# spike/pool/pool.tcl -- a persistent worker pool over Tcl channels.
#
# SPIKE, not palette. The point is to find out whether the design in
# docs/parallel.md is reliable BEFORE any C is written, so everything here runs
# on stock Tcl: `open |cmd r+` for the channel, `chan event` for the
# multiplexing, `vwait` for the wait. No machteld verb is required, which is
# exactly what makes it a fair test -- if it is fragile here it will be fragile
# with a job object wrapped around it.
#
# WHAT THIS SPIKE IS TRYING TO BREAK, in order of how likely I thought each was
# to be wrong:
#
#   1. Deadlock by pipe buffer. A worker writing more than the pipe holds while
#      the director is not reading blocks the worker; a director writing while
#      the worker is blocked blocks the director. Non-blocking channels on both
#      sides are the defence, and this is the part most likely to be subtly wrong
#      on Windows.
#   2. A worker dying mid-item -- the channel reaches EOF with work outstanding.
#   3. Errors crossing the process boundary with their errorcode intact.
#   4. Orphans: does closing the pool actually end every worker?
#
# The pool keeps exactly ONE item in flight per worker. That is not a
# performance choice, it is a legibility one: with one outstanding request the
# mapping from a reply to the item it answers is a fact, not a correlation, and
# a dead worker has exactly one item to requeue.

namespace eval ::pool {
    # WITHOUT THIS LINE NOTHING HERE WORKS, and it fails in the most misleading
    # way available. The prelude puts the palette on the GLOBAL namespace path,
    # and Tcl does not consult the global path for a lookup that BEGINS inside
    # another namespace -- so `json encode` here is simply not a command. Every
    # Feed threw, the catch around it read that as a dead worker, and the pool
    # spent its time killing and respawning perfectly healthy processes: 12
    # deaths and 8 requeues to deliver 4 items. The symptom pointed at the pipe;
    # the cause was name resolution. palette.md documents this and both shipped
    # tools carry the same line.
    namespace path ::machteld

    variable P
    variable seq 0
}

proc ::pool::create {cmd width args} {
    variable P
    variable seq
    set tok pool#[incr seq]
    dict set P $tok cmd $cmd
    dict set P $tok pending {}
    dict set P $tok results {}
    dict set P $tok inflight {}      ;# chan -> item
    dict set P $tok chans {}
    dict set P $tok dead 0
    dict set P $tok requeued 0
    dict set P $tok done 0
    dict set P $tok attempts {}      ;# item id -> tries, so a poison item cannot loop
    dict set P $tok maxtries [expr {[dict exists $args -maxtries] ? [dict get $args -maxtries] : 3}]
    for {set i 0} {$i < $width} {incr i} { Spawn $tok }
    return $tok
}

proc ::pool::Spawn {tok} {
    variable P
    set ch [open "|[dict get $P $tok cmd]" r+]
    # NON-BLOCKING IS THE WHOLE DEFENCE against hazard 1. With a blocking
    # channel, `puts` on a full pipe parks the director for as long as the worker
    # takes to drain it -- and if the worker is itself blocked writing a reply we
    # have not read, neither side ever moves.
    fconfigure $ch -translation lf -encoding utf-8 -blocking 0 -buffering line
    dict set P $tok chans [linsert [dict get $P $tok chans] end $ch]
    chan event $ch readable [list ::pool::Readable $tok $ch]
    return $ch
}

proc ::pool::submit {tok items} {
    variable P
    dict set P $tok pending [concat [dict get $P $tok pending] $items]
    foreach ch [dict get $P $tok chans] { Feed $tok $ch }
}

proc ::pool::Feed {tok ch} {
    variable P
    if {[dict exists [dict get $P $tok inflight] $ch]} { return }
    set pend [dict get $P $tok pending]
    if {![llength $pend]} { Maybedone $tok ; return }
    set item [lindex $pend 0]
    dict set P $tok pending [lrange $pend 1 end]
    dict set P $tok inflight [dict replace [dict get $P $tok inflight] $ch $item]
    if {[catch {puts $ch [json encode $item] ; flush $ch}]} {
        # The worker went away between spawning and writing.
        Died $tok $ch
    }
}

proc ::pool::Readable {tok ch} {
    variable P
    # A non-blocking `gets` returning -1 is not necessarily an error: it also
    # means "a partial line so far". Only `eof` distinguishes a dead worker from
    # a slow one, and confusing the two is how a pool either spins or hangs.
    while {[set n [gets $ch line]] >= 0} {
        if {$line eq ""} continue
        if {[catch {json decode $line} res]} continue
        dict set P $tok results [linsert [dict get $P $tok results] end $res]
        dict set P $tok inflight [dict remove [dict get $P $tok inflight] $ch]
        Feed $tok $ch
    }
    if {[eof $ch]} { Died $tok $ch ; return }
    Maybedone $tok
}

# A worker died. Its outstanding item goes back to the queue -- unless it has
# already killed enough workers to look like the item's fault rather than the
# worker's, which is the difference between resilience and an infinite loop.
proc ::pool::Died {tok ch} {
    variable P
    catch {chan event $ch readable {}}
    catch {chan close $ch}
    dict set P $tok chans [lsearch -all -inline -not -exact [dict get $P $tok chans] $ch]
    dict set P $tok dead [expr {[dict get $P $tok dead] + 1}]
    set infl [dict get $P $tok inflight]
    if {[dict exists $infl $ch]} {
        set item [dict get $infl $ch]
        dict set P $tok inflight [dict remove $infl $ch]
        set id [dict get $item id]
        set tries [expr {[dict exists [dict get $P $tok attempts] $id]
                         ? [dict get [dict get $P $tok attempts] $id] : 0}]
        incr tries
        dict set P $tok attempts [dict replace [dict get $P $tok attempts] $id $tries]
        if {$tries < [dict get $P $tok maxtries]} {
            dict set P $tok pending [linsert [dict get $P $tok pending] 0 $item]
            dict set P $tok requeued [expr {[dict get $P $tok requeued] + 1}]
        } else {
            dict set P $tok results [linsert [dict get $P $tok results] end \
                [dict create id $id ok 0 code {POOL poison} msg "killed $tries workers"]]
        }
    }
    # Replace the worker so the pool keeps its width, but only while there is
    # still work: replacing forever on a poisoned queue is a fork bomb.
    if {[llength [dict get $P $tok pending]] && [dict get $P $tok dead] < 64} {
        set new [Spawn $tok]
        Feed $tok $new
    }
    Maybedone $tok
}

proc ::pool::Maybedone {tok} {
    variable P
    if {![llength [dict get $P $tok pending]] && ![dict size [dict get $P $tok inflight]]} {
        dict set P $tok done 1
        set ::pool::finished($tok) 1
    }
}

proc ::pool::wait {tok {timeout 60000}} {
    variable P
    if {[dict get $P $tok done]} { return [dict get $P $tok results] }
    set ::pool::finished($tok) 0
    set after [after $timeout [list set ::pool::finished($tok) timeout]]
    vwait ::pool::finished($tok)
    after cancel $after
    if {$::pool::finished($tok) eq "timeout"} {
        return -code error -errorcode {POOL timeout} \
            "pool $tok timed out with [dict size [dict get $P $tok inflight]] in flight"
    }
    return [dict get $P $tok results]
}

proc ::pool::stats {tok} {
    variable P
    return [dict create workers [llength [dict get $P $tok chans]] \
                        results [llength [dict get $P $tok results]] \
                        pending [llength [dict get $P $tok pending]] \
                        inflight [dict size [dict get $P $tok inflight]] \
                        dead [dict get $P $tok dead] \
                        requeued [dict get $P $tok requeued]]
}

proc ::pool::close {tok} {
    variable P
    foreach ch [dict get $P $tok chans] {
        catch {chan event $ch readable {}}
        # `chan close`, never bare `close`: inside this namespace `close` finds
        # ::pool::close, which is this very proc.
        catch {chan close $ch}
    }
    dict unset P $tok
    catch {unset ::pool::finished($tok)}
}
