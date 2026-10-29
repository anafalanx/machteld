package require machteld 0.21

# test/entry_test.tcl -- the host's front door: the literal opt-in gate, argv
# and exit status, startup-file quirks (BOM, CRLF, Ctrl-Z, top-level return),
# no lock on the startup file, pinned embedded libraries, refused stdin
# programs, the host modes (--help, --version, --docs) and their precedence
# over same-name files, a hard host kill taking its supervised tree with it,
# and a host started below a folder whose parent cannot be listed.
#
#     machteld.exe test/entry_test.tcl RUNTIME ?--fixture EXE? ?--bare EXE?
#
# RUNTIME is the host under test. The crash checks need the compiled
# process_fixture.exe (--fixture), the payload check the extracted bare host
# (--bare); without them those checks are skipped. The Tcl port (2026-10-28)
# of test/entry_test.ps1. Not checked: that --docs output lacks
# FILE_ATTRIBUTE_TEMPORARY, which Tcl cannot read.

namespace eval ::et {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable failures 0
    variable work ""
    variable runtime ""
}

proc ::et::check {name condition {detail ""}} {
    variable failures
    if {$condition} {
        puts "ok   $name"
    } else {
        incr failures
        puts "FAIL $name $detail"
    }
}

proc ::et::writeText {path text} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel [encoding convertto utf-8 $text]
    close $channel
}

proc ::et::writeBytes {path bytes} {
    set channel [open $path wb]
    puts -nonewline $channel $bytes
    close $channel
}

proc ::et::readText {path} {
    set channel [open $path rb]
    try {
        return [encoding convertfrom -profile replace utf-8 [read $channel]]
    } finally {
        close $channel
    }
}

# Tcl source text for a path: forward slashes, braced.
proc ::et::tclPath {path} {
    return "{[string map {\\ /} $path]}"
}

# Runs the host under test (or -exe) and returns exit, out, err and text
# (err then out), decoded leniently, and the captured bytes as outBytes and
# errBytes. Only the four options below are taken; anything else, such as
# --docs or -encoding, is the host's first argument.
proc ::et::host {args} {
    variable runtime
    set exe $runtime
    set options {}
    while {[lindex $args 0] in {-exe -dir -env -stdin}} {
        set args [lassign $args option value]
        if {$option eq "-exe"} {
            set exe $value
        } else {
            lappend options $option $value
        }
    }
    set result [run -timeout 2m {*}$options -- $exe {*}$args]
    set out [encoding convertfrom -profile replace utf-8 [dict get $result out]]
    set err [encoding convertfrom -profile replace utf-8 [dict get $result err]]
    dict create exit [dict get $result exit] status [dict get $result status] \
        out $out err $err text $err$out outBytes [dict get $result out] errBytes [dict get $result err]
}

# Captured bytes as strict UTF-8; empty when they are not.
proc ::et::strictText {bytes} {
    if {[catch {encoding convertfrom -profile strict utf-8 $bytes} text]} {
        return ""
    }
    return $text
}

proc ::et::waitForFile {path {milliseconds 5000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        if {[file isfile $path] && [file size $path] > 0} {
            return 1
        }
        after 25
    }
    return 0
}

proc ::et::alive {pid} {
    expr {![catch {mtps info $pid}]}
}

proc ::et::waitForProcessGone {pid {milliseconds 5000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        if {![alive $pid]} {
            return 1
        }
        after 25
    }
    return 0
}

proc ::et::decodeJson {text} {
    if {[catch {json decode [string trim $text]} decoded]} {
        return ""
    }
    return $decoded
}

proc ::et::envelopeOk {decoded} {
    expr {$decoded ne "" && [dict exists $decoded ok] && [dict get $decoded ok] == 1 &&
          [dict exists $decoded result]}
}

# Tcl ticket d40d8db3: an exact descendant can be opened while a parent
# directory cannot be enumerated. Tcl 9.0.4 used to drop one component while
# normalizing the executable path, preventing standalone zipfs startup.
# Exercise the actual packaged host and wrap route under that ACL.
proc ::et::aclTests {versionRe} {
    variable work
    variable runtime
    set blocked [file join $work acl-normalize profilecomponent]
    set app [file join $blocked app]
    set aclHost [file join $app [file tail $runtime]]
    file mkdir $app
    file copy $runtime $aclHost
    set user [lindex [split [string trim [encoding convertfrom -profile replace utf-8 \
        [dict get [run -- whoami.exe /user /fo csv /nh] out]]] ,] end]
    set sid [string trim $user "\""]
    set denied 0
    try {
        set result [run -- icacls.exe [file nativename $blocked] /deny "*${sid}:(RD)"]
        if {[dict get $result exit] != 0} {
            check "ACL regression fixture permits exact open but denies parent enumeration" 0 \
                [encoding convertfrom -profile replace utf-8 [dict get $result out][dict get $result err]]
            return
        }
        set denied 1
        set directOpen [expr {![catch {close [open $aclHost rb]}]}]
        set enumerationDenied [catch {glob -directory $blocked *}]
        check "ACL regression fixture permits exact open but denies parent enumeration" \
            [expr {$directOpen && $enumerationDenied}]

        set result [host -exe $aclHost --version]
        check "standalone zipfs starts below an ACL-denied parent" \
            [expr {[dict get $result exit] == 0 && [regexp $versionRe [dict get $result out]]}] [dict get $result text]

        set program [file join $work acl-entry.tcl]
        writeText $program [join {
            {package require machteld}
            {set normalized [file normalize [info nameofexecutable]]}
            {puts "ACL-ENTRY:[file exists $normalized]:[version]"}
        } \n]\n
        set result [host -exe $aclHost $program]
        check "direct entry runs below an ACL-denied parent without losing a path component" \
            [expr {[dict get $result exit] == 0 && [regexp "ACL-ENTRY:1:$versionRe" [dict get $result out]]}] \
            [dict get $result text]

        set wrapped [file join $work acl-wrapped.exe]
        set result [host -exe $aclHost wrap $program -o $wrapped --console]
        check "wrap runs from a host below an ACL-denied parent" \
            [expr {[dict get $result exit] == 0 && [file isfile $wrapped]}] [dict get $result text]
    } finally {
        if {$denied} {
            run -- icacls.exe [file nativename $blocked] /remove:d "*$sid"
        }
    }
}

# A hard host termination bypasses Tcl exit handlers. Every supervised launch
# must still die with the host, including a descendant that outlived its
# direct parent, while an explicit detach remains outside those jobs. The host
# runs as this test's own child; only its own process is terminated.
proc ::et::crashTests {fixture} {
    variable work
    variable runtime
    set childPid [file join $work crash-child.pid]
    set descendantPid [file join $work crash-descendant.pid]
    set detachResult [file join $work crash-detach.result]
    set detachedMarker [file join $work crash-detached.marker]
    set ready [file join $work crash.ready]
    set program [file join $work crash-cleanup.tcl]
    writeText $program [string map [list \
        @@FIXTURE@@ [tclPath $fixture] @@CHILD_PID@@ [tclPath $childPid] \
        @@DESCENDANT_PID@@ [tclPath $descendantPid] @@DETACH_RESULT@@ [tclPath $detachResult] \
        @@DETACHED_MARKER@@ [tclPath $detachedMarker] @@READY@@ [tclPath $ready]] {package require machteld
child start -env [list MACHTELD_TEST_PIDFILE @@CHILD_PID@@] -- @@FIXTURE@@ hang 30000
child start -- @@FIXTURE@@ descendant-parent 30000 @@DESCENDANT_PID@@
set deadline [expr {[clock milliseconds] + 5000}]
while {[clock milliseconds] < $deadline &&
       (![file exists @@CHILD_PID@@] || ![file exists @@DESCENDANT_PID@@])} {
    after 10
}
if {[catch {
    detach -- @@FIXTURE@@ daemon-marker @@DETACHED_MARKER@@ 1800
} detached options]} {
    set detachResult "denied:[dict get $options -errorcode]"
} else {
    set detachResult "ok:$detached"
}
set channel [open @@DETACH_RESULT@@ w]
puts $channel $detachResult
close $channel
set channel [open @@READY@@ w]
puts $channel ready
close $channel
vwait ::machteld_crash_fixture_forever
}]
    set crash [child start -- $runtime $program]
    try {
        set hostPid [dict get [child info $crash] pid]
        set started [expr {[waitForFile $ready] && [waitForFile $childPid 1000] &&
                           [waitForFile $descendantPid 1000] && [waitForFile $detachResult 1000]}]
        check "host-crash cleanup fixture starts its supervised processes" $started
        if {!$started} {
            return
        }
        set child [string trim [readText $childPid]]
        set descendant [string trim [readText $descendantPid]]
        set detachText [string trim [readText $detachResult]]
        set detached ""
        set detachSucceeded [regexp {^ok:([0-9]+)$} $detachText -> detached]
        set detachDenied [expr {$detachText eq "denied:MACHTELD DETACH launch"}]
        check "crash fixture detach either escapes or reports exact strict denial" \
            [expr {$detachSucceeded || $detachDenied}] $detachText
        check "supervised child is alive before host termination" [alive $child]
        check "supervised descendant is alive before host termination" [alive $descendant]
        if {$detachSucceeded} {
            check "detached work is still pending before host termination" \
                [expr {![file exists $detachedMarker] && [alive $detached]}]
        }
        mtps kill $hostPid
        child wait $crash -timeout 10s
        check "forced host termination kills its supervised child" [waitForProcessGone $child]
        check "forced host termination kills the supervised descendant tree" [waitForProcessGone $descendant]
        if {$detachSucceeded} {
            set completed [waitForFile $detachedMarker 5000]
            check "detached work survives forced host termination" \
                [expr {$completed && [string trim [readText $detachedMarker]] == $detached}]
        } elseif {$detachDenied} {
            after 2200
            check "strictly denied detach never runs user code" [expr {![file exists $detachedMarker]}]
        }
    } finally {
        # Whatever the host left behind is still in this child's job.
        child close $crash
    }
}

proc ::et::entryTests {versionRe version} {
    variable work
    set accepted [file join $work accepted.program]
    writeText $accepted [join {
        {#!/usr/bin/env machteld}
        {# Leading comments and blank lines are allowed.}
        {}
        {package require machteld}
        {puts "ENTRY-OK:$argv"}
        {puts "ENTRY-PATH:[expr {$argv0 eq [info script]}]"}
        {puts "ENTRY-ARGC:$argc"}
        {puts "ENTRY-LAST:[lindex $argv end]"}
        {puts "ENTRY-UTF8:\u00e9\u4e16\u754c"}
        {puts stderr "ENTRY-UTF8:\u00e9\u4e16\u754c"}
    } \n]\n
    set result [host $accepted one "two words"]
    set out [dict get $result out]
    check "direct invocation accepts arbitrary extension and literal opt-in" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-OK:one* $out] &&
               [string match {*two words*} $out]}] [dict get $result err]
    check "direct invocation preserves argv0 and info script identity" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-PATH:1* $out]}] [dict get $result text]
    check "direct invocation preserves a spaced argument as one item" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-ARGC:2* $out] &&
               [string match {*ENTRY-LAST:two words*} $out]}] [dict get $result text]
    # The program spells the text as escapes and the expectation is built from
    # code points, so this file's own encoding cannot give both the same
    # mojibake. The captures must be strict UTF-8.
    set utf8 "ENTRY-UTF8:[format %c%c%c 0xe9 0x4e16 0x754c]"
    check "captured stdout and stderr preserve UTF-8 text" \
        [expr {[dict get $result exit] == 0 &&
               [string first $utf8 [strictText [dict get $result outBytes]]] >= 0 &&
               [string first $utf8 [strictText [dict get $result errBytes]]] >= 0}] [dict get $result text]

    set exact [file join $work exact-version.tcl]
    writeText $exact "package require -exact machteld $version\nputs \"ENTRY-EXACT:\[package require machteld\]\"\n"
    set result [host $exact]
    check "direct invocation accepts the exact canonical version" \
        [expr {[dict get $result exit] == 0 && [regexp "(?n)^ENTRY-EXACT:$versionRe\r?$" [dict get $result out]]}] \
        [dict get $result text]

    # The retired engine switch has no direct-host dispatch. With no selected
    # startup script, the ordinary host path fails closed on redirected stdin,
    # here an empty pipe.
    set result [host -dir $work -stdin "" --machteld-engine]
    check "--machteld-engine has no direct-host dispatch" \
        [expr {[dict get $result exit] == 1 && [string match {*redirected stdin is not accepted*} [dict get $result text]]}] \
        [dict get $result text]

    set exitProgram [file join $work exit-seven.tcl]
    writeText $exitProgram "package require machteld\nexit 7\n"
    set result [host $exitProgram]
    check "direct opted-in exit status survives process cleanup" [expr {[dict get $result exit] == 7}] [dict get $result text]

    set bom [file join $work bom-crlf.tcl]
    writeBytes $bom "\xEF\xBB\xBFpackage require machteld\r\nputs ENTRY-BOM-OK\r\n"
    set result [host $bom]
    check "captured startup accepts a UTF-8 BOM and CRLF" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-BOM-OK* [dict get $result out]]}] [dict get $result text]

    set returnProgram [file join $work top-level-return.tcl]
    writeText $returnProgram "package require machteld\nputs ENTRY-RETURN-OK\nreturn\nputs SHOULD-NOT-RUN\n"
    set result [host $returnProgram]
    check "captured startup gives top-level return normal sourced-file semantics" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-RETURN-OK* [dict get $result out]] &&
               ![string match *SHOULD-NOT-RUN* [dict get $result out]]}] [dict get $result text]

    set ctrlZ [file join $work control-z.tcl]
    writeBytes $ctrlZ "package require machteld\nputs ENTRY-CTRLZ-OK\n\x1Aputs SHOULD-NOT-RUN-AFTER-EOF\n"
    set result [host $ctrlZ]
    check "captured startup ignores the DOS end-of-file tail" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-CTRLZ-OK* [dict get $result out]] &&
               ![string match *SHOULD-NOT-RUN-AFTER-EOF* [dict get $result out]]}] [dict get $result text]

    set movable [file join $work movable]
    set moved [file join $work movable-after-start]
    file mkdir $movable
    set moveProgram [file join $movable main.tcl]
    writeText $moveProgram "package require machteld\nfile rename \[file dirname \[info script\]\] [tclPath $moved]\nputs ENTRY-RENAME-OK\n"
    set result [host $moveProgram]
    check "direct entry does not retain locks on its file or parent tree" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-RENAME-OK* [dict get $result out]] &&
               [file isfile [file join $moved main.tcl]]}] [dict get $result text]

    # Loading Tk installs a main loop that starts after the selected program
    # has completed. Its first callback must not inherit the program's
    # temporary `info script` context.
    set marker [file join $work post-start-info-script.txt]
    set postStart [file join $work post-start.tcl]
    writeText $postStart [string map [list @@MARKER@@ [tclPath $marker]] {package require machteld
package require Tk
wm withdraw .
proc entry_post_start {} {
    set channel [open @@MARKER@@ w]
    puts -nonewline $channel [info script]
    close $channel
    destroy .
}
after 0 entry_post_start
}]
    set result [host $postStart]
    check "post-start callbacks see an empty info script context" \
        [expr {[dict get $result exit] == 0 && [file isfile $marker] && [file size $marker] == 0}] [dict get $result text]

    writeText [file join $work wrap] "package require machteld\nputs ENTRY-LITERAL-WRAP\n"
    set result [host -dir $work wrap]
    check "an existing startup file literally named wrap wins over host convenience dispatch" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-LITERAL-WRAP* [dict get $result text]]}] [dict get $result text]

    set result [host [file join $work does-not-exist.tcl]]
    check "direct invocation reports a missing startup with status one" \
        [expr {[dict get $result exit] == 1 && [string length [dict get $result text]] > 0}] [dict get $result text]

    set missing [file join $work missing-opt-in.tcl]
    writeText $missing "puts SHOULD-NOT-RUN\n"
    set result [host $missing]
    check "direct invocation refuses a program without opt-in" \
        [expr {[dict get $result exit] == 1 && [string match {*package require machteld*} [dict get $result text]]}] \
        [dict get $result err]

    set substituted [file join $work substituted.tcl]
    writeText $substituted "set p machteld\npackage require \$p\nputs SHOULD-NOT-RUN\n"
    set result [host $substituted]
    check "direct invocation refuses substituted opt-in" \
        [expr {[dict get $result exit] == 1 && [string match {*package require machteld*} [dict get $result text]]}] \
        [dict get $result err]

    set encodingMarker [file join $work encoding-ran.txt]
    set encodingProgram [file join $work encoding-program.tcl]
    writeText $encodingProgram "package require machteld\nset f \[open [tclPath $encodingMarker] w\]\nputs \$f ran\nclose \$f\n"
    set result [host -encoding utf-8 $encodingProgram]
    check "direct invocation rejects Tcl_Main -encoding before entry eval" \
        [expr {[dict get $result exit] == 1 && ![file exists $encodingMarker]}] [dict get $result text]

    set hostileTcl [file join $work hostile-tcl]
    set hostileTk [file join $work hostile-tk]
    set tclPoison [file join $work tcl-poison-ran.txt]
    set tkPoison [file join $work tk-poison-ran.txt]
    writeText [file join $hostileTcl init.tcl] "set f \[open [tclPath $tclPoison] w\]\nputs \$f poisoned\nclose \$f\n"
    writeText [file join $hostileTk tk.tcl] "set f \[open [tclPath $tkPoison] w\]\nputs \$f poisoned\nclose \$f\n"
    set libraryProgram [file join $work library-program.tcl]
    writeText $libraryProgram "package require machteld\nputs \"TCL-LIB:\$::tcl_library\"\nputs \"TK-LIB:\$::tk_library\"\n"
    set result [host -env [list TCL_LIBRARY [file nativename $hostileTcl] TK_LIBRARY [file nativename $hostileTk]] $libraryProgram]
    check "host ignores hostile TCL_LIBRARY and pins embedded Tcl scripts" \
        [expr {[dict get $result exit] == 0 && [string match *TCL-LIB://zipfs:/app/tcl_library* [dict get $result out]] &&
               ![file exists $tclPoison]}] [dict get $result text]
    check "host ignores hostile TK_LIBRARY and pins embedded Tk scripts" \
        [expr {[dict get $result exit] == 0 && [string match *TK-LIB://zipfs:/app/tk_library* [dict get $result out]] &&
               ![file exists $tkPoison]}] [dict get $result text]

    set result [host -stdin "puts SHOULD-NOT-RUN\n" -]
    check "stdin programs are refused with status one" [expr {[dict get $result exit] == 1}] [dict get $result text]

    set stdinMarker [file join $work stdin-ran.txt]
    set result [host -stdin "set f \[open [tclPath $stdinMarker] w\]\nputs \$f ran\nclose \$f\n"]
    check "redirected stdin without a startup file exits without eval" \
        [expr {[dict get $result exit] == 1 && ![file exists $stdinMarker]}] [dict get $result text]
}

proc ::et::hostModeTests {versionRe} {
    variable work
    set help [host --help]
    set out [dict get $help out]
    check "--help is a host mode" [expr {[dict get $help exit] == 0 && [string length $out] > 0}] [dict get $help err]
    check "--help identifies the complete Machteld, Tcl, and Tk reference" \
        [expr {[regexp -nocase {complete offline reference} $out] && [regexp "Machteld $versionRe" $out] &&
               [regexp {Tcl 9\.0\.4} $out] && [regexp {Tk 9\.0\.4} $out] &&
               [regexp -nocase -- {--docs} $out] && [regexp -nocase {search} $out]}] [dict get $help text]
    set result [host --version]
    check "--version is a host mode" \
        [expr {[dict get $result exit] == 0 && [regexp $versionRe [dict get $result out]]}] [dict get $result err]

    set status [host --docs status --json]
    set decoded [expr {[dict get $status exit] == 0 ? [decodeJson [dict get $status out]] : ""}]
    check "--docs exposes a machine-readable host route" \
        [expr {[dict get $status exit] == 0 && [envelopeOk $decoded]}] [dict get $status text]
    check "embedded reference status names exact runtime versions" \
        [expr {[envelopeOk $decoded] && [regexp $versionRe [dict get $status out]] &&
               [regexp {9\.0\.4} [dict get $status out]] && [regexp -nocase {sha256} [dict get $status out]]}] \
        [dict get $status text]

    set result [host --docs]
    set out [dict get $result out]
    check "--docs with no operation returns the agent documentation bootstrap" \
        [expr {[dict get $result exit] == 0 && [regexp {(?n)^# Agent documentation bootstrap} $out] &&
               [regexp -nocase {complete, exact-version offline\s+references} $out] &&
               [regexp {Tcl 9\.0\.4} $out] && [regexp {Tk 9\.0\.4} $out] &&
               [string match {*docs status*} $out] && [string match {*docs get*} $out] &&
               [string match {*docs search*} $out] && [string match {*docs extract*} $out]}] [dict get $result text]

    set statusFile [file join $work reference-status.json]
    set result [host --docs status --json --output $statusFile]
    set decoded [expr {[dict get $result exit] == 0 && [file isfile $statusFile] ? [decodeJson [readText $statusFile]] : ""}]
    check "--docs writes its JSON envelope to an explicit output file" \
        [expr {[dict get $result exit] == 0 && [envelopeOk $decoded]}] [dict get $result text]

    set result [host docs get tcl/command/dict --section synopsis --limit 4096 --json]
    set decoded [expr {[dict get $result exit] == 0 ? [decodeJson [dict get $result out]] : ""}]
    check "docs convenience route retrieves a bounded Tcl reference section" \
        [expr {[dict get $result exit] == 0 && [envelopeOk $decoded] &&
               [string match *tcl/command/dict* [dict get $result out]] &&
               [regexp -nocase {synopsis} [dict get $result out]]}] [dict get $result text]

    set shadow [file join $work route-directory-shadow]
    file mkdir [file join $shadow docs] [file join $shadow wrap]
    set result [host -dir $shadow docs status --json]
    set decoded [expr {[dict get $result exit] == 0 ? [decodeJson [dict get $result out]] : ""}]
    check "a same-name directory does not hide the docs convenience route" \
        [expr {[dict get $result exit] == 0 && [envelopeOk $decoded]}] [dict get $result text]

    set result [host -dir $shadow wrap]
    check "a same-name directory does not hide the wrap convenience route" \
        [expr {[dict get $result exit] == 1 && [regexp -nocase {wrap} [dict get $result text]] &&
               ![regexp -nocase {regular file|startup program} [dict get $result text]]}] [dict get $result text]

    set result [host --docs get no-such-product/no-such-page --json]
    set decoded [decodeJson [dict get $result text]]
    check "docs host route fails closed for an unknown page" \
        [expr {[dict get $result exit] == 1 && $decoded ne "" && [dict exists $decoded ok] &&
               [dict get $decoded ok] == 0 && [regexp -nocase {not found|notfound} [dict get $result text]]}] \
        [dict get $result text]

    writeText [file join $work docs] "package require machteld\nputs REAL-DOCS-PROGRAM\n"
    set result [host -dir $work docs]
    check "a real opted-in file named docs wins over the convenience route" \
        [expr {[dict get $result exit] == 0 && [string match *REAL-DOCS-PROGRAM* [dict get $result out]]}] [dict get $result text]
    set result [host -dir $work --docs status --json]
    set decoded [expr {[dict get $result exit] == 0 ? [decodeJson [dict get $result out]] : ""}]
    check "the reserved --docs route wins even beside a real file named docs" \
        [expr {[dict get $result exit] == 0 && [envelopeOk $decoded] &&
               ![string match *REAL-DOCS-PROGRAM* [dict get $result out]]}] [dict get $result text]
}

proc ::et::main {argv} {
    variable root
    variable work
    variable runtime
    variable failures
    set fixture ""
    set bare ""
    set argv [lassign $argv runtime]
    while {[llength $argv]} {
        set argv [lassign $argv option value]
        switch -- $option {
            --fixture {set fixture [file normalize $value]}
            --bare {set bare [file normalize $value]}
            default {
                puts stderr "usage: entry_test.tcl RUNTIME ?--fixture EXE? ?--bare EXE?"
                exit 2
            }
        }
    }
    if {$runtime eq "" || ![file isfile $runtime]} {
        puts stderr "entry test: runtime not found: $runtime"
        exit 2
    }
    set runtime [file normalize $runtime]

    # The expected version is derived from the canonical source, never written
    # here: the 0.15.0 sweep found five hardcoded 0.14.0 expectations in this
    # file. The pattern matches the reference generator's canonical check.
    set header [readText [file join $root src machteld.h]]
    if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([0-9]+\.[0-9]+(?:\.[0-9]+)?)"\s*$} $header -> version]} {
        puts stderr "entry test: src/machteld.h has no canonical MACHTELD_VERSION"
        exit 1
    }
    set versionRe [string map {. \\.} $version]

    set work [file join [file normalize $::env(TEMP)] machteld-entry-test-[pid]]
    file mkdir $work
    try {
        aclTests $versionRe
        entryTests $versionRe $version
        if {$fixture ne ""} {
            crashTests $fixture
        } else {
            puts "--   host-crash checks skipped (no --fixture)"
        }
        hostModeTests $versionRe
        if {$bare ne ""} {
            set result [host -exe $bare --version]
            check "bare host refuses to run without its packaged payload" \
                [expr {[dict get $result exit] == 1 && [string match *payload* [dict get $result text]]}] [dict get $result text]
        } else {
            puts "--   bare-host check skipped (no --bare)"
        }
    } finally {
        file delete -force $work
    }
    if {$failures} {
        puts stderr "$failures entry test(s) failed"
        exit 1
    }
    puts "ALL ENTRY TESTS PASSED"
}

::et::main $argv
