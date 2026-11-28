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
export fn .flags($bits: list<bool>) -> list<bool> => $bits
export fn .matrix($bits: list<list<bool>>) -> list<list<bool>> => $bits
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
export fn .required_value<.t>($values: list<.t>, $i: int) -> result<.t,problem> =>
    ok(require_index($values, $i)?)
export fn .required_effects($values: list<text>) -> result<text,problem> =>
    ok(require_index(list_append($values, .observe('base')), len(.observe('x')))?)
extern fn .index_hook() -> unit = ['::index_hook']
export fn .present_at($values:list<text>, $i:int) -> bool {
    .index_hook()
    return match $values[$i] {some(_) => true
        none => false}
}
export fn .assign_only($maybe:int?) -> int {
    $unused := 0
    .index_hook()
    $unused = match $maybe { some($n) => $n
        none => 19 }
    return 42
}
export fn .watched($values:list<text>, $i:int) -> result<text,problem> {
    .index_hook()
    return ok(require_index($values, $i)?)
}
export fn .watched_bound($values:list<text>, $i:int) -> result<text,problem> {
    .index_hook()
    $selected ::= require_index($values, $i)?
    return ok($selected)
}
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
export fn .match_history($items: list<int?>) -> list<list<int>> {
    $out := [10]
    $versions := list<list<int>>()
    for $item in $items {
        $versions = list_append($versions, $out)
        $out = match $item { none => $out
            some($n) => list_append($out, $n) }
    }
    return list_append($versions, $out)
}
export fn .match_put($item: int?, $key: text, $divisor: int) -> result<list<map<text,int>>,problem> {
    $state := map_put(map<text,int>(), 'seed', 1)
    $saved ::= $state
    $state = match $item {
        some($n) => map_put($state, .observe($key), quotient($n, $divisor)?)
        none => $state
    }
    return ok([$saved, $state])
}
export fn .match_other($captured: list<int>?) -> list<int> {
    $out := [99]
    $out = match $captured { none => $out
        some($v) => list_append($v, 7) }
    return $out
}
export fn .match_argument($item: int?) -> list<list<int>> {
    $out := [1]
    return [$out, match $item { some($n) => list_append($out, $n)
        none => $out }, $out]
}
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

proc ::listsTest::watchedReads {app fn} {
    $app eval [list set ::selectedLocal [::appcompiler::emitLocalName selected]]
    $app eval {
        proc ::index_hook {} {}
        proc ::installIndexReads {cmd op} {
            if {$::action eq "write"} {
                uplevel 1 [list trace add variable $::selectedLocal write ::destinationWrite]
            }
            foreach name [info args ::typed::values::watched] label {list index} {
                uplevel 1 [list trace add variable $name read [list ::indexRead $label]]
            }
        }
        proc ::destinationWrite {name sub op} {
            upvar 1 $name selected
            lappend ::reads write
            set selected "observed $selected"
        }
        proc ::indexRead {label name sub op} {
            upvar 1 $name value
            lappend ::reads $label
            if {$label eq "list" && $::action eq "fail"} {error "unavailable"}
            if {$label eq "index" && $::action eq "move"} {set value [incr ::position]}
            if {$label eq "index" && $::action eq "replace"} {
                upvar 1 [lindex [info args ::typed::values::watched] 0] original
                set original {changed}
            }
        }
        trace add execution ::typed::values::index_hook enter ::installIndexReads
    }
    try {
        foreach action {move replace} {
            $app eval [list set ::action $action]
            $app eval {set ::reads {}; set ::position -1}
            equal [$app eval [list $fn {first second third} 0]] {ok first} \
                "required lookup uses its original list and index under $action"
            equal [$app eval {set ::reads}] {list index} "each operand is read once in source order"
        }
        $app eval {set ::reads {}; set ::action fail}
        set status [catch {$app eval [list $fn first 0]} msg opts]
        equal $status 1 "failure while reading the first operand reaches the Tcl caller"
        equal [dict get $opts -errorcode] {TCL READ VARNAME} "original variable-read error"
        equal [$app eval {set ::reads}] list "the index is never read after the list read fails"
        if {$fn eq "watched_bound"} {
            $app eval {set ::reads {}; set ::action write}
            equal [$app eval [list $fn first 0]] {ok {observed first}} "destination write trace sees the element"
            equal [$app eval {set ::reads}] {list index write} "the lookup completes before writing its destination"
            lassign [$app eval [list $fn first [expr {1 << 200}]]] tag problem
            equal [list $tag [dict get $problem code]] {err INDEX_OUT_OF_RANGE} "a bound lookup propagates huge misses"
        }
    } finally {$app eval {trace remove execution ::typed::values::index_hook enter ::installIndexReads}}
    # A Tcl abstract list may compute its length in a callback. A positive
    # miss asks once for the bounds check and once for the diagnostic.
    $app eval {
        proc ::observeLength {cmd op} {
            if {[lindex $cmd 1] eq {unique witness list}} {incr ::lengthCalls}
        }
        trace add execution ::llength enter ::observeLength
    }
    try {
        foreach {index expected} {-1 1 1 1 12 2} {
            $app eval {set ::lengthCalls 0}
            $app eval [list $fn {unique witness list} $index]
            equal [$app eval {set ::lengthCalls}] $expected "$fn list length evaluations for index $index"
        }
    } finally {$app eval {trace remove execution ::llength enter ::observeLength}}
}

proc ::listsTest::discardedIndex {app} {
    $app eval {
        proc ::replaceIndex {local command op} {uplevel 1 [list set $local $::dynamicIndex]}
        proc ::failElement {command op} {
            if {[lindex $command 1] eq {witness values}} {
                return -code error -errorcode {TEST ELEMENT} {element could not be read}
            }
        }
        set indexLocal [lindex [info args ::typed::values::present_at] 1]
        set callback [list ::replaceIndex $indexLocal]
        trace add execution ::typed::values::index_hook enter $callback
    }
    try {
        foreach value {0.5 NaN} {
            $app eval [list set ::dynamicIndex $value]
            set answer [$app eval {
                list [catch {::typed::values::present_at {first second} 0} message opts] \
                    [dict getdef $opts -errorcode {}]
            }]
            equal $answer {1 {TCL VALUE INDEX}} "invalid dynamic index $value still reaches lindex"
        }
    } finally {$app eval {trace remove execution ::typed::values::index_hook enter $callback}}
    $app eval {trace add execution ::lindex enter ::failElement}
    try {
        equal [$app eval {
            list [catch {::typed::values::present_at {witness values} 0} message opts] \
                [dict getdef $opts -errorcode {}]
        }] {1 {TEST ELEMENT}} "discarded capture preserves the selected element fault"
        equal [$app eval {::typed::values::present_at {witness values} 99}] 0 "absent index skips the element read"
    } finally {$app eval {trace remove execution ::lindex enter ::failElement}}
}

proc ::listsTest::matchDestination {app} {
    $app eval [list set ::unusedLocal [::appcompiler::emitLocalName unused]]
    $app eval {
        proc ::watchDestination {cmd op} {
            uplevel 1 [list trace add variable $::unusedLocal {read write} ::noticeDestination]
        }
        proc ::noticeDestination {name element op} {
            if {$op eq "read"} {error "the program never reads this binding"}
            upvar 1 $name value
            lappend ::writes $value
        }
        trace add execution ::typed::values::index_hook enter ::watchDestination
    }
    try {
        $app eval {set ::writes {}}
        foreach value {{some 8} none} {
            equal [$app eval [list ::typed::values::assign_only $value]] 42 \
                "discarded match assignment does not read its destination"
        }
        equal [$app eval {set ::writes}] {8 19} "each selected arm writes the destination once"
    } finally {$app eval {trace remove execution ::typed::values::index_hook enter ::watchDestination}}
}

proc ::listsTest::direct {} {
    variable source
    set modules [dict create values $source]
    equal [::appcompiler::check $modules] {} "list program checks"
    set app [interp create]
    try {
        $app eval [dict get [::appcompiler::compile $modules ::typed] script]
        $app eval {namespace path ::typed::values; set ::events {}; proc ::observe {v} {lappend ::events $v; return $v}}
        equal [$app eval {flags {  true  {false}  1  0  }}] {1 0 1 0} "public boolean lists have canonical values"
        equal [$app eval {matrix {{true false} {} {0 1}}}] {{1 0} {} {0 1}} "nested boolean lists use the same admission"
        foreach {bad path} {{true 1 TRUE} {$bits.2} {{false} {1 01}} {$bits.1.1}} cmd {flags matrix} {
            if {![catch {$app eval [list $cmd $bad]} message options]} {error "accepted invalid boolean list"}
            equal [list $message [dict get $options -errorcode]] \
                [list "expected bool at $path" {APPCOMPILER ARGUMENT TYPE}] "first invalid boolean position"
        }
        interp alias $app ::jsonValue {} ::machteld::json
        foreach prefix {0 1 false true} {
            set wire [format {"%s\u0000tail"} $prefix]
            set raw [$app eval [list jsonValue unwrap [::machteld::json decode -typed $wire]]]
            foreach arg [list $raw [list $raw]] {
                if {![catch {$app eval [list flags $arg]} msg opts]} {error "accepted text after a boolean prefix"}
                equal [list $msg [dict get $opts -errorcode]] \
                    {{expected bool at $bits.0} {APPCOMPILER ARGUMENT TYPE}} "a native NUL is part of the boolean spelling"
            }
        }
        equal [$app eval {
            set root [jsonValue decode -typed 1]
            set child [jsonValue decode -typed false]
            set bad [jsonValue decode -typed 2]
            set first [flags $root]
            set second [flags [list $child]]
            catch {flags [list $bad]}
            list $first $second [jsonValue type $root] [jsonValue type $child] [jsonValue type $bad]
        }] {1 0 number boolean number} "boolean list admission preserves callers' JSON handles"
        foreach wire {17 true {"雪"} {[1,null]} {{"x":"a\u0000b"}}} {
            set retained [$app eval [list apply {{wire} {
                set node [jsonValue decode -typed $wire]
                set count [name_size $node]
                list $count [jsonValue encode -- $node]
            }} $wire]]
            equal $retained [list [string length $wire] $wire] "text length preserves the borrowed JSON handle"
        }
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
            if {[lindex $words 0] eq "::linsert" && [lindex $words 2] eq "end"} {incr ::updates}
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
        equal [$app eval {required_value text {{} 007} 0}] {ok {}} "propagated lookup preserves a present empty string"
        equal [$app eval {required_value text {{} 007} 1}] {ok 007} "propagated lookup preserves integer-looking text"
        equal [$app eval {required_value int? {none} 0}] {ok none} "lookup propagates exactly one result layer"
        set originLine {    ok(require_index($values, $i)?)}
        set expectedOrigin [dict create module values line [expr {1+[lsearch -exact [split $::listsTest::source \n] $originLine]}] \
            column [expr {1+[string first ? $originLine]}]]
        foreach index [list -1 2 [string repeat 9 100] -[string repeat 9 100]] {
            lassign [$app eval [list required_value text {{} 007} $index]] tag failure
            equal [list $tag [dict get $failure code] [dict get $failure message] [dict get $failure origin]] \
                [list err INDEX_OUT_OF_RANGE "index $index is outside a list of length 2" $expectedOrigin] "checked lookup keeps the entire bounds failure"
        }
        $app eval {set ::events {}}
        equal [$app eval {required_effects {first}}] {ok base} "computed indices retain their value"
        equal [$app eval {set ::events}] {base x} "computed operands run once in source order"
        watchedReads $app watched
        watchedReads $app watched_bound
        discardedIndex $app
        matchDestination $app
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
        equal [regexp -line {^::set (v_[0-9a-f]+) \[::linsert \$\1 end } [$app eval {info body ::typed::values::@collect}]] 1 "collector evaluates its base before the item"
        equal [$app eval {match_history {{some 4} none {some 8}}}] {10 {10 4} {10 4} {10 4 8}} "each retained list keeps its value across match updates"
        equal [$app eval {match_other {some {2 3}}}] {2 3 7} "a captured base takes its own value"
        equal [$app eval {match_argument {some 7}}] {1 {1 7} 1} "match in an expression leaves its source local unchanged"
        set key "key\u0000tail"
        $app eval {set ::events {}}
        set pair [$app eval [list match_put {some 8} $key 2]]
        equal [lindex $pair 0] ok "map update succeeds"
        equal [lindex $pair 1] [list {seed 1} [dict create seed 1 $key 4]] "retained map and normalized key survive a match update"
        equal [$app eval {set ::events}] [list $key] "reached key evaluates once"
        $app eval {set ::events {}}
        set failed [$app eval [list match_put {some 8} $key 0]]
        equal [dict get [lindex $failed 1] code] DIVIDE_BY_ZERO "failed element propagates before storing the result"
        equal [$app eval {set ::events}] [list $key] "key is evaluated before the failing map value"
        $app eval {set ::events {}}
        equal [$app eval [list match_put none $key 0]] {ok {{seed 1} {seed 1}}} "unselected arm skips the fallible value"
        equal [$app eval {set ::events}] {} "unselected arm skips the key"
        equal [regexp {::set (v_[0-9a-f]+) \[::linsert \$\1 end \[::lindex \$m_} [$app eval {info body ::typed::values::match_history}]] 1 "match assignment uses the captured list value"
        equal [regexp {::set (v_[0-9a-f]+) \[::dict replace \$\1 } [$app eval {info body ::typed::values::match_put}]] 1 "match assignment reads the map before the key"
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
