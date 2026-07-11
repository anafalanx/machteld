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

        if {$token >= 10 && $token <= 13 && [llength $stack] >= 2} {
            set b [lindex $stack end]
            set stack [lreplace $stack end end]
            set a [lindex $stack end]
            set stack [lreplace $stack end end]

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
                        set value [expr {abs($a) / abs($b)}]
                        if {($a < 0) != ($b < 0)} {
                            set value [expr {-$value}]
                        }
                    }
                }
            }

            lappend stack $value
        }
    }

    if {[llength $stack] == 0} {
        return 0
    }
    return [lindex $stack end]
}
