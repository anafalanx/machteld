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
# NO POLLING ANYWHERE. `chan event` on each worker's stdout does the multiplexing
# that `wait -any` does by blocking, so a Tk tool stays responsive and an idle
# pool costs nothing.
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

proc ::machteld::pool {args} {
    variable POOL
    variable POOL_SEQ
    set subs {create submit wait info close}
    set opts {-width -maxtries -timeout -arg0 -cpu -dir -env -mem}

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
    set maxtries 3
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
                if {![string is integer -strict $v] || $v < 1 || $v > 256} {
                    Fail POOL badvalue "pool create: -width must be between 1 and 256"
                }
                set width $v
            }
            -maxtries {
                if {![string is integer -strict $v] || $v < 1} {
                    Fail POOL badvalue "pool create: -maxtries must be at least 1"
                }
                set maxtries $v
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
        pending {} results {} inflight {} workers {} nextid 0 \
        dead 0 requeued 0 errbuf "" fatal "" done 1 submitted 0 submitted_once 0]
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
    set out [dict get $ci stdout]
    set err [dict get $ci stderr]
    # child start -channels hands over byte-oriented (binary) channels. The
    # worker protocol is UTF-8 JSON lines and `worker serve` configures its own
    # ends that way, so the director must say so too or any character above
    # U+00FF leaves as "?" and arrives as mojibake.
    fconfigure [dict get $ci stdin] -blocking 0 -buffering line -encoding utf-8 -translation lf
    fconfigure $out -blocking 0 -buffering line -encoding utf-8 -translation lf
    fconfigure $err -blocking 0 -encoding utf-8 -translation lf
    chan event $out readable [list ::machteld::PoolReadable $tok $c]
    chan event $err readable [list ::machteld::PoolStderr  $tok $c]
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
    if {[catch {read $ch} chunk]} return
    if {$chunk ne ""} {
        set buf [dict get $POOL $tok errbuf]
        append buf $chunk
        if {[string length $buf] > $POOL_ERRCAP} {
            set buf [string range $buf end-[expr {$POOL_ERRCAP - 1}] end]
        }
        dict set POOL $tok errbuf $buf
    }
}

proc ::machteld::PoolSubmit {tok items} {
    variable POOL
    if {[dict get $POOL $tok submitted_once]} {
        Fail POOL usage "pool submit: a pool accepts exactly one batch; create another pool"
    }
    # `items` is always a list of request dicts; Tcl values do not preserve how
    # the caller happened to spell a one-element list.
    set pend [dict get $POOL $tok pending]
    set next [dict get $POOL $tok nextid]
    foreach it $items {
        if {[catch {dict size $it}]} { Fail POOL badvalue "pool submit: each item must be a dict" }
        if {![dict exists $it op]} { Fail POOL badvalue "pool submit: each item needs an op" }
        dict set it id $next
        incr next
        lappend pend $it
    }
    dict set POOL $tok pending $pend
    dict set POOL $tok nextid $next
    dict set POOL $tok submitted $next
    dict set POOL $tok submitted_once 1
    dict set POOL $tok done 0
    foreach c [dict get $POOL $tok workers] { PoolFeed $tok $c }
    return
}

proc ::machteld::PoolFeed {tok c} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    if {[dict exists [dict get $POOL $tok inflight] $c]} return
    set pend [dict get $POOL $tok pending]
    if {![llength $pend]} { PoolCheckDone $tok ; return }
    set item [lindex $pend 0]
    dict set POOL $tok pending [lrange $pend 1 end]
    dict set POOL $tok inflight [dict replace [dict get $POOL $tok inflight] $c $item]
    if {[catch {
        set ci [child info $c]
        set in [dict get $ci stdin]
        puts $in [json encode -plain -dict $item]
        flush $in
    }]} {
        PoolDied $tok $c
    }
}

proc ::machteld::PoolReadable {tok c} {
    variable POOL
    variable POOL_ERRCAP
    if {![dict exists $POOL $tok]} return
    if {[catch {child info $c} ci]} { PoolDied $tok $c ; return }
    if {![dict exists $ci stdout]} { PoolDied $tok $c ; return }
    set ch [dict get $ci stdout]
    # A non-blocking `gets` returning -1 means "no COMPLETE line yet" as often as
    # it means trouble; only `eof` tells a dead worker from a slow one, and
    # confusing the two makes a pool either spin or hang.
    while {[gets $ch line] >= 0} {
        if {$line eq ""} continue
        if {[catch {json decode $line} rep] ||
            [catch {json encode -plain $rep} encoded] ||
            ![string match \{* $encoded] ||
            ![dict exists $rep id] || ![dict exists $rep ok]} {
            dict set POOL $tok errbuf [string range \
                "[dict get $POOL $tok errbuf]protocol error: worker wrote a malformed reply\n" end-[expr {$POOL_ERRCAP - 1}] end]
            PoolDied $tok $c
            return
        }
        if {![dict exists [dict get $POOL $tok inflight] $c] ||
            [dict get $rep id] ne [dict get $POOL $tok inflight $c id]} {
            dict set POOL $tok errbuf [string range \
                "[dict get $POOL $tok errbuf]protocol error: worker replied with an unexpected id\n" end-[expr {$POOL_ERRCAP - 1}] end]
            PoolDied $tok $c
            return
        }
        dict set POOL $tok results [linsert [dict get $POOL $tok results] end $rep]
        dict set POOL $tok inflight [dict remove [dict get $POOL $tok inflight] $c]
        PoolFeed $tok $c
        # A failed feed has already declared this worker dead and closed its
        # channels; reading $ch again would raise out of the event callback.
        if {$c ni [dict get $POOL $tok workers]} return
    }
    if {[eof $ch]} { PoolDied $tok $c ; return }
    PoolCheckDone $tok
}

# A worker died. Its outstanding item goes back -- unless it has already killed
# enough workers to look like the item's fault rather than the worker's, which is
# the difference between resilience and an infinite loop.
proc ::machteld::PoolDied {tok c} {
    variable POOL
    if {![dict exists $POOL $tok]} return
    if {$c ni [dict get $POOL $tok workers]} return
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
    # Per-item maxtries makes replacement finite without a global death ceiling,
    # which could strand later items after earlier poison consumed the allowance.
    if {[llength [dict get $POOL $tok pending]]} {
        if {[catch {PoolSpawn $tok} new]} {
            dict set POOL $tok fatal $new
            dict set POOL $tok done 1
            set ::machteld::POOL_DONE($tok) 1
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
        dict set POOL $tok results [linsert [dict get $POOL $tok results] end \
            [dict create id $id ok 0 code {MACHTELD POOL poison} \
                         msg "killed $tries workers; giving up"]]
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
        return -code error -errorcode {MACHTELD POOL launch} [dict get $POOL $tok fatal]
    }
    if {![dict get $POOL $tok done]} {
        set ::machteld::POOL_DONE($tok) 0
        set timer [after $ms [list set ::machteld::POOL_DONE($tok) timeout]]
        vwait ::machteld::POOL_DONE($tok)
        after cancel $timer
        if {$::machteld::POOL_DONE($tok) eq "timeout"} {
            Fail POOL timeout "pool timed out with [dict size [dict get $POOL $tok inflight]] item(s) in flight"
        }
    }
    if {[dict get $POOL $tok fatal] ne ""} {
        return -code error -errorcode {MACHTELD POOL launch} [dict get $POOL $tok fatal]
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
        stderr   [dict get $POOL $tok errbuf]]
}

proc ::machteld::PoolClose {tok} {
    variable POOL
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
    dict unset POOL $tok
    catch {unset ::machteld::POOL_DONE($tok)}
    return
}

::machteld::MetaDefine pool [dict create kind tcl args args domain POOL \
    codes {badvalue launch nohandle timeout usage} replycodes {poison} \
    options {-arg0 -cpu -dir -env -maxtries -mem -timeout -width} doc machteld/command/pool \
    subcommands [dict create \
        create [dict create options {-arg0 -cpu -dir -env -maxtries -mem -timeout -width} doc machteld/command/pool#create] \
        submit [dict create options {} doc machteld/command/pool#submit] \
        wait [dict create options {-timeout} doc machteld/command/pool#wait] \
        info [dict create options {} returns {dead done fatal inflight pending requeued results stderr width workers} doc machteld/command/pool#info] \
        close [dict create options {} doc machteld/command/pool#close]]]
