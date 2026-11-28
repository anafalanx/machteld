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
export choice .state { idle }
record .private { key: text }
export fn .inside($key: text) -> text => make<.private>(key: $key).key
export record .empty {}
export record .flat {
    label: text
    tick: int
    valid: bool
}
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
export fn .same_flat($a:.model::flat,$b:.model::flat) -> bool => $a == $b
export fn .different_flat($a:.model::flat,$b:.model::flat) -> bool => $a != $b
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
proc ::recordTest::borrowedValues {} {
    # A native node has a Tcl spelling as well as a separate JSON type.
    # Every public call must leave that type usable by its original owner.
    foreach {type wire wrap rejected} {
        bytes               17                  direct 0
        bytes               {"雪"}              direct 1
        result<int,problem> 17                  direct 1
        range<int>          17                  direct 1
        map<text,text>      {["alpha beta"]}     direct 0
        problem             {["a b message c"]} direct 0
        problem             {["a b c d"]}       origin 1
        .model::state       {"idle"}            direct 0
        instant             {"invalid"}         direct 1
        local_datetime      {"invalid"}         direct 1
    } {
        set node [::machteld::json decode -typed $wire]
        set kind [::machteld::json type $node]
        set plain [string range "_$node" 1 end]
        set native $node
        if {$wrap eq "origin"} {
            set plain [dict create message sample origin $plain]
            set native [dict create message sample origin $node]
        }
        set reference [catch {call create $type id $plain} want original]
        equal $reference $rejected "$type reference outcome"
        equal [catch {call create $type id $native} got options] $reference "$type public outcome"
        equal $got $want "$type complete value or diagnostic"
        if {$rejected} {
            equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "$type public error code"
        }
        equal [::machteld::json type $node] $kind "$type keeps the borrowed JSON type"
        equal [::machteld::json encode -- $node] $wire "$type keeps the borrowed JSON value"
    }
    set bytes {}
    for {set n 0} {$n < 256} {incr n} {append bytes [format %c $n]}
    set expected [binary format a* $bytes]
    foreach input [list $bytes $expected] {
        equal [binary encode hex [dict get [call create bytes id $input] value]] \
            [binary encode hex $expected] "all 256 octets round-trip through bytes"
    }
}
proc ::recordTest::direct {} {
    variable model
    variable client
    variable events
    set modules [dict create model $model client $client]
    equal [::appcompiler::check $modules] {} "record construction checks"
    namespace eval :: [dict get [::appcompiler::compile $modules ::typedRecords] script]
    borrowedValues
    set a [dict create label "007\u0000雪" tick [expr {1 << 100}] valid 1]
    set b [dict create valid 1 label "007\u0000雪" tick +001267650600228229401496703205376]
    foreach {field value} [list label "7\u0000雪" tick [expr {(1 << 100) + 1}] valid 0] {
        equal [call different_flat $a [dict replace $b $field $value]] 1 "flat record distinguishes $field"
    }
    equal [call same_flat $a $b] 1 "flat equality honors field order independence and canonical integers"
    set left [::machteld::json decode -typed {{"a":[1.00e2,"x\u0000y"],"b":false}}]
    set right [::machteld::json decode -typed {{"b":false,"a":[100,"x\u0000y"]}}]
    set changed [::machteld::json decode -typed {{"b":false,"a":["100","x\u0000y"]}}]
    set extended [dict replace $a provenance $left]
    equal [call same_flat $extended [dict replace $b provenance $right]] 1 "retained evidence is recursively equal"
    equal [call different_flat $extended [dict replace $b provenance $changed]] 1 "retained evidence preserves JSON type"
    equal [call same_flat $extended [dict replace $b other $right]] 0 "equal extra counts with different keys"
    equal [call same_flat $b $extended] 0 "an additional retained field affects equality"
    equal [::machteld::json type $left] object "record equality preserves borrowed evidence"
    equal [call write [dict create id fixture value "A\u0000B\u0000\\u0000"]] \
        [list ok {{"id":"fixture","value":"A\u0000B\u0000\\u0000"}}] \
        "embedded NULs and a literal backslash escape stay distinct in an exported record"
    lassign [call write [dict create id fixture value "A\u0000\ud800"]] tag problem
    equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} \
        "a NUL and a following unpaired surrogate retain their schema diagnostic"
    foreach {wire kind} {17 number true boolean {"quoted"} string {[1,null]} array {{"nested":[1.0e+2]}} object} {
        set node [::machteld::json decode -typed $wire]
        set row [dict create id $node value "left\u0000right" extra $node]
        lassign [call write $row] tag encoded
        equal [::machteld::json type $node] $kind "encoding a declared text field retains the original $kind handle"
        equal $tag ok "write a borrowed text field and its opaque alias"
        set result [::machteld::json decode -typed $encoded]
        equal [::machteld::json unwrap [::machteld::json get $result id]] $wire "declared text keeps the handle's spelling"
        equal [::machteld::json encode -- [::machteld::json get $result extra]] $wire "opaque alias keeps its JSON value"
        equal [::machteld::json encode -- [::machteld::json get $result value]] {"left\u0000right"} "embedded NUL survives"
    }
    foreach type {decimal binary64} {
        foreach boundary [list $type list<$type>] {
            foreach {wire rejected} {1.125 0 true 1} {
                set input [::machteld::json decode -typed $wire]
                set kind [::machteld::json type $input]
                set argument $input
                if {$boundary ne $type} {set argument [list $input]}
                set code [catch {call create $boundary id $argument} answer options]
                equal $code $rejected "$boundary accepts or rejects a borrowed $wire"
                if {$rejected} {
                    equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "$boundary rejection code"
                } else {
                    equal [dict get $answer value] 1.125 "$boundary normalizes its result"
                }
                equal [::machteld::json type $input] $kind "$boundary preserves its caller's JSON type"
                equal [::machteld::json encode -- $input] $wire "$boundary preserves the JSON value"
            }
        }
    }
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

proc ::recordTest::guardFailure {command expected} {
    equal [catch {{*}$command} message options] 1 "reject $command"
    equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "boundary error code"
    equal $message $expected "first failing boundary value"
}

proc ::recordTest::guardLists {} {
    set source {record .sample {
    tick: int
    channel: text
    reading: int?
    note: text?
}
record .box<.t> { value: .t }
record .lease { handle: ref<int> }
record .sparse { note: text? }
export fn .sparse_rows($items: list<.sparse>) -> list<.sparse> => $items
export fn .number($value: int) -> int => $value
fn .expired() -> ref<int> {
    using $r ::= ref(1) { return $r }
}
export fn .ignore($items: list<.lease>) -> int => 0
export fn .stale() -> int => .ignore([make<.lease>(handle: .expired())])
export fn .rows($items: list<.sample>) -> list<.sample> => $items
export fn .skip($items: list<.sample>) -> int => 0
export fn .boxes($items: list<.box<int>>) -> list<.box<int>> => $items
export fn .words($items: list<text>) -> list<text> => $items
export fn .ids($items: list<int>) -> list<int> => $items}
    set twin {record .other {
    tick: int
    channel: text
    reading: int?
    note: text?
}
export fn .rows($items: list<.other>) -> list<.other> => $items}
    namespace eval :: [dict get [::appcompiler::compile [dict create guards $source twin $twin] ::checkedRows] script]
    set api ::checkedRows::guards
    set rt ::checkedRows::@rt
    set row [dict create channel "x\0雪" extra opaque tick +0008 reading {some -007} note {some {}}]
    set expected [dict replace $row tick 8 reading {some -7}]
    set next [dict create channel {two words} tick -00]
    set rows [list $row $next]
    equal [${api}::rows $rows] [list $expected [dict replace $next tick 0]] "record order, extras and omitted fields"
    equal [dict get [lindex $rows 0] tick] +0008 "the caller's retained row is unchanged"
    set scalar [::machteld::json decode -typed 17]
    equal [${api}::number $scalar] 17 "a native JSON integer can be admitted as an X integer"
    equal [::machteld::json type $scalar] number "the caller keeps the original native number"
    set required [::machteld::json decode -typed 29]
    set optional [::machteld::json decode -typed -3]
    set normalized [lindex [${api}::rows [list [dict create tick $required channel a reading [list some $optional]]]] 0]
    equal [list [dict get $normalized tick] [dict get $normalized reading]] {29 {some -3}} "nested integers normalize"
    equal [list [::machteld::json type $required] [::machteld::json type $optional]] {number number} "required and optional fields retain their original native numbers"
    set fraction [::machteld::json decode -typed 0.5]
    guardFailure [list ${api}::number $fraction] {expected int at $value}
    equal [::machteld::json type $fraction] number "an invalid integer still belongs to its caller"
    set raw [::machteld::json unwrap [::machteld::json decode -typed {"17\u0000tail"}]]
    guardFailure [list ${api}::number $raw] {expected int at $value}
    equal [${api}::words "   {a}    {b c}   {}  "] [list a {b c} {}] "canonical public Tcl list spelling"
    set number [::machteld::json decode -typed 17]
    equal [${api}::words $number] [list 17] "a native number has a one-word list representation"
    equal [::machteld::json type $number] number "text-list checks retain the caller-owned outer object"
    set words [${api}::words [list $number {two words}]]
    equal [::machteld::json type [lindex $words 0]] number "text-list projection retains native element handles"
    set big [expr {1 << 143}]
    equal [${api}::ids [list -000 +0008 -$big]] [list 0 8 -$big] "signed decimal list and bignum"
    equal [${api}::boxes {{value 0008}}] {{value 8}} "concrete generic list schema"
    foreach {bad want} [list [dict remove $next channel] {expected text at $items.1.channel} \
            [dict replace $next tick 0x10] {expected int at $items.1.tick} \
            [dict replace $next reading {some 1e2}] {expected int at $items.1.reading} \
            [dict replace $next note {none extra}] {expected text? at $items.1.note}] {
        guardFailure [list ${api}::skip [list $row $bad]] $want
    }
    guardFailure [list ${api}::words "\{"] {expected list<text> at $items}
    guardFailure [list ${api}::ids {+08 NaN 0xff}] {expected int at $items.1}
    set record [lindex [dict keys [${rt}::schemas] *sample] 0]
    set type list<$record>
    set other [lindex [dict keys [${rt}::schemas] *other] 0]
    set twinApi ::checkedRows::twin::rows
    foreach command [list ${api}::rows $twinApi] element [list $record $other] {
        guardFailure [list $command "\{"] [format {expected list<%s> at $items} $element]
        guardFailure [list $command [list $row odd]] [format {expected %s at $items.1} $element]
    }
    equal [$twinApi $rows] [${api}::rows $rows] "identical fields in another nominal type"
    set shared {}
    foreach command [list ${api}::rows $twinApi] {
        equal [regexp {(\S+::recordList[0-9]+) } [info body $command] -> helper] 1 "concrete public list guard emitted"
        lappend shared $helper
    }
    equal [lindex $shared 0] [lindex $shared 1] "share code for matching ordered fields across modules"
    set untouched {  {extra}     {same}  }
    equal [${api}::sparse_rows [list $untouched]] [list $untouched] "absent optional field preserves original dictionary spelling"
    set noncanonical { {tick}  5  channel   {a}  extra  {b} }
    equal [${api}::rows [list $noncanonical]] [list {tick 5 channel a extra b}] "present fields canonicalize dictionary spelling"
    equal [${api}::rows [list {tick 1 channel a tick +002}]] [list {tick 2 channel a}] "ordinary public dictionary uses the last duplicate field"
    set typed [::machteld::json value string retained]
    set fromExtern [${rt}::guard $type [list [dict replace $row extra $typed]] value 1]
    equal [::machteld::json type [dict get [lindex $fromExtern 0] extra]] string "extern retains typed JSON extras"
    guardFailure [list ${rt}::guard $type $rows value 1] {expected a retained typed JSON value at value.0[extra]}
    foreach mode {worker workerOutput} {
        guardFailure [list ${rt}::guard $type $rows payload $mode] {expected a declared worker message field at payload.0[extra]}
        set duplicate [list [concat $next {tick 5}]]
        guardFailure [list ${rt}::guard $type $duplicate payload $mode] {expected unique worker record fields at payload.0}
    }
    equal [catch {${api}::stale} message options] 1 "validate unused fields that hold a reference"
    equal [dict get $options -errorcode] {APPCOMPILER REFERENCE EXPIRED} "nested reference must still be live"

    set ::recordTest::schemaLookups 0
    set counter [list apply {{command operation} {incr ::recordTest::schemaLookups}}]
    trace add execution ${rt}::specializeSchema enter $counter
    try {
        ${api}::rows [lrepeat 8 $row]
    } finally {trace remove execution ${rt}::specializeSchema enter $counter}
    equal [expr {$::recordTest::schemaLookups <= 1}] 1 "resolve the record shape at most once for the list"
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
::recordTest::guardLists
::recordTest::negative
if {$argv eq "-pack"} {
    set work [file normalize [file tempdir]]
    try {::recordTest::packed $root $work} finally {file delete -force -- $work}
}
puts "application compiler records: $::recordTest::checks assertions passed"
