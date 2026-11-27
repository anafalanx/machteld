# Split the parser's canonical type spelling at the outermost commas. This
# procedure is also embedded in the generated runtime for boundary checks.
proc ::appcompiler::typeParts {type} {
    if {[string index $type end] eq "?"} {
        return [list optional [string range $type 0 end-1]]
    }
    set open [string first < $type]
    if {$open < 0} {return [list $type]}
    if {[string index $type end] ne ">"} {error "malformed type [list $type]"}
    set parts [list [string range $type 0 $open-1]]
    set depth 0
    set start [expr {$open + 1}]
    for {set i $start} {$i < [string length $type] - 1} {incr i} {
        switch -- [string index $type $i] {
            < {incr depth}
            > {incr depth -1}
            , {
                if {$depth == 0} {
                    lappend parts [string range $type $start $i-1]
                    set start [expr {$i + 1}]
                }
            }
        }
    }
    lappend parts [string range $type $start end-1]
    return $parts
}

# Replace entire parameter atoms, once. A replacement can itself contain a
# caller's type parameters; it belongs to that caller's lexical scope.
proc ::appcompiler::substituteType {type bindings} {
    if {![dict size $bindings] || [string first @ $type] < 0} { return $type }
    set result ""
    set pos 0
    foreach span [regexp -all -inline -indices {@[A-Za-z_][A-Za-z_0-9:]*} $type] {
        lassign $span start end
        set atom [string range $type $start $end]
        set actual [dict getdef $bindings $atom $atom]
        if {[string length $result] + $start - $pos + [string length $actual] > 8192} {
            return -code error -errorcode {APPCOMPILER TYPE_EXPANSION_LIMIT} \
                {expanded type exceeds 8192 characters}
        }
        append result [string range $type $pos $start-1] $actual
        set pos [expr {$end + 1}]
    }
    if {[string length $result] + [string length $type] - $pos > 8192} {
        return -code error -errorcode {APPCOMPILER TYPE_EXPANSION_LIMIT} \
            {expanded type exceeds 8192 characters}
    }
    append result [string range $type $pos end]
    return $result
}

# Substitute only the immediate members. Recursive schemas can describe
# arbitrarily deep values without first constructing an infinite type table.
proc ::appcompiler::specializeSchema {type schemas} {
    set parts [typeParts $type]
    set entry [dict getdef $schemas [lindex $parts 0] {}]
    if {$entry eq ""} { return {} }
    lassign $entry kind members variables
    set arguments [lrange $parts 1 end]
    if {[llength $arguments] != [llength $variables]} { return {} }
    if {![llength $variables]} { return $entry }
    set bindings {}
    foreach variable $variables argument $arguments { dict set bindings $variable $argument }
    set result {}
    dict for {name member} $members {
        if {$kind eq "record"} {
            dict set result $name [substituteType $member $bindings]
        } else {
            dict set result $name [lmap item $member {substituteType $item $bindings}]
        }
    }
    return [list $kind $result]
}
