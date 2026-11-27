# These operations use the host's supervised process tree and binary capture.
proc processProblem {code message} {return [list err [dict create code $code message $message]]}

proc toolPath {relative} {
    variable toolDirectory
    if {![info exists toolDirectory] || [lindex [file system $toolDirectory] 0] ne "native"} {
        return [processProblem PROCESS_CONTEXT {tool resolution requires a native application directory}]
    }
    set path [file join $toolDirectory $relative]
    if {![file isfile $path]} {return [processProblem PROCESS_NOT_FOUND "application tool not found: $relative"]}
    return [list ok $path]
}

proc processLaunchOptions {exe arguments timeout} {
    if {$timeout < 0 || $timeout >= 4294967295} {
        return [processProblem PROCESS_TIMEOUT {timeout must be between 0 and 4294967294 milliseconds}]
    }
    if {[string first \u0000 $exe] >= 0 || [string index $exe 0] eq "~" || [file pathtype $exe] ne "absolute" ||
            [lindex [file system $exe] 0] ne "native" || ![string equal -nocase [file extension $exe] .exe]} {
        return [processProblem PROCESS_PATH {expected an absolute native .exe path}]
    }
    if {![file isfile $exe]} {return [processProblem PROCESS_NOT_FOUND "executable not found: $exe"]}
    foreach arg $arguments {
        if {[string first \u0000 $arg] >= 0} {return [processProblem PROCESS_ARGUMENT {an argument contains NUL}]}
    }
    set options {}
    if {$timeout} {lappend options -timeout ${timeout}ms}
    return [list ok $options]
}

proc capture_process {exe arguments input limit timeout} {
    if {$limit < 0 || $limit > 1048576} {
        return [processProblem PROCESS_LIMIT {capture limit must be between 0 and 1048576 bytes per stream}]
    }
    set launch [processLaunchOptions $exe $arguments $timeout]
    lassign $launch tag options
    if {$tag eq "err"} {return $launch}
    try {
        set child [::machteld::run {*}$options -stdin $input -- $exe {*}$arguments]
    } on error {message detail} {
        set native [dict get $detail -errorcode]
        set code [expr {$native eq {MACHTELD RUN notfound} ? "PROCESS_NOT_FOUND" : "PROCESS_LAUNCH"}]
        return [list err [dict create code $code message $message hostCode $native]]
    }
    set output [dict create status [dict get $child status] exit [dict get $child exit]]
    foreach {stream key} {out stdout err stderr} {
        set bytes [dict get $child $stream]
        set clipped [expr {[string length $bytes] > $limit}]
        if {$clipped} {set bytes [binary format a* [string range $bytes 0 $limit-1]]}
        dict set output $key $bytes
        dict set output ${key}_retained [string length $bytes]
        dict set output ${key}_truncated [expr {$clipped || $stream in [dict get $child truncated]}]
    }
    return [list ok $output]
}

# Search only absolute directories listed in PATH. Never add the caller's
# directory, PATHEXT, a shell, or an implicit extension.
proc find_executable {name} {
    if {[file tail $name] ne $name || [regexp {[:/\\\x00]} $name] ||
            ![string equal -nocase [file extension $name] .exe] || [file pathtype $name] ne "relative"} {
        return [processProblem PROCESS_PATH {expected a bare .exe name for PATH lookup}]
    }
    if {[info exists ::env(PATH)]} {
        foreach directory [split $::env(PATH) {;}] {
            if {[string index $directory 0] eq "\"" && [string index $directory end] eq "\""} {
                set directory [string range $directory 1 end-1]
            }
            if {[file pathtype $directory] ne "absolute" || [string index $directory 0] eq "~" ||
                    [lindex [file system $directory] 0] ne "native"} continue
            set path [file join $directory $name]
            if {[file isfile $path]} {return [list ok [file normalize $path]]}
        }
    }
    return [processProblem PROCESS_NOT_FOUND "executable not found on PATH: $name"]
}

# Preserve the launching handler's lifetime for callbacks and for any new
# streams they start. A nested event loop can deliver unrelated events, so
# a global "current window" would assign the wrong owner. Inspect only the
# active synchronous callback frames, or the current worker coroutine.
proc streamCallback {scope callback args} {
    return [{*}$callback {*}$args]
}
proc streamScope {} {
    set rt [namespace current]
    for {set level [expr {[info level] - 1}]} {$level > 0} {incr level -1} {
        set frame [info level $level]
        if {[lindex $frame 0] eq "${rt}::streamCallback"} {return [lindex $frame 1]}
    }
    variable workerHandlers
    if {[info exists workerHandlers]} {
        set owner [dict getdef $workerHandlers [info coroutine] application]
        if {$owner ne "application"} {
            return [list [list ${rt}::workerOnClose $owner] [list ${rt}::workerForgetClose $owner] \
                [list ${rt}::workerOwnerLive $owner]]
        }
    }
    return {}
}
proc streamScopeLive {scope} {
    if {$scope eq {}} {return 1}
    return [{*}[lindex $scope 2]]
}

# Every channel handler carries the stream key. A retired or queued handler
# can never operate on a newly assigned channel with the same native name.
proc stream_process {location exe arguments input chunk timeout stdout stderr done} {
    variable streamOwner
    variable streamJobs
    if {$chunk < 1 || $chunk > 65536} {
        return [processProblem PROCESS_LIMIT {stream chunk size must be between 1 and 65536 bytes}]
    }
    set launch [processLaunchOptions $exe $arguments $timeout]
    lassign $launch tag options
    if {$tag eq "err"} {return $launch}
    if {![info exists streamOwner]} {set streamOwner [binary encode hex [::machteld::hash random 16]]}
    set key [binary encode hex [::machteld::hash random 16]]
    try {
        set child [::machteld::child start -console none -channels -onexit [list [namespace current]::streamExited $key] {*}$options -- $exe {*}$arguments]
        set info [::machteld::child info $child]
        set channels {}
        foreach name {stdin stdout stderr} {
            set ch [dict get $info $name]
            chan configure $ch -blocking 0 -translation binary -buffering none -buffersize $chunk
            if {$name eq "stdin" && [string length $input] == 0} {
                close $ch
            } else {
                dict set channels $name $ch
            }
        }
        set scope [streamScope]
        set streamJobs($key) [dict create child $child channels $channels input $input offset 0 chunk $chunk \
            stdout $stdout stderr $stderr done $done stdout_bytes 0 stderr_bytes 0 native {} busy 0 timer {} scope $scope location $location]
        if {$scope ne {}} {
            lassign $scope register forget
            set token [{*}$register [list [namespace current]::streamFinish $key ownerClosed]]
            dict set streamJobs($key) detach [list {*}$forget $token]
        }
        streamArm $key 1
    } on error {message options} {
        if {[info exists streamJobs($key)]} {
            streamFinish $key closed
        } elseif {[info exists child]} {
            catch {::machteld::child kill $child}
            catch {::machteld::child close $child}
        }
        set native [dict get $options -errorcode]
        set code [expr {$native eq {MACHTELD CHILD notfound} ? "PROCESS_NOT_FOUND" : "PROCESS_LAUNCH"}]
        return [list err [dict create code $code message $message hostCode $native]]
    }
    return [list ok [list $streamOwner $key]]
}

proc streamArm {key enabled} {
    variable streamJobs
    if {![info exists streamJobs($key)]} {return}
    set channels [dict get $streamJobs($key) channels]
    if {![dict size $channels]} {dict set streamJobs($key) timer {}; return}
    set prefix {}
    if {$enabled} {
        set prefix [list [namespace current]::streamPump $key]
        # Re-arming a Windows pipe after nested event processing does not
        # guarantee another notification for data already signaled. A single
        # fallback wakes this job. An ordinary event cancels it immediately.
        dict set streamJobs($key) timer [after 50 $prefix]
    }
    dict for {name channel} $channels {
        chan event $channel [expr {$name eq "stdin" ? "writable" : "readable"}] $prefix
    }
}

proc streamExited {key child result} {
    variable streamJobs
    if {![info exists streamJobs($key)] || [dict get $streamJobs($key) child] ne $child} {return}
    dict set streamJobs($key) native $result
    streamMaybeFinish $key
    if {[info exists streamJobs($key)]} {streamPump $key}
}

proc streamMaybeFinish {key} {
    variable streamJobs
    if {![info exists streamJobs($key)] || [dict get $streamJobs($key) busy]} {return}
    if {[dict exists $streamJobs($key) canceled]} {
        streamFinish $key canceled
        return
    }
    set native [dict get $streamJobs($key) native]
    if {$native eq {} || [dict exists $streamJobs($key) channels stdout] || [dict exists $streamJobs($key) channels stderr]} return
    if {[dict get $native status] eq "oserror"} {
        streamFinish $key failed [processProblem PROCESS_IO [dict get $native message]]
    } else {
        streamFinish $key completed
    }
}

proc streamFinish {key reason {result {}}} {
    variable streamJobs
    if {![info exists streamJobs($key)]} {return}
    set job $streamJobs($key)
    unset streamJobs($key)
    if {![streamScopeLive [dict get $job scope]]} {set reason ownerClosed}
    if {$reason ne "ownerClosed" && [dict exists $job detach]} {{*}[dict get $job detach]}
    if {[dict get $job timer] ne {}} {after cancel [dict get $job timer]}
    # The native child owns its channels, also when cancellation occurs
    # during a user callback. It closes only the original channel objects.
    if {$reason ne "completed"} {catch {::machteld::child kill [dict get $job child]}}
    if {[catch {::machteld::child close [dict get $job child]} message]} {
        set result [processProblem PROCESS_IO $message]
    }
    if {$reason in {closed ownerClosed} || ![streamScopeLive [dict get $job scope]]} {return}
    if {$result eq {}} {
        set native [dict get $job native]
        set status [dict getdef $native status canceled]
        set exit [dict getdef $native exit -1]
        if {$reason eq "canceled"} {set status canceled; set exit -1}
        set result [list ok [dict create status $status exit $exit stdout_bytes [dict get $job stdout_bytes] stderr_bytes [dict get $job stderr_bytes]]]
    }
    # Notify after releasing the child, including when the consumer fails.
    if {[catch {[namespace current]::streamCallback [dict get $job scope] [dict get $job done] $result} message options]} {
        reportFault process-done $message $options [dict get $job location]
    }
}

proc cancel_process {ticket} {
    variable streamJobs
    set key [lindex $ticket 1]
    if {[info exists streamJobs($key)]} {
        dict set streamJobs($key) canceled 1
        streamMaybeFinish $key
    }
    return {}
}

proc close_process {ticket} {
    streamFinish [lindex $ticket 1] closed
    return {}
}

proc streamWrite {key} {
    variable streamJobs
    set ch [dict get $streamJobs($key) channels stdin]
    if {[chan pending output $ch] > 0} {return}
    set offset [dict get $streamJobs($key) offset]
    set input [dict get $streamJobs($key) input]
    if {$offset < [string length $input]} {
        set end [expr {$offset + [dict get $streamJobs($key) chunk] - 1}]
        try {
            puts -nonewline $ch [string range $input $offset $end]
            dict set streamJobs($key) offset [expr {$end + 1}]
            return
        } trap {POSIX EPIPE} {} {
            # A child can close its input early and still return useful output.
        }
    }
    dict unset streamJobs($key) channels stdin
    dict set streamJobs($key) input {}
    close $ch
}

proc streamPump {key} {
    variable streamJobs
    if {![info exists streamJobs($key)] || [dict get $streamJobs($key) busy]} {return}
    if {![streamScopeLive [dict get $streamJobs($key) scope]]} {
        streamFinish $key ownerClosed
        return
    }
    set timer [dict get $streamJobs($key) timer]
    if {$timer ne {}} {after cancel $timer; dict set streamJobs($key) timer {}}
    dict set streamJobs($key) busy 1
    set delivered 0
    try {
        streamArm $key 0
        if {[dict exists $streamJobs($key) channels stdin]} {streamWrite $key}
        # A single event services both outputs. Slow callbacks exert pipe
        # backpressure. Nested event loops cannot run another chunk handler.
        foreach name {stdout stderr} {
            if {![dict exists $streamJobs($key) channels $name]} continue
            set ch [dict get $streamJobs($key) channels $name]
            set bytes [read $ch [dict get $streamJobs($key) chunk]]
            if {[eof $ch]} {dict unset streamJobs($key) channels $name}
            if {[string length $bytes] == 0} continue
            set delivered 1
            dict incr streamJobs($key) ${name}_bytes [string length $bytes]
            set callbackCode [catch {[namespace current]::streamCallback [dict get $streamJobs($key) scope] \
                    [dict get $streamJobs($key) $name] $bytes} outcome options]
            if {![info exists streamJobs($key)]} {return}
            if {[dict exists $streamJobs($key) canceled]} break
            if {$callbackCode} {
                set origin [mappedLocation $options [sourceMap] [dict get $streamJobs($key) location]]
                dict set options -appcompilerlocation $origin
                set outcome [list err [dict create code PROCESS_CALLBACK message $outcome origin $origin options $options]]
            }
            if {[lindex $outcome 0] eq "err"} {
                streamFinish $key failed $outcome
                return
            }
        }
    } on error {message options} {
        streamFinish $key failed [processProblem PROCESS_IO $message]
        return
    }
    dict set streamJobs($key) busy 0
    streamMaybeFinish $key
    if {[info exists streamJobs($key)]} {
        # Windows pipes can already hold the last byte when the native
        # completion event arrives. A new OS readiness edge is optional.
        if {[dict get $streamJobs($key) native] ne {}} {
            set delay [expr {$delivered ? 0 : 5}]
            dict set streamJobs($key) timer [after $delay [list [namespace current]::streamPump $key]]
        } else {
            dict set streamJobs($key) timer [after idle [list [namespace current]::streamArm $key 1]]
        }
    }
}
