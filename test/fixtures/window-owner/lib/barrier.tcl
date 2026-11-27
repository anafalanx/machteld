namespace eval ::windowFixture {}
proc ::windowFixture::hold {name} {
    if {$name ni {local app}} {error "unknown test barrier"}
    close [open [file join [pwd] $name.started] {WRONLY CREAT EXCL}]
    set deadline [expr {[clock seconds] + 15}]
    while {![file exists [file join [pwd] $name.release]]} {
        if {[clock seconds] >= $deadline} {error "worker test barrier timed out"}
        after 10
    }
    return $name
}
package provide window-fixture 1.0
