# Read-only example controller. No Tk dependency and no nested event loops.
namespace eval ::inspector {
    # A source checkout can also run on the previous signed host.
    set packageRoot [file normalize [file join [file dirname [info script]] .. .. packages]]
    if {[file isdirectory $packageRoot] && $packageRoot ni $::auto_path} {
        lappend ::auto_path $packageRoot
    }
    unset packageRoot
}
package require machteld::job 1.0

oo::class create ::inspector::Job {
    variable worker observer state transport complete generation

    constructor {workerPath {onChange {}} {workerCommand {}}} {
        set worker [expr {$workerCommand eq {} ?
            [list [info nameofexecutable] [file normalize $workerPath]] : $workerCommand}]
        if {![llength $worker]} { error "empty inspection worker command" }
        set observer $onChange
        set complete 0
        set generation 0
        set state [dict create phase idle root {} mode {} rows {} progress 0 \
            message Ready error {} log {}]
        set transport [::machteld::job::Job new [list [self] onJob]]
    }

    destructor {
        if {[info exists transport]} { $transport destroy }
    }

    method snapshot {} { return $state }

    method notify {} {
        if {$observer eq {}} { return }
        set object [self]
        set stamp $generation
        if {![catch {{*}$observer $object $state} message]} { return }
        if {![info object isa object $object] || $stamp != $generation} { return }
        set observer {}
        if {[dict get $state phase] ne "closed"} {
            dict set state phase error
            dict set state message "View update failed; inspection stopped."
        }
        dict set state error $message
        $transport cancel
    }

    method start {directory {mode inspect}} {
        if {[dict get $state phase] in {running closed}} { return 0 }
        if {$mode ni {inspect slow fail noisy}} { error "unknown inspection mode: $mode" }
        incr generation
        set complete 0
        set state [dict create phase running root $directory mode $mode rows {} \
            progress 0 message "Starting $mode inspection..." error {} log {}]
        return [$transport start [list {*}$worker $directory $mode] -console none]
    }

    method cancel {} { return [$transport cancel] }

    method close {} {
        $transport close
        dict set state phase closed
        set observer {}
    }

    method onJob {job event data} {
        if {[dict get $state phase] ne "running"} { return }
        switch -- $event {
            started {}
            lines {
                foreach line $data { my record $line }
            }
            stderr {
                dict set state log [dict get [$job snapshot] log]
            }
            finished {
                dict set state log [dict get $data log]
                set phase [dict get $data phase]
                dict set state phase $phase
                if {$phase eq "canceled"} {
                    dict set state message "Canceled; partial rows are retained."
                } elseif {$phase eq "done" && $complete} {
                    dict set state progress 100
                    dict set state message "Complete: [llength [dict get $state rows]] entries."
                } else {
                    set reason [dict get $data error]
                    if {$phase eq "done"} { set reason "Child ended without a completion record." }
                    if {[dict get $data log] ne {}} {
                        append reason "\n" [dict get $data log]
                    }
                    dict set state phase error
                    dict set state message "Inspection failed; correct the problem and try again."
                    dict set state error $reason
                }
            }
        }
        my notify
    }

    method record {line} {
        if {$complete} { error "record received after completion" }
        set typed [::machteld::json decode -typed -maxbytes 65536 $line]
        if {[::machteld::json type $typed] ne "object"} { error "expected a JSON object" }
        # Decode plainly only after strict validation (including duplicate keys).
        set row [::machteld::json decode $line]
        switch -- [dict get $row type] {
            progress {
                set n [dict get $row value]
                if {![string is integer -strict $n] || $n < 0 || $n > 100} {
                    error "invalid progress value"
                }
                dict set state progress $n
                dict set state message [string range [dict get $row message] 0 1023]
            }
            row {
                if {[llength [dict get $state rows]] >= 500} { error "row limit exceeded (500)" }
                foreach key {name path kind size} { dict get $row $key }
                if {[dict get $row kind] ni {file directory link other} ||
                        ![string is entier -strict [dict get $row size]] || [dict get $row size] < 0} {
                    error "invalid file row"
                }
                dict lappend state rows $row
            }
            complete { set complete 1 }
            default { error "unknown protocol record" }
        }
    }
}
