# pool.tcl -- ::machteld::pool: persistent workers, driven by the event loop.
#
#   set p [pool create -width 8 -- $exe --worker]
#   pool submit $p {{op digest path a.iso} {op digest path b.iso}}
#   pool wait   $p -timeout 60s        ;# results, IN SUBMISSION ORDER
#   pool info   $p                     ;# width, pending, inflight, dead, requeued
#   pool close  $p
#
# Over `child start -channels`, never raw `open |cmd r+`. The transport was never
# the missing piece -- stock Tcl has it -- so the entire reason this is a verb is
# the half Tcl cannot supply: every worker here is born in a job object, dies
# with its parent, is tree-killed rather than asked to stop, can be capped with
# -mem, and is reaped by `scope` at the closing brace.
#
# `chan event` does the multiplexing without polling. After each bounded read,
# the channel is paused through an idle turn before rearming: continuously
# ready pipes must not starve Tk's idle redraw/layout work. An idle pool still
# has no recurring timer.
#
# ONE ITEM IN FLIGHT PER WORKER. Not a throughput choice -- a legibility one. With
# a single outstanding request the mapping from a reply to the item it answers is
# a fact rather than a correlation, and a worker that dies has exactly one item to
# put back.
#
# STDERR MUST BE DRAINED. In channel mode it is a pipe; leaving it unread can
# block a worker mid-write. Keep a capped tail for `pool info` diagnostics.

namespace eval ::machteld {
    variable POOL {}
    variable POOL_SEQ 0
}

set ::machteld::POOL_ERRCAP 65536   ;# per pool, so a chatty worker cannot grow without bound

proc ::machteld::PoolBound {domain option value} {
    set value [ProtocolLimit $domain $option $value]
    if {$option eq "-width" && $value > 256} {
        Fail $domain badvalue "-width must be between 1 and 256"
    }
    return $value
}

proc ::machteld::pool {args} {
    variable POOL
    variable POOL_SEQ
    set subs {create submit wait info close}

    if {![llength $args]} {
        Fail POOL usage "usage: pool create ?-width n? -- command ?arg ...?"
    }
    set sub [lindex $args 0]
    if {$sub ni $subs} {
        Fail POOL usage "pool: unknown subcommand \"$sub\": must be [join $subs {, }]"
    }

    if {$sub eq "create"} { return [PoolCreate [lrange $args 1 end]] }

    if {[llength $args] < 2} { Fail POOL usage "pool $sub needs a pool token" }
    set tok [lindex $args 1]
    if {![dict exists $POOL $tok]} { Fail POOL nohandle "no such pool" }
    set rest [lrange $args 2 end]

    switch -- $sub {
        submit {
            # The item list is one argument; do not guess whether a Tcl value was
            # written as a bare dict or a one-element list.
            if {[llength $rest] != 1} { Fail POOL usage "usage: pool submit token items" }
            return [PoolSubmit $tok [lindex $rest 0]]
        }
        info {
            if {[llength $rest]} { Fail POOL usage "usage: pool info token" }
            return [PoolInfo $tok]
        }
        close {
            if {[llength $rest]} { Fail POOL usage "usage: pool close token" }
            return [PoolClose $tok]
        }
        wait   { return [PoolWait $tok $rest] }
    }
}

proc ::machteld::PoolCreate {argl} {
    variable POOL
    variable POOL_SEQ
    set width 4
    set maxtries 1
    set limits [dict create maxframe 16777216 maxitems 10000 maxbatch 67108864 maxresults 67108864]
    set launch {}
    set i 0
    for {} {$i < [llength $argl]} {incr i} {
        set a [lindex $argl $i]
        if {$a eq "--"} { incr i ; break }
        if {![string match -* $a]} break
        if {$i + 1 >= [llength $argl]} { Fail POOL usage "pool create: option needs a value" }
        set v [lindex $argl [expr {$i + 1}]]
        switch -- $a {
            -width {
                set width [PoolBound POOL $a $v]
            }
            -maxtries {
                set maxtries [PoolBound POOL $a $v]
            }
            -maxframe - -maxitems - -maxbatch - -maxresults {
                dict set limits [string range $a 1 end] [ProtocolLimit POOL $a $v]
            }
            -arg0 - -cpu - -dir - -env - -mem - -timeout {
                lappend launch $a $v
            }
            default { Fail POOL usage "pool create: unknown option \"$a\"" }
        }
        incr i
    }
    set cmd [lrange $argl $i end]
    if {![llength $cmd]} { Fail POOL usage "pool create: no command given" }

    set tok pool#[incr POOL_SEQ]
    dict set POOL $tok [dict create cmd $cmd launch $launch width $width maxtries $maxtries \
        limits $limits pending {} results {} inflight {} workers {} readers {} resumes {} nextid 0 \
        batchbytes 0 resultbytes 0 dead 0 requeued 0 errbuf "" fatal "" fatalcode {} \
        done 1 submitted 0 submitted_once 0]
    if {[catch {
        for {set k 0} {$k < $width} {incr k} { PoolSpawn $tok }
    } msg opts]} {
        catch {PoolClose $tok}
        return -options $opts $msg
    }
    return $tok
}

# One worker: a channel-mode child, plus readable handlers on both of its output
# pipes. Returns the child token.
proc ::machteld::PoolSpawn {tok} {
    variable POOL
    set cmd [dict get $POOL $tok cmd]
    set launch [dict get $POOL $tok launch]
    if {[catch {child start -channels {*}$launch -- {*}$cmd} c]} {
        Fail POOL launch "pool: cannot start a worker: $c"
    }
    set ci [child info $c]
    set in  [dict get $ci stdin]
    set out [dict get $ci stdout]
    set err [dict get $ci stderr]
    # Frame binary bytes first, then decode a complete bounded frame strictly.
    # The nonblocking output queue is capped separately in PoolFeed.
    foreach ch [list $in $out $err] {
        fconfigure $ch -blocking 0 -buffering none -translation binary
    }
    chan event $out readable [list ::machteld::PoolEvent $tok $c readable]
    chan event $err readable [list ::machteld::PoolEvent $tok $c stderr]
    dict set POOL $tok readers $c ""
    dict set POOL $tok workers [linsert [dict get $POOL $tok workers] end $c]
    return $c
}

# Drain stderr so it cannot fill, and keep the tail for diagnosis.
proc ::machteld::PoolStderr {tok c} {
    variable POOL
    variable POOL_ERRCAP
    if {![dict exists $POOL $tok]} return
    if {[catch {child info $c} ci]} return
    if {![dict exists $ci stderr]} return
    set ch [dict get $ci stderr]
    set chunk [read $ch 65536]
    if {$chunk ne ""} {
        set buf [dict get $POOL $tok errbuf]
        append buf $chunk
        if {[string length $buf] > $POOL_ERRCAP} {
            set buf [string range $buf end-[expr {$POOL_ERRCAP - 1}] end]
        }
        dict set POOL $tok errbuf $buf
    }
    if {[eof $ch]} { chan event $ch readable {} }
}

# Every event boundary is contained. An unexpected callback error must wake
# waiters and clean up, never disappear into bgerror while the pool stalls.
proc ::machteld::PoolEvent {tok c kind} {
    variable POOL
    if {![dict exists $POOL $tok] || $c ni [dict get $POOL $tok workers]} return
    if {[catch {
        set ci [child info $c]
        set ch [dict get $ci [expr {$kind eq "stderr" ? "stderr" : "stdout"}]]
        # Suppress file events while processing and until an idle pass has run.
        # Merely limiting reads or using after 0 leaves the event queue always
        # nonempty under sustained I/O, which starves Tk's idle handlers.
        chan event $ch readable {}
        set key [list $c $kind]
        if {[dict exists $POOL $tok resumes $key]} {
            after cancel [dict get $POOL $tok resumes $key]
            dict unset POOL $tok resumes $key
        }
        if {$kind eq "stderr"} { PoolStderr $tok $c } else { PoolReadable $tok $c }
        if {[dict exists $POOL $tok] && $c in [dict get $POOL $tok workers] &&
                !($kind eq "stderr" && [eof $ch])} {
            dict set POOL $tok resumes $key \
                [after idle [list ::machteld::PoolAfterIdle $tok $c $kind]]
        }
    } msg]} {
        PoolAbort $tok failed "pool callback failed: $msg"
    }
}

# The idle callback itself does no I/O. Its zero-delay continuation runs only
# after the current idle pass, giving already-queued GUI work its opportunity.
# Both stages are recorded and canceled by death, abort and close.
proc ::machteld::PoolAfterIdle {tok c kind} {
    variable POOL
    set key [list $c $kind]
    if {![dict exists $POOL $tok resumes $key] || $c ni [dict get $POOL $tok workers]} return
    dict set POOL $tok resumes $key [after 0 [list ::machteld::PoolRearm $tok $c $kind]]
}

proc ::machteld::PoolRearm {tok c kind} {
    variable POOL
    set key [list $c $kind]
    if {![dict exists $POOL $tok resumes $key] || $c ni [dict get $POOL $tok workers]} return
    dict unset POOL $tok resumes $key
    if {[catch {
        set ci [child info $c]
        set ch [dict get $ci [expr {$kind eq "stderr" ? "stderr" : "stdout"}]]
        if {$kind eq "readable" &&
                ([string first \n [dict get $POOL $tok readers $c]] >= 0 || [eof $ch])} {
            # Buffered complete frames need work even without new pipe bytes.
            PoolEvent $tok $c $kind
        } else {
            chan event $ch readable [list ::machteld::PoolEvent $tok $c $kind]
        }
    } msg]} {
        PoolAbort $tok failed "pool channel rearm failed: $msg"
    }
}

proc ::machteld::PoolDiagnostic {tok message} {
    variable POOL
    variable POOL_ERRCAP
    set tail [dict get $POOL $tok errbuf]
    append tail [encoding convertto utf-8 $message]
    dict set POOL $tok errbuf [string range $tail end-[expr {$POOL_ERRCAP - 1}] end]
}

proc ::machteld::PoolSubmit {tok items} {
    variable POOL
    if {[dict get $POOL $tok fatal] ne ""} {
        return -code error -errorcode [dict get $POOL $tok fatalcode] [dict get $POOL $tok fatal]
    }
    if {[dict get $POOL $tok submitted_once]} {
        Fail POOL usage "pool submit: a pool accepts exactly one batch; create another pool"
    }
    set limits [dict get $POOL $tok limits]
    if {[llength $items] > [dict get $limits maxitems]} {
        Fail POOL limit "pool submit: batch exceeds -maxitems ([dict get $limits maxitems])"
    }
    # `items` is always a list of request dicts; Tcl values do not preserve how
    # the caller happened to spell a one-element list.
    set pend [dict get $POOL $tok pending]
    set next [dict get $POOL $tok nextid]
    set bytes 0
    foreach it $items {
        if {[catch {dict size $it}]} { Fail POOL badvalue "pool submit: each item must be a dict" }
        if {![dict exists $it op]} { Fail POOL badvalue "pool submit: each item needs an op" }
        # An item must be expressible on the wire before it is accepted.
        # Refusing here names the caller's mistake at the boundary; discovering
        # it at feed time would kill a healthy worker and poison the item.
        dict set it id $next
        if {[catch {json encode -plain -dict $it} encoded]} {
            Fail POOL badvalue "pool submit: each item must encode as plain JSON; typed json values are refused"
        }
        set frame [encoding convertto utf-8 $encoded]
        set size [string length $frame]
        if {$size > [dict get $limits maxframe]} {
            Fail POOL limit "pool submit: request exceeds -maxframe ([dict get $limits maxframe] bytes)"
        }
        incr bytes [expr {$size + 1}]
        if {$bytes > [dict get $limits maxbatch]} {
            Fail POOL limit "pool submit: batch exceeds -maxbatch ([dict get $limits maxbatch] bytes)"
        }
        incr next
        # Retain exactly the validated wire representation, not a second copy
        # of caller dicts that can be much larger than their encoded payload.
        lappend pend [list id [dict get $it id] frame $frame]
    }
    dict set POOL $tok pending $pend
    dict set POOL $tok nextid $next
    dict set POOL $tok submitted $next
    dict set POOL $tok batchbytes $bytes
    dict set POOL $tok submitted_once 1
    dict set POOL $tok done 0
    # Idle workers may have exited while the caller was doing other event-loop
    # work before submit. Do not leave an accepted batch with no live readers.
    if {[llength $pend] && ![llength [dict get $POOL $tok workers]]} {
        if {[catch {PoolSpawn $tok} message]} {
            PoolAbort $tok launch $message
            return -code error -errorcode {MACHTELD POOL launch} $message
        }
    }
    foreach c [dict get $POOL $tok workers] { PoolFeed $tok $c }
    PoolCheckDone $tok
    return
}

proc ::machteld::PoolFeed {tok c} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    if {[dict get $POOL $tok fatal] ne "" || $c ni [dict get $POOL $tok workers]} return
    if {[dict exists [dict get $POOL $tok inflight] $c]} return
    set pend [dict get $POOL $tok pending]
    if {![llength $pend]} { PoolCheckDone $tok ; return }
    set item [lindex $pend 0]
    dict set POOL $tok pending [lrange $pend 1 end]
    dict set POOL $tok inflight [dict replace [dict get $POOL $tok inflight] $c $item]
    if {[catch {
        set ci [child info $c]
        set in [dict get $ci stdin]
        set frame [dict get $item frame]
        if {[chan pending output $in] + [string length $frame] + 1 >
            [dict get $POOL $tok limits maxframe] + 1} {
            PoolAbort $tok limit "worker input queue exceeds -maxframe"
            return
        }
        puts $in $frame
        flush $in
    }]} {
        PoolDied $tok $c
    }
}

proc ::machteld::PoolReadable {tok c} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    if {[catch {child info $c} ci]} { PoolDied $tok $c ; return }
    if {![dict exists $ci stdout]} { PoolDied $tok $c ; return }
    set ch [dict get $ci stdout]
    set maxframe [dict get $POOL $tok limits maxframe]
    set buffer [dict get $POOL $tok readers $c]
    # At most 64KiB are read, and at most 64 records (including empty ones)
    # handled per event. A sustained writer cannot monopolize the Tk loop.
    if {[string first \n $buffer] < 0} {
        append buffer [read $ch [expr {min(65536, $maxframe + 1 - [string length $buffer])}]]
    }
    set records 0
    while {$records < 64} {
        set lf [string first \n $buffer]
        if {$lf >= 0} {
            set frame [string range $buffer 0 $lf-1]
            set buffer [string range $buffer $lf+1 end]
        } elseif {[string length $buffer] > $maxframe} {
            PoolAbort $tok limit "worker reply exceeds -maxframe ($maxframe bytes)"
            return
        } elseif {[eof $ch] && $buffer ne ""} {
            # Like gets, accept the final complete JSON value without LF.
            set frame $buffer
            set buffer ""
        } else {
            break
        }
        incr records
        if {[string length $frame] > $maxframe} {
            PoolAbort $tok limit "worker reply exceeds -maxframe ($maxframe bytes)"
            return
        }
        if {$frame eq ""} continue
        if {[catch {encoding convertfrom -profile strict utf-8 $frame} line]} {
            PoolDiagnostic $tok "protocol error: worker wrote a reply that is not UTF-8\n"
            PoolDied $tok $c
            return
        }
        if {[catch {json decode $line} rep] ||
            [catch {json encode -plain $rep} encoded] ||
            ![string match \{* $encoded] ||
            ![dict exists $rep id] || ![dict exists $rep ok] ||
            ![string is boolean -strict [dict get $rep ok]]} {
            PoolDiagnostic $tok "protocol error: worker wrote a malformed reply\n"
            PoolDied $tok $c
            return
        }
        if {![dict exists [dict get $POOL $tok inflight] $c] ||
            [dict get $rep id] ne [dict get $POOL $tok inflight $c id]} {
            PoolDiagnostic $tok "protocol error: worker replied with an unexpected id\n"
            PoolDied $tok $c
            return
        }
        if {![PoolResult $tok $rep [expr {[string length $frame] + 1}]]} return
        dict set POOL $tok inflight [dict remove [dict get $POOL $tok inflight] $c]
        PoolFeed $tok $c
        if {$c ni [dict get $POOL $tok workers]} return
    }
    dict set POOL $tok readers $c $buffer
    if {[eof $ch] && $buffer eq ""} { PoolDied $tok $c ; return }
    PoolCheckDone $tok
}

proc ::machteld::PoolResult {tok reply bytes} {
    variable POOL
    set total [expr {[dict get $POOL $tok resultbytes] + $bytes}]
    if {$total > [dict get $POOL $tok limits maxresults]} {
        PoolAbort $tok limit "retained replies exceed -maxresults ([dict get $POOL $tok limits maxresults] bytes)"
        return 0
    }
    dict set POOL $tok resultbytes $total
    dict set POOL $tok results [linsert [dict get $POOL $tok results] end $reply]
    return 1
}

# A worker died without a reply. The operation's outcome is unknown. Replay is
# explicit opt-in, bounded by total attempts; replacement for other pending
# items is independent of whether this lost item may be replayed.
proc ::machteld::PoolDied {tok c} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    if {$c ni [dict get $POOL $tok workers]} return
    foreach kind {readable stderr} {
        set key [list $c $kind]
        if {[dict exists $POOL $tok resumes $key]} {
            after cancel [dict get $POOL $tok resumes $key]
            dict unset POOL $tok resumes $key
        }
    }
    dict unset POOL $tok readers $c
    catch {
        set ci [child info $c]
        foreach k {stdout stderr} {
            if {[dict exists $ci $k]} { chan event [dict get $ci $k] readable {} }
        }
    }
    catch {child close $c}
    dict set POOL $tok workers [lsearch -all -inline -not -exact [dict get $POOL $tok workers] $c]
    dict set POOL $tok dead [expr {[dict get $POOL $tok dead] + 1}]

    set infl [dict get $POOL $tok inflight]
    dict set POOL $tok inflight [dict remove $infl $c]
    PoolRequeue $tok $c $infl
    if {[dict get $POOL $tok fatal] ne ""} return
    # Per-item maxtries makes replacement finite without a global death ceiling,
    # which could strand later items after earlier poison consumed the allowance.
    if {[llength [dict get $POOL $tok pending]]} {
        if {[catch {PoolSpawn $tok} new]} {
            PoolAbort $tok launch $new
        } else {
            PoolFeed $tok $new
        }
    }
    PoolCheckDone $tok
}

proc ::machteld::PoolRequeue {tok c infl} {
    variable POOL
    if {![dict exists $infl $c]} return
    set item [dict get $infl $c]
    set id [dict get $item id]
    set tries [expr {[dict exists $POOL $tok tries $id] ? [dict get $POOL $tok tries $id] : 0}]
    incr tries
    dict set POOL $tok tries $id $tries
    if {$tries < [dict get $POOL $tok maxtries]} {
        dict set POOL $tok pending [linsert [dict get $POOL $tok pending] 0 $item]
        dict set POOL $tok requeued [expr {[dict get $POOL $tok requeued] + 1}]
    } else {
        set reply [dict create id $id ok 0 code {MACHTELD POOL poison} \
            msg "no valid reply after $tries attempt(s); the operation may already have taken effect"]
        PoolResult $tok $reply [expr {[string length [encoding convertto utf-8 \
            [json encode -plain -dict $reply]]] + 1}]
    }
}

proc ::machteld::PoolCheckDone {tok} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    if {![llength [dict get $POOL $tok pending]] &&
        ![dict size [dict get $POOL $tok inflight]]} {
        dict set POOL $tok done 1
        set ::machteld::POOL_DONE($tok) 1
    }
}

# A ready timer can run in the same event-loop turn as completion or close.
# Never overwrite completion or recreate a closed pool's notification element.
proc ::machteld::PoolWaitTimeout {tok} {
    variable POOL
    if {[dict exists $POOL $tok] && ![dict get $POOL $tok done]} {
        set ::machteld::POOL_DONE($tok) timeout
    }
}

proc ::machteld::PoolWait {tok argl} {
    variable POOL
    set ms 300000
    for {set i 0} {$i < [llength $argl]} {incr i 2} {
        set a [lindex $argl $i]
        if {$a ne "-timeout"} { Fail POOL usage "pool wait: unknown option \"$a\"" }
        if {$i + 1 >= [llength $argl]} { Fail POOL usage "pool wait: -timeout needs a value" }
        set ms [_dur2ms POOL [lindex $argl [expr {$i + 1}]]]
    }
    if {[dict get $POOL $tok fatal] ne ""} {
        return -code error -errorcode [dict get $POOL $tok fatalcode] [dict get $POOL $tok fatal]
    }
    if {![dict get $POOL $tok done]} {
        set ::machteld::POOL_DONE($tok) 0
        set timer [after $ms [list ::machteld::PoolWaitTimeout $tok]]
        try {
            vwait ::machteld::POOL_DONE($tok)
        } finally {
            after cancel $timer
        }
        # `close` unsets POOL_DONE to wake vwait. Check the owned state before
        # touching the notification or results, since a GUI callback may have
        # invalidated the token while this wait was servicing events.
        if {![dict exists $POOL $tok]} { Fail POOL nohandle "no such pool" }
        if {$::machteld::POOL_DONE($tok) eq "timeout"} {
            Fail POOL timeout "pool timed out with [dict size [dict get $POOL $tok inflight]] item(s) in flight"
        }
    }
    if {[dict get $POOL $tok fatal] ne ""} {
        return -code error -errorcode [dict get $POOL $tok fatalcode] [dict get $POOL $tok fatal]
    }
    # IN SUBMISSION ORDER. Replies arrive in whatever order the workers finish,
    # which is not an order any caller asked for; the id is the item's index, so
    # the answer can be handed back aligned with what went in.
    set byid {}
    foreach r [dict get $POOL $tok results] { dict set byid [dict get $r id] $r }
    set out {}
    for {set k 0} {$k < [dict get $POOL $tok submitted]} {incr k} {
        if {[dict exists $byid $k]} { lappend out [dict get $byid $k] }
    }
    return $out
}

proc ::machteld::PoolInfo {tok} {
    variable POOL
    return [dict create \
        width    [dict get $POOL $tok width] \
        workers  [llength [dict get $POOL $tok workers]] \
        pending  [llength [dict get $POOL $tok pending]] \
        inflight [dict size [dict get $POOL $tok inflight]] \
        results  [llength [dict get $POOL $tok results]] \
        dead     [dict get $POOL $tok dead] \
        requeued [dict get $POOL $tok requeued] \
        done     [dict get $POOL $tok done] \
        fatal    [dict get $POOL $tok fatal] \
        maxtries [dict get $POOL $tok maxtries] \
        limits   [dict get $POOL $tok limits] \
        batchbytes [dict get $POOL $tok batchbytes] \
        resultbytes [dict get $POOL $tok resultbytes] \
        stderr   [encoding convertfrom -profile replace utf-8 [dict get $POOL $tok errbuf]]]
}

proc ::machteld::PoolStop {tok} {
    variable POOL
    dict for {c timer} [dict get $POOL $tok resumes] { after cancel $timer }
    dict set POOL $tok resumes {}
    foreach c [dict get $POOL $tok workers] {
        catch {
            set ci [child info $c]
            foreach k {stdout stderr} {
                if {[dict exists $ci $k]} { chan event [dict get $ci $k] readable {} }
            }
            # Closing stdin is what gives a well-behaved worker its EOF, so it
            # exits on its own and `child close` has nothing to kill.
            if {[dict exists $ci stdin]} { chan close [dict get $ci stdin] }
        }
        catch {child close $c}
    }
    dict set POOL $tok workers {}
    dict set POOL $tok readers {}
}

proc ::machteld::PoolAbort {tok code message} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    PoolStop $tok
    dict set POOL $tok fatal $message
    dict set POOL $tok fatalcode [list MACHTELD POOL $code]
    dict set POOL $tok done 1
    set ::machteld::POOL_DONE($tok) 1
}

proc ::machteld::PoolClose {tok} {
    variable POOL
    PoolStop $tok
    dict unset POOL $tok
    catch {unset ::machteld::POOL_DONE($tok)}
    return
}

::machteld::MetaDefine pool [dict create kind tcl args args domain POOL \
    codes {badvalue failed launch limit nohandle timeout usage} replycodes {poison} \
    options {-arg0 -cpu -dir -env -maxbatch -maxframe -maxitems -maxresults -maxtries -mem -timeout -width} \
    defaults [dict create maxtries 1 maxframe 16777216 maxitems 10000 maxbatch 67108864 maxresults 67108864] \
    doc machteld/command/pool \
    subcommands [dict create \
        create [dict create options {-arg0 -cpu -dir -env -maxbatch -maxframe -maxitems -maxresults -maxtries -mem -timeout -width} doc machteld/command/pool#create] \
        submit [dict create options {} doc machteld/command/pool#submit] \
        wait [dict create options {-timeout} doc machteld/command/pool#wait] \
        info [dict create options {} returns {batchbytes dead done fatal inflight limits maxtries pending requeued resultbytes results stderr width workers} doc machteld/command/pool#info] \
        close [dict create options {} doc machteld/command/pool#close]]]
