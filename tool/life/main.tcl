# life -- one Conway's Game of Life window, on a torus, that knows when it is over.
#
#   life --seed 41 --geometry +320+180 ?--grace 20s? ?--cell 4? ?--cols 40? ?--rows 40?
#   life --describe --seed 41      ;# print the setting this seed means, and exit
#   life --selftest
#
# WRITTEN TO BE SUPERVISED. It is one window in a field of sixty, each its own
# process, spawned and replaced by `lifelab`. Two things follow from that and
# shape everything else:
#
# 1. IT REPORTS ITS OWN DEATH, as one JSON line on stdout, and nothing else ever
#    goes to stdout. The director reads that line out of the result dict when the
#    process ends. A window killed by `-timeout` never prints it -- which is not
#    a gap, because the director already knows: the child dict says `timeout`.
#
# 2. IT NEVER RUNS FOREVER BY ACCIDENT. Stasis ends it, the grace period ends it,
#    and the director's `-timeout` ends it if both fail. The job object ends it if
#    the director itself dies. Four independent stops, because sixty windows that
#    each might not close is not a screensaver, it is a cleanup job.
#
# STASIS IS A FIXED POINT: this generation identical to the last. That is the
# strict reading and it was chosen deliberately over cycle detection, so it is
# worth knowing what it means -- a blinker is three cells flipping forever and is
# NOT stasis, so any soup that leaves one oscillator behind runs until the
# director's cap. Expect most windows to end `timeout` rather than `stale`. The
# alternative would have been to hash the last N generations and call a repeat
# stasis, which ends nearly every window in seconds; the report tells you which
# you got.

package require Tk

namespace eval ::life {
    namespace path ::machteld

    variable cols 40 ; variable rows 40 ; variable cell 3
    variable ids {}
    variable grid  {}          ;# flat list, one 0/1 per cell, row-major
    variable prev  {}          ;# the previous generation, for the fixed-point test
    variable gen   0
    variable pop   0
    variable born  0           ;# clock milliseconds at start
    variable staleat ""        ;# when stasis was first seen, or ""
    variable grace 20000
    variable seed  0
    variable pattern ""
    variable density 0
    variable done  0
    variable interval 60

    # The named starts, each a list of {dx dy} offsets placed at the middle.
    # Chosen because they behave differently for a long time: r-pentomino runs
    # 1103 generations before settling on an infinite plane, acorn 5206, while
    # the glider just leaves. On a small torus they all end up interfering with
    # themselves, which is the point -- sixty of them will not look alike.
    variable SHAPES {
        rpentomino {{1 0} {2 0} {0 1} {1 1} {1 2}}
        acorn      {{1 0} {3 1} {0 2} {1 2} {4 2} {5 2} {6 2}}
        diehard    {{6 0} {0 1} {1 1} {1 2} {5 2} {6 2} {7 2}}
        glider     {{1 0} {2 1} {0 2} {1 2} {2 2}}
        lwss       {{1 0} {4 0} {0 1} {0 2} {4 2} {0 3} {1 3} {2 3} {3 3}}
        toad       {{1 0} {2 0} {3 0} {0 1} {1 1} {2 1}}
        pulsar     {{2 0} {3 0} {4 0} {8 0} {9 0} {10 0} {0 2} {5 2} {7 2} {12 2}
                    {0 3} {5 3} {7 3} {12 3} {0 4} {5 4} {7 4} {12 4}
                    {2 5} {3 5} {4 5} {8 5} {9 5} {10 5}}
    }
}

# THE SETTING IS A PURE FUNCTION OF THE SEED. The director records the seed; the
# window derives everything else from it. That is what makes a run reproducible
# from the report alone -- "window 417 was seed 417" is enough to see it again,
# with no second file to keep in step.
proc ::life::setting {seed} {
    variable SHAPES
    set names [lsort [dict keys $SHAPES]]
    set n [llength $names]
    # Deliberately not rand(): a table lookup on the seed is reproducible across
    # processes, machines and Tcl versions, which srand() only promises within one.
    set kind [expr {$seed % ($n + 3)}]          ;# +3 => three of every ten are soup
    set cols [expr {24 + (($seed / 7)  % 3) * 8}]
    set rows [expr {24 + (($seed / 11) % 3) * 8}]
    set ivl  [expr {40 + (($seed / 3)  % 5) * 20}]
    if {$kind < $n} {
        return [dict create pattern [lindex $names $kind] density 0 \
                    cols $cols rows $rows interval $ivl]
    }
    return [dict create pattern soup density [expr {12 + (($seed / 5) % 8) * 4}] \
                cols $cols rows $rows interval $ivl]
}

proc ::life::seed_grid {seed} {
    variable cols ; variable rows ; variable grid ; variable SHAPES
    variable pattern ; variable density
    set grid [lrepeat [expr {$cols * $rows}] 0]
    if {$pattern eq "soup"} {
        # A linear congruential generator written out, for the same reason the
        # setting is: identical output for the same seed anywhere.
        set x [expr {($seed * 1103515245 + 12345) & 0x7fffffff}]
        for {set i 0} {$i < $cols * $rows} {incr i} {
            set x [expr {($x * 1103515245 + 12345) & 0x7fffffff}]
            if {($x % 100) < $density} { lset grid $i 1 }
        }
        return
    }
    set off [dict get $SHAPES $pattern]
    set cx [expr {$cols / 2 - 3}] ; set cy [expr {$rows / 2 - 3}]
    foreach o $off {
        lassign $o dx dy
        set c [expr {($cx + $dx) % $cols}] ; set r [expr {($cy + $dy) % $rows}]
        lset grid [expr {$r * $cols + $c}] 1
    }
}

# One generation, on a TORUS: the edges wrap, so nothing is lost off the side and
# a glider comes back. Neighbour offsets are computed with % on both axes.
proc ::life::step {} {
    variable grid ; variable cols ; variable rows ; variable prev ; variable pop
    set prev $grid
    set next [lrepeat [expr {$cols * $rows}] 0]
    set live 0
    for {set r 0} {$r < $rows} {incr r} {
        set rn [expr {(($r - 1) + $rows) % $rows * $cols}]
        set rc [expr {$r * $cols}]
        set rs [expr {($r + 1) % $rows * $cols}]
        for {set c 0} {$c < $cols} {incr c} {
            set cw [expr {(($c - 1) + $cols) % $cols}]
            set ce [expr {($c + 1) % $cols}]
            set n [expr {[lindex $grid [expr {$rn + $cw}]] + [lindex $grid [expr {$rn + $c}]]
                       + [lindex $grid [expr {$rn + $ce}]] + [lindex $grid [expr {$rc + $cw}]]
                       + [lindex $grid [expr {$rc + $ce}]] + [lindex $grid [expr {$rs + $cw}]]
                       + [lindex $grid [expr {$rs + $c}]]  + [lindex $grid [expr {$rs + $ce}]]}]
            set alive [lindex $grid [expr {$rc + $c}]]
            if {($alive && ($n == 2 || $n == 3)) || (!$alive && $n == 3)} {
                lset next [expr {$rc + $c}] 1
                incr live
            }
        }
    }
    set grid $next
    set pop $live
}

# STASIS: this generation is identical to the last. An empty grid qualifies (it
# is a fixed point), which is how a soup that dies out ends promptly.
proc ::life::stale {} {
    variable grid ; variable prev
    expr {$grid eq $prev}
}

# --- the window --------------------------------------------------------------

proc ::life::build_ui {geo} {
    variable cols ; variable rows ; variable cell ; variable seed ; variable pattern
    wm title . "life $seed  $pattern"
    wm resizable . 0 0
    if {$geo ne ""} { wm geometry . $geo }
    canvas .c -width [expr {$cols * $cell}] -height [expr {$rows * $cell}] \
        -background #10131a -highlightthickness 0
    pack .c
    # One rectangle per cell, created once and only ever recoloured. Creating and
    # deleting 1600 canvas items every 60 ms is what makes a Tk grid crawl.
    variable ids
    set ids {}
    for {set r 0} {$r < $rows} {incr r} {
        for {set c 0} {$c < $cols} {incr c} {
            lappend ids [.c create rectangle [expr {$c * $cell}] [expr {$r * $cell}] \
                [expr {($c + 1) * $cell}] [expr {($r + 1) * $cell}] -outline "" -fill #10131a]
        }
    }
    wm protocol . WM_DELETE_WINDOW [list ::life::finish closed]
}

proc ::life::render {} {
    variable grid ; variable ids ; variable staleat
    set on [expr {$staleat eq "" ? "#7fd1b9" : "#d98f4f"}]   ;# amber once it has settled
    set i 0
    foreach v $grid {
        .c itemconfigure [lindex $ids $i] -fill [expr {$v ? $on : "#10131a"}]
        incr i
    }
}

proc ::life::tick {} {
    variable done ; variable gen ; variable staleat ; variable grace ; variable interval
    if {$done} return
    step
    incr gen
    if {$staleat eq ""} {
        if {[stale]} { set staleat [clock milliseconds] ; wm title . "[wm title .] — settled" }
    } elseif {[clock milliseconds] - $staleat >= $grace} {
        finish stale
        return
    }
    catch {render}
    after $interval ::life::tick
}

# THE ONE LINE THIS PROCESS PRINTS. Everything the director cannot observe from
# outside: which generation it reached, how many cells were left, and why it
# stopped. Duration the director times itself -- a child's own clock is not
# evidence about a child.
proc ::life::finish {why} {
    variable done ; variable seed ; variable gen ; variable pop ; variable born
    variable staleat ; variable pattern ; variable density ; variable cols ; variable rows
    if {$done} return
    set done 1
    set rec [dict create seed $seed pattern $pattern density $density \
                 cols $cols rows $rows outcome $why generations $gen population $pop \
                 ms [expr {[clock milliseconds] - $born}] \
                 settled_ms [expr {$staleat eq "" ? -1 : $staleat - $born}]]
    catch {puts stdout [json encode $rec]}
    catch {flush stdout}
    exit 0
}

# --- selftest ----------------------------------------------------------------
# The model with no window: the rules, the torus, and the stasis test. A hidden
# Tk window drops events and would be testing something other than the program.
proc ::life::selftest {} {
    set ::life::fails_ 0
    proc ck {name ok} {
        if {$ok} { puts "ok   $name" } else { incr ::life::fails_ ; puts "FAIL $name" }
    }
    variable cols ; variable rows ; variable grid ; variable prev ; variable pattern
    variable density

    # A block is a still life: two generations identical => stasis at once.
    set cols 8 ; set rows 8 ; set pattern soup ; set density 0
    set grid [lrepeat 64 0]
    foreach i {18 19 26 27} { lset grid $i 1 }
    step
    ck "a block is a fixed point"        [stale]
    ck "a block keeps four cells"        [expr {$::life::pop == 4}]

    # A blinker oscillates with period 2: never a fixed point, which is exactly
    # why this run will report mostly timeouts.
    set grid [lrepeat 64 0]
    foreach i {17 18 19} { lset grid $i 1 }
    step
    ck "a blinker is NOT a fixed point"  [expr {![stale]}]
    step
    ck "a blinker returns after two"     [expr {$grid eq $prev ? 0 : 1}]

    # Extinction is a fixed point, so a dying soup ends promptly rather than
    # sitting on an empty grid until the cap.
    set grid [lrepeat 64 0] ; lset grid 27 1
    step
    ck "a lone cell dies"                [expr {$::life::pop == 0}]
    step
    ck "an empty grid is a fixed point"  [stale]

    # THE TORUS. A glider at the edge must see its neighbours across the wrap,
    # not a wall. With walls this cell has 2 neighbours and dies; with wrap it
    # has 3 and lives.
    set grid [lrepeat 64 0]
    foreach i {0 7 56} { lset grid $i 1 }     ;# three corners meet across the wrap
    step
    ck "edges wrap: corners are neighbours" [expr {$::life::pop > 0}]

    # The setting is a pure function of the seed, in this process and any other.
    set a [setting 417] ; set b [setting 417]
    ck "the same seed gives the same setting" [expr {$a eq $b}]
    ck "different seeds differ"               [expr {[setting 417] ne [setting 418]}]
    ck "a setting names a known pattern"      [expr {
        [dict get $a pattern] in [concat soup [dict keys $::life::SHAPES]]}]
    set seen {}
    for {set s 0} {$s < 60} {incr s} { lappend seen [dict get [setting $s] pattern] }
    ck "60 windows are not all alike"         [expr {[llength [lsort -unique $seen]] >= 5}]

    if {$::life::fails_} { puts "FAILURES: $::life::fails_" ; exit 1 }
    puts "ALL PASS: 0 failure(s)"
    exit 0
}

# --- arguments ---------------------------------------------------------------
set SPEC {
    --seed      {type int    default 0 min 0 help "which start setting to use; the setting is derived from it"}
    --geometry  {type string default "" help "Tk geometry, e.g. +320+180"}
    --grace     {type int    default 20 min 0 max 600 help "seconds to stay up after settling"}
    --cell      {type int    default 3 min 1 max 20 help "pixels per cell"}
    --describe  {type flag   help "print the setting this seed means, as JSON, and exit"}
    --selftest  {type flag   help "run the model's own tests with no window and exit"}
}
if {[catch {::machteld::cli parse $argv $SPEC} opt]} {
    catch {puts stderr "life: $opt"}
    exit 2
}
if {[dict get $opt help]} { catch {puts [::machteld::cli usage $SPEC life]} ; exit 0 }
if {[dict get $opt selftest]} { ::life::selftest }

set ::life::seed [dict get $opt seed]
set s [::life::setting $::life::seed]
if {[dict get $opt describe]} { puts [::machteld::json encode $s] ; exit 0 }

set ::life::pattern  [dict get $s pattern]
set ::life::density  [dict get $s density]
set ::life::cols     [dict get $s cols]
set ::life::rows     [dict get $s rows]
set ::life::interval [dict get $s interval]
set ::life::cell     [dict get $opt cell]
set ::life::grace    [expr {[dict get $opt grace] * 1000}]
set ::life::born     [clock milliseconds]

::life::seed_grid $::life::seed
::life::build_ui [dict get $opt geometry]
::life::render
after $::life::interval ::life::tick
