package require machteld

if {[llength $argv] == 2 && [lindex $argv 0] eq "--resume"} {
    set resumed [browser attach -profile [lindex $argv 1] -timeout 8s]
    browser release $resumed
    puts resumed
    exit 0
}
if {[llength $argv] == 3 && [lindex $argv 0] eq "--launch"} {
    browser launch -profile [lindex $argv 2] -executable [lindex $argv 1] -headless true -timeout 25s
    puts started
    exit 0
}
set script [file normalize [info script]]

proc check {name result} {
    if {!$result} {error "FAIL $name"}
    puts "ok   $name"
}
proc refused {script code} {
    expr {[catch {uplevel 1 $script} message options] &&
        [dict get $options -errorcode] eq [list MACHTELD BROWSER $code]}
}

# Preserve the failed check and its error code even when releasing its resources
# also fails. Cleanup errors still fail an otherwise successful test.
proc withCleanup {body cleanup} {
    set code [catch {uplevel 1 $body} message options]
    if {[catch {uplevel 1 $cleanup} cleanupMessage cleanupOptions]} {
        if {!$code} {return -options $cleanupOptions $cleanupMessage}
        dict append options -errorinfo "\n    additional cleanup error: [dict get $cleanupOptions -errorinfo]"
    }
    return -options $options $message
}

proc closeTestBrowser {session profile} {
    if {$session ne {}} {
        if {![catch {browser close $session}]} return
        catch {browser release $session}
    }
    # The test may have released its token, or its launch host may have exited
    # before handing it back. Use only this profile's verified ownership record.
    lassign [::machteld::browser::Profile $profile 0] path owner
    set receipt [::machteld::browser::Receipt [dict create profile $path owner $owner]]
    if {$receipt eq {} || ![::machteld::BrowserPeer [dict get $receipt pid] [dict get $receipt stamp]]} return
    set attached [browser attach -profile $path -timeout 8s]
    try {browser close $attached} on error {message options} {
        catch {browser release $attached}
        return -options $options $message
    }
}

# Serve only static test pages from this process. A request to /slow receives
# no response until the client cancels, making timeout and cancellation exact.
proc acceptPage {chan ip port} {
    fconfigure $chan -blocking 0 -translation binary -buffering none
    set ::requests($chan) {}
    fileevent $chan readable [list readPage $chan]
}
proc finishPage {chan} {
    catch {close $chan}
    unset -nocomplain ::requests($chan)
}
proc readPage {chan} {
    if {[catch {read $chan 8192} body] || [eof $chan]} {finishPage $chan; return}
    append ::requests($chan) $body
    if {[string length $::requests($chan)] > 32768} {finishPage $chan; return}
    if {[string first "\r\n\r\n" $::requests($chan)] < 0} return
    if {[regexp {^GET /slow } $::requests($chan)]} {set ::receivedSlow 1; return}
    set html {<!doctype html><title>Machteld synthetic browser test</title><p>Ready</p>}
    if {![catch {puts -nonewline $chan "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: [string length $html]\r\nConnection: close\r\n\r\n$html"}]} {flush $chan}
    finishPage $chan
}

proc exercise {exe profile origin} {
    set name [file tail $exe]
    set session [browser launch -executable $exe -profile $profile -headless true -timeout 25s]
    withCleanup {
        check "$name refuses a simultaneous second controller" [refused {browser attach -profile $profile} busy]
        set copy [file join [file dirname $profile] "$name-copy"]
        file mkdir $copy
        file copy [file join $profile .machteld-browser-owner] $copy
        check "$name refuses a copied ownership marker" [refused {browser attach -profile $copy} ownership]
        # The public API accepts aliases, then verifies ownership records in
        # the normalized profile directory. Use that same spelling for this
        # test's direct read and the stale-receipt fixture below.
        set receiptPath [file join [file normalize $profile] .machteld-browser-session]
        set receipt [::machteld::browser::ReadSmall $receiptPath]
        set port [lindex [fconfigure $::server -sockname] end]
        check "$name refuses a listener belonging to the test server" [refused {
            ::machteld::BrowserPeer [dict get $receipt pid] [dict get $receipt stamp] $port
        } ownership]
        check "$name refuses unexpected URL schemes" [refused {browser navigate $session file:///test} badvalue]
        set nav [browser navigate $session $origin/done]
        set page [browser wait $session $nav -timeout 10s]
        check "$name reports load of the selected document" [expr {[dict get $page status] eq "ready" && [dict get $page url] eq "$origin/done"}]
        set fragment [browser navigate $session $origin/done#again]
        check "$name recognizes same-document navigation" [expr {[dict get [browser wait $session $fragment -timeout 5s] status] eq "ready"}]
        check "$name expires the previous navigation token" [refused {browser wait $session $nav} notfound]
        set ::receivedSlow 0
        set slow [browser navigate $session $origin/slow]
        check "$name only admits one pending navigation" [refused {browser navigate $session $origin/done} busy]
        set result [browser wait $session $slow -timeout 200ms]
        check "$name timeout leaves navigation pending" [expr {[dict get $result status] eq "timeout"}]
        set timer [after 150 [list browser cancel $session $slow]]
        try {set stopped [browser wait $session $slow -timeout 4s]} finally {after cancel $timer}
        check "$name Tk timers and cancellation run during a wait" [expr {$::receivedSlow && [dict get $stopped status] eq "cancelled"}]
        browser release $session
        set released $session
        set session {}
        check "$name expires the released handle" [refused {browser navigate $released $origin/done} closed]
        set changed $receipt
        dict incr changed stamp
        publish bytes $receiptPath [encoding convertto utf-8 $changed]
        withCleanup {
            check "$name refuses a stale process creation time" [refused {browser attach -profile $profile} closed]
        } {publish bytes $receiptPath [encoding convertto utf-8 $receipt]}
        set resumed [run -timeout 12s -- [info nameofexecutable] $::script --resume $profile]
        if {[dict get $resumed status] ne "ok" || [dict get $resumed exit] != 0 ||
                [string trim [dict get $resumed out]] ne "resumed"} {
            error "FAIL $name reacquires the profile from another host process: $resumed"
        }
        puts "ok   $name reacquires the profile from another host process"
        check "$name prevents launching over a live detached session" [refused {browser launch -profile $profile -executable $exe} busy]
        set session [browser attach -profile $profile -timeout 8s]
        set next [browser navigate $session $origin/resumed]
        check "$name reattaches to the same browser tab" [expr {[dict get [browser wait $session $next -timeout 5s] status] eq "ready"}]
        browser close $session
        set session {}
        check "$name closes the exact recorded process" [refused {browser attach -profile $profile} closed]
        # Ordinary host termination drops the controller connection and lock.
        set started [exec [info nameofexecutable] $::script --launch $exe $profile]
        set session [browser attach -profile $profile -timeout 8s]
        check "$name survives the launch host exiting and reuses its owned profile" [expr {$started eq "started"}]
        browser release $session
        set session {}
    } {closeTestBrowser $session $profile}
    check "$name cleanup closes a detached test browser" [refused {browser attach -profile $profile} closed]
}

set scratch [file tempdir]
withCleanup {
    set failed [catch {withCleanup {
        error "primary check failed" {} {TEST PRIMARY}
    } {error "secondary cleanup failed"}} message options]
    check {cleanup preserves the original failure and reports both errors} [expr {$failed == 1 &&
        $message eq "primary check failed" && [dict get $options -errorcode] eq {TEST PRIMARY} &&
        [string first {additional cleanup error: secondary cleanup failed} [dict get $options -errorinfo]] >= 0}]
    set unowned [file join $scratch unowned]
    file mkdir $unowned
    close [open [file join $unowned sentinel.txt] w]
    check {an unmarked directory cannot be attached} [refused {browser attach -profile $unowned} ownership]
    check {ownership rejection leaves the existing files untouched} [expr {[::machteld::_children $unowned] eq [list [file join $unowned sentinel.txt]]}]
    check {only existing owned sessions can be attached} [refused {browser attach -profile [file join $scratch missing]} notfound]
    check {unknown option has a browser usage error} [refused {browser attach -endpoint 123} usage]
    check {unknown subcommand has a browser usage error} [refused {browser unknown} usage]
    check {durations include units} [refused {browser attach -profile $unowned -timeout 10} badvalue]
    check {remote and device namespaces are rejected before access} [refused {browser attach -profile {//example.invalid/test}} badvalue]
    check {an unknown session cannot be closed} [refused {browser close unknown} closed]
    if {[info exists ::env(MACHTELD_TEST_EXPECT_DESKTOP)]} {
        set executables {}
        foreach {var subpath} {
            ProgramFiles(x86) {Microsoft Edge Application msedge.exe}
            ProgramFiles {Microsoft Edge Application msedge.exe}
            ProgramFiles {Google Chrome Application chrome.exe}
            LOCALAPPDATA {Google Chrome Application chrome.exe}
        } {
            if {[info exists ::env($var)] && [file isfile [set exe [file join $::env($var) {*}$subpath]]]} {
                lappend executables [file normalize $exe]
            }
        }
        if {![llength $executables]} {error "browser integration requires an installed Edge or Chromium browser"}
        set server [socket -server acceptPage -myaddr 127.0.0.1 0]
        set origin "http://127.0.0.1:[lindex [fconfigure $server -sockname] end]"
        withCleanup {
            foreach exe [lsort -unique $executables] {
                # Exercise a path alias even on volumes without 8.3 names.
                set profile [file join $scratch .. [file tail $scratch] [file tail $exe]]
                exercise $exe $profile $origin
            }
        } {
            close $server
            foreach chan [array names ::requests] {finishPage $chan}
        }
    }
} {
    # Chromium can briefly keep a profile database mapped after its recorded
    # browser process exits. Wait for Windows to release this test's directory.
    set deadline [expr {[clock milliseconds] + 5000}]
    while {[catch {file delete -force -- $scratch} message options]} {
        if {[lrange [dict get $options -errorcode] 0 1] ne {POSIX EACCES}
                || [clock milliseconds] >= $deadline} {
            return -options $options $message
        }
        after 50
    }
}
