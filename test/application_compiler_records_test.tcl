package require machteld
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

namespace eval ::recordTest {
    variable checks 0
    variable model {export record .row<.t> {
    id: text
    value: .t
    note: text?
}
export alias .text_row = .row<text>
export alias .native_output = process_output
export distinct .identifier = text
record .private { key: text }
export fn .inside($key: text) -> text => make<.private>(key: $key).key
export record .empty {}
export record .words {
    while: text
    label: text
    id: text
}
export record .wrapper<.t> { child: .t }
}
    variable client {import model
extern fn .observe($which: text, $bad: bool) -> result<text,problem> = ['::observe']
export fn .create<.t>($id: text,$v: .t) -> .model::row<.t> =>
    make<.model::row<.t>>(value: $v, id: $id)
export fn .none($id: text,$v: text) -> .model::text_row =>
    make<.model::text_row>(id: $id, note: none, value: $v)
export fn .present($id: text,$v: text) -> .model::text_row =>
    make<.model::text_row>(note: some(''), value: $v, id: $id)
export fn .note($r: .model::text_row) -> text? => $r.note
export fn .same($a: .model::text_row, $b: .model::text_row) -> bool => $a == $b
export fn .write($r: .model::text_row) -> result<text,problem> => encode_json($r)
export fn .read($v: text) -> result<.model::text_row,problem> => decode_json<.model::text_row>($v)
export fn .update($r: .model::text_row) -> .model::text_row => $r with {id='updated'}
export fn .nested() -> .model::wrapper<.model::row<int>> =>
    make<.model::wrapper<.model::row<int>>>(child: .create('007', 8))
export fn .optional_type() -> .model::wrapper<text?> => make<.model::wrapper<text?>>()
export fn .blank() -> .model::empty => make<.model::empty>()
export fn .literal() -> .model::text_row => make<.model::text_row>(id:'007', value:'[error BAD] $secret; 雪')
export fn .scalar($id: text) -> .model::identifier => make<.model::identifier>($id)
export fn .seen($fail: bool) -> result<.model::words,problem> =>
    ok(make<.model::words>(
        id: .observe('1',false)?,
        while: .observe('2',$fail)?,
        label: .observe('3',false)?))
}
}

proc ::recordTest::equal {got want label} {
    variable checks
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
    incr checks
}
proc ::recordTest::call {fn args} {::typedRecords::client::$fn {*}$args}
proc ::observe {id fail} {
    lappend ::recordTest::events $id
    if {$fail} {return {err {code TEST_STOP message stopped}}}
    return [list ok $id]
}
proc ::recordTest::direct {} {
    variable model
    variable client
    variable events
    set modules [dict create model $model client $client]
    equal [::appcompiler::check $modules] {} "record construction checks"
    namespace eval :: [dict get [::appcompiler::compile $modules ::typedRecords] script]
    set hostile {007; [error BAD] $value {two words} 雪}
    set omitted [call create text 007 $hostile]
    equal [dict get $omitted id] 007 "text identity preserves leading zeros"
    equal [dict get $omitted value] $hostile "record retains exact Tcl values"
    equal [dict exists $omitted note] 0 "omitted optional has no Tcl dictionary key"
    equal [call note $omitted] none "omitted reads as none"
    set absent [call none 007 $hostile]
    equal [dict get $absent note] none "explicit none uses the tagged optional ABI"
    equal [call same $omitted $absent] 1 "omission and none compare equal"
    set present [call present 007 $hostile]
    equal [call note $present] [list some {}] "present empty text differs from absence"
    foreach row [list $omitted $absent $present] has {0 0 1} {
        lassign [call write $row] tag encoded
        equal $tag ok "constructed values encode"
        set decoded [::machteld::json unwrap [::machteld::json decode -typed $encoded]]
        equal [list [dict get $decoded id] [dict get $decoded value] [dict exists $decoded note]] [list 007 $hostile $has] "JSON optional field presence"
        lassign [call read $encoded] tag roundTrip
        equal [list $tag [call same $roundTrip $row]] {ok 1} "constructed JSON round trip"
    }
    lassign [call read {{"id":"x","value":"y","extra":{"before":1}}}] tag older
    lassign [call write [call update $older]] tag encoded
    set decoded [::machteld::json unwrap [::machteld::json decode -typed $encoded]]
    equal [list [dict get $decoded id] [dict get $decoded extra before]] {updated 1} "decoded records still preserve unknown fields during update"
    equal [dict get [call nested] child value] 8 "nested concrete generic"
    equal [call optional_type] {} "generic type argument makes a field optional"
    equal [call blank] {} "empty declared record"
    equal [dict get [call literal] value] {[error BAD] $secret; 雪} "source text remains data in generated Tcl"
    equal [::typedRecords::model::inside 007] 007 "private record within defining module"
    equal [call scalar 007] 007 "distinct scalar make retains existing ABI"
    equal [catch {call create int 007 bad} ignored options] 1 "Tcl generic call guards field input"
    equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "existing generic boundary code"
    set events {}
    lassign [call seen 0] tag fields
    equal [list $tag [dict get $fields id] [dict get $fields while] [dict get $fields label]] {ok 1 2 3} "names select fields in arbitrary source order"
    equal $events {1 2 3} "each expression runs exactly once in source order"
    set events {}
    lassign [call seen 1] tag problem
    equal [list $tag [dict get $problem code] [dict get $problem origin module]] {err TEST_STOP client} "propagated field failure has a source origin"
    equal $events {1 2} "fields after a failed expression do not execute"
}

proc ::recordTest::bad {imports body code span} {
    variable model
    set input "$imports\n$body"
    set diagnostics [::appcompiler::check [dict create model $model client $input]]
    equal [lmap d $diagnostics {dict get $d code}] [list $code] "diagnostics for $body"
    set loc [dict get [lindex $diagnostics 0] node]
    equal [dict get $loc module] client "diagnostic module"
    set line [lindex [split $input \n] [expr {[dict get $loc line] - 1}]]
    equal [string range $line [expr {[dict get $loc column]-1}] [expr {[dict get $loc endColumn]-2}]] $span "original source span"
    if {$code eq "DUPLICATE_FIELD"} {
        equal [dict get $loc column] [expr {[string last "$span:" $line] + 1}] "duplicate points to the later label"
    }
}
proc ::recordTest::negative {} {
    set import {import model}
    bad $import {fn .bad() -> .model::text_row => make<.model::text_row>(id: 'x', value: 'y', id: 'z')} DUPLICATE_FIELD id
    bad $import {fn .bad() -> .model::text_row => make<.model::text_row>(id: 'x', VALUE: 'y')} UNKNOWN_FIELD VALUE
    bad $import {fn .bad() -> .model::text_row => make<.model::text_row>(id: 'x')} MISSING_FIELD .model::text_row
    bad $import {fn .bad() -> .model::text_row => make<.model::text_row>('x', value:'y')} ARGUMENT_LABEL {'x'}
    bad $import {fn .bad() -> .model::row<int> => make<.model::row<int>>(id: 'x', value: '8')} FIELD_TYPE {'8'}
    bad $import {fn .bad() -> .model::text_row => make<.model::text_row>(id: 'x', value: '', note: 'x')} FIELD_TYPE {'x'}
    bad $import {fn .bad() -> text => make<.model::private>(key: 'x').key} NOT_EXPORTED .model::private
    bad {} {fn .bad() -> text => make<.model::text_row>(id: 'x',value: 'y').id} MISSING_IMPORT .model::text_row
    bad $import {fn .bad() -> text => make<text>('x')} EXPECTED_DISTINCT text
    bad $import {fn .bad() -> .model::identifier => make<.model::identifier>(8)} ARGUMENT_TYPE 8
    bad $import {fn .bad() -> .model::identifier => make<.model::identifier>()} CALL_ARITY make
    bad $import {fn .bad() -> process_output => make<process_output>()} EXPECTED_DISTINCT process_output
    bad $import {fn .bad() -> process_output => make<.model::native_output>(status: 'forged')} EXPECTED_DISTINCT .model::native_output
    bad $import {fn .bad() -> ref<int> => make<ref<int>>(0)} EXPECTED_DISTINCT ref<int>
}

proc ::recordTest::packed {root work} {
    set manifest [file join $root examples typed-request project.dict]
    set tested [::appcompiler::project::test $manifest]
    equal [list [dict get $tested total] [dict get $tested failures]] {1 {}} "typed request executable example"
    set archive [file join $work request.machteld]
    ::appcompiler::project::pack $manifest $archive
    set rebuilt [file join $work rebuilt.machteld]
    ::appcompiler::project::rebuild $archive $rebuilt
    set special {007; [error BAD] $n 雪}
    foreach path [list $archive $rebuilt] {
        set run [::machteld::run -dir $work -timeout 15s -- [info nameofexecutable] $path $special]
        equal [list [dict get $run exit] [dict get $run err]] {0 {}} "packed typed request executes"
        set json [encoding convertfrom -profile strict utf-8 [dict get $run out]]
        set row [::machteld::json unwrap [::machteld::json decode -typed $json]]
        equal [list [dict get $row asset_id] [dict get $row sample_limit] [dict exists $row note]] [list $special 3 0] "rebuilt request uses direct typed input"
    }
}
if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::recordTest::direct
::recordTest::negative
if {$argv eq "-pack"} {
    set work [file normalize [file tempdir]]
    try {::recordTest::packed $root $work} finally {file delete -force -- $work}
}
puts "application compiler records: $::recordTest::checks assertions passed"
