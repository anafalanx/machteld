package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::genericTest {
    variable checks 0
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable library {export record .cell<.item> { value: .item }
export choice .outcome<.item> {
    absent
    found(.item)
}
export fn .id<.item>($value: .item) -> .item => $value
export fn .pick<.item>($first: .item?, $fallback: .item) -> .item =>
    match $first { none => $fallback
        some($present) => $present }
export fn .loop<.item>($value: .item, $n: int) -> .item {
    if $n == 0 { return $value }
    return .loop($value, $n - 1)
}
export fn .boxed<.item>($value: .item) -> .outcome<.item> =>
    .outcome::found(.id($value))
export fn .missing<.item>() -> .outcome<.item> => .outcome<.item>::absent()
}
    variable consumer {import shared
alias .names = .shared::cell<list<text>>
export fn .name($value: text) -> text =>
    .shared::loop(.shared::pick(none, $value), 3)
export fn .tag($id: text) -> text =>
    match .shared::boxed($id) {
        .shared::outcome::absent => 'absent'
        .shared::outcome::found($payload) => $payload
    }
export fn .same($a: .names, $b: .shared::cell<list<text>>) -> bool => $a == $b
export fn .edit($json: text) -> result<text,problem> {
    $row ::= decode_json<.shared::cell<text>>($json)?
    return encode_json($row with {value = .shared::id('007')})
}
export fn .read($path: text) -> result<.shared::cell<text>,problem> =>
    sql_one<.shared::cell<text>>($path, 'SELECT ?1 AS value', '007')
}
}

proc ::genericTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::genericTest::invalid {source {code {}}} {
    set diagnostics [::appcompiler::check [dict create sample $source]]
    if {$code eq {}} {
        equal [expr {[llength $diagnostics] > 0}] 1 "invalid declaration or call $source"
    } else {
        equal [expr {$code in [lmap d $diagnostics {dict get $d code}]}] 1 "$code in $diagnostics"
    }
}

proc ::genericTest::rejections {} {
    invalid {fn .bad<.t>($x: .t) -> int => $x} RETURN_TYPE
    invalid {fn .bad<.t>($x: .t) -> int => $x + 1}
    invalid {fn .eq<.t>($a: list<.t>, $b: list<.t>) -> bool => $a == $b} NOT_COMPARABLE
    invalid {fn .twice<.t>($a: .t, $b: .t) -> .t => $a
fn .bad() -> int => .twice(3, 'three')} ARGUMENT_TYPE
    invalid {fn .id<.t>($a: .t) -> .t => $a
fn .bad() -> int => .id<text>(3)} ARGUMENT_TYPE
    invalid {fn .id<.t>($a: .t) -> .t => $a
fn .bad() -> int => .id<int,text>(3)} TYPE_ARITY
    invalid {fn .unspecified<.t>() -> .t? => none
fn .bad() -> int? => .unspecified()} TYPE_INFERENCE
    invalid {record .a<.t> { value: .t }
fn .bad($a: .a<text,int>) -> int => 1} TYPE_ARITY
    invalid {record .a<.t> { value: .t }
fn .bad($a: .a<int>) -> .a<text> => $a} RETURN_TYPE
    invalid {record .a<.t> { value: .t }
fn .bad($a: .a<int>) -> .a<int> => $a with {value = 'one'}} FIELD_TYPE
    invalid {choice .c<.t> { found(.t) }
fn .bad($a: .c<text>) -> int => match $a { .c::found($x) => $x }} RETURN_TYPE
    invalid {record .a<.t,.t> { value: .t }} DUPLICATE_TYPE_PARAMETER
    invalid {fn .good<.t>($x: .t) -> .t => $x
fn .bad($x: .t) -> int => 3}
    set analysis [::appcompiler::analyzeApplication [dict create entry {
        fn .main<.unused>($args: list<text>) -> result<unit,problem> => ok(unit)
    }] entry main]
    equal [lmap d [dict get $analysis diagnostics] {dict get $d code}] ENTRY_TYPE "entry needs concrete type arguments"
}

proc ::genericTest::boundary {} {
    variable library
    variable consumer
    set sources [dict create shared $library client $consumer]
    set artifact [::appcompiler::compile $sources ::genericApp]
    namespace eval :: [dict get $artifact script]
    equal [::genericApp::client::name 007] 007 "nested inference and recursive generic function"
    equal [::genericApp::client::tag 007] 007 "choice payload inferred across modules"
    equal [::genericApp::shared::id text 007] 007 "exported generics accept explicit Tcl type arguments"
    equal [::genericApp::shared::id list<int> {1 02}] {1 2} "guards specialize nested Tcl arguments"
    set stamp 2026-10-25T00:30:00.000000001Z
    equal [::genericApp::shared::id instant $stamp] $stamp "Tcl can supply a temporal type"
    foreach type {missing int<text> list<invalid> {*} {@local} {text int}} {
        equal [catch {::genericApp::shared::id $type abc}] 1 "invalid Tcl type descriptors $type"
    }
    equal [catch {::genericApp::shared::id list<int> {1 abc}}] 1 "Tcl list element guard"
    equal [::genericApp::client::same [dict create value {007 8}] [dict create value {007 8}]] 1 "record/list equality"
    equal [::genericApp::client::same [dict create value {007 8}] [dict create value {7 8}]] 0 "text identity survives"
    lassign [::genericApp::client::edit {{"value":"before","future":42}}] tag json
    equal $tag ok "generic JSON record update"
    set object [::machteld::json decode -typed $json]
    equal [::machteld::json unwrap [::machteld::json get $object value]] 007 "generic JSON field preserves text"
    equal [::machteld::json unwrap [::machteld::json get $object future]] 42 "unknown JSON field survives"
    set tmp [file normalize [file tempdir]]
    try {
        set db [file join $tmp readings.db]
        sqlite3 seed $db
        seed close
        equal [::genericApp::client::read $db] {ok {value 007}} "typed SQLite generic record"
    } finally {file delete -force -- $tmp}
}

proc ::genericTest::packed {} {
    variable root
    variable library
    set tmp [file normalize [file tempdir]]
    try {
        set project [file join $root examples typed-pages project.dict]
        set archive [file join $tmp pages.machteld]
        ::appcompiler::project::pack $project $archive
        set rebuilt [file join $tmp rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        foreach app [list $archive $rebuilt] {
            foreach {command json output} {
                stations {{"items":[{"name":"North"}]}} North
                vehicles {{"items":[{"fleet_id":"007"}]}} 007
                stations {{"items":[]}} {no station}
            } {
                set run [::machteld::run -dir $tmp -stdin $json -timeout 30s -- [info nameofexecutable] $app $command]
                equal [dict get $run exit] 0 "portable $command returned [dict get $run err]"
                equal [dict get $run out] "$output\n" "portable $command result"
            }
            foreach {page signature} {
                fn/pages/first {export fn .first<.item>}
                type/pages/page {export record .page<.item>}
                type/pages/selection {export choice .selection<.item>}
            } {
                set doc [::appcompiler::reference::query $app get $page]
                equal [expr {[string first $signature $doc] >= 0}] 1 "generic application reference $page"
            }
        }
        set mixed [file join $tmp mixed]
        file mkdir $mixed
        foreach {name data} [list shared.src $library main.tcl {
            package require machteld
            set ident [::application::shared::id text 007]
            set missing [::application::shared::missing int]
            set failed [catch {::application::shared::id list<int> {1 text}} message options]
            puts [list $ident $missing $failed [dict get $options -errorcode]]
        } project.dict {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {shared shared.src}}] {
            ::appcompiler::project::stageBytes [file join $mixed $name] [encoding convertto utf-8 $data]
        }
        set mixedApp [file join $tmp mixed.machteld]
        ::appcompiler::project::pack [file join $mixed project.dict] $mixedApp
        set run [::machteld::run -dir $tmp -timeout 30s -- [info nameofexecutable] $mixedApp]
        equal [dict get $run exit] 0 "Tcl-owned project exit: [dict get $run err]"
        lassign [string trim [dict get $run out]] ident missing failed code
        equal $ident 007 "Tcl-owned project can call generic typed export"
        equal [lindex $missing 0] absent "explicit result-only parameter at Tcl boundary"
        equal $failed 1 "Tcl-owned project gets a failed generic value check"
        equal $code {APPCOMPILER ARGUMENT TYPE} "Tcl-owned project preserves typed error code"
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
package require sqlite3
::genericTest::rejections
::genericTest::boundary
if {$argv eq "-pack"} {::genericTest::packed}
puts "application compiler generics: $::genericTest::checks assertions passed"
