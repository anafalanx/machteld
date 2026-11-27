package require machteld

# Development entry for file-backed typed applications. Resolve the compiler
# beside this tool, independent of the caller's working directory or PATH.
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

proc usage {} {
    return -code error {usage: application_project.tcl check MANIFEST | run MANIFEST ?ARG ...? | pack MANIFEST OUTPUT | rebuild ARCHIVE OUTPUT}
}

try {
    lassign $argv action input output
    switch -exact -- $action {
        check {
            if {$argc != 2} {usage}
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
    puts stderr $message
    exit 1
}
