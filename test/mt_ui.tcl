# mt_ui.tcl -- drive the REAL cockpit window.
#
# The model is covered in run_test.tcl. This covers what a headless test cannot:
# that the window builds, that sections populate and reconcile, that a handle
# appearing and disappearing is reflected, and -- the one that matters most -- that
# the refresh timer stops when the window closes rather than throwing into the
# event loop forever.
#
#   machteld.exe test/mt_ui.tcl

set fails 0
proc check {name ok} {
    if {$ok} { puts "ok   $name" } else { incr ::fails ; puts "FAIL $name" }
}
proc rows_in {section} {
    set out {}
    foreach id [.mt.tv children sec:$section] {
        if {$id ne "$section:none"} { lappend out $id }
    }
    return $out
}

package require Tk

# Something to look at before the window opens, so the first render is not empty.
set WD [file join $env(TEMP) mt_ui_suite]
file delete -force $WD ; file mkdir $WD
set c1 [child start -- [info nameofexecutable] -]
set w1 [watch start $WD -recursive]
set p1 [pty spawn -- cmd]
after 400

mt -interval 200
update
after 400 {set ::go 1} ; vwait ::go
update

check "the cockpit window exists"   [winfo exists .mt]
check "the treeview is mapped"      [winfo ismapped .mt.tv]
check "all four sections are there" [expr {[llength [.mt.tv children {}]] == 4}]
foreach s {children terminals watches untracked} {
    check "section $s exists" [.mt.tv exists sec:$s]
}
check "section headings carry a count" [string match "*(*)*" [.mt.tv item sec:children -text]]

check "the child is listed"  [expr {[llength [rows_in children]] >= 1}]
check "the watch is listed"  [expr {[llength [rows_in watches]] == 1}]
check "the pty is listed"    [expr {[llength [rows_in terminals]] == 1}]
check "the watch row names its directory" [string match "*mt_ui_suite*" \
    [lindex [.mt.tv item [lindex [rows_in watches] 0] -values] 2]]
check "the status line names this session" [string match "*session pid [pid]*" $::machteld::MT_STATUS]

# An empty section says "(none)" rather than vanishing -- a section that
# disappears when empty reads as "not supported" instead of "nothing right now".
watch close $w1
::machteld::MtRefresh ; update
check "an emptied section shows (none)" [expr {[.mt.tv exists watches:none]}]
check "the emptied section counts zero"  [string match "*(0)*" [.mt.tv item sec:watches -text]]

# A new handle appears without a rebuild, and the section it belongs to grows.
set w2 [watch start $WD]
::machteld::MtRefresh ; update
check "a new watch appears"          [expr {[llength [rows_in watches]] == 1}]
check "the (none) placeholder went"  [expr {![.mt.tv exists watches:none]}]

# Reconciliation: a selection must survive a refresh, as in `tasks`.
set row [lindex [rows_in watches] 0]
.mt.tv selection set $row
::machteld::MtRefresh ; update
check "a selection survives a refresh" [expr {[.mt.tv selection] eq $row}]

# Sections keep their open/closed state across a tick -- collapsing one you do
# not care about should not be undone a second later.
.mt.tv item sec:untracked -open 0
::machteld::MtRefresh ; update
check "a collapsed section stays collapsed" [expr {![.mt.tv item sec:untracked -open]}]

# OBSERVING MUST NOT CONSUME. The cockpit has now rendered many times; the
# events queued by the file below must all still be there for the program that
# owns the watch.
set fh [open [file join $WD probe.txt] w] ; puts $fh hello ; close $fh
after 400
set before [dict get [watch info $w2] pending]
foreach _ {1 2 3 4 5} { ::machteld::MtRefresh }
update
check "the cockpit queued events survive it" [expr {
    $before > 0 && [dict get [watch info $w2] pending] == $before}]
check "the owner can still read them"        [expr {[llength [watch read $w2]] >= 1}]

# THE TIMER MUST DIE WITH THE WINDOW. An after chain that outlives its widget
# throws on every tick, forever, into whatever session the user is still using.
check "the refresh timer is armed" [expr {$::machteld::MT_AFTER ne ""}]
destroy .mt
update
check "closing the window cancels the timer" [expr {$::machteld::MT_AFTER eq ""}]
after 500 {set ::go 1} ; vwait ::go
check "no window, no crash after the interval elapses" [expr {![winfo exists .mt]}]

# Reopening works, and does not duplicate.
mt
update
check "the cockpit reopens"     [winfo exists .mt]
check "reopening rebuilt the sections" [expr {[llength [.mt.tv children {}]] == 4}]
mt
update
check "calling mt twice raises rather than duplicates" [expr {[winfo exists .mt]}]
destroy .mt

catch {child kill $c1} ; catch {child wait $c1} ; catch {child close $c1}
catch {pty close $p1} ; catch {watch close $w2}
file delete -force $WD

puts ""
if {$fails == 0} { puts "ALL PASS" ; exit 0 }
puts "FAILURES: $fails" ; exit 1
