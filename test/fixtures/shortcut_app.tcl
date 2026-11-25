package require -exact machteld 30

# Record the receiving process's context. Require the runner's unique
# never-switched desktop before loading Tk, and withdraw immediately.
lassign $argv receipt expected
try {
    package require cffi
    set kernel [cffi::Wrapper new kernel32.dll]
    set user [cffi::Wrapper new user32.dll]
    $kernel function GetCurrentThreadId uint {}
    $kernel function GetConsoleCP uint {}
    $user function GetThreadDesktop ulonglong {thread uint}
    $user function GetUserObjectInformationW int {object ulonglong index int buffer pointer bytes uint needed {uint out}}
    set buffer [cffi::memory frombinary [binary format a512 {}]]
    try {
        if {![GetUserObjectInformationW [GetThreadDesktop [GetCurrentThreadId]] 2 $buffer 512 needed]} {
            error {could not identify the shortcut process desktop}
        }
        set actual [cffi::memory towinstring $buffer]
    } finally {cffi::memory free $buffer}
    if {![string match MachteldDesktopTest-* $expected] || $actual ne $expected} {
        error {shortcut target was not on the requested private desktop}
    }
    set console [GetConsoleCP]
    package require Tk
    wm withdraw .
    update idletasks
    set result [dict create ok 1 desktop $actual console $console tk [winfo exists .] \
        args [lrange $argv 2 end] executable [file normalize [info nameofexecutable]] \
        archive [file normalize $argv0] workingDirectory [pwd] \
        mounted [string match {//zipfs:/*} [info script]]]
    destroy .
} on error {message options} {
    set result [dict create ok 0 message $message]
}
publish bytes $receipt [encoding convertto utf-8 $result]
