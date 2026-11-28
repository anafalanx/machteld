package require machteld
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

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

proc ::mapTest::wireEqual {result expected label} {
    lassign $result tag actual
    equal $tag ok "$label succeeds"
    set encoded [::machteld::json encode -- [::machteld::json decode -typed $actual]]
    set reference [::machteld::json encode -- [::machteld::json decode -typed $expected]]
    equal $encoded $reference "$label preserves JSON member names, order and values"
}
# A text key is a value at the Tcl boundary. Its spelling can be projected
# without losing a retained native handle or exposing that handle as a key.
proc ::mapTest::keyOwnership {} {
    set source {export fn .put($key:text) -> map<text,int> => map_put(map<text,int>(), $key, 42)}
    set program [::appcompiler::compile [dict create keytest $source] ::checkedKeys]
    set app [interp create]
    try {
        # Exercise the portable host first, and the optional native capability
        # through an interpreter alias if the current runtime supplies it.
        set modes {portable}
        if {[llength [info commands ::machteld::x::mapTextKey]]} {lappend modes native}
        foreach mode $modes {
            if {$mode eq "native"} {
                $app eval {namespace eval ::machteld::x {namespace export mapTextKey}}
                $app alias ::machteld::x::mapTextKey ::machteld::x::mapTextKey
            }
            $app eval [dict get $program script]
            set node [::machteld::json decode -typed 17]
            set result [$app eval [list ::checkedKeys::keytest::put $node]]
            equal [::machteld::json type $node] number "$mode retains the incoming native handle"
            equal [dict get $result 17] 42 "$mode projects the key spelling"
            equal [catch {::machteld::json type [lindex [dict keys $result] 0]}] 1 "$mode produces an ordinary text key"
        }
    } finally {interp delete $app}
}
proc ::mapTest::counterUpdates {} {
    set counter {export fn .count($seed: map<text,int>, $keys: list<text>, $other: text) -> list<map<text,int>> {
    $out := $seed
    for $k in $keys {
        $n ::= match $out[$k] { none => 0
            some($old) => $old }
        $out = map_put($out, $k, $n + 3)
    }
    return [$seed, $out]
}}
    set src {extern fn .tap($key: text) -> text = ['::tap']}
    foreach {fn replacements} {
        count {}
        large {{+ 3} {+ 9999999999999999999999999999999999}}
        zero {{+ 3} {+ 0}}
        otherkey {{map_put($out, $k} {map_put($out, $other}}
        nonzero {{none => 0} {none => 7}}
        effect {{[$k]} {[.tap($k)]} {map_put($out, $k} {map_put($out, .tap($k)}}
        decimal {{map<text,int>} {map<text,decimal>} {none => 0} {none => 0.0}}
        observed {{, $n + 3)} {, $n + 3)
        if $n == 0 { $out = map_put($out, $other, 19) }}}
    } {
        append src \n [string map [list .count .$fn {*}$replacements] $counter]
    }
    set app [interp create]
    try {
        $app eval {proc ::tap {k} {lappend ::events $k; return $k}}
        $app eval [dict get [::appcompiler::compile [dict create counters $src] ::counters] script]
        set ns ::counters::counters
        set huge [string repeat 9 150]
        set key "x\u0000雪"
        set seed [dict create $key $huge]
        set result [$app eval [list ${ns}::count $seed [list 007 $key 7 007 {}] outside]]
        equal [lindex $result 0] $seed "prior dictionary stays intact"
        equal [lindex $result 1] [dict create $key [expr {$huge + 3}] 007 6 7 3 {} 3] "increment preserves bignums, spelling and insertion order"
        equal [lindex [$app eval [list ${ns}::large {a 1} a b]] 1] {a 10000000000000000000000000000000000} "arbitrary-precision literal increment"
        equal [lindex [$app eval [list ${ns}::zero {} a b]] 1] {a 0} "an absent key still gets inserted with a zero increment"
        equal [lindex [$app eval [list ${ns}::otherkey {} a b]] 1] {b 3} "different read and write keys"
        equal [lindex [$app eval [list ${ns}::nonzero {} a b]] 1] {a 10} "nonzero initial count"
        equal [lindex [$app eval [list ${ns}::observed {} a b]] 1] {a 3 b 19} "later statement observes the prior count"
        equal [lindex [$app eval [list ${ns}::decimal {a 0.5} a b]] 1] {a 3.5} "decimal counters retain their precision"
        $app eval [list ${ns}::effect {} {a b} z]
        equal [$app eval {set ::events}] {a a b b} "both effectful key expressions evaluate every iteration"
    } finally {interp delete $app}
}
proc ::mapTest::counterTraces {} {
    set source {extern fn .hook() -> unit = ['::hook']
export fn .count($words:list<text>) -> map<text,int> {
    $out := map<text,int>()
    for $key in $words {
        .hook()
        $n ::= match $out[$key] { some($old) => $old
            none => 0 }
        $out = map_put($out, $key, $n + 1)
    }
    return $out
}}
    set pure [string map [list "        .hook()\n" {}] $source]
    set app [interp create]
    try {
        set modules [dict create callback $source pure $pure]
        $app eval [dict get [::appcompiler::compile $modules ::counterTraces] script]
        $app eval [list set ::keyLocal [::appcompiler::emitLocalName key]]
        $app eval [list set ::outLocal [::appcompiler::emitLocalName out]]
        $app eval [list set ::countLocal [::appcompiler::emitLocalName n]]
        $app eval {
            proc ::hook {} {}
            proc ::alternate {name index op} {
                upvar 1 $name key
                set key [expr {[incr ::reads] % 2 ? "read" : "written"}]
            }
            proc ::badCount {name index op} {upvar 1 $name out; set out {a nope}}
            proc ::setCount {name index op} {upvar 1 $name n; set n 41}
            proc ::install {cmd op} {
                if {[incr ::calls] == 2} {
                    uplevel 1 [list trace add variable $::watch $::operation $::action]
                }
            }
            proc ::invokePure {} {::counterTraces::pure::count a}
            proc ::observeStep {cmd op} {
                # The count's right-hand side has already looked up the first key.
                # Inspect the command words without reading the observed variable.
                if {[lindex $cmd 0] eq "::set" && [llength $cmd] == 3 &&
                    [lindex $cmd 1] eq $::countLocal && [incr ::calls] == 1} {
                    uplevel 1 [list trace add variable $::keyLocal read ::alternate]
                }
            }
        }
        set hook ::counterTraces::callback::hook
        $app eval [list trace add execution $hook enter ::install]
        try {
            $app eval {set ::calls 0; set ::reads 0; set ::operation read; set ::watch $::keyLocal; set ::action ::alternate}
            equal [$app eval {::counterTraces::callback::count {a a}}] {a 1 written 1} \
                "Tcl callback can change the key between the lookup and the update"
            equal [$app eval {set ::reads}] 2 "both source key reads are observable"
            $app eval {set ::calls 0; set ::watch $::outLocal; set ::action ::badCount}
            set status [catch {$app eval {::counterTraces::callback::count {a a}}} message options]
            equal $status 1 "the source addition rejects an invalid count"
            equal [dict get $options -errorcode] {ARITH DOMAIN {non-numeric string}} "arithmetic failure category"
            set site [$app eval [list ::counterTraces::@rt::mappedLocation $options \
                [$app eval {::counterTraces::@rt::sourceMap}]]]
            equal $site {module callback line 8 column 9} "arithmetic failure maps to the update"
            $app eval {set ::calls 0; set ::watch $::countLocal; set ::operation write; set ::action ::setCount}
            equal [$app eval {::counterTraces::callback::count {a a}}] {a 42} \
                "the intermediate count binding is written before addition"
        } finally {$app eval [list trace remove execution $hook enter ::install]}

        # An enclosing Tcl caller can begin observing after the key was first
        # evaluated, even when the X loop itself calls no application code.
        $app eval {set ::calls 0; set ::reads 0; trace add execution ::invokePure enterstep ::observeStep}
        try {
            equal [$app eval ::invokePure] {read 1} "the later key read can affect a pure loop"
            equal [$app eval {set ::reads}] 1 "only the remaining source read fires the new trace"
        } finally {$app eval {trace remove execution ::invokePure enterstep ::observeStep}}
    } finally {interp delete $app}
}

proc ::mapTest::crossOrigin {app} {
    set wire {{"data":{"a":"prefix","a\u0000b\\\"\ud83d\ude80z":"old","ab\\\"\ud83d\ude80z":"neighbor","tail":"last"}}}
    set localKey "a\u0000b\\\"\U0001F680z"
    set neighbor "ab\\\"\U0001F680z"
    set original [dict create a prefix $localKey old $neighbor neighbor tail last]
    set node [::machteld::json get [::machteld::json decode -typed $wire] data]
    set nativeKey [lindex [dict keys [::machteld::json unwrap $node]] 1]
    equal [binary encode hex [encoding convertto utf-8 $nativeKey]] \
        [binary encode hex [encoding convertto utf-8 $localKey]] "native and Tcl fixture keys denote identical Unicode"
    lassign [invoke $app read_map $wire] tag decoded
    equal $tag ok "read a map containing an embedded NUL key"
    equal [invoke $app wire_equal $wire $original] {ok 1} "decoded and constructed maps have equal keys and values"
    equal [invoke $app wire_equal $wire [dict replace $original $neighbor different]] {ok 0} \
        "adjacent lookalike key still has an independent value"

    set keys [lmap k [dict keys $original] {binary encode hex [encoding convertto utf-8 $k]}]
    foreach {from map lookup} [list decoded $decoded $localKey constructed $original $nativeKey] {
        equal [invoke $app text_at $map $lookup] {some old} "$from optional lookup accepts the other key origin"
        equal [invoke $app fetch $map $lookup] {ok old} "$from required lookup accepts the other key origin"
        foreach fn {replace_text local_replace_text} {
            set changed [invoke $app $fn $map $lookup new]
            set actual [lmap k [dict keys $changed] {binary encode hex [encoding convertto utf-8 $k]}]
            equal $actual $keys "$from $fn replaces one key in its original position"
            equal [invoke $app fetch $changed $localKey] {ok new} "$from $fn updates the NUL key"
            equal [invoke $app fetch $changed $neighbor] {ok neighbor} "$from $fn preserves the nearby key"
        }
    }

    set mixed [dict create $nativeKey first $localKey second]
    if {[dict size $mixed] == 2} {
        # Older bindings expose two physical dictionary keys for the same text.
        badBoundary $app text_keys $mixed
    } else {
        equal [llength [invoke $app text_keys $mixed]] 1 "host has already coalesced both representations"
        equal [invoke $app fetch $mixed $localKey] {ok second} "host replacement retains the last value"
    }
    wireEqual [invoke $app write_map [dict create data $original]] $wire "encode a Tcl-constructed Unicode key"
    wireEqual [invoke $app roundtrip_map $wire] $wire "decode and encode the original JSON"
    set surrounding [format {{"before":"literal \\u0000 and \"quotes\"","data":%s,"after":{"\ud83d\ude80":"old"}}} \
        [::machteld::json encode -- $node]]
    wireEqual [invoke $app roundtrip_map $surrounding] $surrounding "adjacent parent fields survive the key round trip"
    set replaced [invoke $app local_replace_text $decoded $localKey new]
    wireEqual [invoke $app write_map [dict create data $replaced]] \
        [string map [list {"old"} {"new"}] $wire] "encode the replacement after cross-origin lookup"
    set bytes [encoding convertto -profile strict utf-8 {{"data":{"雪":"before\u0000after"}}}]
    foreach call {first second} {
        equal [invoke $app read_map $bytes] [list ok [dict create 雪 "before\u0000after"]] \
            "$call decode preserves UTF-8 input bytes, key and embedded text NUL"
    }
}

# Model a binding that truncates a string or object key when it crosses into
# Tcl. Its native typed JSON still retains the complete original wire value.
proc ::mapTest::lossyJson {op args} {
    set result [::machteld::json $op {*}$args]
    if {$op ne "unwrap"} {return $result}
    switch -- [::machteld::json type [lindex $args 0]] {
        string {return [lindex [split $result \u0000] 0]}
        object {
            set shortened {}
            dict for {key value} $result {dict set shortened [lindex [split $key \u0000] 0] $value}
            return $shortened
        }
        default {return $result}
    }
}
proc ::mapTest::legacyJson {script} {
    set app [interp create]
    try {
        $app alias ::machteld::json ::mapTest::lossyJson
        $app eval $script
        equal [invoke $app read_map {{"data":{"normal":"雪"}}}] [list ok [dict create normal 雪]] \
            "ordinary strings work through the legacy JSON compatibility path"
        foreach {wire message} {
            {{"data":{"item":"a\u0000b"}}} {value.data[item] cannot be preserved as text by this runtime}
            {{"data":{"part":"first","part\u0000rest":"second"}}} {object keys cannot be preserved by this JSON runtime}
        } {
            lassign [invoke $app read_map $wire] tag problem
            equal [list $tag [dict get $problem code] [dict get $problem message]] \
                [list err JSON_SCHEMA $message] "legacy conversion detects a lossy read"
        }
    } finally {interp delete $app}
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
    append model \n {export record .bag { data: map<text,text> }
export fn .read_map($wire: text) -> result<map<text,text>,problem> {
    $bag ::= decode_json<.bag>($wire)?
    return ok($bag.data)
}
export fn .write_map($bag: .bag) -> result<text,problem> { return encode_json($bag) }
export fn .roundtrip_map($wire: text) -> result<text,problem> {
    $bag ::= decode_json<.bag>($wire)?
    return encode_json($bag)
}
export fn .wire_equal($wire: text, $constructed: map<text,text>) -> result<bool,problem> {
    $bag ::= decode_json<.bag>($wire)?
    return ok($bag.data == $constructed)
}
export fn .replace_text($m: map<text,text>, $key: text, $value: text) -> map<text,text> {
    return map_put($m, $key, $value)
}
export fn .local_replace_text($m: map<text,text>, $key: text, $value: text) -> map<text,text> {
    $out := $m
    $out = map_put($out, $key, $value)
    return $out
}}
    set sources [dict create maps $model]
    equal [::appcompiler::check $sources] {} "map source checks"
    diagnostics
    counterUpdates
    counterTraces
    keyOwnership
    set compiled [::appcompiler::compile $sources ::mapApp]
    set app [interp create]
    try {
        $app alias ::machteld::json ::machteld::json
        $app eval [dict get $compiled script]
        exercise $app $model
        crossOrigin $app
    } finally {interp delete $app}
    legacyJson [dict get $compiled script]
    puts "application compiler map: $count assertions passed"
}
