# changes -- watch a directory tree and show what is changing, live.
#
# The first real machteld tool: a pure Tcl/Tk program that `wrap` stamps into
# its own exe. It uses `watch` for events, `run` for nothing at all, and Tk for
# the window -- so it is also the proof that a wrapped tool carries the palette.
#
#   changes ?dir? ?--all?
#
# The model is deliberately separate from the UI. Everything that decides WHAT
# is shown lives in ::cv and touches no widget, so `changes --selftest` can
# exercise it with no window at all -- which matters more than usual here,
# because an unmapped Tk widget silently drops events and a GUI test that
# hides its window is testing something other than the program.

package require Tk

namespace eval ::cv {
    # The prelude puts the palette on the GLOBAL namespace path, and Tcl does
    # not consult the global path for a lookup that starts inside another
    # namespace -- so a tool with its own namespace asks for the palette once,
    # here, and then writes `watch` and `run` bare like any script would.
    namespace path ::machteld

    variable dir      ""
    variable watch    ""
    variable rows     {}      ;# newest first: {time action path}
    variable seen     0
    variable paused   0
    variable showall  0
    variable maxrows  500
    variable previewcap [expr {256 * 1024}]
}

# Noise a codebase watcher must not drown in: the VCS's own churn, build
# output, and editor scratch files. `--all` turns the filter off, because a
# filter you cannot see past is its own kind of lie.
proc ::cv::ignored {path} {
    variable showall
    if {$showall} { return 0 }
    # By COMPONENT, not by prefix: creating .git emits an event for the
    # directory itself as well as for everything inside it, and a `.git/*`
    # pattern silently lets the first one through.
    foreach part [file split $path] {
        if {$part in {.git .hg .svn __pycache__ node_modules build .DS_Store}} { return 1 }
    }
    foreach pat {*.tmp *~ *.swp *.pyc *.o *.obj} {
        if {[string match $pat [file tail $path]]} { return 1 }
    }
    return 0
}

proc ::cv::add {action path {from ""}} {
    variable rows
    variable maxrows
    variable seen
    if {$action ne "overflow" && [ignored $path]} { return 0 }
    incr seen
    set label $path
    if {$from ne ""} { set label "$path  <- $from" }
    set rows [linsert $rows 0 [list [clock format [clock seconds] -format %H:%M:%S] $action $label $path]]
    if {[llength $rows] > $maxrows} { set rows [lrange $rows 0 [expr {$maxrows - 1}]] }
    return 1
}

# Drain whatever the watch has. Non-blocking: a blocking `watch read` would sit
# in C and never return to Tk's event loop, freezing the window -- so the UI
# polls on a short timer instead. (`child wait` has the same property.)
proc ::cv::drain {} {
    variable watch
    variable paused
    if {$watch eq "" || $paused} { return 0 }
    set n 0
    foreach ev [watch read $watch] {
        set action [dict get $ev action]
        set path   [dict get $ev path]
        set from   [expr {[dict exists $ev from] ? [dict get $ev from] : ""}]
        if {$action eq "overflow"} {
            incr n [add overflow "([dict get $ev count] events lost -- rescan)"]
        } else {
            incr n [add $action $path $from]
        }
    }
    return $n
}

# What to show for a path: its current text, or an honest reason there is none.
proc ::cv::preview {rel} {
    variable dir
    variable previewcap
    set full [file join $dir $rel]
    if {![file exists $full]} { return "(gone)" }
    if {[file isdirectory $full]} { return "(directory)" }
    set size [file size $full]
    if {$size == 0} { return "(empty)" }
    if {[catch {open $full rb} f]} { return "(cannot read: $f)" }
    set data [read $f $previewcap]
    close $f
    if {[string first \x00 $data] >= 0} {
        return "(binary, [format %.1f [expr {$size / 1024.0}]] KiB)"
    }
    set text [encoding convertfrom utf-8 $data]
    if {$size > $previewcap} {
        append text "\n\n--- truncated at [expr {$previewcap / 1024}] KiB of [format %.1f [expr {$size / 1024.0}]] KiB ---"
    }
    return $text
}

# ---- UI ---------------------------------------------------------------------

proc ::cv::build_ui {} {
    variable dir
    wm title . "changes -- $dir"
    wm geometry . 1000x620

    ttk::frame .top -padding 6
    ttk::label .top.dir -text $dir
    ttk::button .top.pause -text "Pause" -width 8 -command ::cv::toggle_pause
    ttk::button .top.clear -text "Clear" -width 8 -command ::cv::clear
    pack .top.dir -side left
    pack .top.clear .top.pause -side right -padx 2
    pack .top -fill x

    ttk::panedwindow .pw -orient horizontal
    ttk::frame .pw.l
    set t [ttk::treeview .pw.l.t -columns {time action path} -show headings -selectmode browse]
    $t heading time   -text "time"
    $t heading action -text "action"
    $t heading path   -text "path"
    $t column time   -width 80  -stretch 0
    $t column action -width 90  -stretch 0
    $t column path   -width 320 -stretch 1
    ttk::scrollbar .pw.l.s -orient vertical -command [list $t yview]
    $t configure -yscrollcommand [list .pw.l.s set]
    grid $t .pw.l.s -sticky nsew
    grid rowconfigure .pw.l 0 -weight 1
    grid columnconfigure .pw.l 0 -weight 1
    bind $t <<TreeviewSelect>> ::cv::on_select

    ttk::frame .pw.r
    text .pw.r.x -wrap none -undo 0 -font TkFixedFont -state disabled
    ttk::scrollbar .pw.r.sy -orient vertical   -command [list .pw.r.x yview]
    ttk::scrollbar .pw.r.sx -orient horizontal -command [list .pw.r.x xview]
    .pw.r.x configure -yscrollcommand [list .pw.r.sy set] -xscrollcommand [list .pw.r.sx set]
    grid .pw.r.x .pw.r.sy -sticky nsew
    grid .pw.r.sx -sticky ew
    grid rowconfigure .pw.r 0 -weight 1
    grid columnconfigure .pw.r 0 -weight 1

    .pw add .pw.l -weight 1
    .pw add .pw.r -weight 2
    pack .pw -fill both -expand 1

    ttk::label .status -anchor w -padding 4
    pack .status -fill x
    bind . <Escape> {destroy .}
    bind . <Control-q> {destroy .}
}

proc ::cv::render {} {
    variable rows
    set t .pw.l.t
    set keep [$t selection]
    $t delete [$t children {}]
    set i 0
    foreach r $rows {
        lassign $r time action label path
        $t insert {} end -id row$i -values [list $time $action $label] -tags $action
        incr i
    }
    $t tag configure added    -foreground #1a7f37
    $t tag configure removed  -foreground #b3261e
    $t tag configure renamed  -foreground #8250df
    $t tag configure overflow -foreground #9a6700
    status
}

proc ::cv::status {} {
    variable rows ; variable seen ; variable paused ; variable showall
    .status configure -text [format "%d shown / %d seen%s%s" \
        [llength $rows] $seen [expr {$paused ? "  --  PAUSED" : ""}] \
        [expr {$showall ? "  --  showing all (no filter)" : ""}]]
}

proc ::cv::on_select {} {
    variable rows
    set sel [.pw.l.t selection]
    if {$sel eq ""} return
    set idx [string range [lindex $sel 0] 3 end]
    if {![string is integer -strict $idx] || $idx >= [llength $rows]} return
    set path [lindex [lindex $rows $idx] 3]
    .pw.r.x configure -state normal
    .pw.r.x delete 1.0 end
    .pw.r.x insert end [preview $path]
    .pw.r.x configure -state disabled
}

proc ::cv::toggle_pause {} {
    variable paused
    set paused [expr {!$paused}]
    .top.pause configure -text [expr {$paused ? "Resume" : "Pause"}]
    status
}

proc ::cv::clear {} {
    variable rows
    set rows {}
    render
}

proc ::cv::tick {} {
    if {[catch {drain} n]} { set n 0 }
    if {$n > 0} { render }
    after 250 ::cv::tick
}

# ---- start ------------------------------------------------------------------

proc ::cv::selftest {} {
    variable dir
    variable watch
    set dir [file join $::env(TEMP) cv_selftest]
    file delete -force $dir
    file mkdir $dir
    set watch [watch start $dir -recursive]
    set ::cv::fails 0
    proc ck {name ok} {
        if {$ok} { puts "ok   $name" } else { puts "FAIL $name" ; incr ::cv::fails }
    }

    set f [open [file join $dir hello.txt] w] ; puts $f "hello world" ; close $f
    after 400
    ck "an added file reaches the model" [expr {[drain] == 1}]
    ck "the row says added"  [expr {[lindex [lindex $::cv::rows 0] 1] eq "added"}]
    ck "preview reads it back" [string match "*hello world*" [preview hello.txt]]

    file mkdir [file join $dir .git]
    set f [open [file join $dir .git config] w] ; puts $f x ; close $f
    after 400
    ck "VCS churn is filtered out" [expr {[drain] == 0}]

    set f [open [file join $dir bin.dat] wb] ; puts -nonewline $f "a\x00b" ; close $f
    after 400
    drain
    ck "binary files are described, not dumped" [string match "(binary,*" [preview bin.dat]]
    ck "a missing file previews honestly" [expr {[preview nope.txt] eq "(gone)"}]

    watch close $watch
    file delete -force $dir
    puts "\n[expr {$::cv::fails == 0 ? {ALL PASS} : {FAILURES}}]: $::cv::fails failure(s)"
    exit $::cv::fails
}

set args $argv
set ::cv::showall [expr {[lsearch -exact $args --all] >= 0}]
set selftest      [expr {[lsearch -exact $args --selftest] >= 0}]
set args [lsearch -all -inline -not -exact $args --all]
set args [lsearch -all -inline -not -exact $args --selftest]

if {$selftest} { ::cv::selftest }

set ::cv::dir [file normalize [expr {[llength $args] ? [lindex $args 0] : [pwd]}]]
if {![file isdirectory $::cv::dir]} {
    tk_messageBox -icon error -title changes -message "Not a directory:\n$::cv::dir"
    exit 1
}
if {[catch {watch start $::cv::dir -recursive} w]} {
    tk_messageBox -icon error -title changes -message "Cannot watch:\n$w"
    exit 1
}
set ::cv::watch $w
::cv::build_ui
::cv::render
::cv::tick
