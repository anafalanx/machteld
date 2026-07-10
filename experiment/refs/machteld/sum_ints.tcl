proc sum_ints {s} {
    set total 0
    foreach tok [regexp -all -inline {\S+} $s] {
        if {[regexp {^[+-]?[0-9]+$} $tok]} {
            set total [expr {$total + $tok}]
        }
    }
    return $total
}
