# Read-only example controller. No Tk dependency and no nested event loops.
namespace eval ::inspector {}

oo::class create ::inspector::Job {
    variable worker observer state token streams generation timers buffer ended complete

    constructor {workerPath {onChange {}} {workerCommand {}}} {
        # Existing callers may supply a plain worker script. Wrapped apps use
        # an explicit executable/role prefix instead of pretending zipfs files
        # are scripts understood by their own application entry point.
        set worker [expr {$workerCommand eq {} ?
            [list [info nameofexecutable] [file normalize $workerPath]] : $workerCommand}]
        if {![llength $worker]} { error "empty inspection worker command" }
        set observer $onChange
        set token {}; set streams {}; set generation 0; set timers {}
        set buffer {}; set ended {}; set complete 0
        set state [dict create phase idle root {} mode {} rows {} progress 0 \
            message Ready error {} log {}]
    }

    destructor { my release }
    method snapshot {} { return $state }
    method notify {} {
        # Observers may cancel or close; handlers recheck their generation after
        # notification. Observer errors must not strand a supervised child.
        set object [self]
        set failed 0
        if {$observer ne {}} { set failed [catch {{*}$observer $object $state} message] }
        # A view may destroy its controller during a callback. Its destructor
        # already cleaned up; do not invoke the now-deleted `my` command again.
        if {![info object isa object $object]} { return 0 }
        if {$failed} {
            my release
            set observer {}
            if {[dict get $state phase] ne "closed"} {
                dict set state phase error
                dict set state message "View update failed; inspection stopped."
            }
            dict set state error $message
        }
        return 1
    }
    method live {stamp} {
        expr {$stamp == $generation && [dict get $state phase] eq "running"}
    }
    method later {key delay script} {
        if {[dict exists $timers $key]} { after cancel [dict get $timers $key] }
        dict set timers $key [after $delay $script]
    }
    method yield {stamp key script} {
        my later $key idle [list [self] defer $stamp $key $script]
    }
    method defer {stamp key script} {
        if {![my live $stamp]} { return }
        # No I/O during the idle phase: let all already queued paint callbacks
        # run before the next turn enables another bounded slice of work.
        my later $key 0 $script
    }
    method release {} {
        incr generation
        dict for {key timer} $timers { after cancel $timer }
        set timers {}
        dict for {name channel} $streams { catch {chan event $channel readable {}} }
        set streams {}
        if {$token ne {}} { catch {::machteld::child close $token}; set token {} }
    }
    method start {directory {mode inspect}} {
        if {[dict get $state phase] in {running closed}} { return 0 }
        if {$mode ni {inspect slow fail noisy}} { error "unknown inspection mode: $mode" }
        my release
        set state [dict create phase running root $directory mode $mode rows {} \
            progress 0 message "Starting $mode inspection..." error {} log {}]
        set buffer {}; set ended [dict create stdout 0 stderr 0]; set complete 0
        set stamp $generation
        try {
            # No shell interpolation. Both the program and directory remain
            # individual arguments even with spaces, Unicode, or punctuation.
            set token [::machteld::child start -channels -timeout 30s -mem 128M -- \
                {*}$worker $directory $mode]
            set io [::machteld::child info $token]
            close [dict get $io stdin]
            foreach name {stdout stderr} {
                set ch [dict get $io $name]
                dict set streams $name $ch
                fconfigure $ch -blocking 0 -translation binary
                if {$name eq "stderr"} {
                    fconfigure $ch -translation lf -encoding utf-8 -profile replace
                }
                chan event $ch readable [list [self] readable $stamp $name]
            }
            my later reap 25 [list [self] poll $stamp]
            my notify
        } on error {message options} {
            my fail "Could not start inspection: $message"
        }
        return 1
    }
    method fail {message} {
        my release
        dict set state phase error
        dict set state message "Inspection failed; correct the problem and try again."
        dict set state error $message
        my notify
    }
    method cancel {} {
        if {[dict get $state phase] ne "running"} { return 0 }
        my release
        dict set state phase canceled
        dict set state message "Canceled; partial rows are retained."
        my notify
        return 1
    }
    method close {} {
        my release
        dict set state phase closed
        set observer {}
    }
    method readable {stamp name} {
        if {![my live $stamp]} { return }
        try {
            set ch [dict get $streams $name]
            chan event $ch readable {}
            # Limit each event's work. Never use an unbounded read or gets.
            set chunk [read $ch 8192]
            dict set ended $name [eof $ch]
            if {$name eq "stderr"} {
                dict append state log $chunk
                dict set state log [string range [dict get $state log] end-8191 end]
                if {![my notify]} { return }
                if {![my live $stamp]} { return }
                if {![dict get $ended stderr]} {
                    my yield $stamp stderr [list [self] rearm $stamp stderr]
                }
            } else {
                append buffer $chunk
                my consume $stamp
            }
        } on error {message options} {
            if {[my live $stamp]} { my fail "Inspection stream error: $message" }
        }
    }
    method rearm {stamp name} {
        if {![my live $stamp]} { return }
        try {
            chan event [dict get $streams $name] readable [list [self] readable $stamp $name]
        } on error {message options} {
            my fail "Could not resume inspection stream: $message"
        }
    }
    method consume {stamp} {
        if {![my live $stamp]} { return }
        try {
            for {set count 0} {$count < 32} {incr count} {
                set split [string first \n $buffer]
                if {$split < 0} { break }
                if {$split > 65536} { error "protocol record exceeds 65536 bytes" }
                set line [string range $buffer 0 $split-1]
                set buffer [string range $buffer $split+1 end]
                my record [encoding convertfrom -profile strict utf-8 $line]
            }
            if {[string first \n $buffer] >= 0} {
                my yield $stamp pump [list [self] consume $stamp]
            } elseif {[string length $buffer] > 65536} {
                error "protocol record exceeds 65536 bytes"
            } elseif {[dict get $ended stdout]} {
                if {$buffer ne {}} { error "unterminated protocol record" }
            } else {
                # A continuously ready channel otherwise starves Tk's idle
                # painting even though ordinary timers can run. Keep BOTH
                # streams disarmed until their next bounded turn.
                my yield $stamp stdout [list [self] rearm $stamp stdout]
            }
            my notify
        } on error {message options} {
            if {[my live $stamp]} { my fail "Inspection protocol error: $message" }
        }
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
    method poll {stamp} {
        if {![my live $stamp]} { return }
        try {
            if {![dict get [::machteld::child info $token] running] &&
                    [dict get $ended stdout] && [dict get $ended stderr] && $buffer eq {}} {
                # Already completed, both pipes drained: this is a zero-time
                # reap, never a wait for work on the GUI thread.
                set result [::machteld::child wait $token -timeout 0ms]
                if {[dict get $result status] ne "ok" || [dict get $result exit] != 0 || !$complete} {
                    my fail "Child ended with status [dict get $result status], exit [dict get $result exit].\n[dict get $state log]"
                    return
                }
                my release
                dict set state phase done
                dict set state progress 100
                dict set state message "Complete: [llength [dict get $state rows]] entries."
                my notify
            } else { my later reap 25 [list [self] poll $stamp] }
        } on error {message options} {
            if {[my live $stamp]} { my fail "Inspection lifecycle error: $message" }
        }
    }
}
