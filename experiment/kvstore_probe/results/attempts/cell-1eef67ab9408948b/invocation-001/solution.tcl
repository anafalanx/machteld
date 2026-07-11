proc run {cmds} {
    set store [dict create]
    set transactions {}
    set output {}

    foreach command $cmds {
        set words {}
        foreach word [split $command " "] {
            if {$word ne ""} {
                lappend words $word
            }
        }

        if {[llength $words] == 0} {
            error "malformed command"
        }

        set operation [lindex $words 0]
        switch -- $operation {
            SET {
                if {[llength $words] != 3} {
                    error "malformed SET"
                }
                set key [lindex $words 1]
                set numeral [lindex $words 2]

                set valid 0
                if {[regexp -indices {^[+-]?[0-9]+} $numeral span]} {
                    lassign $span first last
                    if {$first == 0 && $last == [string length $numeral] - 1} {
                        set valid 1
                    }
                }
                if {!$valid} {
                    error "malformed integer"
                }

                set negative 0
                set digitStart 0
                set sign [string index $numeral 0]
                if {$sign eq "+"} {
                    set digitStart 1
                } elseif {$sign eq "-"} {
                    set digitStart 1
                    set negative 1
                }
                set magnitude 0
                for {set i $digitStart} {$i < [string length $numeral]} {incr i} {
                    scan [string index $numeral $i] %c code
                    set magnitude [expr {$magnitude * 10 + $code - 48}]
                }
                if {$negative} {
                    if {$magnitude > 9223372036854775808} {
                        error "integer out of range"
                    }
                    set value [expr {-$magnitude}]
                } else {
                    if {$magnitude > 9223372036854775807} {
                        error "integer out of range"
                    }
                    set value $magnitude
                }

                if {[llength $transactions] > 0} {
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
                dict set store $key $value
            }
            GET {
                if {[llength $words] != 2} {
                    error "malformed GET"
                }
                set key [lindex $words 1]
                if {[dict exists $store $key]} {
                    lappend output [dict get $store $key]
                } else {
                    lappend output "NULL"
                }
            }
            UNSET {
                if {[llength $words] != 2} {
                    error "malformed UNSET"
                }
                set key [lindex $words 1]
                if {[llength $transactions] > 0} {
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
                if {[dict exists $store $key]} {
                    dict unset store $key
                }
            }
            COUNT {
                if {[llength $words] != 2} {
                    error "malformed COUNT"
                }
                set numeral [lindex $words 1]

                set valid 0
                if {[regexp -indices {^[+-]?[0-9]+} $numeral span]} {
                    lassign $span first last
                    if {$first == 0 && $last == [string length $numeral] - 1} {
                        set valid 1
                    }
                }
                if {!$valid} {
                    error "malformed integer"
                }

                set negative 0
                set digitStart 0
                set sign [string index $numeral 0]
                if {$sign eq "+"} {
                    set digitStart 1
                } elseif {$sign eq "-"} {
                    set digitStart 1
                    set negative 1
                }
                set magnitude 0
                for {set i $digitStart} {$i < [string length $numeral]} {incr i} {
                    scan [string index $numeral $i] %c code
                    set magnitude [expr {$magnitude * 10 + $code - 48}]
                }
                if {$negative} {
                    if {$magnitude > 9223372036854775808} {
                        error "integer out of range"
                    }
                    set value [expr {-$magnitude}]
                } else {
                    if {$magnitude > 9223372036854775807} {
                        error "integer out of range"
                    }
                    set value $magnitude
                }

                set count 0
                dict for {storedKey storedValue} $store {
                    if {$storedValue eq $value} {
                        incr count
                    }
                }
                lappend output $count
            }
            BEGIN {
                if {[llength $words] != 1} {
                    error "malformed BEGIN"
                }
                lappend transactions [dict create]
            }
            ROLLBACK {
                if {[llength $words] != 1} {
                    error "malformed ROLLBACK"
                }
                if {[llength $transactions] == 0} {
                    lappend output "NO TRANSACTION"
                } else {
                    set undo [lindex $transactions end]
                    set transactions [lreplace $transactions end end]
                    dict for {key prior} $undo {
                        if {[lindex $prior 0]} {
                            dict set store $key [lindex $prior 1]
                        } elseif {[dict exists $store $key]} {
                            dict unset store $key
                        }
                    }
                }
            }
            COMMIT {
                if {[llength $words] != 1} {
                    error "malformed COMMIT"
                }
                set transactions {}
            }
            default {
                error "unknown command"
            }
        }
    }

    return [join $output "\n"]
}
