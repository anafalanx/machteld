# Checked Tcl implementation of the two public history queries. Each admitted
# observation is projected to tick, channel, and a reading or the empty marker.
# The public functions never return this internal representation.
namespace eval ::checkedHistory {}

proc ::checkedHistory::bad {path type} {
    return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected $type at $path"
}

# For the usual Tcl integer object, numeric equality of its value alone is
# insufficient: e.g. the external spellings +001, 010 and 0x10 differ.
# The permissive numeric path succeeds only for a canonical decimal spelling.
proc ::checkedHistory::integer {value path} {
    append value {}
    if {[string is entier -strict $value]} {
        set n [expr {$value | 0}]
        if {[string equal $n $value]} {return $n}
    }
    if {![regexp {\A[+-]?[0-9]+\Z} $value]} {bad $path int}
    scan $value %lld n
    return $n
}
# The result rows are private to this handwritten implementation.
# Keep unusual spellings and detailed diagnostics off the common path.
proc ::checkedHistory::events {events} {
    append events {}
    if {[catch {llength $events}]} {bad {$events} list<.kernels::event>}
    set out {}
    set i -1
    foreach row $events {
        incr i
        append row {}
        if {[catch {dict get $row tick} tick]} {
            if {[catch {dict size $row}]} {bad [format {$events.%d} $i] .kernels::event}
            bad [format {$events.%d.tick} $i] int
        }
        append tick {}
        if {[catch {expr {$tick | 0}} n] || $tick ne $n} {
            set n [integer $tick [format {$events.%d.tick} $i]]
        }
        if {[catch {dict get $row channel} channel]} {bad [format {$events.%d.channel} $i] text}
        set opt [dict getdef $row reading none]
        append opt {}
        set reading {}
        if {$opt ne "none"} {
            if {[catch {llength $opt} arity]} {bad [format {$events.%d.reading} $i] int?}
            set tag [lindex $opt 0]
            if {$arity == 2 && $tag eq "some"} {
                set v [lindex $opt 1]
                append v {}
                if {[catch {expr {$v | 0}} reading] || $v ne $reading} {
                    set reading [integer $v [format {$events.%d.reading} $i]]
                }
            } elseif {$arity != 1 || $tag ne "none"} {
                bad [format {$events.%d.reading} $i] int?
            }
        }
        lappend out [list $n $channel $reading]
    }
    return $out
}

proc ::checkedHistory::requests {queries} {
    set out {}
    set i 0
    append queries {}
    if {[catch {llength $queries}]} {bad {$queries} list<.history::query>}
    foreach row $queries {
        set path [format {$queries.%d} $i]
        append row {}
        if {[catch {dict size $row}]} {bad $path .history::query}
        foreach field {cutoff channel start stop} {
            if {![dict exists $row $field]} {
                bad $path.$field [expr {$field eq "channel" ? "text" : "int"}]
            }
            set $field [dict get $row $field]
            if {$field ne "channel"} {set $field [integer [set $field] $path.$field]}
        }
        lappend out [list $cutoff $channel $start $stop]
        incr i
    }
    return $out
}
proc ::checkedHistory::key {channel} {
    append channel {}
    if {[string first \u0000 $channel] < 0} {return $channel}
    # Rejoin logical Tcl characters so keys have one representation even when
    # an older native decoder returned a raw zero byte in a Tcl string.
    return [join [split $channel \u0000] \u0000]
}
proc ::checkedHistory::snapshotBody {events cutoff} {
    set state {}
    foreach event $events {
        lassign $event tick channel value
        if {$tick > $cutoff} break
        if {$value ne {}} {dict set state [key $channel] $value}
    }
    return $state
}
proc ::checkedHistory::windowBody {events wanted start end} {
    append wanted {}
    set out {}
    foreach event $events {
        lassign $event tick channel value
        if {$tick < $start || $tick >= $end} continue
        append channel {}
        if {![string equal $channel $wanted] &&
                ([string first \u0000 $channel] < 0 ||
                 ![string equal [key $channel] [key $wanted]])} continue
        if {$value ne {}} {lappend out $value}
    }
    return $out
}
proc ::checkedHistory::snapshot {data cutoff} {
    set rows [events $data]
    return [snapshotBody $rows [integer $cutoff {$cutoff}]]
}
proc ::checkedHistory::window_readings {data channel start end} {
    set rows [events $data]
    return [windowBody $rows $channel [integer $start {$start}] [integer $end {$end}]]
}
proc ::checkedHistory::batch {data queries} {
    set rows [events $data]
    set checked [requests $queries]
    set out {}
    foreach q $checked {
        lassign $q cutoff channel start stop
        lappend out [dict create state [snapshotBody $rows $cutoff] readings [windowBody $rows $channel $start $stop]]
    }
    return $out
}
