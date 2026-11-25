package require machteld

proc check {label expression} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL $label"}
    puts "ok   $label"
}
proc code {script} {
    if {[catch {uplevel 1 $script} message options]} {return [dict get $options -errorcode]}
    return {}
}
proc rowsFor {class} {
    set result {}
    foreach row [desktop windows] {
        if {[dict get $row class] eq $class} {dict set result [dict get $row pid] $row}
    }
    return $result
}
proc waitFor {file} {
    set end [expr {[clock milliseconds] + 10000}]
    while {![file isfile $file] && [clock milliseconds] < $end} {after 20}
    if {![file isfile $file]} {error "fixture did not produce [file tail $file]"}
}

proc windowsTest {fixture work} {
    set fixture [file normalize $fixture]
    set class "MachteldDesktop[pid]"
    set tokens {}
    try {
        set dir [file join $work {documents with spaces}]
        file mkdir $dir
        set link [file join $dir {launch fixture & verify.lnk}]
        exec $fixture --make-document [file nativename $link] [file nativename $dir]
        desktop open $link
        waitFor [file join $dir shell-opened]
        check "Windows opens a local document with spaces through its existing association" {
            [file size [file join $dir shell-opened]] > 0}
        foreach name {first second} {
            set dir [file join $work $name]
            file mkdir $dir
            close [open [file join $dir open-window] {WRONLY CREAT EXCL}]
            lappend tokens [child start -dir $dir -window visible -- $fixture direct $class normal]
            waitFor [file join $dir opened]
        }
        set rows [rowsFor $class]
        check "two different processes with duplicate window titles are listed" {
            [dict size $rows] == 2 && [llength [lsort -unique [lmap key [dict keys $rows] {
                dict get $rows $key title}]]] == 1}
        lassign [lmap token $tokens {dict get [child info $token] pid}] first second
        set a [dict get $rows $first token]
        set b [dict get $rows $second token]
        check "selection uses distinct window identities" {$a ne {} && $b ne {} && $a ne $b}
        for {set i 0} {$i < 25} {incr i} {
            set seen [rowsFor $class]
            if {[dict get $seen $first token] ne $a || [dict get $seen $second token] ne $b} {
                error "refresh changed a live selection"
            }
        }
        interp create other
        try {
            interp eval other {load {} machtelddesktop}
            interp eval other {::machteld::desktop windows}
            check "separate interpreter refuses this selection" {
                [code [list interp eval other [list ::machteld::desktop activate $a]]] eq {MACHTELD DESKTOP notfound}}
        } finally {interp delete other}
        set requested [desktop activate $b]
        check "activation reports what Windows accepted and observed" {
            [lsort [dict keys $requested]] eq {foreground requested} &&
            [string is boolean -strict [dict get $requested foreground]] &&
            [string is boolean -strict [dict get $requested requested]]}
        if {[dict get $requested foreground]} {
            set observed [rowsFor $class]
            check "the selected duplicate received the foreground" {
                [dict get $observed $second foreground] && ![dict get $observed $first foreground]}
        }
        # The fixture destroys and recreates a window in the same process
        # and on the same GUI thread with the same class and caption.
        close [open [file join $work second recreate] {WRONLY CREAT EXCL}]
        waitFor [file join $work second recreated]
        check "a replacement with identical identifying text expires the original token" {
            [code [list desktop activate $b]] eq {MACHTELD DESKTOP notfound}}
        set refreshed [rowsFor $class]
        check "the replacement gets its own selection and preserves the other one" {
            [dict get $refreshed $second token] ni [list {} $a $b] && [dict get $refreshed $first token] eq $a}
        child shutdown [lindex $tokens 0]
        child wait [lindex $tokens 0] -timeout 5s
        check "a window closed after listing fails before acting" {
            [code [list desktop activate $a]] eq {MACHTELD DESKTOP notfound}}
        check "closing one duplicate preserves its sibling" {[dict keys [rowsFor $class]] eq [list $second]}
    } finally {
        foreach token $tokens {catch {child close $token}}
    }
}

set work [file tempdir]
try {
    set absent [file join $work {missing file.pdf}]
    check "missing document" {[code [list desktop open $absent]] eq {MACHTELD DESKTOP notfound}}
    check "directory is refused" {[code [list desktop open $work]] eq {MACHTELD DESKTOP badvalue}}
    set unknown [file join $work "unassigned [pid].machteld-[binary encode hex [hash random 16]]"]
    close [open $unknown {WRONLY CREAT EXCL}]
    check "an unassociated local document reports noassociation" {
        [code [list desktop open $unknown]] eq {MACHTELD DESKTOP noassociation}}
    check "mounted archive member is refused" {
        [code {desktop open [file join [info library] init.tcl]}] eq {MACHTELD DESKTOP badvalue}}
    check "embedded NUL is refused" {[code [list desktop open "$absent\u0000suffix"]] eq {MACHTELD DESKTOP badvalue}}
    check "an empty selection cannot activate a window" {[code {desktop activate {}}] eq {MACHTELD DESKTOP notfound}}
    check "operation and arity are exact" {
        [code {desktop wind}] eq {MACHTELD DESKTOP usage} && [code {desktop windows unused}] eq {MACHTELD DESKTOP usage}}
    if {[llength $argv] == 2 && [lindex $argv 0] eq "--windows"} {
        windowsTest [lindex $argv 1] $work
    } elseif {[llength $argv]} {error "usage: desktop_test.tcl ?--windows fixture?"}
} finally {file delete -force -- $work}
puts "Desktop checks passed."
