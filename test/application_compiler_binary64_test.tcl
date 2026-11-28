package require machteld
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]
source -encoding utf-8 [file join $root test fixtures compiler_numeric_locale.tcl]

namespace eval ::binaryTest {
    variable checks 0
    variable source {export distinct .gain = binary64
export record .reading { value: .gain }
export fn .from_int($n: int) -> result<binary64,problem> => to_binary64($n)
export fn .from_decimal($n: decimal) -> result<binary64,problem> => to_binary64($n)
export fn .inspect($n: binary64) -> decimal => exact_decimal($n)
export fn .display($n: binary64) -> text => $"$n"
export fn .sum($x: binary64, $y: binary64) -> result<binary64,problem> => $x + $y
export fn .difference($x: binary64, $y: binary64) -> result<binary64,problem> => $x - $y
export fn .product($x: binary64, $y: binary64) -> result<binary64,problem> => $x * $y
export fn .ratio($x: binary64, $y: binary64) -> result<binary64,problem> => $x / $y
extern fn .tap($tag: text, $value: binary64) -> binary64 = ['::binaryTest::tap']
export fn .rounded($a: binary64, $b: binary64, $c: binary64, $d: binary64) -> result<binary64,problem> =>
    ok(((.tap('a', $a) * .tap('b', $b))? - (.tap('c', $c) + .tap('d', $d))?)?)
export fn .times($a: binary64, $b: binary64, $c: binary64, $d: binary64) -> result<binary64,problem> =>
    ok(((.tap('a', $a) - .tap('b', $b))? * (.tap('c', $c) * .tap('d', $d))?)?)
export fn .deeper($a: binary64, $b: binary64, $c: binary64, $d: binary64) -> result<binary64,problem> =>
    ok(((($a * $b)? - ($c * $d)?)? + (($a * $d)? - ($b * $c)?)?)?)
export fn .observed($a: binary64, $b: binary64, $c: binary64, $d: binary64) -> result<binary64,problem> {
    .tap('watch', $a)
    return ok(((($a * $b)? - ($c * $d)?)? + $a)?)
}
export fn .compared($a: binary64, $b: binary64, $c: binary64, $d: binary64) -> result<bool,problem> =>
    ok((.tap('a', $a) * .tap('b', $b))? <= (.tap('c', $c) * .tap('d', $d))?)
export fn .stored($a: binary64, $b: binary64) -> result<binary64,problem> {
    $result ::= $a * $b
    return ok($result?)
}
export fn .negate($x: binary64) -> binary64 => -$x
export fn .same($x: binary64, $y: binary64) -> bool => $x == $y
export fn .same_gain($x: .gain, $y: .gain) -> bool => $x == $y
export fn .identity<.t>($v: .t) -> .t => $v
export fn .named($x: binary64) -> .gain => make<.gain>($x)
export fn .unname($x: .gain) -> binary64 => underlying($x)
export fn .exact_sum() -> decimal => 0.1 + 0.2
export fn .exact_ratio() -> result<decimal,problem> => 1 / 3
export fn .decode($input: text) -> result<.reading,problem> => decode_json<.reading>($input)
export fn .encode($value: .reading) -> result<text,problem> => encode_json($value)
extern fn .wire_hook() -> unit = ['::binaryTest::wireHook']
export fn .observed_wire($row: .reading) -> result<text,problem> {
    .wire_hook()
    return encode_json($row)
}
export fn .sql($path: text, $query: text, $v: .gain) -> result<.reading,problem> =>
    sql_one<.reading>($path, $query, $v)
export fn .store($path: text, $v: .gain) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO readings(value) VALUES (?1)', $v)?
        return sql_commit($tx)
    }
}
export fn .fetch($path: text) -> result<.reading,problem> =>
    sql_one<.reading>($path, 'SELECT value FROM readings ORDER BY rowid DESC LIMIT 1')
export fn .late_equal($a: binary64, $b: binary64) -> bool {
    .wire_hook()
    return $a == $b
}
export fn .late_ratio($a: binary64, $b: binary64) -> result<binary64,problem> {
    .wire_hook()
    return $a / $b
}
export fn .late_nested($a: binary64, $b: binary64) -> result<binary64,problem> {
    .wire_hook()
    return ok((($a + $b)? - $a)?)
}
export fn .paired($a: binary64, $b: binary64, $c: binary64) -> result<binary64,problem> =>
    ok((.tap('a', $a) + (.tap('b', $b) * .tap('c', $c))?)?)
record .observation { raw: binary64
    correction: binary64?
}
export fn .observations($rows:list<.observation>) -> list<.observation> => $rows
}
}
proc ::binaryTest::equal {value expected why} {
    variable checks
    if {$value ne $expected} {error "$why: expected [list $expected], got [list $value]"}
    incr checks
}
proc ::binaryTest::call {name args} {::sample::numbers::$name {*}$args}
proc ::binaryTest::bits {number} {binary encode hex [binary format Q $number]}
proc ::binaryTest::sqlDenormal {database} {
    # The native and legacy Tcl admission paths must retain powers of two as
    # they cross more than one public/JSON validation boundary.
    binary scan [binary decode hex 3e60000000000000] Q power
    equal [bits [call named $power]] 3e60000000000000 "public double at a power of two"
    foreach word {7ff0000000000000 fff0000000000000 7ff8000000000001} {
        binary scan [binary decode hex $word] Q invalid
        set status [catch {call named $invalid} message options]
        equal $status 1 "reject nonfinite Tcl double $word"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "nonfinite Tcl argument diagnostic"
    }
    lassign [call encode [dict create value 2.9802322387695312e-08]] tag body
    equal [list $tag $body] [list ok {{"value":2.9802322387695312e-08}}] "JSON uses the admitted binary64 word"
    # SQLite stored the original double before enabling DAZ.
    package require cffi
    binary scan [binary decode hex 8000000000000001] Q subnormal
    equal [lindex [call store $database $subnormal] 0] ok "store negative subnormal"
    set crt [::cffi::Wrapper new ucrtbase.dll]
    try {
        $crt function _controlfp_s int {mode {uint out} setting uint mask uint}
        equal [_controlfp_s saved 0 0] 0 "read the thread's denormal mode"
        try {
            # Microsoft CRT _DN_FLUSH_OPERANDS_SAVE_RESULTS and _MCW_DN.
            equal [_controlfp_s current 0x02000000 0x03000000] 0 "enable denormals as zero"
            equal [expr {($current & 0x03000000) == 0x02000000}] 1 "denormals as zero is active"
            lassign [call fetch $database] tag row
            equal [list $tag [bits [dict get $row value]]] {ok 8000000000000001} \
                "typed SQLite REAL preserves subnormal bits under DAZ"
            foreach word {0000000000000001 8000000000000001 000fffffffffffff 800fffffffffffff} {
                binary scan [binary decode hex $word] Q pure
                set accepted [call named $pure]
                equal [bits $accepted] $word "public binary64 admission under DAZ"
                lassign [call sql $database {SELECT ?1 AS value} $pure] tag row
                equal [list $tag [bits [dict get $row value]]] [list ok $word] \
                    "typed SQLite parameter under DAZ"
                # Tcl can cache 0.0 text alongside the original subnormal
                # bits. Once present, that external spelling is authoritative.
                string cat : $pure
                equal [bits [call named $pure]] 0000000000000000 "preexisting zero spelling under DAZ"
                equal [bits $pure] $word "input keeps its numeric representation"
            }
        } finally {
            _controlfp_s restored $saved 0x03000000
        }
    } finally {
        if {[llength [info commands ::binaryTest::_controlfp_s]]} {rename ::binaryTest::_controlfp_s {}}
        $crt destroy
    }
}
proc ::binaryTest::tap {tag value} {lappend ::binaryTest::events $tag; return $value}

proc ::binaryTest::arithmeticControls {} {
    if {![llength [info commands ::machteld::x::binary64v1::add]]} {return}
    package require cffi
    set crt [cffi::Wrapper new ucrtbase.dll]
    try {
        $crt function _controlfp_s int {state {uint out} value uint mask uint}
        equal [_controlfp_s saved 0 0] 0 "read the arithmetic controls"
        try {
            # Up/down and flushing denormal operands/results have independent
            # control bits on Windows x64. A half-ULP above 1 rounds to even.
            foreach flags {0x0200 0x0100 0x01000000 0x02000000 0x03000000} {
                equal [_controlfp_s actual $flags 0x03000300] 0 "set arithmetic controls"
                set min 4.9406564584124654e-324
                equal [bits [lindex [call sum 1 1.1102230246251565e-16] 1]] 3ff0000000000000 "round midpoint to even"
                equal [bits [lindex [call rounded 1 1 1 0] 1]] 0000000000000000 "canonical propagated cancellation"
                equal [bits [call negate $min]] 8000000000000001 "negate a positive subnormal"
                equal [call same 0 $min] 0 "subnormal differs from zero"
                equal [bits [lindex [call ratio $min $min] 1]] 3ff0000000000000 "subnormal divisor remains nonzero"
                equal [dict get [lindex [call product 1.7976931348623157e308 2] 1] code] BINARY64_OVERFLOW \
                    "overflow keeps its typed error in directed modes"
                equal [_controlfp_s after 0 0] 0 "reread arithmetic controls"
                equal [expr {$after & 0x03000300}] [expr {$actual & 0x03000300}] "restore caller controls"
            }
        } finally {_controlfp_s restored $saved 0x03000300}
    } finally {
        if {[llength [info commands [namespace current]::_controlfp_s]]} {rename [namespace current]::_controlfp_s {}}
        $crt destroy
    }
}
proc ::binaryTest::watchReads {command op} {
    if {[lindex $command 1] ne "watch"} {return}
    foreach local [info args ::sample::numbers::observed] field {a b c d} {
        uplevel 1 [list trace add variable $local read [list ::binaryTest::recordRead $field]]
    }
}
proc ::binaryTest::recordRead {field args} {lappend ::binaryTest::events $field}
proc ::binaryTest::wireHook {} {}
proc ::binaryTest::restrictedArithmetic {} {
    set analysis [::appcompiler::analyze [dict create probe {
        export fn .same($a: list<binary64>, $b: list<binary64>) -> bool => $a == $b
    }]]
    set artifact [::appcompiler::emitModules [dict get $analysis modules] ::restricted \
        [dict get $analysis facts] [dict get $analysis resolved]]
    set child [interp create -safe]
    try {
        if {[llength [info commands ::machteld::x::binary64v1::add]]} {
            $child eval {namespace eval ::machteld::x::binary64v1 {namespace export add}}
            foreach op {add equal} {
                interp alias $child ::machteld::x::binary64v1::$op {} ::machteld::x::binary64v1::$op
            }
        }
        interp hide $child interp
        $child eval [dict get $artifact script]
        $child eval [list ::namespace eval ::restricted::@rt $::appcompiler::hostDefinitions]
        equal [$child eval {::restricted::probe::same {1 2} {1.0 2.0}}] 1 "restricted list equality"
        equal [$child eval {::restricted::probe::same {1 2} {1 3}}] 0 "restricted list inequality"
    } finally {interp delete $child}
}
proc ::binaryTest::replaceNumber {replacement name index op} {
    upvar 1 $name operand
    set operand $replacement
}
proc ::binaryTest::watchNumbers {function operands command op} {
    foreach local [info args ::sample::numbers::$function] replacement $operands {
        if {$replacement ne {}} {
            uplevel 1 [list trace add variable $local read [list ::binaryTest::replaceNumber $replacement]]
        }
    }
}
proc ::binaryTest::lateNumbers {} {
    foreach {function operands expected} {
        late_equal {9007199254740993 {}} 0
        late_equal {9007199254740993 9007199254740992} 0
        late_ratio {1 3} {ok 0.0}
        late_nested {9007199254740992 1} {ok 1.0}
    } {
        set trace [list ::binaryTest::watchNumbers $function $operands]
        trace add execution ::sample::numbers::wire_hook enter $trace
        try {
            equal [call $function 1 9007199254740992] $expected "late Tcl operands in $function"
        } finally {trace remove execution ::sample::numbers::wire_hook enter $trace}
    }
}
proc ::binaryTest::watchWire {command op} {
    set local [lindex [info args ::sample::numbers::observed_wire] 0]
    uplevel 1 [list trace add variable $local read ::binaryTest::replaceWireRow]
}
proc ::binaryTest::replaceWireRow {name index op} {
    upvar 1 $name row
    set row $::binaryTest::wireRow
    incr ::binaryTest::wireReads
}
proc ::binaryTest::wireExport {} {
    variable wireRow
    variable wireReads
    set node [::machteld::json decode -typed 1.00e+2]
    trace add execution ::sample::numbers::wire_hook enter ::binaryTest::watchWire
    try {
        # A Tcl callback may replace a previously admitted record just before export.
        foreach {spelling expected} [list -0.0 0 -5e-324 -4.9406564584124654e-324 \
                1.00000000000000011102230246251565404236316680908203125001 1.0000000000000002 \
                $node 100] {
            set wireRow [dict create value $spelling]
            set wireReads 0
            equal [call observed_wire {value 1}] [list ok [format {{"value":%s}} $expected]] \
                "late binary64 value retains its checked wire spelling"
            equal $wireReads 1 "export reads the source record once"
        }
        equal [::machteld::json type $node] number "export preserves the borrowed number handle"
        equal [::machteld::json encode -- $node] 1.00e+2 "export preserves its original spelling"
        foreach spelling [list 0x10 Inf "17\u0000tail"] {
            set wireRow [dict create value $spelling]
            set wireReads 0
            equal [catch {call observed_wire {value 1}} message options] 1 "reject invalid late field"
            equal [list [dict get $options -errorcode] $message] \
                {{APPCOMPILER ARGUMENT TYPE} {expected finite binary64 at value.value}} "wire field path"
            equal $wireReads 1 "failed export reads the source record once"
        }
    } finally {trace remove execution ::sample::numbers::wire_hook enter ::binaryTest::watchWire}
}
proc ::binaryTest::problemCode {result} {
    lassign $result tag fields
    equal $tag err "typed problem"
    return [dict get $fields code]
}

proc ::binaryTest::direct {work} {
    variable source
    set modules [dict create numbers $source]
    equal [::appcompiler::check $modules] {} "binary64 source checks"
    namespace eval :: [dict get [::appcompiler::compile $modules ::sample] script]
    arithmeticControls
    restrictedArithmetic
    lateNumbers
    wireExport
    set borrowed [::machteld::json decode -typed 0.1]
    set row [dict create raw $borrowed correction [list some -0.0]]
    lassign [call observations [list $row [dict create raw 1]]] first second
    equal [bits [dict get $first raw]] 3fb999999999999a "numeric row rounds the borrowed value"
    equal [bits [lindex [dict get $first correction] 1]] 0000000000000000 "numeric row canonicalizes optional zero"
    equal [dict exists $second correction] 0 "absent optional stays absent"
    equal [::machteld::json type $borrowed] number "numeric row preserves the caller's JSON number"
    set invalid [dict create correction [list some NaN] raw Inf]
    equal [catch {call observations [list $row $invalid]} message options] 1 "invalid numeric row"
    equal [list [dict get $options -errorcode] $message] \
        {{APPCOMPILER ARGUMENT TYPE} {expected finite binary64 at $rows.1.raw}} "declared error order and field path"
    equal [call exact_sum] 0.3 "ordinary fractional notation stays exact"
    equal [problemCode [call exact_ratio]] NONTERMINATING_DECIMAL "integer division stays decimal"
    foreach {input expected} {9007199254740993 9007199254740992 9007199254740995 9007199254740996} {
        lassign [call from_int $input] tag value
        equal [list $tag [call inspect $value]] [list ok $expected] "round tie toward even from $input"
    }
    equal [call inspect 0.1] 0.1000000000000000055511151231257827021181583404541015625 "exact value of the stored tenth"
    foreach {midpoint expected} {
        1.00000000000000011102230246251565404236316680908203125 3ff0000000000000
        1.00000000000000033306690738754696212708950042724609375 3ff0000000000002
    } {
        equal [bits [lindex [call from_decimal $midpoint] 1]] $expected "decimal midpoint rounds to even"
    }
    set padding [string repeat 0 1600]
    set tie 1.00000000000000011102230246251565404236316680908203125
    set below 1.00000000000000011102230246251565404236316680908203124
    # Half the least subnormal is exactly 5^1075 times 10^-1075.
    set halfMin [expr {5 ** 1075}]
    foreach {label text expected} [list \
            distant-above "$tie${padding}1" 3ff0000000000001 \
            distant-below "$below[string repeat 9 1600]" 3ff0000000000000 \
            subnormal-tie "-${halfMin}e-1075" 0000000000000000 \
            subnormal-above "-$halfMin${padding}1e-2676" 8000000000000001 \
            cancel-integer "12345${padding}e-001604" 3ff3c083126e978d \
            cancel-fraction "0.${padding}12345e+001601" 3ff3c083126e978d] {
        equal [bits [call identity binary64 $text]] $expected "decimal spelling $label"
    }
    equal [call display 0.1] 0.10000000000000001 "interpolation displays a round-trip number"
    ::compilerNumericLocale::withDecimalComma {
        foreach {input expected} {
            -0.125 -0.125
            0.1 0.10000000000000001
            1e-4 0.0001
            1e-5 1.0000000000000001e-05
            1e16 10000000000000000
            1e17 1e+17
            3.141592653589793 3.1415926535897931
        } {
            equal [call display $input] $expected "interpolation under a decimal-comma locale"
            equal [call encode [dict create value $input]] [list ok [format {{"value":%s}} $expected]] \
                "JSON keeps its numeric grammar under a decimal-comma locale"
        }
        equal [call display 2.9802322387695312e-08] 2.9802322387695312e-08 "halfway seventeenth digit rounds to even"
        equal [call inspect -0.125] -0.125 "exact decimal rendering retains its literal dot"
    }
    lassign [call sum 0.1 0.2] tag sum
    equal [list $tag [bits $sum]] {ok 3fd3333333333334} "binary tenth plus two tenths"
    equal [call same $sum 0.3] 0 "compares stored values"
    equal [call inspect -0.125] -0.125 "negative exactly representable fraction"
    # 2^-1074 = 5^1074 / 10^1074. Compare the whole expansion, including its
    # leading zeros and every digit, before any conversion back to binary64.
    set digits [expr {5**1074}]
    set least "0.[string repeat 0 [expr {1074 - [string length $digits]}]]$digits"
    equal [call inspect -5e-324] -$least "complete decimal expansion of negative 2^-1074"
    equal [call inspect 4503599627370495.5] 4503599627370495.5 "half below the exact integer boundary"
    equal [call difference 0.75 0.25] {ok 0.5} "binary subtraction"
    equal [call ratio 5 2] {ok 2.5} "Tcl integer spelling becomes binary64 at a typed boundary"
    equal [call inspect 0010] 10 "leading zeros stay decimal at the Tcl boundary"
    # Long padded integers remain finite up to the IEEE nearest-even overflow boundary.
    set maxInteger [expr {(1 << 1024) - (1 << 971)}]
    set halfway [expr {$maxInteger + (1 << 970)}]
    foreach spelling [list [expr {$halfway - 1}].0 +[expr {$halfway - 1}]e0] {
        equal [bits [call identity binary64 $spelling]] 7fefffffffffffff "decimal below the overflow midpoint rounds to the largest finite value"
    }
    lassign [call decode {{"value":268435455.99999998509883880615234374999}}] tag measurement
    equal [list $tag [bits [dict get $measurement value]]] {ok 41afffffffffffff} "JSON decoding preserves which side of a binary64 midpoint the evidence lies on"
    foreach {magnitude expected} [list 1[string repeat 0 308] 7fe1ccf385ebc8a0 \
            $maxInteger 7fefffffffffffff [expr {$halfway - 1}] 7fefffffffffffff] {
        foreach {sign prefix} {+ 7 - f} {
            set value ${sign}00$magnitude
            set expectedBits [string replace $expected 0 0 $prefix]
            equal [bits [call identity binary64 $value]] $expectedBits "padded scalar near maximum"
            equal [bits [lindex [call identity binary64? [list some $value]] 1]] $expectedBits "padded optional"
            equal [bits [dict get [call identity .numbers::reading [dict create value $value]] value]] \
                $expectedBits "padded record field"
        }
    }
    foreach value [list +00$halfway -00$halfway 001x "001\u0000x"] {
        equal [catch {call identity .numbers::reading [dict create value $value]} problem options] 1 \
            "reject an overflowing or malformed field"
        equal [list [dict get $options -errorcode] $problem] \
            {{APPCOMPILER ARGUMENT TYPE} {expected finite binary64 at $v.value}} "binary64 field path"
    }
    equal [call negate 0.5] -0.5 "unary negation"
    equal [call same -0.0 0.0] 1 "zero equality"
    equal [bits [call negate 0.0]] 0000000000000000 "unary negation canonicalizes zero"
    equal [problemCode [call ratio 1 -0.0]] DIVIDE_BY_ZERO "negative zero divisor"
    set max 1.7976931348623157e308
    set ::binaryTest::events {}
    set pair [call paired -1 1.0000000000000002 0.9999999999999998]
    equal [list [lindex $pair 0] [bits [lindex $pair 1]] $::binaryTest::events] \
        {ok 0000000000000000 {a b c}} "round the right product before adding and retain callback order"
    set pairLine [lsearch -inline -glob [split $source \n] {*ok((.tap('a'*, $a) + (.tap*}]
    set pairSites [regexp -all -inline -indices {\?} $pairLine]
    foreach operands [list [list 0 $max 2] [list $max $max 1]] site {0 1} {
        set ::binaryTest::events {}
        set failed [call paired {*}$operands]
        set location [dict get [lindex $failed 1] origin]
        equal [list [problemCode $failed] [dict get $location line] [dict get $location column] $::binaryTest::events] \
            [list BINARY64_OVERFLOW [expr {1 + [lsearch -exact [split $source \n] $pairLine]}] \
                [expr {1 + [lindex $pairSites $site 0]}] {a b c}] "preserve the first overflowing operator of the pair"
    }
    foreach {args expected} {{1 2 1 1} 0 {1 1 1 2} 1 {-5e-324 0.5 0 1} 1} {
        set ::binaryTest::events {}
        equal [call compared {*}$args] [list ok $expected] "compare two checked products"
        equal $::binaryTest::events {a b c d} "comparison preserves operand order"
    }
    set expression [lsearch -inline -glob [split $source \n] {*<= (.tap*}]
    set line [expr {1 + [lsearch -exact [split $source \n] $expression]}]
    set sites [regexp -all -inline -indices {\?} $expression]
    foreach {args site events} [list [list $max 2 $max 2] 0 {a b} \
            [list 1 1 $max 2] 1 {a b c d} [list 1 1 -$max 2] 1 {a b c d}] {
        set ::binaryTest::events {}
        set failure [call compared {*}$args]
        equal [problemCode $failure] BINARY64_OVERFLOW "comparison detects either sign of overflow"
        set origin [dict get [lindex $failure 1] origin]
        equal [list [dict get $origin line] [dict get $origin column] $::binaryTest::events] \
            [list $line [expr {1 + [lindex $sites $site 0]}] $events] "comparison preserves first failure and reached reads"
    }
    # The nested operation must evaluate each operand once and round at
    # every X operator. A fused multiply/subtract would retain a residual.
    foreach {a b c d expected} {
        1.0000000000000002 0.9999999999999998 1 0 0000000000000000
        -5e-324 0.5 0 0 0000000000000000
        5e-324 1 0 0 0000000000000001
        3 5 2 4 4022000000000000
    } {
        set ::binaryTest::events {}
        lassign [call rounded $a $b $c $d] tag number
        equal [list $tag [bits $number] $::binaryTest::events] \
            [list ok $expected {a b c d}] "rounding and effect order for $a * $b - ($c + $d)"
    }
    set expression [lsearch -inline -glob [split $source \n] {*ok(((.tap*}]
    set line [expr {1 + [lsearch -exact [split $source \n] $expression]}]
    set sites [regexp -all -inline -indices {\?} $expression]
    foreach {args order site} [list [list $max 2 $max $max] {a b} 0 \
            [list 1 1 $max $max] {a b c d} 1 [list $max 1 -$max 0] {a b c d} 2] {
        set ::binaryTest::events {}
        set failure [call rounded {*}$args]
        equal [problemCode $failure] BINARY64_OVERFLOW "checked arithmetic failed at operator $site"
        set origin [dict get [lindex $failure 1] origin]
        equal [list [dict get $origin module] [dict get $origin line] [dict get $origin column] $::binaryTest::events] \
            [list numbers $line [expr {1 + [lindex $sites $site 0]}] $order] "first failing ? and operand effects"
    }
    # Zero times an overflowing right subtree must report the right-hand ?
    # without evaluating 0.0 * Inf in Tcl. An intermediate underflow may
    # reach later arithmetic, but observable zero always has positive bits.
    set ::binaryTest::events {}
    set error [call times 1 1 $max 2]
    equal [problemCode $error] BINARY64_OVERFLOW "zero cannot erase an overflowing operand"
    equal $::binaryTest::events {a b c d} "multiplication reads all its operands exactly once"
    foreach args {{-5e-324 0.5 -5e-324 0.5} {0 -1 0 1} {-0.0 1 -0.0 -1}} {
        lassign [call deeper {*}$args] tag value
        equal [list $tag [bits $value]] {ok 0000000000000000} "nested zeros are canonical at the boundary"
    }
    # Install ordinary Tcl read traces after the public guard and observe the
    # source locals. Overflow in a subtree must skip every later operand.
    trace add execution ::sample::numbers::tap enter ::binaryTest::watchReads
    try {
        foreach {args expected} [list {2 4 1 3} {watch a b c d a} \
            [list $max 2 1 1] {watch a b} [list 1 1 $max 2] {watch a b c d} \
            [list $max 1 -$max 1] {watch a b c d}] {
            set ::binaryTest::events {}
            call observed {*}$args
            equal $::binaryTest::events $expected "each local is read at the original point"
        }
    } finally {trace remove execution ::sample::numbers::tap enter ::binaryTest::watchReads}
    equal [problemCode [call stored $max 2]] BINARY64_OVERFLOW "an escaping result retains its error tag"
    equal [problemCode [call product $max 2]] BINARY64_OVERFLOW "multiplication overflow"
    equal [problemCode [call sum $max $max]] BINARY64_OVERFLOW "addition overflow"
    equal [problemCode [call difference -$max $max]] BINARY64_OVERFLOW "subtraction overflow"
    equal [problemCode [call ratio $max 0.5]] BINARY64_OVERFLOW "division overflow"
    equal [problemCode [call from_int [expr {10**400}]]] BINARY64_OVERFLOW "conversion overflow"
    # Around 2^1023 the unsigned spelling has 308 digits. A minus sign makes
    # it 309 characters. Both spellings must round at the same halfway values.
    set base [expr {1 << 1023}]
    set half [expr {1 << 970}]
    foreach {distance lowBits} [list [expr {$half-1}] 0 $half 0 [expr {$half+1}] 1 \
            [expr {3*$half-1}] 1 [expr {3*$half}] 2 [expr {3*$half+1}] 2] {
        set magnitude [expr {$base + $distance}]
        foreach {value prefix} [list $magnitude 7fe -$magnitude ffe] {
            set expected ${prefix}000000000000$lowBits
            equal [bits [call identity binary64 $value]] $expected "public large integer midpoint"
            lassign [call from_int $value] tag converted
            equal [list $tag [bits $converted]] [list ok $expected] "X integer midpoint"
        }
    }
    foreach {input expected} {
        5e-324 0000000000000001 -5e-324 8000000000000001
        2.2250738585072014e-308 0010000000000000
        1.7976931348623157e308 7fefffffffffffff
    } {
        set decimal [call inspect $input]
        lassign [call from_decimal $decimal] tag value
        equal [list $tag [bits $value]] [list ok $expected] "exact-decimal round trip at $input"
    }
    equal [bits [lindex [call ratio -5e-324 2] 1]] 0000000000000000 "tiny negative tie underflows to canonical zero"
    foreach invalid [list Inf -Infinity NaN 0x10 {1 + 2} {[error BAD]}] {
        equal [catch {call identity list<binary64> [list $invalid]} message options] 1 "reject [list $invalid] at nested generic boundary"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "boundary error code"
    }
    set nominal [call named 1.0000000000000002]
    equal [bits [call unname [call identity .numbers::gain $nominal]]] 3ff0000000000001 "generic and distinct preserve binary bits"
    equal [call same_gain $nominal 1.0] 0 "distinct equality uses binary64"
    set json {{"value":1.0000000000000002e0,"future":"007"}}
    lassign [call decode $json] tag reading
    equal [list $tag [bits [dict get $reading value]]] {ok 3ff0000000000001} "declared JSON field accepts exponential notation"
    lassign [call encode $reading] tag encoded
    equal $tag ok "encodes finite binary64"
    equal [call decode $encoded] [list ok $reading] "JSON round trip preserves bits and unknown fields"
    foreach invalid {{{"value":"0.1"}} {{"value":1e400}}} {
        equal [lindex [call decode $invalid] 0] err "declared binary64 rejects invalid JSON field"
    }
    package require sqlite3
    set database [file join $work readings.db]
    sqlite3 db $database
    db eval {CREATE TABLE readings (value REAL NOT NULL) STRICT}
    db close
    lassign [call sql $database {SELECT ?1 AS value} $nominal] tag row
    equal [list $tag [bits [dict get $row value]]] {ok 3ff0000000000001} "typed SQL binds and reads the original REAL bits"
    equal [problemCode [call sql $database {SELECT CAST(?1 AS INTEGER) AS value} $nominal]] SQL_TYPE "typed SQL rejects INTEGER for binary64"
    equal [problemCode [call sql $database {SELECT ?1 * 1e999 AS value} $nominal]] SQL_TYPE "typed SQL rejects an infinity"
    equal [problemCode [call sql $database {SELECT -?1 * 1e999 AS value} $nominal]] SQL_TYPE "typed SQL rejects negative infinity"
    lassign [call sql $database {SELECT CASE WHEN ?1 > 0 THEN -0.0 ELSE 0.0 END AS value} $nominal] tag row
    equal [list $tag [bits [dict get $row value]]] {ok 0000000000000000} "typed SQL canonicalizes negative zero"
    sqlDenormal $database
    foreach word {0000000000000001 8000000000000001 0010000000000000 3ff0000000000001 7fefffffffffffff} {
        binary scan [binary decode hex $word] Q value
        equal [lindex [call store $database $value] 0] ok "commit $word in a REAL column"
        lassign [call fetch $database] tag row
        equal [list $tag [bits [dict get $row value]]] [list ok $word] "fresh connection reads the exact stored bits"
        lassign [call encode $row] tag encoded
        lassign [call decode $encoded] tag decoded
        equal [list $tag [bits [dict get $decoded value]]] [list ok $word] "JSON round trip at $word"
    }
    # Cover each finite exponent, alternating signs and varying the 52-bit
    # mantissa. Compare bits after exact expansion and nearest-even conversion.
    set fraction 1
    for {set exponent 0} {$exponent < 2047} {incr exponent} {
        set fraction [expr {(6364136223846793005 * $fraction + 1) & ((1 << 52) - 1)}]
        set word [expr {(($exponent & 1) << 63) | ($exponent << 52) | $fraction}]
        binary scan [binary format W $word] Q value
        lassign [call from_decimal [call inspect $value]] tag roundTrip
        binary scan [binary format Q $roundTrip] Wu restored
        if {$tag ne "ok" || $restored != $word} {error "exact decimal lost bits at exponent $exponent"}
    }
}

proc ::binaryTest::negative {} {
    foreach {code fragment} {
        OPERAND_TYPE {fn .f($x: binary64) -> result<binary64,problem> => $x + 1}
        OPERAND_TYPE {fn .f($x: binary64) -> result<binary64,problem> => 0.1 * $x}
        OPERAND_TYPE {fn .f($x: binary64) -> bool => $x == 0.1}
        RETURN_TYPE {fn .f() -> binary64 => 0.1}
        ARGUMENT_TYPE {fn .f($x: binary64) -> result<int,problem> => quotient($x, 1)}
        ARGUMENT_TYPE {fn .f($x: text) -> result<binary64,problem> => to_binary64($x)}
        ARGUMENT_TYPE {fn .f($x: decimal) -> decimal => exact_decimal($x)}
        ARGUMENT_TYPE {distinct .gain = binary64
            fn .f($x: .gain) -> decimal => exact_decimal($x)}
        ARGUMENT_TYPE {fn .id<.t>($a: .t, $b: .t) -> .t => $a
            fn .f($x: binary64) -> binary64 => .id($x, 1)}
        MAP_KEY_TYPE {fn .f($m: map<binary64,text>) -> text => 'x'}
    } {
        equal [lmap diagnostic [::appcompiler::check [dict create invalid $fragment]] {dict get $diagnostic code}] $code "diagnostics for $fragment"
    }
}

proc ::binaryTest::packed {root work} {
    set manifest [file join $root examples typed-calibration project.dict]
    set results [::appcompiler::project::test $manifest]
    equal [list [dict get $results total] [dict get $results failures]] {1 {}} "calibration example"
    set archive [file join $work calibration.machteld]
    ::appcompiler::project::pack $manifest $archive
    set rebuilt [file join $work rebuilt.machteld]
    ::appcompiler::project::rebuild $archive $rebuilt
    foreach app [list $archive $rebuilt] {
        set exe [info nameofexecutable]
        set run [::machteld::run -dir $work -stdin {{"raw":8,"gain":1.25,"offset":-0.5}} -timeout 30s -- $exe $app]
        equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] {0 9.5 {}} "packed calibration"
        set run [::machteld::run -dir $work -stdin {{"raw":1e308,"gain":10,"offset":0}} -timeout 30s -- $exe $app]
        equal [list [dict get $run exit] [dict get $run out] [string match {calibration:*: *exceeds*binary64*} [dict get $run err]]] {1 {} 1} "packed overflow has source location"
    }
}
if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set work [file normalize [file tempdir]]
try {
    ::binaryTest::direct $work
    ::binaryTest::negative
    if {$argv eq "-pack"} {::binaryTest::packed $root $work}
} finally {file delete -force -- $work}
puts "application compiler binary64: $::binaryTest::checks assertions passed"
