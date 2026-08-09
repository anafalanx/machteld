# lifelab -- run a field of Game-of-Life windows, each its own process, and
# record how every one of them died.
#
#   lifelab                                  ;# 10 at a time, 50 in total
#   lifelab --windows 60 --total 600         ;# the full field
#   lifelab --cap 600 --grace 20 --out run.jsonl
#   lifelab --selftest
#
# WHY THIS IS `child start` AND NOT `pmap`. A pool exists for items: short
# request-reply work that a persistent worker picks up, answers, and forgets. A
# Life window is the opposite of an item -- it is one long-lived process with a
# window, its own event loop, and a death to report. Handing it to a pool would
# mean a worker blocked for ten minutes on a single "request", which is a pool
# with the pooling switched off. So: `child start -timeout`, `child info` to
# poll, and a refill each time one dies. The measurement in docs/parallel.md
# says the same thing from the other side -- for one external program per item,
# `child start` beats the pool, because the pool's worker is a middleman.
#
# THE DIRECTOR HAS A WINDOW, WHICH DECIDES HOW IT WAITS. `wait -any` blocks, and
# a blocked director is a frozen dashboard. So supervision runs off the event
# loop: `after 250` -> ask each child whether it is still running -> harvest the
# ones that are not -> refill. That is the two-ways-to-wait rule in
# docs/execution-model.md, and this tool is what it is for.
#
# NOTHING SURVIVES THIS PROCESS. Every window is born in the director's job
# object, so closing the dashboard -- or killing it, or a crash -- takes all ten
# with it. That is machteld's anti-orphan law doing the work that would
# otherwise be a cleanup script nobody remembers to run.

package require Tk

namespace eval ::lab {
    namespace path ::machteld

    variable LIVE    {}        ;# token -> {seed slot t0}
    variable REC     {}        ;# finished records, in completion order
    variable spawned 0
    variable width   10
    variable total   50
    variable capms   600000
    variable gracems 20000
    variable cmd     {}        ;# argv prefix that starts one window
    variable cell    3
    variable out     ""
    variable fh      ""
    variable t0      0
    variable slots   {}
    variable finished 0
}

# HOW MANY TO START RIGHT NOW. Pure, so the scheduler can be tested without
# spawning anything: room in the field, capped by what is left of the budget.
proc ::lab::to_spawn {live spawned width total} {
    expr {max(0, min($width - $live, $total - $spawned))}
}

# Tile positions for a field of n windows on a screen of sw x sh. Deliberately
# takes the screen as arguments rather than asking Tk, so the tiling is testable
# with no display and reproducible in the report.
proc ::lab::tile {n sw sh cw ch} {
    set cols [expr {max(1, $sw / $cw)}]
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        set x [expr {($i % $cols) * $cw}]
        set y [expr {(($i / $cols) % max(1, $sh / $ch)) * $ch}]
        lappend out "+$x+$y"
    }
    return $out
}

# ONE FINISHED WINDOW, AS A RECORD. The child reports what only it can know --
# which generation it reached, what was left alive, whether it settled. The
# DIRECTOR reports duration and outcome, and where they overlap the director
# wins: a child's own clock is not evidence about a child, and a child killed at
# the cap never gets to file a report at all.
proc ::lab::record {seed ms r} {
    set st  [dict get $r status]
    set out [string trim [dict get $r out]]
    set mine [dict create seed $seed ms $ms status $st]
    set theirs {}
    if {$out ne ""} {
        catch {set theirs [json decode [lindex [split $out \n] end]]}
    }
    set rec [dict merge $theirs $mine]
    # `outcome` in plain words, which is what the summary counts.
    if {$st eq "timeout"} {
        dict set rec outcome timedout
    } elseif {![dict exists $rec outcome]} {
        dict set rec outcome [expr {$st eq "ok" ? "gone" : $st}]
    }
    return $rec
}

proc ::lab::summarise {recs} {
    set by [dict create]
    foreach r $recs {
        set o [dict get $r outcome]
        dict incr by $o
    }
    return $by
}

# --- running the field -------------------------------------------------------

proc ::lab::launch {slot} {
    variable cmd ; variable spawned ; variable LIVE ; variable capms
    variable gracems ; variable slots ; variable cell
    set seed $spawned
    incr spawned
    set geo [lindex $slots $slot]
    set c [child start -timeout ${capms}ms -- {*}$cmd \
               --seed $seed --geometry $geo --grace ${gracems}ms --cell $cell]
    dict set LIVE $c [list $seed $slot [clock milliseconds]]
    return $c
}

proc ::lab::harvest {c} {
    variable LIVE ; variable REC ; variable fh ; variable finished
    lassign [dict get $LIVE $c] seed slot t0
    set r [child wait $c]                        ;# already finished: returns at once
    catch {child close $c}
    dict unset LIVE $c
    set rec [record $seed [expr {[clock milliseconds] - $t0}] $r]
    lappend REC $rec
    incr finished
    if {$fh ne ""} { catch { puts $fh [json encode $rec] ; flush $fh } }
    return $slot
}

proc ::lab::tick {} {
    variable LIVE ; variable spawned ; variable total ; variable width
    # Ask, do not wait. `child info` is a question; `child wait` with no bound is
    # only safe once the answer is "not running", which is why the order matters.
    set freed {}
    foreach c [dict keys $LIVE] {
        if {[catch {child info $c} ci]} { lappend freed [harvest $c] ; continue }
        if {![dict get $ci running]} { lappend freed [harvest $c] }
    }
    # Refill: one new window for each that closed, until the budget is spent.
    # After that the field just drains -- "let all existing windows run until
    # death", which is the whole reason `to_spawn` clamps on both sides.
    set n [to_spawn [dict size $LIVE] $spawned $width $total]
    for {set i 0} {$i < $n} {incr i} {
        launch [expr {$i < [llength $freed] ? [lindex $freed $i] : [dict size $LIVE]}]
    }
    refresh
    if {$spawned >= $total && [dict size $LIVE] == 0} { finish ; return }
    after 250 ::lab::tick
}

# --- the dashboard -----------------------------------------------------------

proc ::lab::build_ui {} {
    variable total ; variable width
    wm title . "lifelab — $width at a time, $total in total"
    wm geometry . 560x360+40+40
    . configure -background #12151c
    label .h -text "" -font {Consolas 11 bold} -anchor w \
        -background #12151c -foreground #d7e0ea -padx 10 -pady 8
    pack .h -fill x
    label .c -text "" -font {Consolas 10} -anchor w -justify left \
        -background #12151c -foreground #7fd1b9 -padx 10
    pack .c -fill x
    text .t -height 14 -font {Consolas 9} -background #0d1016 -foreground #93a4b8 \
        -borderwidth 0 -highlightthickness 0 -padx 10 -pady 6
    pack .t -fill both -expand 1
    .t configure -state disabled
    wm protocol . WM_DELETE_WINDOW [list ::lab::finish]
}

proc ::lab::refresh {} {
    variable spawned ; variable total ; variable LIVE ; variable REC ; variable t0
    variable finished
    set el [expr {([clock milliseconds] - $t0) / 1000}]
    .h configure -text [format "spawned %d/%d   live %d   done %d   elapsed %d:%02d" \
        $spawned $total [dict size $LIVE] $finished [expr {$el / 60}] [expr {$el % 60}]]
    set by [summarise $REC]
    set parts {}
    foreach k [lsort [dict keys $by]] { lappend parts "$k [dict get $by $k]" }
    .c configure -text [expr {[llength $parts] ? [join $parts "   "] : "no windows have closed yet"}]
    .t configure -state normal
    .t delete 1.0 end
    foreach r [lrange $REC end-13 end] {
        .t insert end [format "seed %-4d %-11s %-9s %6.1fs  gen %-6s pop %s\n" \
            [dict get $r seed] \
            [expr {[dict exists $r pattern] ? [dict get $r pattern] : "?"}] \
            [dict get $r outcome] \
            [expr {[dict get $r ms] / 1000.0}] \
            [expr {[dict exists $r generations] ? [dict get $r generations] : "-"}] \
            [expr {[dict exists $r population] ? [dict get $r population] : "-"}]]
    }
    .t configure -state disabled
}

# The report. Written to stdout as well as the JSONL file, because a run whose
# only record is a file nobody opens has not reported anything.
proc ::lab::finish {} {
    variable REC ; variable LIVE ; variable fh ; variable out ; variable t0
    variable spawned
    foreach c [dict keys $LIVE] { catch {child kill $c} ; catch {child close $c} }
    if {$fh ne ""} { catch {close $fh} ; set fh "" }
    set el [expr {([clock milliseconds] - $t0) / 1000.0}]
    set lines {}
    lappend lines [format "\n%d windows spawned, %d recorded, %.1fs elapsed" \
        $spawned [llength $REC] $el]
    dict for {k v} [summarise $REC] { lappend lines [format "  %-10s %d" $k $v] }
    set ms [lmap r $REC {dict get $r ms}]
    if {[llength $ms]} {
        set srt [lsort -integer $ms]
        lappend lines [format "  median %.1fs   min %.1fs   max %.1fs" \
            [expr {[lindex $srt [expr {[llength $srt] / 2}]] / 1000.0}] \
            [expr {[lindex $srt 0] / 1000.0}] [expr {[lindex $srt end] / 1000.0}]]
    }
    if {$out ne ""} { lappend lines "  records: $out" }
    catch {puts [join $lines \n]}
    exit 0
}

# --- selftest ----------------------------------------------------------------
# The scheduler, the tiling and the record builder, with no windows and no
# children. Everything here is a claim the run depends on and would otherwise
# only be checked by watching sixty windows and hoping.
proc ::lab::selftest {} {
    set ::lab::fails_ 0
    proc ck {name ok} {
        if {$ok} { puts "ok   $name" } else { incr ::lab::fails_ ; puts "FAIL $name" }
    }

    ck "a cold start fills the field"      [expr {[to_spawn 0 0 10 50] == 10}]
    ck "a full field spawns nothing"       [expr {[to_spawn 10 10 10 50] == 0}]
    ck "one death, one replacement"        [expr {[to_spawn 9 10 10 50] == 1}]
    # The budget clamp: near the end the field must NOT be refilled past the total.
    ck "the budget clamps the refill"      [expr {[to_spawn 8 48 10 50] == 2}]
    ck "a spent budget spawns nothing"     [expr {[to_spawn 4 50 10 50] == 0}]
    ck "and never goes negative"           [expr {[to_spawn 12 50 10 50] == 0}]

    set s [tile 10 1920 1080 190 220]
    ck "one slot per window"               [expr {[llength $s] == 10}]
    ck "slots are distinct"                [expr {[llength [lsort -unique $s]] == 10}]
    ck "slots are on-screen geometries"    [expr {[regexp {^\+\d+\+\d+$} [lindex $s 9]]}]
    ck "a narrow screen still tiles"       [expr {[llength [tile 10 800 600 190 220]] == 10}]

    # A window that settled and reported: the child's facts survive, the
    # director's duration wins over the child's own clock.
    set r [record 7 4210 [dict create status ok out \
        {{"seed":7,"pattern":"acorn","outcome":"stale","generations":812,"population":44,"ms":9999}} \
        err {} exit 0 pid 1 truncated {}]]
    ck "a settled window keeps its pattern"   [expr {[dict get $r pattern] eq "acorn"}]
    ck "it keeps the generation count"        [expr {[dict get $r generations] == 812}]
    ck "the DIRECTOR's duration wins"         [expr {[dict get $r ms] == 4210}]
    ck "outcome comes through as stale"       [expr {[dict get $r outcome] eq "stale"}]

    # A window killed at the cap reports nothing at all -- the director must
    # still produce a complete record from the outside alone.
    set r [record 8 600123 [dict create status timeout out {} err {} exit 1 pid 2 truncated {}]]
    ck "a capped window is still recorded"    [expr {[dict get $r seed] == 8}]
    ck "and is marked timedout"               [expr {[dict get $r outcome] eq "timedout"}]
    ck "with the director's duration"         [expr {[dict get $r ms] == 600123}]

    # Garbage on stdout must not take the run down with it.
    set r [record 9 100 [dict create status ok out "not json at all" err {} exit 0 pid 3 truncated {}]]
    ck "unparseable output is survivable"     [expr {[dict get $r seed] == 9}]

    set by [summarise [list [dict create outcome stale] [dict create outcome stale] \
                            [dict create outcome timedout]]]
    ck "the summary counts outcomes"          [expr {[dict get $by stale] == 2 && [dict get $by timedout] == 1}]

    if {$::lab::fails_} { puts "FAILURES: $::lab::fails_" ; exit 1 }
    puts "ALL PASS: 0 failure(s)"
    exit 0
}

# --- arguments ---------------------------------------------------------------
set SPEC {
    --windows  {type int    default 10 min 1 max 200  help "how many windows run at once"}
    --total    {type int    default 50 min 1 max 5000 help "how many to spawn before draining"}
    --cap      {type string default 10m help "how long any one window may live (90s, 10m)"}
    --grace    {type string default 20s help "how long a settled window stays up (20s, 2m)"}
    --cellsize {type int    default 3 min 1 max 20    help "pixels per cell in each window"}
    --out      {type string default ""  help "JSONL record file (default build/lifelab.jsonl)"}
    --selftest {type flag   help "run the scheduler's own tests with no windows and exit"}
}
if {[catch {::machteld::cli parse $argv $SPEC} opt]} {
    catch {puts stderr "lifelab: $opt"}
    catch {puts stderr [::machteld::cli usage $SPEC lifelab]}
    exit 2
}
if {[dict get $opt help]} { catch {puts [::machteld::cli usage $SPEC lifelab]} ; exit 0 }
if {[dict get $opt selftest]} { ::lab::selftest }

set ::lab::width  [dict get $opt windows]
set ::lab::total  [dict get $opt total]
# Durations in the palette's own syntax, parsed by the palette's own parser --
# `cli duration`, which is `_dur2ms`, which is what every verb uses. These flags
# took bare integers until that parser was exposed, which meant this tool
# accepted `--cap 600` while `child start -timeout 600` next to it was refused:
# the toolkit's convention not kept by the toolkit's own tools.
#
# Parsed at the edge, so a bad duration is refused before ten windows start
# rather than by each of them separately.
if {[catch {::machteld::cli duration [dict get $opt cap]} ::lab::capms]} {
    catch {puts stderr "lifelab: --cap: $::lab::capms"}
    exit 2
}
if {[catch {::machteld::cli duration [dict get $opt grace]} ::lab::gracems]} {
    catch {puts stderr "lifelab: --grace: $::lab::gracems"}
    exit 2
}

# The window exe sits beside this one when both are wrapped, and beside the
# script when this is run as a script. Resolved rather than assumed, because a
# director that cannot find its windows should say so now and not in 250 ms.
set here [file dirname [info nameofexecutable]]
set wexe [file join $here life.exe]
if {[file exists $wexe]} {
    set ::lab::cmd [list $wexe]                       ;# wrapped: the exe is the window
} else {
    # Run as a script: the exe is the interpreter, so the window's script has to
    # be named too. Same distinction `sums` makes, for the same reason.
    set alt [file join [file dirname [file dirname [file normalize [info script]]]] life main.tcl]
    if {![file exists $alt]} {
        catch {puts stderr "lifelab: cannot find life.exe beside $here, nor $alt"}
        exit 2
    }
    set ::lab::cmd [list [info nameofexecutable] $alt]
}
set ::lab::cell [dict get $opt cellsize]

set ::lab::out [dict get $opt out]
if {$::lab::out eq ""} { set ::lab::out [file join $here lifelab.jsonl] }
if {[catch {open $::lab::out w} ::lab::fh]} { set ::lab::fh "" }
if {$::lab::fh ne ""} { fconfigure $::lab::fh -translation lf }

::lab::build_ui
set ::lab::t0 [clock milliseconds]
set ::lab::slots [::lab::tile $::lab::width \
    [winfo screenwidth .] [winfo screenheight .] 190 220]
::lab::tick
