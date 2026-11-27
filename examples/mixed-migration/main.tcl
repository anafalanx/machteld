package require machteld

set appDir [file dirname [file normalize [info script]]]
lappend auto_path [file join $appDir lib]
package require cards::captions 1.0

proc ::cards::refresh {field value} {
    set ::cards::captionText [::cards::caption $field $value]
}

proc ::cards::dispatch {callback} {
    set ::cards::status [catch {{*}$callback} ::cards::captionText ::cards::options]
}

set graphical [expr {[lindex $argv 0] eq "--gui"}]
set arguments $argv
if {$graphical} {set arguments [lrange $argv 1 end]}
if {[llength $arguments] != 2} {
    puts stderr "usage: ?--gui? FIELD VALUE"
    exit 2
}
lassign $arguments field value
set refresh [list ::cards::refresh $field $value]
if {$graphical} {
    package require Tk
    ttk::label .caption -textvariable ::cards::captionText
    ttk::button .refresh -text Refresh -command $refresh
    pack .caption .refresh -padx 12 -pady 6
    .refresh invoke
    tkwait window .
} else {
    # Exercise the same command prefix through the Tcl event loop.
    after 0 [list ::cards::dispatch $refresh]
    vwait ::cards::status
    chan configure stdout -encoding utf-8 -translation lf
    chan configure stderr -encoding utf-8 -translation lf
    if {$::cards::status} {
        puts stderr [list [dict get $::cards::options -errorcode] $::cards::captionText]
        exit 1
    }
    puts $::cards::captionText
}
