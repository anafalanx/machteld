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

# On a real desktop, keep the window up briefly so it's visible; headless (window
# creation failed) just falls through and exits.
if {[string match *OK* $gui]} {
    wm protocol . WM_DELETE_WINDOW {exit 0}
    after 4000 {exit 0}
    vwait forever
}
exit 0
