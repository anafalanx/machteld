# Focused process-supervision regression suite.
#
# Invoke through the host, not tclsh:
#   out/machteld.exe test/process_test.tcl out/test/process_fixture.exe

package require machteld

if {[llength $argv] != 1} {
    puts stderr "usage: process_test.tcl process_fixture.exe"
    exit 2
}

set MT [info nameofexecutable]
set HERE [file dirname [file normalize [info script]]]
set FIXTURE [file normalize [lindex $argv 0]]
if {![file executable $FIXTURE]} {
    puts stderr "process fixture is not executable: $FIXTURE"
    exit 2
}

set WORK [file join $env(TEMP) machteld-process-test-[pid]]
file delete -force $WORK
file mkdir $WORK

set fails 0
proc check {name condition} {
    if {$condition} {
        puts "ok   $name"
    } else {
        incr ::fails
        puts "FAIL $name"
    }
}
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} message options] == 0} { return {} }
    return [dict get $options -errorcode]
}
proc slurp {path} {
    set channel [open $path rb]
    set value [read $channel]
    close $channel
    return $value
}
proc wait_for_file {path {milliseconds 4000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        if {[file exists $path] && [file size $path] > 0} { return 1 }
        after 25
    }
    return 0
}
proc wait_for_dead {process_id {milliseconds 4000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        if {[catch {mtps info $process_id}]} { return 1 }
        after 25
    }
    return 0
}
proc own_handle_count {} {
    set result [run -- $::FIXTURE handle-count [pid]]
    set value [string trim [dict get $result out]]
    if {[dict get $result status] ne "ok" ||
            ![string is integer -strict $value]} {
        return -1
    }
    return $value
}

# Ordinary results, Unicode argv, full-width exit codes, and callbacks form one
# compact supervision contract.
set result [run -- $FIXTURE ok "hëllö 世界"]
check "run captures Unicode stdout bytes" [expr {
    [encoding convertfrom utf-8 [dict get $result out]] eq "hëllö 世界"}]
check "run captures Unicode stderr bytes" [expr {
    [encoding convertfrom utf-8 [dict get $result err]] eq "E:hëllö 世界"}]
check "run status is ok" [expr {[dict get $result status] eq "ok" &&
                                      [dict get $result exit] == 0}]

set result [run -- $FIXTURE fail payload]
check "nonzero exit is preserved" [expr {[dict get $result exit] == 7 &&
                                           [dict get $result status] eq "error"}]

# A caller-supplied Unicode environment block must preserve unrelated inherited
# entries, replace names case-insensitively, and sort the complete merged block
# in Windows' case-insensitive ordinal order. The fixture validates every entry
# in its raw GetEnvironmentStringsW block and prints these probes in block order;
# reverse option order makes a mere append implementation fail visibly.
set ::env(MACHTELD_ENV_INHERITED) inherited
set ::env(MACHTELD_ENV_REPLACED) parent
set result [run -env [list \
    ZZZ_MACHTELD_ENV end \
    machteld_env_replaced overridden \
    MMM_MACHTELD_ENV middle \
    AAA_MACHTELD_ENV begin] -- \
    $FIXTURE environment-order \
    AAA_MACHTELD_ENV MACHTELD_ENV_INHERITED MACHTELD_ENV_REPLACED \
    MMM_MACHTELD_ENV ZZZ_MACHTELD_ENV]
unset ::env(MACHTELD_ENV_INHERITED) ::env(MACHTELD_ENV_REPLACED)
check "custom environment is merged, overridden, and ordinally sorted" [expr {
    [dict get $result status] eq "ok" &&
    [split [string trim [dict get $result out]] "\n"] eq [list \
        AAA_MACHTELD_ENV=begin \
        MACHTELD_ENV_INHERITED=inherited \
        machteld_env_replaced=overridden \
        MMM_MACHTELD_ENV=middle \
        ZZZ_MACHTELD_ENV=end]
}]

set ::callback_lines {}
set result [run -onout {lappend ::callback_lines} -- cmd /c "echo one&echo two"]
check "run stdout callback remains supported" [expr {$::callback_lines eq {one two}}]
check "callback-owned stdout is not also buffered" [expr {[dict get $result out] eq ""}]

# Default capture is deliberately bounded rather than an accidental unbounded
# allocation surface. Both readers must keep draining after their retained
# prefix fills, and the result must disclose each truncated stream.
set result [run -- $FIXTURE flood-capture]
check "run retains exactly 1 MiB of each captured stream" [expr {
    [string length [dict get $result out]] == 1048576 &&
    [string length [dict get $result err]] == 1048576}]
check "run discloses both truncated streams" [expr {
    [dict get $result truncated] eq {out err}}]
check "run retains the first bytes of truncated streams" [expr {
    [string index [dict get $result out] end] eq "O" &&
    [string index [dict get $result err] end] eq "E"}]

# A payload substantially larger than an anonymous pipe buffer exercises the
# write/read interlock and short WriteFile completions. Exact echoing also makes
# truncation or an early stdin close visible.
set input [string repeat 0123456789abcdef 24576]
set result [run -stdin $input -- $FIXTURE stdin-echo]
check "large stdin is written completely" [expr {[dict get $result out] eq $input}]
check "large stdin byte count is exact" [expr {
    [string trim [dict get $result err]] eq "BYTES:[string length $input]"}]

# Channel mode gives EOF ownership to the caller. Closing stdin after the last
# request lets an EOF-driven child finish; wait itself deliberately does not
# close a protocol channel behind the caller's back.
set token [child start -channels -- $FIXTURE stdin-echo]
set channels [child info $token]
set channel_input [binary format H* 000180ff4142007f]
puts -nonewline [dict get $channels stdin] $channel_input
flush [dict get $channels stdin]
chan close [dict get $channels stdin]
set result [child wait $token -timeout 5s]
set channel_out [read [dict get $channels stdout]]
set channel_err [read [dict get $channels stderr]]
check "closing child channel stdin delivers EOF and permits completion" [expr {
    [dict get $result status] eq "ok"}]
check "channel-mode stdin/stdout preserve arbitrary bytes" [expr {
    [binary encode hex $channel_out] eq [binary encode hex $channel_input]}]
check "channel child reports exact input byte count" [expr {
    [string trim $channel_err] eq "BYTES:8"}]
child close $token

# A caller's observation timeout is not a process deadline. A short wait must
# return a running snapshot and leave the supervised job alive.
set token [child start -- $FIXTURE hang 5000]
set child_pid [dict get [child info $token] pid]
set result [child wait $token -timeout 50ms]
check "child wait timeout returns a running snapshot" [expr {
    [dict get $result status] eq "running"}]
check "child wait timeout does not kill the child" [expr {
    ![catch {mtps info $child_pid}]}]
child kill $token
child wait $token
set close_result [child close $token]
check "child close is successful best-effort teardown" [expr {
    $close_result eq "" && $token ni [child list]}]
check "child close rejects an already-released token" [expr {
    [errcode_of [list child close $token]] eq {MACHTELD CHILD nohandle}}]

# The archived run-probe failure: the direct parent exits while its descendant
# retains both capture-pipe write handles. Without a timeout, run owns the whole
# job and therefore waits for EOF and returns the descendant's output.
set descendant_pidfile [file join $WORK descendant-no-timeout.pid]
set started [clock milliseconds]
set result [run -- $FIXTURE descendant-parent 900 $descendant_pidfile]
set elapsed [expr {[clock milliseconds] - $started}]
check "run waits for descendant-held stdout/stderr" [expr {$elapsed >= 650 && $elapsed < 5000}]
check "descendant stdout reaches the result" [string match *DESCENDANT-OUT* [dict get $result out]]
check "descendant stderr reaches the result" [string match *DESCENDANT-ERR* [dict get $result err]]
check "descendant PID was reported" [wait_for_file $descendant_pidfile]
set descendant_pid [expr {[file exists $descendant_pidfile] ? [string trim [slurp $descendant_pidfile]] : ""}]
check "completed descendant is dead" [expr {$descendant_pid ne "" && [wait_for_dead $descendant_pid]}]

# With a timeout, the same held pipes must not make run wait for natural EOF.
# The timeout kills the entire job and retains output written before the kill.
set descendant_pidfile [file join $WORK descendant-timeout.pid]
set started [clock milliseconds]
set result [run -timeout 500ms -- $FIXTURE descendant-parent 5000 $descendant_pidfile]
set elapsed [expr {[clock milliseconds] - $started}]
check "descendant-held pipes honor run timeout" [expr {$elapsed >= 300 && $elapsed < 3000}]
check "descendant-held pipe reports timeout" [expr {[dict get $result status] eq "timeout"}]
check "tree timeout keeps the already-exited root process code" [expr {
    [dict get $result exit] == 0}]
check "pre-timeout stdout is retained" [string match *PARENT-OUT* [dict get $result out]]
check "pre-timeout stderr is retained" [string match *PARENT-ERR* [dict get $result err]]
check "timed descendant PID was reported" [wait_for_file $descendant_pidfile]
set descendant_pid [expr {[file exists $descendant_pidfile] ? [string trim [slurp $descendant_pidfile]] : ""}]
check "run timeout kills the descendant" [expr {$descendant_pid ne "" && [wait_for_dead $descendant_pid]}]

# A child-start deadline is autonomous. Deliberately do not call child list,
# info, wait, or the generic wait command until well after the deadline.
set child_pidfile [file join $WORK autonomous-child.pid]
set token [child start -timeout 450ms -env [list MACHTELD_TEST_PIDFILE $child_pidfile] -- \
           $FIXTURE hang 5000]
check "autonomous child reports its PID" [wait_for_file $child_pidfile]
set child_pid [expr {[file exists $child_pidfile] ? [string trim [slurp $child_pidfile]] : ""}]
after 1300
check "child deadline fires without observation" [expr {$child_pid ne "" && [wait_for_dead $child_pid]}]
set result [child wait $token]
check "autonomous deadline reason survives" [expr {[dict get $result status] eq "timeout"}]
child close $token

# Exact ensemble dispatch and arity prevent accidental expansion when a new
# subcommand shares a prefix. All three ensembles use their own error domain.
foreach {name script expected} {
    "child rejects abbreviated subcommand" {child sta -- cmd /c exit 0} {MACHTELD CHILD usage}
    "child list has exact arity" {child list extra} {MACHTELD CHILD usage}
    "child info requires a token" {child info} {MACHTELD CHILD usage}
    "pty rejects abbreviated subcommand" {pty sp -- cmd /c exit 0} {MACHTELD PTY usage}
    "pty rejects unknown subcommand" {pty teleport} {MACHTELD PTY usage}
    "pty list has exact arity" {pty list extra} {MACHTELD PTY usage}
    "pty send requires token and bytes" {pty send} {MACHTELD PTY usage}
    "watch rejects abbreviated subcommand" {watch sta .} {MACHTELD WATCH usage}
    "watch list has exact arity" {watch list extra} {MACHTELD WATCH usage}
    "watch info requires a token" {watch info} {MACHTELD WATCH usage}
} {
    check $name [expr {[errcode_of $script] eq $expected}]
}

# Options outside each command's implemented contract must be errors, never
# accepted no-ops. `run` keeps callbacks; asynchronous child, detach and PTY do
# not pretend to implement them.
foreach {name script expected} [list \
    "child rejects run-only callback" [list child start -onout puts -- $FIXTURE ok x] {MACHTELD CHILD usage} \
    "detach rejects run-only timeout" [list detach -timeout 1s -- $FIXTURE ok x] {MACHTELD DETACH usage} \
    "pty rejects run-only stdin" [list pty spawn -stdin x -- $FIXTURE ok x] {MACHTELD PTY usage}] {
    check $name [expr {[errcode_of $script] eq $expected}]
}

check "wait -any requires handles" [expr {
    [errcode_of {wait -any}] eq {MACHTELD WAIT usage}}]
check "wait rejects unknown handle" [expr {
    [errcode_of {wait -any child#999999}] eq {MACHTELD WAIT nohandle}}]

# A detached child either demonstrably escapes a nested launcher's job and
# writes after that launcher exits, or the nested launch is rejected. Returning
# a PID for a silently attached process is the forbidden third outcome.
set marker [file join $WORK daemon.marker]
set launcher [file join $WORK detach-launcher.tcl]
set channel [open $launcher w]
puts $channel {package require machteld}
puts $channel {
    if {[catch {
        detach -- [lindex $argv 0] daemon-marker [lindex $argv 1] 800
    } result options]} {
        puts "DETACH-DENIED:[dict get $options -errorcode]"
        exit 3
    }
    puts "DETACH-OK:$result"
}
close $channel
set started [clock milliseconds]
set outer [run -- $MT $launcher $FIXTURE $marker]
set launcher_elapsed [expr {[clock milliseconds] - $started}]
if {[dict get $outer status] eq "ok"} {
    set output [string trim [dict get $outer out]]
    set successful [regexp {^DETACH-OK:([0-9]+)$} $output _ daemon_pid]
    check "nested detach success is explicitly reported" $successful
    check "detach returns before daemon work" [expr {$launcher_elapsed < 700 && ![file exists $marker]}]
    check "detached daemon outlives launcher" [wait_for_file $marker]
    check "detached marker identifies returned PID" [expr {
        $successful && [file exists $marker] && [string trim [slurp $marker]] eq $daemon_pid}]
} else {
    set output [string trim [dict get $outer out]]
    check "breakaway denial is reported, not silently attached" [expr {
        [dict get $outer status] eq "error" &&
        $output eq {DETACH-DENIED:MACHTELD DETACH launch} &&
        ![file exists $marker]}]
}

# A direct detach has the same strict contract. Some managed/agent hosts are inside
# an outer job that forbids breakaway; success must be demonstrated, and denial
# must be the exact launch error with no user code silently started attached.
set marker [file join $WORK direct-daemon.marker]
if {[catch {
    detach -- $FIXTURE daemon-marker $marker 250
} daemon_pid options]} {
    check "direct breakaway denial is exact" [expr {
        [dict get $options -errorcode] eq {MACHTELD DETACH launch}}]
    after 500
    check "directly denied detach never runs user code" [expr {![file exists $marker]}]
} else {
    check "detach success returns a PID" [string is integer -strict $daemon_pid]
    check "detached process performs delayed work" [wait_for_file $marker]
    check "detach PID matches daemon marker" [expr {
        [file exists $marker] && [string trim [slurp $marker]] eq $daemon_pid}]
}

# Interactive send/read semantics get their own terminal lane below. The
# default/headless lane checks lifecycle plus the redirected-parent binding
# gate, which needs no console at all.
set pty_token [pty spawn -- $FIXTURE ok pty]
check "pty spawn returns a token" [string match pty#* $pty_token]
check "pty token is listed" [expr {$pty_token in [pty list]}]
pty close $pty_token
check "pty close releases the token" [expr {$pty_token ni [pty list]}]

# A pty child's stdio must bind to the pseudoconsole even when the PARENT's own
# stdio is not a console. CreateProcess duplicates a parent's non-console std
# handles into a console child even with bInheritHandles=FALSE, so a pty launch
# that leaves the std-handle fields unset sends the child's bytes into the
# parent's own pipe or file (CI, `run` capture, hidden launches) while
# `pty read` sees only VT initialization. The inner parent below runs with both
# stdio streams captured by `run` -- exactly that hostile redirection -- and
# reports only the COUNT of canary lines `pty read` collected, never the canary
# itself, so a single canary byte on either captured stream is a leak.
set pty_leaf [file join $WORK pty-redirect-leaf.tcl]
set channel [open $pty_leaf w]
puts $channel {package require machteld}
puts $channel {for {set i 0} {$i < 300} {incr i} { puts MACHTELD-PTY-CANARY }}
close $channel
set pty_parent [file join $WORK pty-redirect-parent.tcl]
set channel [open $pty_parent w]
puts $channel {package require machteld}
puts $channel {
    set token [pty spawn -- [info nameofexecutable] [lindex $argv 0]]
    set collected ""
    set deadline [expr {[clock milliseconds] + 8000}]
    while {[clock milliseconds] < $deadline} {
        append collected [pty read $token -timeout 200ms]
        if {[regexp -all {MACHTELD-PTY-CANARY} [pty strip $collected]] >= 300} break
    }
    catch {pty close $token}
    puts stderr "PTY-REDIRECT-REPORT canary-lines=[regexp -all {MACHTELD-PTY-CANARY} [pty strip $collected]]"
}
close $channel
set result [run -timeout 20s -- $MT $pty_parent $pty_leaf]
check "pty parent with redirected stdio completes" [expr {
    [dict get $result status] eq "ok"}]
check "redirected parent stdout stays byte-clean of the pty child" [expr {
    [dict get $result out] eq ""}]
set pty_lines -1
regexp {PTY-REDIRECT-REPORT canary-lines=(\d+)} [dict get $result err] -> pty_lines
check "pty read collects the child's output despite parent redirection" [expr {
    $pty_lines >= 300}]

# Each non-empty send uses a private duplicate of the PTY input handle while its
# writer is alive. Repeated small writes make failure to close that duplicate a
# large, deterministic process-handle increase without filling either pipe.
set pty_handle_probe [pty spawn -- $FIXTURE stdin-line-count]
set handles_before [own_handle_count]
for {set index 0} {$index < 128} {incr index} {
    pty send $pty_handle_probe X
}
set handles_after [own_handle_count]
pty send $pty_handle_probe "\r\n"
catch {pty close $pty_handle_probe}
check "repeated PTY sends release their private writer handles" [expr {
    $handles_before >= 0 && $handles_after >= 0 &&
    $handles_after <= $handles_before + 8}]

# A synchronous send must service ConPTY's output at the same time: cooked
# console input is echoed before the final newline reaches the child, and a
# full output pipe would otherwise stop ConHost from consuming more input. Run
# the regression under a supervised outer timeout so a future circular wait is
# a bounded failure rather than a hung test lane. The sentinels prove that bytes
# drained to break backpressure remain available to `pty read` in order.
set pty_large [file join $WORK pty-large-send.tcl]
set channel [open $pty_large w]
puts $channel {package require machteld}
puts $channel {
    set token [pty spawn -- [lindex $argv 0] stdin-line-count]
    try {
        set payload "MACHTELD-PTY-BEGIN-"
        set markers {}
        for {set index 0} {$index < 128} {incr index} {
            set marker [format "<M%03d>" $index]
            lappend markers $marker
            append payload $marker [string repeat Q 1024]
        }
        append payload "-MACHTELD-PTY-END"
        pty send $token "$payload\r\n"
        set pending [dict get [pty info $token] pending]
        set observed ""
        set expected "PTY-BYTES:[string length $payload]"
        set deadline [expr {[clock milliseconds] + 10000}]
        while {[clock milliseconds] < $deadline &&
                ![string match *$expected* $observed]} {
            append observed [pty read $token -timeout 100ms]
        }
        set visible [pty strip $observed]
        set begin_index [string first MACHTELD-PTY-BEGIN- $visible]
        set end_index [string first -MACHTELD-PTY-END $visible]
        set summary_index [string first $expected $visible]
        set marker_index $begin_index
        set milestones [expr {$marker_index >= 0}]
        foreach marker $markers {
            set marker_index [string first $marker $visible $marker_index]
            if {$marker_index < 0} {
                set milestones 0
                break
            }
            incr marker_index [string length $marker]
        }
        puts [dict create pending $pending \
            complete [string match *$expected* $visible] \
            milestones $milestones \
            ordered [expr {$begin_index >= 0 && $end_index > $marker_index &&
                            $summary_index > $end_index}]]
    } finally {
        catch {pty close $token}
    }
}
close $channel
set result [run -timeout 20s -- $MT $pty_large $FIXTURE]
set pty_large_report [string trim [dict get $result out]]
set pty_large_valid [expr {
    [dict get $result status] eq "ok" &&
    ![catch {dict size $pty_large_report}]}]
foreach key {pending complete milestones ordered} {
    if {$pty_large_valid && ![dict exists $pty_large_report $key]} {
        set pty_large_valid 0
    }
}
check "large PTY send completes within a supervised bound" $pty_large_valid
check "large PTY send reports preserved pending output" [expr {
    $pty_large_valid && [dict get $pty_large_report pending] > 0}]
check "large PTY send reaches the child without truncation" [expr {
    $pty_large_valid && [dict get $pty_large_report complete]}]
check "large PTY send preserves drained output across the payload" [expr {
    $pty_large_valid && [dict get $pty_large_report milestones] &&
    [dict get $pty_large_report ordered]}]

if {[info exists ::env(MACHTELD_TEST_PTY_IO)] && $::env(MACHTELD_TEST_PTY_IO) eq "1"} {
    # Exercise the production retention ceiling honestly rather than through a
    # test-only knob. Cooked terminal echo means the writer cannot accept this
    # entire record without more than 8 MiB of output becoming readable.
    set pty_limit [file join $WORK pty-send-limit.tcl]
    set channel [open $pty_limit w]
    puts $channel {package require machteld}
    puts $channel {
        set token [pty spawn -- [lindex $argv 0] stdin-line-count]
        try {
            set payload [string repeat Z [expr {9 * 1024 * 1024}]]
            set caught [catch {pty send $token $payload} message options]
            unset payload
            set code [expr {$caught && [dict exists $options -errorcode]
                                ? [dict get $options -errorcode] : {}}]
            set pending [dict get [pty info $token] pending]
            set sample_length [string length [pty read $token]]
            set closed [expr {![catch {pty close $token}]}]
            if {$closed} { set token "" }
            puts [dict create caught $caught code $code pending $pending \
                sampleLength $sample_length closed $closed]
        } finally {
            if {$token ne ""} { catch {pty close $token} }
        }
    }
    close $channel
    set result [run -timeout 120s -- $MT $pty_limit $FIXTURE]
    set pty_limit_report [string trim [dict get $result out]]
    set pty_limit_valid [expr {
        [dict get $result status] eq "ok" &&
        ![catch {dict size $pty_limit_report}]}]
    foreach key {caught code pending sampleLength closed} {
        if {$pty_limit_valid && ![dict exists $pty_limit_report $key]} {
            set pty_limit_valid 0
        }
    }
    check "PTY send retention limit completes within a supervised bound" \
        $pty_limit_valid
    check "PTY send retention limit has its exact semantic error" [expr {
        $pty_limit_valid && [dict get $pty_limit_report caught] &&
        [dict get $pty_limit_report code] eq {MACHTELD PTY limit}}]
    check "PTY send retention limit preserves queued output" [expr {
        $pty_limit_valid && [dict get $pty_limit_report pending] >= 8 * 1024 * 1024 &&
        [dict get $pty_limit_report sampleLength] > 0 &&
        [dict get $pty_limit_report sampleLength] <= 8192}]
    check "PTY remains closable after its send retention limit" [expr {
        $pty_limit_valid && [dict get $pty_limit_report closed]}]

    # Redirected stdin is refused above by entry_test; a genuine terminal is
    # the one no-startup case that intentionally remains an interactive REPL.
    set repl [pty spawn -- $MT]
    pty send $repl "puts MACHTELD-REPL-OK\r\nexit\r\n"
    set observed ""
    set deadline [expr {[clock milliseconds] + 5000}]
    while {[clock milliseconds] < $deadline &&
            ![string match *MACHTELD-REPL-OK* $observed]} {
        append observed [pty read $repl -timeout 100ms]
    }
    check "console TTY without a startup file remains a REPL" [expr {
        [string match *MACHTELD-REPL-OK* $observed]}]
    catch {pty close $repl}
}

file delete -force $WORK
if {$fails} {
    puts stderr "$fails process test(s) failed"
    exit 1
}
puts "ALL PROCESS TESTS PASSED"
