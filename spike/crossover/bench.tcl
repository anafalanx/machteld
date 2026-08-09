# bench.tcl -- where the crossover actually is: four ways to run the same items.
#
#   machteld.exe bench.tcl                     the whole thing
#   machteld.exe bench.tcl --worker            one pool worker (arm C)
#   machteld.exe bench.tcl --item  <file> <i>  one item      (arm B1)
#   machteld.exe bench.tcl --chunk <file> <a> <b>  a slice   (arm B2)
#
# The item list lives in a FILE that every arm reads, so no arm gets its work
# handed to it in a cheaper form than the others. Arm C reads it once per worker
# and is then fed indices over the pipe, which is the same information.

namespace eval ::bench {
    namespace path ::machteld
    variable ITEMS {}       ;# per-item iteration counts
    variable FILES {}       ;# per-item file paths, for the external-program arm
}

# THE WORK. In a proc, in every arm, because the same loop at top level runs 3.6x
# slower (docs/parallel.md) -- and a benchmark that puts it at top level in one
# arm and in a proc in another is measuring the compiler, not the cores. That
# mistake has already been made once in this project.
proc ::bench::workitem {n} {
    set acc 0
    for {set i 0} {$i < $n} {incr i} {
        set acc [expr {($acc + $i * 2654435761) % 4294967291}]
    }
    return $acc
}

# The external-program item: the archetype -- spawn a real program, read what it
# said. `findstr` over a source file is the same shape as the 4.84x measurement
# already in the docs.
proc ::bench::runitem {path} {
    set r [run -- findstr /c:proc $path]
    return [string length [dict get $r out]]
}

proc ::bench::load {file} {
    variable ITEMS ; variable FILES
    set fh [open $file r]
    fconfigure $fh -translation lf
    set data [read $fh]
    close $fh
    set ITEMS [lindex $data 0]
    set FILES [lindex $data 1]
}

# --- the modes a child or worker runs in ------------------------------------

# The iteration count comes on the command line, not out of the item file: arm C
# is told its `n` over the pipe and reads nothing, so a child that had to open and
# parse a file first would be losing to the pool on I/O this benchmark did not set
# out to measure. Only the chunk arm needs the file, because a slice is a list.
proc ::bench::mode_item {n} {
    puts [workitem $n]
}

proc ::bench::mode_chunk {file a b} {
    variable ITEMS ; variable FILES
    load $file
    set out {}
    for {set i $a} {$i <= $b} {incr i} {
        set n [lindex $ITEMS $i]
        lappend out [expr {$n eq "x" ? [runitem [lindex $FILES $i]] : [workitem $n]}]
    }
    puts $out
}

proc ::bench::mode_worker {} {
    # The handler calls `workitem` by bare name from ::bench -- which resolves
    # because a handler is compiled in the namespace it was written in. Before
    # step 5 this same line failed at request time, from another process.
    worker on burn {n}    { workitem $n }
    worker on grep {path} { runitem $path }
    worker serve
}

# --- the four arms -----------------------------------------------------------

proc ::bench::arm_seq {items files} {
    set out {}
    foreach n $items f $files {
        lappend out [expr {$n eq "x" ? [runitem $f] : [workitem $n]}]
    }
    return $out
}

# B1: one child per item, bounded to $width, refilled as each finishes. For the
# external workload the child IS the external program -- no intermediate Tcl
# process, which is the fairest possible version of the old way.
proc ::bench::arm_child {items files width file exe self} {
    set out [lrepeat [llength $items] ""]
    set live [dict create]           ;# handle -> index
    set next 0
    set n [llength $items]
    while {$next < $n || [dict size $live]} {
        while {$next < $n && [dict size $live] < $width} {
            if {[lindex $items $next] eq "x"} {
                set c [child start -- findstr /c:proc [lindex $files $next]]
            } else {
                set c [child start -- $exe $self --item [lindex $items $next]]
            }
            dict set live $c $next
            incr next
        }
        set done [wait -any {*}[dict keys $live]]
        set idx [dict get $live $done]
        set r [child wait $done]
        if {[lindex $items $idx] eq "x"} {
            lset out $idx [string length [dict get $r out]]
        } else {
            lset out $idx [string trim [dict get $r out]]
        }
        catch {child close $done}
        dict unset live $done
    }
    return $out
}

# B2: one child per WORKER, each handed a contiguous slice. The smart old way,
# and the pool's real competitor: it pays the 26 ms boot $width times in total
# and then has no protocol at all.
proc ::bench::arm_chunk {items width file exe self} {
    set n [llength $items]
    set per [expr {($n + $width - 1) / $width}]
    set kids {}
    for {set a 0} {$a < $n} {incr a $per} {
        set b [expr {min($a + $per - 1, $n - 1)}]
        lappend kids [list [child start -- $exe $self --chunk $file $a $b] $a $b]
    }
    set out {}
    foreach k $kids {
        lassign $k c a b
        set r [child wait $c]
        catch {child close $c}
        foreach v [string trim [dict get $r out]] { lappend out $v }
    }
    return $out
}

proc ::bench::arm_pool {items files width exe self} {
    set reqs {}
    foreach n $items f $files {
        if {$n eq "x"} {
            lappend reqs [list op grep path $f]
        } else {
            lappend reqs [list op burn n $n]
        }
    }
    return [pmap $reqs -width $width -- $exe $self --worker]
}

# --- the harness -------------------------------------------------------------

proc ::bench::ms {script} {
    set t0 [clock microseconds]
    uplevel 1 $script
    return [expr {([clock microseconds] - $t0) / 1000.0}]
}

proc ::bench::median {vals} {
    set s [lsort -real $vals]
    return [lindex $s [expr {[llength $s] / 2}]]
}

# Runs an arm REPS times warm and returns {median min max}. The first run is
# discarded: a cold pass measures the disk and the filter driver, not the design.
proc ::bench::measure {reps script} {
    uplevel 1 $script
    set times {}
    for {set i 0} {$i < $reps} {incr i} {
        lappend times [uplevel 1 [list ::bench::ms $script]]
    }
    return [list [median $times] [tcl::mathfunc::min {*}$times] [tcl::mathfunc::max {*}$times]]
}

# --- driver ------------------------------------------------------------------

set ::bench::EXE  [info nameofexecutable]
set ::bench::SELF [file normalize [info script]]

# Modes first: a child or worker must do its job and nothing else.
if {[lindex $argv 0] eq "--worker"} { ::bench::mode_worker ; exit 0 }
if {[lindex $argv 0] eq "--item"}   { ::bench::mode_item  [lindex $argv 1] ; exit 0 }
if {[lindex $argv 0] eq "--chunk"}  { ::bench::mode_chunk [lindex $argv 1] [lindex $argv 2] [lindex $argv 3] ; exit 0 }

proc ::bench::write_items {file items files} {
    set fh [open $file w]
    fconfigure $fh -translation lf
    puts $fh [list $items $files]
    close $fh
}

# How many iterations is a millisecond on this box, right now. Measured rather
# than assumed, so "2 ms" means two milliseconds here and not on the machine the
# constant was written on.
proc ::bench::calibrate {} {
    workitem 200000
    set t [ms {::bench::workitem 400000}]
    return [expr {int(400000 / $t)}]
}

proc ::bench::report {label a arm} {
    lassign $arm med lo hi
    set sp [expr {$med > 0 ? $a / $med : 0}]
    puts [format "  %-22s %8.1f ms  (%.0f-%.0f)   %5.2fx" $label $med $lo $hi $sp]
    return $sp
}

set WIDTH 12
set REPS  3
set ITEMFILE [file join $::env(TEMP) bench_items_[pid].txt]
set PERMS [::bench::calibrate]
puts "calibration: [format %d $PERMS] iterations = 1 ms in this process"
puts "width $WIDTH, $REPS reps, median reported, first run discarded"

proc ::bench::void_check {name a other} {
    if {$a eq $other} { return 0 }
    puts "  !! $name DISAGREED with sequential -- void, not fast"
    return 1
}

# An optional first argument runs one workload only: the whole thing takes
# minutes, and re-running one section beats re-running all of them to look at a
# single number.
set ONLY [expr {[llength $argv] ? [lindex $argv 0] : "all"}]
proc want {name} { expr {$::ONLY eq "all" || $::ONLY eq $name} }

# --- workload 1: CPU-bound Tcl, four item sizes ------------------------------
if {[want cpu]} {
puts "\n=== CPU-bound Tcl work ==============================================="
foreach {targetms count} {0.5 1600 2 500 8 150 30 40} {
    set n [expr {int($targetms * $PERMS)}]
    set items [lrepeat $count $n]
    set files [lrepeat $count ""]
    ::bench::write_items $ITEMFILE $items $files

    puts [format "\n%.1f ms/item x %d items" $targetms $count]
    set base [::bench::arm_seq $items $files]
    set aA [::bench::measure $REPS {::bench::arm_seq $items $files}]
    ::bench::report "A sequential" [lindex $aA 0] $aA

    set rB1 [::bench::arm_child $items $files $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF]
    set aB1 [::bench::measure $REPS {::bench::arm_child $items $files $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF}]
    ::bench::void_check "B1 child-per-item" $base $rB1
    ::bench::report "B1 child per item" [lindex $aA 0] $aB1

    set rB2 [::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF]
    set aB2 [::bench::measure $REPS {::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF}]
    ::bench::void_check "B2 static chunks" $base $rB2
    ::bench::report "B2 static chunks" [lindex $aA 0] $aB2

    set rC [::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF]
    set aC [::bench::measure $REPS {::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF}]
    ::bench::void_check "C pool" $base $rC
    ::bench::report "C pool (pmap)" [lindex $aA 0] $aC
}

}

# --- workload 2: skewed item sizes, same total work --------------------------
# A tenth of the items cost 10x the rest, placed at random with a fixed seed.
# Random placement is the AVERAGE case for static chunking; clustered would be
# worse, so this understates the effect rather than dramatising it.
if {[want skew]} {
puts "\n=== skew: same total work, a tenth of the items 10x =================="
expr {srand(42)}
set count 500
set light [expr {int(1.05 * $PERMS)}]
set heavy [expr {$light * 10}]
set items {}
for {set i 0} {$i < $count} {incr i} {
    lappend items [expr {rand() < 0.1 ? $heavy : $light}]
}
set files [lrepeat $count ""]
::bench::write_items $ITEMFILE $items $files
puts [format "\n%d items, 1.05 ms and 10.5 ms mixed" $count]
set base [::bench::arm_seq $items $files]
set aA [::bench::measure $REPS {::bench::arm_seq $items $files}]
::bench::report "A sequential" [lindex $aA 0] $aA
set rB2 [::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF]
set aB2 [::bench::measure $REPS {::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF}]
::bench::void_check "B2 static chunks" $base $rB2
::bench::report "B2 static chunks" [lindex $aA 0] $aB2
set rC [::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF]
set aC [::bench::measure $REPS {::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF}]
::bench::void_check "C pool" $base $rC
::bench::report "C pool (pmap)" [lindex $aA 0] $aC

# THE SAME TOTAL WORK, CLUSTERED. The run above scattered the heavy items at
# random, and with ~42 items per chunk that self-averages: every chunk drew about
# the same number of them, so static chunking never met a straggler. That is the
# average case, not the case chunking fails. Real input is rarely shuffled -- a
# directory listing keeps the big files together, a sorted work list puts the
# expensive end last -- so here the heavy items sit in one contiguous run, which
# lands them in one or two chunks and leaves those children still working after
# the rest have gone idle.
set items {}
for {set i 0} {$i < $count} {incr i} {
    lappend items [expr {$i >= $count - 50 ? $heavy : $light}]
}
::bench::write_items $ITEMFILE $items $files
puts [format "\n%d items, the 50 heavy ones contiguous at the end" $count]
set base [::bench::arm_seq $items $files]
set aA [::bench::measure $REPS {::bench::arm_seq $items $files}]
::bench::report "A sequential" [lindex $aA 0] $aA
set rB2 [::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF]
set aB2 [::bench::measure $REPS {::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF}]
::bench::void_check "B2 static chunks" $base $rB2
::bench::report "B2 static chunks" [lindex $aA 0] $aB2
set rC [::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF]
set aC [::bench::measure $REPS {::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF}]
::bench::void_check "C pool" $base $rC
::bench::report "C pool (pmap)" [lindex $aA 0] $aC
}

# --- workload 3: an external program per item --------------------------------
# The archetype. Here B1 spawns findstr DIRECTLY -- no intermediate Tcl process
# at all -- which is the fairest version of the old way there is.
if {[want ext]} {
puts "\n=== an external program per item (findstr over a source file) ========"
set src {}
foreach pat {tcl/*.tcl src/*.c test/*.tcl tools/*.tcl} {
    foreach f [glob -nocomplain [file join [file dirname $::bench::SELF] .. .. $pat]] {
        lappend src [file normalize $f]
    }
}
set files {}
while {[llength $files] < 150} { foreach f $src { lappend files $f } }
set files [lrange $files 0 149]
set items [lrepeat [llength $files] x]
::bench::write_items $ITEMFILE $items $files
puts [format "\n%d items over %d distinct files" [llength $files] [llength $src]]
set base [::bench::arm_seq $items $files]
set aA [::bench::measure $REPS {::bench::arm_seq $items $files}]
::bench::report "A sequential" [lindex $aA 0] $aA
set rB1 [::bench::arm_child $items $files $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF]
set aB1 [::bench::measure $REPS {::bench::arm_child $items $files $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF}]
::bench::void_check "B1 child per item" $base $rB1
::bench::report "B1 child per item" [lindex $aA 0] $aB1
set rC [::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF]
set aC [::bench::measure $REPS {::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF}]
::bench::void_check "C pool" $base $rC
::bench::report "C pool (pmap)" [lindex $aA 0] $aC

}

# --- workload 4: is the ceiling real, or is it the floor? --------------------
# Across the four sizes above, the pool's WALL CLOCK barely moved -- 452, 374,
# 376, 379 ms -- while sequential ranged 741 to 997. That flatness looks like a
# fixed cost (twelve machteld starts at ~90 a second, plus teardown) dominating
# jobs that are only a second long, which would make the ~2.5x "ceiling" an
# artefact of short runs rather than a limit. If so, holding the item size fixed
# and growing the JOB should walk the speedup up toward what the cores can give.
#
# No discarded warm-up pass here, unlike the sections above: that pass exists for
# the file cache and the filter driver, and this workload touches no files. One
# small call warms the bytecode, which is all this needs -- and a discard pass at
# 32 seconds an arm would cost more than the measurement.
if {[want long]} {
puts "\n=== the same 8 ms item, total work from ~1s to ~32s =================="
proc ::bench::measure_nw {reps script} {
    set times {}
    for {set i 0} {$i < $reps} {incr i} {
        lappend times [uplevel 1 [list ::bench::ms $script]]
    }
    return [list [median $times] [tcl::mathfunc::min {*}$times] [tcl::mathfunc::max {*}$times]]
}
::bench::workitem 200000
set n [expr {int(8 * $PERMS)}]
foreach count {125 500 2000 4000} {
    set items [lrepeat $count $n]
    set files [lrepeat $count ""]
    ::bench::write_items $ITEMFILE $items $files
    puts [format "\n%d items x 8 ms = ~%.1f s of sequential work" $count [expr {$count * 8 / 1000.0}]]
    set base [::bench::arm_seq $items $files]
    set aA [::bench::measure_nw 2 {::bench::arm_seq $items $files}]
    ::bench::report "A sequential" [lindex $aA 0] $aA
    set rB2 [::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF]
    set aB2 [::bench::measure_nw 2 {::bench::arm_chunk $items $WIDTH $ITEMFILE $::bench::EXE $::bench::SELF}]
    ::bench::void_check "B2 static chunks" $base $rB2
    ::bench::report "B2 static chunks" [lindex $aA 0] $aB2
    set rC [::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF]
    set aC [::bench::measure_nw 2 {::bench::arm_pool $items $files $WIDTH $::bench::EXE $::bench::SELF}]
    ::bench::void_check "C pool" $base $rC
    ::bench::report "C pool (pmap)" [lindex $aA 0] $aC
}
}

file delete -force $ITEMFILE
puts "\ndone."
