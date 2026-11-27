package require machteld

namespace eval ::projectDriver {}

proc ::projectDriver::synopsis {} {
    return [format {usage: %s check ?--json? MANIFEST | locate MANIFEST|ARCHIVE MODULE ?LINE? | test MANIFEST | run MANIFEST ?ARG ...? | pack MANIFEST OUTPUT | rebuild ARCHIVE OUTPUT | docs ARCHIVE|--runtime search QUERY ?LIMIT? | docs ARCHIVE|--runtime get ID ?OFFSET? ?LIMIT?} [file tail $::argv0]]
}

proc ::projectDriver::usage {} {
    return -code error -errorcode {APPCOMPILER PROJECT USAGE} [synopsis]
}

proc ::projectDriver::jsonString {value} {
    set value [string map [list \\ {\\} \" {\"}] $value]
    set value [regsub -all -command {[\x00-\x1f]} $value {apply {{c} {format {\u%04x} [scan $c %c]}}}]
    return "\"$value\""
}

proc ::projectDriver::writeReport {diagnostics} {
    set rows {}
    foreach item $diagnostics {
        set node null
        if {[dict exists $item node]} {
            set pos [dict get $item node]
            set node [format {{"module":%s,"line":%d,"column":%d,"endLine":%d,"endColumn":%d}} \
                [jsonString [dict get $pos module]] [dict get $pos line] [dict get $pos column] \
                [dict get $pos endLine] [dict get $pos endColumn]]
        }
        lappend rows [format {{"code":%s,"message":%s,"node":%s}} [jsonString [dict get $item code]] \
            [jsonString [dict get $item message]] $node]
    }
    set ok [expr {[llength $rows] ? "false" : "true"}]
    set document [format {{"schema":1,"ok":%s,"diagnostics":[%s]}} $ok [join $rows ,]]
    chan configure stdout -translation binary
    puts -nonewline stdout [encoding convertto -profile strict utf-8 "$document\n"]
}

proc ::projectDriver::failure {message options compilerLoaded} {
    set code INTERNAL_ERROR
    if {$compilerLoaded} {
        switch -glob -- [dict get $options -errorcode] {
            {APPCOMPILER CHECK} {
                set diagnostics [dict getdef $options -diagnostics {}]
                if {[llength $diagnostics]} {return $diagnostics}
            }
            {APPCOMPILER PROJECT INVALID} - {MACHTELD PACK badvalue} {set code PROJECT_INVALID}
            {POSIX *} - {WINDOWS *} - {MACHTELD PACK notfound} - {MACHTELD PACK oserror} {set code PROJECT_IO}
            {APPCOMPILER PROJECT USAGE} {set code CLI_USAGE}
        }
    }
    return [list [dict create code $code message $message]]
}

proc ::projectDriver::main {argv driverDirectory} {
    set argc [llength $argv]
    set jsonCheck [expr {[lrange $argv 0 1] eq {check --json}}]
    set diagnostics {}
    set compilerLoaded 0
    try {
        set loadedVersion [package provide application-compiler]
        if {$loadedVersion eq {}} {
            uplevel #0 [list source -encoding utf-8 [file join $driverDirectory compiler.tcl]]
        } elseif {$loadedVersion ne "0.1" || ![info exists ::appcompiler::compilerDirectory] ||
                $::appcompiler::compilerDirectory ne $driverDirectory} {
            error "a different application compiler is already loaded; run this project's driver in a fresh interpreter"
        }
        set compilerLoaded 1
        lassign $argv action input output
        switch -exact -- $action {
            --help {
                if {$argc != 1} {usage}
                puts [synopsis]
            }
            check {
                if {$jsonCheck} {
                    if {$argc != 3} {usage}
                    set input $output
                } elseif {$argc != 2} {usage}
                ::appcompiler::project::check $input
            }
            test {
                if {$argc != 2} {usage}
                set report [::appcompiler::project::test $input]
                foreach diagnostic [dict get $report failures] {
                    puts stderr [::appcompiler::formatDiagnostic $diagnostic]
                }
                puts [format {%d examples: %d passed, %d failed} [dict get $report total] \
                    [dict get $report passed] [dict get $report failed]]
                if {[dict get $report failed]} {exit 1}
            }
            locate {
                if {$argc ni {3 4}} {usage}
                set answer [::appcompiler::project::locate $input {*}[lrange $argv 2 end]]
                chan configure stdout -translation binary
                puts -nonewline stdout [encoding convertto -profile strict utf-8 "$answer\n"]
            }
            run {
                if {$argc < 2} {usage}
                set projectBuild [::appcompiler::project::build $input]
                set ::argv0 [file normalize $input]
                if {[lindex [file system $driverDirectory] 0] eq "native" && [llength [info commands ::machteld::app]]} {
                    # A loose driver's worker needs the same compiler and
                    # manifest even when the child starts in another directory.
                    set ::machteld::launchPrefix [list [info nameofexecutable] \
                        [file join $driverDirectory driver.tcl] run $::argv0]
                }
                if {[dict get $projectBuild project tclEntry] ne {}} {
                    set ::argv0 [file join [file dirname $::argv0] [dict get $projectBuild project tclEntry]]
                }
                set ::argv [lrange $argv 2 end]
                set ::argc [llength $::argv]
                return [uplevel #0 [dict get $projectBuild artifact script]]
            }
            pack - rebuild {
                if {$argc != 3} {usage}
                puts [::appcompiler::project::$action $input $output]
            }
            docs {
                if {$argc < 4} {usage}
                set answer [::appcompiler::reference::query $input {*}[lrange $argv 2 end]]
                if {$output eq "search" && $answer ne {}} {append answer \n}
                chan configure stdout -translation binary
                puts -nonewline stdout [encoding convertto -profile strict utf-8 $answer]
            }
            default {usage}
        }
    } on error {message options} {
        if {!$jsonCheck} {
            if {[info exists projectBuild] && [dict get $projectBuild project tclEntry] ne {}} {
                # Tcl's accumulated stack includes source file and line, plus
                # the original typed location when a public export fails.
                set message [dict getdef $options -errorinfo $message]
            }
            puts stderr $message
            exit 1
        }
        set diagnostics [::projectDriver::failure $message $options $compilerLoaded]
    }
    if {$jsonCheck} {
        ::projectDriver::writeReport $diagnostics
        exit [expr {[llength $diagnostics] != 0}]
    }
}

::projectDriver::main $::argv [file dirname [file normalize [info script]]]
