# Reconcile exact quantities and invoice values from a stored ledger.
package require machteld
package require sqlite3
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set compilers {}
set timed 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set flag [lindex $argv $i]] {
        --embedded {
            if {[dict exists $compilers X]} {error "select one candidate compiler"}
            dict set compilers X [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --timings {set timed 1}
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$flag needs a compiler directory"}
            set label [expr {$flag eq "--compiler" ? "X" : "baseline"}]
            if {[dict exists $compilers $label]} {error "select one $label compiler"}
            dict set compilers $label [lindex $argv $i]
            if {$label eq "baseline"} {set timed 1}
        }
        default {error {usage: invoice-totals.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--timings?}}
    }
}
if {![dict exists $compilers X]} {dict set compilers X [file join $root packages application-compiler]}
set f [open [file join $here invoice-totals.src]]
try {chan configure $f -encoding utf-8; set source [read $f]} finally {close $f}
dict for {label directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set built [$child eval [list ::appcompiler::compile [dict create invoice $source] ::invoice_$label]]
        namespace eval :: [dict get $built script]
    } finally {interp delete $child}
}

# The oracle accumulates integer units at one known scale. It never parses a
# decimal, delegates arithmetic to X, or derives expected values from SQL.
proc decimalText {units scale} {
    if {$units == 0} {return 0}
    set sign [expr {$units < 0 ? "-" : ""}]
    set digits [expr {abs($units)}]
    set digits [string repeat 0 [expr {max(0, 1 + $scale - [string length $digits])}]]$digits
    set cut [expr {[string length $digits] - $scale}]
    set whole [string range $digits 0 $cut-1]
    set fraction [string trimright [string range $digits $cut end] 0]
    if {$fraction ne {}} {append whole . $fraction}
    return $sign$whole
}
proc ledger {db shape count} {
    set scale [expr {$shape eq "tiny" ? 43 : 3}]
    set common [expr {$shape eq "wide" ? 10**35 : 0}]
    set units 0
    set amount 0
    set low 0
    set high 0
    set records {}
    $db transaction {
        $db eval {DELETE FROM entry}
        for {set id 0} {$id < $count} {incr id} {
            set issuedUnits [expr {$common + ($id * 337) % 810000 - 2300}]
            set returnedUnits [expr {$common + ($id * 563) % 260000}]
            set rateUnits [expr {($id * 2011) % 930000}]
            set net [expr {$issuedUnits - $returnedUnits}]
            incr units $net
            incr amount [expr {$net * $rateUnits}]
            if {$id == 0 || $net < $low} {set low $net}
            if {$id == 0 || $net > $high} {set high $net}
            set issued [decimalText $issuedUnits $scale]
            set returned [decimalText $returnedUnits $scale]
            set price [decimalText $rateUnits 2]
            $db eval {INSERT INTO entry VALUES ($id,$issued,$returned,$price)}
            lappend records [dict create id $id issued $issued returned $returned price $price]
        }
    }
    set summary [dict create lines $count units [decimalText $units $scale] \
            amount [decimalText $amount [expr {$scale + 2}]] \
            smallest [decimalText $low $scale] largest [decimalText $high $scale]]
    return [list $records $summary]
}

set area [file normalize [file tempdir]]
set path [file join $area invoice.db]
try {
    sqlite3 writer $path
    try {
        writer eval {CREATE TABLE entry(id INTEGER PRIMARY KEY,issued TEXT NOT NULL,returned TEXT NOT NULL,price TEXT NOT NULL) STRICT}
        if {$timed} {puts [join {round compiler shape rows operation elapsed_us} \t]}
        foreach shape {empty ordinary wide tiny} {
            set count [expr {$shape eq "empty" ? 0 : ($timed ? 1536 : 48)}]
            lassign [ledger writer $shape $count] rows expected
            for {set round 0} {$round <= ($timed ? 12 : 0)} {incr round} {
                set order [dict keys $compilers]
                if {$round % 2} {set order [lreverse $order]}
                foreach op {sum_rows report} {
                    foreach label $order {
                        set call ::invoice_${label}::invoice::$op
                        set input [expr {$op eq "report" ? $path : $rows}]
                        set start [clock microseconds]
                        set result [$call $input]
                        set elapsed [expr {[clock microseconds] - $start}]
                        set want [expr {$op eq "report" ? [list ok $expected] : $expected}]
                        if {$result ne $want} {error "$label $shape $op: expected $want, got $result"}
                        if {$round} {puts [join [list $round $label $shape $count $op $elapsed] \t]}
                    }
                }
            }
        }
        writer eval {UPDATE entry SET issued='1.2e5' WHERE id=(SELECT max(id) FROM entry)}
        dict for {label directory} $compilers {
            lassign [::invoice_${label}::invoice::report $path] status problem
            if {$status ne "err" || [dict get $problem code] ne "SQL_TYPE"} {error "accepted malformed stored quantity"}
        }
    } finally {writer close}
} finally {file delete -force -- $area}
if {!$timed} {puts {invoice totals: all exact totals and extrema verified for empty, ordinary, wide and tiny data}}
