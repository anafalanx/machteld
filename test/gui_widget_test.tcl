package require machteld
package require Tk

# Real Tk widgets and their bindings. Run separately from the non-GUI lane;
# this creates a short-lived visible window. Clipboard delivery is intercepted
# inside the example namespace: do not destroy a user's image/rich clipboard
# while pretending that saving plain text preserves every Windows format.
set HERE [file dirname [file normalize [info script]]]
set EXAMPLE [file join $HERE .. examples project-inspector]
source [file join $EXAMPLE model.tcl]
source [file join $EXAMPLE view.tcl]
set ::inspector::testClipboard {}
set ::inspector::testClipboardCalls {}
proc ::inspector::clipboard {subcommand args} {
    lappend ::inspector::testClipboardCalls $subcommand
    switch -exact -- $subcommand {
        clear {
            if {[llength $args]} { error {unexpected clipboard clear arguments} }
            set ::inspector::testClipboard {}
        }
        append {
            if {[llength $args] != 1} { error {unexpected clipboard append arguments} }
            append ::inspector::testClipboard [lindex $args 0]
        }
        default { error "unexpected clipboard operation: $subcommand" }
    }
    return
}
set TEMP_ROOT [file normalize $env(TEMP)]
set WORK_ROOT [file normalize [file join $TEMP_ROOT machteld-inspector-widget-[pid]-[clock clicks]]]
if {[file dirname $WORK_ROOT] ne $TEMP_ROOT || [file exists $WORK_ROOT]} { error "unsafe test workspace" }
set WORK [file join $WORK_ROOT {space 雪}]
file mkdir $WORK
set ch [open [file join $WORK {café 雪.txt}] w]
puts $ch widget-fixture; close $ch
set fails 0; set checks 0; set ticks 0; set bgerrors {}
proc bgerror {message} { lappend ::bgerrors $message }
proc check {name condition} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc pause {ms} { set ::awake 0; after $ms {set ::awake 1}; vwait ::awake }
proc settle {} {
    set deadline [expr {[clock milliseconds]+12000}]
    while {[dict get [$::inspector::job snapshot] phase] eq "running" && [clock milliseconds] < $deadline} { pause 5 }
    if {[dict get [$::inspector::job snapshot] phase] eq "running"} { error "widget test timed out" }
    pause 35
}
proc tick {} { incr ::ticks; set ::tickTimer [after 5 tick] }
set baseline [child list]
set scale [tk scaling]
tick
try {
    ::inspector::open $WORK [file join $EXAMPLE inspect.tcl]
    set mappingDeadline [expr {[clock milliseconds]+2000}]
    while {![winfo ismapped .path.entry] && [clock milliseconds] < $mappingDeadline} { pause 10 }
    focus -force .path.entry
    pause 20
    check "initial keyboard target exists" [expr {[focus] eq ".path.entry"}]
    event generate .path.entry <Control-Return>
    settle
    check "keyboard starts successful inspection" [expr {[dict get [$::inspector::job snapshot] phase] eq "done"}]
    set table .panes.files.table
    check "real tree contains result" [expr {[llength [$table children {}]] == 1}]
    $table selection set row0
    event generate $table <<TreeviewSelect>>
    check "selection displays Unicode detail" [string match {*café 雪.txt*} [.panes.detail.text get 1.0 end]]
    check "detail is read-only and focusable" [expr {
        [.panes.detail.text cget -state] eq "disabled" && [.panes.detail.text cget -takefocus] == 1}]
    focus -force .toolbar.inspect
    event generate .toolbar.inspect <Tab>
    pause 10
    check "Tab follows visual order and skips disabled Cancel" [expr {[focus] eq ".toolbar.copy"}]
    event generate [focus] <Control-l>
    check "Ctrl+L focuses directory" [expr {[focus] eq ".path.entry"}]
    .toolbar.slow invoke
    pause 35
    check "buttons expose running state" [expr {
        [.toolbar.inspect cget -state] eq "disabled" && [.toolbar.cancel cget -state] eq "normal"}]
    # Shortcut remains bound while the button is disabled; model rejects it.
    set token [child list]
    event generate .path.entry <Control-Return>
    check "repeated shortcut cannot duplicate work" [expr {[child list] eq $token}]
    event generate .path.entry <Escape>
    settle
    check "Escape cancels" [expr {[dict get [$::inspector::job snapshot] phase] eq "canceled"}]
    .toolbar.fail invoke
    settle
    check "error visible in actual text widget" [string match {*Deliberate demonstration failure*} [.panes.detail.text get 1.0 end]]
    .toolbar.copy invoke
    check "Copy button supplies error diagnostics to clipboard adapter" [expr {
        $::inspector::testClipboardCalls eq {clear append} &&
        [string match {*Deliberate demonstration failure*} $::inspector::testClipboard]}]
    puts "SKIP operating-system clipboard transfer: all existing user clipboard formats left untouched"
    .toolbar.inspect invoke
    settle
    check "GUI recovers after error" [expr {[dict get [$::inspector::job snapshot] phase] eq "done"}]
    set before $ticks
    .toolbar.noisy invoke
    settle
    check "widgets remain event-responsive under output" [expr {$ticks-$before > 5}]
    check "rendered diagnostic tail remains bounded" [expr {[string length [.panes.detail.text get 1.0 end]] < 8500}]
    foreach scaling {1.0 1.5 2.0} {
        tk scaling $scaling
        # Reconfigure point-sized named fonts so this exercises changed widget
        # requisitions, not merely a changed global scaling variable.
        foreach named [font names] {
            font configure $named -size [font actual $named -size]
        }
        foreach geometry {720x480 1120x800} {
            wm geometry . $geometry
            pause 35
            check "tree and detail laid out: scale $scaling at $geometry" [expr {
                [winfo width $table] >= 200 && [winfo height $table] > 50 &&
                [winfo width .panes.detail.text] >= 200 && [winfo height .panes.detail.text] > 30}]
            check "actions fit: scale $scaling at $geometry" [expr {
                [winfo x .toolbar.copy]+[winfo width .toolbar.copy] <= [winfo width .toolbar]}]
        }
    }
    tk scaling $scale
    .toolbar.slow invoke
    set owned [child list]
    eval [wm protocol . WM_DELETE_WINDOW]
    check "WM close removes active children" [expr {$owned ne $baseline && [child list] eq $baseline}]
    check "WM close destroys widgets and marks completion" [expr {[catch {winfo exists .}] && $::inspector::closed}]
    pause 50
    check "no late callbacks after close" [expr {$bgerrors eq {}}]
} finally {
    after cancel $tickTimer
    if {![catch {winfo exists .} exists] && $exists} {
        tk scaling $scale
        ::inspector::close
    }
    if {[file dirname [file normalize $WORK_ROOT]] ne $TEMP_ROOT} { error "refusing escaped test cleanup" }
    file delete -force $WORK_ROOT
}
puts "$checks GUI-widget checks, $fails failures"
exit [expr {$fails != 0}]
