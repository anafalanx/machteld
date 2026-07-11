proc rpn_eval {prog length} {
    if {$length < 0} {
        set length 0
    } elseif {$length > 8} {
        set length 8
    }

    set stack {}
    for {set i 0} {$i < $length} {incr i} {
        set token [expr {($prog >> (4 * $i)) & 0xF}]

        if {$token <= 9} {
            if {[llength $stack] < 4} {
                lappend stack $token
            }
            continue
        }

        if {$token >= 14} {
            continue
        }

        set count [llength $stack]
        if {$count < 2} {
            continue
        }

        set b [lindex $stack end]
        set a [lindex $stack end-1]
        set stack [lreplace $stack end-1 end]

        switch $token {
            10 {
                set value [expr {$a + $b}]
            }
            11 {
                set value [expr {$a - $b}]
            }
            12 {
                set value [expr {$a * $b}]
            }
            13 {
                if {$b == 0} {
                    set value 0
                } else {
                    set quotient [expr {abs($a) / abs($b)}]
                    if {($a < 0) != ($b < 0)} {
                        set value [expr {-$quotient}]
                    } else {
                        set value $quotient
                    }
                }
            }
        }
        lappend stack $value
    }

    if {[llength $stack] == 0} {
        return 0
    }
    return [lindex $stack end]
}
