# One supervised child. stdout is an LF-delimited UTF-8 record stream;
# stderr is diagnostic text. The application interprets the records.
package require Tcl 9
package require machteld

namespace eval ::machteld::job {}

oo::class create ::machteld::job::Job {
    variable callback state token streams generation timers buffer ended completion

    constructor {{onEvent {}}} {
        # Parse the prefix now so a malformed list cannot strand a child later.
        llength $onEvent
        set callback $onEvent
        set state [dict create phase idle result {} error {} log {}]
        set token {}
        set streams {}
        set generation 0
        set timers {}
        set buffer {}
        set ended {}
        set completion {}
    }

    destructor { my release }

    method snapshot {} { return $state }

    method live {stamp} {
        expr {$stamp == $generation && [dict get $state phase] eq "running"}
    }

    method emit {event data} {
        if {$callback eq {}} { return }
        set object [self]
        set stamp $generation
        if {![catch {{*}$callback $object $event $data} message]} { return }
        # The callback may have destroyed the object, canceled or restarted.
        if {![info object isa object $object] || $generation != $stamp} { return }
        if {$event eq "finished"} {
            dict set state phase error
            dict set state error $message
            return
        }
        my finish error $message
    }

    method later {key delay script} {
        if {[dict exists $timers $key]} { after cancel [dict get $timers $key] }
        dict set timers $key [after $delay $script]
    }

    method yield {stamp key script} {
        # Re-arm after idle work has had a turn, even for always-readable pipes.
        my later $key idle [namespace code [list my defer $stamp $key $script]]
    }

    method defer {stamp key script} {
        if {[my live $stamp]} { my later $key 0 $script }
    }

    method release {} {
        incr generation
        dict for {key timer} $timers { after cancel $timer }
        set timers {}
        dict for {name channel} $streams { catch {chan event $channel readable {}} }
        set streams {}
        set buffer {}
        if {$token ne {}} {
            catch {::machteld::child close $token}
            set token {}
        }
    }

    method finish {phase {message {}}} {
        my release
        dict set state phase $phase
        dict set state error $message
        my emit finished $state
    }

    method start {argv args} {
        if {[dict get $state phase] in {running closed}} { return 0 }
        if {![llength $argv]} { error "empty child command" }
        if {[llength $args] % 2} { error "expected option/value pairs for -timeout, -mem, -window or -console" }
        set options [dict create -timeout 30s -mem 128M]
        foreach {option value} $args {
            if {$option ni {-window -console} && ![dict exists $options $option]} { error "unknown job option: $option" }
            dict set options $option $value
        }

        my release
        set stamp $generation
        set state [dict create phase running result {} error {} log {}]
        set ended [dict create stdout 0 stderr 0]
        set completion {}
        try {
            set token [::machteld::child start -channels -onexit [namespace code [list my completed $stamp]] {*}$options -- {*}$argv]
            set io [::machteld::child info $token]
            close [dict get $io stdin]
            foreach name {stdout stderr} {
                set ch [dict get $io $name]
                dict set streams $name $ch
                fconfigure $ch -blocking 0 -translation binary
                if {$name eq "stderr"} {
                    fconfigure $ch -translation lf -encoding utf-8 -profile replace
                }
                chan event $ch readable [namespace code [list my readable $stamp $name]]
            }
        } on error {message options} {
            my finish error "Could not start child: $message"
            return 1
        }
        my emit started {}
        return 1
    }

    method cancel {} {
        if {[dict get $state phase] ne "running"} { return 0 }
        my finish canceled
        return 1
    }

    method close {} {
        my release
        dict set state phase closed
        set callback {}
    }

    method readable {stamp name} {
        if {![my live $stamp]} { return }
        set object [self]
        try {
            set ch [dict get $streams $name]
            chan event $ch readable {}
            set chunk [read $ch 8192]
            dict set ended $name [eof $ch]
            if {$name eq "stdout"} {
                append buffer $chunk
                my consume $stamp
            } else {
                dict append state log $chunk
                dict set state log [string range [dict get $state log] end-8191 end]
                if {$chunk ne {}} { my emit stderr $chunk }
                if {[info object isa object $object] && [my live $stamp]} {
                    if {[dict get $ended stderr]} {
                        my maybeFinish $stamp
                    } else {
                        my yield $stamp stderr [namespace code [list my rearm $stamp stderr]]
                    }
                }
            }
        } on error {message options} {
            if {[info object isa object $object] && [my live $stamp]} { my finish error $message }
        }
    }

    method rearm {stamp name} {
        if {![my live $stamp]} { return }
        try {
            chan event [dict get $streams $name] readable [namespace code [list my readable $stamp $name]]
        } on error {message options} {
            my finish error $message
        }
    }

    method consume {stamp} {
        if {![my live $stamp]} { return }
        set object [self]
        try {
            set lines {}
            for {set count 0} {$count < 32} {incr count} {
                set split [string first \n $buffer]
                if {$split < 0} { break }
                if {$split > 65536} { error "protocol record exceeds 65536 bytes" }
                lappend lines [encoding convertfrom -profile strict utf-8 [string range $buffer 0 $split-1]]
                set buffer [string range $buffer $split+1 end]
            }

            if {[llength $lines]} { my emit lines $lines }
            if {![info object isa object $object] || ![my live $stamp]} { return }
            if {[string first \n $buffer] >= 0} {
                my yield $stamp pump [namespace code [list my consume $stamp]]
            } elseif {[string length $buffer] > 65536} {
                error "protocol record exceeds 65536 bytes"
            } elseif {[dict get $ended stdout]} {
                if {$buffer ne {}} { error "unterminated protocol record" }
                my maybeFinish $stamp
            } else {
                my yield $stamp stdout [namespace code [list my rearm $stamp stdout]]
            }
        } on error {message options} {
            if {[info object isa object $object] && [my live $stamp]} { my finish error $message }
        }
    }

    method completed {stamp child result} {
        if {![my live $stamp]} { return }
        set completion $result
        my maybeFinish $stamp
    }

    method maybeFinish {stamp} {
        if {![my live $stamp] || $completion eq {} || ![dict get $ended stdout] ||
                ![dict get $ended stderr] || $buffer ne {}} { return }
        dict set state result $completion
        set status [dict get $completion status]
        set exit [dict get $completion exit]
        if {$status eq "ok" && $exit == 0} {
            my finish done
        } elseif {$status eq "oserror"} {
            my finish error [dict get $completion message]
        } else {
            my finish error "Child ended with status $status, exit $exit."
        }
    }

    unexport live emit later yield defer release finish readable rearm consume completed maybeFinish
}

package provide machteld::job 1.0
