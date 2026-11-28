# Reconstruct probe membership and observation gaps for a bench's runs.
package require machteld
set here [file dirname [file normalize [info script]]]
set compilers {}
set mode {}
set tclReference 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set option [lindex $argv $i]] {
        --once {set mode once}
        --timings {set mode timings}
        --tcl-reference {set tclReference 1}
        --embedded {
            if {[dict exists $compilers X]} {error "select the candidate compiler once"}
            dict set compilers X [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --runs {
            if {[incr i] >= [llength $argv]} {error "$option needs a run count"}
            set count [lindex $argv $i]
            if {![string is integer -strict $count] || $count < 0} {error "expected a nonnegative run count"}
        }
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$option needs a compiler directory"}
            set label [expr {$option eq "--compiler" ? "X" : "baseline"}]
            if {[dict exists $compilers $label]} {error "select the $label compiler once"}
            dict set compilers $label [lindex $argv $i]
        }
        default {error {usage: probe-window.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--tcl-reference? ?--runs count? ?--once | --timings?}}
    }
}
if {![dict exists $compilers X]} {dict set compilers X [file join $here .. .. .. packages application-compiler]}
set timed [expr {$mode eq "timings" || ($mode eq {} && [dict exists $compilers baseline])}]
set f [open [file join $here probe-window.src] r]
try {chan configure $f -encoding utf-8; set source [read $f]} finally {close $f}
dict for {label directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set app [$child eval [list ::appcompiler::compile [dict create probe $source] ::probe_$label]]
        namespace eval :: [dict get $app script]
    } finally {interp delete $child}
}

proc runRow {id bench start stop} {dict create id $id bench $bench start $start stop $stop}
proc assignment {id run probe start stop} {dict create id $id run $run probe $probe start $start stop $stop}
proc gap {run start stop} {dict create run $run start $start stop $stop}

# The oracle enumerates each integer tick within the selected runs. It does
# not use sorted interval starts or a cursor over merged intervals like X.
proc oracle {runs north south bench start stop} {
    set byRun {}
    foreach feed [list $north $south] {
        set seen {}
        foreach row $feed {
            set id [dict get $row id]
            if {[dict exists $seen $id]} {
                foreach field {run probe start stop} {
                    if {[dict get $seen $id $field] ne [dict get $row $field]} {error "conflicting fixture id $id"}
                }
                continue
            }
            dict set seen $id $row
            dict lappend byRun [dict get $row run] $row
        }
    }
    set picked {}
    foreach run $runs {
        set lo [expr {max($start,[dict get $run start])}]
        set hi [expr {min($stop,[dict get $run stop])}]
        if {[dict get $run bench] eq $bench && $lo < $hi} {dict set picked [dict get $run id] [list $lo $hi]}
    }
    set gaps {}; set probes {}; set evidence 0
    foreach id [lsort -ascii [dict keys $picked]] {
        lassign [dict get $picked $id] lo hi
        set ticks {}
        foreach row [dict getdef $byRun $id {}] {
            set first [expr {max($lo,[dict get $row start])}]
            set last [expr {min($hi,[dict get $row stop])}]
            if {$first >= $last} continue
            incr evidence
            lappend probes [dict get $row probe]
            for {set t $first} {$t < $last} {incr t} {dict set ticks $t 1}
        }
        unset -nocomplain missing
        for {set t $lo} {$t < $hi} {incr t} {
            if {![dict exists $ticks $t]} {
                if {![info exists missing]} {set missing $t}
            } elseif {[info exists missing]} {
                lappend gaps [gap $id $missing $t]; unset missing
            }
        }
        if {[info exists missing]} {lappend gaps [gap $id $missing $hi]}
    }
    return [dict create runs [lsort -ascii [dict keys $picked]] probes [lsort -ascii -unique $probes] gaps $gaps evidence $evidence]
}
proc verify {actual want} {
    lassign $actual tag report
    if {[llength $actual] != 2 || $tag ne "ok" || [lsort [dict keys $report]] ne {evidence gaps probes runs}} {error "unexpected report: $actual"}
    foreach field {evidence runs probes} {
        if {[dict get $report $field] ne [dict get $want $field]} {error "incorrect $field"}
    }
    set gaps [dict get $report gaps]
    if {[llength $gaps] != [llength [dict get $want gaps]]} {error "incorrect gap count"}
    foreach row $gaps expected [dict get $want gaps] {
        if {[lsort [dict keys $row]] ne {run start stop}} {error "incorrect gap fields"}
        foreach field {run start stop} {
            if {[dict get $row $field] ne [dict get $expected $field]} {error "incorrect ordered gap: $row, expected $expected"}
        }
    }
}

set bench "Alpha 雪"
set implementations {}
dict for {label directory} $compilers {dict set implementations $label ::probe_${label}::probe::research}
if {$tclReference} {
    source -encoding utf-8 [file join $here probe-reference.tcl]
    dict set implementations Tcl ::handProbe::research
}
set runs [list [runRow quiet $bench 8 12] [runRow R2 $bench 4 10] [runRow R1 $bench 0 12] [runRow edge $bench 12 16] [runRow empty $bench 7 7] [runRow other Beta 0 12]]
set c [assignment c1 R1 7 -4 4]
set north [list $c [assignment c2 R1 "P\0A" 4 6] [assignment c3 R2 雪 4 5] [assignment c4 R1 later 12 14] [assignment c5 R1 empty 8 8] [assignment c6 R1 007 3 4] $c]
set south [list $c [assignment c2 R1 "P\0A" 5 7] [assignment c3 R1 🧪 9 11] [assignment c4 R2 雪 6 10] [assignment c5 other stray 6 10] [assignment c6 unscheduled stray 2 12]]
set known [dict create runs {R1 R2 quiet} probes [list 007 7 "P\0A" 雪 🧪] gaps [list [gap R1 7 9] [gap R1 11 12] [gap R2 5 6] [gap quiet 8 12]] evidence 8]
verify [list ok [oracle $runs $north $south $bench 2 12]] $known
foreach query [list [list $bench 2 12] [list $bench 12 13] [list $bench 8 8] [list $bench 9 2] {missing 0 20}] {
    set args [list $runs $north $south {*}$query]
    set want [oracle {*}$args]
    dict for {label command} $implementations {verify [$command {*}$args] $want}
}
set conflict [concat $north [list [dict replace $c probe different]]]
if {![catch {oracle $runs $conflict $south $bench 0 10} message] || $message ne {conflicting fixture id c1}} {error "invalid conflict control"}
set distant [expr {1 << 80}]
set wideInput [list [list [runRow wide $bench 0 [expr {$distant+5}]]] \
    [list [assignment late wide B $distant [expr {$distant+2}]] [assignment early wide A 1 3]] \
    {} $bench 0 [expr {$distant+5}]]
set wideReport [dict create runs wide probes {A B} evidence 2 gaps \
    [list [gap wide 0 1] [gap wide 3 $distant] [gap wide [expr {$distant+2}] [expr {$distant+5}]]]]
dict for {label command} $implementations {
    verify [$command {*}$wideInput] $wideReport
    verify [$command [lreverse $runs] [lreverse $south] [lreverse $north] $bench 2 12] $known
    lassign [$command $runs $conflict $south $bench 0 10] tag problem
    if {$tag ne "err" || [dict get $problem message] ne "source reused evidence id 'c1' with different content"
        || ($label ne "Tcl" && [dict get $problem origin module] ne "probe")} {error "wrong conflicting-id result"}
}

# All runs are short, even when the absolute clock exceeds signed 64 bits.
proc fixture {count clockBase bench} {
    set runs {}; set feeds [dict create north {} south {}]
    set probes [list 007 7 "p\0a" 雪 🧪 Amber amber]
    for {set i 0} {$i < $count} {incr i} {
        set id "run-$i"
        set base [expr {$clockBase+($i%7)*6}]
        set which [expr {$i%4 == 3 ? "Beta" : $bench}]
        lappend runs [runRow $id $which $base [expr {$base+40}]]
        if {$i%7 == 6} continue
        foreach side {0 1} name {north south} {
            for {set j 0} {$j < 16} {incr j} {
                set at [expr {$base+($j%4)*10+$j/4+$side-2}]
                set probe [lindex $probes [expr {($i+$j+$side)%[llength $probes]}]]
                set row [assignment "e-$i-$j" $id $probe $at [expr {$at+2+($j+$side)%4}]]
                dict lappend feeds $name $row
                if {$j%5 == 0} {dict lappend feeds $name $row}
            }
        }
    }
    list [lreverse $runs] [dict get $feeds north] [lreverse [dict get $feeds south]] $bench [expr {$clockBase+3}] [expr {$clockBase+68}]
}
if {![info exists count]} {set count [expr {$timed ? 64 : 8}]}
set args [fixture $count [expr {1<<75}] $bench]
set want [oracle {*}$args]
dict for {label command} $implementations {verify [$command {*}$args] $want}
source -encoding utf-8 [file join $here probe-archive.tcl]
set readers {}
dict for {label directory} $compilers {dict set readers $label ::probe_${label}::probe::archive_coverage}
verifyProbeArchive $readers
if {!$timed} {puts "probe coverage: distinct probes, two-source evidence and every uncovered span verified"; return}
puts "round\tcompiler\truns\tnorth_rows\tsouth_rows\telapsed_us"
for {set round 1} {$round <= 12} {incr round} {
    set order [dict keys $implementations]
    if {[llength $order] > 2} {
        set shift [expr {(($round-1)/2) % [llength $order]}]
        set order [concat [lrange $order $shift end] [lrange $order 0 $shift-1]]
    }
    if {$round%2} {set order [lreverse $order]}
    foreach label $order {
        set start [clock microseconds]
        set result [[dict get $implementations $label] {*}$args]
        set elapsed [expr {[clock microseconds]-$start}]
        verify $result $want
        puts [join [list $round $label $count [llength [lindex $args 1]] [llength [lindex $args 2]] $elapsed] \t]
    }
}
