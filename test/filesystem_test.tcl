# Hostile Windows filesystem regressions for dirs, links, and canon.

package require machteld

set ROOT [file join [string map {\\ /} $env(TEMP)] machteld-fs-test-[pid]]
set OUTSIDE ${ROOT}-outside
set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} message options] == 0} { return {} }
    return [dict get $options -errorcode]
}
proc write_file {path bytes} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel $bytes
    close $channel
}
proc wipe {path} {
    if {![file exists $path]} return
    foreach child [glob -nocomplain -directory $path * .*] {
        if {[file tail $child] in {. ..}} continue
        if {[file isdirectory $child] && ![catch {file link $child}]} {
            catch {exec cmd /c rmdir [file nativename $child]}
        }
    }
    catch {exec cmd /c icacls [file nativename $path] /reset /t /q /c}
    catch {exec cmd /c rmdir /s /q [file nativename $path]}
}

wipe $ROOT
wipe $OUTSIDE
try {
    file mkdir $ROOT
    file mkdir [file join $OUTSIDE outside-child]
    foreach directory {.dot hidden {has space} {quote'n[brace]} target/child locked/child deep} {
        file mkdir [file join $ROOT $directory]
    }
    catch {exec cmd /c attrib +h +s [file nativename [file join $ROOT hidden]]}
    write_file [file join $ROOT ordinary.txt] data

    set deep [file join $ROOT deep]
    for {set index 0} {$index < 16} {incr index} {
        set deep [file join $deep d]
        file mkdir $deep
    }

    set names [list AB Zz _z aa b1 \u00e9 \u65e5\u672c\u8a9e \ue000 \ue001 \U0001F600]
    file mkdir [file join $ROOT order]
    foreach name $names { file mkdir [file join $ROOT order $name] }

    set junctions {}
    foreach {name target} [list junction [file join $ROOT target] outside $OUTSIDE loop $ROOT] {
        set path [file join $ROOT $name]
        if {![catch {exec cmd /c mklink /J [file nativename $path] [file nativename $target]}]} {
            lappend junctions $name
        }
    }
    check "junction fixture is available" [expr {[llength $junctions] == 3}]

    set denied [expr {![catch {exec cmd /c icacls [file nativename [file join $ROOT locked]] \
        /deny "$env(USERNAME):(OI)(CI)(RD)"}] &&
        [catch {glob -nocomplain -directory [file join $ROOT locked] *}]}]

    set result [dirs $ROOT]
    set paths [dict get $result paths]
    check "dirs includes its normalized root first" [expr {
        [lindex $paths 0] eq $ROOT && [dict get $result root] eq $ROOT}]
    check "dirs includes hidden directories" [expr {[file join $ROOT hidden] in $paths}]
    check "dirs includes dot directories" [expr {[file join $ROOT .dot] in $paths}]
    check "dirs preserves spaces and Tcl metacharacters" [expr {
        [file join $ROOT {has space}] in $paths && [file join $ROOT {quote'n[brace]}] in $paths}]
    check "dirs excludes ordinary files" [expr {[file join $ROOT ordinary.txt] ni $paths}]
    foreach name $names {
        check "dirs preserves Unicode name [binary encode hex [encoding convertto utf-8 $name]]" \
            [expr {[file join $ROOT order $name] in $paths}]
    }
    check "repeated basenames do not collapse" [expr {
        [llength [lsearch -all -glob $paths [file join $ROOT deep]/*]] == 16}]
    check "deep traversal reports exact max depth" [expr {[dict get $result maxdepth] == 17}]

    set seen {}
    set duplicates {}
    foreach path $paths {
        if {[dict exists $seen $path]} { lappend duplicates $path }
        dict set seen $path 1
    }
    check "dirs never duplicates a path" [expr {$duplicates eq {}}]
    check "dirs count matches its path list" [expr {[dict get $result dirs] == [llength $paths]}]

    foreach name $junctions {
        set path [file join $ROOT $name]
        check "junction $name is listed" [expr {$path in $paths}]
        check "junction $name is not descended" [expr {[lsearch -glob $paths $path/*] < 0}]
    }
    check "outside junction content cannot leak into walk" [expr {
        [lsearch -glob $paths */outside-child] < 0}]
    if {$junctions ne {}} {
        check "every junction is disclosed" [expr {[llength [dict get $result links]] == [llength $junctions]}]
    }
    if {$denied} {
        check "unreadable directory is named" [expr {[file join $ROOT locked] in $paths}]
        check "unreadable child is not invented" [expr {[file join $ROOT locked child] ni $paths}]
        check "unreadable descent has an error row" [expr {
            [llength [dict get $result errors]] == 1 &&
            [dict get [lindex [dict get $result errors] 0] win32] > 0}]
    } else {
        puts "SKIP unreadable-directory checks (deny ACE did not take)"
    }

    set depth0 [dirs $ROOT -depth 0]
    check "depth zero returns only the root" [expr {[dict get $depth0 paths] eq [list $ROOT]}]
    set depth2 [dirs $ROOT -depth 2]
    check "depth cap excludes deeper descendants" [expr {
        [file join $ROOT deep d] in [dict get $depth2 paths] &&
        [file join $ROOT deep d d] ni [dict get $depth2 paths]}]
    set pruned [dirs $ROOT -prune {DEEP target}]
    check "prune is case-insensitive and names refusals" [expr {
        [dict get $pruned pruned] == 2 &&
        [file join $ROOT deep d] ni [dict get $pruned paths] &&
        [file join $ROOT target child] ni [dict get $pruned paths]}]

    check "dirs rejects drive-relative roots" [expr {
        [errcode_of {dirs C:}] eq {MACHTELD DIRS badvalue}}]
    check "dirs rejects device paths" [expr {
        [errcode_of {dirs {//./PhysicalDrive0}}] eq {MACHTELD DIRS badvalue}}]
    check "dirs rejects missing roots" [expr {
        [errcode_of [list dirs [file join $ROOT missing]]] eq {MACHTELD DIRS notfound}}]
    check "dirs rejects unknown options" [expr {
        [errcode_of [list dirs $ROOT -unknown value]] eq {MACHTELD DIRS usage}}]

    # Hardlink identity and reparse targets are the facts `links` adds to the
    # shared traversal. Both fixtures work without elevation on local NTFS.
    write_file [file join $ROOT shared-a.bin] abc
    set hardlink [file join $ROOT shared-b.bin]
    set have_hardlink [expr {![catch {exec cmd /c mklink /H [file nativename $hardlink] \
        [file nativename [file join $ROOT shared-a.bin]]}]}]
    set link_result [links $ROOT -hardlinks]
    check "links counts the same directories as dirs" [expr {
        [dict get $link_result dirs] == [dict get [dirs $ROOT] dirs]}]
    check "links entered rows describe actual descents" [expr {
        [lsearch -not -exact [lmap row [dict get $link_result entered] {
            dict get $row action
        }] descended] < 0}]
    if {$have_hardlink} {
        check "links reports both names of shared content" [expr {
            [llength [dict get $link_result multilinked]] == 2}]
        foreach row [dict get $link_result multilinked] {
            check "hardlink row reports link count" [expr {[dict get $row links] == 2}]
        }
    } else {
        puts "SKIP hardlink checks (fixture creation failed)"
    }
    check "links without -hardlinks avoids identity scan" [expr {
        [dict get [links $ROOT] multilinked] eq {}}]

    if {"junction" in $junctions} {
        set canonical [canon [file join $ROOT junction]]
        set canonical_path [string map {\\ /} [dict get $canonical path]]
        set target_path [string map {\\ /} [file join $ROOT target]]
        check "canon resolves a junction target" \
            [string equal -nocase $canonical_path $target_path]
        check "canon reports the target's filesystem link count" [expr {
            [dict exists $canonical links] &&
            [string is integer -strict [dict get $canonical links]] &&
            [dict get $canonical links] >= 1}]
    }
} finally {
    wipe $ROOT
    wipe $OUTSIDE
}

if {$fails} {
    puts stderr "$fails filesystem test(s) failed"
    exit 1
}
puts "ALL FILESYSTEM TESTS PASSED"
