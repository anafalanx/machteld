proc _kvParseInt {token} {
    if {![regexp -indices {^[+-]?[0-9]+} $token span]} {
        error "not an integer: $token"
    }
    lassign $span first last
    if {$first != 0 || $last != [string length $token] - 1} {
        error "not an integer: $token"
    }

    set negative [expr {[string index $token 0] eq "-"}]
    set start [expr {[string index $token 0] in {+ -} ? 1 : 0}]
    set magnitude 0
    for {set i $start} {$i < [string length $token]} {incr i} {
        scan [string index $token $i] %c code
        set magnitude [expr {$magnitude * 10 + $code - 48}]
    }
    set value [expr {$negative ? -$magnitude : $magnitude}]
    if {$value < -9223372036854775808 || $value > 9223372036854775807} {
        error "integer out of range: $token"
    }
    return $value
}

proc _kvTokens {command} {
    set tokens {}
    foreach token [split $command " "] {
        if {$token ne ""} {
            lappend tokens $token
        }
    }
    return $tokens
}

proc run {commands} {
    set store [dict create]
    set transactions {}
    set output {}

    foreach command $commands {
        set tokens [_kvTokens $command]
        set count [llength $tokens]
        if {$count == 0} {
            error "empty command"
        }
        set word [lindex $tokens 0]

        switch -- $word {
            SET {
                if {$count != 3} { error "SET needs 2 args" }
                set key [lindex $tokens 1]
                set value [_kvParseInt [lindex $tokens 2]]
                if {[llength $transactions] > 0} {
                    set index [expr {[llength $transactions] - 1}]
                    set log [lindex $transactions $index]
                    if {[dict exists $store $key]} {
                        lappend log [list $key 1 [dict get $store $key]]
                    } else {
                        lappend log [list $key 0 {}]
                    }
                    lset transactions $index $log
                }
                dict set store $key $value
            }
            GET {
                if {$count != 2} { error "GET needs 1 arg" }
                set key [lindex $tokens 1]
                if {[dict exists $store $key]} {
                    lappend output [dict get $store $key]
                } else {
                    lappend output NULL
                }
            }
            UNSET {
                if {$count != 2} { error "UNSET needs 1 arg" }
                set key [lindex $tokens 1]
                if {[llength $transactions] > 0} {
                    set index [expr {[llength $transactions] - 1}]
                    set log [lindex $transactions $index]
                    if {[dict exists $store $key]} {
                        lappend log [list $key 1 [dict get $store $key]]
                    } else {
                        lappend log [list $key 0 {}]
                    }
                    lset transactions $index $log
                }
                if {[dict exists $store $key]} {
                    dict unset store $key
                }
            }
            COUNT {
                if {$count != 2} { error "COUNT needs 1 arg" }
                set target [_kvParseInt [lindex $tokens 1]]
                set matches 0
                dict for {_ value} $store {
                    if {$value == $target} { incr matches }
                }
                lappend output $matches
            }
            BEGIN {
                if {$count != 1} { error "BEGIN takes no args" }
                lappend transactions {}
            }
            ROLLBACK {
                if {$count != 1} { error "ROLLBACK takes no args" }
                set depth [llength $transactions]
                if {$depth == 0} {
                    lappend output "NO TRANSACTION"
                } else {
                    set log [lindex $transactions end]
                    set transactions [lreplace $transactions end end]
                    foreach change [lreverse $log] {
                        lassign $change key had old
                        if {$had} {
                            dict set store $key $old
                        } elseif {[dict exists $store $key]} {
                            dict unset store $key
                        }
                    }
                }
            }
            COMMIT {
                if {$count != 1} { error "COMMIT takes no args" }
                set transactions {}
            }
            default {
                error "unknown command: $word"
            }
        }
    }

    return [join $output "\n"]
}
