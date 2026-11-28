# Fetch stored binary64 measurements and run the example's calibrated filter.
package require machteld
package require sqlite3
set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set compilers {}
set timed 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set option [lindex $argv $i]] {
        --timings {set timed 1}
        --embedded {
            if {[dict exists $compilers X]} {error "select one candidate compiler"}
            dict set compilers X [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$option needs a compiler directory"}
            set label [expr {$option eq "--compiler" ? "X" : "baseline"}]
            if {[dict exists $compilers $label]} {error "select one $label compiler"}
            dict set compilers $label [lindex $argv $i]
            if {$label eq "baseline"} {set timed 1}
        }
        default {error {usage: calibrated-series.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--timings?}}
    }
}
if {![dict exists $compilers X]} {dict set compilers X [file join $root packages application-compiler]}
set channel [open [file join $root examples typed-calibration calibration.src] r]
try {chan configure $channel -encoding utf-8; set calibration [read $channel]} finally {close $channel}
set series {import calibration
record .reading {
    id: int
    raw: binary64
    bias: binary64?
}
record .point {
    id: int
    value: binary64
}
export fn .rows($path: text, $limit: int) -> result<list<.reading>,problem> =>
    sql_many<.reading>($path, 'SELECT id,raw,bias FROM readings WHERE id < ?1 ORDER BY id', $limit)
export fn .selected($path: text, $limit: int, $gain: binary64, $threshold: binary64) -> result<list<.point>,problem> =>
    .selected_rows(.rows($path, $limit)?, $gain, $threshold)
export fn .selected_rows($rows: list<.reading>, $gain: binary64, $threshold: binary64) -> result<list<.point>,problem> {
    $points := list<.point>()
    $zero ::= to_binary64(0)?
    for $r in $rows {
        $offset ::= match $r.bias {
            some($v) => $v
            none => $zero
        }
        $m ::= make<.calibration::measurement>(raw: $r.raw, gain: $gain, offset: $offset)
        $y ::= .calibration::apply($m)?
        if $y >= $threshold { $points = list_append($points, make<.point>(id: $r.id, value: $y)) }
    }
    return ok($points)
}}
dict for {label directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set artifact [$child eval [list ::appcompiler::compile [dict create calibration $calibration series $series] ::series_$label]]
        namespace eval :: [dict get $artifact script]
    } finally {interp delete $child}
}

proc fromBits {bits} {binary scan [binary format W $bits] Q number; return $number}
proc bits {number} {binary scan [binary format Q $number] Wu word; return $word}
proc fixture {db count} {
    set query {}
    set selected {}
    $db eval {CREATE TABLE readings(id INTEGER PRIMARY KEY, raw REAL NOT NULL, bias REAL)}
    $db transaction {
        for {set id 0} {$id < $count} {incr id} {
            # Independent expected values use only integer exponent shifts. Each
            # bias, when present, doubles the scaled value exactly. No rounding
            # or formatting routine under test supplies the expected bits.
            set negative [expr {$id % 3 == 0}]
            set exponent [expr {1017 + ($id * 17) % 20}]
            set fraction [expr {($id * 0x9e3779b97f4a7c15) & 0xfffffffffffff}]
            set raw [expr {($negative << 63) | ($exponent << 52) | $fraction}]
            set scaled [expr {$raw - (5 << 52)}]
            set bindings [dict create 1 [list integer $id] 2 [list real [fromBits $raw]]]
            if {$id % 7} {
                dict set bindings 3 [list real [fromBits $scaled]]
                set bias [list some $scaled]
                set adjusted [expr {$scaled + (1 << 52)}]
            } else {
                dict set bindings 3 [list null]
                set bias none
                set adjusted $scaled
            }
            $db eval -parameters $bindings {INSERT INTO readings VALUES (?1,?2,?3)}
            lappend query [list $id $raw $bias]
            if {!$negative && $adjusted >= 0x3ff0000000000000} {lappend selected [list $id $adjusted]}
        }
    }
    return [dict create rows $query selected $selected]
}

proc verify {operation answer expected} {
    lassign $answer tag data
    if {$tag ne "ok" || [llength $data] != [llength $expected]} {error "wrong $operation result or row count: $tag"}
    foreach row $data want $expected {
        if {$operation eq "rows"} {
            if {[dict size $row] != 3} {error "wrong query columns"}
            set bias [dict get $row bias]
            if {[lindex $bias 0] eq "some" && [llength $bias] == 2} {set bias [list some [bits [lindex $bias 1]]]}
            set got [list [dict get $row id] [bits [dict get $row raw]] $bias]
        } else {
            if {[dict size $row] != 2} {error "wrong calibrated fields"}
            set got [list [dict get $row id] [bits [dict get $row value]]]
        }
        if {$got ne $want} {error "$operation row differs: expected $want, got $got"}
    }
}

set area [file normalize [file tempdir]]
set path [file join $area readings.db]
try {
    sqlite3 writer $path
    try {set expected [fixture writer [expr {$timed ? 8192 : 48}]]} finally {writer close}
    # A Tcl application may already own the sensor records. Construct its
    # copies directly from the fixture words, independently of the SQL reader.
    set resident {}
    foreach input [dict get $expected rows] {
        lassign $input id raw bias
        if {[lindex $bias 0] eq "some"} {set bias [list some [fromBits [lindex $bias 1]]]}
        lappend resident [dict create id $id raw [fromBits $raw] bias $bias]
    }
    set sizes [expr {$timed ? {0 256 8192} : {0 1 48}}]
    if {$timed} {puts [join {round compiler operation input_rows output_rows elapsed_us} \t]}
    for {set round 0} {$round <= ($timed ? 12 : 0)} {incr round} {
        set order [dict keys $compilers]
        if {$round % 2} {set order [lreverse $order]}
        foreach count $sizes {
            set inputs [lrange $resident 0 [expr {$count-1}]]
            foreach op {rows selected selected_rows} {
                set want {}
                set shape [expr {$op eq "rows" ? "rows" : "selected"}]
                foreach row [dict get $expected $shape] {
                    if {[lindex $row 0] >= $count} break
                    lappend want $row
                }
                foreach label $order {
                    set query ::series_${label}::series::$op
                    switch -- $op {
                        rows {set call [list $query $path $count]}
                        selected {set call [list $query $path $count 0.03125 1.0]}
                        selected_rows {set call [list $query $inputs 0.03125 1.0]}
                    }
                    set begin [clock microseconds]
                    set result [{*}$call]
                    set elapsed [expr {[clock microseconds] - $begin}]
                    verify $shape $result $want
                    unset result
                    if {$round} {puts [join [list $round $label $op $count [llength $want] $elapsed] \t]}
                }
            }
        }
    }
    if {!$timed} {puts "compiler calibrated series: every stored bit, optional bias, filtered ID and adjusted value matched"}
} finally {
    file delete -force -- $path
    file delete -- $area
}
