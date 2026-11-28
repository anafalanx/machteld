# Run with the pinned upstream Tcl test shell (win/tcltests.exe).
# testasync and testthread signal this interpreter from a second OS thread.
package require -exact tcl::test 9.0.4

proc interruptUpdate {result code} {
    return -code error -errorcode {TEST FUNCTIONAL ASYNC} interrupted
}

proc checkInterrupt {kind method} {
    set values {}
    set count 0
    set handler {}
    set worker {}
    set rc [catch {
        if {$method eq "async"} {
            set handler [testasync create interruptUpdate]
            testasync marklater $handler
        } else {
            set worker [testthread create -joinable [list apply {{target} {
                after 4
                testthread cancel $target interrupted
            }} [testthread id]]]
        }
        # Bound memory even if delivery fails. There is no event loop here.
        for {set round 0} {$round < 100000} {incr round} {
            set values {}
            for {set count 0} {$count < 64} {incr count} {
                if {$kind eq "list"} {
                    set values [linsert $values end $count]
                } elseif {$kind eq "first"} {
                    set values [lindex [list [linsert $values end $count] $count] 0]
                } elseif {$kind eq "second"} {
                    set values [lindex [list $count [linsert $values end $count]] 1]
                } else {
                    set values [dict replace $values $count $count]
                }
            }
        }
    } message options]
    if {$handler ne {}} {testasync delete $handler}
    if {$worker ne {}} {testthread join $worker}
    if {$rc != 1 || $message ne "interrupted"} {error "$kind $method failed to interrupt: $rc $message"}
    set expected [expr {$method eq "async" ? {TEST FUNCTIONAL ASYNC} : {TCL CANCEL ICANCEL interrupted}}]
    if {[dict get $options -errorcode] ne $expected} {error "$kind $method: [dict get $options -errorcode]"}
    # The callback can interrupt at either side of a complete assignment.
    set n [expr {$kind ne "dict" ? [llength $values] : [dict size $values]}]
    if {$n > 64} {error "unexpected $kind size $n"}
    for {set i 0} {$i < $n} {incr i} {
        set item [expr {$kind ne "dict" ? [lindex $values $i] : [dict get $values $i]}]
        if {$item ne $i} {error "$kind lost item $i at interrupt"}
    }
}

foreach kind {list dict} {
    foreach method {async cancel} {
        for {set trial 0} {$trial < 8} {incr trial} {checkInterrupt $kind $method}
    }
}
puts "functional collection updates: 32 native cross-thread interrupt and cancellation trials passed"
foreach kind {first second} {
    foreach method {async cancel} {
        for {set trial 0} {$trial < 8} {incr trial} {checkInterrupt $kind $method}
    }
}
puts "two-element list selection: 32 native cross-thread interrupt and cancellation trials passed"


# Materialize the dictionary's string before replacing an existing key.
# Keep the same value alive while replacing itself and reuse the former map
# as a value later. Both retained representations must remain independent.
proc checkExistingEntry {} {
    set key "zero\u0000雪\U0001f6de"
    set value [binary decode hex 00ff807f00]
    set m [dict create first [clock clicks] $key old last end]
    set priorText [format {<%s>} $m]
    set m [dict replace $m $key $value]
    set m [dict replace $m $key $value]
    if {[dict keys $m] ne [list first $key last] || [binary encode hex [dict get $m $key]] ne "00ff807f00"
            || [format {<%s>} $m] eq $priorText} {error "stale existing entry or dictionary spelling"}
    set m [dict replace $m $key $m]
    set old [dict get $m $key]
    if {[binary encode hex [dict get $old $key]] ne "00ff807f00" || [dict keys $old] ne [list first $key last]} {
        error "dictionary failed to capture its previous value"
    }
}
checkExistingEntry
puts "existing dictionary entry: same-value, binary, cached spelling, order and self-assignment passed"
