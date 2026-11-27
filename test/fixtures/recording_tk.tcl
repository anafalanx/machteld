# Isolated Tcl interpreter only. Register the recording implementation before
# any application code runs so a headless gate never loads a native Tk.
if {[package provide Tk] ne {}} {error "recording fixture needs an interpreter without Tk"}
package provide Tk 9.0
namespace eval ::recordTk {
    variable widgets {}
    variable bindings {}
    variable serial 0
    variable current {}
    variable waiting {}
    variable grid {}
}
namespace eval ::ttk {}
proc ::recordTk::create {kind path args} {
    variable widgets
    dict set widgets $path [dict create kind $kind tags [list $path] items {} options $args]
    interp alias {} ::$path {} ::recordTk::widget $path
    return $path
}
proc ::toplevel {path args} {::recordTk::create window $path {*}$args}
proc ::ttk::label {path args} {::recordTk::create label $path {*}$args}
proc ::ttk::button {path args} {::recordTk::create button $path {*}$args}
proc ::canvas {path args} {::recordTk::create canvas $path {*}$args}
proc ::wm {op path value} {dict set ::recordTk::widgets $path $op $value}
proc ::grid {path args} {dict set ::recordTk::grid $path $args}
proc ::font {op face flag} {return 2}
proc ::bindtags {path args} {
    if {[llength $args]} {dict set ::recordTk::widgets $path tags [lindex $args 0]}
    return [dict get $::recordTk::widgets $path tags]
}
proc ::bind {tag event script} {
    set key [list $tag $event]
    if {$script eq {}} {dict unset ::recordTk::bindings $key} else {dict set ::recordTk::bindings $key $script}
    return {}
}
proc ::winfo {op path} {
    switch $op {
        exists {return [dict exists $::recordTk::widgets $path]}
        toplevel {return .[lindex [split $path .] 1]}
        default {error "unsupported winfo $op"}
    }
}
proc ::destroy {path} {
    if {![winfo exists $path]} {error "no such window $path"}
    foreach child [dict keys $::recordTk::widgets $path.*] {destroy $child}
    set tags [bindtags $path]
    dict unset ::recordTk::widgets $path
    rename ::$path {}
    foreach tag $tags {
        set script [dict getdef $::recordTk::bindings [list $tag <Destroy>] {}]
        if {$script ne {}} {uplevel #0 [string map [list %W $path] $script]}
    }
}
proc ::tkwait {what path} {
    if {$what ne "window"} {error "unexpected tkwait $what"}
    {*}$::recordTk::waiting $path
    if {[winfo exists $path]} {destroy $path}
}
proc ::recordTk::ids {path tag} {
    variable widgets
    variable current
    if {$tag eq "current"} {set tag $current}
    set result {}
    dict for {id item} [dict get $widgets $path items] {
        if {$tag eq "all" || $tag eq $id || $tag in [dict get $item tags]} {lappend result $id}
    }
    return $result
}
proc ::recordTk::widget {path op args} {
    variable widgets
    variable serial
    switch $op {
        configure {
            dict set widgets $path options [dict merge [dict get $widgets $path options] $args]
        }
        cget {return [dict get $widgets $path options [lindex $args 0]]}
        invoke {return [uplevel #0 [dict get $widgets $path options -command]]}
        create {
            set index [lsearch -exact $args -tags]
            set tags [lindex $args $index+1]
            set id [incr serial]
            dict set widgets $path items $id [dict create kind [lindex $args 0] tags $tags]
            return $id
        }
        delete {foreach id [ids $path [lindex $args 0]] {dict unset widgets $path items $id}}
        find {return [ids $path [lindex $args 1]]}
        gettags {
            set id [lindex [ids $path [lindex $args 0]] 0]
            return [dict getdef $widgets $path items $id tags {}]
        }
        type {return [dict getdef $widgets $path items [lindex $args 0] kind {}]}
        bbox {if {[llength [ids $path [lindex $args 0]]]} {return {0 0 50 40}}}
        addtag {
            lassign $args tag withtag id
            set tags [dict get $widgets $path items $id tags]
            if {$tag ni $tags} {dict set widgets $path items $id tags [linsert $tags end $tag]}
        }
        dtag {
            lassign $args id tag
            dict set widgets $path items $id tags [lsearch -all -inline -not -exact [dict get $widgets $path items $id tags] $tag]
        }
        default {error "unsupported recorded widget command $op"}
    }
    return {}
}
proc ::recordTk::click {path item x y} {
    variable bindings
    variable current $item
    foreach tag [bindtags $path] {
        set script [dict getdef $bindings [list $tag <Button-1>] {}]
        if {$script ne {}} {uplevel #0 [string map [list %x $x %y $y] $script]}
    }
}
