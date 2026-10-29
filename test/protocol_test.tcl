# Framing, bounded retention, replay safety and teardown of real child peers.
package require machteld
set MT [info nameofexecutable]
set HERE [file dirname [file normalize [info script]]]
set WORKER [file join $HERE fixtures worker_program.tcl]
set PEER [file join $HERE fixtures protocol_program.tcl]
set WORK [file join $env(TEMP) machteld-protocol-test-[pid]-[clock clicks]]
file mkdir $WORK
set fails 0
set checks 0
proc check {name condition} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc errcode_of {script} {
    if {![catch {uplevel 1 $script} value options]} { return {} }
    return [dict get $options -errorcode]
}
proc effect_count {path} {
    if {![file exists $path]} { return 0 }
    set f [open $path r]
    try { return [llength [split [string trim [read $f]] \n]] } finally { close $f }
}
proc dead {process_id} {
    set deadline [expr {[clock milliseconds] + 4000}]
    while {[clock milliseconds] < $deadline} {
        if {[catch {mtps info $process_id}]} { return 1 }
        after 10
    }
    return 0
}

set initialChildren [child list]
set initialChannels [lsort [chan names]]
set initialTimers [lsort [after info]]
set defaults [dict create maxtries 1 maxframe 16777216 maxitems 10000 maxbatch 67108864 maxresults 67108864]
check "manifest exposes bounded pool and pmap defaults" [expr {
    [dict get [manifest] pool defaults] eq $defaults &&
    [dict get [manifest] pmap defaults] eq $defaults}]
foreach option {-maxframe -maxitems -maxbatch -maxresults} {
    foreach value {0 -1 1.5 unlimited {} 2147483648} {
        check "pool rejects $option <$value> before launch" [expr {
            [errcode_of [list pool create $option $value -- missing.exe]] eq {MACHTELD POOL badvalue}}]
        check "pmap validates $option <$value> even for empty batches" [expr {
            [errcode_of [list pmap {} $option $value -- missing.exe]] eq {MACHTELD PMAP badvalue}}]
    }
}
foreach value {0 -1 1.5 2147483648} {
    check "worker rejects frame limit $value before reading" [expr {
        [errcode_of [list worker serve -maxframe $value]] eq {MACHTELD WORKER badvalue}}]
}
foreach option {-width -maxtries} {
    check "empty pmap validates $option" [expr {
        [errcode_of [list pmap {} $option 0 -- missing.exe]] eq {MACHTELD PMAP badvalue}}]
}

# A rejected batch is atomic, including after earlier items have validated.
foreach {option value requests} {
    -maxitems 1 {{op echo text a} {op echo text b}}
    -maxframe 64 {{op echo text a} {op echo text xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx}}
    -maxbatch 50 {{op echo text a} {op echo text b}}
} {
    set p [pool create -width 1 $option $value -- $MT $WORKER]
    try {
        check "batch rejects $option before acceptance" [expr {
            [errcode_of [list pool submit $p $requests]] eq {MACHTELD POOL limit} &&
            [dict get [pool info $p] pending] == 0 && [dict get [pool info $p] inflight] == 0}]
        pool submit $p {{op echo text accepted}}
        check "rejected $option batch leaves pool reusable" [expr {
            [dict get [lindex [pool wait $p -timeout 10s] 0] result] eq "accepted"}]
    } finally { pool close $p }
}

# Exact wire-byte accounting includes UTF-8 expansion and LF only in totals.
set item [dict create op echo text "\u00e9\u4e16\u754c"]
set bytes [string length [encoding convertto utf-8 [json encode -plain -dict [dict merge $item {id 0}]]]]
set p [pool create -width 1 -maxframe $bytes -maxbatch [expr {$bytes+1}] -- $MT $WORKER]
try {
    pool submit $p [list $item]
    set replies [pool wait $p -timeout 10s]
    check "exact UTF-8 request byte boundary accepted" [expr {
        [dict get [lindex $replies 0] result] eq "\u00e9\u4e16\u754c" &&
        [dict get [pool info $p] batchbytes] == $bytes+1}]
} finally { pool close $p }
set p [pool create -width 1 -maxframe [expr {$bytes-1}] -- $MT $WORKER]
try {
    check "one-byte-too-small UTF-8 request limit refused" [expr {
        [errcode_of [list pool submit $p [list $item]]] eq {MACHTELD POOL limit}}]
} finally { pool close $p }

foreach mode {split-unicode final} expected [list "caf\u00e9 \u4e16\u754c" final] {
    set replies [pmap {{op ignored}} -width 1 -raw -timeout 10s -- $MT $PEER $mode]
    check "pool preserves $mode reply framing" [expr {
        [dict get [lindex $replies 0] result] eq $expected}]
}
foreach mode {partial-utf8 wrong-ok} {
    set p [pool create -width 1 -- $MT $PEER $mode]
    try {
        pool submit $p {{op ignored}}
        set replies [pool wait $p -timeout 10s]
        check "malformed $mode reply is not replayed by default" [expr {
            [dict get [lindex $replies 0] code] eq {MACHTELD POOL poison} &&
            [dict get [pool info $p] requeued] == 0 && [dict get [pool info $p] dead] == 1}]
    } finally { pool close $p }
}

set p [pool create -width 1 -maxframe 1024 -- $MT $PEER unterminated 1025]
try {
    pool submit $p {{op ignored}}
    check "oversized unterminated reply aborts without waiting for LF or EOF" [expr {
        [errcode_of [list pool wait $p -timeout 3s]] eq {MACHTELD POOL limit} &&
        [dict get [pool info $p] workers] == 0}]
    check "limit failure remains structured on repeated wait" [expr {
        [errcode_of [list pool wait $p -timeout 0ms]] eq {MACHTELD POOL limit}}]
} finally { pool close $p }

set p [pool create -width 1 -maxresults 250 -- $MT $WORKER]
try {
    pool submit $p [lrepeat 3 {op big bytes 100}]
    check "aggregate retained reply bytes have a separate bound" [expr {
        [errcode_of [list pool wait $p -timeout 10s]] eq {MACHTELD POOL limit} &&
        [dict get [pool info $p] resultbytes] <= 250 && [dict get [pool info $p] workers] == 0}]
} finally { pool close $p }
check "pmap relabels aggregate bounds and closes children" [expr {
    [errcode_of [list pmap [lrepeat 3 {op big bytes 100}] -width 1 -maxresults 250 -timeout 10s -- $MT $WORKER]]
        eq {MACHTELD PMAP limit} && [child list] eq $initialChildren}]

set p [pool create -width 1 -maxframe 1200000 -- $MT $PEER no-read]
try {
    pool submit $p [lrepeat 3 [dict create op ignored payload [string repeat x 1000000]]]
    check "a lying slow reader cannot accumulate unbounded queued writes" [expr {
        [errcode_of [list pool wait $p -timeout 3s]] eq {MACHTELD POOL limit} &&
        [dict get [pool info $p] workers] == 0}]
} finally { pool close $p }

# The worker checks input before JSON decoding, even without a terminating LF.
set c [child start -channels -- $MT $WORKER -maxframe 128]
try {
    set ci [child info $c]
    set input [dict get $ci stdin]
    fconfigure $input -buffering none -translation binary
    puts -nonewline $input [string repeat x 129]
    set observed [child wait $c -timeout 3s]
    check "worker rejects oversized unterminated request before EOF" [expr {
        [dict get $observed status] ne "running" && [dict get $observed exit] != 0}]
} finally { child close $c }
set result [run -stdin [encoding convertto utf-8 {{"id":0,"op":"echo","text":"final"}}] \
    -timeout 3s -- $MT $WORKER]
check "worker accepts complete final JSON request without LF" [expr {
    [dict get $result status] eq "ok" && [dict get [json decode [dict get $result out]] result] eq "final"}]
set result [run -stdin [binary decode hex c30a] -timeout 3s -- $MT $WORKER]
check "worker invalid UTF-8 receives a parse failure, not replacement text" [expr {
    [dict get $result status] eq "ok" &&
    [dict get [json decode [dict get $result out]] code] eq {MACHTELD WORKER parse}}]
set c [child start -channels -- $MT $WORKER]
try {
    set ci [child info $c]
    set input [dict get $ci stdin]
    set output [dict get $ci stdout]
    fconfigure $input -buffering none -translation binary
    fconfigure $output -translation lf -encoding utf-8
    # Construct actual non-ASCII data without relying on source-file encoding.
    set wire [encoding convertto utf-8 [json encode -plain -dict [dict create id 0 op echo text "caf\u00e9"]]]
    set split [string first [binary decode hex c3] $wire]
    puts -nonewline $input [string range $wire 0 $split]
    after 20
    puts $input [string range $wire $split+1 end]
    set reply [json decode [gets $output]]
    check "worker preserves a request UTF-8 character split across reads" [expr {
        [dict get $reply result] eq "caf\u00e9"}]
} finally { child close $c }
set p [pool create -width 1 -- $MT $WORKER -maxframe 256]
try {
    pool submit $p {{op big bytes 1000}}
    set replies [pool wait $p -timeout 10s]
    check "oversized worker result becomes a bounded failure reply" [expr {
        [dict get [lindex $replies 0] code] eq {MACHTELD WORKER limit} &&
        [dict get [pool info $p] dead] == 0}]
} finally { pool close $p }

# Fairness: all buffered empty records count against the same callback quota.
set p [pool create -width 1 -- $MT $WORKER]
try {
    set c [lindex [dict get $::machteld::POOL $p workers] 0]
    dict set ::machteld::POOL $p readers $c [string repeat \n 1000]
    ::machteld::PoolEvent $p $c readable
    check "one callback processes at most 64 buffered records" [expr {
        [string length [dict get $::machteld::POOL $p readers $c]] == 936 &&
        [dict exists $::machteld::POOL $p resumes [list $c readable]]}]
} finally { pool close $p }
source [file join $HERE protocol_fairness_test.tcl]

# Close/abort cancel both halves of the idle-to-timer continuation, on both
# streams. Stale dispatched callbacks may not resurrect released state.
foreach stage {idle rearm} {
    set beforeTimers [lsort [after info]]
    set p [pool create -width 1 -- $MT $WORKER]
    set c [lindex [dict get $::machteld::POOL $p workers] 0]
    foreach kind {readable stderr} {
        ::machteld::PoolEvent $p $c $kind
        if {$stage eq "rearm"} {
            after cancel [dict get $::machteld::POOL $p resumes [list $c $kind]]
            ::machteld::PoolAfterIdle $p $c $kind
        }
    }
    pool close $p
    foreach kind {readable stderr} {
        ::machteld::PoolAfterIdle $p $c $kind
        ::machteld::PoolRearm $p $c $kind
    }
    check "close cancels both stream $stage continuations without resurrection" [expr {
        [lsort [after info]] eq $beforeTimers && ![dict exists $::machteld::POOL $p]}]
}
set p [pool create -width 1 -- $MT $WORKER]
set c [lindex [dict get $::machteld::POOL $p workers] 0]
::machteld::PoolEvent $p $c stderr
chan close [dict get [child info $c] stderr]
try {
    pool submit $p {{op delay milliseconds 10000 text late}}
    check "failed channel rearm wakes waiters and cleans workers" [expr {
        [errcode_of [list pool wait $p -timeout 3s]] eq {MACHTELD POOL failed} &&
        [dict get [pool info $p] workers] == 0}]
} finally { pool close $p }
set p [pool create -width 1 -- $MT $WORKER]
rename ::machteld::PoolReadable ::machteld::ProtocolCloseOriginalReadable
proc ::machteld::PoolReadable {tok c} {
    ::machteld::ProtocolCloseOriginalReadable $tok $c
    pool close $tok
}
try {
    pool submit $p {{op echo text trigger}}
    check "reentrant close inside a channel callback does not rearm closed channels" [expr {
        [errcode_of [list pool wait $p -timeout 3s]] eq {MACHTELD POOL nohandle}}]
} finally {
    rename ::machteld::PoolReadable {}
    rename ::machteld::ProtocolCloseOriginalReadable ::machteld::PoolReadable
    catch {pool close $p}
}
set p [pool create -width 1 -- $MT $PEER stderr-bytes]
try {
    pool submit $p {{op ignored}}
    pool wait $p -timeout 10s
    check "stderr tail retains at most 64KiB raw bytes" [expr {
        [string length [dict get $::machteld::POOL $p errbuf]] <= 65536 &&
        [string first \u00e9 [dict get [pool info $p] stderr]] >= 0}]
} finally { pool close $p }

# A visible side effect followed by process death is an UNKNOWN outcome, not
# proof the operation did not run. Total attempts are opt-in and exact.
foreach tries {1 3} {
    set path [file join $WORK effect-$tries.txt]
    set options [expr {$tries == 1 ? {} : [list -maxtries $tries]}]
    set p [pool create -width 1 {*}$options -- $MT $WORKER]
    try {
        pool submit $p [list [dict create op effect-die path $path]]
        set replies [pool wait $p -timeout 10s]
        check "lost reply executes exactly $tries authorized attempt(s)" [expr {
            [effect_count $path] == $tries && [dict get [pool info $p] requeued] == $tries-1 &&
            [dict get [lindex $replies 0] code] eq {MACHTELD POOL poison}}]
        check "lost reply reports outcome uncertainty" [string match {*may already have taken effect*} \
            [dict get [lindex $replies 0] msg]]
    } finally { pool close $p }
}
set path [file join $WORK pmap-default.txt]
check "default pmap does not replay a lost-reply side effect" [expr {
    [errcode_of [list pmap [list [dict create op effect-die path $path]] -width 1 -timeout 10s -- $MT $WORKER]]
        eq {MACHTELD POOL poison} && [effect_count $path] == 1}]
set path [file join $WORK reported.txt]
check "reported handler failure is never retried even with maxtries 3" [expr {
    [errcode_of [list pmap [list [dict create op effect-fail path $path]] -width 1 -maxtries 3 -timeout 10s -- $MT $WORKER]]
        eq {FIXTURE reported} && [effect_count $path] == 1}]

set p [pool create -width 1 -- $MT $WORKER]
try {
    child kill [lindex [dict get $::machteld::POOL $p workers] 0]
    set deadline [expr {[clock milliseconds] + 3000}]
    while {[dict get [pool info $p] workers] && [clock milliseconds] < $deadline} {
        after 10 {set ::idleDeath 1}
        vwait ::idleDeath
    }
    check "idle worker death is observed without an item to replay" [expr {
        [dict get [pool info $p] workers] == 0}]
    pool submit $p {{op echo text revived}}
    check "submission after idle worker death still makes progress" [expr {
        [dict get [lindex [pool wait $p -timeout 3s] 0] result] eq "revived"}]
} finally { pool close $p }

set p [pool create -width 1 -timeout 100ms -- $MT $WORKER]
try {
    pool submit $p {{op delay milliseconds 10000 text late}}
    set replies [pool wait $p -timeout 3s]
    check "launch deadline terminates work, unlike observation timeout" [expr {
        [dict get [lindex $replies 0] code] eq {MACHTELD POOL poison} &&
        [dict get [pool info $p] requeued] == 0}]
} finally { pool close $p }

# Fault injection remains inside the real event dispatcher and wakeup path.
set p [pool create -width 1 -- $MT $WORKER]
rename ::machteld::PoolReadable ::machteld::ProtocolOriginalReadable
proc ::machteld::PoolReadable {args} { error "injected callback failure" }
try {
    pool submit $p {{op echo text trigger}}
    set rc [catch {pool wait $p -timeout 3s} message options]
    check "callback exceptions wake waiters and terminate owned workers" [expr {
        $rc == 1 && [dict get $options -errorcode] eq {MACHTELD POOL failed} &&
        [string match {*injected callback failure*} $message] && [dict get [pool info $p] workers] == 0}]
} finally {
    rename ::machteld::PoolReadable {}
    rename ::machteld::ProtocolOriginalReadable ::machteld::PoolReadable
    pool close $p
}
set p [pool create -width 1 -- $MT $WORKER]
set c [lindex [dict get $::machteld::POOL $p workers] 0]
set ::protocolFailReadChannel [dict get [child info $c] stderr]
rename ::read ::protocolOriginalRead
proc ::read {args} {
    if {[lindex $args 0] eq $::protocolFailReadChannel} { error "injected stderr read failure" }
    tailcall ::protocolOriginalRead {*}$args
}
try {
    pool submit $p {{op noise bytes 50000}}
    set rc [catch {pool wait $p -timeout 3s} message options]
    check "stderr read errors reach callback containment instead of rearming forever" [expr {
        $rc == 1 && [dict get $options -errorcode] eq {MACHTELD POOL failed} &&
        [string match {*injected stderr read failure*} $message] && [dict get [pool info $p] workers] == 0}]
} finally {
    rename ::read {}
    rename ::protocolOriginalRead ::read
    unset ::protocolFailReadChannel
    pool close $p
}
check "close cancels every protocol continuation and wait timer" [expr {
    [lsort [after info]] eq $initialTimers && [lsort [chan names]] eq $initialChannels &&
    [child list] eq $initialChildren}]

set result [run -timeout 8s -- $MT $PEER parent-exit]
set pids [string trim [dict get $result out]]
set allDead [expr {[llength $pids] == 2}]
foreach process_id $pids { if {![dead $process_id]} { set allDead 0 } }
check "parent exit terminates active pool workers without close" [expr {
    [dict get $result status] eq "ok" && $allDead}]
set result [run -timeout 8s -- $MT $PEER interpreter-delete]
# Capture deliberately preserves raw bytes, including Windows stdout CRLF.
set deletionStates [string map [list "\r\n" "\n"] [string trim [dict get $result out]]]
check "interpreter deletion terminates its active pool workers" [expr {
    [dict get $result status] eq "ok" && $deletionStates eq [join [lrepeat 6 dead] \n]}]

file delete -force $WORK
if {$fails} { puts stderr "$fails of $checks protocol checks failed"; exit 1 }
puts "ALL $checks PROTOCOL CHECKS PASSED"
