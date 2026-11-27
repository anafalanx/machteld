package require machteld
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

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
}
}
proc ::binaryTest::equal {value expected why} {
    variable checks
    if {$value ne $expected} {error "$why: expected [list $expected], got [list $value]"}
    incr checks
}
proc ::binaryTest::call {name args} {::sample::numbers::$name {*}$args}
proc ::binaryTest::bits {number} {binary encode hex [binary format Q $number]}
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
    equal [call display 0.1] 0.10000000000000001 "interpolation displays a round-trip number"
    lassign [call sum 0.1 0.2] tag sum
    equal [list $tag [bits $sum]] {ok 3fd3333333333334} "binary tenth plus two tenths"
    equal [call same $sum 0.3] 0 "compares stored values"
    equal [call inspect -0.125] -0.125 "negative exactly representable fraction"
    equal [call difference 0.75 0.25] {ok 0.5} "binary subtraction"
    equal [call ratio 5 2] {ok 2.5} "Tcl integer spelling becomes binary64 at a typed boundary"
    equal [call inspect 0010] 10 "leading zeros stay decimal at the Tcl boundary"
    equal [call negate 0.5] -0.5 "unary negation"
    equal [call same -0.0 0.0] 1 "zero equality"
    equal [bits [call negate 0.0]] 0000000000000000 "unary negation canonicalizes zero"
    equal [problemCode [call ratio 1 -0.0]] DIVIDE_BY_ZERO "negative zero divisor"
    set max 1.7976931348623157e308
    equal [problemCode [call product $max 2]] BINARY64_OVERFLOW "multiplication overflow"
    equal [problemCode [call sum $max $max]] BINARY64_OVERFLOW "addition overflow"
    equal [problemCode [call difference -$max $max]] BINARY64_OVERFLOW "subtraction overflow"
    equal [problemCode [call ratio $max 0.5]] BINARY64_OVERFLOW "division overflow"
    equal [problemCode [call from_int [expr {10**400}]]] BINARY64_OVERFLOW "conversion overflow"
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
