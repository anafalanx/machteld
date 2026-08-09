# log.tcl -- ::machteld::log: say what happened, where someone can read it later.
#
#   log configure -level info -file app.log
#   log info  "watching $dir" count 3
#   log warn  "queue at 90%"
#   log error "cannot open $path"
#   log configure                  -> the current settings, and what was dropped
#
# Logging is in every standard library there is -- Python's `logging`, Go's `log`,
# Deno's `log` -- and machteld had none, which matters more here than the count
# suggests: running things unattended is the whole premise. A `detach`'d daemon
# had nowhere to write at all.
#
# A WRITE FAILURE NEVER THROWS. This is the decision that shapes the rest. A
# wrapped GUI exe is started with no standard channels, so `puts stderr` there
# raises -- and a log call that can throw is a log call that kills the program at
# whatever arbitrary point it was asked to record something. Nothing is worth
# that. So a failed write increments a counter instead, and `log configure`
# reports it, which is the same bargain `watch` already makes with its `dropped`
# count: losing data silently is unacceptable, so it is counted and reported, but
# it does not become an exception in the middle of unrelated work.
#
# PAIRS AFTER THE MESSAGE ARE STRUCTURE, NOT DECORATION. `log info "started" pid
# 4812 dir /tmp` renders `... started pid=4812 dir=/tmp`. Creed 2 says
# machine-legible and human-legible should be the same thing, and a log line is
# the place that principle is most often abandoned.

namespace eval ::machteld {
    variable LOG_LEVEL   info
    variable LOG_CHAN    ""      ;# "" means: work it out at write time
    variable LOG_FILE    ""
    variable LOG_OWNED   0       ;# did we open the channel, and must we close it?
    variable LOG_DROPPED 0
}

# Ordered, so a threshold is a comparison rather than a table of what implies
# what. `debug` is the most verbose; `off` silences everything.
set ::machteld::LOG_LEVELS {debug info warn error}

proc ::machteld::LogRank {level} {
    variable LOG_LEVELS
    if {$level eq "off"} { return [llength $LOG_LEVELS] }
    return [lsearch -exact $LOG_LEVELS $level]
}

# The sink. Resolved late rather than at configure time, because stderr may exist
# by the time the first message is written even if it did not when the prelude
# loaded -- and because a tool that never logs should not open a file.
proc ::machteld::LogChan {} {
    variable LOG_CHAN
    if {$LOG_CHAN ne ""} { return $LOG_CHAN }
    return stderr
}

proc ::machteld::LogWrite {level msg pairs} {
    variable LOG_LEVEL
    variable LOG_DROPPED
    if {[LogRank $level] < [LogRank $LOG_LEVEL]} { return 0 }

    set now [clock milliseconds]
    set line [format "%s.%03d %-5s %s" \
        [clock format [expr {$now / 1000}] -format "%Y-%m-%dT%H:%M:%S"] \
        [expr {$now % 1000}] [string toupper $level] $msg]
    # A dangling key with no value is the caller's mistake, but a log line is the
    # worst possible place to raise about it: the message would be lost precisely
    # when something is already going wrong. Render what is there and mark the
    # odd one, rather than guessing which value is missing.
    set dangling ""
    if {[llength $pairs] % 2} {
        set dangling [lindex $pairs end]
        set pairs [lrange $pairs 0 end-1]
    }
    foreach {k v} $pairs { append line " $k=[LogQuote $v]" }
    if {$dangling ne ""} { append line " $dangling=?" }
    if {[catch {
        set ch [LogChan]
        puts $ch $line
        flush $ch
    }]} {
        incr LOG_DROPPED
        return 0
    }
    return 1
}

# A value with spaces or quotes would make the line ambiguous to anything trying
# to read it back, which is the entire point of the pairs.
proc ::machteld::LogQuote {v} {
    if {$v eq ""} { return {""} }
    if {[string match {*[ "	]*} $v]} {
        return "\"[string map {\\ \\\\ \" \\\"} $v]\""
    }
    return $v
}

proc ::machteld::log {args} {
    variable LOG_LEVEL
    variable LOG_LEVELS
    variable LOG_CHAN
    variable LOG_FILE
    variable LOG_OWNED
    variable LOG_DROPPED
    set subs {configure debug info warn error}
    set opts {-level -channel -file}

    if {![llength $args]} {
        Fail LOG usage "usage: log configure ?-opt val ...? | log <[join $LOG_LEVELS |]> message ?key value ...?"
    }
    set sub [lindex $args 0]
    if {$sub ni $subs} {
        Fail LOG usage "log: unknown subcommand \"$sub\": must be [join $subs {, }]"
    }

    if {$sub eq "configure"} {
        set rest [lrange $args 1 end]
        if {![llength $rest]} {
            return [dict create level $LOG_LEVEL channel [LogChan] file $LOG_FILE \
                                dropped $LOG_DROPPED]
        }
        if {[llength $rest] % 2} { Fail LOG usage "log configure: an option is missing its value" }
        foreach {o v} $rest {
            if {$o ni $opts} {
                Fail LOG usage "log configure: unknown option \"$o\": must be [join $opts {, }]"
            }
            switch -- $o {
                -level {
                    if {$v ni [concat $LOG_LEVELS off]} {
                        Fail LOG badvalue "log: unknown level \"$v\": must be [join [concat $LOG_LEVELS off] {, }]"
                    }
                    set LOG_LEVEL $v
                }
                -channel {
                    # Checked here for the same reason -file is: a channel that
                    # cannot be written is a configuration mistake, and finding
                    # out by silently counting drops is finding out too late.
                    if {$v ni [chan names]} {
                        Fail LOG badvalue "log: \"$v\" is not an open channel"
                    }
                    if {$LOG_OWNED} { catch {close $LOG_CHAN} ; set LOG_OWNED 0 }
                    set LOG_CHAN $v
                    set LOG_FILE ""
                }
                -file {
                    # Opened here, not at first write, so a path that cannot be
                    # written is reported to whoever configured it rather than
                    # discovered later by a message that quietly went nowhere.
                    if {[catch {open $v a} ch]} {
                        Fail LOG oserror "log: cannot open \"$v\" for appending"
                    }
                    fconfigure $ch -translation lf -buffering line
                    if {$LOG_OWNED} { catch {close $LOG_CHAN} }
                    set LOG_CHAN $ch
                    set LOG_FILE $v
                    set LOG_OWNED 1
                }
            }
        }
        return
    }

    if {[llength $args] < 2} { Fail LOG usage "log $sub: a message is required" }
    LogWrite $sub [lindex $args 1] [lrange $args 2 end]
    return
}
