proc regmachine {prog k} {
    if {$k < 0} {
        return 0
    }

    set acc 0
    set pc 0
    set steps 0

    while {$steps < $k && $pc < 16} {
        set opcode [expr {($prog >> (4 * $pc)) & 0xf}]

        if {$opcode == 0} {
            return $acc
        }

        incr steps
        switch $opcode {
            1 {
                incr acc
            }
            2 {
                incr acc -1
            }
            3 {
                set acc [expr {$acc * 2}]
            }
            4 {
                set acc [expr {-$acc}]
            }
            5 {
                if {$acc < 0} {
                    set acc [expr {-((- $acc) / 2)}]
                } else {
                    set acc [expr {$acc / 2}]
                }
            }
            6 {
                incr acc 3
            }
            7 {
                incr acc -5
            }
            8 {
                if {$acc == 0} {
                    incr pc 2
                } else {
                    incr pc
                }
                continue
            }
            9 {
                if {$acc != 0} {
                    incr pc 2
                } else {
                    incr pc
                }
                continue
            }
            10 {
                set acc [expr {$acc * 3}]
            }
            11 {
                if {$acc < 0} {
                    set acc [expr {-((- $acc) % 2)}]
                } else {
                    set acc [expr {$acc % 2}]
                }
            }
            12 {
                set acc [expr {abs($acc)}]
            }
            13 {
                set acc 0
            }
            14 {
                incr acc 2
            }
            15 {
                incr acc -2
            }
        }

        incr pc
    }

    return $acc
}
