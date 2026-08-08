# tasks_ui.tcl -- drive the REAL tasks window, not just its model.
#
# `tasks --selftest` covers everything that decides what is shown; this covers
# the half that selftest deliberately cannot reach: that build_ui constructs, that
# render fills the treeview, that reconciliation preserves a selection across a
# refresh, and that End Task actually ends a task through the button's own code
# path. A mapped window is used on purpose -- an unmapped or withdrawn Tk widget
# takes different paths through the geometry manager, so testing a hidden window
# proves something about a program nobody runs.
#
#   machteld.exe test/tasks_ui.tcl

set HERE [file dirname [file normalize [info script]]]
set MAIN [file join $HERE .. tool tasks main.tcl]

set fails 0
proc check {name ok} {
    if {$ok} { puts "ok   $name" } else { incr ::fails ; puts "FAIL $name" }
}

set argv {}
set argc 0
source $MAIN

# One real tick has run from main.tcl's own entry code. Give it a second so a
# second sample exists and CPU percentages are populated.
update
after 1200 {set ::go 1} ; vwait ::go
::tm::tick
update

check "window is real and mapped"   [expr {[winfo exists .m.tv] && [winfo ismapped .m.tv]}]
set ids [.m.tv children {}]
check "treeview is populated"       [expr {[llength $ids] > 20}]
check "a row exists for every model row" [expr {[llength $ids] == [llength $::tm::rows]}]
check "item ids are pids"           [expr {[lsearch -exact $ids [pid]] >= 0}]
check "our own row is tagged self"  [expr {"self" in [.m.tv item [pid] -tags]}]
check "status line reports a count" [string match "*processes*" $::tm::statustext]

# The status line must own up to what it cannot see. On a non-elevated token
# there are always unreadable processes; if there are none we are elevated and
# the clause is correctly absent.
set nden 0
foreach r $::tm::rows { if {[dict get $r access] == 0} { incr nden } }
check "status admits unreadable rows when there are any" [expr {
    ($nden > 0) == [string match "*not readable*" $::tm::statustext]}]

# Sorting must reorder the WIDGET, not just the model -- render moves existing
# items rather than rebuilding, so the two can drift apart. Order is asserted
# against the model's own numbers rather than against formatted text, and from a
# known starting column, since sort_by toggles when you click the current one.
proc widget_col {id} {
    set i [lsearch -exact [lmap c $::tm::COLS {lindex $c 0}] $id]
    return [lmap item [.m.tv children {}] {lindex [.m.tv item $item -values] $i}]
}
::tm::sort_by name           ;# leave mem, so the next click is a fresh column
::tm::sort_by mem
update
check "a fresh numeric column sorts descending" [expr {$::tm::sortdir eq "-decreasing"}]
set pids [.m.tv children {}]
set mems [lmap p $pids {
    set v ""
    foreach r $::tm::rows { if {[dict get $r pid] == $p} { set v [dict get $r mem] } }
    expr {$v eq "" ? -1 : $v}
}]
set ordered 1
for {set i 1} {$i < [llength $mems]} {incr i} {
    if {[lindex $mems $i] > [lindex $mems [expr {$i-1}]]} { set ordered 0 ; break }
}
check "widget rows are in descending memory order" $ordered
check "unreadable rows sink to the bottom" [expr {[lindex $mems end] == -1 || [lindex $mems 0] > 0}]
::tm::sort_by mem            ;# same column again: reverse
update
check "clicking the same heading reverses" [expr {$::tm::sortdir eq "-increasing"}]
::tm::sort_by name
update
check "switching to a text column sorts ascending" [expr {$::tm::sortdir eq "-increasing"}]
check "names come out in order" [expr {
    [widget_col name] eq [lsort -dictionary [widget_col name]]}]

# Filtering drives the widget.
set all [llength [.m.tv children {}]]
set ::tm::filter "machteld"
::tm::render
update
set some [llength [.m.tv children {}]]
check "filter narrows the widget"  [expr {$some > 0 && $some < $all}]
set ::tm::filter ""
::tm::render
update
check "clearing the filter restores" [expr {[llength [.m.tv children {}]] >= $some}]

# RECONCILIATION IS THE POINT OF render'S COMPLEXITY. A rebuild-every-tick list
# drops the selection two seconds after you make it, and the next button is
# "End task" -- so this is a correctness test, not a polish test.
.m.tv selection set [pid]
::tm::on_select
update
check "selecting shows the exe path" [string match "*machteld*" $::tm::detailtext]
::tm::tick
update
check "selection survives a refresh"  [expr {[.m.tv selection] eq [pid]}]
check "detail survives a refresh"     [string match "*machteld*" $::tm::detailtext]

# A victim that actually stays alive. `machteld.exe -` reads EOF immediately and
# exits, which is how the corpse case below was found -- but a test of "does the
# row disappear" needs a process that is there when we look.
set SLEEPER [file join $::env(TEMP) tm_sleeper.tcl]
set fh [open $SLEEPER w] ; puts $fh {after 30000} ; close $fh

# A departed process must leave the widget. Start one, see it, kill it, tick.
set victim [child start -- [info nameofexecutable] $SLEEPER]
set vpid   [dict get [child info $victim] pid]
::tm::tick ; update
check "a newly started process appears" [expr {[lsearch -exact [.m.tv children {}] $vpid] >= 0}]
catch {child kill $victim} ; catch {child wait $victim} ; child close $victim
after 400 {set ::go 1} ; vwait ::go
::tm::tick ; update
check "a departed process disappears"   [expr {[lsearch -exact [.m.tv children {}] $vpid] < 0}]

# End Task through the button's own code path, with the confirm dialog stubbed --
# the dialog is Tk's, not ours, and blocking a test on a modal is not a test.
set victim2 [child start -- [info nameofexecutable] $SLEEPER]
set vpid2   [dict get [child info $victim2] pid]
::tm::tick ; update
.m.tv selection set $vpid2
proc ::tk_messageBox {args} { return yes }
::tm::kill_selected 0
update
check "End task ended the selected process" [expr {
    [dict get [child wait $victim2] status] in {killed error}}]
child close $victim2

# And the error path: ending something we may not touch reports, rather than
# throwing out of the button callback and leaving the window wedged.
set ::msg ""
proc ::tk_messageBox {args} {
    if {[dict exists $args -message]} { set ::msg [dict get $args -message] }
    return yes
}
# pid 4 (System) is already in the list -- it is the canonical unkillable row.
check "the System process is listed" [expr {[lsearch -exact [.m.tv children {}] 4] >= 0}]
.m.tv selection set 4
check "ending a protected process does not throw" [expr {
    [catch {::tm::kill_selected 0}] == 0}]
check "ending a protected process explains why"   [string match "*administrator*" $::msg]

file delete -force $SLEEPER

destroy .
puts ""
if {$fails == 0} { puts "ALL PASS" ; exit 0 }
puts "FAILURES: $fails" ; exit 1
