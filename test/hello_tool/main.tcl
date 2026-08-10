# hello_tool/main.tcl -- a throwaway Tk tool, the first fixture for machteld's
# tool packaging. It proves three things when wrapped into an exe:
#   1. app-mode: main.tcl auto-runs (this file executing at all)
#   2. the machteld prelude loaded alongside it (::machteld::vtstrip present)
#   3. Tk is available and a window can be built
# It writes a marker next to the exe so 1-2 are verifiable HEADLESSLY; the actual
# window (3) is confirmed on a real desktop. Not a real tool -- a test target.

set marker [file join [file dirname [info nameofexecutable]] _hello_ran.txt]
set f [open $marker w]
puts $f "app-mode: main.tcl ran"
puts $f "exe: [info nameofexecutable]"
puts $f "prelude: [expr {[llength [info commands ::machteld::vtstrip]] ? {loaded} : {NOT loaded}}]"
puts $f "proc-in-basekit: [expr {[llength [info commands ::machteld::run]] ? {yes} : {no}}]"

set gui "gui: not attempted"
if {![catch {
    package require Tk
    wm title . "hello -- packaged by machteld"
    pack [label .l -text "packaged by machteld" -padx 40 -pady 40]
    update
} e]} {
    set gui "gui: window created OK"
} else {
    set gui "gui: failed ($e)"
}
puts $f $gui
close $f

# Then go, promptly. This used to linger 4000 ms so a human could see the window
# -- and nobody was watching: it was 4.4 of the suite's 22.7 seconds, the single
# most expensive check in it, spent asleep. The evidence this fixture exists to
# produce is already in the marker above, written before the pause ever started.
#
# The linger is still available for the one case it was written for, by asking:
#   MT_HELLO_LINGER=4000 hello.exe
if {[string match *OK* $gui]} {
    wm protocol . WM_DELETE_WINDOW {exit 0}
    set linger 150
    if {[info exists env(MT_HELLO_LINGER)]} { set linger $env(MT_HELLO_LINGER) }
    after $linger {exit 0}
    vwait forever
}
exit 0
