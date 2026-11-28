package require machteld

set here [file dirname [file normalize [info script]]]
set timings 0
set checkedCollections 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -exact -- [lindex $argv $i] {
        --timings {set timings 1}
        --checked-collections {set checkedCollections 1}
        --embedded {
            if {[info exists compiler]} {error "select the compiler once"}
            set compiler [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler {
            if {[info exists compiler]} {error "select the compiler once"}
            if {[incr i] >= [llength $argv]} {error "--compiler requires the compiler directory"}
            set compiler [lindex $argv $i]
        }
        --compare-with {
            if {[incr i] >= [llength $argv]} {error "--compare-with requires a baseline compiler directory"}
            set baseline [lindex $argv $i]
            set timings 1
        }
        default {error "usage: run.tcl ?--embedded | --compiler directory? ?--timings? ?--compare-with baselineDirectory? ?--checked-collections?"}
    }
}
if {![info exists compiler]} {set compiler [file join $here .. .. .. packages application-compiler]}
source -encoding utf-8 [file join $here reference.tcl]
source -encoding utf-8 [file join $here cases.tcl]
set ch [open [file join $here kernels.src] r]
try {
    chan configure $ch -encoding utf-8
    set sources [dict create kernels [read $ch]]
} finally {close $ch}

# Compile each revision in a fresh interpreter, then execute its generated code
# in the same host and timing thread as the other implementations.
proc loadKernels {directory sources target} {
    set build [interp create]
    try {
        $build eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set built [$build eval [list ::appcompiler::compile $sources $target]]
    } finally {interp delete $build}
    namespace eval :: [dict get $built script]
}
loadKernels $compiler $sources ::corpus
set implementations [dict create Tcl ::hand X ::corpus::kernels]
set orders {{Tcl X} {X Tcl}}
if {[info exists baseline]} {
    loadKernels $baseline $sources ::previous
    dict set implementations baseline ::previous::kernels
    # All six permutations balance position and preceding implementation.
    set orders {{Tcl X baseline} {X baseline Tcl} {baseline Tcl X}
                {Tcl baseline X} {baseline X Tcl} {X Tcl baseline}}
}

proc verify {kernel command expected} {
    set actual [{*}$command]
    switch -exact -- $kernel {
        histogram - snapshot {
            if {[dict size $actual] != [dict size $expected]} {error "$kernel returned the wrong number of keys"}
            dict for {key value} $expected {
                if {![dict exists $actual $key] || [dict get $actual $key] ne $value} {
                    error "$kernel disagrees at key [list $key]"
                }
            }
        }
        merge_sorted - compact_ids - window_readings - reconcile - json_intake {
            if {[llength $actual] != [llength $expected]} {error "$kernel returned the wrong number of items"}
            set i 0
            foreach got $actual want $expected {
                if {$got ne $want} {error "$kernel disagrees at element $i"}
                incr i
            }
        }
        default {
            if {$actual ne $expected} {error "$kernel returned [list $actual], expected [list $expected]"}
        }
    }
}

proc sample {command calls} {
    return [lindex [time {{*}$command} $calls] 0]
}

# Different implementations need different batch sizes to collect useful samples.
proc batchSize {command} {
    set calls 1
    while {1} {
        set perCall [sample $command $calls]
        if {$perCall * $calls >= 20000} {return $calls}
        set calls [expr {min(8 * $calls, max($calls + 1, int(ceil(30000 / max($perCall, 0.001)))))}]
    }
}

set goldenCount 0
if {$checkedCollections} {
    source -encoding utf-8 [file join $here checked-collections.tcl]
}
foreach {kernel arguments expected} [goldenCases] {
    dict for {impl prefix} $implementations {
        verify $kernel [list ${prefix}::$kernel {*}$arguments] $expected
    }
    if {$checkedCollections && $kernel in {histogram merge_sorted}} {
        verify $kernel [list ::checkedCollections::$kernel {*}$arguments] $expected
    }
    incr goldenCount
}
set cases [timedCases]
if {$timings} {puts [join {kind workload implementation round calls microseconds_per_call} \t]}
dict for {kernel arguments} $cases {
    if {$checkedCollections && $kernel ni {histogram merge_sorted}} continue
    set commands {}
    dict for {impl prefix} $implementations {dict set commands $impl [list ${prefix}::$kernel {*}$arguments]}
    set trialOrders $orders
    if {$checkedCollections} {
        dict set commands checked [list ::checkedCollections::$kernel {*}$arguments]
        if {[dict exists $commands baseline]} {
            # Each implementation occupies every position equally and follows
            # each of the others equally often.
            set trialOrders {{Tcl X checked baseline} {X baseline Tcl checked}
                {baseline checked X Tcl} {checked Tcl baseline X}}
        } else {
            set trialOrders {{Tcl X checked} {X checked Tcl} {checked Tcl X}
                {Tcl checked X} {checked X Tcl} {X Tcl checked}}
        }
    }
    set expected [{*}[dict get $commands Tcl]]
    verify $kernel [dict get $commands X] $expected
    if {[info exists baseline]} {verify $kernel [dict get $commands baseline] $expected}
    if {$checkedCollections} {verify $kernel [dict get $commands checked] $expected}
    if {!$timings} continue

    dict for {impl command} $commands {
        set calls($impl) [batchSize $command]
        set samples($impl) {}
    }
    for {set round 1} {$round <= 12} {incr round} {
        set order [lindex $trialOrders [expr {($round-1) % [llength $trialOrders]}]]
        foreach impl $order {
            set us [sample [dict get $commands $impl] $calls($impl)]
            lappend samples($impl) $us
            puts [join [list sample $kernel $impl $round $calls($impl) [format %.6f $us]] \t]
        }
    }
    dict for {impl command} $commands {
        verify $kernel $command $expected
        lassign [lrange [lsort -real $samples($impl)] 5 6] lower upper
        puts [join [list median $kernel $impl - $calls($impl) [format %.6f [expr {($lower + $upper) / 2.0}]]] \t]
    }
}
if {!$timings} {
    set count [expr {$checkedCollections ? 2 : [dict size $cases]}]
    puts "compiler workload corpus: $goldenCount fixed cases and $count full workloads passed"
}
