proc rpn_eval {prog length} {
    if {$length < 0} { set length 0 }
    if {$length > 8} { set length 8 }
    set stack {}
    for {set i 0} {$i < $length} {incr i} {
        set token [expr {($prog >> (4 * $i)) & 15}]
        if {$token <= 9} {
            if {[llength $stack] < 4} { lappend stack $token }
        } elseif {$token <= 13 && [llength $stack] >= 2} {
            set b [lindex $stack end]
            set a [lindex $stack end-1]
            set stack [lrange $stack 0 end-2]
            switch -- $token {
                10 { set value [expr {$a + $b}] }
                11 { set value [expr {$a - $b}] }
                12 { set value [expr {$a * $b}] }
                13 {
                    if {$b == 0} {
                        set value 0
                    } else {
                        set q [expr {abs($a) / abs($b)}]
                        set value [expr {(($a < 0) != ($b < 0)) ? -$q : $q}]
                    }
                }
            }
            lappend stack $value
        }
    }
    return [expr {[llength $stack] ? [lindex $stack end] : 0}]
}
