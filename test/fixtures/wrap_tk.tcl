package require machteld

lassign $argv mode fixture report replacementIcon control
set startedWithTk [expr {![catch {package present Tk}]}]
package require Tk
load $fixture Desktopcatalog
label .sample -text "Wrapped application"
pack .sample
toplevel .second
wm deiconify .
wm deiconify .second
proc readIcons {} {
    global startedWithTk report replacementIcon control
    try {
        if {![winfo ismapped .] || ![winfo ismapped .second]} {
            error "timed out waiting for both private-desktop toplevels to map"
        }
        update idletasks
        set result [dict create startedWithTk $startedWithTk manager [winfo manager .sample] \
            shell [::fixtureCatalog shellicon [info nameofexecutable]] control [::fixtureCatalog shellicon $control] \
            root [::fixtureCatalog windowicon [wm frame .]] inherited [::fixtureCatalog windowicon [wm frame .second]]]
        image create photo custom -height 24 -width 24
        custom put #00eb63 -to 0 0 24 24
        wm iconphoto .second custom
        update idletasks
        dict set result photo [::fixtureCatalog windowicon [wm frame .second]]
        wm iconbitmap .second $replacementIcon
        update idletasks
        dict set result bitmap [::fixtureCatalog windowicon [wm frame .second]]
        dict set result unchanged [::fixtureCatalog windowicon [wm frame .]]
    } on error {message options} {
        set result [dict create error [dict get $options -errorinfo]]
    } finally {
        publish bytes $report [encoding convertto utf-8 $result]
        destroy .
    }
}
set deadline [expr {[clock milliseconds] + 5000}]
proc waitForMapping {} {
    if {([winfo ismapped .] && [winfo ismapped .second]) || [clock milliseconds] >= $::deadline} {
        readIcons
    } else {after 20 waitForMapping}
}
after 0 waitForMapping
if {$mode eq "console"} {tkwait window .}
