package require machteld 30-
set here [file dirname [info script]]
source -encoding utf-8 [file join $here view.tcl]
source -encoding utf-8 [file join $here research.tcl]

if {[llength $argv] == 2 && [lindex $argv 0] eq "--create-sample"} {
    ::research::createSample [lindex $argv 1]
    return
}
if {[llength $argv] in {3 4} && [lindex $argv 0] eq "--headless"} {
    lassign $argv _ database instant key
    ::research::refresh $database $instant
    ::research::pick $key
    chan configure stdout -encoding utf-8 -translation lf
    puts [::research::report]
    return
}
if {[llength $argv] ni {1 2} || [string match --* [lindex $argv 0]]} {
    error {usage: research.machteld DATABASE ?INSTANT? | --create-sample NEW_DATABASE | --headless DATABASE INSTANT ?OCCURRENCE_ID?}
}
lassign $argv database instant
if {$instant ne {}} {set ::research::input $instant}
package require Tk
wm title . {Observations in time}
ttk::frame .body -padding 14
pack .body -fill both -expand 1
ttk::label .body.label -text {Research instant}
ttk::entry .body.time -textvariable ::research::input -width 36
set canvas .body.diagram
ttk::button .body.apply -text Apply -command [list ::research::apply $database $canvas]
ttk::label .body.status -textvariable ::research::status
canvas $canvas -background white -width 640 -height 300 -highlightthickness 0 \
    -xscrollcommand {.body.x set} -yscrollcommand {.body.y set}
ttk::scrollbar .body.x -orient horizontal -command [list $canvas xview]
ttk::scrollbar .body.y -orient vertical -command [list $canvas yview]
ttk::label .body.details -textvariable ::research::details -justify left
grid .body.label .body.time .body.apply -sticky w -padx 3
grid .body.status -row 1 -columnspan 3 -sticky w -pady 5
grid $canvas -row 2 -column 0 -columnspan 3 -sticky nsew
grid .body.y -row 2 -column 3 -sticky ns
grid .body.x -row 3 -column 0 -columnspan 3 -sticky ew
grid .body.details -row 4 -columnspan 3 -sticky w -pady 6
grid columnconfigure .body 1 -weight 1
grid rowconfigure .body 2 -weight 1
bind .body.time <Return> [list ::research::apply $database $canvas]
bind $canvas <Button-1> [list ::research::click $canvas]
::research::apply $database $canvas
focus .body.time
tkwait window .
