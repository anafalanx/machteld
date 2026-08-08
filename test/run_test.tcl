# run_test.tcl -- end-to-end verification of ::machteld::run (M1).
# Run under machteld.exe:   machteld.exe test/run_test.tcl
# Spawns real child processes through the winjob substrate and checks the dicts.

set MT   [info nameofexecutable]
set HERE [file dirname [file normalize [info script]]]
set CHILD [file join $HERE _child.tcl]

# A tiny child program, written fresh so the test is self-contained: echo argv,
# sleep, or exit with a code.
set f [open $CHILD w]
puts $f {fconfigure stdout -translation lf
set mode [lindex $argv 0]
switch -- $mode {
  echoargv { foreach a [lrange $argv 1 end] { puts $a } }
  sleep    { after [lindex $argv 1] }
  exitcode { exit [lindex $argv 1] }
  default  { puts "unknown mode: $mode"; exit 3 }
}}
close $f

set fails 0
proc check {name ok} {
    if {$ok} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}

# 0. the palette is exposed as bare verbs (unqualified run/child/... resolve)
set ok 0
if {![catch {run -- cmd /c echo bare-ok} br]} { set ok [string match *bare-ok* [dict get $br out]] }
check "bare verb 'run' resolves" $ok

# 1. basic run: capture + exit + status
set r [::machteld::run -- cmd /c echo hello]
check "basic exit 0"        [expr {[dict get $r exit] == 0}]
check "basic status ok"     [expr {[dict get $r status] eq "ok"}]
check "basic captured out"  [string match "*hello*" [dict get $r out]]

# 2. exit code > 255 not truncated (a Unix 8-bit code would give 44)
set r [::machteld::run -- cmd /c exit 300]
check "exit 300 untruncated" [expr {[dict get $r exit] == 300}]
check "nonzero => error"     [expr {[dict get $r status] eq "error"}]

# 3. argv round-trip through real CreateProcess (EscapeArg quoting survives the kernel)
set r [::machteld::run -- $MT $CHILD echoargv one "two three" {a"b} {c\d}]
set lines [split [string trimright [dict get $r out] \n] \n]
check "argv count 4"        [expr {[llength $lines] == 4}]
check "argv plain"          [expr {[lindex $lines 0] eq "one"}]
check "argv with space"     [expr {[lindex $lines 1] eq "two three"}]
check "argv with quote"     [expr {[lindex $lines 2] eq {a"b}}]
check "argv with backslash" [expr {[lindex $lines 3] eq {c\d}}]

# 4. -timeout tree-kills a slow child (proves born-in-job + TerminateJobObject)
set t0 [clock milliseconds]
set r [::machteld::run -timeout 500ms -- $MT $CHILD sleep 8000]
set dt [expr {[clock milliseconds] - $t0}]
check "timeout => status timeout" [expr {[dict get $r status] eq "timeout"}]
check "timeout killed fast (<4s)" [expr {$dt < 4000}]

# 5. unknown command throws with structured -errorcode {MACHTELD RUN notfound}
set threw 0
if {[catch {::machteld::run -- no_such_program_zzz_42} e opts]} {
    set threw 1
    check "notfound errorcode" [expr {[lrange [dict get $opts -errorcode] 0 1] eq {MACHTELD RUN}}]
}
check "notfound threw" $threw

# 5b. -stdin feeds the child's standard input
set rs [run -stdin "STDIN-MARKER-77\n" -- findstr STDIN]
check "stdin fed to child" [string match *STDIN-MARKER-77* [dict get $rs out]]

# 5c. -env sets/overrides the child's environment
set re [run -env {ENVMARKER hello-env-42} -- cmd /c echo %ENVMARKER%]
check "env var set for child" [string match *hello-env-42* [dict get $re out]]

# 5d. vtstrip removes ANSI/VT escapes and keeps the text (pure Tcl, headless-safe)
set E [format %c 27]; set B [format %c 7]
set raw [string cat $E {[2J} $E {[0;32mgreen} $E {[0m and } $E {]0;title} $B {done}]
check "vtstrip cleans VT" [expr {[::machteld::vtstrip $raw] eq "green and done"}]

# 5e. -onout streams stdout line-by-line to a callback (and does not also buffer)
set ::onout_lines {}
set r5e [run -onout {lappend ::onout_lines} -- cmd /c "echo line-1&echo line-2&echo line-3"]
check "onout streamed 3 lines"  [expr {[llength $::onout_lines] == 3}]
check "onout line content"      [expr {[lindex $::onout_lines 0] eq "line-1" && [lindex $::onout_lines 2] eq "line-3"}]
check "onout leaves out empty"  [expr {[dict get $r5e out] eq ""}]

# 5f. -onerr streams stderr; a pipe without a callback is still captured
set ::onerr_lines {}
set r5f [run -onerr {lappend ::onerr_lines} -- cmd /c "echo out-here&echo err-here 1>&2"]
check "onerr streamed stderr"   [string match *err-here* [join $::onerr_lines]]
check "onerr keeps out buffered" [string match *out-here* [dict get $r5f out]]

# 5g. a callback error aborts the run and propagates
set threw5g [catch {run -onout {apply {l {error "cb-boom"}}} -- cmd /c echo x} e5g]
check "onout cb error propagates" [expr {$threw5g && [string match *cb-boom* $e5g]}]

# 5h. detach honors -env: the daemon writes its env to a file we then read back
set ddir  [file dirname [info script]]
set dfile [file join $ddir _detach_env.txt]
file delete -force $dfile
detach -env {DETACH_TAG dval-88} -dir $ddir -- cmd /c "echo %DETACH_TAG% > _detach_env.txt"
set dgot ""
for {set i 0} {$i < 50} {incr i} {
    after 100
    if {[file exists $dfile]} {
        set fh [open $dfile]; set dgot [string trim [read $fh]]; close $fh
        if {$dgot ne ""} break
    }
}
check "detach -env set child env" [string match *dval-88* $dgot]
file delete -force $dfile

# 5i. pty spawn accepts -env (plumbing; env reaching the child is checked on a
# real terminal by pty_real.tcl, since pty output can't route headless)
set pe [pty spawn -env {PTY_TAG pval} -- cmd]
check "pty spawn -env ok" [string match pty#* $pe]
pty close $pe

# --- child ensemble ---------------------------------------------------------

# 6. child start / wait: async child, collect its dict
set c [::machteld::child start -- cmd /c echo async]
check "child token"        [string match "child#*" $c]
set r [::machteld::child wait $c]
check "child wait exit 0"  [expr {[dict get $r exit] == 0}]
check "child captured out" [string match "*async*" [dict get $r out]]
::machteld::child close $c

# 7. child info reports running; kill flips status to "killed"
set c [::machteld::child start -- $MT $CHILD sleep 8000]
check "child info running"  [expr {[dict get [::machteld::child info $c] running] == 1}]
::machteld::child kill $c
check "killed status"       [expr {[dict get [::machteld::child wait $c] status] eq "killed"}]
::machteld::child close $c

# 8. wait -any returns whichever child finishes first
set a [::machteld::child start -- $MT $CHILD sleep 200]
set b [::machteld::child start -- $MT $CHILD sleep 8000]
check "wait -any first"     [expr {[::machteld::wait -any $a $b] eq $a}]
::machteld::child kill $b
::machteld::child close $a
::machteld::child close $b

# 9. scope tree-kills children born inside it, by the closing brace
set outer [::machteld::child list]
::machteld::scope {
    ::machteld::child start -- $MT $CHILD sleep 8000
    ::machteld::child start -- $MT $CHILD sleep 8000
}
check "scope killed its children" [expr {[::machteld::child list] eq $outer}]

# 10. detach: fire-and-forget daemon -- returns a pid, not tracked as a child
set before [::machteld::child list]
set pid [::machteld::detach -- cmd /c exit 0]
check "detach returns a pid" [expr {[string is integer -strict $pid] && $pid > 0}]
check "detach not tracked"   [expr {[::machteld::child list] eq $before}]

# --- pty (ConPTY) -----------------------------------------------------------
# This CI sandbox is HEADLESS -- GetConsoleWindow() is NULL and stdout is a
# redirected file -- so a spawned child cannot route through a pseudo-console
# (its output leaks to the inherited stdio instead). Interactive capture / send
# / expect therefore can't be exercised here: the SAME class of sandbox limit as
# detach's breakaway. We verify the ConPTY plumbing that IS observable -- a
# pseudo-console child spawns and the console tears down cleanly, no hang.
# Full expect-style interaction is verified on a real Win11 terminal.
set p [::machteld::pty spawn -- cmd /c exit 0]
check "pty spawn token"    [string match "pty#*" $p]
check "pty listed"         [expr {$p in [::machteld::pty list]}]
::machteld::pty close $p
check "pty closed cleanly" [expr {$p ni [::machteld::pty list]}]

# --- batch no-injection, end-to-end (CVE-2024-24576) ------------------------
# Prove the mitigation through the LIVE launcher: run a real .bat with the
# classic hostile argument and confirm the injected command never executes
# (no canary file), while the batch itself still runs.
set bdir   [file dirname [file normalize [info script]]]
set bat    [file join $bdir _echo.bat]
set canary [file join $bdir _canary.txt]
set fb [open $bat w]
fconfigure $fb -translation crlf
puts $fb "@echo off"
puts $fb "echo BATCH-RAN"
close $fb
file delete -force $canary
# If the argument escaped its quoting, "& echo owned> _canary.txt &" would run
# and create the canary in the child's cwd. With the fix it is one inert arg.
set payload {x" & echo owned> _canary.txt & rem "}
set br [run -dir $bdir -- $bat $payload]
check "batch ran"                 [string match *BATCH-RAN* [dict get $br out]]
check "batch exit 0"              [expr {[dict get $br exit] == 0}]
check "injection inert (no canary)" [expr {![file exists $canary]}]
file delete -force $bat $canary

# --- docs shipped in the exe, and accurate ----------------------------------
# The exe carries its own OKF bundle (help), and a shipped doc must never embed a
# lie -- so the palette's built verbs must exist, and run's dict must match the
# shape the palette documents.
check "help lists palette topic"   [string match *palette* [help]]
check "help palette has content"   [expr {[string length [help palette]] > 500}]
check "help rejects a bad topic"   [catch {help nonesuch_zzz_42}]
set pal [help palette]
set drift {}
foreach v {run child wait scope detach pty store wrap} {
    if {![llength [info commands ::machteld::$v]] || ![string match "*$v*" $pal]} { lappend drift $v }
}
check "palette doc matches built verbs" [expr {$drift eq ""}]
set rdoc [run -- cmd /c echo hi]
check "run dict matches its documented shape" [expr {
    [dict exists $rdoc exit] && [dict exists $rdoc status] && [dict exists $rdoc out] &&
    [dict exists $rdoc err] && [dict exists $rdoc pid] && [dict exists $rdoc truncated]}]

# --- the error-code registry is closed ---------------------------------------
# Creed 5: errors are part of the contract. A code you can trap must be a code
# that is documented, and a code that is documented must be one the C can throw.
# Both directions are checked against the SOURCE, so a new run_error() literal
# added in a hurry fails this test until contract.md names it.
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} m opts] == 0} { return "" }
    return [dict get $opts -errorcode]
}
set SRC [file join $HERE .. src]
if {![file isdirectory $SRC]} {
    puts "skip registry closure (no src/ beside the test)"
} else {
    # Codes the C can raise. Three shapes carry one: an mt_error/fail_code call
    # with a literal, and the two places a code travels in a VARIABLE -- the
    # caller's seed and child_launch/pty_spawn's override -- which a literal
    # scan would otherwise miss entirely.
    set thrown {}
    set domains {}
    foreach f [list [file join $SRC proc.c] [file join $SRC store.c]] {
        set fh [open $f r]; set text [read $fh]; close $fh
        foreach {_ d c} [regexp -all -inline {mt_error\(interp,\s*"([A-Z]+)",\s*"([a-z]+)"} $text] {
            dict set thrown $c 1 ; dict set domains $d 1
        }
        foreach {_ c} [regexp -all -inline {fail_code\(interp,\s*"([a-z]+)"} $text] {
            dict set thrown $c 1 ; dict set domains STORE 1
        }
        foreach {_ c} [regexp -all -inline {code = "([a-z]+)"} $text] { dict set thrown $c 1 }
    }
    # The documented sets, parsed out of the shipped doc's own tables -- so the
    # DOC is the registry, and this test is what stops it becoming a lie.
    set documented {}
    set docdomains {}
    foreach line [split [help contract] \n] {
        if {[regexp {^\|\s*`([a-z]+)`\s*\|} $line -> c]}  { dict set documented $c 1 }
        if {[regexp {^\|\s*`([A-Z]+)`\s*\|} $line -> d]}  { dict set docdomains $d 1 }
    }
    set undocumented [lsort [lmap k [dict keys $thrown]  {expr {[dict exists $documented $k] ? [continue] : $k}}]]
    set unthrown     [lsort [lmap k [dict keys $documented] {expr {[dict exists $thrown $k] ? [continue] : $k}}]]
    set undocdom     [lsort [lmap k [dict keys $domains]  {expr {[dict exists $docdomains $k] ? [continue] : $k}}]]
    set unuseddom    [lsort [lmap k [dict keys $docdomains] {expr {[dict exists $domains $k] ? [continue] : $k}}]]
    check "every code the C throws is documented"    [expr {$undocumented eq ""}]
    check "every documented code exists in the C"    [expr {$unthrown eq ""}]
    check "every domain the C raises is documented"  [expr {$undocdom eq ""}]
    check "every documented domain exists in the C"  [expr {$unuseddom eq ""}]
    if {$undocumented ne ""} { puts "     undocumented: $undocumented" }
    if {$unthrown ne ""}     { puts "     documented but unthrown: $unthrown" }
    if {$undocdom ne ""}     { puts "     undocumented domains: $undocdom" }
    if {$unuseddom ne ""}    { puts "     documented but unraised domains: $unuseddom" }
    check "registry is non-trivial" [expr {[dict size $thrown] >= 8 && [dict size $domains] >= 6}]
}

# --- watch: live directory events --------------------------------------------
set WD [file join $env(TEMP) mt_watch_suite]
file delete -force $WD ; file mkdir $WD ; file mkdir [file join $WD sub]
set w [watch start $WD -recursive]
check "watch start returns a token" [string match "watch#*" $w]
check "watch list shows it"         [expr {$w in [watch list]}]

proc mkfile {path text} { set f [open $path w] ; puts $f $text ; close $f }
proc settle {} { after 300 }

mkfile [file join $WD a.txt] one ; settle
set e [watch read $w]
# creation emits added THEN modified; coalescing must keep the informative one
check "watch sees a creation as added" [expr {
    [llength $e] == 1 && [dict get [lindex $e 0] path] eq "a.txt" &&
    [dict get [lindex $e 0] action] eq "added"}]

mkfile [file join $WD a.txt] two ; settle
set e [watch read $w]
check "watch sees a write as modified" [expr {
    [llength $e] == 1 && [dict get [lindex $e 0] action] eq "modified"}]

file rename [file join $WD a.txt] [file join $WD b.txt] ; settle
set e [watch read $w]
check "watch joins a rename pair" [expr {
    [llength $e] == 1 && [dict get [lindex $e 0] action] eq "renamed" &&
    [dict get [lindex $e 0] path] eq "b.txt" && [dict get [lindex $e 0] from] eq "a.txt"}]

file delete [file join $WD b.txt] ; settle
set e [watch read $w]
check "watch sees a delete as removed" [expr {
    [llength $e] == 1 && [dict get [lindex $e 0] action] eq "removed"}]

mkfile [file join $WD sub deep.txt] y ; settle
set e [watch read $w]
check "watch -recursive reaches a subdirectory" [expr {
    [llength $e] == 1 && [dict get [lindex $e 0] path] eq "sub/deep.txt"}]

mkfile [file join $WD raw.txt] r ; settle
check "watch -raw leaves the stream unmerged" [expr {[llength [watch read $w -raw]] > 1}]
check "an empty read is empty, not a block" [expr {[watch read $w] eq ""}]

# A read with -timeout and nothing coming returns empty, promptly rather than never.
set t0 [clock milliseconds]
watch read $w -timeout 300ms
set waited [expr {[clock milliseconds] - $t0}]
check "watch read -timeout returns on time" [expr {$waited >= 250 && $waited < 3000}]

# The multiplexer: `wait` blocks on a child OR a watch, without polling either.
# The change is made by an external process because a blocking read is in C and
# does not pump Tcl's event loop -- the same rule `child wait` follows.
set slow [child start -- cmd /c "ping -n 4 127.0.0.1 >nul"]
set poke [child start -- cmd /c "ping -n 2 127.0.0.1 >nul & echo q > [file nativename [file join $WD m.txt]]"]
set t0 [clock milliseconds]
set done [wait -any $slow $w]
check "wait -any wakes on the watch, not the slower child" [expr {$done eq $w}]
check "wait -any returned before the slow child exited" [expr {[clock milliseconds] - $t0 < 3500}]
check "the event is there to read" [expr {[llength [watch read $w]] >= 1}]
catch {child kill $slow} ; child close $slow ; child close $poke

check "wait rejects an unknown token" [expr {
    [errcode_of {wait nosuch#1}] eq {MACHTELD WAIT nohandle}}]
watch close $w
check "watch close removes it" [expr {$w ni [watch list]}]
check "reading a closed watch => nohandle" [expr {
    [errcode_of {watch read $w}] eq {MACHTELD WATCH nohandle}}]
check "watching a missing dir => notfound" [expr {
    [errcode_of {watch start [file join $WD nope_zzz]}] eq {MACHTELD WATCH notfound}}]
file delete -force $WD

# --- the manifest describes the RUNNING binary -------------------------------
# The generator derives the manifest from the C source; these check it against
# the interpreter that actually shipped, which is the half a source scan cannot
# prove. Tcl_GetIndexFromObj's own error message enumerates the real subcommand
# table, so the binary is asked rather than trusted.
set M [manifest]
# Every palette verb, C-written and Tcl-written alike -- a manifest that
# described only half the palette would be a partial truth.
check "manifest covers the whole palette" [expr {[lsort [dict keys $M]] eq
    {child detach help manifest pty run scope store version vtstrip wait watch wrap}}]
foreach v [dict keys $M] {
    check "manifest verb $v exists" [expr {[llength [info commands ::machteld::$v]] == 1}]
}
check "manifest marks C and Tcl verbs" [expr {
    [dict get $M run kind] eq "c" && [dict get $M wrap kind] eq "tcl"}]
# The manifest describes itself, which is the cheapest possible proof that
# self-description is not special-cased.
check "manifest describes itself" [expr {[dict get $M manifest kind] eq "tcl"}]
# subcommands: ask the binary by provoking the index error, then compare.
foreach v {child pty store watch} {
    catch {::machteld::$v __nosuch__} m
    set live {}
    if {[regexp {must be (.*)$} $m -> tail]} {
        foreach w [split [string map {" or " " " "," " "} $tail] " "] {
            if {$w ne ""} { lappend live $w }
        }
    }
    set declared [dict keys [dict get $M $v subcommands]]
    check "manifest subcommands match the binary ($v)" \
        [expr {[lsort $live] eq [lsort $declared]}]
    if {[lsort $live] ne [lsort $declared]} { puts "     live=[lsort $live] declared=[lsort $declared]" }
}
# result keys: run the verb and compare the dict it really answers with.
check "manifest run returns matches reality" [expr {
    [lsort [dict keys [run -- cmd /c echo x]]] eq [lsort [dict get $M run returns]]}]
# options: every option the manifest declares must be ACCEPTED (not "unknown
# option"), and an invented one must be rejected -- otherwise "declared" and
# "accepted" could drift apart in either direction.
check "declared option accepted"  [expr {[errcode_of {run -dir . -- cmd /c echo x}] eq ""}]
check "undeclared option refused" [expr {[errcode_of {run -nosuch v -- cmd /c echo x}] eq {MACHTELD RUN usage}}]
set mcodes {}
foreach v [dict keys $M] {
    if {[dict exists $M $v codes]} { lappend mcodes {*}[dict get $M $v codes] }
}
check "manifest codes cover the registry" [expr {
    [lsort -unique $mcodes] eq [lsort [dict keys $documented]]}]

# The domain is the VERB the caller invoked, not the helper that failed: all
# five process verbs share one option parser and one launch core, and used to
# answer MACHTELD RUN whatever you called.
check "run domain"     [expr {[lindex [errcode_of {run -nosuchopt v -- cmd /c echo x}] 1] eq "RUN"}]
check "child domain"   [expr {[lindex [errcode_of {child start -nosuchopt v -- cmd /c echo x}] 1] eq "CHILD"}]
check "wait domain"    [expr {[lindex [errcode_of {wait child#99999}] 1] eq "WAIT"}]
check "detach domain"  [expr {[lindex [errcode_of {detach -nosuchopt v -- cmd /c echo x}] 1] eq "DETACH"}]
check "pty domain"     [expr {[lindex [errcode_of {pty spawn -nosuchopt v -- cmd}] 1] eq "PTY"}]
check "store domain"   [expr {[lindex [errcode_of {store get k}] 1] eq "STORE"}]
# ...including through the SHARED parser and the SHARED launch core.
check "shared parser keeps the caller's domain" [expr {
    [errcode_of {pty spawn -timeout 100 -- cmd}] eq {MACHTELD PTY badvalue}}]
check "shared launcher keeps the caller's domain" [expr {
    [errcode_of {child start -- no_such_program_zzz_42}] eq {MACHTELD CHILD notfound}}]

# The launch/notfound split, which was the defect this registry exposed: the
# SAME condition (a program that is not on PATH) used to answer `launch` from
# run/child/pty and `notfound` from detach.
set missing no_such_program_zzz_42
check "run missing => notfound"         [expr {[errcode_of {run -- $missing}] eq {MACHTELD RUN notfound}}]
check "child start missing => notfound" [expr {[errcode_of {child start -- $missing}] eq {MACHTELD CHILD notfound}}]
check "detach missing => notfound"      [expr {[errcode_of {detach -- $missing}] eq {MACHTELD DETACH notfound}}]
check "pty spawn missing => notfound"   [expr {[errcode_of {pty spawn -- $missing}] eq {MACHTELD PTY notfound}}]
# ...and a dead token is a DIFFERENT failure, so it gets a different code.
check "bad child token => nohandle"     [expr {[errcode_of {child info child#99999}] eq {MACHTELD CHILD nohandle}}]
check "bad pty token => nohandle"       [expr {[errcode_of {pty send pty#99999 x}] eq {MACHTELD PTY nohandle}}]
check "bad duration => badvalue"        [expr {[errcode_of {run -timeout 100 -- cmd /c echo x}] eq {MACHTELD RUN badvalue}}]
check "unknown option => usage"         [expr {[errcode_of {run -nosuchopt v -- cmd /c echo x}] eq {MACHTELD RUN usage}}]

# store now carries codes at all (it set none before).
check "store before open => notopen" [expr {[errcode_of {store get k}] eq {MACHTELD STORE notopen}}]
store open [file join $env(TEMP) mt_regtest.sqlite]
check "store put/get round-trips"    [expr {[store put a b] eq "" && [store get a] eq "b"}]
store close
file delete -force [file join $env(TEMP) mt_regtest.sqlite]

# --- the first real tool, wrapped and self-testing -----------------------------
# `changes` is a pure Tcl/Tk tool stamped by wrap. Its own --selftest exercises
# the event model with no window, because a hidden Tk window drops events and
# would be testing something other than the program.
set TOOL [file join $HERE .. tool changes]
if {[file isdirectory $TOOL]} {
    check "the change-viewer's model passes its own selftest" [expr {
        ![catch {run -timeout 60s -- $MT [file join $TOOL main.tcl] --selftest} tr]
        && [dict get $tr exit] == 0}]
}

file delete $CHILD
puts "\n[expr {$fails == 0 ? {ALL PASS} : {FAILURES}}]: $fails failure(s)"
exit $fails
