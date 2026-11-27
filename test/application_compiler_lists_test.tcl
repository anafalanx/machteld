package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::listsTest {
    variable checks 0
    variable source {export fn .empty<.t>() -> list<.t> => []
export fn .pair<.t>($a: .t, $b: .t) -> list<.t> => [$a, $b]
export fn .nested() -> list<list<int>> => [
    [],
    [7],
    [],
]
export fn .numbers($v: list<int>) -> int => len($v)
export fn .as_argument() -> int => .numbers([])
export fn .with_sibling() -> list<list<text>> => .pair([], ['007'])
export fn .optional() -> list<int?> => [none, some(9)]
export fn .replace() -> list<int> {
    $items := [1]
    $items = []
    return $items
}
export fn .iterate() -> int {
    $total := 0
    for $value in [2, 3, 4] { $total = $total + $value }
    return $total
}
fn .add($n: int, $value: int) -> int => $n + $value
export fn .handlers() -> list<callable<int,int>> => [bind(.add, 2), bind(.add, 3)]
export fn .dispatch($start: int) -> int {
    $value := $start
    for $handler in .handlers() { $value = $handler($value) }
    return $value
}
export fn .rows($rows: list<list<text>>) -> int => len($rows)
export fn .name_size($name: text) -> int => len($name)
export fn .byte_size($data: bytes) -> int => len($data)
export fn .key_count($counts: map<text,int>) -> int => len($counts)
export fn .empty_size() -> int => len([])
export fn .nested_equal() -> bool => [[], ['007']] == [[], ['007']]
export fn .text($input: text) -> list<text> => [$input, '$a; [error BAD]', '007', '']
example .text('x') => ['x', '$a; [error BAD]', '007', '']
extern fn .observe($id: text) -> text = ['::observe']
export fn .seen($divisor: int) -> result<list<text>,problem> => ok([
    .observe('before'),
    $"value ${quotient(8, $divisor)?}",
    .observe('after'),
])
}
}

proc ::listsTest::equal {value expected label} {
    variable checks
    if {$value ne $expected} {error "$label: expected [list $expected], got [list $value]"}
    incr checks
}

proc ::listsTest::direct {} {
    variable source
    set modules [dict create values $source]
    equal [::appcompiler::check $modules] {} "list program checks"
    set app [interp create]
    try {
        $app eval [dict get [::appcompiler::compile $modules ::typed] script]
        $app eval {namespace path ::typed::values; set ::events {}; proc ::observe {v} {lappend ::events $v; return $v}}
        equal [$app eval {empty text}] {} "declared generic result supplies empty list type"
        equal [$app eval nested] {{} 7 {}} "sibling determines nested empty element type"
        equal [$app eval as_argument] 0 "parameter supplies element type"
        equal [$app eval with_sibling] {{} 007} "other argument determines generic element type"
        equal [$app eval optional] [list none [list some 9]] "optional elements join"
        equal [$app eval replace] {} "known mutable binding can be assigned an empty list"
        equal [$app eval iterate] 9 "loop visits every literal element"
        equal [$app eval {dispatch 7}] 12 "ordered typed callbacks retain independent captures"
        equal [$app eval {{*}[lindex [handlers] 1] 10}] 13 "a callback survives the list boundary to Tcl"
        equal [$app eval nested_equal] 1 "equality uses nested element types"
        equal [$app eval {pair text 007 7}] {007 7} "Tcl generic call retains text values"
        set special {x; [error BAD] $a {a b}}
        equal [$app eval [list text $special]] [list $special {$a; [error BAD]} 007 {}] "source and external words remain data"
        equal [$app eval [list rows [list [list $special] {}]]] 2 "list length counts elements"
        equal [$app eval [list name_size "a\U0001f682e\u0301"]] 4 "text length counts Unicode code points"
        equal [$app eval [list byte_size [binary decode hex 00ffc3a9]]] 4 "bytes length counts all octets"
        equal [$app eval [list key_count [dict create {} 7 $special 0 007 1 7 2]]] 4 "map length counts keys"
        equal [$app eval empty_size] 0 "empty length needs no element value"
        equal [$app eval {seen 4}] [list ok [list before {value 2} after]] "successful nested propagation"
        equal [$app eval {set ::events}] {before after} "items evaluated once in source order"
        $app eval {set ::events {}}
        lassign [$app eval {seen 0}] tag failure
        equal [list $tag [dict get $failure code] [dict get $failure origin module]] {err DIVIDE_BY_ZERO values} "failed item keeps source"
        equal [$app eval {set ::events}] before "failed item skips subsequent items"
        equal [catch {$app eval {numbers {1 wrong}}} message options] 1 "Tcl boundary validates elements before computing length"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "Tcl boundary reports a typed failure"
    } finally {interp delete $app}
}

proc ::listsTest::negative {} {
    foreach {code source} {
        LIST_ELEMENT_TYPE {fn .bad() -> list<int> => [1, '2']}
        LIST_ELEMENT_TYPE {fn .bad() -> list<list<int>> => [[1], [], ['2']]}
        INCOMPLETE_TYPE {fn .bad() -> int { $v := [[]]
            $v = [[1]]
            $v = [['2']]
            return 0 }}
        INCOMPLETE_TYPE {fn .bad() -> int { $v ::= []
            return len($v) }}
        INCOMPLETE_TYPE {fn .bad() -> int { $v := ok([])
            $v = ok(['x'])
            return 0 }}
        ASSIGNMENT_TYPE {fn .bad() -> int { $v := [1]
            $v = ['2']
            return len($v) }}
        RETURN_TYPE {fn .bad() -> list<int> => ['2']}
        ARGUMENT_TYPE {fn .bad() -> int => len(4)}
        ARGUMENT_TYPE {fn .bad<.t>($v: .t) -> int => len($v)}
        CALL_ARITY {fn .bad() -> int => len()}
        CALL_ARITY {fn .bad() -> int => len([], [])}
        E_PARSE_EXPECTED {fn .bad() -> list<int> => [1 2]}
        E_PARSE_EXPECTED {fn .bad() -> list<int> => [1,,2]}
        E_PARSE_EXPECTED {fn .bad() -> list<int> => [1,}
    } {
        set diagnostics [::appcompiler::check [dict create invalid $source]]
        equal [lmap d $diagnostics {dict get $d code}] $code "diagnostics for $source"
    }
}

proc ::listsTest::packed {} {
    variable source
    set work [file normalize [file tempdir]]
    try {
        set entry {package require machteld
            chan configure stdout -encoding utf-8 -translation lf
            set value [lindex $argv 0]
            puts [list [::application::values::text $value] [::application::values::name_size $value] [::application::values::nested]]
        }
        set project [file join $work project.dict]
        set manifest {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {values values.src}}
        foreach {name body} [list values.src $source main.tcl $entry project.dict $manifest] {
            ::appcompiler::project::stageBytes [file join $work $name] [encoding convertto utf-8 $body]
        }
        set tested [::appcompiler::project::test $project]
        equal [list [dict get $tested total] [dict get $tested failures]] {1 {}} "list literals in executable examples"
        set archive [file join $work demo.machteld]
        ::appcompiler::project::pack $project $archive
        set rebuilt [file join $work rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        set expected [list [list {雪 $x; [error BAD]} {$a; [error BAD]} 007 {}] 17 {{} 7 {}}]
        foreach app [list $archive $rebuilt] {
            set run [::machteld::run -dir $work -timeout 30s -- [info nameofexecutable] $app {雪 $x; [error BAD]}]
            equal [list [dict get $run exit] [dict get $run err]] {0 {}} "packed Tcl entry runs"
            equal [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run out]] "\n"] $expected "packed Tcl/typed round trip"
        }
    } finally {file delete -force -- $work}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::listsTest::direct
::listsTest::negative
if {$argv eq "-pack"} {::listsTest::packed}
puts "application compiler lists: $::listsTest::checks assertions passed"
