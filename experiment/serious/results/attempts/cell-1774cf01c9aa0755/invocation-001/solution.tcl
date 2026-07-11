proc date_valid {d} {
    if {$d <= 0} {
        return 0
    }

    set day [expr {$d % 100}]
    set month [expr {($d / 100) % 100}]
    set year [expr {$d / 10000}]

    if {$year < 1 || $year > 9999 ||
        $month < 1 || $month > 12 ||
        $day < 1} {
        return 0
    }

    set month_days {31 28 31 30 31 30 31 31 30 31 30 31}
    set maximum [lindex $month_days [expr {$month - 1}]]
    if {$month == 2 &&
        $year % 4 == 0 &&
        ($year % 100 != 0 || $year % 400 == 0)} {
        set maximum 29
    }

    return [expr {$day <= $maximum ? 1 : 0}]
}
