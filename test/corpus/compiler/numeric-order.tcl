# Read numbered observations in the exact numeric order of their external keys.
package require machteld
set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set compilers {}
set timed 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set flag [lindex $argv $i]] {
        --timings {set timed 1}
        --embedded {
            if {[dict exists $compilers X]} {error "select the candidate compiler once"}
            dict set compilers X [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$flag needs a compiler directory"}
            set label [expr {$flag eq "--compiler" ? "X" : "baseline"}]
            if {[dict exists $compilers $label]} {error "select the $label compiler once"}
            dict set compilers $label [lindex $argv $i]
            if {$label eq "baseline"} {set timed 1}
        }
        default {error {usage: numeric-order.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--timings?}}
    }
}
if {![dict exists $compilers X]} {dict set compilers X [file join $root packages application-compiler]}

set source {}
foreach type {int decimal} {
    append source [string map [list TYPE $type] {
export fn .ordered_TYPE($rows: map<TYPE,int>) -> list<TYPE> => sorted_keys($rows)
export fn .read_TYPE($rows: map<TYPE,int>) -> result<list<int>,problem> {
    $values := list<int>()
    for $key in sorted_keys($rows) {
        $values = list_append($values, require_key($rows, $key)?)
    }
    return ok($values)
}
}]
}
dict for {label directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set artifact [$child eval [list ::appcompiler::compile [dict create readings $source] ::numeric_$label]]
        namespace eval :: [dict get $artifact script]
    } finally {interp delete $child}
}

# Construct strictly increasing magnitudes in bands. Fractional digits beyond
# binary64 precision and integer IDs beyond 64 bits survive in the answer.
proc orderedKeys {type count} {
    if {!$count} {return {}}
    set positive {}
    if {$type eq "decimal"} {
        for {set i 1} {$i <= $count} {incr i} {lappend positive [format {0.%06d1} $i]}
    }
    for {set i 1} {$i <= $count} {incr i} {lappend positive $i}
    if {$type eq "int"} {
        foreach power {63 64 128} {
            foreach delta {-1 0 1} {lappend positive [expr {(1 << $power) + $delta}]}
        }
    } else {
        for {set i 1} {$i <= $count} {incr i} {
            lappend positive [format {9007199254740992.0000000000000000%06d1} $i]
        }
    }
    set wide 1[string repeat 0 180]
    for {set i 1} {$i <= $count} {incr i} {lappend positive [expr {$wide + $i}]}
    return [concat [lmap key [lreverse $positive] {format {-%s} $key}] [list 0] $positive]
}

if {$timed} {puts [join {round compiler type keys operation elapsed_us} \t]}
foreach type {int decimal} {
    foreach count {0 1 32 256} {
        set keys [orderedKeys $type $count]
        set n [llength $keys]
        # Insert in two interleaved, reversed passes. Payloads are independent
        # row numbers and check that a key still selects its original value.
        set rows {}
        foreach parity {0 1} {
            for {set i [expr {$n - 1 - $parity}]} {$i >= 0} {incr i -2} {
                dict set rows [lindex $keys $i] [expr {3 * $i + 43}]
            }
        }
        set values {}
        for {set i 0} {$i < $n} {incr i} {lappend values [expr {3 * $i + 43}]}
        set expected [dict create ordered $keys read [list ok $values]]
        set limit [expr {$timed ? 12 : 0}]
        for {set round 0} {$round <= $limit} {incr round} {
            set labels [dict keys $compilers]
            if {$round % 2} {set labels [lreverse $labels]}
            foreach label $labels {
                foreach op {ordered read} {
                    set cmd ::numeric_${label}::readings::${op}_$type
                    set start [clock microseconds]
                    set result [$cmd $rows]
                    set elapsed [expr {[clock microseconds] - $start}]
                    if {$result ne [dict get $expected $op]} {error "$label/$type/$n wrong $op result"}
                    if {$round} {puts [join [list $round $label $type $n $op $elapsed] \t]}
                }
            }
        }
    }
}
if {!$timed} {puts {compiler numeric map order: every exact key and observation matched}}
