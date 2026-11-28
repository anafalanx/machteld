package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::orderedTest {
    variable checks 0
    variable source {distinct .code = text
distinct .distance = decimal
distinct .gain = binary64
distinct .stamp = instant
record .row { code: text }
export fn .text($a: text, $b: text) -> list<bool>=>[$a < $b,$a <= $b,$a > $b,$a >= $b]
export fn .ints($a: int, $b: int) -> list<bool> => [$a < $b,$a <= $b,$a > $b,$a >= $b]
fn .int_equality($a: int, $b: int) -> list<bool> => [$a == $b, $a != $b]
export fn .dec($a: decimal, $b: decimal) -> list<bool> => [$a < $b,$a <= $b,$a > $b,$a >= $b]
export fn .mixed($a: decimal, $b: int) -> bool => $a >= $b && $b < $a
export fn .codes($a: .code, $b: .code) -> bool => $a < $b
export fn .distances($a: .distance, $b: .distance) -> bool => $a > $b
export fn .gains($a: .gain, $b: .gain) -> bool => $a > $b
export fn .floating($a: binary64, $b: binary64) -> list<bool> => [$a < $b,$a <= $b,$a > $b,$a >= $b]
export fn .stamps($a: .stamp, $b: .stamp) -> bool => $a < $b
export fn .local($a: local_datetime, $b: local_datetime) -> bool => $a <= $b
export fn .in_period($at: instant, $start: instant, $stop: instant) -> bool =>
    $start <= $at && $at < $stop
export fn .fall_back($text: text) -> result<bool,problem> =>
    ok(match resolve_zone(parse_local_datetime($text)?, 'Europe/Brussels')? {
        [$first,$second] => $first < $second
        _ => false
    })
export fn .json_before($json: text, $b: text) -> result<bool,problem> =>
    ok(decode_json<.row>($json)?.code < $b)
export fn .precedence($x: int) -> bool =>
    false || !false && $x + 1 * 2 < 8 == (true && !!true)
example .precedence(5) => true
example .precedence(6) => false
export fn .range_len() -> int {
    $n := 0
    for $x in 1 + 1 ..= 3 * 2 {
        if $x > -2 && -$x <= -3 { $n = $n + 1 }
    }
    return $n
}
export extern fn .list($v: text)->list<text>=['::list']
export fn .id<.t>($x: .t)->.t=>$x
export fn .tight($x: int) -> bool => .id<int>($x)>=2
export fn .tight_list($s: text)->list<list<text>>=>[.list($s)]
extern fn .log($tag: text, $v: bool) -> bool = ['::orderSeen']
extern fn .tick($v: int) -> int = ['::orderTick']
extern fn .raise() -> bool = ['::orderRaise']
export fn .skip_fault($left: bool) -> bool => $left || .raise()
export fn .lazy($first: bool, $second: bool) -> bool =>
    .log('A',$first) || .log('B',$second) && .log('C',true)
export fn .once() -> bool => .tick(1) < .tick(2)
export fn .integer_branches($x:int) -> int {
    $index := 0
    while .tick($index) < .tick(2) {
        if .tick($x) == .tick($index) {return $index}
        $index = $index+1
    }
    return -1
}
fn .fail() -> result<bool,problem> => err(problem('expected flag'))
export fn .and_error($v: bool) -> result<bool,problem> => ok($v && .fail()?)
export fn .or_error($v: bool) -> result<bool,problem> => ok($v || .fail()?)
fn .branch($go: bool) -> int {
    if $go && 'PAYLOAD' == 'PAYLOAD' && .log('branch', true) { return 1 }
    else { return 2 }
}
export fn .hostile($go: bool) -> bool => $go && match ['PAYLOAD'] {
    [$v] => $v >= 'PAYLOAD'
    _ => false
}
fn .main($args: list<text>) -> result<unit,problem> {
    if .codes(make<.code>('007'), make<.code>('7')) && !.and_error(false)? {
        return write_stdout_utf8('ordered')
    }
    return err(problem('condition failed'))
}}
    set source [string map [list PAYLOAD [format {a%c [orderWitness] $v; " \\ %c} 125 10]] $source]
}

proc ::orderedTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::orderedTest::bad {source code {mark {}}} {
    set diagnostics [::appcompiler::check [dict create entry $source]]
    equal [lmap item $diagnostics {dict get $item code}] $code "diagnostics for $source"
    if {$mark ne ""} {
        set node [dict get [lindex $diagnostics 0] node]
        set row [lindex [split $source \n] [expr {[dict get $node line] - 1}]]
        equal [string range $row [expr {[dict get $node column]-1}] [expr {[dict get $node endColumn]-2}]] $mark "offending source token"
    }
}

proc ::orderedTest::direct {} {
    variable source
    set compiled [::appcompiler::compile [dict create entry $source] ::ordered]
    namespace eval :: [dict get $compiled script]
    set huge [string repeat 9 140]
    set larger 1[string repeat 0 140]
    set tiny 0.[string repeat 0 140]1
    set prefix [string repeat 0 140]
    equal [string first {::@rt::equal} [info body ::ordered::entry::int_equality]] -1 \
        "checked integer equality and inequality avoid general type dispatch"
    foreach {fn left right expected} [list \
        ints $huge $larger {1 1 0 0} ints -$huge -$larger {0 0 1 1} ints +00009 9 {0 1 0 1} \
        dec $huge.${prefix}1 $huge.${prefix}2 {1 1 0 0} dec -$tiny 0 {1 1 0 0} dec -1.10002 -1.10001 {1 1 0 0} \
        dec 2.000000000 ${prefix}2 {0 1 0 1} dec -$larger -$huge.9 {1 1 0 0} dec -0.00 +0 {0 1 0 1} \
        text 007 7 {1 1 0 0} text 19 2 {1 1 0 0} text 7 007 {0 0 1 1} text A a {1 1 0 0} \
        text {} {} {0 1 0 1} text "a\u0000b" "a\u0000c" {1 1 0 0} text e\u0301 \u00e9 {1 1 0 0} \
        text \uE000 \U00010000 {1 1 0 0}] {
        equal [::ordered::entry::$fn $left $right] $expected "$fn order of [list $left $right]"
    }
    equal [::ordered::entry::mixed ${huge}.00001 $huge] 1 "int compared against exact decimal"
    equal [::ordered::entry::codes 007 7] 1 "distinct text preserves spelling"
    equal [::ordered::entry::distances 1.001 1.0009] 1 "distinct exact decimal"
    equal [::ordered::entry::gains 1.0000000000000002 1.0] 1 "adjacent distinct binary64 values"
    equal [::ordered::entry::floating 5e-324 0] {0 0 1 1} "smallest positive subnormal exceeds zero"
    equal [::ordered::entry::floating -0.0 0] {0 1 0 1} "canonical binary64 zero"
    equal [::ordered::entry::stamps 2026-10-25T00:30:00.000000001Z 2026-10-25T00:30:00.000000002Z] 1 "adjacent nanoseconds"
    set lo 2026-10-25T00:30:00.000000000Z
    set hi 2026-10-25T00:30:00.000000001Z
    equal [::ordered::entry::in_period $lo $lo $hi] 1 "lower interval endpoint included"
    equal [::ordered::entry::in_period $hi $lo $hi] 0 "upper interval endpoint excluded"
    equal [::ordered::entry::local 2026-10-25T02:30:00 2026-10-25T02:30:00] 1 "same local reading"
    equal [::ordered::entry::local 2026-10-25T02:30:00 2026-10-25T02:30:00.000000001] 1 "local reading just after a whole second"
    equal [::ordered::entry::fall_back 2026-10-25T02:30:00] {ok 1} "both instants from a repeated Brussels hour ordered"
    equal [::ordered::entry::fall_back 2026-03-29T02:30:00] {ok 0} "skipped Brussels hour"
    equal [::ordered::entry::json_before {{"code":"007"}} 7] {ok 1} "JSON string identifier"
    equal [::ordered::entry::json_before {{"code":"a\u0000b"}} "a\u0000b"] {ok 0} "equal JSON and Tcl NUL strings"
    equal [::ordered::entry::json_before {{"code":"a\u0000b"}} "a\u0000c"] {ok 1} "JSON and Tcl NUL strings sort ordinally"
    equal [::ordered::entry::precedence 5] 1 "default logical and arithmetic binding"
    equal [::ordered::entry::precedence 6] 0 "arithmetic before ordering before equality"
    equal [::ordered::entry::range_len] 4 "unary minus and range precedence"
    equal [::ordered::entry::tight 2] 1 "tight generic and comparison spellings"
    equal [::ordered::entry::tight_list 007] 007 "tight nested type arrow and extern equals"
    set ::orderHistory {}
    set ::orderWitnessCalls 0
    proc ::orderWitness {} {incr ::orderWitnessCalls}
    proc ::orderSeen {tag value} {lappend ::orderHistory $tag; return $value}
    proc ::orderTick {value} {lappend ::orderHistory $value; return $value}
    set ::orderHistory {}
    equal [::ordered::entry::integer_branches 1] 1 "matched integer branch"
    equal $::orderHistory {0 2 1 0 1 2 1 1} "if and while read the reached operands once and in order"
    proc ::orderRaise {} {lappend ::orderHistory fault; error {observed failure}}
    foreach {a b answer history} {true false 1 A false false 0 {A B} false true 1 {A B C}} {
        set ::orderHistory {}
        equal [::ordered::entry::lazy $a $b] $answer "boolean result"
        equal $::orderHistory $history "only reached arguments run once, left to right"
    }
    set ::orderHistory {}
    equal [::ordered::entry::once] 1 "ordered comparison"
    equal $::orderHistory {1 2} "ordered operands run once left to right"
    set ::orderHistory {}
    equal [::ordered::entry::skip_fault 1] 1 "true OR skips a foreign programming fault"
    equal [catch {::ordered::entry::skip_fault 0}] 1 "false OR reaches the foreign fault"
    equal $::orderHistory fault "only the reached foreign call ran"
    foreach {fn skip answer} {and_error 0 0 or_error 1 1} {
        equal [::ordered::entry::$fn $skip] [list ok $answer] "skipped error does not propagate"
        lassign [::ordered::entry::$fn [expr {!$skip}]] tag problem
        equal [list $tag [dict get $problem message]] {err {expected flag}} "reached error propagates"
        equal [dict get $problem origin module] entry "error retains application source location"
    }
    equal [::ordered::entry::hostile 1] 1 "unbalanced brace, bracket, backslash and newline are safe inside lazy branch"
    equal [::ordered::entry::hostile 0] 0 "hostile literal safe in skipped branch"
    set ::orderHistory {}
    equal [::ordered::entry::branch 0] 2 "a false if condition skips the right operand"
    equal $::orderHistory {} "no calls on the untaken side of a condition"
    equal [::ordered::entry::branch 1] 1 "a braced if condition preserves literal text"
    equal $::orderHistory branch "a reached operand runs exactly once"
    equal [string first "::if \{" [info body ::ordered::entry::branch]] 0 "Tcl can compile the if expression as a literal"
    equal $::orderWitnessCalls 0 "literal brackets never execute"
    equal [catch {::ordered::entry::lazy 2 true}] 1 "external boolean requires a valid bool"
    equal [catch {::ordered::entry::ints 1 0x10}] 1 "external ints use decimal input"
    equal [catch {::ordered::entry::dec 1e7 0}] 1 "external decimal requires fixed-point spelling"

    bad {fn .a() -> bool => 4 < '4'} OPERAND_TYPE <
    bad {fn .a() -> bool => '1' >= 1} OPERAND_TYPE >=
    bad {fn .a() -> bool => false && 3} OPERAND_TYPE 3
    bad {fn .a() -> bool => 'yes' || true} OPERAND_TYPE {'yes'}
    bad {fn .a() -> bool => !7} OPERAND_TYPE 7
    bad {fn .a() -> bool => true < false} NOT_ORDERED <
    bad {fn .a() -> bool => 1 < 2 < 3} OPERAND_TYPE <
    bad {fn .a($v: bytes) -> bool => $v >= $v} NOT_ORDERED >=
    bad {fn .a($v: int?) -> bool => $v > $v} NOT_ORDERED >
    bad {fn .a($v: int, $t: instant) -> bool => $v < $t} OPERAND_TYPE <
    bad {fn .a($v: binary64) -> bool => $v <= 1.0} OPERAND_TYPE <=
    bad {distinct .gain = binary64
fn .a($v: binary64, $gain: .gain) -> bool => $v < $gain} OPERAND_TYPE <
    bad {fn .a($v: instant, $t: local_datetime) -> bool => $v < $t} OPERAND_TYPE <
    bad {distinct .code = text
fn .a($c: .code) -> bool => $c < '99'} OPERAND_TYPE <
    bad {distinct .a = int
distinct .b = int
fn .test($a: .a, $b: .b) -> bool => $a >= $b} OPERAND_TYPE >=
    bad {distinct .flag = bool
fn .test($a: .flag) -> bool => $a >= $a} NOT_ORDERED >=
    bad {fn .a($x: int) -> int => $x
fn .b() -> bool => .a == .a} NOT_COMPARABLE ==
    bad {fn .id<.t>($x: .t) -> .t => $x
fn .b() -> bool => .id<int>==.id<int>} NOT_COMPARABLE ==
}

proc ::orderedTest::packed {} {
    variable source
    set tmp [file normalize [file tempdir]]
    try {
        set project [file join $tmp project]
        set manifest [file join $project project.dict]
        ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {entry main} modules {entry condition.src}}
        ::appcompiler::project::stageBytes [file join $project condition.src] [encoding convertto utf-8 $source]
        set report [::appcompiler::project::test $manifest]
        equal [dict get $report passed] 2 "source examples"
        set archive [file join $tmp conditions.machteld]
        ::appcompiler::project::pack $manifest $archive
        file rename -- $project [file join $tmp retired]
        set rebuilt [file join $tmp rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        foreach app [list $archive $rebuilt] {
            set run [::machteld::run -dir $tmp -timeout 30s -- [info nameofexecutable] $app]
            equal [dict get $run exit] 0 "packed condition: [dict get $run err]"
            equal [dict get $run out] ordered "generated condition and propagation"
        }
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::orderedTest::direct
if {$argv eq "-pack"} {::orderedTest::packed}
puts "application compiler ordered conditions: $::orderedTest::checks assertions passed"
