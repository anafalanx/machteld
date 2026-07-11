proc kvstoreCanonicalInteger {token} {
    set length [string length $token]
    if {$length == 0} {
        error "invalid integer"
    }

    set negative 0
    set position 0
    set first [string index $token 0]
    if {$first eq "+" || $first eq "-"} {
        set negative [expr {$first eq "-"}]
        set position 1
        if {$length == 1} {
            error "invalid integer"
        }
    }

    for {set i $position} {$i < $length} {incr i} {
        scan [string index $token $i] %c code
        if {$code < 48 || $code > 57} {
            error "invalid integer"
        }
    }

    set digits [string range $token $position end]
    set digitCount [string length $digits]
    set firstNonzero 0
    while {$firstNonzero < $digitCount &&
           [string index $digits $firstNonzero] eq "0"} {
        incr firstNonzero
    }

    if {$firstNonzero == $digitCount} {
        return "0"
    }
    set digits [string range $digits $firstNonzero end]

    set digitCount [string length $digits]
    if {$digitCount > 19} {
        error "integer out of range"
    }
    if {$digitCount == 19} {
        if {$negative} {
            set limit "9223372036854775808"
        } else {
            set limit "9223372036854775807"
        }
        if {[string compare $digits $limit] > 0} {
            error "integer out of range"
        }
    }

    if {$negative} {
        return "-$digits"
    }
    return $digits
}

proc run {cmds} {
    set store [dict create]
    set transactions {}
    set outputs {}

    foreach command $cmds {
        set tokens {}
        foreach token [split $command " "] {
            if {$token ne ""} {
                lappend tokens $token
            }
        }

        if {[llength $tokens] == 0} {
            error "malformed command"
        }
        set operation [lindex $tokens 0]

        switch -- $operation {
            SET {
                if {[llength $tokens] != 3} {
                    error "malformed SET"
                }
                set key [lindex $tokens 1]
                set value [kvstoreCanonicalInteger [lindex $tokens 2]]
                dict set store $key $value
            }
            GET {
                if {[llength $tokens] != 2} {
                    error "malformed GET"
                }
                set key [lindex $tokens 1]
                if {[dict exists $store $key]} {
                    lappend outputs [dict get $store $key]
                } else {
                    lappend outputs "NULL"
                }
            }
            UNSET {
                if {[llength $tokens] != 2} {
                    error "malformed UNSET"
                }
                set key [lindex $tokens 1]
                if {[dict exists $store $key]} {
                    dict unset store $key
                }
            }
            COUNT {
                if {[llength $tokens] != 2} {
                    error "malformed COUNT"
                }
                set wanted [kvstoreCanonicalInteger [lindex $tokens 1]]
                set count 0
                dict for {key value} $store {
                    if {$value eq $wanted} {
                        incr count
                    }
                }
                lappend outputs $count
            }
            BEGIN {
                if {[llength $tokens] != 1} {
                    error "malformed BEGIN"
                }
                lappend transactions $store
            }
            ROLLBACK {
                if {[llength $tokens] != 1} {
                    error "malformed ROLLBACK"
                }
                if {[llength $transactions] == 0} {
                    lappend outputs "NO TRANSACTION"
                } else {
                    set store [lindex $transactions end]
                    set transactions [lreplace $transactions end end]
                }
            }
            COMMIT {
                if {[llength $tokens] != 1} {
                    error "malformed COMMIT"
                }
                set transactions {}
            }
            default {
                error "unknown command"
            }
        }
    }

    return [join $outputs "\n"]
}
