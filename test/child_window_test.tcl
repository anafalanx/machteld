package require machteld

# Starts real Win32 windows. Run on an interactive desktop with window_fixture.exe.
if {[llength $argv] != 1} { error "usage: child_window_test.tcl window_fixture.exe" }
set fixture [file normalize [lindex $argv 0]]
set work [file tempdir]
set tokens {}
set checks 0

proc check {label value} {
    if {!$value} { error "FAIL $label" }
    incr ::checks
    puts "ok   $label"
}
proc signalFixture {path name} { close [open [file join $path $name] {WRONLY CREAT EXCL}] }
proc reported {path name} {
    set file [file join $path $name]
    set deadline [expr {[clock milliseconds] + 10000}]
    while {![file isfile $file]} {
        if {[clock milliseconds] >= $deadline} { error "fixture did not report $name in $path" }
        after 15
    }
    set f [open $file rb]
    try { return [string trim [read $f]] } finally { close $f }
}
proc startFixture {leaf class mode disposition args} {
    set path [file join $::work $leaf]
    file mkdir $path
    set token [child start {*}$args -dir $path -timeout 1m -- $::fixture $disposition $class $mode]
    lappend ::tokens $token
    return [list $token $path [reported $path started]]
}
proc closeFixture {token} {
    child close $token
    set ::tokens [lsearch -all -inline -not -exact $::tokens $token]
}
proc observe {path} {
    file delete [file join $path observed]
    signalFixture $path observe
    return [reported $path observed]
}
proc ready {token args} {
    set deadline [expr {[clock milliseconds] + 8000}]
    while {1} {
        set report [child present $token {*}$args]
        if {[dict get $report status] eq "ready"} { return $report }
        if {[clock milliseconds] >= $deadline} { error "window did not become ready: $report" }
        after 25
    }
}

try {
    set class "MachteldWindowTest[pid]"
    check "unknown window policy fails before launch" [expr {
        [catch {child start -window nonsense -- $fixture} msg opts] &&
        [dict get $opts -errorcode] eq {MACHTELD CHILD badvalue}}]
    lassign [startFixture ordinary $class normal direct] ordinary ordinaryPath ordinaryLaunch
    check "default start leaves Windows' initial show state unspecified" [expr {![dict get $ordinaryLaunch showSet]}]
    check "a child must opt in before it can be presented" [expr {
        [catch {child present $ordinary} msg opts] && [dict get $opts -errorcode] eq {MACHTELD CHILD badvalue}}]
    closeFixture $ordinary
    check "present rejects a released child token" [expr {
        [catch {child present $ordinary} msg opts] && [dict get $opts -errorcode] eq {MACHTELD CHILD nohandle}}]

    lassign [startFixture default $class normal direct -window default] standard ignored launch
    check "explicit default keeps the original show policy and refuses presentation" [expr {
        ![dict get $launch showSet] && [catch {child present $standard} msg opts] &&
        [dict get $opts -errorcode] eq {MACHTELD CHILD badvalue}}]
    closeFixture $standard

    # The decoy has exactly the same class. It belongs to a separate child job.
    lassign [startFixture decoy $class iconic direct -window normal] decoy decoyPath launch
    check "normal launch requests SW_SHOWNORMAL from Windows" [expr {
        [dict get $launch showSet] && [dict get $launch show] == 1}]
    foreach {label value} [list empty {} oversized [string repeat a 256] {embedded NUL} "ABC\u0000XYZ"] {
        check "present rejects a class with $label input" [expr {
            [catch {child present $decoy -class $value} msg opts] &&
            [dict get $opts -errorcode] eq {MACHTELD CHILD badvalue}}]
    }
    signalFixture $decoyPath open-window
    check "unrelated lookalike starts minimized" [dict get [reported $decoyPath opened] iconic]

    lassign [startFixture owner $class hidden handoff -window normal -console none] owner path secondary
    check "the original process handed off to a distinct descendant" [expr {
        [dict get $secondary pid] != [dict get [child info $owner] pid]}]
    set pending [child present $owner -class $class]
    check "no owned window returns pending despite the matching outside window" [expr {
        [dict get $pending status] eq "pending" && ![dict get $pending visible] &&
        ![dict get $pending iconic] && ![dict get $pending cloaked] &&
        ![dict get $pending onScreen] && ![dict get $pending foreground]}]
    signalFixture $path open-window
    check "the descendant's own window starts hidden" [expr {![dict get [reported $path opened] visible]}]
    check "unfiltered presentation leaves hidden windows alone" [expr {
        [dict get [child present $owner] status] eq "pending" && ![dict get [observe $path] visible]}]
    check "class matching requires the whole class name" [expr {
        [dict get [child present $owner -class [string range $class 0 end-1]] status] eq "pending"}]
    set found [ready $owner -class [string toupper $class]]
    check "an exact class match presents the hidden descendant after its launcher exits" [expr {
        [dict get $found visible] && [dict get $found onScreen] &&
        ![dict get $found iconic] && ![dict get $found cloaked] &&
        [string is boolean -strict [dict get $found foreground]]}]
    check "the fixture independently sees the descendant's window" [dict get [observe $path] visible]
    check "present leaves the unrelated matching window minimized" [dict get [observe $decoyPath] iconic]

    signalFixture $path minimize
    check "the attended fixture manually minimizes its window" [dict get [reported $path minimized] iconic]
    for {set i 0} {$i < 3} {incr i} {
        child present $owner -class $class
        after 35
    }
    check "subsequent presentation polls respect the user's minimize" [dict get [observe $path] iconic]
    signalFixture $path finish
    check "window handoff finishes in the original supervised job" [expr {
        [dict get [child wait $owner -timeout 5s] status] eq "ok"}]
    check "a finished attended token can report that its window is gone" [expr {
        [dict get [child present $owner] status] eq "pending"}]
    closeFixture $owner

    set restored [ready $decoy]
    check "the decoy's own token can restore its minimized window" [expr {
        [dict get $restored visible] && ![dict get [observe $decoyPath] iconic]}]
    closeFixture $decoy
    lassign [startFixture misplaced $class offscreen direct -window normal] misplaced misplacedPath ignored
    signalFixture $misplacedPath open-window
    check "fixture places its window outside the desktop" [expr {![dict get [reported $misplacedPath opened] onScreen]}]
    set restored [ready $misplaced]
    set actual [observe $misplacedPath]
    check "presentation without a class repairs an off-screen owned window" [expr {
        [dict get $restored onScreen] && [dict get $actual onScreen] && [dict get $actual visible]}]
} finally {
    foreach token $tokens { catch {child close $token} }
    file delete -force $work
}
puts "ALL $checks ATTENDED WINDOW CHECKS PASSED"
