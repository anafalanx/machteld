package require machteld 30-

# This gate entry loads the original main.tcl only after this thread has
# identified the never-switched desktop. An environment marker alone cannot
# establish where Windows put a descendant of the private test runner.
namespace eval ::migrationUi {}
proc ::migrationUi::requirePrivateDesktop {} {
    if {[package provide Tk] ne {} || ![info exists ::env(MACHTELD_TEST_EXPECT_DESKTOP)] ||
        ![regexp {^MachteldDesktopTest-[0-9]+-[0-9]+$} $::env(MACHTELD_TEST_EXPECT_DESKTOP)]} {
        error "the migration UI requires a fresh interpreter on the private gate desktop"
    }
    package require cffi
    set kernel [cffi::Wrapper new kernel32.dll]
    set user [cffi::Wrapper new user32.dll]
    try {
        $kernel function GetCurrentThreadId uint {}
        $user function GetThreadDesktop ulonglong {thread uint}
        $user function GetUserObjectInformationW int {object ulonglong index int buffer pointer bytes uint needed {uint out}}
        set buffer [cffi::memory frombinary [binary format a512 {}]]
        try {
            set desktop [GetThreadDesktop [GetCurrentThreadId]]
            if {![GetUserObjectInformationW $desktop 2 $buffer 512 needed] ||
                [cffi::memory towinstring $buffer] ne $::env(MACHTELD_TEST_EXPECT_DESKTOP)} {
                error "the receiving process is outside the gate's private desktop"
            }
        } finally {cffi::memory free $buffer}
    } finally {$user destroy; $kernel destroy}
}

proc ::migrationUi::entered {command operation} {
    variable calls
    lappend calls $command
}

proc ::migrationUi::refresh {} {
    variable calls
    variable expected
    variable timer
    variable outcome
    try {
        if {![llength [info commands winfo]] || ![winfo exists .refresh] || ![winfo ismapped .refresh]} {
            set timer [after 25 [namespace code refresh]]
            return
        }
        if {[winfo class .refresh] ne "TButton" || [winfo class .caption] ne "TLabel" ||
            [.refresh cget -command] ne {::cards::refresh shelf A-17} ||
            [.caption cget -text] ne "Shelf: A-17"} {
            error "the original refresh button and initial caption did not appear"
        }
        set calls {}
        foreach command $expected {
            trace add execution [lindex $command 0] enter [namespace code entered]
        }
        set ::cards::captionText {waiting for refresh}
        if {[.caption cget -text] ne $::cards::captionText} {error "the label did not show the pending text"}
        .refresh invoke
        if {$calls ne $expected} {error "refresh called [list $calls], expected [list $expected]"}
        if {[.caption cget -text] ne "Shelf: A-17"} {error "the refresh callback did not restore the caption"}
        set outcome passed
    } on error {message options} {
        set outcome [dict get $options -errorinfo]
    }
    destroy .
}

::migrationUi::requirePrivateDesktop
if {$argv ni {{tcl source} {tcl archive} {mixed source} {mixed archive}}} {error "invalid migration UI scenario"}
lassign $argv variant delivery
set mounted [expr {[lindex [file system [info script]] 0] eq "zipfs"}]
if {$mounted != ($delivery eq "archive")} {error "the fixture ran from the wrong filesystem"}
set typed ::application::captions::caption
if {[llength [info commands $typed]] != ($variant eq "mixed")} {error "unexpected typed implementation"}
set ::migrationUi::expected [list {::cards::refresh shelf A-17} {::cards::caption shelf A-17}]
if {$variant eq "mixed"} {lappend ::migrationUi::expected [list $typed shelf A-17]}
lappend ::migrationUi::expected {::cards::fieldName shelf}

set argv {--gui shelf A-17}
set argc [llength $argv]
set ::migrationUi::outcome {the window closed before refresh completed}
set ::migrationUi::timer [after 25 ::migrationUi::refresh]
set deadline [after 10000 {
    set ::migrationUi::outcome {timed out waiting for the refresh button}
    if {[llength [info commands destroy]]} {destroy .}
}]
try {
    source -encoding utf-8 [file join [file dirname [info script]] main.tcl]
} finally {
    after cancel $deadline
    after cancel $::migrationUi::timer
}
if {$::migrationUi::outcome ne "passed"} {error $::migrationUi::outcome}
puts [list $variant $delivery {Shelf: A-17}]
