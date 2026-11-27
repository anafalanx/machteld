package require machteld

proc usage {} {
    return -code error -errorcode {APPCOMPILER PROJECT USAGE} \
        [format {usage: %s check ?--json? MANIFEST | run MANIFEST ?ARG ...? | pack MANIFEST OUTPUT | rebuild ARCHIVE OUTPUT} [file tail $::argv0]]
}

namespace eval ::projectDriver {}

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

set jsonCheck [expr {[lrange $argv 0 1] eq {check --json}}]
set diagnostics {}
set compilerLoaded 0
try {
    source -encoding utf-8 [file join [file dirname [info script]] compiler.tcl]
    set compilerLoaded 1
    lassign $argv action input output
    switch -exact -- $action {
        check {
            if {$jsonCheck} {
                if {$argc != 3} {usage}
                set input $output
            } elseif {$argc != 2} {usage}
            ::appcompiler::project::build $input
        }
        run {
            if {$argc < 2} {usage}
            set projectBuild [::appcompiler::project::build $input]
            set argv0 [file normalize $input]
            set argv [lrange $argv 2 end]
            set argc [llength $argv]
            namespace eval :: [dict get $projectBuild artifact script]
        }
        pack - rebuild {
            if {$argc != 3} {usage}
            puts [::appcompiler::project::$action $input $output]
        }
        default {usage}
    }
} on error {message options} {
    if {!$jsonCheck} {
        puts stderr $message
        exit 1
    }
    set diagnostics [::projectDriver::failure $message $options $compilerLoaded]
}
if {$jsonCheck} {
    ::projectDriver::writeReport $diagnostics
    exit [expr {[llength $diagnostics] != 0}]
}
