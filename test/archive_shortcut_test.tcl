package require -exact machteld 30

proc check {label condition} {
    if {!$condition} {error "FAIL $label"}
    puts "ok   $label"
}
if {![info exists env(MACHTELD_TEST_EXPECT_DESKTOP)] ||
        ![string match MachteldDesktopTest-* $env(MACHTELD_TEST_EXPECT_DESKTOP)] || [llength $argv] != 1} {
    error {run archive_shortcut_test.tcl on the isolated desktop with the window fixture}
}
set scratch [file tempdir]
try {
    set install [file join $scratch {relocated 安装}]
    set cwd [file join $scratch {shortcut working directory}]
    file mkdir $install $cwd
    set exe [file join $install machteld.exe]
    file copy -- [info nameofexecutable] $exe
    set archive [file join $install {example app.machteld}]
    set entry [file join [file dirname [info script]] fixtures shortcut_app.tcl]
    set built [run -timeout 30s -- [info nameofexecutable] pack $entry -o $archive]
    check "the actual runtime packs the shortcut application" [expr {[dict get $built exit] == 0 && [file isfile $archive]}]
    set receipt [file join $scratch result.dict]
    set shortcut [file join $scratch {open example.lnk}]
    set expected $env(MACHTELD_TEST_EXPECT_DESKTOP)
    set words [list {two words} {café 🚉} {& [literal] $5} {}]
    # These fixture words contain neither a quote nor a trailing backslash.
    set arguments [join [lmap word [list [file nativename $archive] [file nativename $receipt] $expected {*}$words] {
        format {"%s"} $word
    }] { }]
    exec [lindex $argv 0] --make-archive-link [file nativename $shortcut] [file nativename $cwd] \
        [file nativename $exe] $arguments
    desktop open $shortcut
    set deadline [expr {[clock milliseconds] + 20000}]
    while {![file exists $receipt] && [clock milliseconds] < $deadline} {after 25}
    check "Windows dispatched the real Shell link to the archive" [file isfile $receipt]
    set f [open $receipt rb]
    try {set result [encoding convertfrom -profile strict utf-8 [read $f]]} finally {close $f}
    if {![dict get $result ok]} {error [dict get $result message]}
    check "the selected archive on the relocated host received the original arguments" [expr {
        [dict get $result mounted] && [dict get $result archive] eq $archive &&
        [dict get $result executable] eq $exe && [dict get $result args] eq $words}]
    check "the shortcut preserves its independent working directory" [expr {[dict get $result workingDirectory] eq $cwd}]
    check "Tk starts on the requested private desktop" [expr {[dict get $result tk] && [dict get $result desktop] eq $expected}]
    check "the shortcut target has no attached console at application entry" [expr {[dict get $result console] == 0}]
    check "the installed folder contains only the host and archive" [expr {
        [lsort [glob -directory $install -tails *]] eq [list {example app.machteld} machteld.exe]}]
} finally {
    # The shell starts the target asynchronously. Its image can still be
    # mapped for a moment after the Tcl script publishes its final receipt.
    set deadline [expr {[clock milliseconds] + 5000}]
    while {[info exists exe] && [file exists $exe] && [catch {file delete -- $exe}]} {
        if {[clock milliseconds] >= $deadline} break
        after 25
    }
    file delete -force -- $scratch
}
