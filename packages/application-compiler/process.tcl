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

proc capture_process {exe arguments input limit timeout} {
    if {$limit < 0 || $limit > 1048576} {
        return [processProblem PROCESS_LIMIT {capture limit must be between 0 and 1048576 bytes per stream}]
    }
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
