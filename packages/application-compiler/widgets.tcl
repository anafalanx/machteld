# Embedded only when typed Tk is used. Checking, packing and loading the
# generated procedures never requires Tk. Only tk_open starts the toolkit.
proc tkId {} {
    variable tkSerial
    return [incr tkSerial]_[binary encode hex [::machteld::hash random 16]]
}

proc tkGuard {kind ticket path} {
    variable tkState
    set size [expr {$kind eq "tk_item" ? 4 : 2}]
    if {[catch {llength $ticket} n] || $n != $size || [lindex $ticket 0] ne $kind} {
        reject $path "a live $kind from this application"
    }
    lassign $ticket tag id generation item
    set widgetKind [expr {$kind eq "tk_item" ? "tk_canvas" : $kind}]
    if {![info exists tkState($id)] || [dict get $tkState($id) kind] ne $widgetKind} {
        return -code error -errorcode {APPCOMPILER TK STALE} "expired or foreign $kind at $path"
    }
    set native [dict get $tkState($id) path]
    if {![::winfo exists $native]} {
        tkGone $id
        return -code error -errorcode {APPCOMPILER TK STALE} "destroyed $kind at $path"
    }
    if {$kind eq "tk_item" && ($generation ne [dict get $tkState($id) generation] ||
            ![regexp {\A[1-9][0-9]*\Z} $item] || "mt_owned_$id" ni [$native gettags $item])} {
        return -code error -errorcode {APPCOMPILER TK STALE} "expired or foreign canvas item at $path"
    }
    return $ticket
}

proc tkPath {kind ticket} {
    variable tkState
    lassign [tkGuard $kind $ticket $kind] tag id
    return [dict get $tkState($id) path]
}

# Two narrow entry points for a trusted Tcl renderer working alongside X.
proc tkCanvasPath {canvas} {return [tkPath tk_canvas $canvas]}
proc tkTag {canvasId key} {
    return mt_occ_${canvasId}_[binary encode hex [encoding convertto -profile strict utf-8 $key]]
}
proc tkTagItems {canvas key items} {
    set c [tkCanvasPath $canvas]
    set id [lindex $canvas 1]
    foreach item $items {
        if {![regexp {\A[1-9][0-9]*\Z} $item] || [$c type $item] eq ""} {
            reject {canvas item} {a live item number on this canvas}
        }
    }
    set group [tkTag $id $key]
    foreach item $items {
        foreach tag [$c gettags $item] {
            if {[string match mt_occ_${id}_* $tag]} {$c dtag $item $tag}
        }
        $c addtag $group withtag $item
        $c addtag mt_owned_$id withtag $item
    }
    return {}
}

proc tkRegister {kind id path window} {
    variable tkState
    if {![::winfo exists $path] || ($id ne $window && ![info exists tkState($window)])} {
        return -code error -errorcode {APPCOMPILER TK STALE} {widget was destroyed during creation}
    }
    set tag mt_binding_$id
    set tkState($id) [dict create kind $kind path $path window $window generation 1 children {} closeHooks {}]
    if {$id ne $window} {dict set tkState($window) children $id 1}
    ::bind $tag <Destroy> [list [namespace current]::tkGone $id]
    ::bindtags $path [linsert [::bindtags $path] 0 $tag]
    return [list $kind $id]
}

proc tkGone {id} {
    variable tkState
    if {![info exists tkState($id)]} {return}
    set record $tkState($id)
    unset tkState($id)
    set parent [dict get $record window]
    if {[info exists tkState($parent)]} {dict unset tkState($parent) children $id}
    set tag mt_binding_$id
    ::bind $tag <Destroy> {}
    ::bind $tag <Button-1> {}
    foreach child [dict keys [dict get $record children]] {tkGone $child}
    # Make the entire window stale before any close observer can reenter it.
    set failed 0
    dict for {token prefix} [dict get $record closeHooks] {
        if {[catch {{*}$prefix} message options] && !$failed} {
            set failed 1
            set firstMessage $message
            set firstOptions $options
        }
    }
    if {$failed} {return -options $firstOptions $firstMessage}
    return {}
}

proc tkOnClose {window prefix} {
    variable tkState
    set id [lindex [tkGuard tk_window $window window] 1]
    set token [tkId]
    dict set tkState($id) closeHooks $token $prefix
    return $token
}
proc tkForgetClose {window token} {
    variable tkState
    set id [lindex [tkGuard tk_window $window window] 1]
    dict unset tkState($id) closeHooks $token
    return {}
}

proc tk_open {title} {
    try {
        if {[package provide Tk] eq ""} {
            package require Tk
            ::wm withdraw .
        }
        set id [tkId]
        set path .mt_$id
        ::toplevel $path
        try {
            ::wm title $path $title
            set window [tkRegister tk_window $id $path $id]
        } on error {message options} {
            try {if {[::winfo exists $path]} {::destroy $path}} finally {tkGone $id}
            return -options $options $message
        }
        return [list ok $window]
    } on error {message options} {
        return [list err [dict create code TK_OPEN message $message]]
    }
}
proc tkEndWindow {window} {
    variable tkState
    set id [lindex $window 1]
    if {[info exists tkState($id)]} {
        set path [dict get $tkState($id) path]
        try {if {[::winfo exists $path]} {::destroy $path}} finally {tkGone $id}
    }
}
proc tk_close {window} {
    tkGuard tk_window $window window
    tkEndWindow $window
    return {}
}
proc tk_wait {window} {
    ::tkwait window [tkPath tk_window $window]
    return {}
}
proc tk_title {window title} {
    ::wm title [tkPath tk_window $window] $title
    return {}
}

proc tkChild {kind window command args} {
    set parent [tkPath tk_window $window]
    set id [tkId]
    set path $parent.w_$id
    $command $path {*}$args
    try {
        return [tkRegister $kind $id $path [lindex $window 1]]
    } on error {message options} {
        try {if {[::winfo exists $path]} {::destroy $path}} finally {tkGone $id}
        return -options $options $message
    }
}
proc tk_label {window text} {return [tkChild tk_label $window ::ttk::label -text $text]}
proc tk_button {window text} {return [tkChild tk_button $window ::ttk::button -text $text]}
proc tk_canvas {window width height} {
    return [tkChild tk_canvas $window ::canvas -width $width -height $height -background white -highlightthickness 0]
}
proc tk_grid {widget row column} {
    set kind [lindex $widget 0]
    if {$kind ni {tk_label tk_button tk_canvas}} {reject tk_grid {a label, button or canvas}}
    ::grid [tkPath $kind $widget] -row $row -column $column -sticky w -padx 4 -pady 3
    return {}
}
proc tk_label_text {widget text} {
    [tkPath tk_label $widget] configure -text $text
    return {}
}
proc tk_button_text {widget text} {
    [tkPath tk_button $widget] configure -text $text
    return {}
}

proc tkNewItem {canvas key kind args} {
    variable tkState
    set c [tkCanvasPath $canvas]
    set id [lindex $canvas 1]
    set item [$c create $kind {*}$args -tags [list mt_owned_$id [tkTag $id $key]]]
    return [list tk_item $id [dict get $tkState($id) generation] $item]
}
proc tk_rectangle {canvas key x1 y1 x2 y2} {
    return [tkNewItem $canvas $key rectangle $x1 $y1 $x2 $y2 -fill white -outline black]
}
proc tk_text {canvas key x y text} {
    return [tkNewItem $canvas $key text $x $y -text $text]
}
proc tk_remove {item} {
    variable tkState
    lassign [tkGuard tk_item $item item] kind id generation number
    [dict get $tkState($id) path] delete $number
    return {}
}
proc tk_clear {canvas} {
    variable tkState
    [tkCanvasPath $canvas] delete all
    dict incr tkState([lindex $canvas 1]) generation
    return {}
}
proc tk_highlight {canvas occurrence} {
    set c [tkCanvasPath $canvas]
    set id [lindex $canvas 1]
    $c delete mt_selection_$id
    if {[lindex $occurrence 0] eq "none"} {return 0}
    set box [$c bbox [tkTag $id [lindex $occurrence 1]]]
    if {![llength $box]} {return 0}
    $c create rectangle $box -outline #365e91 -width 2 -state disabled -tags mt_selection_$id
    return 1
}

# Only generated IDs and Tk's integer coordinates appear in binding scripts.
# Keep application text and callback captures out of percent substitution.
proc tkBind {kind widget event callback location} {
    variable tkState
    set path [tkPath $kind $widget]
    set id [lindex $widget 1]
    set version [tkId]
    set script [list [namespace current]::tkDispatch $id $version]
    if {$event eq "click"} {
        ::bind mt_binding_$id <Button-1> [list {*}$script %x %y]
    } else {
        $path configure -command $script
    }
    # Preserve callback errors for Tk's background error handler and add
    # the mapped X source, falling back to this registration's location.
    lassign $callback command
    set dispatch [list [namespace current]::callExport $command $location {*}[lrange $callback 1 end]]
    dict set tkState($id) binding [list $version $event $dispatch]
    return {}
}
proc tk_on_click {location canvas callback} {
    return [tkBind tk_canvas $canvas click [guardCallable callable<tk_click,unit> $callback click] $location]
}
proc tk_on_action {location button callback} {
    return [tkBind tk_button $button action [guardCallable callable<tk_action,unit> $callback action] $location]
}

proc tkDispatch {id version args} {
    variable tkState
    if {![info exists tkState($id)]} {return}
    set state $tkState($id)
    lassign [dict getdef $state binding {}] current event callback
    if {$version ne $current} {return}
    set window [list tk_window [dict get $state window]]
    if {$event eq "click"} {
        lassign $args x y
        set key none
        set prefix mt_occ_${id}_
        foreach tag [[dict get $state path] gettags current] {
            if {[string first $prefix $tag] == 0} {
                set bytes [binary decode hex -strict [string range $tag [string length $prefix] end]]
                set key [list some [encoding convertfrom -profile strict utf-8 $bytes]]
                break
            }
        }
        set payload [dict create window $window canvas [list tk_canvas $id] \
            x [guard int $x x] y [guard int $y y] occurrence $key]
    } else {
        set payload [dict create window $window button [list tk_button $id]]
    }
    if {[llength [info commands [namespace current]::workerHandle]]} {
        set owner [workerControl window [tkPath tk_window $window]]
        return [workerHandle $owner $callback $payload]
    }
    return [{*}$callback $payload]
}
