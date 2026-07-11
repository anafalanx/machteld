proc kvstore_integer {token} {
    if {![regexp -indices {^[+-]?[0-9]+} $token span]} {
        error "malformed integer"
    }

    lassign $span first last
    if {$first != 0 || $last != [string length $token] - 1} {
        error "malformed integer"
    }

    set negative 0
    set firstCharacter [string index $token 0]
    if {$firstCharacter eq "+" || $firstCharacter eq "-"} {
        set negative [expr {$firstCharacter eq "-"}]
        set digits [string range $token 1 end]
    } else {
        set digits $token
    }

    while {[string length $digits] > 1 && [string index $digits 0] eq "0"} {
        set digits [string range $digits 1 end]
    }

    if {$negative} {
        set limit 9223372036854775808
    } else {
        set limit 9223372036854775807
    }
    if {[string length $digits] > [string length $limit] ||
        ([string length $digits] == [string length $limit] &&
         [string compare $digits $limit] > 0)} {
        error "integer out of range"
    }

    if {$digits eq "0"} {
        return 0
    }
    if {$negative} {
        return -$digits
    }
    return $digits
}

proc kvstore_remember {storeName transactionsName key} {
    upvar 1 $storeName store $transactionsName transactions

    if {[llength $transactions] == 0} {
        return
    }

    set undo [lindex $transactions end]
    if {![dict exists $undo $key]} {
        if {[dict exists $store $key]} {
            dict set undo $key [list 1 [dict get $store $key]]
        } else {
            dict set undo $key [list 0]
        }
        lset transactions end $undo
    }
}

proc run {cmds} {
    set store [dict create]
    set transactions {}
    set outputs {}

    foreach command $cmds {
        set fields {}
        foreach field [split $command " "] {
            if {$field ne ""} {
                lappend fields $field
            }
        }

        if {[llength $fields] == 0} {
            error "malformed command"
        }
        set operation [lindex $fields 0]

        switch -- $operation {
            SET {
                if {[llength $fields] != 3} {
                    error "malformed SET"
                }
                set key [lindex $fields 1]
                set value [kvstore_integer [lindex $fields 2]]
                kvstore_remember store transactions $key
                dict set store $key $value
            }
            GET {
                if {[llength $fields] != 2} {
                    error "malformed GET"
                }
                set key [lindex $fields 1]
                if {[dict exists $store $key]} {
                    lappend outputs [dict get $store $key]
                } else {
                    lappend outputs NULL
                }
            }
            UNSET {
                if {[llength $fields] != 2} {
                    error "malformed UNSET"
                }
                set key [lindex $fields 1]
                kvstore_remember store transactions $key
                if {[dict exists $store $key]} {
                    dict unset store $key
                }
            }
            COUNT {
                if {[llength $fields] != 2} {
                    error "malformed COUNT"
                }
                set value [kvstore_integer [lindex $fields 1]]
                set count 0
                dict for {key currentValue} $store {
                    if {$currentValue eq $value} {
                        incr count
                    }
                }
                lappend outputs $count
            }
            BEGIN {
                if {[llength $fields] != 1} {
                    error "malformed BEGIN"
                }
                lappend transactions [dict create]
            }
            ROLLBACK {
                if {[llength $fields] != 1} {
                    error "malformed ROLLBACK"
                }
                if {[llength $transactions] == 0} {
                    lappend outputs "NO TRANSACTION"
                } else {
                    set undo [lindex $transactions end]
                    set transactions [lreplace $transactions end end]
                    dict for {key previous} $undo {
                        if {[lindex $previous 0]} {
                            dict set store $key [lindex $previous 1]
                        } elseif {[dict exists $store $key]} {
                            dict unset store $key
                        }
                    }
                }
            }
            COMMIT {
                if {[llength $fields] != 1} {
                    error "malformed COMMIT"
                }
                set transactions {}
            }
            default {
                error "unrecognized command"
            }
        }
    }

    return [join $outputs "\n"]
}
