package require machteld 0.21

# test/entry_test.tcl -- the host's front door: the literal opt-in gate, argv
# and exit status, startup-file quirks (BOM, CRLF, Ctrl-Z, top-level return),
# no lock on the startup file, pinned embedded libraries, refused stdin
# programs, the host modes (--help, --version, --docs) and their precedence
# over same-name files, a hard host kill taking its supervised tree with it,
# and a host started below a folder whose parent cannot be listed.
#
#     machteld.exe test/entry_test.tcl RUNTIME ?--fixture EXE?
#
# RUNTIME is the host under test. The crash checks need the compiled
# process_fixture.exe (--fixture). The payload test derives the bare PE from
# the candidate's section table before checking the startup error.

source [file join [file dirname [info script]] pe_resources.tcl]

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
# Exercise the actual packaged host and pack route under that ACL.
proc ::et::aclTests {versionRe} {
    variable work
    variable runtime
    set blocked [file join $work acl-normalize profilecomponent]
    set app [file join $blocked app]
    set aclHost [file join $app [file tail $runtime]]
    file mkdir $app
    file copy $runtime $aclHost
    set system [file join $::env(SystemRoot) System32]
    set acl [file join $system icacls.exe]
    set identity [run -- [file join $system whoami.exe] /user /fo csv /nh]
    if {[dict get $identity exit] != 0} { error "whoami.exe could not identify the ACL test user" }
    set user [lindex [split [string trim [encoding convertfrom -profile replace utf-8 \
        [dict get $identity out]]] ,] end]
    set sid [string trim $user "\""]
    if {![regexp {^S-1-(?:[0-9]+-)*[0-9]+$} $sid]} { error "whoami.exe returned an invalid SID" }
    set denied 0
    try {
        set result [run -- $acl [file nativename $blocked] /deny "*${sid}:(RD)"]
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

        set archive [file join $work acl-app.machteld]
        set result [host -exe $aclHost pack $program -o $archive]
        check "pack runs from a host below an ACL-denied parent" \
            [expr {[dict get $result exit] == 0 && [file isfile $archive]}] [dict get $result text]
    } finally {
        if {$denied} {
            run -- $acl [file nativename $blocked] /remove:d "*$sid"
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
    variable runtime
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

    # Exercise the actual entry gate and Tcl package resolver on scripts from
    # the unpublished baseline. A rejected requirement must stop the body.
    set legacy [file join $work baseline-version.tcl]
    foreach {requirement accepts} {{machteld 22-} 1 {machteld 22-30} 0 {-exact machteld 22} 0} {
        writeText $legacy "package require $requirement\nputs ENTRY-BASELINE-BODY\n"
        set result [host $legacy]
        set entered [string match *ENTRY-BASELINE-BODY* [dict get $result out]]
        check "entry requirement $requirement on $version" \
            [expr {$entered == $accepts && ([dict get $result exit] == 0) == $accepts}] \
            [dict get $result text]
    }

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

    # Use the Windows shell's normal foreground and redirection paths. The
    # named files are relative to its private cwd and the image is quoted.
    writeText [file join $work redirected.tcl] {package require machteld
after 100
puts "[gets stdin]|[lindex $argv 0]"
puts stderr done
exit 37
}
    writeText [file join $work input.txt] "input from disk\n"
    writeText [file join $work foreground.cmd] [join {
        {@echo off}
        {"%ENTRY_TEST_EXE%" redirected.tcl "two words" < input.txt > output.txt 2> errors.txt}
        {exit /b %errorlevel%}
    } "\r\n"]
    set shell [file join $::env(SystemRoot) System32 cmd.exe]
    set previousDir [pwd]
    set hadExe [info exists ::env(ENTRY_TEST_EXE)]
    if {$hadExe} { set previousExe $::env(ENTRY_TEST_EXE) }
    try {
        cd $work
        set ::env(ENTRY_TEST_EXE) [file nativename $runtime]
        catch {exec $shell /d /c foreground.cmd} message options
    } finally {
        cd $previousDir
        if {$hadExe} { set ::env(ENTRY_TEST_EXE) $previousExe } else { unset ::env(ENTRY_TEST_EXE) }
    }
    check "Windows shell waits for the console host and preserves redirected streams, arguments and exit status" \
        [expr {[dict exists $options -errorcode] && [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS" &&
            [lindex [dict get $options -errorcode] 2] == 37 &&
            [string trimright [readText [file join $work output.txt]] "\r\n"] eq "input from disk|two words" &&
            [string trimright [readText [file join $work errors.txt]] "\r\n"] eq "done"}] $message

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

    writeText [file join $work pack] "package require machteld\nputs ENTRY-LITERAL-PACK\n"
    set result [host -dir $work pack]
    check "an existing startup file literally named pack wins over host convenience dispatch" \
        [expr {[dict get $result exit] == 0 && [string match *ENTRY-LITERAL-PACK* [dict get $result text]]}] [dict get $result text]

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

proc ::et::inspectionTests {version} {
    variable work
    set home [file join $work {inspection café}]
    set project [file join $home app]
    file mkdir $project
    set app [file join $project main.tcl]
    set marker [file join $project executed]
    writeText $app "package require -exact machteld $version\nclose \[open [list $marker] w\]\n"
    writeText [file join $project project.dict] {schema 1 entry main.tcl files {main.tcl}}
    set archive [file join $home sample.machteld]
    set packed [host pack $app -o $archive]
    check "static-check archive fixture packs" [expr {[dict get $packed exit] == 0}] [dict get $packed text]
    foreach {source kind count} {app/main.tcl script 1 app/project.dict project 1 app directory 2 sample.machteld archive 1} {
        set result [host -dir $home --check $source --json]
        set decoded [decodeJson [dict get $result out]]
        check "check $kind accepts a relative path and never executes its entry" \
            [expr {[dict get $result exit] == 0 && [envelopeOk $decoded] &&
                [dict get $decoded result kind] eq $kind && [dict get $decoded result files] == $count &&
                [dict get $decoded result entry] eq "main.tcl" && ![dict get $decoded result executed] &&
                ![file exists $marker]}] [dict get $result text]
    }
    set bad [file join $home bad.tcl]
    foreach {source code line} [list "# comment\n\nputs bad\n" optin 3 \
            "package require -exact machteld 99999\n" version 1 \
            "package require machteld\n# comment\nset x \{" syntax 3] {
        writeText $bad $source
        set result [host --check $bad --json]
        set decoded [decodeJson [dict get $result err]]
        check "check reports ENTRY $code and the source line" \
            [expr {[dict get $result exit] == 1 && $decoded ne "" && ![dict get $decoded ok] &&
                [dict get $decoded error code] eq $code && [dict get $decoded error line] == $line &&
                [dict get $decoded error path] eq $bad && [dict get $decoded error doc] eq "machteld/application/host"}] \
            [dict get $result text]
    }
    set broken [file join $home broken.machteld]
    zipfs lmkzip $broken [list $app main.tcl]
    set badProject [file join $home broken.dict]
    writeText $badProject {schema 1 entry main.tcl files {{[error should-not-run]}}}
    set forged [file join $home forged.machteld]
    set index [file join $home inventory.dict]
    writeText $index [dict create schema 1 entry main.tcl files [dict create main.tcl \
        [dict create bytes [file size $app] sha256 [string repeat 0 64]]]]
    zipfs lmkzip $forged [list $app main.tcl $index machteld-inventory.dict]
    foreach {args code} [list [list --check $broken] inventory [list --check $forged] inventory \
            [list --check $badProject] notfound [list --check "$bad.missing"] notfound \
            [list --check] usage [list --manifest command absent] notfound \
            [list --manifest package Tk --probe] unsupported [list --manifest --json] usage] {
        set result [host {*}$args --json]
        set decoded [decodeJson [dict get $result err]]
        check "inspection diagnostic for $args" [expr {[dict get $result exit] == 1 &&
            $decoded ne "" && ![dict get $decoded ok] && [dict get $decoded error code] eq $code}] [dict get $result text]
    }
    set manifest [decodeJson [dict get [host --manifest --json] out]]
    set contractScript [file join $home contract.tcl]
    writeText $contractScript {package require machteld
set contract [manifest]
puts [list [lsort [dict keys $contract]] [dict get $contract child subcommands wait]]
}
    lassign [dict get [host $contractScript] out] names waitFacts
    set expectedPackages {Tcl Tk cffi machteld sqlite3}
    variable root
    foreach dir [glob -directory [file join $root packages] -types d machteld-*] {
        lappend expectedPackages machteld::[string range [file tail $dir] 9 end]
    }
    check "shell catalog lists live commands and bundled packages" [expr {[envelopeOk $manifest] &&
        $names eq [dict get $manifest result commands] && [lsort $expectedPackages] eq [dict get $manifest result packages] &&
        ![dict get $manifest result probed]}] $manifest
    set contract [decodeJson [dict get [host --manifest command child wait --json] out]]
    set equal [expr {[envelopeOk $contract] && [lsort [dict keys [dict get $contract result facts]]] eq [lsort [dict keys $waitFacts]]}]
    if {$equal} {
        dict for {key value} $waitFacts {
            if {[dict get $contract result facts $key] ne $value} { set equal 0 }
        }
    }
    check "single subcommand retains typed options and its exact documentation ID" [expr {[envelopeOk $contract] &&
        $equal && [dict get $contract result facts doc] eq "machteld/command/child#wait"}] $contract
    foreach package {Tk sqlite3 machteld::browser} {
        set item [decodeJson [dict get [host --manifest package $package --json] out]]
        check "$package catalog lookup keeps package lazy" [expr {[envelopeOk $item] &&
            [llength [dict get $item result versions]] && ![dict get $item result loaded] && ![dict get $item result probed]}] $item
    }
    set sqlite [decodeJson [dict get [host --manifest package sqlite3 --probe --json] out]]
    check "explicit sqlite3 probe exercises FTS5 trigram" [expr {[envelopeOk $sqlite] &&
        [dict get $sqlite result loaded] && [dict get $sqlite result probed] && "trigram" in [dict get $sqlite result features]}] $sqlite
    # Windows can derive ProgramFiles from ProgramW6432 when creating a child.
    set noBrowser [dict create ProgramFiles $home ProgramFiles(x86) $home ProgramW6432 $home LOCALAPPDATA $home]
    set browser [decodeJson [dict get [host -env $noBrowser --manifest package machteld::browser --probe --json] out]]
    check "explicit browser probe reports an absent installed browser" [expr {[envelopeOk $browser] &&
        [dict get $browser result probed] && ![dict get $browser result detected]}] $browser
    set browserPath [file join $home Microsoft Edge Application msedge.exe]
    writeText $browserPath "fixture metadata only"
    set browser [decodeJson [dict get [host -env $noBrowser --manifest package machteld::browser --probe --json] out]]
    check "browser discovery identifies an install without running it" [expr {[envelopeOk $browser] &&
        [dict get $browser result detected] && [dict get $browser result executable] eq $browserPath}] $browser
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
    check "--help shows archive and standalone packaging" [expr {
        [string first {machteld.exe pack app-directory -o app.machteld} $out] >= 0 &&
        [string first {machteld.exe wrap app.dict -o MyApp.exe --gui} $out] >= 0
    }]
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
    file mkdir [file join $shadow docs] [file join $shadow pack]
    set result [host -dir $shadow docs status --json]
    set decoded [expr {[dict get $result exit] == 0 ? [decodeJson [dict get $result out]] : ""}]
    check "a same-name directory does not hide the docs convenience route" \
        [expr {[dict get $result exit] == 0 && [envelopeOk $decoded]}] [dict get $result text]

    set result [host -dir $shadow pack]
    check "a same-name directory does not hide the pack convenience route" \
        [expr {[dict get $result exit] == 1 && [regexp -nocase {pack} [dict get $result text]] &&
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

proc ::et::companionTests {} {
    variable runtime
    variable work
    set bin [file join $work {installed alongside 世界}]
    set cwd [file join $work {other directory}]
    file mkdir $bin $cwd
    set host [file join $bin {field notes.exe}]
    set nativeHost [file join $bin MACHTELD.EXE]
    file copy -- $runtime $host
    file copy -- $runtime $nativeHost
    set body {package require machteld
fconfigure stdout -translation lf -encoding utf-8
if {$argv eq {--relaunch}} {
    set result [run -timeout 10s -- {*}[app launch] worker {two words}]
    if {[dict get $result exit] != 0} {error {worker relaunch failed}}
    puts -nonewline [encoding convertfrom -profile strict utf-8 [dict get $result out]]
    return
}
puts [list [file normalize [info script]] [file normalize $argv0] $argv [app launch]]}
    set side [file join $bin {field notes.tcl}]
    set decoy [file join $cwd {field notes.tcl}]
    set decoyText "package require machteld\nputs WRONG-DIRECTORY"
    writeText $decoy $decoyText
    set explicit [file join $cwd explicit.tcl]
    writeText $explicit "package require machteld\nputs EXPLICIT"
    set r [host -exe $host -dir $cwd $explicit]
    check "renamed host without a sibling still accepts explicit programs" \
        [expr {[dict get $r exit] == 0 && [string trim [dict get $r out]] eq "EXPLICIT"}] [dict get $r text]
    writeText $side $body
    set words [list $explicit {two words} "--help" {éß} {}]
    set r [host -exe $host -dir $cwd {*}$words]
    set expected [list [file normalize $side] [file normalize $side] $words [list [file normalize $host]]]
    check "a renamed host selects its adjacent opted-in script and preserves every argument" \
        [expr {[dict get $r exit] == 0 && [string trim [dict get $r out]] eq $expected}] [dict get $r text]
    set r [host -exe $host -dir $cwd --version]
    check "an option at the front is delivered to the named application" \
        [expr {[dict get $r exit] == 0 && [lindex [string trim [dict get $r out]] 2] eq "--version"}] [dict get $r text]
    set r [host -exe $host -dir $cwd]
    check "a named application starts without arguments from a different working directory" \
        [expr {[dict get $r exit] == 0 && [lindex [string trim [dict get $r out]] 2] eq {}}] [dict get $r text]
    set r [host -exe $host -dir $cwd --relaunch]
    check "app launch starts the same companion without injecting an extra script argument" \
        [expr {[dict get $r exit] == 0 && [lindex [string trim [dict get $r out]] 2] eq {worker {two words}}}] [dict get $r text]
    writeText [file join $bin machteld.tcl] "package require machteld\nputs WRONG-CANONICAL"
    set r [host -exe $nativeHost -dir $cwd $explicit]
    check "the canonical host ignores a neighboring machteld.tcl, case-insensitively" \
        [expr {[dict get $r exit] == 0 && [string trim [dict get $r out]] eq "EXPLICIT"}] [dict get $r text]
    set r [host -exe $host -dir $cwd --machteld-generation invalid]
    check "a captured worker-generation route retains precedence over the companion" \
        [expr {[dict get $r exit] != 0 && ![string match "*$side*" [dict get $r out]]}] [dict get $r text]
    writeText $side "puts UNVALIDATED-COMPANION"
    set r [host -exe $host -dir $cwd $explicit]
    check "an unopted companion fails without evaluating it or a fallback script" \
        [expr {[dict get $r exit] != 0 && [dict get $r out] eq {} &&
            [string match {*package require machteld*} [dict get $r err]]}] [dict get $r text]
    file delete -- $side
    if {![catch {file link -symbolic $side $decoy}]} {
        try {
            set r [host -exe $host -dir $cwd $explicit]
            check "a companion name redirect never selects its target" \
                [expr {[dict get $r exit] != 0 && [dict get $r out] eq {}}] [dict get $r text]
        } finally {
            # The signed 0.21 driver cannot recursively remove file symlinks on Windows.
            file delete -- $side
            set missing [catch {file lstat $side st} message options]
            check "the companion link has been removed" \
                [expr {$missing && [lrange [dict get $options -errorcode] 0 1] eq {POSIX ENOENT}}] $message
            check "removing the companion link preserves its target" \
                [expr {[file isfile $decoy] && [readText $decoy] eq $decoyText}]
        }
    } else {
        puts "--   companion symbolic link requires Windows file-symlink permission"
    }
}

proc ::et::main {argv} {
    variable root
    variable work
    variable runtime
    variable failures
    set fixture ""
    set argv [lassign $argv runtime]
    while {[llength $argv]} {
        set argv [lassign $argv option value]
        switch -- $option {
            --fixture {set fixture [file normalize $value]}
            default {
                puts stderr "usage: entry_test.tcl RUNTIME ?--fixture EXE?"
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
    if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([1-9][0-9]*)"\s*$} $header -> version]} {
        puts stderr "entry test: src/machteld.h has no canonical MACHTELD_VERSION"
        exit 1
    }
    # The version is one natural number, matched as a whole word: 22 does not
    # match inside 220 or 122.
    set versionRe "\\m$version\\M"

    set work [file join [file normalize $::env(TEMP)] machteld-entry-test-[pid]]
    file mkdir $work
    try {
        aclTests $versionRe
        entryTests $versionRe $version
        companionTests
        if {$fixture ne ""} {
            crashTests $fixture
        } else {
            puts "--   host-crash checks skipped (no --fixture)"
        }
        hostModeTests $versionRe
        inspectionTests $version
        # Exercise payload refusal using the tested runtime's PE sections.
        # The release artifact itself remains untouched.
        set bare [file join $work stripped-runtime.exe]
        set image [::pe::bytes $runtime]
        set pe [::pe::u32 $image 0x3c]
        set count [::pe::u16 $image [expr {$pe + 6}]]
        set table [expr {$pe + 24 + [::pe::u16 $image [expr {$pe + 20}]]}]
        set end 0
        for {set i 0} {$i < $count} {incr i} {
            set row [expr {$table + 40*$i}]
            set end [expr {max($end, [::pe::u32 $image [expr {$row+20}]] + [::pe::u32 $image [expr {$row+16}]])}]
        }
        set f [open $bare {CREAT EXCL WRONLY BINARY}]
        try {puts -nonewline $f [string range $image 0 [expr {$end-1}]]} finally {close $f}
        set result [host -exe $bare --version]
        check "bare host refuses to run without its packaged payload" \
            [expr {[dict get $result exit] == 1 && [string match *payload* [dict get $result text]]}] [dict get $result text]
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
