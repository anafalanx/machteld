package require machteld
# The GUI basekit creates an unmapped Tk root. This is a command-line example,
# even when its host has the GUI subsystem: never enter Tk's event loop.
if {[llength [info commands ::destroy]]} { ::destroy . }
fconfigure stdout -encoding utf-8 -translation lf
fconfigure stderr -encoding utf-8 -translation lf
try {
    set library [file join [file dirname [info nameofexecutable]] examplemath.dll]
    if {![file isfile $library]} {
        error "Required adjacent extension is missing: $library"
    }
    # Explicit absolute filename and package name. No auto_path/PATH/CWD search,
    # package-index evaluation, downloading, or extraction from the archive.
    load $library Examplemath
    if {[llength $argv] != 2} { error "usage: extension-example.exe signed32 signed32" }
    puts [::examplemath::add {*}$argv]
} on error {message options} {
    puts stderr $message
    exit 1
}
exit 0
