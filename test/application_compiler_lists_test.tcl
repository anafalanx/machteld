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
export fn .extend<.t>($values: list<.t>, $item: .t) -> list<.t> =>
    list_append($values, $item)
export fn .initial<.t>() -> list<.t> => list<.t>()
export fn .lookup<.t>($values: list<.t>, $i: int) -> .t? => $values[$i]
example .lookup<text>(['', '007'], 0) => some('')
export fn .required<.t>($values: list<.t>, $i: int) -> result<.t,problem> =>
    require_index($values, $i)
export fn .inferred() -> list<text> {
    $names := list_append([], '007')
    return list_append($names, '7')
}
fn .identity($values: list<int>) -> list<int> => $values
export fn .snapshots() -> list<list<int>> {
    $values := [1, 2]
    $initial ::= $values
    $saved ::= bind(.identity, $values)
    for $n in $values { $values = list_append($values, $n + 2) }
    return [$initial, $saved(), $values]
}
export fn .collect($limit: int) -> list<int> {
    $values := list<int>()
    for $n in 0..$limit { $values = list_append($values, $n) }
    return $values
}
example .collect(3) => [0, 1, 2]
export fn .different_base() -> list<text> {
    $left := ['left']
    $other ::= ['other']
    $left = list_append($other, 'tail')
    return $left
}
export fn .append_quotient($divisor: int) -> result<list<int>,problem> {
    $history := [11]
    $history = list_append($history, quotient(8, $divisor)?)
    return ok($history)
}
export record .observation {
    group: text
    id: text
    selected: bool
}
export fn .groups($rows: list<.observation>) -> map<text,list<text>> {
    $groups := map<text,list<text>>()
    for $row in $rows {
        if $row.selected {
            $members ::= match $groups[$row.group] {
                none => list<text>()
                some($present) => $present
            }
            $groups = map_put($groups, $row.group, list_append($members, $row.id))
        }
    }
    return $groups
}
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
        equal [$app eval {initial list<int?>}] {} "explicit generic empty nested list"
        equal [$app eval inferred] {007 7} "append infers an empty literal's element"
        equal [$app eval snapshots] {{1 2} {1 2} {1 2 3 4}} "copy, callback and iteration retain their snapshots"
        equal [$app eval different_base] {other tail} "assignment can build from a different local"
        set step [list apply {{words op} {
            if {[lindex $words 0] eq "::lappend" && [string match v_* [lindex $words 1]]} {incr ::updates}
        }}]
        $app eval {set ::updates 0}
        $app eval [list trace add execution ::typed::values::append_quotient enterstep $step]
        try {
            lassign [$app eval {append_quotient 0}] tag detail
            equal [list $tag [dict get $detail code] [$app eval {set ::updates}]] {err DIVIDE_BY_ZERO 0} "failed item propagates before any update"
            equal [$app eval {append_quotient 2}] {ok {11 4}} "successful item appended"
            equal [$app eval {set ::updates}] 1 "successful assignment updates the local once"
        } finally {$app eval [list trace remove execution ::typed::values::append_quotient enterstep $step]}
        equal [$app eval {lookup text {{} 007} 0}] {some {}} "present empty text"
        equal [$app eval {lookup text {{} 007} 0001}] {some 007} "an input integer indexes from zero"
        equal [$app eval {lookup int? {none {some 9}} 0}] {some none} "present absent optional differs from missing index"
        equal [$app eval {lookup list<int> {{} {2 3}} 0}] {some {}} "present empty nested list"
        foreach index [list -1 2 [string repeat 9 100] -[string repeat 9 100]] {
            equal [$app eval [list lookup text {{} 007} $index]] none "missing index $index"
            lassign [$app eval [list required text {{} 007} $index]] tag failure
            equal [list $tag [dict get $failure code]] {err INDEX_OUT_OF_RANGE} "required bounds failure for $index"
        }
        equal [$app eval {required text {{} 007} 0}] {ok {}} "required empty text"
        set raw [binary decode hex 00ffc0af]
        set extended [$app eval [list extend bytes {} $raw]]
        equal [binary encode hex [lindex [$app eval [list lookup bytes $extended 0]] 1]] 00ffc0af "append and lookup preserve raw bytes"
        binary scan [binary decode hex 3ff0000000000001] Q measured
        set extended [$app eval [list extend binary64 {} $measured]]
        equal [binary encode hex [binary format Q [lindex [$app eval [list lookup binary64 $extended 0]] 1]]] 3ff0000000000001 "binary64 values retain every bit"
        equal [$app eval {extend list<int?> {{none}} {{some 1} none}}] [list [list none] [list [list some 1] none]] "generic nested optional append"
        set rows {{group A id 007 selected 1} {group B id skipped selected 0} {group C id {} selected 1} {group A id 7 selected 1}}
        equal [$app eval [list groups $rows]] {A {007 7} C {{}}} "filter and group preserve order, spelling and the empty id"
        set values [$app eval {collect 40000}]
        equal [list [llength $values] [lindex $values 0] [lindex $values end]] {40000 0 39999} "large collector preserves all positions"
        equal [regexp -line {^::lappend v_[0-9a-f]+ } [$app eval {info body ::typed::values::collect}]] 1 "repeated direct append uses the local Tcl instruction"
        equal [catch {$app eval {lookup text {x} end}} msg options] 1 "Tcl end index rejected at typed boundary"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "invalid index has a typed boundary error"
        equal [catch {$app eval {extend int {1 2} bad}} msg options] 1 "Tcl append item checked against its descriptor"
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
        TYPE_ARITY {fn .bad() -> list<int> => list()}
        TYPE_ARITY {fn .bad() -> list<int> => list<int,text>()}
        CALL_ARITY {fn .bad() -> list<int> => list<int>(1)}
        CALL_ARITY {fn .bad() -> list<int> => list_append([1])}
        EXPECTED_LIST {fn .bad() -> list<int> => list_append(1, 2)}
        ARGUMENT_TYPE {fn .bad() -> list<int> => list_append([1], '2')}
        LIST_INDEX_TYPE {fn .bad() -> int? => [1]['0']}
        LIST_INDEX_TYPE {distinct .index = int
            fn .bad($i: .index) -> int? => [1][$i]}
        ARGUMENT_TYPE {fn .bad() -> result<int,problem> => require_index([1], '1')}
        EXPECTED_LIST {fn .bad() -> result<int,problem> => require_index(map<text,int>(), 0)}
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
        set author [file join $work author]
        set delivery [file join $work {new location}]
        set elsewhere [file join $work elsewhere]
        file mkdir $author $delivery $elsewhere
        set entry {package require machteld
            chan configure stdout -encoding utf-8 -translation lf
            set value [lindex $argv 0]
            set rows [list [dict create group A id $value selected 1] [dict create group A id skip selected 0] [dict create group A id 007 selected 1]]
            set selected [dict get [::application::values::groups $rows] A]
            puts [list [::application::values::text $value] [::application::values::name_size $value] [::application::values::nested] \
                $selected [::application::values::lookup text $selected 1] [::application::values::required text $selected 0]]
        }
        set project [file join $author project.dict]
        set manifest {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {values values.src}}
        foreach {name body} [list values.src $source main.tcl $entry project.dict $manifest] {
            ::appcompiler::project::stageBytes [file join $author $name] [encoding convertto utf-8 $body]
        }
        set tested [::appcompiler::project::test $project]
        equal [list [dict get $tested total] [dict get $tested failures]] {3 {}} "list operations in executable examples"
        set archive [file join $delivery demo.machteld]
        ::appcompiler::project::pack $project $archive
        set rebuilt [file join $delivery rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        set expected [list [list {雪 $x; [error BAD]} {$a; [error BAD]} 007 {}] 17 {{} 7 {}} \
            [list {雪 $x; [error BAD]} 007] {some 007} [list ok {雪 $x; [error BAD]}]]
        set driver [file join $::appcompiler::compilerDirectory driver.tcl]
        foreach command [list [list $driver run $project] [list $archive] [list $rebuilt]] {
            set run [::machteld::run -dir $elsewhere -timeout 30s -- [info nameofexecutable] {*}$command {雪 $x; [error BAD]}]
            equal [list [dict get $run exit] [dict get $run err]] {0 {}} "Tcl entry runs through $command"
            equal [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run out]] "\n"] $expected "typed list results through $command"
            if {[lindex $command 0] eq $driver} {file rename $author [file join $work retired]}
        }
    } finally {file delete -force -- $work}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::listsTest::direct
::listsTest::negative
if {$argv eq "-pack"} {::listsTest::packed}
puts "application compiler lists: $::listsTest::checks assertions passed"
