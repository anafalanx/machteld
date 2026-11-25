package require machteld

proc check {name condition} {
    if {!$condition} { error "FAIL $name" }
    puts "ok   $name"
}

check "the console has no bare clipboard command before Tk" [expr {
    [namespace which -command clipboard] eq {} && [package provide Tk] eq {}}]
check "ownership works without starting Tk" [expr {
    [::machteld::clipboard owned] in {0 1} && [package provide Tk] eq {}}]
foreach args {{} {ow} {clear} {owned extra}} {
    check "usage error for [list $args]" [expr {
        [catch {::machteld::clipboard {*}$args} message options] &&
        [dict get $options -errorcode] eq {MACHTELD CLIPBOARD usage}}]
}

if {![llength $argv]} { exit 0 }

# A different desktop on the same Windows window station shares its clipboard.
# --exercise-clipboard is explicit permission to replace a disposable VM or
# window station's clipboard. CI also verifies that it runs on its hosted VM.
if {$argv eq {--hosted-clipboard}} {
    foreach {key value} {GITHUB_ACTIONS true RUNNER_ENVIRONMENT github-hosted RUNNER_OS Windows} {
        if {![info exists ::env($key)] || $::env($key) ne $value} {
            error "--hosted-clipboard requires a GitHub-hosted Windows runner"
        }
    }
} elseif {[lindex $argv 0] eq "--peer"} {
    if {[llength $argv] != 2 || ![info exists ::env(MACHTELD_CLIPBOARD_PEER)] ||
            $::env(MACHTELD_CLIPBOARD_PEER) ne [lindex $argv 1]} {
        error "the clipboard peer must be started by the test parent"
    }
} elseif {$argv ne {--exercise-clipboard}} {
    error "usage: clipboard_test.tcl ?--exercise-clipboard|--hosted-clipboard?"
}

package require Tk
wm withdraw .
update idletasks
check "Tk owns the global command and the process query remains available" [expr {
    [namespace which -command clipboard] eq "::clipboard" &&
    [::machteld::clipboard owned] in {0 1}}]

# Keep both Tk event loops servicing Windows' requests for delayed clipboard data.
proc waitForMarker {marker {peer {}}} {
    set deadline [expr {[clock milliseconds] + 15000}]
    while {![file isdirectory $marker]} {
        if {$peer ne {} && ![dict get [child info $peer] running]} {
            error "clipboard peer exited before [file tail $marker]: [child wait $peer]"
        }
        if {[clock milliseconds] >= $deadline} { error "timed out waiting for [file tail $marker]" }
        after 10 {set ::tick 1}
        vwait ::tick
    }
}

set first "Résumé 雪 🚆"
set second "Δεύτερο 水 🐈"
if {[lindex $argv 0] eq "--peer"} {
    set work [lindex $argv 1]
    check "another process owns the clipboard before takeover" [expr {![::machteld::clipboard owned]}]
    check "the query preserves the first Unicode value" [expr {[::clipboard get] eq $first}]
    ::clipboard clear
    ::clipboard append -- $second
    update
    check "peer owns the clipboard after writing" [::machteld::clipboard owned]
    file mkdir [file join $work ready]
    waitForMarker [file join $work checked]
    destroy .
    exit 0
}

set work [file tempdir]
set peer {}
try {
    ::clipboard clear
    ::clipboard append -- $first
    update
    check "this process owns the clipboard after writing" [::machteld::clipboard owned]
    set other [interp create]
    try {
        interp eval $other {load {} machteldclipboard}
        check "ownership extends across interpreters in this process" \
                [interp eval $other {::machteld::clipboard owned}]
    } finally { interp delete $other }

    set peer [child start -timeout 35s -env [dict create MACHTELD_CLIPBOARD_PEER $work] -- \
            [info nameofexecutable] [file normalize [info script]] --peer $work]
    waitForMarker [file join $work ready] $peer
    check "peer takeover ends this process's ownership" [expr {![::machteld::clipboard owned]}]
    check "the query preserves the peer's Unicode value" [expr {[::clipboard get] eq $second}]
    file mkdir [file join $work checked]
    set report [child wait $peer -timeout 10s]
    if {[dict get $report status] ne "ok" || [dict get $report exit] != 0} {
        error "clipboard peer failed: $report"
    }
} finally {
    if {$peer ne {}} { child close $peer }
    file delete -force -- $work
    destroy .
}
