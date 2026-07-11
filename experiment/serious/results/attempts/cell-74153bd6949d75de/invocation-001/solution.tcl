proc damm_valid {n} {
    if {$n < 0} {
        return 0
    }

    set table {
        0317598642
        7092154863
        4206871359
        1750983426
        6123045978
        3674209581
        5869720134
        8945362017
        9438617205
        2581436790
    }

    set interim 0
    foreach digit [split $n ""] {
        set interim [string index [lindex $table $interim] $digit]
    }

    return [expr {$interim == 0 ? 1 : 0}]
}
