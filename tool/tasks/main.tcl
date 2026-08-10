# tasks -- what this machine is running, and how to stop it.
#
# A task manager: the process list, live, sortable, filterable, with End Task.
# Deliberately smaller than Windows' own -- no per-app grouping, no history
# graphs, no services tab. One flat table of processes and the two questions you
# actually open a task manager to answer: what is eating the machine, and how do
# I kill it.
#
#   tasks ?--interval ms? ?--selftest?
#
# WHY THIS TOOL EXISTS AT ALL. machteld could already supervise processes it
# started -- born-in-job, tree-kill, caps. It could not see a process it did not
# start. Writing this is what made that gap concrete, and `ps` is what closed
# it. The rule at the time was that a capability lands only when a tool reaches
# for it; that has since been relaxed, but this is still how `ps` got its shape --
# a dict designed against a real caller rather than guessed at.
#
# As with `changes`, everything that decides WHAT is shown lives in ::tm and
# touches no widget, so --selftest exercises the model with no window.

package require Tk

namespace eval ::tm {
    # The prelude puts the palette on the GLOBAL namespace path, and Tcl does not
    # consult the global path for a lookup starting inside another namespace --
    # so the tool asks for it once, here, and then writes `ps` bare.
    namespace path ::machteld

    variable prev     {}      ;# pid -> cpu ms, from the previous sample
    variable prevms   0       ;# wall clock of that sample
    variable rows     {}      ;# the current model: list of row dicts
    variable filter   ""
    variable sortcol  mem
    variable sortdir  -decreasing
    variable interval 2000
    variable paused   0
    variable ncpu     [expr {[info exists ::env(NUMBER_OF_PROCESSORS)]
                             ? $::env(NUMBER_OF_PROCESSORS) : 1}]
}

# --- model ------------------------------------------------------------------

# CPU PERCENT IS COMPUTED HERE, NOT IN C. `ps` reports cumulative CPU because a
# percentage is a rate, and a rate needs two samples and a clock -- putting it in
# the verb would mean hidden state and an answer that depends on when you last
# asked. So the tool keeps the previous sample and divides. Dividing by the core
# count is what makes 100% mean "the whole machine" rather than "one core", which
# is what Windows' own Task Manager shows and therefore what a reader expects.
proc ::tm::sample {} {
    variable prev
    variable prevms
    variable ncpu

    set now  [mtps list]
    set nowms [clock milliseconds]
    set dt   [expr {$nowms - $prevms}]
    set cur  {}
    set out  {}

    foreach p $now {
        set pid [dict get $p pid]
        set cpu [dict get $p cpu]
        # An unreadable process has no cpu figure at all. It stays in the list --
        # the rows you cannot open are often the interesting ones -- but with an
        # empty percentage rather than 0.0, because "denied" and "idle" are not
        # the same claim.
        if {$cpu eq ""} {
            dict set p pct ""
        } else {
            dict set cur $pid $cpu
            if {$prevms > 0 && $dt > 0 && [dict exists $prev $pid]} {
                set d [expr {$cpu - [dict get $prev $pid]}]
                # A process that exited and had its pid reused reads as a huge
                # negative delta; clamp rather than print nonsense.
                if {$d < 0} { set d 0 }
                dict set p pct [expr {double($d) * 100.0 / (double($dt) * $ncpu)}]
            } else {
                dict set p pct ""   ;# first sample: nothing to subtract from yet
            }
        }
        lappend out $p
    }
    set prev   $cur
    set prevms $nowms
    return $out
}

proc ::tm::matches {row pat} {
    if {$pat eq ""} { return 1 }
    set pat *[string tolower $pat]*
    foreach k {name exe pid} {
        if {[string match $pat [string tolower [dict get $row $k]]]} { return 1 }
    }
    return 0
}

proc ::tm::filtered {rows pat} {
    set out {}
    foreach r $rows { if {[matches $r $pat]} { lappend out $r } }
    return $out
}

# Sorting has to cope with the empty cells that `access 0` leaves behind. An
# empty numeric field sorts as -1 so unreadable rows sink to the bottom of a
# descending sort instead of floating to the top as if they were the biggest.
#
# Both branches decorate-sort-undecorate rather than using `lsort -index $col`:
# -index addresses a LIST POSITION, and a row is a dict. It happens to also be a
# well-formed list, so `-index 3` would "work" for as long as nobody reorders the
# keys the C emits -- which is precisely the kind of accidental coupling that
# breaks silently and sorts by the wrong column.
proc ::tm::sorted {rows col dir} {
    set text [expr {$col in {name exe}}]
    set keyed [lmap r $rows {
        set v [dict get $r $col]
        list [expr {$text ? $v : ($v eq "" ? -1 : $v)}] $r
    }]
    set opt [expr {$text ? "-dictionary" : "-real"}]
    return [lmap p [lsort $opt $dir -index 0 $keyed] {lindex $p 1}]
}

proc ::tm::fmtbytes {n} {
    if {$n eq ""} { return "" }
    if {$n < 1024} { return "$n B" }
    foreach {lim unit} {1048576 KB 1073741824 MB 1099511627776 GB} {
        if {$n < $lim} { return [format "%.1f %s" [expr {$n * 1024.0 / $lim}] $unit] }
    }
    return [format "%.1f TB" [expr {$n / 1099511627776.0}]]
}

proc ::tm::fmtpct {p} {
    if {$p eq ""} { return "" }
    if {$p < 0.05} { return "0" }
    return [format "%.1f" $p]
}

proc ::tm::fmtcpu {ms} {
    if {$ms eq ""} { return "" }
    set s [expr {$ms / 1000}]
    return [format "%d:%02d:%02d" [expr {$s/3600}] [expr {($s/60)%60}] [expr {$s%60}]]
}

proc ::tm::totals {rows} {
    set mem 0 ; set thr 0 ; set denied 0
    foreach r $rows {
        if {[dict get $r mem] ne ""} { incr mem [dict get $r mem] }
        incr thr [dict get $r threads]
        if {[dict get $r access] == 0} { incr denied }
    }
    return [dict create n [llength $rows] mem $mem threads $thr denied $denied]
}

# --- ui ---------------------------------------------------------------------

set ::tm::COLS {
    {pid     PID       70  e}
    {name    Name      190 w}
    {pct     {CPU %}   70  e}
    {mem     Memory    90  e}
    {private Private   90  e}
    {threads Threads   70  e}
    {cpu     {CPU time} 90 e}
    {ppid    Parent    70  e}
}

proc ::tm::build_ui {} {
    variable COLS
    wm title . "machteld tasks"
    wm geometry . 940x600

    ttk::frame .top -padding {8 6 8 4}
    ttk::label .top.l -text "Filter:"
    ttk::entry .top.e -textvariable ::tm::filter -width 24
    ttk::button .top.end  -text "End task"   -command {::tm::kill_selected 0}
    ttk::button .top.tree -text "End tree"   -command {::tm::kill_selected 1}
    ttk::checkbutton .top.pause -text "Pause" -variable ::tm::paused
    pack .top.l -side left
    pack .top.e -side left -padx {4 12}
    pack .top.end .top.tree -side left -padx 2
    pack .top.pause -side left -padx 12
    pack .top -side top -fill x

    ttk::frame .m
    set cols [lmap c $COLS {lindex $c 0}]
    ttk::treeview .m.tv -columns $cols -show headings -selectmode browse \
        -yscrollcommand {.m.sb set}
    foreach c $COLS {
        lassign $c id title width anchor
        .m.tv heading $id -text $title -command [list ::tm::sort_by $id]
        .m.tv column  $id -width $width -anchor $anchor -stretch [expr {$id eq "name"}]
    }
    ttk::scrollbar .m.sb -orient vertical -command {.m.tv yview}
    pack .m.sb -side right -fill y
    pack .m.tv -side left -fill both -expand 1
    pack .m -side top -fill both -expand 1

    # A row we cannot open is dimmed rather than hidden: you should be able to
    # see that a process exists and that you are not allowed to look at it.
    .m.tv tag configure denied -foreground gray55
    .m.tv tag configure self   -foreground "#0a6"

    ttk::label .status -anchor w -padding {8 4} -textvariable ::tm::statustext
    pack .status -side bottom -fill x
    ttk::label .detail -anchor w -padding {8 0} -textvariable ::tm::detailtext
    pack .detail -side bottom -fill x

    bind .m.tv <<TreeviewSelect>> {::tm::on_select}
    bind .m.tv <Delete>           {::tm::kill_selected 0}
    bind .top.e <KeyRelease>      {::tm::render}
    bind . <F5>                   {::tm::tick}
    bind . <Escape>               {destroy .}
}

proc ::tm::sort_by {col} {
    variable sortcol
    variable sortdir
    if {$col eq $sortcol} {
        set sortdir [expr {$sortdir eq "-decreasing" ? "-increasing" : "-decreasing"}]
    } else {
        set sortcol $col
        # Text reads best ascending, quantities descending -- the first click on
        # "Memory" should show you the hog, not the smallest thing on the box.
        set sortdir [expr {$col in {name exe} ? "-increasing" : "-decreasing"}]
    }
    render
}

# Rows are reconciled rather than rebuilt: item ids ARE pids, so the selection
# and the scroll position survive a refresh. Deleting and re-inserting every two
# seconds would drop whichever row you were about to click, which in a program
# whose next button is "End task" is not a cosmetic problem.
proc ::tm::render {} {
    variable rows
    variable filter
    variable sortcol
    variable sortdir
    variable COLS
    if {![winfo exists .m.tv]} { return }

    set show [sorted [filtered $rows $filter] $sortcol $sortdir]
    set have {}
    foreach id [.m.tv children {}] { dict set have $id 1 }

    set order {}
    foreach r $show {
        set pid [dict get $r pid]
        set vals [lmap c $COLS {
            set id [lindex $c 0]
            switch -- $id {
                pct     { fmtpct [dict get $r pct] }
                mem     { fmtbytes [dict get $r mem] }
                private { fmtbytes [dict get $r private] }
                cpu     { fmtcpu [dict get $r cpu] }
                default { dict get $r $id }
            }
        }]
        set tags {}
        if {[dict get $r access] == 0} { lappend tags denied }
        if {$pid == [pid]}             { lappend tags self }
        if {[dict exists $have $pid]} {
            .m.tv item $pid -values $vals -tags $tags
            dict unset have $pid
        } else {
            .m.tv insert {} end -id $pid -values $vals -tags $tags
        }
        lappend order $pid
    }
    foreach dead [dict keys $have] { .m.tv delete $dead }
    set i 0
    foreach pid $order { .m.tv move $pid {} $i ; incr i }
    status
}

proc ::tm::status {} {
    variable rows
    variable filter
    set t [totals $rows]
    set s [format "%d processes   %s in working sets   %d threads" \
        [dict get $t n] [fmtbytes [dict get $t mem]] [dict get $t threads]]
    # Say plainly how much of the picture is missing. A task manager that shows
    # a total while silently omitting 150 processes it could not open is telling
    # you a number you would misread.
    if {[dict get $t denied] > 0} {
        append s [format "   (%d not readable without elevation)" [dict get $t denied]]
    }
    if {$filter ne ""} {
        append s [format "   -- showing %d" [llength [filtered $rows $filter]]]
    }
    set ::tm::statustext $s
}

proc ::tm::on_select {} {
    variable rows
    set sel [.m.tv selection]
    if {$sel eq ""} { set ::tm::detailtext "" ; return }
    foreach r $rows {
        if {[dict get $r pid] == $sel} {
            set exe [dict get $r exe]
            if {$exe eq ""} { set exe "(not readable)" }
            set ::tm::detailtext "$exe"
            return
        }
    }
}

proc ::tm::kill_selected {tree} {
    variable rows
    set sel [.m.tv selection]
    if {$sel eq ""} { return }
    set name $sel
    foreach r $rows { if {[dict get $r pid] == $sel} { set name "[dict get $r name] ($sel)" } }
    set what [expr {$tree ? "$name and everything it started" : $name}]
    if {[tk_messageBox -type yesno -icon warning -title "End task" \
            -message "End $what?\n\nUnsaved work in that process is lost."] ne "yes"} {
        return
    }
    if {[catch {expr {$tree ? [mtps kill $sel -tree] : [mtps kill $sel]}} m opts]} {
        # The error contract is the UI here: `denied` has a specific remedy and
        # `notfound` is not really a failure, so they get different words rather
        # than one generic "could not end task".
        switch -- [lindex [dict get $opts -errorcode] 2] {
            denied   { tk_messageBox -icon error -title "End task" -message \
                       "Windows refused: $name is protected or owned by another\
                        account.\n\nRun tasks as administrator to end it." }
            notfound { tk_messageBox -icon info -title "End task" -message \
                       "$name has already exited." }
            default  { tk_messageBox -icon error -title "End task" -message $m }
        }
    }
    tick
}

# The reschedule happens whatever the body did. A tick that throws takes the
# refresh loop with it and leaves a window showing a frozen list that still LOOKS
# live -- the worst failure this program has, because the next button is End Task
# and the pid under the cursor may by then belong to something else entirely. A
# transient failure must cost one sample, never the loop.
proc ::tm::tick {} {
    variable rows
    variable paused
    variable interval
    if {!$paused} {
        if {![catch {sample} s]} {
            set rows $s
            catch {render}
        }
    }
    after $interval ::tm::tick
}

# --- selftest ---------------------------------------------------------------
# The model, with no window. Everything here is a claim the GUI relies on and
# would otherwise only be checked by looking at it.
proc ::tm::selftest {} {
    variable prev ; variable prevms ; variable rows
    set fails 0
    proc ck {name ok} {
        if {$ok} { puts "ok   $name" } else { incr ::tm::fails_ ; puts "FAIL $name" }
    }
    set ::tm::fails_ 0

    set a [sample]
    ck "sample returns processes"        [expr {[llength $a] > 20}]
    ck "first sample has no percentages" [expr {[lsearch -exact [lmap r $a {dict get $r pct}] ""] >= 0}]
    set allempty 1
    foreach r $a { if {[dict get $r pct] ne ""} { set allempty 0 } }
    ck "first sample: every pct empty"   $allempty

    # Burn measurable CPU between samples, so the second one has something real
    # to report rather than a list of zeroes.
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 600} { set _ [expr {sqrt(2.0)}] }
    set b [sample]
    set mine ""
    foreach r $b { if {[dict get $r pid] == [pid]} { set mine $r } }
    ck "second sample has our row"       [expr {$mine ne ""}]
    ck "our own cpu% is now a number"    [string is double -strict [dict get $mine pct]]
    ck "our own cpu% is positive"        [expr {[dict get $mine pct] > 0}]
    ck "no percentage exceeds 100"       [expr {[tcl::mathfunc::max 0 {*}[lmap r $b {
        expr {[dict get $r pct] eq "" ? 0 : [dict get $r pct]}}]] <= 100.5}]

    # An unreadable row must survive filtering and sorting with empty cells --
    # this is where a naive numeric sort throws, or floats them to the top.
    set den ""
    foreach r $b { if {[dict get $r access] == 0} { set den $r ; break } }
    if {$den ne ""} {
        ck "denied rows carry an empty pct" [expr {[dict get $den pct] eq ""}]
    }
    set s [sorted $b mem -decreasing]
    ck "sort by mem descending"   [expr {[llength $s] == [llength $b]}]
    ck "unreadable rows sink"     [expr {[dict get [lindex $s 0] mem] ne ""}]
    ck "sort by name is stable in size" [expr {[llength [sorted $b name -increasing]] == [llength $b]}]
    ck "sort by an empty-heavy column"  [expr {[llength [sorted $b pct -decreasing]] == [llength $b]}]

    ck "filter finds ourselves"   [expr {[llength [filtered $b machteld]] >= 1}]
    ck "filter is case-blind"     [expr {[llength [filtered $b MACHTELD]] ==
                                         [llength [filtered $b machteld]]}]
    ck "filter matching nothing"  [expr {[llength [filtered $b zzz_no_such_zzz]] == 0}]
    ck "empty filter shows all"   [expr {[llength [filtered $b ""]] == [llength $b]}]

    ck "fmtbytes scales"          [expr {[fmtbytes 0] eq "0 B" && [fmtbytes 2048] eq "2.0 KB"
                                         && [fmtbytes 1572864] eq "1.5 MB"}]
    ck "fmtbytes passes empty"    [expr {[fmtbytes ""] eq ""}]
    ck "fmtcpu formats hh:mm:ss"  [expr {[fmtcpu 3661000] eq "1:01:01" && [fmtcpu ""] eq ""}]
    ck "fmtpct rounds"            [expr {[fmtpct 12.34] eq "12.3" && [fmtpct 0.001] eq "0"
                                         && [fmtpct ""] eq ""}]

    set t [totals $b]
    ck "totals count every row"   [expr {[dict get $t n] == [llength $b]}]
    ck "totals skip empty memory" [expr {[dict get $t mem] > 0}]

    puts ""
    if {$::tm::fails_ == 0} { puts "ALL PASS" ; exit 0 }
    puts "FAILURES: $::tm::fails_"
    exit 1
}

# --- entry ------------------------------------------------------------------

# STDERR FIRST, DIALOG ONLY IF THERE IS NO STDERR. A wrapped GUI exe is started
# with no standard channels at all, so `puts stderr` throws there and the dialog
# is the only way to be heard. Run from a console -- which is how the tool is
# tested and how it is launched during development -- stderr exists and a modal
# dialog is exactly wrong: it blocks a non-interactive caller until something
# times out and kills it. Trying the dialog first did that to the test suite.
proc ::tm::die {msg} {
    if {[catch {puts stderr "tasks: $msg"}]} {
        catch {tk_messageBox -icon error -title tasks -message $msg}
    }
    exit 2
}

# The whole of the argument handling, declared once. What this replaces is worth
# remembering: a hand-rolled `lsearch` that accepted `--interval` with nothing
# after it, set the interval to the empty string, and let `after ""` throw out of
# the refresh timer several frames later. `cli` refuses a missing value at the
# point it is missing, and the usage text below is generated from this same
# declaration rather than written separately and left to rot.
set SPEC {
    --interval {type int default 2000 min 100 max 3600000
                help "how often to refresh the list, in milliseconds"}
    --selftest {type flag help "run the model's own tests and exit"}
}
if {[catch {::machteld::cli parse $argv $SPEC} opt]} {
    ::tm::die "$opt

[::machteld::cli usage $SPEC tasks]"
}
if {[dict get $opt help]} {
    catch {puts [::machteld::cli usage $SPEC tasks]}
    exit 0
}
set ::tm::interval [dict get $opt interval]
set selftest [dict get $opt selftest]

if {$selftest} { ::tm::selftest }
::tm::build_ui
::tm::tick
