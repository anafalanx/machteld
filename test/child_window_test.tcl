package require machteld

# The release runner sets this identifier on its never-switched desktop.
# The foreground and monitor checks below require the attended lane.
if {[llength $argv] != 1 && ([llength $argv] != 2 || [lindex $argv 1] ne "--startup-only")} {
    error "usage: child_window_test.tcl window_fixture.exe ?--startup-only?"
}
set privateOnly [expr {[llength $argv] == 2 || ([info exists env(MACHTELD_TEST_EXPECT_DESKTOP)] &&
    [string match MachteldDesktopTest-* $env(MACHTELD_TEST_EXPECT_DESKTOP)])}]
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

    lassign [startFixture other $class startup direct -window hidden] other otherPath ignored
    signalFixture $otherPath open-window
    reported $otherPath opened
    foreach {policy show flag} {visible 1 1 hidden 0 0} {
        lassign [startFixture $policy $class startup direct -console none -window $policy] token path launch
        check "$policy startup passes the initial show state to the child" [expr {
            [dict get $launch showSet] && [dict get $launch show] == $show}]
        signalFixture $path open-window
        check "$policy startup affects the fixture's first window" [expr {
            [dict get [reported $path opened] visible] == $flag}]
        if {$flag} {
            check "visible opts into presentation" [expr {![catch {child present $token -class $class}]}]
        } else {
            check "hidden refuses presentation" [expr {
                [catch {child present $token} msg opts] && [dict get $opts -errorcode] eq {MACHTELD CHILD badvalue}}]
        }
        set requested [child shutdown $token]
        check "shutdown posts to the $policy fixture window ($requested)" [expr {
            [dict get $requested windows] >= 1 && ![dict get $requested stdin]}]
        set result [child wait $token -timeout 5s]
        check "$policy startup preserves supervised exit reporting" [expr {
            [dict get $result status] eq "ok" && [dict get $result pid] == [dict get $launch pid]}]
        closeFixture $token
    }
    check "a matching window in another job survives both shutdowns" [expr {
        [dict get [child info $other] running] && ![dict get [observe $otherPath] visible]}]
    closeFixture $other

    package require Tk
    set panel .machteldChildTest
    toplevel $panel
    label $panel.progress -text waiting
    pack $panel.progress
    update
    check "Tk mapped the test window" [winfo ismapped $panel]
    set delivered 0
    proc finished {token result} {
        incr ::delivered
        set ::completed [list $token [dict get $result status]]
        child close $token
    }
    try {
        lassign [startFixture responsive $class startup direct -window hidden -onexit finished] child path ignored
        signalFixture $path open-window
        reported $path opened
        bind $panel <<ChildTest>> [list $panel.progress configure -text responsive]
        after 0 [list event generate $panel <<ChildTest>> -when tail]
        set finishTimer [after 100 [list child shutdown $child]]
        set guard [after 10000 {set ::completed expired}]
        try { vwait ::completed } finally {after cancel $finishTimer; after cancel $guard}
        update
        check "Tk handles a widget event while a supervised job is running" [expr {
            [winfo ismapped $panel] && [$panel.progress cget -text] eq "responsive"}]
        check "one callback receives the completed token and can release it" [expr {
            $delivered == 1 && $completed eq [list $child ok] && $child ni [child list]}]
    } finally {
        destroy .
    }

    if {$privateOnly} { puts "ALL $checks STARTUP WINDOW CHECKS PASSED"; return }

    # The decoy has exactly the same class. It belongs to a separate child job.
    lassign [startFixture decoy $class iconic direct -window normal] decoy decoyPath launch
    check "normal launch requests SW_SHOWNORMAL from Windows" [expr {
        [dict get $launch showSet] && [dict get $launch show] == 1}]
    foreach {label value} [list empty {} oversized [string repeat a 256] \
            {256 UTF-16 units} [string repeat "📦" 128] {embedded NUL} "ABC\u0000XYZ"] {
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
    closeFixture $misplaced

    lassign [startFixture tiny $class tiny direct -window normal] tiny tinyPath ignored
    signalFixture $tinyPath open-window
    set small [reported $tinyPath opened]
    check "fixture creates a four-pixel top-level window" [expr {
        [dict get $small width] == 4 && [dict get $small height] == 4}]
    ready $tiny -class $class
    set repaired [observe $tinyPath]
    check "presentation gives a tiny window usable dimensions" [expr {
        [dict get $repaired width] >= 32 && [dict get $repaired height] >= 24 &&
        [dict get $repaired onScreen]}]
} finally {
    foreach token $tokens { catch {child close $token} }
    file delete -force $work
}
puts "ALL $checks ATTENDED WINDOW CHECKS PASSED"
