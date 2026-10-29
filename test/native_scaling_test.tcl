# Measured, deliberately bounded worker scaling; timing is observational, not
# a fragile CI performance gate. No platform-wide tracing/settings are used.
# Invoke: machteld.exe test/native_scaling_test.tcl native_probe.dll process_fixture.exe
package require machteld
if {[llength $argv] != 2} {error "usage: native_scaling_test.tcl native_probe.dll process_fixture.exe"}
load [file normalize [lindex $argv 0]] Nativeprobe
set FIXTURE [file normalize [lindex $argv 1]]
set WORKER [file join [file dirname [file normalize [info script]]] fixtures worker_program.tcl]
set checks 0
set fails 0
proc check {name value} {
    incr ::checks
    if {$value} {puts "ok   $name"} else {incr ::fails; puts "FAIL $name"}
}
proc sample_idle {mode width} {
    after 100
    # Thread snapshots enumerate the machine and can consume tens of ms. Keep
    # that bookkeeping outside the timed window; endpoints use only target
    # process counters, avoiding a misleading telemetry-induced idle CPU cost.
    set inventory [native_metrics]
    set first [native_cpu]
    set started [clock microseconds]
    after 1000
    set last [native_cpu]
    set wall [expr {[clock microseconds]-$started}]
    set cpu [expr {[dict get $last cpu_us]-[dict get $first cpu_us]}]
    puts [list SCALING mode $mode width $width wall_us $wall host_cpu_us $cpu \
        core_percent [format %.3f [expr {100.0*$cpu/$wall}]] \
        host_handles [dict get $last handles] host_threads [dict get $inventory threads] \
        host_private_bytes [dict get $last private_bytes] host_working_set [dict get $last working_set] \
        host_cycles [expr {[dict get $last cycles]-[dict get $first cycles]}]]
}
set baseline [native_metrics]
try {
    sample_idle baseline 0
    # Channels use one monitor plus Tcl's pipe helper threads per worker;
    # capture owns one monitor, two drains and two 1 MiB capture allocations.
    # GetProcessTimes has coarse scheduler accounting: zero does not mean zero
    # work. QueryProcessCycleTime is reported without guessing CPU frequency.
    # These measurements
    # include the read-only telemetry call and Windows scheduling noise.
    foreach mode {channels capture} {
        foreach width {1 8 32} {
            set tokens {}
            set start [clock microseconds]
            for {set n 0} {$n < $width} {incr n} {
                set opts [expr {$mode eq "channels" ? {-channels} : {}}]
                lappend tokens [child start {*}$opts -timeout 10s -- $FIXTURE hang 10000]
            }
            puts [list SCALING mode $mode width $width launch_us [expr {[clock microseconds]-$start}]]
            sample_idle $mode $width
            set all_running 1
            foreach token $tokens {
                if {![dict get [child info $token] running]} {set all_running 0}
            }
            check "$mode width $width is live throughout sample" $all_running
            set start [clock microseconds]
            foreach token $tokens {child close $token}
            puts [list SCALING mode $mode width $width close_us [expr {[clock microseconds]-$start}]]
            check "$mode width $width fully closes" [expr {[child list] eq {}}]
        }
    }
    # Measure actual JSONL pool request/response throughput separately from
    # process startup, and test ordered results at all observed widths.
    foreach width {1 8 32} {
        set start [clock microseconds]
        set pool [pool create -width $width -- [info nameofexecutable] $WORKER]
        set launch [expr {[clock microseconds]-$start}]
        try {
            set requests {}
            for {set n 0} {$n < 128} {incr n} {lappend requests [dict create op echo text $n]}
            set start [clock microseconds]
            pool submit $pool $requests
            set replies [pool wait $pool -timeout 10s]
            set wall [expr {[clock microseconds]-$start}]
            set ordered [expr {[llength $replies] == 128}]
            for {set n 0} {$n < [llength $replies]} {incr n} {
                if {[dict get [lindex $replies $n] result] ne "$n"} {set ordered 0}
            }
            check "pool width $width delivers 128 ordered replies" $ordered
            puts [list SCALING mode pool width $width launch_us $launch requests 128 \
                batch_us $wall requests_per_second [format %.1f [expr {128000000.0/max(1,$wall)}]]]
        } finally {pool close $pool}
    }
    after 200
    set final [native_metrics]
    puts [list SCALING baseline $baseline final $final]
    check "scaling run returns to bounded handle baseline" [expr {
        [dict get $final handles] <= [dict get $baseline handles] + 12}]
    check "scaling run leaves no registered children" [expr {[child list] eq {}}]
} finally {
    if {[info exists pool]} {catch {pool close $pool}}
    foreach token [child list] {catch {child close $token}}
}
puts "$checks native scaling checks; $fails failures"
exit [expr {$fails != 0}]
