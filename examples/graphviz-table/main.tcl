package require machteld 30-
package require Tk
source -encoding utf-8 [file join [file dirname [info script]] view.tcl]
wm title . "Order relationships"
pack [canvas .diagram -background white -highlightthickness 0] -padx 16 -pady 16
::diagram::show .diagram
tkwait window .
