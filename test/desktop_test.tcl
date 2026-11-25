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

proc visibleIcon {photo} {
    for {set y 0} {$y < [image height $photo]} {incr y} {
        for {set x 0} {$x < [image width $photo]} {incr x} {
            if {![$photo transparency get $x $y]} {return 1}
        }
    }
    return 0
}

proc dropTests {probe} {
    set paths [list [file nativename {C:/files with spaces/one.txt}] \
                    [file nativename {C:/éß/文件 🚉 [literal];$.txt}]]
    frame .incoming
    frame .other
    set ::delivered {}
    set prefix [list lappend ::delivered]
    check "widget drop registration starts empty" {[desktop drop .incoming] eq {}}
    desktop drop .incoming $prefix
    check "each widget retains its own command prefix" {[desktop drop .incoming] eq $prefix && [desktop drop .other] eq {}}
    fixtureCatalog drop .incoming $paths
    check "the drop callback never runs inside native window dispatch" {$::delivered eq {}}
    update
    check "multiple Unicode file names arrive in order as one Tcl list" {$::delivered eq [list $paths]}
    set ::delivered {}
    fixtureCatalog drop .incoming $paths
    desktop drop .incoming [list lappend ::delivered replaced]
    update
    check "replacing a registration cancels queued drops" {$::delivered eq {}}
    fixtureCatalog drop .incoming $paths
    update
    check "a replacement receives only subsequent drops" {$::delivered eq [list replaced $paths]}
    set ::delivered {}
    fixtureCatalog drop .incoming $paths
    desktop drop .incoming {}
    update
    check "unregistering cancels pending drops and removes OS acceptance" {$::delivered eq {} &&
        [desktop drop .incoming] eq {} && [catch {fixtureCatalog drop .incoming $paths}]}
    desktop drop .incoming $prefix
    fixtureCatalog drop .incoming $paths
    destroy .incoming
    frame .incoming
    update
    check "destroyed and recreated widgets do not inherit pending drops" {$::delivered eq {} && [desktop drop .incoming] eq {}}
    proc ::destroyAfterDrop {paths} {set ::delivered $paths; destroy .incoming}
    desktop drop .incoming ::destroyAfterDrop
    fixtureCatalog drop .incoming $paths
    update
    check "the callback can destroy its own target" {$::delivered eq $paths && ![winfo exists .incoming]}
    rename ::destroyAfterDrop {}
    check "unknown widgets and malformed command prefixes get typed errors" {
        [code {desktop drop .absent abc}] eq {MACHTELD DESKTOP notfound} &&
        [code [list desktop drop .other \{]] eq {MACHTELD DESKTOP badvalue}}
    set other [interp create]
    set ::lateDrops {}
    try {
        interp eval $other [list set ::tk_library $::tk_library]
        interp eval $other {load {} Tk; wm withdraw .; load {} machtelddesktop}
        load $probe Desktopcatalog $other
        interp alias $other signalUnexpectedDrop {} lappend ::lateDrops
        interp eval $other [list set paths $paths]
        interp eval $other {
            frame .child
            ::machteld::desktop drop .child signalUnexpectedDrop
            fixtureCatalog drop .child $paths
        }
    } finally {interp delete $other}
    update
    check "interpreter teardown retires a pending native drop" {$::lateDrops eq {} && [desktop drop .other] eq {}}
    destroy .other
}

proc catalogTests {fixture probe work} {
    package require Tk
    wm withdraw .
    set photo [image create photo]
    try {
        set rows [desktop apps]
        set byKind {}
        foreach row $rows {dict lappend byKind [dict get $row kind] [dict get $row target]}
        foreach kind {shortcut store} {
            if {![dict exists $byKind $kind]} {
                puts "No $kind entries are installed in this Windows profile."
                continue
            }
            set found 0
            foreach token [dict get $byKind $kind] {
                if {![catch {desktop icon $token $photo 24}] && [visibleIcon $photo]} {set found 1; break}
            }
            check "an installed $kind supplies visible pixels to a Tk photo" {$found}
        }
        load $probe Desktopcatalog
        dropTests $probe
        set menu [file join $work isolated-menu]
        set place [file join $work {launch here}]
        file mkdir [file join $menu nested] $place
        set shortcut [file join $menu nested {test application.lnk}]
        exec $fixture --make-document [file nativename $shortcut] [file nativename $place]
        set rows [fixtureCatalog scan $menu]
        check "a closed installed shortcut is discovered by name" {
            [llength $rows] == 1 && [dict get [lindex $rows 0] kind] eq "shortcut" &&
            [dict get [lindex $rows 0] name] eq "test application"}
        set token [dict get [lindex $rows 0] target]
        check "unchanged catalog entries preserve their selections" {
            [dict get [lindex [fixtureCatalog scan $menu] 0] target] eq $token}
        check "the selected shortcut supplies an icon" {[fixtureCatalog icon $token $photo 32] eq $photo && [visibleIcon $photo]}
        fixtureCatalog launch $token
        waitFor [file join $place shell-opened]
        check "launch preserves the selected shortcut arguments and working directory" {[file size [file join $place shell-opened]] > 0}
        file rename $shortcut $shortcut.previous
        exec $fixture --make-document [file nativename $shortcut] [file nativename $place]
        check "replaced shortcut is refused before launch" {[code [list fixtureCatalog launch $token]] eq {MACHTELD DESKTOP notfound}}
        set next [dict get [lindex [fixtureCatalog scan $menu] 0] target]
        check "refreshed shortcut receives a new identity" {$next ne $token}
        file delete $shortcut
        check "deleted shortcut is refused before icon extraction" {
            [code [list fixtureCatalog icon $next $photo 32]] eq {MACHTELD DESKTOP notfound}}
        check "removed shortcuts leave the next catalog" {![llength [fixtureCatalog scan $menu]]}
    } finally {image delete $photo; destroy .}
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
    set targets {}
    set valid 1
    foreach row [desktop apps] {
        if {[lsort [dict keys $row]] ne {kind name source target} || [dict get $row kind] ni {shortcut store} ||
                [dict get $row name] eq {} || [dict get $row source] eq {} || [dict exists $targets [dict get $row target]]} {set valid 0}
        dict set targets [dict get $row target] 1
    }
    check "installed applications have distinct targets and complete records" {$valid}
    check "unknown application targets are refused" {[code {desktop launch invalid}] eq {MACHTELD DESKTOP notfound}}
    check "invalid icon size is refused before shell access" {[code {desktop icon invalid photo 0}] eq {MACHTELD DESKTOP badvalue}}
    if {[llength $argv] in {2 3} && [lindex $argv 0] eq "--windows"} {
        windowsTest [lindex $argv 1] $work
        if {[llength $argv] == 3} {catalogTests [file normalize [lindex $argv 1]] [file normalize [lindex $argv 2]] $work}
    } elseif {[llength $argv]} {error "usage: desktop_test.tcl ?--windows fixture ?catalog-probe??"}
} finally {file delete -force -- $work}
puts "Desktop checks passed."
