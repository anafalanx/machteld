# mt.tcl -- ::machteld::mt, a live view of what this session is controlling.
#
# `manifest` says what machteld CAN do. This says what it IS doing: the children
# it launched, the terminals it is steering, the directories it is watching, and
# the processes it started and deliberately let go. Creed 4 extended from
# structure to time.
#
#   mt              ;# open the window (raises it if already open)
#   mt -interval ms ;# how often to refresh, default 1000
#
# WHY THIS IS A PALETTE VERB AND NOT A WRAPPED EXE. Every handle machteld hands
# out -- child#N, pty#N, watch#N -- is a pointer in one interpreter's heap:
# `proc_ctx` is calloc'd per interpreter and passed to each command as its client
# data. There is no global registry, no shared section, no file. A separate
# monitor.exe would therefore enumerate its OWN children, which is nothing, and
# could not see another machteld's tokens at all. The tool has to run inside the
# session it reports on, so it has to ship as Tcl in the prelude. That is an
# architectural fact, not a packaging preference.
#
# READ-ONLY, AND NON-DESTRUCTIVE BY CONSTRUCTION. This is the sharper constraint.
# `watch read` DRAINS the event queue and `pty read` CONSUMES the child's output,
# so a monitor built on either would be stealing from the program it is watching
# -- an observer that changes what it observes is worse than no observer. Nothing
# here calls them. The only calls made are `child list` / `child info`,
# `pty list` / `pty info`, `watch list` / `watch info` and `ps list`, every one of
# which answers without taking anything away. `watch info` and `pty info` were
# added for exactly this: they report queue depth and pending bytes, where
# reading would have emptied them.

namespace eval ::machteld {
    variable MT_AFTER   ""
    variable MT_ROWS    {}
    variable MT_INTERVAL 1000
    variable MT_STARTED [clock seconds]
}

# --- model: one snapshot of everything this session controls ------------------
# Returns a list of {section key pid status detail} rows. No widget is touched,
# so the whole model is testable with no window -- which matters here more than
# usual, because the claim being tested is "this does not perturb anything".
proc ::machteld::MtSnapshot {} {
    set rows {}
    set mine {}

    foreach t [child list] {
        set i [child info $t]
        set pid [dict get $i pid]
        dict set mine $pid 1
        set status [expr {[dict get $i running] ? "running" : "exited"}]
        if {[dict exists $i exit]} { set status "exit [dict get $i exit]" }
        lappend rows [list children $t $pid $status [MtProcDetail $pid]]
    }

    foreach t [pty list] {
        set i [pty info $t]
        set pid [dict get $i pid]
        dict set mine $pid 1
        set pend [dict get $i pending]
        set detail [expr {$pend > 0 ? "$pend bytes waiting to be read" : "idle"}]
        if {[set d [MtProcDetail $pid]] ne ""} { set detail "$detail   --   $d" }
        lappend rows [list terminals $t $pid \
            [expr {[dict get $i running] ? "running" : "exited"}] $detail]
    }

    foreach t [watch list] {
        set i [watch info $t]
        set detail [dict get $i dir]
        if {[dict get $i recursive]} { append detail "   (recursive)" }
        append detail "   --   [dict get $i pending] queued"
        # A watch that dropped events has lost information the program will never
        # see. That is not a detail; say it where it cannot be missed.
        if {[dict get $i dropped] > 0} { append detail ", [dict get $i dropped] DROPPED" }
        lappend rows [list watches $t "" \
            [expr {[dict get $i armed] ? "armed" : "STALLED"}] $detail]
    }

    # What we started and do NOT supervise. `detach` is fire-and-forget on
    # purpose -- it returns a pid and tracks nothing -- so these processes are
    # invisible to `child list` by design. Showing them is the difference between
    # "what machteld controls" and "what machteld is responsible for", and a
    # monitor that quietly omitted them would be flattering itself.
    if {![catch {ps list} all]} {
        foreach r $all {
            if {[dict get $r ppid] != [pid]} continue
            if {[dict exists $mine [dict get $r pid]]} continue
            lappend rows [list untracked "(detached)" [dict get $r pid] "running" \
                [MtProcDetail [dict get $r pid]]]
        }
    }
    return $rows
}

# The join that makes this worth looking at: machteld knows the token and the
# pid, `ps` knows everything else about that pid.
proc ::machteld::MtProcDetail {pid} {
    if {$pid eq "" || [catch {ps info $pid} r]} { return "" }
    set out [dict get $r name]
    if {[dict get $r access] == 0} { return "$out   (not readable)" }
    append out [format "   %s   cpu %s" \
        [MtBytes [dict get $r mem]] [MtDuration [dict get $r cpu]]]
    return $out
}

proc ::machteld::MtBytes {n} {
    if {$n eq ""} { return "" }
    if {$n < 1024} { return "$n B" }
    foreach {lim unit} {1048576 KB 1073741824 MB 1099511627776 GB} {
        if {$n < $lim} { return [format "%.1f %s" [expr {$n * 1024.0 / $lim}] $unit] }
    }
    return [format "%.1f TB" [expr {$n / 1099511627776.0}]]
}

proc ::machteld::MtDuration {ms} {
    if {$ms eq ""} { return "" }
    set s [expr {$ms / 1000}]
    return [format "%d:%02d:%02d" [expr {$s/3600}] [expr {($s/60)%60}] [expr {$s%60}]]
}

proc ::machteld::MtSummary {rows} {
    variable MT_STARTED
    set n {children 0 terminals 0 watches 0 untracked 0}
    foreach r $rows { dict incr n [lindex $r 0] }
    set up [expr {[clock seconds] - $MT_STARTED}]
    set s [format "session pid %d   up %s   --   %d supervised, %d terminals, %d watches" \
        [pid] [MtDuration [expr {$up * 1000}]] \
        [dict get $n children] [dict get $n terminals] [dict get $n watches]]
    if {[dict get $n untracked] > 0} {
        append s [format ", %d detached and untracked" [dict get $n untracked]]
    }
    return $s
}

# --- window -------------------------------------------------------------------

set ::machteld::MT_SECTIONS {
    children  "Children -- launched and supervised"
    terminals "Terminals -- ConPTY sessions being steered"
    watches   "Watches -- directories under ReadDirectoryChangesW"
    untracked "Detached -- started by us, deliberately not supervised"
}

proc ::machteld::MtBuild {} {
    variable MT_SECTIONS
    toplevel .mt
    wm title .mt "mt -- what this machteld is doing"
    wm geometry .mt 900x520

    ttk::treeview .mt.tv -columns {pid status detail} -show {tree headings} \
        -selectmode browse -yscrollcommand {.mt.sb set}
    .mt.tv heading #0     -text "Handle"
    .mt.tv heading pid    -text "PID"
    .mt.tv heading status -text "Status"
    .mt.tv heading detail -text "Detail"
    .mt.tv column #0     -width 210 -stretch 0
    .mt.tv column pid    -width 70  -anchor e -stretch 0
    .mt.tv column status -width 90  -stretch 0
    .mt.tv column detail -width 500 -stretch 1
    ttk::scrollbar .mt.sb -orient vertical -command {.mt.tv yview}

    # Sections are created once and never destroyed, so they keep their
    # open/closed state across refreshes -- collapsing a section you do not care
    # about should survive the next tick.
    foreach {key title} $MT_SECTIONS {
        .mt.tv insert {} end -id sec:$key -text $title -open 1 -tags section
    }
    .mt.tv tag configure section   -font TkHeadingFont
    .mt.tv tag configure warn      -foreground "#b00"
    .mt.tv tag configure untracked -foreground gray45
    .mt.tv tag configure empty     -foreground gray55

    pack .mt.sb -side right -fill y
    pack .mt.tv -side left -fill both -expand 1

    ttk::label .mt.status -anchor w -padding {8 4} -textvariable ::machteld::MT_STATUS
    pack .mt.status -side bottom -fill x

    # The refresh must stop when the window goes, or the after chain outlives it
    # and every tick throws into the event loop forever.
    bind .mt <Destroy> {
        if {"%W" eq ".mt"} {
            catch {after cancel $::machteld::MT_AFTER}
            set ::machteld::MT_AFTER ""
        }
    }
    bind .mt <F5>     {::machteld::MtRefresh}
    bind .mt <Escape> {destroy .mt}
}

proc ::machteld::MtRender {} {
    variable MT_ROWS
    variable MT_SECTIONS
    if {![winfo exists .mt.tv]} { return }

    foreach {key title} $MT_SECTIONS {
        set parent sec:$key
        set want {}
        foreach r $MT_ROWS {
            if {[lindex $r 0] eq $key} { lappend want $r }
        }
        # Reconcile rather than rebuild, so a selection and the scroll position
        # survive a tick -- the same reason `tasks` does it.
        set have {}
        foreach id [.mt.tv children $parent] { dict set have $id 1 }
        set order {}
        set i 0
        foreach r $want {
            lassign $r _ handle pid status detail
            set id "$key:$handle:$pid"
            set tags {}
            if {$key eq "untracked"} { lappend tags untracked }
            if {$status in {STALLED exited} || [string match "*DROPPED*" $detail]} {
                lappend tags warn
            }
            if {[dict exists $have $id]} {
                .mt.tv item $id -text $handle -values [list $pid $status $detail] -tags $tags
                dict unset have $id
            } else {
                .mt.tv insert $parent end -id $id -text $handle \
                    -values [list $pid $status $detail] -tags $tags
            }
            lappend order $id
            incr i
        }
        if {[llength $want] == 0} {
            set id "$key:none"
            if {![dict exists $have $id]} {
                .mt.tv insert $parent end -id $id -text "" -values {"" "" "(none)"} -tags empty
            } else {
                dict unset have $id
            }
            lappend order $id
        }
        foreach dead [dict keys $have] { .mt.tv delete $dead }
        set i 0
        foreach id $order { .mt.tv move $id $parent $i ; incr i }
        .mt.tv item $parent -text "$title   ([llength $want])"
    }
    set ::machteld::MT_STATUS [MtSummary $MT_ROWS]
}

proc ::machteld::MtRefresh {} {
    variable MT_ROWS
    if {![catch {MtSnapshot} s]} {
        set MT_ROWS $s
        catch {MtRender}
    }
}

# As in `tasks`: the reschedule happens whatever the body did. A monitor that
# silently stops refreshing still looks live, which is the one failure mode a
# monitor must not have.
proc ::machteld::MtTick {} {
    variable MT_AFTER
    variable MT_INTERVAL
    MtRefresh
    if {[winfo exists .mt]} {
        set MT_AFTER [after $MT_INTERVAL ::machteld::MtTick]
    } else {
        set MT_AFTER ""
    }
}

proc ::machteld::mt {args} {
    variable MT_INTERVAL
    set i [lsearch -exact $args -interval]
    if {$i >= 0} {
        set v [lindex $args [expr {$i+1}]]
        if {![string is integer -strict $v] || $v < 100} {
            return -code error -errorcode {MACHTELD MT badvalue} \
                "mt -interval takes a whole number of milliseconds, at least 100"
        }
        set MT_INTERVAL $v
        set args [lreplace $args $i [expr {$i+1}]]
    }
    if {[llength $args]} {
        return -code error -errorcode {MACHTELD MT usage} \
            "usage: mt ?-interval ms?"
    }
    package require Tk
    if {[winfo exists .mt]} { raise .mt ; focus .mt ; return }
    MtBuild
    MtTick
    return
}
