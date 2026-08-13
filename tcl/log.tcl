# log.tcl -- ::machteld::log: say what happened, where someone can read it later.
#
#   log configure -level info -file app.log
#   log info  "watching $dir" count 3
#   log warn  "queue at 90%"
#   log error "cannot open $path"
#   log configure                  -> the current settings, and what was dropped
#
# A write failure never throws: a GUI host may have no standard channels, and a
# diagnostic must not terminate unrelated work. Failures increment `dropped`.
# Key/value pairs after the message remain machine- and human-readable.

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
        set newLevel $LOG_LEVEL
        set sinkKind current
        set sinkValue ""
        foreach {o v} $rest {
            if {$o ni $opts} {
                Fail LOG usage "log configure: unknown option \"$o\": must be [join $opts {, }]"
            }
            switch -- $o {
                -level {
                    if {$v ni [concat $LOG_LEVELS off]} {
                        Fail LOG badvalue "log: unknown level \"$v\": must be [join [concat $LOG_LEVELS off] {, }]"
                    }
                    set newLevel $v
                }
                -channel {
                    # Checked here for the same reason -file is: a channel that
                    # cannot be written is a configuration mistake, and finding
                    # out by silently counting drops is finding out too late.
                    if {$v ni [chan names]} {
                        Fail LOG badvalue "log: \"$v\" is not an open channel"
                    }
                    set sinkKind channel
                    set sinkValue $v
                }
                -file {
                    set sinkKind file
                    set sinkValue $v
                }
            }
        }
        # Commit only after the whole request is known to be valid. A bad final
        # option must not leave a different level or half-installed sink behind.
        set staged ""
        if {$sinkKind eq "file"} {
            if {[catch {
                set staged [open $sinkValue a]
                fconfigure $staged -translation lf -buffering line
            }]} {
                if {$staged ne ""} { catch {close $staged} }
                Fail LOG oserror "log: cannot open \"$sinkValue\" for appending"
            }
        }
        if {$sinkKind ne "current" && $LOG_OWNED} { catch {close $LOG_CHAN} }
        set LOG_LEVEL $newLevel
        if {$sinkKind eq "channel"} {
            set LOG_CHAN $sinkValue
            set LOG_FILE ""
            set LOG_OWNED 0
        } elseif {$sinkKind eq "file"} {
            set LOG_CHAN $staged
            set LOG_FILE $sinkValue
            set LOG_OWNED 1
        }
        return
    }

    if {[llength $args] < 2} { Fail LOG usage "log $sub: a message is required" }
    return [LogWrite $sub [lindex $args 1] [lrange $args 2 end]]
}

::machteld::MetaDefine log [dict create kind tcl args args domain LOG \
    codes {badvalue oserror usage} options {-channel -file -level} doc machteld/command/log \
    subcommands [dict create \
        configure [dict create options {-channel -file -level} doc machteld/command/log#configure] \
        debug [dict create options {} doc machteld/command/log#debug] \
        info [dict create options {} doc machteld/command/log#info] \
        warn [dict create options {} doc machteld/command/log#warn] \
        error [dict create options {} doc machteld/command/log#error]]]
