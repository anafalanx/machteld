proc jacobi {a n} {
    set a [expr {$a % $n}]
    if {$a < 0} { set a [expr {$a + $n}] }
    set result 1

    while {$a != 0} {
        while {$a % 2 == 0} {
            set a [expr {$a / 2}]
            set nmod8 [expr {$n % 8}]
            if {$nmod8 == 3 || $nmod8 == 5} {
                set result [expr {-$result}]
            }
        }

        set tmp $a
        set a $n
        set n $tmp
        if {$a % 4 == 3 && $n % 4 == 3} {
            set result [expr {-$result}]
        }
        set a [expr {$a % $n}]
    }
    return [expr {$n == 1 ? $result : 0}]
}
