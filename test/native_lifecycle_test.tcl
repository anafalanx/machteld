# Bounded native ownership/teardown regressions. No GUI, network, or installers.
# Invoke: machteld.exe test/native_lifecycle_test.tcl native_probe.dll process_fixture.exe
package require machteld
if {[llength $argv] != 2} {error "usage: native_lifecycle_test.tcl native_probe.dll process_fixture.exe"}
load [file normalize [lindex $argv 0]] Nativeprobe
set FIXTURE [file normalize [lindex $argv 1]]
set WORK [file join $env(TEMP) machteld-lifecycle-[pid]-[clock clicks]]
file mkdir $WORK
set fails 0
set checks 0
proc check {name value} {
    incr ::checks
    if {$value} {puts "ok   $name"} else {incr ::fails; puts "FAIL $name"}
}
proc dead {id {timeout 3000}} {
    set deadline [expr {[clock milliseconds] + $timeout}]
    while {[clock milliseconds] < $deadline} {
        if {[catch {native_metrics $id} value] || ![dict get $value alive]} {return 1}
        after 10
    }
    return 0
}
proc registries_empty {} {
    expr {[child list] eq {} && [watch list] eq {} && [pty list] eq {}}
}
proc closing_transform {token method channel args} {
    switch -- $method {
        initialize {return {initialize finalize write}}
        finalize {
            set caught [catch {child close $token} message options]
            set ::recursive_close [list $caught [dict get $options -errorcode]]
        }
        write {return [lindex $args 0]}
    }
}
proc cycle {round} {
    set result [run -timeout 2s -stdin [string repeat x 16384] -- $::FIXTURE stdin-echo]
    if {[dict get $result status] ne "ok" || [string length [dict get $result out]] != 16384} {
        error "stdin/capture cycle $round failed: $result"
    }
    set token [child start -channels -timeout 2s -- $::FIXTURE hang 10000]
    set id [dict get [child info $token] pid]
    set streams [child info $token]
    # Exercise both Tcl-first and child-first channel cleanup.
    if {$round % 2} {
        foreach key {stdin stdout stderr} {close [dict get $streams $key]}
    }
    child kill $token
    child close $token
    if {![dead $id]} {error "cancelled child $id survived cycle $round"}
    set token [child start -timeout 0ms -- $::FIXTURE hang 10000]
    set result [child wait $token -timeout 2s]
    child close $token
    if {[dict get $result status] ne "timeout"} {error "deadline cycle failed: $result"}
    # A finite stdin writer blocked on a child which never reads must be joined
    # after cancellation too; otherwise each repetition retains a thread/buffer.
    if {$round % 4 == 0} {
        set token [child start -stdin [string repeat x 131072] -timeout 2s -- $::FIXTURE hang 10000]
        set id [dict get [child info $token] pid]
        child close $token
        if {![dead $id]} {error "blocked stdin child $id survived close"}
    }
    # Failure after pipes/job allocation must also release every handle.
    set caught [catch {child start -dir [file join $::WORK absent] -- $::FIXTURE ok x} msg opts]
    if {!$caught || [dict get $opts -errorcode] ne {MACHTELD CHILD launch}} {
        error "expected native launch failure: $msg"
    }
    set watcher [watch start $::WORK]
    set file [open [file join $::WORK watch-event.txt] w]
    puts $file $round
    close $file
    watch read $watcher -timeout 1s
    watch close $watcher
    if {![registries_empty]} {error "resource registry not empty after cycle $round"}
}

try {
    # Tcl's pipe allocator normally reuses these names immediately. Retrying is
    # bounded, and failure to exercise reuse is not silently treated as a pass.
    set reused 0
    set intact 1
    for {set attempt 0} {$attempt < 64 && !$reused} {incr attempt} {
        set first [child start -channels -timeout 5s -- $FIXTURE hang 10000]
        set old [child info $first]
        foreach key {stdin stdout stderr} {close [dict get $old $key]}
        set second [child start -channels -timeout 5s -- $FIXTURE hang 10000]
        set current [child info $second]
        foreach key {stdin stdout stderr} {
            if {[dict get $old $key] in [chan names]} {incr reused}
        }
        child close $first
        foreach key {stdin stdout stderr} {
            if {[dict get $current $key] ni [chan names]} {set intact 0}
        }
        child close $second
    }
    check "fixture exercises recycled Tcl channel names" [expr {$reused > 0}]
    check "closing old child never closes another child's recycled channels" $intact

    # Explicit channel transfer is legitimate Tcl ownership: deleting the
    # original child must not unregister a channel from the receiving interp.
    set receiver [interp create]
    set token [child start -channels -timeout 5s -- $FIXTURE hang 10000]
    set channel [dict get [child info $token] stdout]
    interp transfer {} $channel $receiver
    child close $token
    check "transferred channel remains owned by receiving interpreter" \
        [expr {$channel in [interp eval $receiver {chan names}]}]
    interp delete $receiver

    # A reflected transform can run arbitrary Tcl in its finalize callback.
    # Unpublish the token before closing channels; the old order freed the
    # child reentrantly and crashed the process with an access violation.
    set recursive_close {}
    set token [child start -channels -timeout 5s -- $FIXTURE hang 10000]
    chan push [dict get [child info $token] stdin] [list closing_transform $token]
    child close $token
    check "channel-finalize callback cannot recursively free its child" \
        [expr {$recursive_close eq {1 {MACHTELD CHILD nohandle}}}]
    check "reentrant close leaves no registered child" [expr {[child list] eq {}}]

    # Warm all exercised paths before comparing checkpoints. Handle/thread
    # deltas are gating; allocator/RSS observations have generous high-water
    # budgets and are trend evidence, not a claim that all leaks are impossible.
    for {set n 0} {$n < 8} {incr n} {cycle $n}
    after 100
    set baseline [native_metrics]
    puts "LIFECYCLE warmup $baseline"
    set samples {}
    for {set block 0} {$block < 4} {incr block} {
        for {set n 0} {$n < 16} {incr n} {cycle [expr {$block * 16 + $n}]}
        after 100
        set sample [native_metrics]
        lappend samples $sample
        puts "LIFECYCLE checkpoint [expr {($block+1)*16}] $sample"
        check "checkpoint $block bounds handle growth" [expr {
            [dict get $sample handles] <= [dict get $baseline handles] + 8}]
        check "checkpoint $block bounds surviving thread growth" [expr {
            [dict get $sample threads] <= [dict get $baseline threads] + 4}]
        check "checkpoint $block bounds private commit growth" [expr {
            [dict get $sample private_bytes] <= [dict get $baseline private_bytes] + 8*1024*1024}]
        check "checkpoint $block bounds working-set growth" [expr {
            [dict get $sample working_set] <= [dict get $baseline working_set] + 16*1024*1024}]
    }
    check "72 repeated mixed cycles leave no registered resources" [registries_empty]

    # Repeated interpreter destruction while child jobs, Tcl channels, and a
    # watcher are live. No callback evaluation during native teardown is needed.
    set before [native_metrics]
    for {set n 0} {$n < 24} {incr n} {
        set slave [interp create]
        interp eval $slave {load {} machteldproc}
        set token [interp eval $slave [list ::machteld::child start -channels -timeout 5s -- $FIXTURE hang 10000]]
        set id [dict get [interp eval $slave [list ::machteld::child info $token]] pid]
        interp eval $slave [list ::machteld::watch start $WORK]
        interp delete $slave
        if {![dead $id]} {error "deleted interpreter left child $id alive"}
    }
    after 100
    set after [native_metrics]
    puts "LIFECYCLE interpreter-before $before"
    puts "LIFECYCLE interpreter-after $after"
    check "24 interpreter deletions release process/channel/watch handles" [expr {
        [dict get $after handles] <= [dict get $before handles] + 8}]
    check "24 interpreter deletions release monitor/watch threads" [expr {
        [dict get $after threads] <= [dict get $before threads] + 4}]

    # Small repeated ConPTY creation/close lane. No GUI is created, and no
    # interactive byte pumping or focus manipulation is involved.
    for {set n 0} {$n < 2} {incr n} {
        set token [pty spawn -- $FIXTURE hang 10000]
        pty close $token
    }
    after 100
    set before [native_metrics]
    for {set n 0} {$n < 8} {incr n} {
        set token [pty spawn -- $FIXTURE hang 10000]
        set id [dict get [pty info $token] pid]
        pty close $token
        if {![dead $id]} {error "closed pseudo-console left child $id alive"}
    }
    after 100
    set after [native_metrics]
    puts "LIFECYCLE pty-before $before"
    puts "LIFECYCLE pty-after $after"
    check "repeated ConPTY close releases handles" [expr {
        [dict get $after handles] <= [dict get $before handles] + 8}]
    check "repeated ConPTY close releases drain threads" [expr {
        [dict get $after threads] <= [dict get $before threads] + 4}]
    check "final native registries are empty" [registries_empty]
} finally {
    foreach token [child list] {catch {child close $token}}
    foreach token [watch list] {catch {watch close $token}}
    foreach token [pty list] {catch {pty close $token}}
    foreach slave [interp slaves] {catch {interp delete $slave}}
    file delete -force $WORK
}
puts "$checks native lifecycle checks; $fails failures"
exit [expr {$fails != 0}]
