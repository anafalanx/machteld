# Focused native streaming regressions. No compiler or build is invoked here.
# machteld.exe test/streaming_bounds_test.tcl process_fixture.exe
package require machteld
if {[llength $argv] != 1} {error {usage: streaming_bounds_test.tcl process_fixture.exe}}
set fixture [file normalize [lindex $argv 0]]
set failures 0
set checks 0
proc check {name value} {
    incr ::checks
    if {$value} {puts "ok   $name"} else {puts "FAIL $name"; incr ::failures}
}
proc count_line {stream line} {
    incr ::counts($stream)
    set ::lengths($stream) [string length $line]
}
foreach stream {out err} {
    foreach ending {lf eof} {
        set counts($stream) 0
        set result [run -timeout 20s -on$stream [list count_line $stream] -- \
            $fixture stream-line 16777216 $ending $stream]
        check "exact 16 MiB $stream line at $ending stays one callback" [expr {
            [dict get $result status] eq "ok" && $counts($stream) == 1 &&
            $lengths($stream) == 16777216}]
        set counts($stream) 0
        set caught [catch {run -timeout 20s -on$stream [list count_line $stream] -- \
            $fixture stream-line 16777217 $ending $stream} message options]
        check "oversized $stream line at $ending fails without partial callback" [expr {
            $caught && [dict get $options -errorcode] eq {MACHTELD RUN limit} &&
            $counts($stream) == 0}]
    }
}
set counts(out) 0
set result [run -timeout 20s -onout {count_line out} -- $fixture stream-line 16777215 crlf out]
check "CR counts toward the byte bound but is stripped from callback" [expr {
    [dict get $result status] eq "ok" && $counts(out) == 1 && $lengths(out) == 16777215}]
set counts(out) 0
set caught [catch {run -timeout 20s -onout {count_line out} -- \
    $fixture stream-line 16777216 crlf out} message options]
check "CR exceeding the bound fails before delivery" [expr {
    $caught && [dict get $options -errorcode] eq {MACHTELD RUN limit} && $counts(out) == 0}]
set lines {}
run -onout {lappend ::lines} -- $fixture stream-split
check "split UTF-8, CRLF and trailing EOF keep line semantics" [expr {
    $lines eq [list "hë世😀" tail]}]
set caught [catch {run -onout {lappend ::lines} -- $fixture stream-invalid} message options]
check "incomplete UTF-8 at EOF is explicit failure" [expr {
    $caught && [dict get $options -errorcode] eq {MACHTELD RUN badvalue}}]

# Intentionally slow callbacks exercise pipe backpressure on both streams.
proc slow_line {stream line} {count_line $stream $line; after 1}
set counts(out) 0
set counts(err) 0
set result [run -timeout 20s -onout {slow_line out} -onerr {slow_line err} -- $fixture stream-bursts]
check "stdout and stderr bursts both drain under slow consumers" [expr {
    [dict get $result status] eq "ok" && $counts(out) == 256 && $counts(err) == 256 &&
    $lengths(out) == 4095 && $lengths(err) == 4095}]

set work [file join $::env(TEMP) machteld-stream-[pid]-[clock clicks]]
file mkdir $work
try {
    set rootfile [file join $work root.pid]
    set leaffile [file join $work leaf.pid]
    set before [child list]
    set caught [catch {run -timeout 20s -env [list MACHTELD_TEST_PIDFILE $rootfile] \
        -onout {count_line out} -onerr {count_line err} -- \
        $fixture stream-overflow-tree $leaffile} message options]
    check "overflow terminates supervised tree" [expr {
        $caught && [dict get $options -errorcode] eq {MACHTELD RUN limit}}]
    foreach path [list $rootfile $leaffile] {
        set ch [open $path r]
        try {set childpid [read $ch]} finally {close $ch}
        check "overflow leaves no process from [file tail $path]" [catch {mtps info $childpid}]
    }
    check "overflow leaves registry unchanged" [expr {[child list] eq $before}]
    proc failing_line {line} {return -code error -errorcode {TEST ORIGINAL callback} {callback sentinel}}
    set caught [catch {run -timeout 10s -onout failing_line -- $fixture stream-bursts} message options]
    check "callback failure survives cleanup unchanged" [expr {
        $caught && $message eq "callback sentinel" &&
        [dict get $options -errorcode] eq {TEST ORIGINAL callback}}]
} finally {
    file delete -force $work
}
check "runtime metadata advertises exact stream bounds" [expr {
    [dict get [manifest] run limits callback_line_bytes] == 16777216 &&
    [dict get [manifest] run limits pump_bytes_per_stream] == 8192 &&
    "limit" in [dict get [manifest] run codes]}]
puts "streaming bounds: $checks checks, $failures failures"
exit [expr {$failures != 0}]
