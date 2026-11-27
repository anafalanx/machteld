package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::mapTest {variable count 0}
proc ::mapTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::mapTest::invoke {app function args} {
    $app eval [list ::mapApp::maps::$function {*}$args]
}
proc ::mapTest::badBoundary {app fn args} {
    set status [catch {invoke $app $fn {*}$args} msg opts]
    equal $status 1 "Tcl boundary rejects invalid input for $fn"
    equal [dict get $opts -errorcode] {APPCOMPILER ARGUMENT TYPE} "structured binding error for $fn"
}

proc ::mapTest::exercise {app model} {
    set made [invoke $app made]
    equal [dict keys $made] {z 007 7 {}} "updating the first key retains its insertion position"
    equal $made [dict create z 5 007 2 7 3 {} 4] "empty and differently spelled numeric-looking text keys"
    equal [invoke $app digits $made] {ok 5234} "for visits map keys in insertion order"
    equal [invoke $app digits {}] {ok 0} "empty map has no iterations"
    set changed [invoke $app put $made 007 8]
    equal [dict keys $changed] [dict keys $made] "replacing a middle key preserves insertion order"
    equal [invoke $app digits $changed] {ok 5834} "replaced value is visible in the returned map"
    equal [invoke $app digits $made] {ok 5234} "persistent update preserves the caller's original map"
    set extended [invoke $app put $changed new 9]
    equal [dict keys $extended] {z 007 7 {} new} "new key appends after existing keys"
    equal [dict exists $changed new] 0 "insertion preserves the previous map"
    set seed [dict create a 1 b 4]
    equal [invoke $app edit_alias $seed] [list ok [dict create a 4 b 9 old_a 1 old_b 4]] \
        "self-update reads its old value and keeps a fixed binding to the previous map"
    equal $seed [dict create a 1 b 4] "several mutable self-updates preserve the caller's dictionary"
    set incomplete [dict create b 7]
    lassign [invoke $app edit_alias $incomplete] tag problem
    equal [list $tag [dict get $problem code] $incomplete] {err MISSING_KEY {b 7}} \
        "failed lookup after local mutations leaves the original dictionary intact"

    set texts [dict create {} {} 007 seven 7 {}]
    foreach {key expected} [list missing none {} [list some {}] 007 {some seven} 7 [list some {}]] {
        equal [invoke $app text_at $texts $key] $expected "optional text lookup for [list $key]"
    }
    equal [invoke $app fetch $texts {}] [list ok {}] "required lookup succeeds for an empty key and value"
    lassign [invoke $app fetch $texts missing] tag problem
    equal [list $tag [dict get $problem code]] {err MISSING_KEY} "required lookup reports a typed missing key"
    set origin [dict get $problem origin]
    set where [lsearch -exact [split $model \n] {    $value ::= require_key($m, $key)?}]
    equal [list [dict get $origin module] [dict get $origin line]] [list maps [expr {$where + 1}]] \
        "propagated missing key points to the original lookup line"

    set maybe [dict create cleared none blank [list some {}]]
    equal [invoke $app maybe $maybe cleared] {ok none} "present key with absent optional payload"
    equal [invoke $app maybe $maybe blank] [list ok [list some {}]] "present key with present empty payload"
    foreach {key expected} [list missing none cleared {some none} blank [list some [list some {}]]] {
        equal [invoke $app maybe_at $maybe $key] $expected "two optional layers for [list $key]"
    }
    equal [invoke $app cleared $maybe cleared] 1 "optional lookup preserves a nested none"
    equal [invoke $app cleared $maybe missing] 0 "missing key differs from present none"
    equal [invoke $app cleared $maybe blank] 0 "present empty differs from present none"
    set nested [dict create group [dict create 007 {}]]
    equal [invoke $app nested $nested group 7] [list ok [list some {}]] "propagation and indexing compose across nested maps"
    equal [invoke $app nested $nested group 6] {ok none} "missing inner key remains an optional"
    lassign [invoke $app nested $nested other 7] tag problem
    equal [list $tag [dict get $problem code]] {err MISSING_KEY} "missing outer key propagates a typed error"

    set spellings [list 雪 7 {} a 007 A e\u0301 \u00e9 \uE000 \U00010000]
    set raw {}
    foreach key $spellings {dict set raw $key payload}
    equal [invoke $app text_keys $raw] [lsort -ascii $spellings] "text sorts by ordinal value without folding or normalization"
    set huge 9999999999999999999999999999999999999999
    set larger [expr {$huge + 1}]
    set integers [dict create $larger hi -0007 low $huge mid +002 pos -0 zero]
    equal [invoke $app int_keys $integers] [list -7 0 2 $huge $larger] "integer keys sort exactly and normalize at the boundary"
    set decimalKeys [dict create 9007199254740992.0002 b -0.0100 c 9007199254740992.0001 a 0.000 z -10.20 d]
    equal [invoke $app decimal_keys $decimalKeys] {-10.2 -0.01 0 9007199254740992.0001 9007199254740992.0002} \
        "signed decimal keys sort exactly beyond double precision"
    equal [invoke $app decimal_put [dict create +0008.900 old 2.0 other] 8.9000 new] \
        [dict create 8.9 new 2 other] "a canonical decimal update replaces the existing spelling in place"
    equal [invoke $app bool_keys [dict create true yes false no]] {0 1} "bool keys sort false before true"
    badBoundary $app int_keys [dict create 007 old 7 new]
    badBoundary $app decimal_keys [dict create -0.00 old +000.000 new]
    badBoundary $app bool_keys [dict create false old 0 new]
    badBoundary $app int_keys [list orphan]
    badBoundary $app nested [dict create group [dict create not_an_int text]] group 2

    set one [list some 1]
    set left [dict create x [list $one none] y {}]
    set right [dict create y {} x [list [list some +001] none]]
    equal [invoke $app same $left $right] 1 "map equality ignores insertion order and recurses through list and optional"
    equal [invoke $app same $left [dict replace $right x [list none $one]]] 0 "element order still matters inside list values"
    equal [invoke $app same $left [dict remove $right y]] 0 "extra empty-valued key participates in equality"
    equal [invoke $app same [dict create 7 {}] [dict create 007 {}]] 0 "map equality preserves text key spelling"
    badBoundary $app same [dict create x [list [list some -abc]]] $right
}

proc ::mapTest::diagnostics {} {
    foreach {expected source} {
        MAP_KEY_TYPE {fn .bad($m: map<list<int>,text>) -> unit { return unit }}
        TYPE_ARITY {fn .bad() -> map<text,int> { return map<text>() }}
        CALL_ARITY {fn .bad() -> map<text,int> { return map<text,int>(1) }}
        MAP_KEY_TYPE {fn .bad($m: map<int,text>) -> text? { return $m['1'] }}
        MAP_KEY_TYPE {fn .bad($m: map<text,int>) -> result<int,problem> { return require_key($m, 1) }}
        ARGUMENT_TYPE {fn .bad($m: map<int,text>) -> map<int,text> { return map_put($m, 1, true) }}
        EXPECTED_MAP {fn .bad($x: int) -> bool? { return $x['k'] }}
        EXPECTED_MAP {fn .bad($m: map<text,map<int,text>>) -> text? { return $m['k'][0] }}
        DISCARDED_RESULT {fn .bad($m: map<text,int>) -> unit {
    require_key($m, 'k')
    return unit
}}
        NOT_COMPARABLE {record .entry { issue: problem }
fn .bad($m: map<text,list<.entry>>) -> bool { return $m == $m }}
    } {
        set errors [::appcompiler::check [dict create sample $source]]
        equal [lmap d $errors {dict get $d code}] [list $expected] "map diagnostic $expected"
    }
}

namespace eval ::mapTest {
    set model {export fn .made() -> map<text,int> {
    $m := map<text,int>()
    $m = map_put($m, 'z', 1)
    $m = map_put($m, '007', 2)
    $m = map_put($m, '7', 3)
    $m = map_put($m, '', 4)
    return map_put($m, 'z', 5)
}
export fn .put($m: map<text,int>, $key: text, $v: int) -> map<text,int> { return map_put($m, $key, $v) }
export fn .edit_alias($seed: map<text,int>) -> result<map<text,int>,problem> {
    $m := $seed
    $old ::= $m
    $m = map_put($m, 'a', require_key($m, 'b')?)
    $m = map_put($m, 'b', 9)
    $m = map_put($m, 'old_a', require_key($old, 'a')?)
    $m = map_put($m, 'old_b', require_key($old, 'b')?)
    return ok($m)
}
export fn .digits($m: map<text,int>) -> result<int,problem> {
    $n := 0
    for $key in $m { $n = $n * 10 + require_key($m, $key)? }
    return ok($n)
}
export fn .text_at($m: map<text,text>, $key: text) -> text? { return $m[$key] }
export fn .fetch($m: map<text,text>, $key: text) -> result<text,problem> {
    $value ::= require_key($m, $key)?
    return ok($value)
}
export fn .maybe($m: map<text,text?>, $key: text) -> result<text?,problem> { return require_key($m, $key) }
export fn .maybe_at($m: map<text,text?>, $key: text) -> text?? { return $m[$key] }
export fn .cleared($m: map<text,text?>, $key: text) -> bool { return $m[$key] == some(none) }
export fn .nested($m: map<text,map<int,text>>, $group: text, $key: int) -> result<text?,problem> {
    return ok(require_key($m, $group)?[$key])
}
export fn .text_keys($m: map<text,text>) -> list<text> { return sorted_keys($m) }
export fn .int_keys($m: map<int,text>) -> list<int> { return sorted_keys($m) }
export fn .decimal_keys($m: map<decimal,text>) -> list<decimal> { return sorted_keys($m) }
export fn .decimal_put($m: map<decimal,text>, $k: decimal, $v: text) -> map<decimal,text> {
    return map_put($m, $k, $v)
}
export fn .bool_keys($m: map<bool,text>) -> list<bool> { return sorted_keys($m) }
export fn .same($a: map<text,list<int?>>, $b: map<text,list<int?>>) -> bool { return $a == $b }}
    set sources [dict create maps $model]
    equal [::appcompiler::check $sources] {} "map source checks"
    diagnostics
    set compiled [::appcompiler::compile $sources ::mapApp]
    set app [interp create]
    try {
        $app eval [dict get $compiled script]
        exercise $app $model
    } finally {interp delete $app}
    puts "application compiler map: $count assertions passed"
}
