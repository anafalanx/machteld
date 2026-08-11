# run_test.tcl -- end-to-end verification of ::machteld::run (M1).
# Run under machteld.exe:   machteld.exe tcl test/run_test.tcl
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

# Hoisted to the top: it is used from the first test onward, and living halfway
# down the file meant a new test above that point failed with "invalid command"
# rather than with what it was actually checking.
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} m opts] == 0} { return "" }
    return [dict get $opts -errorcode]
}

# The value of a script, or "" if it raised. For a check whose SUBJECT may stop
# existing when the thing under test regresses: calling a command that is now
# missing aborts the whole run at that line, so the gate reports as a crash and
# every check after it silently never runs. This suite has learned that three
# times (`wres`, `pres`, `pwait`); this is the general form.
proc valof {script} {
    if {[catch {uplevel 1 $script} r]} { return "" }
    return $r
}

# WRITING A FIXTURE FILE, HOISTED HERE FOR THE SAME REASON `errcode_of` WAS.
# Three separate sections grew their own copy of this three lines lower down,
# and twice a section reached FORWARD for one defined two hundred lines below
# it -- which does not fail the check, it aborts the run with "invalid command"
# and silently drops every check after it. Same failure the two procs above
# exist to prevent, arriving through the fixtures instead of through the
# subjects. One writer, defined before anything uses it.
proc FxWrite {path text} {
    file mkdir [file dirname $path]
    set fh [open $path wb]
    puts -nonewline $fh $text
    close $fh
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
set r [::machteld::run -- $MT tcl $CHILD echoargv one "two three" {a"b} {c\d}]
set lines [split [string trimright [dict get $r out] \n] \n]
check "argv count 4"        [expr {[llength $lines] == 4}]
check "argv plain"          [expr {[lindex $lines 0] eq "one"}]
check "argv with space"     [expr {[lindex $lines 1] eq "two three"}]
check "argv with quote"     [expr {[lindex $lines 2] eq {a"b}}]
check "argv with backslash" [expr {[lindex $lines 3] eq {c\d}}]

# 4. -timeout tree-kills a slow child (proves born-in-job + TerminateJobObject)
set t0 [clock milliseconds]
set r [::machteld::run -timeout 500ms -- $MT tcl $CHILD sleep 8000]
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
set c [::machteld::child start -- $MT tcl $CHILD sleep 8000]
check "child info running"  [expr {[dict get [::machteld::child info $c] running] == 1}]
::machteld::child kill $c
check "killed status"       [expr {[dict get [::machteld::child wait $c] status] eq "killed"}]
::machteld::child close $c

# 7b. -timeout on an ASYNCHRONOUS child. This was accepted and silently ignored:
# `-timeout` lives in the shared option parser, so the manifest declared it for
# `child` while nothing enforced it, and `child wait` waited forever regardless.
# A documented, declared, inert option is worse than a missing one, because a
# caller builds on it. The spinner below never reads its input and never checks
# for anything -- only the OS can stop it.
set spin [file join $HERE _spin.tcl]
set f [open $spin w] ; puts $f {proc spin {} { while {1} { set x [expr {sqrt(2.0)}] } } ; spin} ; close $f

set t0 [clock milliseconds]
set c [child start -timeout 800ms -- $MT tcl $spin]
# The outer bound is deliberate. `child wait` with no timeout of its own blocks
# FOREVER on a spinner, so if the start deadline is ever lost this test would
# hang the suite rather than fail it -- and a hang reports nothing at all. With
# a 15s ceiling the same regression instead lands as a wall-clock failure below.
set r [child wait $c -timeout 15s]
set dt [expr {[clock milliseconds] - $t0}]
check "child start -timeout kills an uncooperative child" [expr {[dict get $r status] eq "timeout"}]
check "child start -timeout fires near its deadline"      [expr {$dt > 500 && $dt < 4000}]
child close $c

# A CALLER'S WAIT BOUND IS NOT A DEATH SENTENCE, and this block asserted the
# opposite until a supervisor needed to poll. `child wait -timeout` used to
# tree-kill on expiry -- which meant the polling pattern the docs recommend for a
# Tk tool ("a short -timeout from an after handler") silently killed every child
# it asked about. Two timeouts that look alike are not alike: the one declared at
# `child start` is a contract the child was launched under, the one passed to
# `wait` is only how long the CALLER is prepared to stand there.
set t0 [clock milliseconds]
set c [child start -- $MT tcl $spin]
set r [child wait $c -timeout 800ms]
set dt [expr {[clock milliseconds] - $t0}]
check "child wait -timeout returns near time"   [expr {$dt > 500 && $dt < 4000}]
check "an expired wait bound says running"      [expr {[dict get $r status] eq "running"}]
check "a running child has no exit code yet"    [expr {[dict get $r exit] eq ""}]
check "a bounded wait does NOT kill the child"  [expr {[dict get [child info $c] running] == 1}]
# The shape must not fork for it -- same keys as every other result dict, with
# `exit` empty rather than a second shape hiding behind one verb.
check "the running dict keeps run's shape"      [expr {
    [lsort [dict keys $r]] eq {err exit out pid status truncated}}]
# Asking again, unbounded, still gets the real answer once it is over.
child kill $c
set r [child wait $c]
check "after killing, the same handle reports it" [expr {[dict get $r status] eq "killed"}]
child close $c

# AN ABSOLUTE MAXIMUM MUST NOT DEPEND ON BEING WAITED FOR. The deadline used to
# be checked only inside `child wait`, so a supervisor that polls `child info` --
# which is what a tool with a window has to do -- never triggered it. Caught by
# watching Life windows run 148 seconds under a 25-second cap. Asking "are you
# done?" is not waiting, and `-timeout` is a promise about the child.
set t0 [clock milliseconds]
set c [child start -timeout 600ms -- $MT tcl $spin]
while {[clock milliseconds] - $t0 < 6000} {
    if {![dict get [child info $c] running]} break
    after 100
}
set dt [expr {[clock milliseconds] - $t0}]
check "a cap is enforced by polling alone"   [expr {$dt > 400 && $dt < 4000}]
check "and the reason survives to the wait"  [expr {[dict get [child wait $c] status] eq "timeout"}]
child close $c

# A CAP HOLDS THROUGH EVERY DOOR, not just the one that got fixed first. The
# deadline was enforced at call sites, so each new way of observing a child was a
# fresh way to miss it: `child wait` had it, then `child info` needed it, then
# `child list` and `wait -any` still did not. Three wrongs about one idea. It now
# lives in one place, and this asserts every entrance to it.
#
# `child list` alone -- a supervisor that only ever asks "who is still here?".
set t0 [clock milliseconds]
set c [child start -timeout 600ms -- $MT tcl $spin]
while {[clock milliseconds] - $t0 < 6000} {
    child list
    if {![dict get [child info $c] running]} break
    after 100
}
check "listing alone enforces a cap" [expr {
    [clock milliseconds] - $t0 > 400 && [clock milliseconds] - $t0 < 4000}]
child close $c

# `wait -any` -- which blocked INFINITE and would have waited out a ten-minute
# cap forever. The outer `after` bound is NOT a substitute: if the cap is not
# enforced this check must fail, not hang the suite, so the elapsed time is what
# is asserted.
set t0 [clock milliseconds]
set c [child start -timeout 700ms -- $MT tcl $spin]
set d [child start -- $MT tcl $spin]
set woke [wait -any $c $d]
set dt [expr {[clock milliseconds] - $t0}]
check "wait -any returns when a cap fires" [expr {$dt > 500 && $dt < 5000}]
check "and it names the capped child"      [expr {$c in $woke}]
check "which reports status timeout"       [expr {[dict get [child wait $c] status] eq "timeout"}]
catch {child kill $d} ; catch {child wait $d} ; child close $d ; child close $c

# THE DOCUMENTED PATTERN, EXECUTED. `palette.md` shows a supervisor loop for a Tk
# tool; that loop used to kill every child it asked about, and no gate noticed
# because gates test code and this was advice. So the advice is now run here, and
# asserted to still be what the shipped doc says -- if either moves, this fails.
set ADVICE {if {[dict get [child wait $c -timeout 50ms] status] ne "running"} { harvest $c }}
# `string first`, not `string match`: in a match PATTERN the brackets all over
# this snippet are character classes, so the comparison silently tested
# something else entirely. Found by this check failing against a doc that plainly
# contained the line.
check "the palette still shows this loop" [expr {[string first $ADVICE [help palette]] >= 0}]
set c [child start -- $MT tcl $spin]
proc harvest {tok} { set ::harvested $tok }
set ::harvested ""
eval $ADVICE
check "the documented poll does not harvest a live child" [expr {$::harvested eq ""}]
check "and does not kill it either"                       [expr {
    [dict get [child info $c] running] == 1}]
child kill $c ; child wait $c
eval $ADVICE
check "the same loop harvests it once it is gone"         [expr {$::harvested eq $c}]
child close $c

# Two deadlines can apply; the earlier must win, or a child given 5s at start
# would get 30 more because someone waited generously. And when the START
# deadline is the one that expires, it still kills -- that half was always right.
set t0 [clock milliseconds]
set c [child start -timeout 600ms -- $MT tcl $spin]
set r [child wait $c -timeout 30s]
set dt [expr {[clock milliseconds] - $t0}]
check "the earlier of the two deadlines wins" [expr {$dt < 4000}]
check "and an expired START deadline kills"   [expr {[dict get $r status] eq "timeout"}]
child close $c

set c [child start -timeout 30s -- cmd /c echo quick]
set r [child wait $c]
check "a child that finishes early is unaffected" [expr {[dict get $r status] eq "ok"}]
check "and its output is still captured"          [string match "*quick*" [dict get $r out]]
child close $c

set c [child start -- cmd /c echo x]
check "child wait rejects an unknown option" [expr {
    [errcode_of {child wait $c -nope 1}] eq {MACHTELD CHILD usage}}]
check "child wait rejects a bare number"     [expr {
    [errcode_of {child wait $c -timeout 5}] eq {MACHTELD CHILD badvalue}}]
child close $c
# $spin is deleted at the end of the channel-mode block below, which also needs
# it. Removing it here made that block launch a script that no longer existed:
# the child died instantly with status "error", and its companion check -- which
# asserted only SPEED -- passed anyway. A timing assertion cannot tell "killed on
# time" from "died for the wrong reason".

# 7c. CHANNEL MODE: the child's pipes become Tcl channels, so it can be talked
# to while it runs. Everything here exists to answer one question -- does a child
# still get every supervision guarantee when its pipes belong to Tcl? -- because
# the transport alone was already available in stock Tcl (`open |cmd r+`), and
# the guarantees are the entire reason for doing this in C.
set ECHOW [file join $HERE _echoworker.tcl]
set f [open $ECHOW w]
puts $f {fconfigure stdin -translation lf
fconfigure stdout -translation lf -buffering line
while {[gets stdin l] >= 0} { if {$l eq "bye"} break ; puts "echo:$l" }}
close $f

set cc [child start -channels -- $MT tcl $ECHOW]
set ci [child info $cc]
check "channel mode reports three channels" [expr {
    [dict exists $ci stdin] && [dict exists $ci stdout] && [dict exists $ci stderr]}]
set cin [dict get $ci stdin] ; set cout [dict get $ci stdout]
puts $cin "hello" ; flush $cin
check "a channel-mode child answers"        [expr {[gets $cout] eq "echo:hello"}]
puts $cin "again" ; flush $cin
check "and keeps answering (persistent)"    [expr {[gets $cout] eq "echo:again"}]
check "it is a tracked child like any other" [expr {$cc in [child list]}]
child close $cc
check "child close releases the channels"   [expr {$cin ni [chan names]}]

# The result dict MUST NOT fork: run and child wait share one builder and the
# manifest derives `returns` from it, so channel mode keeps the documented shape
# with out/err simply empty rather than growing a second shape behind one verb.
set cc [child start -channels -- $MT tcl $ECHOW]
close [dict get [child info $cc] stdin]
set cr [child wait $cc]
check "channel mode keeps the result shape" [expr {[lsort [dict keys $cr]] eq
    {err exit out pid status truncated}}]
check "out and err are empty, not missing"  [expr {
    [dict get $cr out] eq "" && [dict get $cr err] eq ""}]
check "closing stdin gives the worker EOF"  [expr {[dict get $cr status] eq "ok"}]
child close $cc

# Capture and channels cannot both own a pipe.
check "-channels refuses -onout" [expr {
    [errcode_of {child start -channels -onout {puts} -- $MT tcl $ECHOW}] eq {MACHTELD CHILD usage}}]
check "-channels refuses -stdin" [expr {
    [errcode_of {child start -channels -stdin x -- $MT tcl $ECHOW}] eq {MACHTELD CHILD usage}}]

# THE GUARANTEES. Each of these is why this is C and not a Tcl idiom.
set t0 [clock milliseconds]
set cc [child start -channels -timeout 800ms -- $MT tcl $spin]
set cr [child wait $cc]
check "channel mode: -timeout still kills" [expr {[dict get $cr status] eq "timeout"}]
check "channel mode: and kills promptly"   [expr {[clock milliseconds]-$t0 < 4000}]
child close $cc

set hog [file join $HERE _hog.tcl]
set f [open $hog w] ; puts $f {proc hog {} { set L {} ; while {1} { lappend L [string repeat x 100000] } } ; hog} ; close $f
set t0 [clock milliseconds]
set cc [child start -channels -mem 64m -timeout 20s -- $MT tcl $hog]
set cr [child wait $cc]
check "channel mode: -mem still caps"      [expr {[dict get $cr status] ne "timeout"}]
check "channel mode: the cap bites fast"   [expr {[clock milliseconds]-$t0 < 10000}]
child close $cc
file delete -force $hog

# TREE-KILL, tested against a real grandchild. An earlier version of this check
# compared a process count that was zero both times and passed vacuously -- so
# the worker now reports the pid it spawned and the test asks `ps` about that
# exact process.
set TREEW [file join $HERE _treeworker.tcl]
set pidfile [file join $env(TEMP) mt_grandchild.txt]
file delete -force $pidfile
set f [open $TREEW w]
puts $f [string map [list @PIDFILE@ $pidfile] {
    set gp [exec cmd /c "ping -n 120 127.0.0.1" &]
    set fh [open {@PIDFILE@} w] ; puts $fh $gp ; close $fh
    after 120000}]
close $f
set cc [child start -channels -- $MT tcl $TREEW]
for {set i 0} {$i < 60 && ![file exists $pidfile]} {incr i} { after 100 }
set gp ""
if {[file exists $pidfile]} { set fh [open $pidfile] ; set gp [string trim [read $fh]] ; close $fh }
check "the worker really spawned a grandchild" [expr {
    $gp ne "" && ![catch {mtps info $gp}]}]
child kill $cc
child wait $cc
after 700
check "child kill takes the grandchild too"    [expr {$gp eq "" || [catch {mtps info $gp}]}]
child close $cc
file delete -force $pidfile $TREEW

# scope reaps a channel-mode child at the closing brace, like any other.
set outer3 [child list]
scope {
    child start -channels -- $MT tcl $ECHOW
    child start -channels -- $MT tcl $ECHOW
}
check "scope reaps channel-mode children" [expr {[child list] eq $outer3}]

# `--` ends the option scan, so a command may take -channels as its OWN argument.
set argw [file join $HERE _argw.tcl]
set f [open $argw w] ; puts $f {puts "ARGV=$argv"} ; close $f
set ar [run -- $MT tcl $argw -channels]
check "-- stops the -channels scan" [string match "*ARGV=-channels*" [dict get $ar out]]
file delete -force $argw $ECHOW $spin

# 8. wait -any returns whichever child finishes first
set a [::machteld::child start -- $MT tcl $CHILD sleep 200]
set b [::machteld::child start -- $MT tcl $CHILD sleep 8000]
check "wait -any first"     [expr {[::machteld::wait -any $a $b] eq $a}]
::machteld::child kill $b
::machteld::child close $a
::machteld::child close $b

# 9. scope tree-kills children born inside it, by the closing brace
set outer [::machteld::child list]
::machteld::scope {
    ::machteld::child start -- $MT tcl $CHILD sleep 8000
    ::machteld::child start -- $MT tcl $CHILD sleep 8000
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
# Driven by the MANIFEST rather than a hand-kept list: the manifest already
# knows every verb, so a new one is documented-or-caught automatically instead
# of quietly missing from a list nobody remembered to extend. That list had
# already gone stale -- it never learned about watch or manifest.
# Matched as a WHOLE WORD, not a substring. `*$v*` let `ps` pass on the strength
# of "steps", "helps" and "maps" -- a two-letter verb walks through a substring
# test unnoticed, which is the same vacuous-gate failure the registry scan had.
# A verb counts as documented when the doc uses it as a command: at the start of
# a line in a code block, or in backticks.
set drift {}
foreach v [dict keys [manifest]] {
    set used [expr {
        [regexp -line "^\\s*$v\\M" $pal] || [string match "*`$v`*" $pal] ||
        [string match "*`$v *" $pal]}]
    if {![llength [info commands ::machteld::$v]] || !$used} { lappend drift $v }
}
check "palette doc documents every verb the manifest knows" [expr {$drift eq ""}]
if {$drift ne ""} { puts "     undocumented: $drift" }
# EVERY VERB IS REACHABLE BY ITS BARE NAME. The palette is exposed by putting
# ::machteld on the GLOBAL namespace path, and a path is consulted only after a
# namespace's own commands -- so a verb sharing a name with a core Tcl command
# would not shadow it, it would be shadowed BY it: silently unreachable
# unqualified while Tcl's command answers to that name instead. The palette doc
# claims no verb shadows a core command; this puts the claim under test rather
# than under review, so the day someone adds `close` or `format` the suite says
# so instead of a script quietly calling the wrong command.
set unreachable {}
foreach v [dict keys [manifest]] {
    if {[namespace which -command $v] ne "::machteld::$v"} { lappend unreachable $v }
}
check "every palette verb is reachable by its bare name" [expr {$unreachable eq ""}]
if {$unreachable ne ""} { puts "     shadowed: $unreachable" }
set rdoc [run -- cmd /c echo hi]
check "run dict matches its documented shape" [expr {
    [dict exists $rdoc exit] && [dict exists $rdoc status] && [dict exists $rdoc out] &&
    [dict exists $rdoc err] && [dict exists $rdoc pid] && [dict exists $rdoc truncated]}]

# --- every doc is checked against the binary, not proofread -------------------
# The palette's poll loop was tested by hand, one snippet. This is the class: the
# docs make claims about verbs, subcommands and options, and until now nothing
# compared any of them to the manifest. Two lies were sitting in the bundle --
# `hash sha256 -file` in stdlib (an API that was planned and never shipped) and,
# in the other direction, `json encode -dict` which WORKS while the manifest
# denied it. Both were found by running this scanner for the first time, and the
# second turned out to be the manifest's fault, not the doc's.
#
# WHAT THIS CANNOT CHECK, stated so nobody mistakes green for proof: prose,
# measured numbers, and any snippet's behaviour. It checks names and options --
# the claims that go stale silently when code moves.
set docdrift {}
set docblocks 0
set M [manifest]
set VERBS [dict keys $M]
foreach topic [lsearch -all -inline -not -exact [lmap l [split [help] \n] {
        set t [string trim $l]
        expr {[regexp {^[a-z][a-z-]*$} $t] ? $t : [continue]}}] all] {
    set text [help $topic]
    set inblock 0 ; set block ""
    foreach line [split $text \n] {
        if {[regexp {^\s*```tcl\s*$} $line]} { set inblock 1 ; set block "" ; incr docblocks ; continue }
        if {[regexp {^\s*```} $line]} {
            # A block that does not parse is a doc nobody ran, and the most
            # basic lie there is: it cannot be what the author meant.
            if {$inblock && ![info complete $block]} {
                lappend docdrift "$topic: a tcl block is not syntactically whole"
            }
            set inblock 0 ; continue
        }
        if {!$inblock} continue
        append block $line "\n"
        set code [string trim [regsub {\s;#.*$} [string trim $line] ""]]
        if {$code eq "" || [string index $code 0] eq "#"} continue
        # EVERY COMMAND ON THE LINE, not just the first. `child list ; child reap
        # $c` slipped through the first version of this gate: it read `child
        # list`, found it valid, and never looked past the semicolon. A
        # break-test put a non-existent subcommand there and the suite stayed
        # green -- the same vacuous-gate shape as matching `ps` against "steps".
        # Bracketed commands count too: half the doc's lines wrap a verb in
        # `[...]`, and those were invisible as well.
        set cmds [split $code {;}]
        foreach {_ inner} [regexp -all -inline {\[([^\[\]]+)\]} $code] { lappend cmds $inner }
    foreach cmd $cmds {
        set toks [split [string trim $cmd]]
        set v [lindex $toks 0]
        if {$v ni $VERBS} continue
        set m [dict get $M $v]
        set rest [lrange $toks 1 end]
        set declared {}
        if {[dict exists $m options]} { set declared [dict get $m options] }
        if {[dict exists $m subcommands]} {
            set subs [dict keys [dict get $m subcommands]]
            set s [lindex $rest 0]
            if {$s ne "" && [regexp {^[a-z]+$} $s] && $s ni $subs} {
                lappend docdrift "$topic: `$v $s` is not a subcommand ($subs)"
            }
            if {[dict exists [dict get $m subcommands] $s]} {
                set sm [dict get $m subcommands $s]
                if {[dict exists $sm options]} { set declared [concat $declared [dict get $sm options]] }
            }
        }
        foreach tok $rest {
            if {$tok eq "--"} break        ;# past the guard it is the child's argv
            if {![regexp {^-[a-z]+$} $tok]} continue
            if {$tok ni $declared} { lappend docdrift "$topic: `$v ... $tok` is not an option ($declared)" }
        }
    }
    }
}
check "the shipped docs have tcl blocks to check" [expr {$docblocks > 20}]
check "no doc names a verb, subcommand or option that does not exist" [expr {$docdrift eq ""}]
foreach d $docdrift { puts "     $d" }

# --- the error-code registry is closed ---------------------------------------
# Creed 5: errors are part of the contract. A code you can trap must be a code
# that is documented, and a code that is documented must be one the C can throw.
# Both directions are checked against the SOURCE, so a new run_error() literal
# added in a hurry fails this test until contract.md names it.
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
    # Every .c, found rather than listed: the previous hardcoded four meant a new
    # source file was outside the gate until somebody remembered to add it, which
    # is the same way `ps` slipped through undocumented.
    set sources [lsort [glob -nocomplain -directory $SRC *.c]]
    # sqlite3.c is a vendored amalgamation, not ours, and raises nothing in this
    # registry; scanning it would only find false positives.
    set sources [lsearch -all -inline -not [lsearch -all -inline -not $sources *sqlite3.c] *sqlite3ext*]
    check "the registry scan covers every source file" [expr {[llength $sources] >= 4}]
    foreach f $sources {
        set fh [open $f r]; set text [read $fh]; close $fh
        foreach {_ d c} [regexp -all -inline {mt_error\(interp,\s*"([A-Z]+)",\s*"([a-z]+)"} $text] {
            dict set thrown $c 1 ; dict set domains $d 1
        }
        foreach {_ c} [regexp -all -inline {fail_code\(interp,\s*"([a-z]+)"} $text] {
            dict set thrown $c 1 ; dict set domains STORE 1
        }
        foreach {_ c} [regexp -all -inline {code = "([a-z]+)"} $text] { dict set thrown $c 1 }
        # the raw form, used by a file with no error helper of its own (json.c)
        set rawpat {Tcl_SetErrorCode\(interp,\s*"MACHTELD",\s*"([A-Z]+)",\s*"(\w+)"}
        foreach {_ d c} [regexp -all -inline $rawpat $text] {
            dict set thrown $c 1 ; dict set domains $d 1
        }
        # A single-domain file names its domain once, inside its own raiser, and
        # passes only the code: ps_error(interp, "denied", msg). Neither pattern
        # above sees either half of that -- the domain because the code beside it
        # is a variable, the code because the call is not spelled mt_error. When
        # ps.c landed, this scan therefore found nothing in it and all four
        # closure checks passed VACUOUSLY; the manifest cross-check is what
        # actually caught the two undocumented names. A gate that can be silently
        # emptied is worse than no gate, so both halves are read here.
        foreach {_ d} [regexp -all -inline \
            {Tcl_SetErrorCode\(interp,\s*"MACHTELD",\s*"([A-Z]+)"} $text] { dict set domains $d 1 }
        foreach {_ c} [regexp -all -inline {\w+_error\(interp,\s*"([a-z]+)"} $text] {
            dict set thrown $c 1
        }
    }

    # THE PRELUDE RAISES TOO, AND USED TO BE OUTSIDE THIS GATE ENTIRELY. The scan
    # read only src/*.c, so a Tcl verb's errors were invisible to it -- `mt`
    # raises {MACHTELD MT badvalue} and nothing here would ever have asked for it
    # to be documented. Creed 5 says errors are part of the contract; it does not
    # say "the errors written in C".
    #
    # Phase 0 of the stdlib plan closed the hole this used to merely count: the
    # prelude raised eleven bare `return -code error` with no code at all, which
    # put its two verbs of the time outside the registry entirely. It is a GATE now, not a
    # note, because the standard library lands in the prelude and an uncoded error
    # would otherwise become the norm there rather than the exception.
    set TCLSRC [file join $HERE .. tcl]
    set uncoded 0
    foreach f [lsort [glob -nocomplain -directory $TCLSRC *.tcl]] {
        set fh [open $f r]; set text [read $fh]; close $fh
        # `--` before the pattern: it begins with a dash, so regexp would
        # otherwise read it as an option and fail with "bad option".
        foreach {_ d c} [regexp -all -inline -- \
            {-errorcode\s+\{MACHTELD\s+([A-Z]+)\s+([a-z]+)\}} $text] {
            dict set thrown $c 1 ; dict set domains $d 1
        }
        # Fail's own body is the one legitimate `return -code error`, and it
        # carries an -errorcode; anything else without one is the defect.
        incr uncoded [regexp -all -- {return -code error (?!-errorcode)} $text]
        # The prelude's raiser, and a helper told its domain by the caller.
        foreach {_ d c} [regexp -all -inline -- {Fail\s+([A-Z]+)\s+([a-z]+)\s} $text] {
            dict set thrown $c 1 ; dict set domains $d 1
        }
        foreach {_ c} [regexp -all -inline -- {Fail\s+\$\w+\s+([a-z]+)\s} $text] {
            dict set thrown $c 1
        }
        # AND THE INVERSE SHAPE, which was a hole until `mirror` fell into it.
        # The two patterns above read `Fail DOMAIN code` and `Fail $domain code`
        # -- a literal domain with a literal code, or a passed domain. mirror.tcl
        # writes the third: a per-verb wrapper `MirrorFail {code msg}` whose body
        # is `Fail MIRROR $code $msg`, so the DOMAIN is a literal and the CODE is
        # the variable. Neither pattern saw either half, so `MIRROR` and all five
        # of its codes were outside the registry entirely while contract.md
        # documented them -- the gate failed loudly, which is the only reason
        # this is a note and not a silence.
        foreach {_ d} [regexp -all -inline -- {Fail\s+([A-Z]+)\s+\$} $text] {
            dict set domains $d 1
        }
        # The wrapper's CALL SITES carry the codes: `MirrorFail usage "..."`.
        # Matched on the `<Word>Fail <code>` shape rather than on a list of
        # wrapper names, so the next verb to grow one is inside the gate by
        # construction.
        foreach {_ c} [regexp -all -inline -- {\m[A-Z]\w*Fail\s+([a-z]+)\s} $text] {
            dict set thrown $c 1
        }
    }
    check "every prelude error carries an errorcode" [expr {$uncoded == 0}]
    if {$uncoded != 0} { puts "     $uncoded uncoded 'return -code error' remain" }

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

# A watch must be RECORDING by the time start returns, not merely have a thread.
# Creating a file with no pause at all is the only way to see the difference:
# before this was fixed the event was missed outright, roughly two runs in five,
# and the failure mode was silence rather than an error.
set immediate [file join $WD immediate.txt]
set f [open $immediate w] ; puts $f now ; close $f
after 400
check "a change made immediately after start is not missed" [expr {
    [llength [watch read $w]] >= 1}]

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

# --- ps: the machine's processes, not just our own children ------------------
# `child list` enumerates what machteld launched; ps enumerates what the machine
# is running. That distinction is the whole reason the verb exists, so it is the
# first thing checked: processes we did NOT start have to be visible.

set PROCS [mtps list]
check "mtps list returns many processes" [expr {[llength $PROCS] > 20}]
check "mtps list dwarfs our own child list" [expr {[llength $PROCS] > [llength [child list]] + 20}]

set self {}
foreach p $PROCS { if {[dict get $p pid] == [pid]} { set self $p ; break } }
check "mtps list contains our own pid" [expr {$self ne ""}]
check "ps row carries the full shape" [expr {[lsort [dict keys $self]] eq
    {access cpu exe mem name pid ppid private started threads}}]
check "our own row is readable" [expr {[dict get $self access] == 1}]
check "our own exe is this binary" [expr {
    [file normalize [dict get $self exe]] eq [file normalize [info nameofexecutable]]}]
check "our own start time is sane" [expr {
    [dict get $self started] > 1700000000 && [dict get $self started] <= [clock seconds] + 2}]

# info and list must agree about the same process: two code paths, one answer.
set inf [mtps info [pid]]
check "mtps info agrees with mtps list" [expr {
    [dict get $inf pid]  == [dict get $self pid] &&
    [dict get $inf name] eq [dict get $self name] &&
    [dict get $inf exe]  eq [dict get $self exe]}]

# A process we cannot open still appears, and its unreadable fields are EMPTY
# rather than 0 -- "we were denied" and "genuinely zero" must not look alike, or
# a task manager silently reports system processes as using no memory. Under an
# elevated token there may be no such row, so the shape is asserted only if one is.
set unread {}
foreach p $PROCS { if {[dict get $p access] == 0} { set unread $p ; break } }
if {$unread ne ""} {
    check "denied row still has its snapshot fields" [expr {
        [dict get $unread pid] ne "" && [dict get $unread name] ne ""}]
    check "denied row leaves details empty, not zero" [expr {
        [dict get $unread mem] eq "" && [dict get $unread cpu] eq "" &&
        [dict get $unread exe] eq ""}]
} else {
    puts "skip ps denied-row shape (elevated: every process was readable)"
}

check "cpu reads as an integer ms count" [string is integer -strict [dict get $self cpu]]

# mtps kills by pid. The only process a test may safely kill is one it started
# itself -- which is also the sharpest check, since child can confirm the death.
set victim [child start -- $MT tcl $CHILD sleep 8000]
set vpid   [dict get [child info $victim] pid]
check "ps sees a process we launched" [expr {[dict get [mtps info $vpid] pid] == $vpid}]
check "mtps kill reports one killed" [expr {[mtps kill $vpid] == 1}]
check "mtps kill actually ended it" [expr {
    [dict get [child wait $victim] status] in {killed error}}]
child close $victim

# -tree reaches past the root: cmd /c spawns the sleeper as its own child, so the
# tree is two deep and a flat kill would leave the leaf running.
set root [child start -- cmd /c "$MT tcl $CHILD sleep 8000"]
after 400
set rpid [dict get [child info $root] pid]
set n [mtps kill $rpid -tree]
check "mtps kill -tree killed the root and its child" [expr {$n >= 2}]
catch {child kill $root} ; catch {child wait $root} ; child close $root

# A process that exited on its own, whose pid we still hold a handle to, must
# report `notfound` -- not `denied`. TerminateProcess fails with
# ERROR_ACCESS_DENIED for a corpse exactly as it does for a protected process, so
# a naive reading tells the user to re-run elevated over something that simply
# finished. The tasks tool showed that advice until the exit code was consulted.
set gone [child start -- $MT tcl $CHILD exitcode 0]
set gpid [dict get [child info $gone] pid]
child wait $gone
check "mtps kill of an exited process => notfound, not denied" [expr {
    [errcode_of {mtps kill $gpid}] eq {MACHTELD MTPS notfound}}]
child close $gone

# the error contract
check "mtps info on a missing pid => notfound" [expr {
    [errcode_of {mtps info 4000000}] eq {MACHTELD MTPS notfound}}]
check "mtps kill on a missing pid => notfound" [expr {
    [errcode_of {mtps kill 4000000}] eq {MACHTELD MTPS notfound}}]
check "ps on a non-integer pid => badvalue" [expr {
    [errcode_of {mtps info notanumber}] eq {MACHTELD MTPS badvalue}}]
check "ps on an out-of-range pid => badvalue" [expr {
    [errcode_of {mtps info 99999999999}] eq {MACHTELD MTPS badvalue}}]
check "mtps kill of the system process => denied" [expr {
    [errcode_of {mtps kill 4}] eq {MACHTELD MTPS denied}}]
check "mtps kill with an unknown option => usage" [expr {
    [errcode_of {mtps kill [pid] -nope}] eq {MACHTELD MTPS usage}}]

# --- watch info / pty info: observe without consuming -------------------------
# The cockpit needs to show what is pending. `watch read` DRAINS and `pty read`
# CONSUMES, so building a monitor on either would steal from the program being
# monitored. These two report the same facts and take nothing, which is the only
# property that makes a monitor honest -- so it is tested directly rather than
# assumed from the implementation.
set WD2 [file join $env(TEMP) mt_info_suite]
file delete -force $WD2 ; file mkdir $WD2
set w2 [watch start $WD2 -recursive]
set fh [open [file join $WD2 probe.txt] w] ; puts $fh hello ; close $fh
after 400

set wi [watch info $w2]
check "watch info shape" [expr {[lsort [dict keys $wi]] eq
    {armed dir dropped pending recursive token}}]
check "watch info reports the directory" [expr {
    [file normalize [dict get $wi dir]] eq [file normalize $WD2]}]
check "watch info reports -recursive"    [expr {[dict get $wi recursive] == 1}]
check "watch info reports armed"         [expr {[dict get $wi armed] == 1}]
set p0 [dict get $wi pending]
check "watch info sees queued events"    [expr {$p0 > 0}]
# The property that matters: asking repeatedly must not empty the queue.
foreach _ {1 2 3 4 5} { watch info $w2 }
check "watch info does not consume"      [expr {[dict get [watch info $w2] pending] == $p0}]
check "the events are still readable"    [expr {[llength [watch read $w2]] >= 1}]
check "watch info sees the drain"        [expr {[dict get [watch info $w2] pending] == 0}]
check "watch info on a dead token"       [expr {
    [errcode_of {watch info nosuch#9}] eq {MACHTELD WATCH nohandle}}]
watch close $w2 ; file delete -force $WD2

set p2 [pty spawn -- cmd]
after 400
set pi [pty info $p2]
check "pty info shape" [expr {[lsort [dict keys $pi]] eq {pending pid running token}}]
check "pty info reports a pid"      [expr {[dict get $pi pid] > 0}]
# NOT asserted as 1: this suite runs with stdio redirected, so a ConPTY child
# cannot route and `cmd` exits at once -- the same sandbox limit the pty section
# above already records. What matters is that the field is a real boolean derived
# from the process, not a placeholder.
check "pty info reports running as a boolean" [expr {[dict get $pi running] in {0 1}}]
set b0 [dict get $pi pending]
foreach _ {1 2 3} { pty info $p2 }
check "pty info does not consume"   [expr {[dict get [pty info $p2] pending] == $b0}]
check "pty info on a dead token"    [expr {
    [errcode_of {pty info nosuch#9}] eq {MACHTELD PTY nohandle}}]
pty close $p2

# --- log: say what happened, where someone can read it later -----------------
set LGF [file join $env(TEMP) mt_log_suite.txt]
proc logfile {} { set c [open $::LGF r] ; set t [read $c] ; close $c ; return $t }
proc logreset {} {
    # Switching sinks first is not tidiness: Windows refuses to delete a file
    # that is still open, so this only works because `log` closes the channel it
    # owns when the sink changes. If it leaked, every reset below would fail.
    catch {log configure -channel stderr}
    file delete -force $::LGF
    log configure -file $::LGF -level debug
}

logreset
log info "hello"
# The reset above proves it, but state it as a claim: an owned file channel is
# released when the sink changes, or it would be locked for the process's life.
log configure -channel stderr
check "switching sinks releases the file" [expr {[catch {file delete -force $LGF}] == 0}]
log configure -file $LGF -level debug
log info "hello"
check "a line carries an ISO timestamp" [regexp {^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3} } [logfile]]
check "a line carries the level"        [string match "*INFO *"  [logfile]]
check "a line carries the message"      [string match "*hello*"  [logfile]]

logreset
log info "started" pid 4812 dir /tmp
check "pairs render as key=value" [expr {
    [string match "*pid=4812*" [logfile]] && [string match "*dir=/tmp*" [logfile]]}]
logreset
log info "spaced" path "C:/some path/x.txt"
check "a value with spaces is quoted"  [string match {*path="C:/some path/x.txt"*} [logfile]]
logreset
log info "empty" k ""
check "an empty value is visibly empty" [string match {*k=""*} [logfile]]

# A dangling key must not lose the message: the caller made a mistake, but a log
# line is the worst place to raise about it.
logreset
log warn "half a pair" a 1 dangling
check "a dangling key is marked"        [string match "*dangling=?*" [logfile]]
check "a dangling key keeps the message" [string match "*half a pair*" [logfile]]
check "a dangling key keeps the good pairs" [string match "*a=1*" [logfile]]

# Levels
logreset
log configure -level warn
log debug "no" ; log info "no" ; log warn "yes-warn" ; log error "yes-error"
check "below the level is dropped" [expr {![string match "*no*" [logfile]]}]
check "at the level is kept"       [string match "*yes-warn*"  [logfile]]
check "above the level is kept"    [string match "*yes-error*" [logfile]]
logreset
log configure -level off
log error "silenced"
check "off silences even error" [expr {[string trim [logfile]] eq ""}]

# -file APPENDS. A tool restarting must not erase the record of why it restarted.
logreset
log info "first run"
log configure -file $LGF
log info "second run"
check "reconfiguring the same file appends" [expr {
    [string match "*first run*" [logfile]] && [string match "*second run*" [logfile]]}]

# THE PROPERTY THE WHOLE VERB RESTS ON: a failed write never throws. A process
# with no standard channels -- a GUI host, a detached child -- makes `puts
# stderr` raise, and a log
# call that can throw kills the program at whatever arbitrary point it was asked
# to record something.
logreset
set dead [open [file join $env(TEMP) mt_log_dead.txt] w]
log configure -channel $dead
close $dead
set before [dict get [log configure] dropped]
check "logging to a dead channel does not throw" [expr {[catch {log error "into the void"}] == 0}]
check "logging to a dead channel does not throw twice" [expr {[catch {log warn "again"}] == 0}]
check "the drops are counted"  [expr {[dict get [log configure] dropped] == $before + 2}]
check "configure reports what was lost" [expr {[dict get [log configure] dropped] > 0}]

# configure reads back
log configure -channel stderr -level info
set lc [log configure]
check "configure returns a dict"        [expr {[lsort [dict keys $lc]] eq {channel dropped file level}}]
check "configure reports the level"     [expr {[dict get $lc level] eq "info"}]
check "configure reports the channel"   [expr {[dict get $lc channel] eq "stderr"}]

# the error contract -- and the split that matters: a bad LEVEL is the author's
# mistake (badvalue), an unknown OPTION is a usage error.
check "an unknown level => badvalue"     [expr {
    [errcode_of {log configure -level shouty}] eq {MACHTELD LOG badvalue}}]
check "an unknown channel => badvalue"   [expr {
    [errcode_of {log configure -channel nosuch}] eq {MACHTELD LOG badvalue}}]
check "an unwritable file => oserror"    [expr {
    [errcode_of {log configure -file [file join $env(TEMP) nosuchdir_zzz x.log]}]
        eq {MACHTELD LOG oserror}}]
check "an unknown option => usage"       [expr {
    [errcode_of {log configure -nope 1}] eq {MACHTELD LOG usage}}]
check "an option without a value => usage" [expr {
    [errcode_of {log configure -level}] eq {MACHTELD LOG usage}}]
check "an unknown subcommand => usage"   [expr {
    [errcode_of {log shout "hi"}] eq {MACHTELD LOG usage}}]
check "a level with no message => usage" [expr {
    [errcode_of {log info}] eq {MACHTELD LOG usage}}]
file delete -force $LGF [file join $env(TEMP) mt_log_dead.txt]

# --- worker: the far side of a channel-mode child -----------------------------
# Registration and introspection run in THIS process; dispatch is exercised for
# real, over a channel-mode child, because a worker that only works when called
# directly has not been tested as a worker at all.
worker on wt_double {n}                     { expr {$n * 2} }
worker on wt_greet  {name {greeting Hello}} { return "$greeting, $name!" }

set wops [worker ops]
check "worker ops lists what was registered" [expr {
    [dict exists $wops wt_double] && [dict exists $wops wt_greet]}]
check "worker ops reports a plain parameter" [expr {[dict get $wops wt_double] eq "n"}]
# `info args` returns parameter NAMES only -- for {name {greeting Hello}} it says
# `name greeting`, with the default nowhere in sight. The first version of the
# dispatcher checked the length of that and so treated every optional parameter
# as required; `info default` is the only way to ask. This asserts the defaults
# survive into the reported schema.
check "worker ops reports a default too"     [expr {
    [dict get $wops wt_greet] eq {name {greeting Hello}}}]
check "worker on rejects a bad call"  [expr {
    [errcode_of {worker on onlyone}] eq {MACHTELD WORKER usage}}]
check "worker on rejects an empty op" [expr {
    [errcode_of {worker on {} {} {}}] eq {MACHTELD WORKER badvalue}}]
check "worker rejects an unknown subcommand" [expr {
    [errcode_of {worker nosuch}] eq {MACHTELD WORKER usage}}]

# WHERE A HANDLER BODY LIVES. In the namespace it was written in, so it calls
# that namespace's procs by bare name like every other line in the file. It used
# to be compiled into ::machteld regardless of where `worker on` was called,
# which meant a tool with a namespace of its own got `invalid command name` for
# its OWN helper -- and not at definition time but at request time, arriving as a
# failure reply from another process, which is the latest and least legible place
# to learn about a scope mistake.
namespace eval ::wtns {
    namespace path ::machteld
    proc helper {x} { return "helped:$x" }
    worker on wt_ns  {v} { helper $v }
    worker on wt_pal {v} { hash sum sha256 $v }
}
# Through `valof`, because if this regresses the handler is not there to call:
# a bare call would abort the run at this line rather than fail this check.
check "a handler is defined where it was written" [expr {
    [info procs ::wtns::WorkerOp_wt_ns] eq "::wtns::WorkerOp_wt_ns"}]
check "a handler resolves its own namespace's procs" [expr {
    [valof {::wtns::WorkerOp_wt_ns zz}] eq "helped:zz"}]
check "a handler still resolves palette verbs" [expr {
    [valof {::wtns::WorkerOp_wt_pal zz}] eq [hash sum sha256 zz]}]

# Dispatch, over a real channel-mode child.
set WSRC [file join $HERE _worker_fixture.tcl]
set f [open $WSRC w]
puts $f {worker on double {n}                     { expr {$n * 2} }
worker on greet  {name {greeting Hello}} { return "$greeting, $name!" }
worker on digest {path {alg sha256}}     { hash file $alg $path }
worker on boom   {}                      { error "handler exploded" }
worker on coded  {}                      { hash sum nosuchalg x }
worker serve}
close $f

set wc [child start -channels -- $MT tcl $WSRC]
set wi [child info $wc]
set win [dict get $wi stdin] ; set wout [dict get $wi stdout]
proc wask {req} { puts $::win [json encode $req] ; flush $::win ; return [json decode [gets $::wout]] }
# A reply is either {ok 1 result ...} or {ok 0 code ... msg ...}. Reaching for
# `result` on a failure reply raises "key not known in dictionary", which ABORTS
# the run instead of failing a check -- so a regression that flips a reply to
# failure reports as a crash mid-block and every later check silently never runs.
# Every assertion below goes through this instead.
proc wres {r} { expr {[dict exists $r result] ? [dict get $r result] : ""} }

set wr [wask {id 1 op double n 21}]
check "a request gets its answer"      [expr {[dict get $wr ok] == 1 && [wres $wr] == 42}]
check "the reply carries the id back"  [expr {[dict get $wr id] == 1}]
check "an omitted parameter defaults"  [expr {
    [wres [wask {id 2 op greet name World}]] eq "Hello, World!"}]
check "a supplied parameter wins"      [expr {
    [wres [wask {id 3 op greet name World greeting Hi}]] eq "Hi, World!"}]
set wr [wask {id 4 op greet}]
check "a missing required parameter is named" [expr {
    [dict get $wr ok] == 0 && [dict get $wr code] eq {MACHTELD WORKER usage} &&
    [string match "*name*" [dict get $wr msg]]}]
set wr [wask {id 5 op nosuch}]
check "an unknown op is reported, not fatal" [expr {
    [dict get $wr ok] == 0 && [dict get $wr code] eq {MACHTELD WORKER notfound}}]

# THE ERROR CONTRACT CROSSES THE PROCESS BOUNDARY. A code that arrives as prose
# has stopped being part of the contract, so this checks the code itself, not the
# message.
set wr [wask {id 6 op coded}]
check "a coded failure keeps its errorcode" [expr {
    [dict get $wr code] eq {MACHTELD HASH badvalue}}]
set wr [wask {id 7 op boom}]
check "a plain error still reports failure" [expr {[dict get $wr ok] == 0}]

# The worker must really do the work, so compare against this process computing
# the same thing -- a dispatcher that echoed a plausible value would pass every
# check above.
set wpath [file join $HERE .. README.md]
set wr [wask [dict create id 8 op digest path $wpath]]
check "the worker's result matches in-process" [expr {
    [wres $wr] eq [hash file sha256 $wpath]}]

# A malformed line must not kill the worker: dying on a typo costs the director a
# death, a requeue and a respawn to report it.
puts $win "this is not json" ; flush $win
set wr [json decode [gets $wout]]
check "a garbage line is answered, not fatal" [expr {
    [dict get $wr ok] == 0 && [dict get $wr code] eq {MACHTELD WORKER parse}}]
check "the worker survives garbage"           [expr {
    [wres [wask {id 9 op double n 5}]] == 10}]
child close $wc
file delete -force $WSRC

# --- pool: persistent workers over the event loop -----------------------------
# The spike (spike/pool) attacked this design on stock Tcl; these are the same
# hazards against the real verb, where workers are supervised children rather
# than bare pipes.
set PW [file join $HERE _poolworker.tcl]
set f [open $PW w]
puts $f {worker on echo  {text}        { return $text }
worker on big   {bytes}       { return [string repeat x $bytes] }
worker on noise {lines}       { puts stderr [string repeat "diagnostic " $lines] ; return ok }
worker on boom  {}            { hash sum nosuchalg x }
worker on die   {}            { exit 9 }
worker serve}
close $f

proc pres {r} { expr {[dict exists $r result] ? [dict get $r result] : ""} }
# `pool wait` RAISES {MACHTELD POOL timeout} when a pool wedges, and an uncaught
# raise aborts the run: the check that would have named the regression never
# reports, and every check after it silently never runs. Removing the stderr
# drain does exactly that -- workers block mid-write on a full pipe and the wait
# times out -- so a regression there used to stop the suite dead instead of
# failing a line. Every wait below goes through this and yields {} on timeout,
# which fails the result-count check cleanly and lets the rest of the suite run.
proc pwait {args} {
    if {[catch {pool wait {*}$args} r]} { return {} }
    return $r
}

# Correctness, and the ordering guarantee.
set pp [pool create -width 6 -- $MT tcl $PW]
set pitems {}
for {set i 0} {$i < 40} {incr i} { lappend pitems [dict create op echo text "item-$i"] }
pool submit $pp $pitems
set pr [pwait $pp -timeout 90s]
check "pool returns every result"    [expr {[llength $pr] == 40}]
set ordered 1
for {set i 0} {$i < 40} {incr i} {
    if {[pres [lindex $pr $i]] ne "item-$i"} { set ordered 0 }
}
# Replies arrive in whatever order workers finish, which is not an order anyone
# asked for. The id is the item's index, so the answer comes back aligned.
check "results come back in submission order" $ordered
check "no worker died in the happy path" [expr {[dict get [pool info $pp] dead] == 0}]
pool close $pp

# THE PIPE-BUFFER HAZARD. A Windows pipe holds a few KB; replies far larger than
# that must not wedge either end. This was the risk named as most likely to sink
# the design, so it is checked against the real verb and not only in the spike.
set pp [pool create -width 4 -- $MT tcl $PW]
set pitems {}
foreach n {1 2 3 4} { lappend pitems [dict create op big bytes [expr {$n * 1048576}]] }
pool submit $pp $pitems
set pr [pwait $pp -timeout 90s]
check "multi-megabyte replies arrive"  [expr {[llength $pr] == 4}]
check "and arrive intact"              [expr {
    [lsort -integer [lmap x $pr {string length [pres $x]}]] eq
    {1048576 2097152 3145728 4194304}}]
pool close $pp

# STDERR. This hazard is NEW relative to the spike: stock Tcl let a subprocess
# inherit stderr to the console, but a channel-mode child's stderr is a real
# pipe, and a pipe nobody reads fills and blocks the worker mid-write -- a hang,
# not an error. The pool drains it and keeps the tail.
set pp [pool create -width 3 -- $MT tcl $PW]
set pitems {}
for {set i 0} {$i < 12} {incr i} { lappend pitems [dict create op noise lines 3000] }
pool submit $pp $pitems
set pr [pwait $pp -timeout 90s]
check "a worker spewing stderr does not wedge the pool" [expr {[llength $pr] == 12}]
check "and its diagnostics are kept for inspection"     [expr {
    [string match "*diagnostic*" [dict get [pool info $pp] stderr]]}]
pool close $pp

# Errors cross the process boundary with their code, and the pool passes them
# through rather than flattening them to prose.
set pp [pool create -width 2 -- $MT tcl $PW]
pool submit $pp [list [dict create op boom] [dict create op echo text fine]]
set pr [pwait $pp -timeout 60s]
check "a failing item reports failure"  [expr {[dict get [lindex $pr 0] ok] == 0}]
check "with the worker's own errorcode" [expr {
    [dict get [lindex $pr 0] code] eq {MACHTELD HASH badvalue}}]
check "a healthy item beside it still succeeds" [expr {[pres [lindex $pr 1]] eq "fine"}]
pool close $pp

# A worker dying mid-item: detected, its item requeued, and a poison item capped
# rather than looping forever.
set pp [pool create -width 3 -maxtries 2 -- $MT tcl $PW]
set pitems {}
for {set i 0} {$i < 10} {incr i} { lappend pitems [dict create op echo text "e$i"] }
lappend pitems [dict create op die]
pool submit $pp $pitems
set pr [pwait $pp -timeout 90s]
set pinfo [pool info $pp]
check "the pool survives a worker dying"  [expr {[llength $pr] >= 10}]
check "it noticed the death"              [expr {[dict get $pinfo dead] >= 1}]
check "and requeued the item"             [expr {[dict get $pinfo requeued] >= 1}]
check "a poison item does not loop"       [expr {[dict get $pinfo dead] <= 30}]
check "the healthy items all came back"   [expr {
    [llength [lsearch -all -inline -not -exact [lmap x $pr {pres $x}] ""]] >= 10}]
pool close $pp

# SUPERVISION -- the reason this is over `child start -channels` and not `open
# |cmd r+`. Pool workers are ordinary children, so scope reaps them.
set outer4 [child list]
scope { pool create -width 3 -- $MT tcl $PW }
check "scope reaps a pool's workers" [expr {[child list] eq $outer4}]

# No orphans after an explicit close.
set before4 [llength [child list]]
set pp [pool create -width 5 -- $MT tcl $PW]
check "workers are tracked children"  [expr {[llength [child list]] == $before4 + 5}]
pool close $pp
check "close leaves no workers behind" [expr {[llength [child list]] == $before4}]

# the error contract
check "pool rejects an unknown subcommand" [expr {
    [errcode_of {pool nosuch}] eq {MACHTELD POOL usage}}]
check "pool rejects a bad token"           [expr {
    [errcode_of {pool info nosuch#9}] eq {MACHTELD POOL nohandle}}]
check "pool create rejects a bad width"    [expr {
    [errcode_of {pool create -width 0 -- $MT tcl $PW}] eq {MACHTELD POOL badvalue}}]
check "pool create needs a command"        [expr {
    [errcode_of {pool create -width 2 --}] eq {MACHTELD POOL usage}}]
check "pool submit needs an op per item"   [expr {
    [errcode_of {
        set q [pool create -width 1 -- $MT tcl $PW]
        catch {pool submit $q [list [dict create noop 1]]} m o
        pool close $q
        return -options $o $m}] eq {MACHTELD POOL badvalue}}]
file delete -force $PW

# --- pmap: a pool in one call, with the error contract intact -----------------
set PMW [file join $HERE _pmapworker.tcl]
set f [open $PMW w]
puts $f {worker on digest {path {alg sha256}} { hash file $alg $path }
worker on echo   {text}              { return $text }
worker on boom   {}                  { hash sum nosuchalg x }
worker on plain  {}                  { error "just an error" }
worker serve}
close $f

# The real work, checked against this process computing the same thing -- a pmap
# that returned plausible strings would pass every structural check below.
set pmpaths [lsort [glob -nocomplain [file join $HERE .. src *.c]]]
set pmreqs [lmap pp $pmpaths {list op digest path $pp}]
set pmgot [pmap $pmreqs -width 6 -timeout 120s -- $MT tcl $PMW]
check "pmap returns one result per request" [expr {[llength $pmgot] == [llength $pmpaths]}]
check "pmap results match in-process"       [expr {
    $pmgot eq [lmap pp $pmpaths {hash file sha256 $pp}]}]
check "pmap returns plain results"          [expr {
    [string length [lindex $pmgot 0]] == 64}]

# ORDER. Results follow submission, not completion, so which answer is which does
# not depend on which worker happened to finish first.
set pmr [pmap [lmap i {0 1 2 3 4 5 6 7} {list op echo text "v$i"}] -width 4 -timeout 60s -- $MT tcl $PMW]
check "pmap preserves submission order" [expr {$pmr eq {v0 v1 v2 v3 v4 v5 v6 v7}}]

# THE POINT OF THE VERB: a worker's failure is re-raised carrying THE WORKER'S
# OWN errorcode. Raised in one process, trappable in another, unflattened -- if
# this were relabelled {MACHTELD PMAP ...} the only useful thing about it would
# be gone.
set pmc [errcode_of {pmap [list {op echo text a} {op boom} {op echo text c}] \
                        -width 2 -timeout 60s -- $MT tcl $PMW}]
check "a worker failure keeps its own errorcode" [expr {$pmc eq {MACHTELD HASH badvalue}}]

# A handler raising a plain `error` has errorcode NONE, which is not something a
# caller can trap on; it becomes a pmap failure rather than being passed through
# as a code that means nothing.
set pmc [errcode_of {pmap [list {op plain}] -width 1 -timeout 60s -- $MT tcl $PMW}]
check "an uncoded worker error becomes a pmap failure" [expr {$pmc eq {MACHTELD PMAP failed}}]

# -raw opts out of raising, for a caller that wants partial success.
set pmraw [pmap [list {op echo text ok} {op boom}] -raw -width 2 -timeout 60s -- $MT tcl $PMW]
check "-raw returns replies rather than raising" [expr {[llength $pmraw] == 2}]
check "-raw shows which item failed"             [expr {
    [dict get [lindex $pmraw 0] ok] == 1 && [dict get [lindex $pmraw 1] ok] == 0}]

# THE POOL IS ALWAYS CLOSED, including on the raising path. Four calls with three
# chances to leak a pool of live processes is the reason this verb exists at all.
set pmbefore [llength [child list]]
catch {pmap [list {op boom}] -width 4 -timeout 60s -- $MT tcl $PMW}
check "pmap closes its pool even when it raises" [expr {[llength [child list]] == $pmbefore}]
set pmgot [pmap [list {op echo text x}] -width 3 -timeout 60s -- $MT tcl $PMW]
check "and on the happy path"                    [expr {[llength [child list]] == $pmbefore}]

check "an empty request list does no work" [expr {[pmap {} -width 2 -- $MT tcl $PMW] eq ""}]

# pmap's OWN failures are PMAP, because the domain is the verb you called.
check "pmap rejects a missing command"  [expr {
    [errcode_of {pmap {{op echo text a}} -width 2 --}] eq {MACHTELD PMAP usage}}]
check "pmap rejects an unknown option"  [expr {
    [errcode_of {pmap {{op echo text a}} -nope 1 -- $MT tcl $PMW}] eq {MACHTELD PMAP usage}}]
check "pmap rejects a dangling option"  [expr {
    [errcode_of {pmap {{op echo text a}} -width}] eq {MACHTELD PMAP usage}}]
check "a bad width surfaces as a pmap failure" [expr {
    [lrange [errcode_of {pmap {{op echo text a}} -width 0 -- $MT tcl $PMW}] 0 1] eq {MACHTELD PMAP}}]
file delete -force $PMW

# --- run -inherit: the child gets OUR stdio, not a pipe -----------------------
# A front door must hand the terminal to what it runs: colours, progress bars, a
# pager, Ctrl-C. Every other launch path here exists to CAPTURE, which is the
# opposite. This needed no change in the launcher -- it duplicates whichever
# handles it is given and restricts inheritance to exactly those, so handing it
# our own console handles gives the child the console with the job object, the
# tree-kill and the deadline all still in force.
check "run declares -inherit" [expr {"-inherit" in [dict get [manifest] run options]}]

# --- -arg0: the child's name need not be its path ----------------------------
# `wj_launch` has always passed the executable and the command line to
# CreateProcessW SEPARATELY -- lpApplicationName and lpCommandLine -- so which
# file runs and what it calls itself were independent from the first day. Only
# a way to SAY so was missing, and the front door refused the one workspace tool
# that needs it (`make`, vendored as mingw32-make.exe) rather than run it under
# the wrong name.
#
# Declared by the SHARED parser, so every spawning verb claims it -- and a claim
# the manifest makes is one the verb has to honour.
foreach {v where} {run {run options}
                   child {child subcommands start options}
                   detach {detach options}
                   pty {pty subcommands spawn options}} {
    check "$v declares -arg0" [expr {"-arg0" in [dict get [manifest] {*}$where]}]
}

# THE RENAME IS ONLY OBSERVABLE FROM INSIDE THE CHILD, and Tcl cannot see its
# own argv[0]: `info nameofexecutable` is the exe path however it was invoked,
# and `$argv0` is the script. So this needs a child that reports its own name,
# and `bash -c {echo $0}` is the one the workspace vendors. Skipped rather than
# failed where there is no workspace -- the suite must pass on a machine that
# has never seen one, which is why the z-agreement lives in its own file.
set A0BASH ""
catch { set A0BASH [dict get [front env bash] exe] }
if {$A0BASH ne "" && [file exists $A0BASH]} {
    set plain [string trim [dict get [run -timeout 30s -- $A0BASH -c {echo $0}] out]]
    set named [string trim [dict get [run -timeout 30s -arg0 MTFAKE0 -- $A0BASH -c {echo $0}] out]]
    check "without -arg0 the child sees its own path" [expr {$plain ne "MTFAKE0" && $plain ne ""}]
    check "with -arg0 the child sees the name given"  [expr {$named eq "MTFAKE0"}]
    # A RENAME, NEVER A REDIRECTION. `-arg0` is applied AFTER the program is
    # resolved from argv[0] as written, so it cannot change WHICH file runs.
    # Getting that order wrong would turn a rename into a PATH lookup for
    # something else entirely -- the one thing this workspace refuses everywhere
    # else -- so naming a program that does not exist must still fail.
    check "-arg0 does not choose the program" [expr {
        [errcode_of {run -arg0 bash -- no_such_program_zzz.exe}] eq {MACHTELD RUN notfound}}]
} else {
    puts "     (no workspace bash: the -arg0 behaviour checks need one)"
}

# PROVED, NOT ASSUMED. Asserting "out is empty" would also pass if the child
# never ran. So an inner machteld runs the child with -inherit, and the OUTER
# one captures: the marker can only reach this pipe by flowing through the inner
# process's inherited stdout. It also keeps the child's output off this suite's
# own stdout, which would otherwise interleave with the results.
set inner [file join $HERE _inherit_fixture.tcl]
set fh [open $inner w]
puts $fh {run -inherit -- cmd /c "echo MARKER-THROUGH-INHERITED-STDOUT"}
close $fh
set r [run -timeout 30s -- $MT tcl $inner]
check "an inherited child's output reaches our stdout" [expr {
    [string match "*MARKER-THROUGH-INHERITED-STDOUT*" [dict get $r out]]}]
file delete -force $inner

set r [run -inherit -- cmd /c "exit 7"]
check "-inherit still reports the exit code"  [expr {[dict get $r exit] == 7}]
check "-inherit captures nothing"             [expr {[dict get $r out] eq "" && [dict get $r err] eq ""}]
check "-inherit keeps the documented shape"   [expr {
    [lsort [dict keys $r]] eq {err exit out pid status truncated}}]

# Supervision is not traded away for the terminal: the deadline still bites.
# WITH ITS OWN FIXTURE. The first version reused `$spin` from the child block --
# whose file is deleted 200 lines earlier, so the child died instantly and the
# check reported `error` instead of `timeout`. It looked like a defect in inherit
# mode and was a defect in the test: a block that borrows another block's fixture
# silently changes meaning the day that block cleans up after itself.
set ispin [file join $HERE _inherit_spin.tcl]
set fh [open $ispin w]
puts $fh {proc spin {} { while {1} { set x [expr {sqrt(2.0)}] } } ; spin}
close $fh
set t0 [clock milliseconds]
set r [run -inherit -timeout 600ms -- $MT tcl $ispin]
set dt [expr {[clock milliseconds] - $t0}]
check "-inherit is still supervised (timeout)" [expr {[dict get $r status] eq "timeout"}]
check "-inherit's deadline fires on time"      [expr {$dt > 400 && $dt < 5000}]
file delete -force $ispin

# Exclusive with the capture path, refused rather than silently ignored.
check "-inherit refuses -onout" [expr {
    [errcode_of {run -inherit -onout {x} -- cmd /c echo hi}] eq {MACHTELD RUN usage}}]
check "-inherit refuses -stdin" [expr {
    [errcode_of {run -inherit -stdin text -- cmd /c echo hi}] eq {MACHTELD RUN usage}}]

# --- the front door dispatches argv ------------------------------------------
# `mt rg --version` has to run ripgrep. The dispatch lives in the prelude because
# `Tcl_Main` calls AppInit before it looks at argv -- and the name it takes as
# the script is in **argv0**, with the rest in `argv`. Reading argv[0] instead
# made the front door resolve the first ARGUMENT of every command, so
# `mt script.tcl a b` went looking for a tool called "a". Only running it showed
# that, which is why these drive the real exe rather than calling a proc.
if {![catch {front roots} FR]} {
    set r [run -timeout 30s -- $MT rg --version]
    check "mt <tool> runs the curated tool" [expr {
        [dict get $r exit] == 0 && [string match "ripgrep*" [dict get $r out]]}]

    set r [run -timeout 30s -- $MT rg --no-such-flag-at-all]
    check "and hands back its exit code"    [expr {[dict get $r exit] != 0}]

    set r [run -timeout 30s -- $MT version]
    check "a builtin answers in-process"    [expr {
        [string trim [dict get $r out]] eq [version]}]

    set r [run -timeout 30s -- $MT nosuchtool-zzz]
    check "an unknown name exits 127"       [expr {[dict get $r exit] == 127}]
    check "and says there is no PATH fallback" [expr {
        [string match "*no PATH fallback*" [dict get $r err]]}]

    # A SCRIPT IS STILL A SCRIPT. The rule is "looks like a path", not "the file
    # exists", so a stray file in the working directory cannot change what a
    # bare name means -- the same accident as a PATH fallback in other clothes.
    set sfix [file join $HERE _dispatch_fixture.tcl]
    set fh [open $sfix w] ; puts $fh {puts "SCRIPT-RAN [llength $argv]"} ; close $fh
    set r [run -timeout 30s -- $MT tcl $sfix a b]
    check "a .tcl path still runs as a script" [expr {
        [string match "*SCRIPT-RAN 2*" [dict get $r out]]}]
    file delete -force $sfix

    # And the workspace's own facts survive the round trip.
    check "the dispatcher found the workspace" [expr {[dict exists $FR root]}]
} else {
    check "no workspace: dispatch stays out of the way" [expr {
        [dict get [run -timeout 30s -- $MT version] exit] == 0}]
}

# --- the journal: what the front door did --------------------------------------
# Its own connection and its own file, so `store` and the journal cannot evict
# one another by both being "the" database.
set jdb [file join $::env(TEMP) _journal_test_[pid].db]
foreach x [list $jdb $jdb-wal $jdb-shm] { file delete -force $x }
check "journal refuses before open" [expr {
    [errcode_of {journal stats}] eq {MACHTELD JOURNAL notopen}}]
journal open $jdb
set jid [journal add [dict create session S name rg kind tool exe C:/rg.exe                           argv {["rg"]} cwd C:/dev project els pid 7 parent ""]]
check "a row starts out running"  [expr {
    [dict get [lindex [journal rows -live] 0] status] eq "running"}]
check "a running row has no exit" [expr {
    [dict get [lindex [journal rows -live] 0] exit] eq ""}]
journal done $jid ok 0
check "done records the status"   [expr {[dict get [lindex [journal rows] 0] status] eq "ok"}]
check "done computes a duration"  [expr {[dict get [lindex [journal rows] 0] ms] ne ""}]
check "and it is no longer live"  [expr {[llength [journal rows -live]] == 0}]
check "filters by name"           [expr {
    [llength [journal rows -name rg]] == 1 && [llength [journal rows -name zz]] == 0}]
check "filters by project"        [expr {[llength [journal rows -project els]] == 1}]
check "stats counts by status"    [expr {[dict get [journal stats] ok] == 1}]

# EVERY VALUE IS BOUND, NEVER PASTED. A tool name is data; if it were spliced
# into the statement text this would drop the table and the next check would
# find nothing to count.
journal add [dict create session S name {x'; DROP TABLE run; --} kind tool exe x                  argv {[]} cwd C:/ project "" pid "" parent ""]
check "a name shaped like SQL stays data" [expr {[llength [journal rows]] == 2}]

check "prune removes by age"      [expr {
    [journal prune [expr {[clock milliseconds] + 1000}]] == 2 && [llength [journal rows]] == 0}]
journal close
check "and refuses again once closed" [expr {
    [errcode_of {journal stats}] eq {MACHTELD JOURNAL notopen}}]
foreach x [list $jdb $jdb-wal $jdb-shm] { file delete -force $x }

# A READER NEEDS NO FILENAME. `front run` opens the record lazily, so a script
# that only wants to read it would otherwise spell the path itself -- a second
# authority on where the journal lives, and the first thing to go stale.
check "front journal opens the workspace's own record" [expr {
    [file tail [front journal]] eq "mt.db" && [file exists [front journal]]}]
check "and the record is queryable straight after" [expr {
    [dict exists [journal stats] rows]}]
journal close

# --- cli duration: the palette's convention, available to its tools -----------
# machteld refuses a bare number for a duration so `-timeout 100` can never
# silently mean 100 seconds -- and then exposed no parser, so `life` and
# `lifelab` shipped taking bare integers. The convention was not kept by the
# tools the toolkit builds. This is the SAME `_dur2ms` the verbs use, so the two
# cannot drift.
check "cli duration parses ms"          [expr {[cli duration 500ms] == 500}]
check "cli duration parses seconds"     [expr {[cli duration 30s] == 30000}]
check "cli duration parses minutes"     [expr {[cli duration 5m] == 300000}]
check "cli duration parses hours"       [expr {[cli duration 2h] == 7200000}]
check "cli duration refuses a bare number" [expr {
    [errcode_of {cli duration 100}] eq {MACHTELD CLI badvalue}}]
check "cli duration refuses nonsense"   [expr {
    [errcode_of {cli duration soon}] eq {MACHTELD CLI badvalue}}]
check "cli duration rejects a bad arity" [expr {
    [errcode_of {cli duration 1s 2s}] eq {MACHTELD CLI usage}}]
# AND IT AGREES WITH THE C. One syntax, two enforcers, would drift silently
# because each looks right alone: whatever `cli duration` accepts, a verb must
# accept, and whatever it refuses, a verb must refuse.
foreach d {250ms 3s 1m} {
    set c [child start -- cmd /c "exit 0"]
    check "the C accepts what cli duration accepts ($d)" [expr {
        ![catch {child wait $c -timeout $d}]}]
    child close $c
}
foreach d {100 soon -5s} {
    set c [child start -- cmd /c "exit 0"]
    check "the C refuses what cli duration refuses ($d)" [expr {
        [lrange [errcode_of {child wait $c -timeout $d}] 0 1] eq {MACHTELD CHILD}}]
    child close $c
}

# --- cli: declare a tool's arguments once ------------------------------------
set CSPEC {
    --interval {type int    default 2000 min 100 max 60000 help "refresh interval, ms"}
    --format   {type string default text choices {text json} help "output format"}
    --all      {type flag                help "show everything"}
    --name     {type string              help "a name"}
    dir        {type string default .    help "directory"}
}

# Defaults come from the spec, and `help` is always present so a tool can check
# it without declaring it.
set c0 [cli parse {} $CSPEC]
check "cli applies defaults"        [expr {[dict get $c0 interval] == 2000}]
check "cli defaults a flag to 0"    [expr {[dict get $c0 all] == 0}]
check "cli defaults a positional"   [expr {[dict get $c0 dir] eq "."}]
check "cli always supplies help"    [expr {[dict get $c0 help] == 0}]
check "an undeclared option has no key" [expr {![dict exists $c0 nosuch]}]

set c1 [cli parse {--interval 500 --all --format json somewhere} $CSPEC]
check "cli reads an option value"   [expr {[dict get $c1 interval] == 500}]
check "cli sets a flag"             [expr {[dict get $c1 all] == 1}]
check "cli checks choices"          [expr {[dict get $c1 format] eq "json"}]
check "cli takes a positional"      [expr {[dict get $c1 dir] eq "somewhere"}]

check "cli reports --help as a value" [expr {[dict get [cli parse {--help} $CSPEC] help] == 1}]
check "--help does not consume a positional" [expr {
    [dict get [cli parse {--help x} $CSPEC] dir] eq "x"}]

# `--` ends options, so a positional may look like one.
set c2 [cli parse {-- --interval} $CSPEC]
check "-- ends option parsing" [expr {[dict get $c2 dir] eq "--interval"}]

# THE BUG THIS VERB EXISTS TO PREVENT. `tasks --interval` with nothing after it
# set the interval to the empty string; `after ""` then threw out of the refresh
# timer and the tool died at startup. A missing value is refused here, at the
# point it is missing, not discovered three frames later.
check "an option with no value is refused" [expr {
    [errcode_of {cli parse {--interval} $CSPEC}] eq {MACHTELD CLI usage}}]
# A STRING option is the case that matters, and the one this suite first missed.
# For --interval the type check catches an empty value anyway, so removing the
# missing-value guard entirely still produced {MACHTELD CLI usage} and every test
# here passed -- the gate was vacuous. Nothing downstream checks a string, so
# without the guard `--name` at the end of argv silently binds the empty string:
# exactly the shape of the bug that killed `tasks` at startup.
check "a string option with no value is refused" [expr {
    [errcode_of {cli parse {--name} $CSPEC}] eq {MACHTELD CLI usage}}]
check "a string option does not silently bind empty" [expr {
    [catch {cli parse {--name} $CSPEC}] == 1}]
check "the missing-value message says so" [expr {
    [catch {cli parse {--name} $CSPEC} m] && [string match "*needs a value*" $m]}]
check "a string option followed by an option is refused" [expr {
    [errcode_of {cli parse {--name --all} $CSPEC}] eq {MACHTELD CLI usage}}]
check "but a value that looks like nothing is still taken" [expr {
    [dict get [cli parse {--name -- x} $CSPEC] name] eq "" ||
    [dict get [cli parse {--name zz} $CSPEC] name] eq "zz"}]
check "an option followed by another option is refused" [expr {
    [errcode_of {cli parse {--interval --all} $CSPEC}] eq {MACHTELD CLI usage}}]
check "the message names the option" [expr {
    [catch {cli parse {--interval} $CSPEC} m] && [string match "*--interval*" $m]}]

# user errors are `usage`
foreach {label argl} {
    "a non-numeric int"    {--interval abc}
    "below the minimum"    {--interval 5}
    "above the maximum"    {--interval 99999}
    "an unknown option"    {--nonsense}
    "a value outside choices" {--format xml}
    "an extra positional"  {a b}
} {
    check "cli refuses $label" [expr {[errcode_of {cli parse $argl $CSPEC}] eq {MACHTELD CLI usage}}]
}

# spec errors are `badvalue` -- the author's mistake, not the user's, and worth a
# different code precisely so a tool can tell them apart.
foreach {label spec} {
    "an unknown attribute" {--x {typo int}}
    "an unknown type"      {--x {type integer}}
    "a repeated name"      {--x {type flag} --x {type string}}
    "a key collision"      {--dir {type string} dir {type string}}
    "a positional flag"    {p {type flag}}
    "a non-dict spec"      {this is not a spec because odd}
} {
    check "cli refuses $label in the spec" [expr {
        [errcode_of {cli parse {} $spec}] eq {MACHTELD CLI badvalue}}]
}

# required
set RSPEC {--who {type string required 1} what {type string required 1}}
check "a missing required option is refused"   [expr {
    [errcode_of {cli parse {x} $RSPEC}] eq {MACHTELD CLI usage}}]
check "a missing required positional is refused" [expr {
    [errcode_of {cli parse {--who me} $RSPEC}] eq {MACHTELD CLI usage}}]
check "supplying both is accepted" [expr {
    [dict get [cli parse {--who me thing} $RSPEC] what] eq "thing"}]

# usage text is generated from the same spec, so it cannot describe a different
# program from the one that runs.
set u [cli usage $CSPEC mytool]
check "usage names the program"     [string match "usage: mytool*" $u]
check "usage lists every option"    [expr {
    [string match "*--interval*" $u] && [string match "*--format*" $u] &&
    [string match "*--all*" $u] && [string match "*--help*" $u]}]
check "usage lists the positional"  [string match "*dir*" $u]
check "usage states the default"    [string match "*2000*" $u]
check "usage states the range"      [string match "*100*" $u]
check "usage states the choices"    [string match "*text, json*" $u]
check "usage rejects a bad spec"    [expr {
    [errcode_of {cli usage {--x {typo 1}}}] eq {MACHTELD CLI badvalue}}]

check "cli rejects an unknown subcommand" [expr {
    [errcode_of {cli nosuch {} {}}] eq {MACHTELD CLI usage}}]

# --- hash: digests, HMAC, and cryptographic random ---------------------------
# Published vectors, not self-consistency: a hash that agrees only with itself
# is worthless, and every one of these is checkable against NIST/RFC by hand.
check "hash algorithms are the five documented" [expr {
    [lsort [hash algorithms]] eq {md5 sha1 sha256 sha384 sha512}}]

foreach {alg data want} {
    md5    {}    d41d8cd98f00b204e9800998ecf8427e
    md5    abc   900150983cd24fb0d6963f7d28e17f72
    sha1   {}    da39a3ee5e6b4b0d3255bfef95601890afd80709
    sha1   abc   a9993e364706816aba3e25717850c26c9cd0d89d
    sha256 {}    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    sha256 abc   ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    sha384 abc   cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7
    sha512 abc   ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f
} {
    check "$alg of \"$data\" matches the published vector" [expr {[hash sum $alg $data] eq $want}]
}

# RFC 2202 / RFC 4231, test case 1.
set hk [binary decode hex 0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b]
check "hmac-sha256 matches RFC 4231" [expr {[hash hmac sha256 $hk "Hi There"] eq
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"}]
check "hmac-sha1 matches RFC 2202"   [expr {[hash hmac sha1 $hk "Hi There"] eq
    "b617318655057264e28bc0b6fb378c8ef146be00"}]
check "hmac differs from the plain digest" [expr {
    [hash hmac sha256 $hk "Hi There"] ne [hash sum sha256 "Hi There"]}]

# WHICH BYTES GET HASHED. This is the rule the implementation got wrong first
# time: Tcl 9 carries two byte-array object types and registers only one by name,
# so a typePtr comparison missed exactly the values `binary decode` produces --
# and they fell through to the string path, where each byte was read as a
# character and re-encoded. `binary decode hex 636166c3a9` hashed as seven bytes
# of UTF-8 instead of five bytes of data, silently.
check "a string hashes as UTF-8" [expr {
    [hash sum sha256 "café"] eq [hash sum sha256 [encoding convertto utf-8 "café"]]}]
check "UTF-8 is what the OS agrees with" [expr {
    [hash sum sha256 "café"] eq "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e"}]
check "a byte array hashes its bytes" [expr {
    [hash sum sha256 [binary decode hex 616263]] eq [hash sum sha256 abc]}]
check "a byte array is not re-encoded" [expr {
    [hash sum sha256 [binary decode hex 636166c3a9]] eq [hash sum sha256 "café"]}]
check "a non-Latin-1 string still hashes as UTF-8" [expr {
    [hash sum sha256 "a日"] eq [hash sum sha256 [encoding convertto utf-8 "a日"]]}]

# -binary gives the raw digest, which must encode back to the hex form.
set hb [hash sum sha256 abc -binary]
check "-binary returns 32 bytes"   [expr {[string length $hb] == 32}]
check "-binary encodes to the hex" [expr {[binary encode hex $hb] eq [hash sum sha256 abc]}]

# file: streamed, and cross-checked against the same bytes hashed as a value.
set HF [file join $env(TEMP) mt_hash_suite.bin]
set fh [open $HF wb] ; puts -nonewline $fh [string repeat "0123456789abcdef" 40000] ; close $fh
check "hash file agrees with hash sum on the same bytes" [expr {
    [hash file sha256 $HF] eq [hash sum sha256 [string repeat "0123456789abcdef" 40000]]}]
check "hash file streams past one chunk" [expr {[file size $HF] > 65536}]
check "hash file on a missing path => notfound" [expr {
    [errcode_of {hash file sha256 [file join $env(TEMP) nosuch_zzz_42.bin]}] eq {MACHTELD HASH notfound}}]
file delete -force $HF

# incremental: same answer as one-shot, and `final` consumes the token.
set before [llength [hash list]]
set hh [hash start sha256]
check "start returns a token"   [string match "hash#*" $hh]
check "the token is listed"     [expr {$hh in [hash list]}]
foreach chunk {abc def ghi} { hash update $hh $chunk }
check "incremental equals one-shot" [expr {[hash final $hh] eq [hash sum sha256 abcdefghi]}]
check "final consumed the token"    [expr {[llength [hash list]] == $before}]
check "the consumed token is gone"  [expr {
    [errcode_of {hash update $hh x}] eq {MACHTELD HASH nohandle}}]

# random: the property that matters is that it is not the same twice.
set r1 [hash random 32]
set r2 [hash random 32]
check "random returns the asked-for length" [expr {[string length $r1] == 32}]
check "random is not repeating"             [expr {$r1 ne $r2}]
check "random is a byte array"              [expr {[string length [binary encode hex $r1]] == 64}]
check "random 0 => badvalue"   [expr {[errcode_of {hash random 0}] eq {MACHTELD HASH badvalue}}]
check "random huge => badvalue" [expr {[errcode_of {hash random 99999999}] eq {MACHTELD HASH badvalue}}]

# the error contract
check "unknown algorithm => badvalue" [expr {
    [errcode_of {hash sum sha999 x}] eq {MACHTELD HASH badvalue}}]
check "unknown option => usage"       [expr {
    [errcode_of {hash sum sha256 x -nope}] eq {MACHTELD HASH usage}}]
check "bad token => nohandle"         [expr {
    [errcode_of {hash final nosuch#9}] eq {MACHTELD HASH nohandle}}]

# --- the manifest describes TCL verbs as fully as C ones ----------------------
# Phase 0 of the stdlib plan. A Tcl verb used to report `kind tcl` plus `info
# args` and nothing else, so the prelude's verbs had no domain, no codes and no
# options in the dict whose whole purpose is describing the palette. These check
# the derivation actually derives -- a MtclFacts that quietly returned nothing
# would leave every assertion below trivially true, which is the failure mode
# three gates already had today.
set M0 [manifest]
foreach v {front help} {
    check "manifest gives $v a domain" [expr {[dict exists $M0 $v domain]}]
    check "manifest gives $v codes"    [expr {
        [dict exists $M0 $v codes] && [llength [dict get $M0 $v codes]] >= 2}]
}
check "manifest gives front its options" [expr {
    [dict exists $M0 front options] &&
    [lsort [dict get $M0 front options]] eq {-depth -inherit -json -out -prune -stdout}}]
check "a verb that cannot fail has no domain" [expr {
    ![dict exists $M0 version domain] && ![dict exists $M0 vtstrip domain]}]

# The codes a Tcl verb declares must be codes it really raises.
foreach {label script want} {
    "front with no arguments"   {front}                      {MACHTELD FRONT usage}
    "front with a bad subcommand" {front nosuch}             {MACHTELD FRONT usage}
    "front run with no name"    {front run}                  {MACHTELD FRONT usage}
    "help on a missing topic"   {help nosuch_topic_zzz}      {MACHTELD HELP notfound}
} {
    check "$label => [lindex $want 2]" [expr {[errcode_of $script] eq $want}]
}
foreach v {front help} {
    foreach c [expr {[dict exists $M0 $v codes] ? [dict get $M0 $v codes] : {}}] {
        check "$v declares $c, which is in the registry" [expr {[dict exists $documented $c]}]
    }
}

# EVERY OPTION A TCL VERB PARSES MUST BE IN ITS DECLARED TABLE -- the mirror of
# the C check, and of the bug that made it worth writing. A `set opts {...}`
# table wins outright in MtclFacts, so it IS the manifest's answer: `front`
# declared {-json} while `front run -inherit` plainly worked, and the manifest
# therefore denied an option the verb accepted. A table that omits something is
# not a smaller answer, it is a wrong one.
#
# An EMPTY table is exempt, because it is a different claim: `set opts {}` says
# "no options of my own", and `cli` really does compare against `--help` while
# parsing some other program's argv. Read out of the live interpreter, so it
# covers the whole prelude rather than one file.
set undeclared {}
set scanned 0
foreach v [lsort [dict keys $M0]] {
    if {[dict get $M0 $v kind] ne "tcl"} continue
    if {![llength [info procs ::machteld::$v]]} continue
    set body [info body ::machteld::$v]
    if {![regexp -line -- {^\s+set opts \{([^\}]*)\}} $body -> table]} continue
    if {[string trim $table] eq ""} continue
    incr scanned
    set found {}
    foreach {_ o} [regexp -all -inline -line -- {^\s+(--?[a-z][-a-z0-9]*)\s+\{} $body] {
        lappend found $o
    }
    foreach {_ o} [regexp -all -inline -- {eq\s+"(--?[a-z][-a-z0-9]*)"} $body] {
        lappend found $o
    }
    foreach o [lsort -unique $found] {
        if {$o ni $table} { lappend undeclared "$v $o" }
    }
}
if {$undeclared ne ""} { puts "     parsed but undeclared: $undeclared" }
check "every option a Tcl verb parses is in its declared table" [expr {$undeclared eq ""}]
check "the prelude option scan found tables to check" [expr {$scanned >= 3}]

# A Tcl subcommand behind a C verb is as visible as a C one: `pty expect` is
# written in the prelude, and the manifest used to be silent about both the
# option it takes and the timeout it raises.
check "pty declares expect's -timeout" [expr {
    [dict exists $M0 pty subcommands expect options] &&
    "-timeout" in [dict get $M0 pty subcommands expect options]}]
check "pty declares expect's timeout code" [expr {
    "timeout" in [dict get $M0 pty codes]}]

# --- the manifest describes the RUNNING binary -------------------------------
# The generator derives the manifest from the C source; these check it against
# the interpreter that actually shipped, which is the half a source scan cannot
# prove. Tcl_GetIndexFromObj's own error message enumerates the real subcommand
# table, so the binary is asked rather than trusted.
set M [manifest]
# Every palette verb, C-written and Tcl-written alike -- a manifest that
# described only half the palette would be a partial truth.
check "manifest covers the whole palette" [expr {[lsort [dict keys $M]] eq
    {canon child cli detach dirs front hash help journal json links log manifest mtps pmap pool pty run scope store tcl version vtstrip wait watch worker wrap}}]
foreach v [dict keys $M] {
    check "manifest verb $v exists" [expr {[llength [info commands ::machteld::$v]] == 1}]
}
check "manifest marks C and Tcl verbs" [expr {
    [dict get $M run kind] eq "c" && [dict get $M front kind] eq "tcl"}]
# EVERY C VERB CARRIES C FACTS. Those facts come from a build-time scan of
# src/*.c, and until 2026-08-10 that scan worked off two hand-kept lists -- so a
# new .c file could compile, link and run while the generator never read it.
# `journal` did exactly that: a C command with seven subcommands and six
# options, published as `kind tcl` with no domain and nothing else, because the
# runtime's fallback for "no entry" was to call it Tcl. This asks the running
# binary instead: anything under ::machteld:: that is not a Tcl proc is C, and a
# C verb the generator never read has no domain to show.
set unseen {}
foreach cmd [lsort [info commands ::machteld::*]] {
    set v [namespace tail $cmd]
    if {[string match {[A-Z_]*} $v] || [llength [info procs $cmd]]} continue
    if {![dict exists $M $v] || [dict get $M $v kind] ne "c"
        || [dict get $M $v domain] eq "" || ![llength [dict get $M $v codes]]} {
        lappend unseen $v
    }
}
if {$unseen ne ""} { puts "     unread by genmanifest: $unseen" }
check "every C verb was read by the manifest generator" [expr {$unseen eq ""}]
# The manifest describes itself, which is the cheapest possible proof that
# self-description is not special-cased.
check "manifest describes itself" [expr {[dict get $M manifest kind] eq "tcl"}]

# --- the front door must not derive the manifest to resolve a name -----------
# Deriving the Tcl half runs MtclFacts over every Tcl verb, and MtclFacts
# follows helpers transitively with a regexp per helper per body: 316 ms,
# measured. `FrontResolve` opened with `dict exists [manifest] $name` to ask
# whether a name was a builtin, so EVERY `mt <name>` paid it -- 361 ms against
# z.exe's 9. Structural rather than timed, because a timing gate on a shared
# machine fails for reasons that have nothing to do with the code.
# COMMENTS STRIPPED FIRST: the proc explains what it used to do, and quoting the
# old line is not doing it. A gate that cannot tell code from prose about code
# fails on its own documentation, which is how a true gate gets deleted.
set frbody ""
foreach line [split [info body ::machteld::FrontResolve] \n] {
    if {[string index [string trim $line] 0] eq "#"} continue
    append frbody $line \n
}
# `string first`, NOT `string match`. In a match pattern `[manifest]` is a
# CHARACTER CLASS -- any one of m,a,n,i,f,e,s,t -- so `*[manifest]*` matches
# essentially every string, and this gate passed and failed for reasons
# unrelated to what it claims to check. The same trap caught the palette-advice
# gate once already; a literal search is the answer both times.
check "FrontResolve does not derive the manifest" [expr {
    [string first {[manifest]} $frbody] < 0}]
# THE PREDICATE AND THE MANIFEST MUST AGREE, since the point of using the cheap
# one is that it answers the same question. If they ever diverge, `mt foo` and
# `dict keys [manifest]` disagree about what a verb is.
set pverbs {}
foreach cmd [info commands ::machteld::*] {
    set v [namespace tail $cmd]
    if {[::machteld::PaletteVerb $v]} { lappend pverbs $v }
}
check "PaletteVerb agrees with the manifest's keys" [expr {
    [lsort $pverbs] eq [lsort [dict keys $M]]}]
# And the derivation is memoised, so a caller that asks twice pays once.
set t0 [clock microseconds] ; manifest ; manifest ; manifest
check "manifest is derived once, not once per call" [expr {
    ([clock microseconds] - $t0) / 1000 < 100}]
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
# Every option the C compares against must appear SOMEWHERE in the manifest.
# Without this, an option parsed by an idiom the generator does not recognise is
# simply absent from the self-description -- which is how `watch` came to claim
# it had no options while accepting three.
if {[file isdirectory $SRC]} {
    set declared {}
    foreach v [dict keys $M] {
        set d [dict get $M $v]
        if {[dict exists $d options]} { lappend declared {*}[dict get $d options] }
        if {[dict exists $d subcommands]} {
            dict for {_s sd} [dict get $d subcommands] { lappend declared {*}[dict get $sd options] }
        }
    }
    set inC {}
    # EVERY .c, FOUND RATHER THAN LISTED -- the same fix the registry scan above
    # already got, and for the same reason. The four-file list left hash.c (one
    # option-shaped strcmp) and journal.c (six) outside this gate entirely, one
    # gate below the comment saying a gate that can be silently emptied is worse
    # than no gate. A new source file was outside it too until somebody
    # remembered, which is exactly how `watch` came to claim it had no options.
    set optsrc [lsearch -all -inline -not [lsearch -all -inline -not \
        [lsort [glob -nocomplain -directory $SRC *.c]] *sqlite3.c] *sqlite3ext*]
    check "the option scan covers every source file" [expr {[llength $optsrc] >= 8}]
    # COMMENTS ARE NOT CODE, and this gate learned it the way the palette-advice
    # gate did: a comment in dirs.c EXPLAINING that the generator reads
    # `strcmp(a, "-x")` literals made the scan demand an option called `-x`, and
    # the suite failed on a sentence. A gate that a comment can fail is a gate
    # reporting on prose. Stripped before scanning, in both comment syntaxes,
    # and the stripper is checked below so it cannot quietly stop stripping.
    proc cstrip {text} {
        regsub -all {/\*.*?\*/} $text " " text
        regsub -all -line {//.*$} $text " " text
        return $text
    }
    check "the comment stripper strips both syntaxes" [expr {
        [string first "-nope" [cstrip "a /* strcmp(a, \"-nope\") */ b"]] < 0 &&
        [string first "-nope" [cstrip "a // strcmp(a, \"-nope\")\nb"]] < 0 &&
        [string first "-real" [cstrip {strcmp(a, "-real")}]] >= 0}]
    foreach f $optsrc {
        set fh [open $f r] ; set text [cstrip [read $fh]] ; close $fh
        foreach {_ o} [regexp -all -inline {strcmp\([^,]+,\s*"(-\w+)"\)} $text] { lappend inC $o }
    }
    set missing [lsort -unique [lmap o $inC {expr {$o in $declared ? [continue] : $o}}]]
    check "every option the C parses is in the manifest" [expr {$missing eq ""}]
    if {$missing ne ""} { puts "     undeclared options: $missing" }
}
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

# --- `tcl`: the first argument is a NAME, and a script is named --------------
# The dispatcher used to hand anything shaped like a path back to Tcl_Main, so
# `mt app.tcl` ran app.tcl. That shape test is gone; these hold the replacement
# to what it claims, from a real child process rather than in-process, because
# the claim is about what the EXE does with its command line.
set TSCRIPT [file join $env(TEMP) mt_tcltest_[pid].tcl]
set fh [open $TSCRIPT w] ; fconfigure $fh -translation lf
puts $fh {puts "argv0=[file tail $argv0] argv=$argv" ; exit 7}
close $fh

set tr [run -timeout 30s -- $MT tcl $TSCRIPT a "b c"]
check "mt tcl runs a script"             [expr {[dict get $tr exit] == 7}]
check "and the script owns argv0/argv"   [expr {
    [string match "*argv0=[file tail $TSCRIPT]*" [dict get $tr out]]
    && [string match "*argv=a {b c}*" [dict get $tr out]]}]

# THE OLD SPELLING IS GONE, and says so usefully. A bare path is now a name that
# nobody curates -- but being told "not a builtin, a shipped tool or a curated
# tool" when you plainly typed a filename is unhelpful, so the second line names
# the new spelling.
set tr [run -timeout 30s -- $MT $TSCRIPT]
check "a bare script path is no longer run" [expr {[dict get $tr exit] == 127}]
check "and the error names `mt tcl`"        [expr {
    [string match "*mt tcl*" [dict get $tr err]]}]
file delete -force $TSCRIPT

# `file exists` is allowed in that message and nowhere near the decision: what
# `mt` runs must not depend on what happens to be in the working directory.
# `version` is a builtin, and stays one even standing next to a file called
# `version`.
set VFILE [file join $env(TEMP) mt_tcltest_[pid]]
file mkdir $VFILE
set fh [open [file join $VFILE version] w] ; puts $fh "not a program" ; close $fh
set tr [run -timeout 30s -dir $VFILE -- $MT version]
check "a file of the same name does not shadow a verb" [expr {
    [dict get $tr exit] == 0 && [string match "0.*" [string trim [dict get $tr out]]]}]
file delete -force $VFILE

check "tcl with no script is a usage error" [expr {
    [errcode_of {tcl}] eq {MACHTELD TCL usage}}]

# --- step 4: z's commands, reachable by their bare names ---------------------
# `mt projects`, not `mt front projects`, because these exist to be typed where
# `z projects` was.
foreach c {which env tools projects runtimes roots journal} {
    check "$c is a front-door command" [expr {$c in [::machteld::FrontCommands]}]
}
# ONE DEFINITION. `FrontCommands` reads `front`'s own `set subs {...}` line, the
# same line MtclFacts reads for the manifest -- minus the names deliberately not
# promoted. If they ever diverge otherwise, `mt X` and `front X` disagree about
# what exists.
check "the promoted set is front's subcommands minus the exclusions" [expr {
    [lsort [concat [::machteld::FrontCommands] [::machteld::FrontUnpromoted]]] eq
    [lsort [dict keys [dict get [manifest] front subcommands]]]}]
# `run` IS NOT PROMOTED, and ten projects depend on that. `front run` is the
# plumbing that executes a resolved name, so `mt run rg` would only be `mt rg`
# with extra words -- while claiming a bare name that ten of the twelve projects
# here declare as a command of their own. z has no `run` built-in either.
check "run is not promoted to a bare name" [expr {
    "run" ni [::machteld::FrontCommands]}]
check "and front run still works in full" [expr {
    "run" in [dict keys [dict get [manifest] front subcommands]]}]
set claimed {}
foreach p [valof {json decode [front projects -json]}] {
    foreach n [dict keys [::machteld::FrontProjectCommands [dict get $p path]]] {
        if {$n in [::machteld::FrontCommands]} { lappend claimed "[dict get $p name]/$n" }
    }
}
if {$claimed ne ""} { puts "     project commands a promoted name shadows: $claimed" }
check "no promoted name shadows a project command" [expr {$claimed eq ""}]
# NOTHING IS SHADOWED. z reserves its built-in names; here the check is live,
# because the workspace gains tools without asking anybody.
set shadowed {}
foreach c [::machteld::FrontCommands] {
    if {$c in [::machteld::FrontToolNames]} { lappend shadowed $c }
}
if {$shadowed ne ""} { puts "     front commands shadowing curated tools: $shadowed" }
check "no front-door command shadows a curated tool" [expr {$shadowed eq ""}]
check "a bare command name resolves in-process" [expr {
    [dict get [valof {front env projects}] kind] eq "command"}]

# --- status: the part that is here, and the part that is refused -------------
# `status` is a COCKPIT -- it aggregates the mirror report, the mirror run state
# and (under -deep) `verify` and `ledger check`, three of which the plan defers
# to last. So it lands half-built on purpose, and the half that is missing is
# ABSENT rather than guessed: no `mirror: null` claiming there is no report when
# there is one.
set st [valof {json decode [front status -json]}]
check "status reports root and the workspace git" [expr {
    [dict exists $st root] && [dict exists $st zGit ok] && [dict exists $st zGit branch]}]
check "status counts git the way the cockpit does" [expr {
    [lsort [dict keys [dict get $st zGit counts]]] eq {deleted modified other untracked}}]
# `front projects` renders TEXT; the count has to come from the -json form.
# Comparing against `llength` of the rendering counted words, not projects.
check "status covers every hosted project" [expr {
    [llength [dict get $st projects]]
        == [llength [valof {json decode [front projects -json]}]]
    && [llength [dict get $st projects]] > 0}]
check "every project row carries a git summary" [expr {
    [llength [lmap p [dict get $st projects] {expr {[dict exists $p git ok] ? [continue] : $p}}]] == 0}]
# NOT FAKED. A key machteld cannot fill is one it does not emit -- so a caller
# diffing against z sees a missing key, which is true, rather than a null that
# would be a claim.
foreach k {mirror mirrorState deep} {
    check "status does not invent `$k`" [expr {![dict exists $st $k]}]
}
check "status -deep is refused, not approximated" [expr {
    [errcode_of {front status -deep}] eq {MACHTELD FRONT unsupported}}]

# --- the project tier, and the qualifiers ------------------------------------
# `z:name` means THE KIT's name -- a curated tool -- and explicitly not a
# builtin: a builtin needs no qualifying, there being nothing to qualify it
# against. machteld had this backwards until 2026-08-10, so `z:rg` did not
# resolve while `z:run` reached the palette. Never caught, because the agreement
# test only ever asked bare names.
check "z: reaches a curated tool"        [expr {
    [string match "*rg.exe" [valof {front which z:rg}]]}]
check "z: does not reach the palette"    [expr {
    [errcode_of {front which z:run}] eq {MACHTELD FRONT notfound}}]
check "an unknown qualifier is a usage error" [expr {
    [errcode_of {front which nope:rg}] eq {MACHTELD FRONT usage}}]

# PROJECT COMMANDS, the tier machteld did not have. Every project's z.json
# `commands` entry: argv[0] resolving to a curated tool CLONES that tool's whole
# target -- env overlay, PATH shaping, prepended arguments -- and the rest of the
# argv is appended to it, with the project root as the working directory.
set pcmd {}
foreach p [valof {json decode [front projects -json]}] {
    set c [::machteld::FrontProjectCommands [dict get $p path]]
    if {[dict size $c]} { set pcmd [list [dict get $p path] $c] ; break }
}
check "a project declares commands to resolve" [expr {$pcmd ne ""}]
if {$pcmd ne ""} {
    lassign $pcmd proot cmds
    set n [lindex [lsort [dict keys $cmds]] 0]
    set t [dict get $cmds $n]
    check "a project command is kind project"   [expr {[dict get $t kind] eq "project"}]
    check "it runs from the project root"       [expr {
        [string equal -nocase [dict get $t cwd] [file nativename $proot]]}]
    check "it carries the project's env"        [expr {
        [dict get $t env MT_PROJECT_ROOT] eq [file nativename $proot]}]
    # PATHS ARE CLEANED, because `filepath.Join` cleans and `file join` does
    # not: `./drang.exe` came out as `_drang\.\drang.exe` and `../_drang/...`
    # as `_exp\..\_drang\...` -- both run, both the wrong string, both differing
    # from z on nothing but punctuation.
    set dirty {}
    foreach nm [dict keys $cmds] {
        set e [dict get $cmds $nm exe]
        if {[string first "\\.\\" $e] >= 0 || [string first "\\..\\" $e] >= 0} { lappend dirty $nm }
    }
    check "project command paths are cleaned"   [expr {$dirty eq ""}]
}

# --- verify: the workspace's structural problems -----------------------------
set vf [valof {json decode [front verify -json]}]
check "verify answers with problems and counts" [expr {
    [dict exists $vf problems] && [dict exists $vf counts builtins]
    && [dict exists $vf counts tools] && [dict exists $vf counts project]}]
# THE ROOT IS MEANT TO BE ALMOST EMPTY: the front door, its private directory,
# and hosted projects. Anything else is reported, because drift there is the
# kind nobody notices for years.
check "verify reports unexpected root entries" [expr {
    [llength [lsearch -all -inline -glob [dict get $vf problems] "unexpected workspace-root entry*"]] > 0}]
# BOTH FRONT DOORS ARE ACCEPTED while both exist -- otherwise `mt verify` would
# flag `mt.exe` the day it lands beside `z.exe`, which is the transition rather
# than a problem with the workspace.
foreach keep {z.exe mt.exe .z .mt} {
    check "verify accepts $keep at the root" [expr {
        [llength [lsearch -all -inline -glob [dict get $vf problems] "*$keep"]] == 0}]
}
# A KIT NAME DEFINED TWICE would be a real problem; there are none, and the
# check has to be live because the workspace gains tools without asking.
check "no kit name is defined twice" [expr {
    [llength [lsearch -all -inline -glob [dict get $vf problems] "kit defines*"]] == 0}]

# --- scout: every underscore directory, not every project --------------------
# `projects` lists the ones carrying a project file; `scout` lists them ALL and
# reports which do not, which is how a directory meant to become a project and
# never did gets noticed. Different questions, and scout deliberately omits the
# length check `projects` applies.
set sc [valof {json decode [front scout -json]}]
check "scout sees more than projects does" [expr {
    [llength $sc] > [llength [valof {json decode [front projects -json]}]]}]
check "every scout row is complete" [expr {
    [llength [lmap r $sc {expr {
        [dict exists $r name] && [dict exists $r zjson] && [dict exists $r readme]
        && [dict exists $r git] && [dict exists $r branch] && [dict exists $r commands]
        ? [continue] : $r}}]] == 0}]
check "scout reports a git state it recognises" [expr {
    [llength [lmap r $sc {expr {
        [dict get $r git] in {clean dirty no-git git?} ? [continue] : $r}}]] == 0}]
# CONCURRENT AND SERIAL MUST AGREE. The probes run as supervised children by
# default -- 1.17 s serial against 0.56 s concurrent, measured -- and a
# concurrency that changes the answer is not an optimisation.
check "concurrent and --serial scout agree" [expr {
    [valof {front scout -json}] eq [valof {front scout --serial -json}]}]

# THE `t/` DIRECTORY IS A SOURCE OF TOOLS, not just an override of manifest
# entries. Four tools existed only as `.z/t/<name>/` directories and machteld
# refused all four while z ran them -- invisible for a month because the
# agreement test enumerated machteld's own list.
set tdir [file join [dict get [front roots] home] t]
set unlisted {}
foreach d [glob -nocomplain -types d -directory $tdir *] {
    set n [file tail $d]
    if {![file exists [file join $d $n.exe]]} continue
    if {$n ni [::machteld::FrontToolNames]} { lappend unlisted $n }
}
if {$unlisted ne ""} { puts "     installed in t/ but not curated: $unlisted" }
check "every installed t/<name>/<name>.exe is a curated tool" [expr {$unlisted eq ""}]

# `file normalize` FOLLOWS LINKS AND MUST NOT BE USED FOR THIS. `.z/r/winsdk` is
# a junction into Program Files, so normalising both sides put them in different
# trees and `signtool` stopped being a winsdk alias -- one row of fourteen.
check "containment is lexical, not link-resolving" [expr {
    [::machteld::FrontWithin {C:/x/link} {C:/x/link/sub/tool.exe}] &&
    ![::machteld::FrontWithin {C:/x/link} {C:/x/linked/tool.exe}] &&
    [::machteld::FrontClean {C:\a\.\b\..\c}] eq "C:/a/c"}]
check "tcl on a missing script says so"     [expr {
    [errcode_of {tcl no_such_script_zzz.tcl}] eq {MACHTELD TCL notfound}}]

# --- `wrap`: a tool of your own, with no compiler ----------------------------
# THIS IS THE ONE VERB WHOSE OUTPUT IS THE TEST. Everything else here can be
# checked by asking the running binary a question; `wrap` is only proved by
# stamping an exe and running it on a machine that has no Tcl, which is the whole
# point of it -- a colleague on a share, with nothing installed.
#
# The fixture writes a marker file beside itself recording what it could see, so
# app-mode and the prelude are verifiable HEADLESSLY. The window itself needs a
# desktop and is checked by the same marker when there is one.
check "wrap declares its options" [expr {
    [lsort [valof {dict get [manifest] wrap options}]] eq {--console --gui --no-prelude -o}}]
foreach {label script want} {
    "wrap with no arguments"          {wrap}                       {MACHTELD WRAP usage}
    "wrap with a stray argument"      {wrap a b c}                 {MACHTELD WRAP usage}
    "wrap on a dir with no main.tcl"  {wrap $env(TEMP) -o x.exe}   {MACHTELD WRAP notfound}
} {
    check "$label => [lindex $want 2]" [expr {[errcode_of $script] eq $want}]
}

set WTOOL [file join $HERE hello_tool]
# STAMPED INSIDE THE WORKSPACE, deliberately. The obvious place is $TEMP, and
# there the last check below proves nothing: `FrontRoots` finds no `.mt` above
# $TEMP, so the dispatcher stands aside for want of a workspace and the stamped
# tool runs whether or not it is recognised as one. Here the workspace IS found,
# so only the zipfs-main.tcl check keeps the front door out of the way.
set WOUT  [file join $HERE .. build mt_wrap_[pid].exe]
set WMARK [file join $HERE .. build _hello_ran.txt]
if {[file isdirectory $WTOOL]} {
    file delete -force $WMARK
    check "wrap stamps an exe"        [expr {
        ![catch {wrap $WTOOL -o $WOUT --console}] && [file exists $WOUT]}]
    # SELF-CONTAINED means it carries a whole Tcl/Tk runtime, so it is big. A
    # 200 KB result would mean the basekit was not appended and the thing would
    # not run anywhere but here.
    check "and it is self-contained"  [expr {[file size $WOUT] > 4000000}]
    set wr [run -timeout 60s -- $WOUT]
    check "the stamped exe runs"      [expr {[dict get $wr exit] == 0}]
    check "and its main.tcl auto-ran" [expr {[file exists $WMARK]}]
    if {[file exists $WMARK]} {
        set wf [open $WMARK r] ; set wtext [read $wf] ; close $wf
        # THE PRELUDE RIDES ALONG, which is what makes a stamped tool worth
        # having: the whole palette is inside it, on a machine with no Tcl.
        check "the palette is inside it" [expr {[string match "*prelude: loaded*" $wtext]}]
        check "and so is the C library"  [expr {[string match "*proc-in-basekit: yes*" $wtext]}]
    }
    # A STAMPED TOOL MUST NOT REACH THE FRONT DOOR'S DISPATCHER. Its argv0 is
    # its own main.tcl inside its own zipfs, and under "the first argument is a
    # name" that would resolve as a tool name and exit 127 before the program
    # ran. Caught by building this, not by reading the code.
    check "a stamped tool is not dispatched as a name" [expr {
        [dict get $wr exit] != 127}]
    file delete -force $WOUT $WMARK
}

# --- `dirs`: the directory tree, and the silences it must make impossible -----
#
# THESE GATES ARE AIMED AT THE C WALKER, NOT AT THE `glob` WALKERS IT REPLACES.
# That distinction is the whole methodology. It is easy to write a suite that
# fires on the three prelude attempts recorded in direction.md -- 786 short, 77%
# over, deduplicated back to 786 short -- and such a suite proves the last war
# was won. The break-tests each gate below is written against are defects of the
# implementation that actually shipped: emitting in NTFS enumeration order,
# treating every reparse point as a surrogate the way z does, refusing to descend
# a root that is itself a junction, counting at push instead of at pop,
# converting names with CP_ACP instead of CP_UTF8, and losing the \\?\ prefix.
# Every one of those is silent, and silence is the reason this verb is in C.
#
# THE EXPECTATION IS DERIVED FROM THE LITERAL SHAPE, never from a second walk.
# An expectation built with `glob` is two implementations of the same misreading
# checked against each other, which is exactly how three attempts in a row
# reported a plausible number and a wrong list.
set FX  [string map {\\ /} $env(TEMP)]/mt_dirs_[pid]
set FXO [string map {\\ /} $env(TEMP)]/mt_dirs_out_[pid]
proc DirsNat {p} { return [file nativename $p] }
proc DirsWipe {p} {
    if {![file exists $p]} return
    # JUNCTIONS FIRST, and that ordering is most of why teardown used to be slow.
    # `icacls /reset /t` FOLLOWS a junction, so `linkup` -- which points at the
    # fixture root -- sends it round the whole tree again: measured, ~64 levels of
    # linkup\linkup\... before MAX_PATH stops it, every teardown doing ~64x the
    # ACL work it needs to. `rmdir` on a junction removes the LINK and never the
    # target, so this is safe to do first. Only the top level is scanned, which is
    # where this fixture's three junctions live.
    foreach q [glob -nocomplain -types d -directory $p *] {
        if {![catch {file link $q}]} { catch {exec cmd /c rmdir [DirsNat $q]} }
    }
    # `icacls /reset` BEFORE the rmdir, and this is not belt-and-braces. Measured:
    # with a deny ACE in place `rmdir /s /q` prints "Access is denied", EXITS 0,
    # and leaves the directory behind -- so a teardown that trusts the exit code
    # leaves a fixture that the next run cannot rebuild and cannot remove either,
    # and every subsequent run fails for a reason that has nothing to do with the
    # code.
    catch {exec cmd /c icacls [DirsNat $p] /reset /t /q /c}
    catch {exec cmd /c rmdir /s /q [DirsNat $p]}
}
# EVERY LEFTOVER FIXTURE, NOT THIS RUN'S. The on-entry wipe used to be
# `DirsWipe $FX`, and its comment said it existed "because the run that leaves
# the mess is the one that was killed" -- but $FX carries THIS process's pid, so
# a fresh run's path can never be a killed run's path and nothing ever collected
# anything. Measured: %TEMP% held four abandoned mt_dirs_* trees from killed
# runs, each with a `locked` subdirectory still carrying its deny ACE, which a
# later plain `rmdir /s /q` calls "not empty", exits 0 on, and leaves for good.
foreach stale [glob -nocomplain -directory [string map {\\ /} $env(TEMP)] mt_dirs_*] {
    DirsWipe $stale
}

# The sibling tree a junction points OUT of the root at.
file mkdir [file join $FXO ochild]

file mkdir $FX
# A dot-name that is ALSO hidden is the real-world case: `.git` is both, and the
# 786 missing directories were hidden, not dotted. The two are separated here so
# a fixture cannot pass by getting one of them right.
foreach d {.dotname .dothidden hiddenattr} { file mkdir [file join $FX $d] }
file mkdir [file join $FX hiddenattr inside]
catch {exec cmd /c attrib +h [DirsNat [file join $FX .dothidden]]}
catch {exec cmd /c attrib +h +s [DirsNat [file join $FX hiddenattr]]}
file mkdir [file join $FX {has space}]
file mkdir [file join $FX {quote'n[brace]}]
file mkdir [file join $FX target tchild]
file mkdir [file join $FX locked lchild]
# A FILE, which must never appear in the answer.
set fh [open [file join $FX afile.txt] w] ; puts $fh x ; close $fh

# Forty levels, every one of them called `d`: a walker keyed on a base name
# rather than a path collapses this to one.
set DEEPN 40
set p [file join $FX deep]
for {set i 0} {$i < $DEEPN} {incr i} { set p [file join $p d] }
file mkdir $p

# PAST MAX_PATH, and it takes a detour to build. Measured: Tcl's own `file
# mkdir` gives up at 256 characters, `cmd /c mkdir` is MAX_PATH-bound, the chdir
# trick fails because the current directory is MAX_PATH-bound too, and Tcl's
# path parser silently mangles a \\?\ prefix -- `file mkdir` on one returns
# success and creates nothing. .NET's Directory.CreateDirectory takes the prefix
# straight through, which is the only route from here that works.
set LONGSEG {}
for {set i 0} {$i < 12} {incr i} { lappend LONGSEG [string repeat x 24]$i }
set longnat [DirsNat [file join $FX deeplong]]
foreach s $LONGSEG { append longnat "\\" $s }
catch {exec powershell -NoProfile -Command \
    "\[System.IO.Directory\]::CreateDirectory('\\\\?\\$longnat') | Out-Null"} psmsg
check "the fixture reaches past MAX_PATH" [expr {
    [string length $longnat] > 300 && [file isdirectory [file join $FX deeplong]]}]

# Three junctions: one inside the root, one out of it, and one AT the root. The
# third is the canary -- a walker that descends surrogates does not fail on it,
# it recurses until the path runs out.
foreach {name tgt} [list linkin [file join $FX target] \
                         linkout $FXO \
                         linkup $FX] {
    catch {exec cmd /c mklink /J [DirsNat [file join $FX $name]] [DirsNat $tgt]}
}
check "the fixture has its three junctions" [expr {
    [file isdirectory [file join $FX linkin]] && [file isdirectory [file join $FX linkout]]
    && [file isdirectory [file join $FX linkup]]}]

# Sibling order, and the two orderings that are NOT it. `AB aa Zz _z b1`
# separates code-point order from NTFS's case-insensitive upcase collation
# (measured: NTFS enumerates them aa AB b1 Zz _z, completely disjoint from the
# sorted order). U+E000 against U+1F600 separates UTF-8 code-point order from
# UTF-16 code-unit order -- the emoji's lead surrogate 0xD83D sorts BEFORE
# U+E000 as UTF-16 and AFTER it as code points. Written as escapes rather than
# as bytes so this file's own encoding cannot be what is under test.
#
# U+E001 SITS BESIDE U+E000 TO FEED GATE 2, and it is one token that turns a
# real gate into a reachable one. "dirs lists nothing twice" was written against
# duplication and could not fire on the one defect in the shipped code that
# PRODUCES a duplicate: convert with CP_ACP instead of CP_UTF8 and two distinct
# names collapse to the same bytes. Measured on the CP_ACP build with the old
# list, every name still mapped to something distinct -- e9, ???, ?, ?? -- so
# gate 2 stayed silent and only gate 1 fired. Two adjacent private-use
# characters both become `?`, which is the collision, and it is also the only
# subject in this file that reaches the WC_ERR_INVALID_CHARS decision the source
# calls "the point".
set ORDER [list AB Zz _z aa b1 \u00e9 \u65e5\u672c\u8a9e \ue000 \ue001 \U0001F600]
file mkdir [file join $FX order]
foreach n $ORDER { file mkdir [file join $FX order $n] }
check "the fixture carries non-ASCII names" [expr {
    [file isdirectory [file join $FX order \u65e5\u672c\u8a9e]] &&
    [file isdirectory [file join $FX order \U0001F600]]}]

catch {exec cmd /c icacls [DirsNat [file join $FX locked]] /deny "$env(USERNAME):(OI)(CI)(RD)"}

# GATE 0, THE CANARY, IN A CHILD PROCESS. `linkup` points at the fixture root:
# a walker that descends surrogates does not return a wrong answer here, it does
# not return. In-process that hangs the suite with no output; as a supervised
# child with a timeout it is a failed check and the rest of the run continues.
# (With \\?\ the path is bounded at 32,767 characters, so such a walk terminates
# after some thousands of levels rather than never -- the timeout is what
# protects the suite, not the arithmetic.)
# In %TEMP%, not in the repo's own test/ directory. It was written beside this
# file and deleted only on the success path, so an abort at gate 0 left a stray
# .tcl in the source tree -- and $HERE is also shared by concurrent runs, which
# this fixture otherwise keys on the pid to avoid.
set DCANARY [file join [string map {\\ /} $env(TEMP)] mt_dirs_canary_[pid].tcl]
set fh [open $DCANARY w] ; fconfigure $fh -translation lf
puts $fh {set r [dirs [lindex $argv 0]] ; puts "CANARY [dict get $r dirs]"}
close $fh
set dcr [run -timeout 90s -- $MT tcl $DCANARY $FX]
check "dirs terminates on a junction pointing at its own root" [expr {
    [dict get $dcr status] eq "ok" && [string match "*CANARY*" [dict get $dcr out]]}]
file delete -force $DCANARY

set R [dirs $FX]
set GOT [dict get $R paths]

# Whether the deny ACE actually took. FILE_FLAG_BACKUP_SEMANTICS is mandatory to
# open a directory at all, and with SeBackupPrivilege it BYPASSES the ACE -- so
# on an elevated run `locked/lchild` is readable and the expectation below has to
# change. The suite already carries this scar for `mtps`; the wrong response to
# a red gate here is to weaken the gate, so the condition is probed and said out
# loud instead.
#
# THE PROBE IS EXTERNAL, not the walker's own output. It used to be
# `[file join $FX locked lchild] ni $GOT` -- the verb under test asked whether
# the verb under test was right, which is the self-referential shape gate 8's
# comment explicitly rejects two hundred lines below. It happened to
# self-correct, because gate 9 also demands exactly one errors row; it was still
# the wrong oracle. `glob` reads the directory through the same ACL and answers
# from outside: measured, it raises "permission denied" on the denied directory
# and returns cleanly (empty) on a readable empty one, so a `catch` separates
# them without needing the walker to agree.
set DENIED [catch {glob -nocomplain -directory [file join $FX locked] *}]
if {!$DENIED} { puts "     NOTE: elevated -- the deny ACE did not take, gates 1/9 relaxed" }

set EXPECT [list $FX]
lappend EXPECT [file join $FX .dothidden] [file join $FX .dotname] [file join $FX deep]
set p [file join $FX deep]
for {set i 0} {$i < $DEEPN} {incr i} { set p [file join $p d] ; lappend EXPECT $p }
lappend EXPECT [file join $FX deeplong]
set p [file join $FX deeplong]
foreach s $LONGSEG { set p [file join $p $s] ; lappend EXPECT $p }
lappend EXPECT [file join $FX {has space}] [file join $FX hiddenattr] \
               [file join $FX hiddenattr inside] \
               [file join $FX linkin] [file join $FX linkout] [file join $FX linkup] \
               [file join $FX locked]
if {!$DENIED} { lappend EXPECT [file join $FX locked lchild] }
lappend EXPECT [file join $FX order]
foreach n $ORDER { lappend EXPECT [file join $FX order $n] }
lappend EXPECT [file join $FX {quote'n[brace]}] [file join $FX target] \
               [file join $FX target tchild]

# GATE 1: the exact set, BOTH DIRECTIONS. Not a count -- the recorded failures
# were 786 short AND 16,504 over, and a walker can be both at once while landing
# on a total that looks right.
set missing {} ; set extra {}
foreach e $EXPECT { if {$e ni $GOT} { lappend missing $e } }
foreach g $GOT    { if {$g ni $EXPECT} { lappend extra $g } }
check "dirs lists exactly the tree that is there" [expr {$missing eq "" && $extra eq ""}]
# THE DIAGNOSTIC IS WRAPPED, and that is not defensive habit. A walker that
# converts names with CP_ACP instead of CP_UTF8 hands back byte strings that are
# not valid UTF-8; this gate fired on it correctly, and then `puts` threw trying
# to render one -- so the run aborted here and every check after it silently
# never ran, which is the failure `valof` was added to this file to stop. The
# count survives even when the paths cannot be printed.
if {$missing ne ""} {
    if {[catch {puts "     missing: [lrange $missing 0 9]"}]} { puts "     missing: [llength $missing] (unprintable)" }
}
if {$extra ne ""} {
    if {[catch {puts "     extra:   [lrange $extra 0 9]"}]} { puts "     extra:   [llength $extra] (unprintable)" }
}

# GATE 2: nothing twice -- a SEPARATE gate, because a set difference cannot see
# a duplicate. `glob -- * .*` walked every dot-directory twice, terminated
# normally, and every one of its duplicates was a real path.
set seen {} ; set dups {}
foreach g $GOT { if {[dict exists $seen $g]} { lappend dups $g } ; dict set seen $g 1 }
check "dirs lists nothing twice" [expr {$dups eq ""}]
if {$dups ne ""} {
    if {[catch {puts "     duplicated: [lrange $dups 0 9]"}]} { puts "     duplicated: [llength $dups] (unprintable)" }
}

# GATE 3: the ORDER, against the literal. Ordering is contract (a cache file
# gets diffed), and pushing children in enumeration order is invisible to every
# other gate here: same set, same count, different bytes.
check "dirs emits depth-first, siblings in code-point order" [expr {$GOT eq $EXPECT}]
if {$GOT ne $EXPECT} {
    for {set i 0} {$i < [llength $GOT] && $i < [llength $EXPECT]} {incr i} {
        if {[lindex $GOT $i] ne [lindex $EXPECT $i]} {
            if {[catch {puts "     first divergence at $i: got [lindex $GOT $i] want [lindex $EXPECT $i]"}]} {
                puts "     first divergence at $i (unprintable)"
            }
            break
        }
    }
}
check "the root is listed, and first" [expr {[lindex $GOT 0] eq $FX}]
check "dirs counts what it listed" [expr {[dict get $R dirs] == [llength $GOT]}]

# GATE 4: the individual name classes, so a failure says which one broke.
check "a dot-name is listed"            [expr {[file join $FX .dotname] in $GOT}]
check "a hidden dot-name is listed"     [expr {[file join $FX .dothidden] in $GOT}]
check "a hidden+system name is listed"  [expr {[file join $FX hiddenattr] in $GOT}]
check "and its child too"               [expr {[file join $FX hiddenattr inside] in $GOT}]
check "a name with a space is listed"   [expr {[file join $FX {has space}] in $GOT}]
check "a name with quotes/brackets too" [expr {[file join $FX {quote'n[brace]}] in $GOT}]
check "a FILE is never listed"          [expr {[file join $FX afile.txt] ni $GOT}]

# GATE 5: non-ASCII round-trips. Two conversions stand between a UTF-16 name and
# a Tcl string, and CP_ACP in place of CP_UTF8 passes every other gate in this
# block -- the names still sort, still count, still differ from one another.
foreach n $ORDER {
    check "a non-ASCII sibling survives the walk ([string length $n] chars)" \
        [expr {[file join $FX order $n] in $GOT}]
}
check "40 directories all called d survive" [expr {
    [llength [lsearch -all -inline $GOT [file join $FX deep]/*]] == $DEEPN}]
# `==`, not `>=`. The one-sided form passes when the whole computation is
# replaced by `w->maxdepth = 9999` -- measured -- so it constrained nothing above
# the true answer. `deep` is depth 1 and carries 40 levels of `d`, so 41 is the
# number and there is no reason to accept a larger one.
check "maxdepth reports the deepest reached" [expr {[dict get $R maxdepth] == $DEEPN + 1}]
check "a path past MAX_PATH is listed"      [expr {
    [lindex $EXPECT [expr {[lsearch -exact $EXPECT [file join $FX deeplong]] + 12}]] in $GOT}]

# GATE 6: reparse points are LISTED and NOT DESCENDED, and the rows are named.
# Counting them would be a count agreeing by accident; the tag and the
# disposition are what make the classification auditable.
foreach n {linkin linkout linkup} {
    check "$n is listed"          [expr {[file join $FX $n] in $GOT}]
    check "nothing under $n"      [expr {[lsearch -glob $GOT [file join $FX $n]/*] < 0}]
}
# THE SUBJECT IS THE BASENAME THAT ONLY EXISTS OUTSIDE, not the outside path.
# This used to read `lsearch -glob $GOT $FXO*`, which can never match whatever
# the walker does: every path is built LEXICALLY by joining a name onto the
# root's own prefix, and a link target is never resolved, so descending
# `linkout` emits $FX/linkout/ochild and not $FXO/ochild. The pattern could only
# fire if the ROOT were $FXO. `ochild` exists nowhere under $FX, so seeing it at
# all means the walk left the tree it was given.
check "nothing outside the root leaked in" [expr {[lsearch -glob $GOT */ochild] < 0}]
set LROWS {}
foreach l [dict get $R links] { dict set LROWS [dict get $l path] $l }
check "every junction has a links row" [expr {
    [dict exists $LROWS [file join $FX linkin]] && [dict exists $LROWS [file join $FX linkout]]
    && [dict exists $LROWS [file join $FX linkup]]}]
# `dict exists` GUARDING THE `dict get`s. Stubbing the mklink out of the fixture
# does not degrade this block, it CRASHES it: `dict get` on a missing key throws
# "key not known in dictionary", the run aborts here, and gates 7-15 plus BOTH
# DirsWipe calls never execute -- so a fixture that failed to build also leaks
# itself permanently, deny ACE and all. Measured.
check "and the row carries the tag and the disposition" [expr {
    [dict exists $LROWS [file join $FX linkin]] &&
    [dict get $LROWS [file join $FX linkin] tag] eq "0xa0000003" &&
    [dict get $LROWS [file join $FX linkin] surrogate] == 1 &&
    [dict get $LROWS [file join $FX linkin] action] eq "nofollow"}]
check "no ordinary directory produced a links row" [expr {[llength [dict get $R links]] == 3}]

# GATE 7: a root that is ITSELF a junction is descended. You named it, so you
# get it -- and a walker that classifies the root the way it classifies a child
# returns the root alone and passes every other gate in this file.
set RL [valof {dirs [file join $FX linkin]}]
check "a junction root is descended, not refused" [expr {
    [file join $FX linkin/tchild] in [dict get $RL paths] && [dict get $RL dirs] == 2}]
# AND IT SAYS SO. Descending a named junction root is right; being SILENT about
# it is the failure this verb exists to abolish, appearing in the mechanism built
# to prevent it. Measured on the first implementation: root came back as the
# junction's own path, `paths` held the target's tree, `errors` was empty and
# `links` was EMPTY TOO -- so nothing in the answer disclosed that every path
# returned is a second name for a tree living somewhere else, and a caller
# auditing containment got a clean, plausible, false negative. The cause was
# structural rather than a slip: the classification block is gated on depth > 0
# because the root is exempt from the VETO, which made it exempt from being
# DESCRIBED, and the root's validation handle FOLLOWS the reparse point so its
# tag reads 0. Both the source and palette.md promise "every reparse directory
# gets a row"; gate 7 checked only `paths` and `dirs`, so 576 checks passed over
# it.
set RLROW ""
foreach l [dict get $RL links] { if {[dict get $l path] eq [file join $FX linkin]} { set RLROW $l } }
check "a junction ROOT still gets its links row" [expr {
    $RLROW ne "" && [dict get $RLROW tag] eq "0xa0000003" &&
    [dict get $RLROW surrogate] == 1 && [dict get $RLROW action] eq "descended"}]
check "and the same root spelled with a trailing separator too" [expr {
    [llength [dict get [valof {dirs [file join $FX linkin]/}] links]] == 1}]
# An ordinary root must NOT acquire one, or the row means nothing.
check "an ordinary root produces no links row of its own" [expr {
    ![dict exists $LROWS $FX]}]

# GATE 8: THE DIVERGENCE FROM z, which is the one decision here that is not
# inherited. z refuses to descend anything carrying FILE_ATTRIBUTE_REPARSE_POINT;
# this refuses only NAME SURROGATES (tag & 0x20000000), so a cloud placeholder,
# a DEDUP store or a WIM projection is walked instead of silently omitted --
# 124,145 directories under one OneDrive root, measured.
#
# THE SUBJECT IS FOUND WITH fsutil, NOT WITH `dirs`. The first version of this
# gate scanned the verb's own `links` rows for one with `surrogate 0` and
# skipped when it found none. That is the shape that empties itself under
# exactly the defect it exists to catch, and it was not a theoretical worry: a
# build patched to use z's blanket rule marks every reparse point a surrogate,
# emits no such row, the gate skipped -- and NOTHING ELSE in this file fired
# either. Measured, 0 failures out of 576 checks. So the oracle is external, and
# its absence is SAID rather than passed over, because a non-surrogate reparse
# point cannot be created here without either elevation or FSCTL_SET_REPARSE_POINT.
set HOMEDIR [string map {\\ /} $env(USERPROFILE)]
set NONSURR "" ; set NONTAG ""
foreach cand [glob -nocomplain -types d -directory $HOMEDIR *] {
    if {[catch {exec fsutil reparsepoint query [DirsNat $cand]} q]} continue
    if {![regexp {Reparse Tag Value\s*:\s*(0x[0-9a-fA-F]+)} $q -> t]} continue
    if {($t & 0x20000000) == 0} { set NONSURR $cand ; set NONTAG $t ; break }
}
if {$NONSURR eq ""} {
    puts "     SKIP non-surrogate reparse descent: fsutil found no such directory under $HOMEDIR"
    puts "          (the surrogate rule is then exercised against junctions only)"
} else {
    set HOMEW [valof {dirs $HOMEDIR -depth 2}]
    set nrow ""
    foreach l [dict get $HOMEW links] { if {[dict get $l path] eq $NONSURR} { set nrow $l } }
    check "a non-surrogate reparse directory is classified as such" [expr {
        $nrow ne "" && [dict get $nrow surrogate] == 0
        && [dict get $nrow tag] == $NONTAG && [dict get $nrow action] eq "descended"}]
    check "and it is DESCENDED, where z would stop" [expr {
        [lsearch -glob [dict get $HOMEW paths] $NONSURR/*] >= 0}]
    if {$nrow eq ""} { puts "     no links row at all for $NONSURR (tag $NONTAG)" }
    # AND WHEN IT IS THE ROOT ITSELF. The root's tag is read through a handle,
    # and a cloud filter CONSUMES its own reparse point on open -- the top of
    # dirs.c records exactly this measurement -- so the root of such a tree read
    # back as an ordinary directory and `links` came back EMPTY. Narrowing a walk
    # to the divergent subtree was therefore the one invocation that lost the
    # disclosure, while naming the parent kept it. That is the junction-root
    # silence this verb was already fixed for once, in the other spelling; the
    # parent's scan supplies the row now, for disclosure only and never for the
    # veto.
    set NROOTW [valof {dirs $NONSURR -depth 1}]
    set nrrow ""
    foreach l [valof {dict get $NROOTW links}] {
        if {[dict get $l path] eq $NONSURR} { set nrrow $l }
    }
    check "a non-surrogate reparse point NAMED AS THE ROOT is disclosed too" [expr {
        $nrrow ne "" && [dict get $nrrow surrogate] == 0
        && [dict get $nrrow tag] == $NONTAG && [dict get $nrrow action] eq "descended"}]
    # AND THE DISCLOSURE DOES NOT AUTHORISE ANYTHING. The veto is `noenter &&
    # depth > 0`, so a root is entered whatever its tag says -- you named it, so
    # you get it -- and a fallback that changed that would turn `dirs <junction>`
    # into a one-line answer.
    check "and naming such a root still enters it" [expr {
        [dict get $NROOTW dirs] > 1}]
}
# AND AN ORDINARY DIRECTORY IS STILL NOT A REPARSE POINT, or the fallback above
# would be manufacturing rows: the scan is consulted only when the handle said no.
check "an ordinary root produces no links row of its own" [expr {
    [dict get [valof {dirs $FX/target -depth 0}] links] eq ""}]

# GATE 9: unreadable is COUNTED, never fatal. contract.md confines `denied` to
# `mtps`; a subdirectory you may not open is a row, because failing the whole
# listing would make the verb useless on exactly the machines it is for.
check "an unreadable directory is still listed" [expr {[file join $FX locked] in $GOT}]
if {$DENIED} {
    check "but its child is not"      [expr {[file join $FX locked lchild] ni $GOT}]
    set erows {}
    foreach e [dict get $R errors] { dict set erows [dict get $e path] $e }
    check "and it has exactly one errors row" [expr {
        [llength [dict get $R errors]] == 1 && [dict exists $erows [file join $FX locked]]}]
    if {[dict exists $erows [file join $FX locked]]} {
        set er [dict get $erows [file join $FX locked]]
        check "the row carries a raw win32 code"  [expr {[dict get $er win32] != 0}]
        check "and a reason, without a line break" [expr {
            [dict get $er reason] ne "" &&
            [dict get $er reason] eq [string trim [dict get $er reason]]}]
    }
}

# GATE 10: THE ACCOUNTING INVARIANT, which is the reason the result dict has the
# shape it has: every directory under the root is either in `paths`, or its
# absence is attributable to exactly one counted cause. Three prelude walkers
# went missing silently; this is the arithmetic that makes silence impossible.
#
# THE PREVIOUS VERSION OF THIS GATE COULD NOT FIRE, and its three defects are
# worth naming because each is a shape that recurs.
#   - `if {$absent in $GOT} continue` skipped any probe the walker HAD listed.
#     Over-listing -- descending a junction, which is exactly what this gate
#     exists to catch -- therefore emptied it. Measured: a build whose surrogate
#     veto reads `depth > 1` instead of `depth > 0` descends all three junctions,
#     and the old gate passed with every one of its four probes skipped.
#   - It modelled two of the four counted causes. `pruned` and `depthlimited`
#     were absent from the model and it was never run against a -prune or -depth
#     result anyway, so half the arithmetic was never checked at all.
#   - Its four probes duplicated gate 6 and gate 9.
# So: absence is now REQUIRED as well as accounted, the model carries all four
# causes, and it runs against three different walks of the same fixture.
proc DirsDepth {root p} {
    if {$p eq $root} { return 0 }
    return [llength [split [string trimleft [string range $p [string length $root] end] /] /]]
}
# Every stopping cause this result declares, keyed by the directory it stopped
# AT. `-depth` and `-prune` leave no row -- they are counters plus the option the
# caller passed -- so they are reconstructed from the option, which is precisely
# what a caller closing the arithmetic has to do.
proc DirsStops {r cap prune} {
    set stopped {}
    foreach e [dict get $r errors] { dict set stopped [dict get $e path] errors }
    foreach l [dict get $r links] {
        if {[dict get $l action] ne "descended"} { dict set stopped [dict get $l path] links }
    }
    set root [dict get $r root]
    foreach q [dict get $r paths] {
        if {$cap >= 0 && [DirsDepth $root $q] >= $cap} { dict set stopped $q depthlimited }
        foreach pat $prune {
            if {[string match -nocase $pat [file tail $q]]} { dict set stopped $q pruned }
        }
    }
    return $stopped
}
# How many ancestors of $p stopped the walk. Exactly one is the invariant: zero
# means it vanished with nothing saying why, and the nearest one is the answer.
proc DirsAccounts {r p {cap -1} {prune {}}} {
    set stopped [DirsStops $r $cap $prune]
    set nc 0
    set anc [file dirname $p]
    while {[string length $anc] > 3} {
        if {[dict exists $stopped $anc]} { incr nc }
        set nx [file dirname $anc]
        if {$nx eq $anc} break
        set anc $nx
    }
    return $nc
}
# The directories that GENUINELY EXIST under the root and are deliberately not
# listed -- through the junctions and behind the deny ACE. Written from the
# literal fixture, never from a second walk.
set ABSENT [list [file join $FX linkin tchild] [file join $FX linkout ochild]]
foreach n {.dotname .dothidden deep deeplong {has space} hiddenattr linkin linkout \
           linkup locked order {quote'n[brace]} target} {
    lappend ABSENT [file join $FX linkup $n]
}
if {$DENIED} { lappend ABSENT [file join $FX locked lchild] }
set overlisted {} ; set unaccounted {}
foreach absent $ABSENT {
    if {$absent in $GOT} { lappend overlisted $absent ; continue }
    if {[DirsAccounts $R $absent] != 1} { lappend unaccounted $absent }
}
check "nothing behind a refused descent was listed anyway" [expr {$overlisted eq ""}]
if {$overlisted ne ""} { puts "     over-listed: [lrange $overlisted 0 9]" }
check "every absent directory is attributable to exactly one counted cause" [expr {
    $unaccounted eq ""}]
if {$unaccounted ne ""} { puts "     unaccounted: $unaccounted" }
# The other two causes, each against a walk that actually produces it.
set ACCP [valof {dirs $FX -prune deep}]
set ACCD [valof {dirs $FX -depth 1}]
check "a pruned subtree is attributable too" [expr {
    [file join $FX deep d] ni [dict get $ACCP paths] &&
    [DirsAccounts $ACCP [file join $FX deep d] -1 deep] == 1}]
check "and a depth-limited one" [expr {
    [file join $FX deep d] ni [dict get $ACCD paths] &&
    [DirsAccounts $ACCD [file join $FX deep d] 1 {}] == 1}]

# GATE 11: -depth. The cap is checked AFTER emission, so -depth 0 is the root
# alone and -depth 1 is the root plus its children. `0` never means unlimited --
# unlimited is spelled by leaving the option out, because a sentinel that turns
# a typo into a thousand-fold difference in the answer is the `-timeout 100`
# mistake and the answer here is a whole drive.
set D0 [valof {dirs $FX -depth 0}]
set D1 [valof {dirs $FX -depth 1}]
set D3 [valof {dirs $FX -depth 3}]
check "-depth 0 is the root alone" [expr {[dict get $D0 paths] eq [list $FX]}]
check "-depth 0 counts one refusal" [expr {[dict get $D0 depthlimited] == 1}]
check "-depth 1 is the root and its children" [expr {
    [dict get $D1 dirs] == 14 && [dict get $D1 depthlimited] == 13}]
# The root is depth 0, so under -depth 3 the deepest thing listed is
# deep/d/d -- deep is 1, deep/d is 2, deep/d/d is 3 and is refused descent.
check "-depth 3 stops at three" [expr {
    [file join $FX deep/d/d] in [dict get $D3 paths] &&
    [file join $FX deep/d/d/d] ni [dict get $D3 paths]}]
check "a deeper limit is a superset of a shallower one" [expr {
    [llength [lmap p [dict get $D1 paths] {expr {$p in [dict get $D3 paths] ? [continue] : $p}}]] == 0}]
check "and unlimited is a superset of both" [expr {
    [dict get $R dirs] > [dict get $D3 dirs] && [dict get $R depthlimited] == 0}]
# `depthlimited` COUNTS REFUSALS, NOT ELISIONS, and that is written down here
# because the accounting story invites the opposite reading. Every directory at
# the cap is counted, INCLUDING a leaf with nothing underneath it -- so a nonzero
# `depthlimited` does not mean anything was actually omitted, and it is not the
# number of elided subtrees. `target` holds one leaf, `tchild`, and nothing else:
# under -depth 1 the count is 1 and the answer is nonetheless complete.
set DLEAF [valof {dirs [file join $FX target] -depth 1}]
check "depthlimited counts refusals, leaves included" [expr {
    [dict get $DLEAF dirs] == 2 && [dict get $DLEAF depthlimited] == 1}]

# GATE 12: -prune. It speaks Tcl's own `string match` -- no private pattern
# dialect, which is what `glob`'s did -- matched case-insensitively against the
# base name. A pruned directory is LISTED and not descended, so pruning is a
# descent decision like every other one here.
set P1 [valof {dirs $FX -prune deep}]
check "-prune lists the match and not its contents" [expr {
    [file join $FX deep] in [dict get $P1 paths] &&
    [file join $FX deep/d] ni [dict get $P1 paths] && [dict get $P1 pruned] == 1}]
check "-prune is case-insensitive" [expr {[dict get [valof {dirs $FX -prune DEEP}] pruned] == 1}]
check "-prune takes a glob pattern" [expr {[dict get [valof {dirs $FX -prune deep*}] pruned] == 2}]
check "-prune takes several patterns" [expr {
    [dict get [valof {dirs $FX -prune {deep target}}] pruned] == 2}]
check "the root is never pruned" [expr {
    [dict get [valof {dirs $FX -prune [file tail $FX]}] dirs] == [dict get $R dirs]}]

# GATE 13: how the root is spelled must not change what comes back, and a
# spelling that hides process state is refused rather than honoured.
#
# THE cd IS RESTORED EVEN WHEN THE CHECK RAISES. Measured: with `dirs target`
# made to raise, the run aborted with the process cwd still INSIDE the fixture,
# teardown never ran, and the fixture leaked -- a directory nothing can remove
# while a process is sitting in it.
set here [pwd]
set RELROOT "" ; set DOTROOT ""
try {
    cd $FX
    set RELROOT [dict get [valof {dirs target}] root]
    set DOTROOT [dict get [valof {dirs .}] root]
} finally {
    cd $here
}
check "a relative root resolves"  [expr {$RELROOT eq [file join $FX target]}]
check "and so does ."             [expr {$DOTROOT eq $FX}]
# BOTH HALVES, because the count alone tests nothing here. Measured: disabling
# the entire trailing-separator strip in dirs_prefix leaves every check in this
# block green, since dirs_join independently suppresses a doubled separator when
# the parent already ends in one. The regression is in the REPORTED ROOT --
# the broken build answers `C:/dev/_machteld/docs/` -- and the neighbouring
# "comes back normalised" check only ever ran against $R, whose root was spelled
# without a separator.
set TSEP [valof {dirs $FX/}]
check "a trailing separator changes nothing" [expr {
    [dict get $TSEP dirs] == [dict get $R dirs] && [dict get $TSEP root] eq $FX}]
check "the root comes back normalised, forward-slashed, unprefixed" [expr {
    [dict get $R root] eq $FX && [string first "?" [dict get $R root]] < 0}]

# GATE 13b: THE ROOT SPELLINGS THAT HAD NO GATE AT ALL. All of these were
# sabotaged in one build and the suite reported ALL PASS -- every one is a real,
# user-visible regression that nothing here could see.
#
# One key of one result, or "" if the call raised or the key is absent. `valof`
# stops a regression that makes `dirs` RAISE from aborting the run; it does not
# stop the `dict get` that follows it from aborting on the "" it returns, which
# is the same crash one line later.
proc DirsKey {script key} {
    if {[catch {uplevel 1 $script} r]} { return "" }
    if {![dict exists $r $key]} { return "" }
    return [dict get $r $key]
}
check "a drive root is the root DIRECTORY, not the volume device" [expr {
    [DirsKey {dirs C:/ -depth 0} root] eq "C:/"}]
# \\?\C:\ is the same claim in the spelling that turns normalisation OFF, and it
# is the one the code got wrong: the drive-root exemption tested `fl == 3 &&
# full[1] == ':'`, which is written for C:\ and misses the prefixed form, where
# the colon sits at index 5. The trailing backslash was stripped and the walk was
# handed \\?\C: -- the volume DEVICE its own comment warns about -- so a drive
# root that plainly exists came back `notfound`, in the only spelling that
# reaches the names refused by gate 13d.
check "and so is the prefixed spelling of it" [expr {
    [DirsKey {dirs \\\\?\\C:\\ -depth 0} root] eq "C:/"}]
check "a prefixed root is taken as given" [expr {
    [DirsKey {dirs \\\\?\\[DirsNat $FX]} dirs] == [dict get $R dirs]}]
# The forward-slash spelling of the prefix is not the backslash test, and
# GetFullPathNameW rewrites it into one -- after which the leading \\ was read as
# a UNC name and \\?\UNC\?\C:\... was built, a path that has never existed,
# refused as `notfound`. A wrong path silently constructed, not a rejected
# spelling.
check "and its forward-slash spelling resolves to the same tree" [expr {
    [DirsKey {dirs //?/$FX} dirs] == [dict get $R dirs]}]
check "a device path is refused" [expr {
    [errcode_of {dirs //./PhysicalDrive0}] eq {MACHTELD DIRS badvalue} &&
    [errcode_of {dirs \\\\.\\PhysicalDrive0}] eq {MACHTELD DIRS badvalue}}]
check "an empty root is refused" [expr {[errcode_of {dirs {}}] eq {MACHTELD DIRS badvalue}}]
check "a malformed -prune list is refused" [expr {
    [errcode_of {dirs $FX -prune \{}] eq {MACHTELD DIRS badvalue}}]

# GATE 13c: UNC. The whole `unc` branch -- eight characters of prefix standing in
# for two, undone again on the way out -- had no gate: a build with it broken
# answers `root UNC/localhost/C$/...` and emits every path under a prefix that
# does not exist. An admin share is not guaranteed to be reachable, so the
# subject is probed and its absence is SAID rather than passed over.
set UNCFX //localhost/[string index $FX 0]\$[string range $FX 2 end]
if {[catch {dirs $UNCFX} UR]} {
    puts "     SKIP UNC root: $UNCFX is not reachable ([lindex [errcode_of {dirs $UNCFX}] 2])"
} else {
    check "a UNC root round-trips as //server/share/..." [expr {[dict get $UR root] eq $UNCFX}]
    check "and lists the same tree the drive spelling does" [expr {
        [dict get $UR dirs] == [dict get $R dirs]}]
    # Past the leading `//`, which is the UNC spelling and not a doubled
    # separator -- the failure this looks for is \\?\UNC\server\share\\child,
    # which the join is what prevents.
    check "with no doubled separator anywhere in it" [expr {
        [lsearch -glob [lmap p [dict get $UR paths] {string range $p 2 end}] *//*] < 0}]
}

# GATE 13d: A COMPONENT WIN32 WOULD SILENTLY REWRITE IS REFUSED, NOT HONOURED.
# GetFullPathNameW trims trailing dots and spaces, so `X/...` collapses to `X`:
# measured on the first implementation, `dirs X/...` returned the PARENT's tree
# -- root reported as X, six directories, no error and no row -- while
# `X/trailspace ` and `X/traildot.` failed with `notfound`, which is luck rather
# than design. The walker CREATES and LISTS all four of these happily, so it was
# the verb's own output failing to round-trip, in the one spelling that is silent
# about it. `.` and `..` are the two components where trailing dots are the whole
# meaning; they stay exempt, and the two checks above this one hold them.
foreach n [list ... "trailspace " "traildot." "dots.."] {
    check "a root component normalisation would rewrite is refused (<$n>)" [expr {
        [errcode_of {dirs $FX/$n}] eq {MACHTELD DIRS badvalue}}]
}
check "and the prefixed spelling is the escape hatch that still works" [expr {
    [DirsKey {dirs \\\\?\\[DirsNat $FX]\\deep} dirs] == $DEEPN + 1}]

# GATE 14: the error contract. Every code is one contract.md already carries --
# `denied` stays confined to `mtps` and `depth` means C recursion, which an
# iterative walk over a heap stack cannot do.
check "a missing root => notfound"    [expr {[errcode_of {dirs $FX/nope_zzz}] eq {MACHTELD DIRS notfound}}]
check "a FILE as root => notfound"    [expr {
    [errcode_of {dirs [file join $FX afile.txt]}] eq {MACHTELD DIRS notfound}}]
check "-depth nope => badvalue"       [expr {[errcode_of {dirs $FX -depth nope}] eq {MACHTELD DIRS badvalue}}]
check "-depth -1 => badvalue"         [expr {[errcode_of {dirs $FX -depth -1}] eq {MACHTELD DIRS badvalue}}]
check "a drive-relative root => badvalue" [expr {[errcode_of {dirs C:}] eq {MACHTELD DIRS badvalue}}]
check "an unknown option => usage"    [expr {[errcode_of {dirs $FX -nosuch v}] eq {MACHTELD DIRS usage}}]
check "an option with no value => usage" [expr {[errcode_of {dirs $FX -depth}] eq {MACHTELD DIRS usage}}]
check "no argument => Tcl's own WRONGARGS" [expr {[lindex [errcode_of {dirs}] 0] eq "TCL"}]
check "dirs raises in its own domain" [expr {[lindex [errcode_of {dirs $FX -nosuch v}] 1] eq "DIRS"}]

# GATE 14b: A FAILING CALL COSTS NOTHING THAT IS NOT GIVEN BACK. The three
# result lists are created before the root is even parsed and are adopted only by
# the result dict, so every error return had to free them by hand and eight did
# not: measured on the shipped exe, 144 bytes a call -- exactly 3 x
# sizeof(Tcl_Obj) in Tcl 9 -- linear over 200,000 calls with no plateau, against
# a success path that plateaus at zero after the first batch.
#
# It is gated rather than merely fixed because the suite exercises each error
# code ONCE, which is the one call count at which an unbounded leak is invisible,
# and because `notfound` is what a directory that vanished between two walks
# answers: `foreach p $roots {catch {dirs $p}}` is the ordinary way to probe
# candidates and the host is a long-lived front door. The bound is deliberately
# loose -- 20,000 calls leaked 2.8 MB, so anything under 1 MB is a fix and not a
# smaller leak, and the allocator's own first-touch growth is warmed off first.
proc DirsMem {} {
    foreach p [mtps list] { if {[dict get $p pid] == [pid]} { return [dict get $p mem] } }
    return 0
}
foreach i {1 2 3} { catch {dirs $FX/nope_zzz} ; catch {dirs $FX -nosuch v} }
set LEAKN 20000
set memA [DirsMem]
for {set i 0} {$i < $LEAKN} {incr i} { catch {dirs $FX/nope_zzz} }
set memB [DirsMem]
for {set i 0} {$i < $LEAKN} {incr i} { catch {dirs $FX -depth nope} }
set memC [DirsMem]
check "a failing dirs does not leak its result lists" [expr {
    $memB - $memA < 1048576 && $memC - $memB < 1048576}]
if {$memB - $memA >= 1048576 || $memC - $memB >= 1048576} {
    puts [format "     notfound: %+d bytes over %d calls (%.1f/call);\
 badvalue: %+d (%.1f/call)" [expr {$memB-$memA}] $LEAKN \
        [expr {($memB-$memA)/double($LEAKN)}] [expr {$memC-$memB}] \
        [expr {($memC-$memB)/double($LEAKN)}]]
}

# GATE 15: the manifest against the running verb, not against the source that
# was scanned to build it.
set MD [manifest]
check "manifest dirs returns matches reality" [expr {
    [lsort [dict keys $R]] eq [lsort [dict get $MD dirs returns]]}]
check "manifest dirs declares its options" [expr {
    [lsort [dict get $MD dirs options]] eq {-depth -prune}}]
check "a declared option is accepted" [expr {[errcode_of {dirs $FX -prune {}}] eq ""}]
check "dirs is a C verb, with no Tcl proc behind it" [expr {
    [dict get $MD dirs kind] eq "c" && ![llength [info procs ::machteld::dirs]]}]
# THE CODES, WHICH WERE OUTSIDE THIS GATE AND SHOULD NOT HAVE BEEN. Fixing the
# result-list leak by folding free-and-raise into one helper --
# `dirs_bail(interp, &w, "usage", msg)` -- moved the code literal out of the
# second argument position, which is where genmanifest.tcl's
# `\w+_error\(interp,\s*"([a-z]+)"` looks for it. The build reported
# `dirs domain=DIRS codes=1` against a truth of four, every one of the 600
# checks below still passed, and `manifest dirs codes` quietly became a lie.
# Creed 4 is the palette describing ITSELF; a generator that can be blinded by a
# refactor needs a gate that notices, in the file whose whole subject is a
# regression nothing announces.
check "manifest dirs declares every code it can throw" [expr {
    [lsort [dict get $MD dirs codes]] eq {badvalue notfound oserror usage}}]
set DTHREW {}
foreach s {{dirs $FX/nope_zzz} {dirs [file join $FX afile.txt]} {dirs $FX -depth nope}
           {dirs C:} {dirs {}} {dirs $FX -nosuch v} {dirs $FX -depth}} {
    set c [lindex [errcode_of $s] 2]
    if {$c ne ""} { dict set DTHREW $c 1 }
}
check "and every code it actually threw is declared" [expr {
    [llength [lmap c [dict keys $DTHREW] {
        expr {$c in [dict get $MD dirs codes] ? [continue] : $c}}]] == 0}]

# --- `cdirs`: the front-door command over the `dirs` verb ---------------------
#
# THE VERB IS GATED IN THE 102 CHECKS ABOVE; WHAT IS NEW HERE IS POLICY. Where
# the file goes, when a report is written, what the report SAYS -- and every one
# of those is a silence when it is wrong: a list written to the wrong place, a
# stale report read as current, a consequence not disclosed. z's own stats line
# is the shape being replaced, and it is worth stating exactly what is wrong
# with it, because these gates are aimed at that: "12 links skipped" is
# arithmetically true, names none of the twelve, and on this machine one of them
# hid 124,144 directories while the other eleven hid a few hundred between them.
#
# The subject is the `mt_dirs_[pid]` fixture the block above already erected --
# reused rather than rebuilt, since building a second one would double the
# slowest setup in this file and prove nothing the first does not.
set CDOUT [file join [string map {\\ /} $env(TEMP)] mt_cdirs_[pid]]
file delete -force $CDOUT
file mkdir $CDOUT
# THE BARE NAME, NOT `front cdirs`, and the difference is not cosmetic. `mt
# cdirs` goes through the argv dispatcher, `FrontResolve` and `FrontExec` before
# reaching the command -- which is how a person types it, and which is also the
# path that exposed the empty-list encoding defect these gates now carry: the
# same build wrote `"entered":{}` through the dispatcher and `"entered":[]`
# through `front cdirs`, because the two paths leave Tcl's shared empty-string
# literal in different states. Testing the shorter spelling would have been
# testing the path where the bug was invisible.
proc CdirsRun {args} {
    set r [run -timeout 300s -- $::MT cdirs {*}$args]
    return [list [dict get $r exit] [dict get $r out] [dict get $r err]]
}
proc CdirsLines {f} {
    if {![file exists $f]} { return "" }
    set fh [open $f r] ; fconfigure $fh -encoding utf-8 -translation lf
    set t [read $fh] ; close $fh
    set l {}
    foreach x [split [string trimright $t \n] \n] { if {$x ne ""} { lappend l $x } }
    return $l
}
# A `dirs` RESULT WITHOUT A DISK. `FrontDirsReport` is a pure dict->dict
# function, and that is the whole reason it is a separate proc from the renderer:
# the verdict logic and the errors/links join can be pointed at situations this
# machine cannot be made to produce -- a DFS tag, a reparse point that failed to
# open, a cloud root beside a junction -- instead of only at the ones a fixture
# happens to reach. The review of `dirs` itself found FIVE gates that could not
# fail, every one of them aimed at a subject incapable of showing the defect.
proc CdirsFake {args} {
    set d [dict create root C:/fx paths [list C:/fx] dirs 1 maxdepth 0 \
               links {} errors {} pruned 0 depthlimited 0]
    foreach {k v} $args { dict set d $k $v }
    return $d
}
proc CdirsLink {path tag surrogate action} {
    return [dict create path $path tag $tag surrogate $surrogate action $action]
}

# CD1: the slug, which is the whole defence against z's naming defect. `z cdirs
# --root C:\dev` writes 21,804 workspace directories into a file called
# `c-drive-dirs.txt`, overwriting the drive index -- a name that lies, and a
# species of lie this project has spent a lot of its history removing. Four
# shapes of root, and the long one because AppData/Local/Packages paths on this
# machine really do exceed the cap.
check "the slug of a drive root"   [expr {[::machteld::FrontDirsSlug C:/] eq "c"}]
check "the slug of the workspace"  [expr {[::machteld::FrontDirsSlug C:/dev] eq "c-dev"}]
check "the slug of a deep root"    [expr {
    [::machteld::FrontDirsSlug C:/Users/anafa] eq "c-users-anafa"}]
check "the slug of a UNC root"     [expr {
    [::machteld::FrontDirsSlug //srv/share/x] eq "srv-share-x"}]
set CDLONG "C:/Users/anafa/AppData/Local/Packages/Claude_pzs8sxrjxfjjc/LocalCache/Roaming/uv"
set CDSLUG [::machteld::FrontDirsSlug $CDLONG]
check "a long root is capped and gets a hash tail" [expr {
    [string length $CDSLUG] == 64 && [regexp -- {-[0-9a-f]{8}$} $CDSLUG]}]
# DETERMINISTIC, or the cache never hits and every run leaves another file.
check "and the same root slugs the same way twice" [expr {
    $CDSLUG eq [::machteld::FrontDirsSlug $CDLONG]}]
# TWO ROOTS SHARING A 55-CHARACTER PREFIX MUST NOT COLLIDE, which is exactly
# what the cap would cause without the hash -- and AppData is full of siblings
# that long.
check "two long roots with the same prefix do not collide" [expr {
    [::machteld::FrontDirsSlug $CDLONG/python/cpython-3.12] ne
    [::machteld::FrontDirsSlug $CDLONG/python/cpython-3.14]}]
# AND THE SHORT ONES, WHICH IS WHERE THE OLD GATE WAS POINTED AWAY FROM. The
# collision check above tests only the >64-character case -- i.e. exactly the
# branch where the hash makes the guarantee hold -- while the squash
# `[^a-z0-9]+ -> -` is many-to-one precisely among the SHORT, ordinary roots.
# Two of these pairs were found colliding among the real indices on this machine,
# not invented: `.codex/.tmp` against `.codex/tmp`, and `OneDrive/_LIVE` against
# `OneDrive/live`. `C:/dev/_x` is a real directory here too.
foreach {cda cdb} [list \
        C:/dev/_x                  C:/dev-x \
        C:/dev.x                   C:/dev/x \
        "C:/dev x"                 C:/dev/_x \
        //a/b                      A:/b \
        C:/Users/anafa/.codex/.tmp C:/Users/anafa/.codex/tmp \
        C:/Users/anafa/OneDrive/_LIVE C:/Users/anafa/OneDrive/live] {
    check "`$cda` and `$cdb` do not slug to one file" [expr {
        [::machteld::FrontDirsSlug $cda] ne [::machteld::FrontDirsSlug $cdb]}]
}
# THE SHARPEST CASE: a component that survives the squash as NOTHING makes a root
# slug to its PARENT, so `C:/Users/anafa/<non-ASCII>` wrote itself over
# `c-users-anafa.txt` -- the home index, the flagship artefact of this command.
check "a root whose last component is non-ASCII does not slug to its parent" [expr {
    [::machteld::FrontDirsSlug C:/Users/anafa/\u00c4] ne
    [::machteld::FrontDirsSlug C:/Users/anafa]}]
# AND THE READABLE NAMES ARE NOT PAID FOR THIS. A hash on every root would make
# the four checks above pass and every cache file unreadable; the four at the top
# of this block are what stops that, and this one says the discrimination is the
# point rather than a side effect.
check "a lossy root is marked as lossy, and a clean one is not" [expr {
    [regexp -- {--[0-9a-f]{8}$} [::machteld::FrontDirsSlug C:/dev/_x]]
    && ![regexp -- {--} [::machteld::FrontDirsSlug C:/dev/x]]}]

# CD2: the tag table. `dfs` and `dfsr` are the rows that matter here: they are
# vetoed by `dirs.c` although they do NOT set the surrogate bit, they have never
# been observed on this machine, and no fixture can create one -- so a unit
# check on the naming function is the only place they are reachable at all.
foreach {tag want} {0xa0000003 junction 0xa000000c symlink 0x8000000a dfs
                    0x80000012 dfsr 0x9000701a cloud 0x9000001a cloud
                    0x9000f01a cloud 0x00000000 reparse} {
    check "tag $tag is named `$want`" [expr {[::machteld::FrontDirsTag $tag] eq $want}]
}
# THE EMPTY-LIST FORM, in this process. Said plainly rather than oversold: this
# check was written believing it was the deterministic one and it is NOT -- with
# the helper deliberately broken to `return {}` it stayed GREEN here, because
# whether a bare empty string encodes as `[]`, `{}` or `""` depends on what the
# rest of the interpreter did to Tcl's single shared empty-string object, and
# this suite's own process happened to have left it list-shaped. The claim is
# carried by the WIRE checks further down, which read the bytes a real run wrote
# in its own process. This one stays because it is free and states the intent.
check "the empty-list form is an empty list, and encodes as an array here" [expr {
    [llength [::machteld::FrontEmptyList]] == 0
    && [json encode [dict create k [::machteld::FrontEmptyList]]] eq {{"k":[]}}}]
# AND AN UNKNOWN TAG IS NOT GUESSED AT. A table of half-remembered reparse
# constants would be the front door asserting knowledge the C's veto rule does
# not have, and the two would drift with nothing to notice.
check "an unrecognised tag comes back as its own hex" [expr {
    [::machteld::FrontDirsTag 0x12345678] eq "0x12345678"}]

# CD3: THE VERDICT AND THE JOIN, on synthesised results.
set CDR [::machteld::FrontDirsReport [CdirsFake] 5 "" {}]
check "a walk that refused nothing is COMPLETE" [expr {
    [dict get $CDR complete] == 1 && [dict get $CDR refused] eq ""
    && [dict get $CDR entered] eq ""}]
set CDR [::machteld::FrontDirsReport [CdirsFake links \
    [list [CdirsLink C:/fx/j 0xa0000003 1 nofollow]]] 5 "" {}]
check "one nofollow link makes it PARTIAL, with the place NAMED" [expr {
    [dict get $CDR complete] == 0 && [llength [dict get $CDR refused]] == 1
    && [dict get [lindex [dict get $CDR refused] 0] path] eq "C:/fx/j"
    && [dict get [lindex [dict get $CDR refused] 0] why] eq "junction"}]
set CDR [::machteld::FrontDirsReport [CdirsFake errors \
    [list [dict create path C:/fx/locked win32 5 reason "Access is denied."]]] 5 "" {}]
check "an unreadable directory is named, with its raw win32 code" [expr {
    [dict get $CDR complete] == 0 && [llength [dict get $CDR refused]] == 1
    && [dict get [lindex [dict get $CDR refused] 0] why] eq "unreadable"
    && [dict get [lindex [dict get $CDR refused] 0] win32] == 5}]
# THE JOIN, WHICH IS THE EASIEST THING HERE TO GET WRONG. A `failed` link always
# has an `errors` row beside it -- the descent was attempted and the open failed
# -- so concatenating the two lists reports one place TWICE and makes the
# headline count disagree with the rows printed under it.
set CDR [::machteld::FrontDirsReport [CdirsFake \
    links  [list [CdirsLink C:/fx/j 0xa0000003 1 failed]] \
    errors [list [dict create path C:/fx/j win32 5 reason "Access is denied."]]] 5 "" {}]
check "a failed link is ONE row carrying both its tag and its win32" [expr {
    [llength [dict get $CDR refused]] == 1
    && [dict get [lindex [dict get $CDR refused] 0] tag] eq "0xa0000003"
    && [dict get [lindex [dict get $CDR refused] 0] win32] == 5
    && [dict get [lindex [dict get $CDR refused] 0] why] eq "junction"}]
# A CALLER'S OWN REFUSAL IS COUNTED, NEVER NAMED -- and the link rows carrying
# those actions must not reach `refused`, because `dirs.c` has ALREADY counted
# them in the integers. Counting them twice breaks the arithmetic the palette
# guarantees: every absent directory attributable to exactly one cause.
set CDR [::machteld::FrontDirsReport [CdirsFake pruned 4 depthlimited 7 links \
    [list [CdirsLink C:/fx/p 0xa0000003 1 pruned] \
          [CdirsLink C:/fx/q 0xa0000003 1 depthlimited]]] 5 3 {node_modules}]
check "prune and depth refusals are counted, and add nothing to refused" [expr {
    [dict get $CDR complete] == 0 && [dict get $CDR refused] eq ""
    && [dict get $CDR pruned] == 4 && [dict get $CDR depthlimited] == 7}]
# ONE SUBJECT PER TERM, because the verdict is a THREE-TERM CONJUNCTION and the
# subject above sets both counters at once -- so either term could be deleted
# outright and the other still returned 0. Measured: both deletions left all 701
# checks green, on a build whose headline then read `[COMPLETE]` above a body
# saying `9 directories at the -depth 1 limit`. A headline contradicting its own
# body, on the fail-dangerous side, with nothing red.
set CDR [::machteld::FrontDirsReport [CdirsFake pruned 4] 5 "" {node_modules}]
check "`pruned` alone is enough to make the verdict PARTIAL" [expr {
    [dict get $CDR complete] == 0 && [dict get $CDR depthlimited] == 0}]
set CDR [::machteld::FrontDirsReport [CdirsFake depthlimited 7] 5 1 {}]
check "`depthlimited` alone is enough to make the verdict PARTIAL" [expr {
    [dict get $CDR complete] == 0 && [dict get $CDR pruned] == 0}]
# THE REVERSE SILENCE. A reader expecting z's semantics gets more than twice the
# lines and no way to learn why; a descended non-surrogate is disclosed too.
proc CdirsCloud {args} {
    return [CdirsFake dirs 3 paths [list C:/fx C:/fx/cloud C:/fx/cloud/a] \
                links [list [CdirsLink C:/fx/cloud 0x9000701a 0 descended]] {*}$args]
}
set CDR [::machteld::FrontDirsReport [CdirsFake links \
    [list [CdirsLink C:/fx/cloud 0x9000701a 0 descended]]] 5 "" {}]
check "a descended non-surrogate is disclosed, and is not a refusal" [expr {
    [dict get $CDR complete] == 1 && [llength [dict get $CDR entered]] == 1
    && [dict get [lindex [dict get $CDR entered] 0] why] eq "cloud"
    && [dict get [lindex [dict get $CDR entered] 0] surrogate] == 0}]
# THE MAGNITUDE, WHICH IS THE HALF THAT SHIPPED MISSING. z's defect is "counted,
# consequence invisible"; a report that names the place and gives no number is
# the same failure with the terms swapped, and on the real home tree that one row
# accounts for 124,144 of 236,162 lines. Counted by PREFIX over the walk's own
# paths, so a renderer that lost the count cannot be papered over by the row.
set CDR [::machteld::FrontDirsReport [CdirsCloud] 5 "" {}]
# `dict exists` FIRST, not a bare `dict get`. Measured while break-testing this
# very block: the version without it RAISED on the build with `below` removed,
# the run aborted at that line, and the two hundred checks after it silently
# never ran -- the failure `valof` exists in this file to stop, met again.
check "and it carries how much of the answer came from under it" [expr {
    [dict exists [lindex [dict get $CDR entered] 0] below]
    && [dict get [lindex [dict get $CDR entered] 0] below] == 1}]
# A DESCENDED SURROGATE IS THE ROOT, so `below` is the whole list by
# construction; asserted rather than assumed, because the two arms are different
# code.
set CDR [::machteld::FrontDirsReport [CdirsFake dirs 3 \
    paths [list C:/fx C:/fx/a C:/fx/b] links \
    [list [CdirsLink C:/fx 0xa0000003 1 descended]]] 5 "" {}]
check "a descended surrogate root counts the whole list below it" [expr {
    [dict exists [lindex [dict get $CDR entered] 0] below]
    && [dict get [lindex [dict get $CDR entered] 0] below] == 2}]
# THE RENDERED TEXT, AND NOT ONLY THE JSON. Only the JSON array (CD12) and the
# SURROGATE paragraph below were gated, so the whole non-surrogate block could be
# deleted from `FrontDirsText` with all 701 checks green -- measured. That is the
# paragraph answering "why 236,162 where z says 112,018", i.e. this command's
# entire reason for existing, able to vanish from the human output in silence.
set CDR [::machteld::FrontDirsReport [CdirsCloud] 5 "" {}]
set CDTEXT [valof {::machteld::FrontDirsText $CDR}]
check "the text says the entered place is content, names it, and sizes it" [expr {
    [string match "*content, not a second name for*" $CDTEXT]
    && [string match "*C:/fx/cloud*" $CDTEXT]
    && [string match "*tag 0x9000701a*" $CDTEXT]
    && [string match "*1 of the 3 directories above*" $CDTEXT]}]
# AND THE COMPLETENESS SENTENCE IS CONDITIONAL. `Everything under it IS in the
# count above` used to print unconditionally -- including under `-depth 3` on the
# home tree, where ~124,000 directories below that very row are NOT in the count.
# A report telling the reader the list is complete below a place where it is not,
# in the one direction this command exists to prevent, with no gate reading the
# string.
check "a clean walk keeps the strong completeness sentence" [expr {
    [string match "*everything under it IS in the count above*" $CDTEXT]}]
foreach {cdlabel cdsub} [list \
        "a -depth limit"  [CdirsCloud depthlimited 1] \
        "a -prune"        [CdirsCloud pruned 1] \
        "a refusal below the entered place" \
            [CdirsCloud errors [list [dict create path C:/fx/cloud/a win32 5 \
                                          reason "Access is denied."]]]] {
    set cdt [valof {::machteld::FrontDirsText \
                    [::machteld::FrontDirsReport $cdsub 5 "" {}]}]
    check "$cdlabel withdraws it" [expr {
        ![string match "*everything under it IS in the count*" $cdt]
        && [string match "*only PARTLY in the count above*" $cdt]}]
}
# AND A REFUSAL SOMEWHERE ELSE ENTIRELY DOES NOT, or the sentence would be
# withdrawn on every real walk and mean nothing.
set cdt [valof {::machteld::FrontDirsText [::machteld::FrontDirsReport \
    [CdirsCloud errors [list [dict create path C:/fx/other win32 5 \
                                  reason "Access is denied."]]] 5 "" {}]}]
check "a refusal outside the entered place leaves it standing" [expr {
    [string match "*everything under it IS in the count above*" $cdt]}]
# A SURROGATE THAT WAS DESCENDED CAN ONLY BE THE ROOT YOU NAMED, and the verb's
# own review found this exact disclosure missing: a junction root produced no
# `links` row at all, so nothing anywhere said every path returned was a second
# name for a tree living elsewhere, and 576 checks passed over it.
set CDR [::machteld::FrontDirsReport [CdirsFake links \
    [list [CdirsLink C:/fx 0xa0000003 1 descended]]] 5 "" {}]
# `valof`, because the renderer is the thing under test and a regression in it
# raises rather than returning something wrong. Measured while break-testing this
# block: a broken `FrontDirsReport` made `FrontDirsText` throw here, the run
# aborted at this line, and the forty checks after it silently never ran -- the
# exact failure `valof` exists in this file to stop, met for the fourth time.
set CDTEXT [valof {::machteld::FrontDirsText $CDR}]
check "a junction ROOT is disclosed as a second name for somewhere else" [expr {
    [llength [dict get $CDR entered]] == 1
    && [string match "*NAMED it*" $CDTEXT]
    && [string match "*second name for a tree living elsewhere*" $CDTEXT]}]

# CD4: the list file. ORDER INCLUDED -- a count would let an emission-order
# change through, and the order is contract because this file gets diffed
# against yesterday's.
set CDOUT1 [file join $CDOUT list1.txt]
lassign [CdirsRun $FX -out $CDOUT1] cdex cdout cderr
check "cdirs writes its list"        [expr {$cdex == 0 && [file exists $CDOUT1]}]
check "and the list is dirs' answer, order included" [expr {
    [CdirsLines $CDOUT1] eq [dict get $R paths]}]
check "one line per path, and no header" [expr {
    [llength [CdirsLines $CDOUT1]] == [dict get $R dirs]}]
# LF AND UTF-8 AND NO BOM, none of which is Tcl's default on Windows: `auto`
# translation emits CRLF, and the fixture's own names are why the encoding
# matters -- U+E000 beside U+E001 is in the tree three hundred lines above
# precisely because CP_ACP collapses them.
set cdfh [open $CDOUT1 rb] ; set cdraw [read $cdfh] ; close $cdfh
check "the list is LF-terminated, with no CR anywhere" [expr {
    [string first "\r" $cdraw] < 0 && [string index $cdraw end] eq "\n"}]
check "and carries no BOM" [expr {[string range $cdraw 0 2] ne "\xef\xbb\xbf"}]
check "and is forward-slashed, like the verb's own answer" [expr {
    [string first "\\" $cdraw] < 0}]
check "a non-ASCII name survives the round trip through the file" [expr {
    [file join $FX order \ue000] in [CdirsLines $CDOUT1]
    && [file join $FX order \ue001] in [CdirsLines $CDOUT1]}]

# CD5: THE REPORT SIDECAR IS ALWAYS WRITTEN, and that is the deliberate
# difference from z. z creates `<out>.errors.txt` unconditionally and mentions it
# only sometimes, so its presence says nothing and its absence has two meanings:
# clean run, or the run died before it got there. Here the sidecar is the WHOLE
# report, so its presence is unambiguous -- and the list file stays pure paths,
# because a header would stop it being greppable.
set CDREP1 [file join $CDOUT list1.json]
check "a report sidecar is written beside the list, always" [expr {[file exists $CDREP1]}]
# `valof` around the decode, and `dict exists` in the checks: the SUBJECT of
# these gates is a file that stops existing when the thing under test regresses,
# so a missing sidecar has to make them FAIL rather than abort the run at this
# line and silently skip the forty checks below. Measured while break-testing --
# deleting the sidecar write took the whole block out and reported one failure
# where there should have been several.
set CDJ [valof {json decode [lindex [CdirsLines $CDREP1] 0]}]
check "the sidecar is the report, and names both files" [expr {
    [dict exists $CDJ list] && [dict get $CDJ list] eq $CDOUT1
    && [dict get $CDJ report] eq $CDREP1
    && [dict get $CDJ dirs] == [dict get $R dirs]
    && [dict get $CDJ bytes] == [file size $CDOUT1]}]
# `paths` IS DELIBERATELY NOT IN THE REPORT. The list is the file; a JSON
# document carrying 236,150 strings is not what any caller of a cache-building
# command wants, and `-stdout` is how you ask for the paths.
check "the report does not carry the paths" [expr {
    [dict exists $CDJ dirs] && ![dict exists $CDJ paths]}]
# EVERY REFUSAL SURVIVES THE WIRE AS AN OBJECT WITH A PATH.
#
# THIS REPLACED A VACUOUS GATE, and the replacement is the point. What stood here
# first asserted that a clean walk encodes `refused` as `[]` and not `{}` --
# a real hazard, since `json encode` decides array-versus-object from a value's
# internal representation. It could not fail. The verdict computation calls
# `llength` on the same list two lines earlier, which shimmers it to a list
# object, so `set refused {}` and `set refused [list]` and even `expr {... : ""}`
# all encoded as `[]`. Proved by breaking it three different ways and watching
# nothing go red. (The prelude now says `lrange` there, so the shape is a
# guarantee rather than a side effect of where `llength` happens to sit.)
#
# What is checked instead has a live failure mode: flatten the rows -- the
# obvious wrong way to build `refused` -- and the elements stop being objects.
set cdshape [expr {[dict exists $CDJ refused] ? "" : "no refused key at all"}]
foreach r [valof {dict get $CDJ refused}] {
    if {![string is list $r] || [llength $r] % 2 || ![dict exists $r path]
        || ![dict exists $r why]} { lappend cdshape $r }
}
check "every refusal reaches the wire as an object with a path and a reason" [expr {
    [dict exists $CDJ refused] && [llength [dict get $CDJ refused]] >= 2
    && $cdshape eq ""}]
lassign [CdirsRun [file join $FX target] -out [file join $CDOUT clean.txt] -json] cdex cdjs cderr
set cdclean [valof {json decode $cdjs}]
check "a walk that refused nothing still carries both keys" [expr {
    [dict exists $cdclean refused] && [dict exists $cdclean entered]
    && [llength [dict get $cdclean refused]] == 0
    && [llength [dict get $cdclean entered]] == 0}]
# AND THEY ARE EMPTY ARRAYS ON THE WIRE, NOT EMPTY OBJECTS -- asserted on the
# RAW TEXT, because `json decode` turns `{}` and `[]` into the same
# zero-length Tcl value and a gate written with `llength` cannot tell them
# apart. That is not a hypothetical distinction: it shipped. The sidecar of a
# clean run carried `"entered":{}` and `"prune":{}` while the -json form of the
# same run carried `[]`, because `json encode` reads the value's internal
# representation and Tcl's empty string is ONE SHARED OBJECT per interpreter --
# so the answer depended on what an unrelated line had done to that literal
# earlier in the process. A consumer looping over `report.refused` breaks on
# `{}`, and the common case is exactly the one that produced it.
#
# TWO SUBJECTS, AND THE SECOND IS THE ONE THAT CATCHES IT. A walk with nothing
# refused anywhere was green on the broken build; the walk that reproduced the
# defect had a NON-EMPTY `refused` beside an empty `entered`, which is the
# ordinary shape of a real run and the shape the fixture has. Checking only the
# all-empty case is checking the case where the bug hides.
foreach {cdwhere cdtext} [list \
        "the -json form of a clean walk" $cdjs \
        "a clean walk's sidecar"     [lindex [CdirsLines [file join $CDOUT clean.json]] 0] \
        "a sidecar with refusals in it" [lindex [CdirsLines $CDREP1] 0]] {
    set cdobj {}
    set cddec [valof {json decode $cdtext}]
    foreach k {refused entered prune} {
        if {![dict exists $cddec $k]} { lappend cdobj "$k missing" ; continue }
        if {[llength [dict get $cddec $k]]} continue      ;# non-empty renders fine
        if {[string first "\"$k\":\[\]" $cdtext] < 0} { lappend cdobj $k }
    }
    check "$cdwhere spells an empty list as an ARRAY" [expr {$cdobj eq ""}]
    if {$cdobj ne ""} { puts "     not an array in $cdwhere: $cdobj" }
}

# CD6: THE DEFAULT PATH IS DERIVED FROM MT_HOME, and this proves it WITHOUT ever
# writing to the real one. `FrontRoots` honours MT_ROOT/MT_HOME when both are set
# and MT_HOME exists, so the whole workspace is redirected into %TEMP% for one
# child. A gate hardcoding `C:/dev/.z` would be asserting this machine's layout;
# a gate running without the override would CLOBBER the live cache from a test.
set CDWS   [file join $CDOUT ws]
set CDHOME [file join $CDWS .mt]
file mkdir $CDHOME
set cdr [run -timeout 300s -env [list MT_ROOT $CDWS MT_HOME $CDHOME] -- \
             $MT front cdirs $FX -depth 1]
set CDDEF [file join $CDHOME cache mt dirs "[::machteld::FrontDirsSlug $FX].txt"]
check "the default output path is derived from MT_HOME" [expr {
    [dict get $cdr exit] == 0 && [file exists $CDDEF]}]
check "and the report names the file it wrote" [expr {
    [string match "*[file tail $CDDEF]*" [dict get $cdr out]]}]
# AND IT IS NOT z's FILE. During the transition MT_HOME *is* `.z`, so a default
# of `cache/cdirs/c-drive-dirs.txt` would have machteld overwrite the live cache
# of the front door still in daily use -- with a forward-slashed list that is
# also 2.1x longer on the home tree. Two silent incompatibilities in one file.
check "the default is not z's cache file" [expr {
    ![string match "*c-drive-dirs.txt*" $CDDEF]
    && ![string match "*cache/cdirs/*" [string map {\\ /} $CDDEF]]}]
# THE DEFAULT ROOT IS THE WORKSPACE, asserted on the reported ROOT rather than on
# a count: a count is satisfied by any tree of the same size, and the whole point
# of this default is WHICH tree it is.
set cdr [run -timeout 300s -env [list MT_ROOT $CDWS MT_HOME $CDHOME] -- \
             $MT front cdirs -depth 0 -json]
check "with no root named, cdirs walks MT_ROOT" [expr {
    [dict get $cdr exit] == 0
    && [dict get [json decode [dict get $cdr out]] root] eq $CDWS}]

# CD7: `-stdout` writes NO file at all, puts the list on stdout and the report on
# stderr. The separation is what makes `mt cdirs C:/dev -stdout | rg node_modules`
# work, and it is two checks rather than one because putting the report on stdout
# would still pass a gate that only looked for the paths.
set cdbefore [lsort [glob -nocomplain -directory $CDOUT *]]
lassign [CdirsRun [file join $FX target] -stdout] cdex cdout cderr
set cdafter [lsort [glob -nocomplain -directory $CDOUT *]]
check "-stdout writes no file" [expr {$cdex == 0 && $cdbefore eq $cdafter}]
check "-stdout puts the list on stdout" [expr {
    [lsearch -exact [split [string map {\r\n \n} [string trimright $cdout]] \n] \
         [file join $FX target]] >= 0}]
# `string first` AND NOT `string match`, and the first draft of this line got it
# wrong in the way that always passes: `string match "cdirs \[*"` reads `[` as a
# character-class opener, so the pattern stopped meaning what it looked like.
# Every bracket in this block is compared literally for that reason.
check "and the report on stderr" [expr {
    [string first "cdirs \[" [string trim $cderr]] == 0}]
check "and the report names no file, because none was written" [expr {
    ![string match "*list *" $cderr] && ![string match "*report *" $cderr]}]
# ORTHOGONAL: `-stdout` chooses where the LIST goes, `-json` the FORMAT of the
# REPORT. All four combinations mean something, which is why there is no
# conflict rule to write and no fourth case to refuse.
lassign [CdirsRun [file join $FX target] -stdout -json] cdex cdout cderr
check "-stdout -json puts paths on stdout and JSON on stderr" [expr {
    $cdex == 0 && [string match "*/target*" $cdout]
    && [dict get [json decode $cderr] root] eq [file join $FX target]}]
# `-out` AND `-stdout` ARE TWO DISPOSITIONS NAMED AT ONCE, refused rather than
# resolved by precedence: silently letting one win is the command ignoring
# something the caller wrote, which is the failure this whole report opposes.
check "-out with -stdout is a usage error, not a silent preference" [expr {
    [errcode_of {front cdirs $FX -out [file join $CDOUT never.txt] -stdout}]
        eq {MACHTELD FRONT usage}
    && ![file exists [file join $CDOUT never.txt]]}]

# CD8: `-depth` is the verb's own option, CHECKED AT THREE VALUES. One value
# passes under an off-by-one as easily as under the truth; and 0 is the value
# that separates "the root alone" from "unlimited", which is the trap the palette
# documents and the same class of mistake as `-timeout 100`.
foreach n {0 1 3} {
    set cdf [file join $CDOUT d$n.txt]
    lassign [CdirsRun $FX -out $cdf -depth $n] cdex cdout cderr
    check "-depth $n reaches the verb unchanged" [expr {
        $cdex == 0 && [CdirsLines $cdf] eq [dict get [valof {dirs $FX -depth $n}] paths]}]
}
check "-depth 0 is the root alone, and never unlimited" [expr {
    [CdirsLines [file join $CDOUT d0.txt]] eq [list $FX]}]
set cdf [file join $CDOUT pr.txt]
lassign [CdirsRun $FX -out $cdf -prune deep] cdex cdout cderr
check "-prune reaches the verb unchanged" [expr {
    $cdex == 0 && [CdirsLines $cdf] eq [dict get [valof {dirs $FX -prune deep}] paths]}]
check "and the report counts the refusal without naming it" [expr {
    [string match "*by request*" $cdout] && [string match "*-prune {deep}*" $cdout]}]
# AND THE SENTENCE AGREES WITH THE NUMBER. `1 directories matching -prune {...}`
# and `1 directories at the -depth 3 limit` shipped in a report that says
# `1 directory`, `1 place` and `1 reparse directory` everywhere else -- small, and
# the same shape as the rest of this file: a count checked and the sentence
# carrying it not.
lassign [CdirsRun $FX -out [file join $CDOUT one.txt] -depth 0] cdex cdone cderr
check "one refusal is `1 directory`, not `1 directories`" [expr {
    [string match "*1 directory at the -depth 0 limit*" $cdone]
    && ![string match "*1 directories*" $cdone]
    && ![string match "*stopped at each*" $cdone]}]
lassign [CdirsRun $FX -out [file join $CDOUT many.txt] -depth 1] cdex cdmany cderr
check "and more than one is still plural" [expr {
    [regexp -- {\d directories at the -depth 1 limit} $cdmany]}]

# CD9: THE HUMAN TEXT AND THE JSON ARE THE SAME NUMBERS. A human reads the text
# and a script reads `-json`; formatted from two sets of counters, one of them is
# wrong and nothing says which. Here the text is rendered FROM the report dict,
# so this gate is checking that the rendering has not grown a second source.
lassign [CdirsRun $FX -out [file join $CDOUT j.txt] -json] cdex cdjs cderr
set CDJ [valof {json decode $cdjs}]
lassign [CdirsRun $FX -out [file join $CDOUT j.txt]] cdex cdtx cderr
check "the headline count is the report's own `dirs`" [expr {
    [dict exists $CDJ dirs] && [string first \
        "[::machteld::FrontThousands [dict get $CDJ dirs]] directories" $cdtx] >= 0}]
check "the headline verdict is the report's own `complete`" [expr {
    [dict exists $CDJ complete]
    && [dict get $CDJ complete] == ([string first "\[COMPLETE\]" $cdtx] >= 0)
    && [dict get $CDJ complete] != ([string first "\[PARTIAL\]" $cdtx] >= 0)}]
check "the headline names the root the verb reported" [expr {
    [dict exists $CDJ root] && [string first "under [dict get $CDJ root] in " $cdtx] >= 0}]
# THE BICONDITIONAL ABOVE IS CORRECT AND HAS ONLY ONE SUBJECT -- a PARTIAL walk.
# Hardwiring the word to `PARTIAL` left all 701 checks green; the inverse does
# fire, so the hole was on the fail-safe side, but a verdict is two words and
# both of them are printed. `$FX/target` is the fixture's clean subtree.
lassign [CdirsRun [file join $FX target] -out [file join $CDOUT ok.txt] -json] cdex cdjs cderr
set CDOKJ [valof {json decode $cdjs}]
lassign [CdirsRun [file join $FX target] -out [file join $CDOUT ok.txt]] cdex cdoktx cderr
check "a walk that refused nothing prints \[COMPLETE\], and says so in the JSON" [expr {
    [dict exists $CDOKJ complete] && [dict get $CDOKJ complete] == 1
    && [string first "cdirs \[COMPLETE\]" $cdoktx] == 0
    && [string first "\[PARTIAL\]" $cdoktx] < 0}]
# THE THREE KEYS THE REPORT PUBLISHES AND NOTHING READ. Forced to 999 / 0 / 0 in
# turn, the suite stayed green each time -- and `elapsed` is the one thing this
# layer exists to add over the verb, by the register's own argument for putting
# `-out` and the two `clock milliseconds` calls up here.
check "`maxdepth` is the verb's own answer for the same walk" [expr {
    [dict exists $CDOKJ maxdepth]
    && [dict get $CDOKJ maxdepth] == [dict get [valof {dirs [file join $FX target]}] maxdepth]}]
check "`when` is when the run happened" [expr {
    [dict exists $CDOKJ when]
    && abs([dict get $CDOKJ when] - [clock seconds]) < 600}]
# `elapsed` NEEDS A SUBJECT THAT TAKES MEASURABLE TIME, and the fixture does not:
# a walk of eleven directories can honestly report 0 ms, so a lower bound there
# would be flaky rather than load-bearing. The home tree at depth 2 is hundreds
# of directories off a real disk and takes milliseconds; the upper bound is the
# wall clock this suite measured around the child, which no invented constant can
# satisfy.
set cdw0 [clock milliseconds]
lassign [CdirsRun $HOMEDIR -depth 2 -out [file join $CDOUT el.txt] -json] cdex cdjs cderr
set cdwall [expr {[clock milliseconds] - $cdw0}]
set CDELJ [valof {json decode $cdjs}]
check "`elapsed` is the run's own wall time, not a constant" [expr {
    [dict exists $CDELJ elapsed] && [dict get $CDELJ elapsed] > 0
    && [dict get $CDELJ elapsed] <= $cdwall}]
if {[dict exists $CDELJ elapsed]} {
    puts "     cdirs elapsed: [dict get $CDELJ elapsed] ms inside a $cdwall ms child"
}
# THE FORMATTER ITSELF, which the headline check cannot see: it builds its
# expectation by calling the same `FrontThousands` the renderer calls, so it
# gates "no second source of counters" (as its comment says) and not the
# formatting. Nothing else read this proc.
foreach {cdn cdwant} {0 0 1 1 999 999 1000 1,000 1234 1,234 999999 999,999
                      1000000 1,000,000 236159 236,159 -1234 -1,234} {
    check "$cdn prints as $cdwant" [expr {[::machteld::FrontThousands $cdn] eq $cdwant}]
}
# EVERY REFUSAL IS NAMED IN THE TEXT, not merely totalled. This is the claim the
# command exists to make, and a report that printed only the count would satisfy
# every other check in this block.
# `string first` AND NOT `string match`, because a path IS a glob pattern: this
# machine carries `C:/Users/anafa/gdrive/[19] MASTER`, and the fixture two
# hundred lines above carries `quote'n[brace]` on purpose. A bracket expression
# that fails to match is a gate that passes for the wrong reason.
# `dict exists` first, because a row that has stopped being a dict must make this
# FAIL rather than raise -- a raise here aborts the run and every check after it
# silently never happens.
set cdunnamed {}
foreach r [valof {dict get $CDJ refused}] {
    if {![dict exists $r path]} { lappend cdunnamed $r ; continue }
    if {[string first [dict get $r path] $cdtx] < 0} { lappend cdunnamed [dict get $r path] }
}
# THE NON-EMPTINESS IS PART OF THE CLAIM. `foreach` over an empty list names
# nothing and reports nothing wrong, so a report that lost its rows entirely --
# or a decode that returned nothing -- would satisfy the loop above perfectly.
# The fixture carries three junctions, so three is the floor.
check "every refused place is NAMED in the text, not just counted" [expr {
    $cdunnamed eq "" && [llength [valof {dict get $CDJ refused}]] >= 3}]
if {$cdunnamed ne ""} { puts "     counted but not named: [lrange $cdunnamed 0 5]" }

# CD10: an unreadable directory becomes a named refusal carrying its raw win32
# code -- the palette's reason applies verbatim, since the message cannot be
# trapped on and does not discriminate: a directory pending delete and an ACL
# denial both arrive as ERROR_ACCESS_DENIED.
if {$DENIED} {
    lassign [CdirsRun $FX -out [file join $CDOUT den.txt] -json] cdex cdjs cderr
    set CDJ [valof {json decode $cdjs}]
    set cdrow ""
    foreach r [valof {dict get $CDJ refused}] {
        if {[dict exists $r path] && [dict get $r path] eq [file join $FX locked]} { set cdrow $r }
    }
    check "an unreadable directory is a named refusal" [expr {$cdrow ne ""}]
    check "carrying the raw win32 code, and marked PARTIAL" [expr {
        $cdrow ne "" && [dict get $cdrow win32] != 0 && [dict get $CDJ complete] == 0}]
    check "and the walk still succeeded" [expr {$cdex == 0}]
} else {
    puts "     SKIP cdirs unreadable: elevated, the deny ACE did not take"
}

# CD11: A FAILED RUN MUST NOT DESTROY A GOOD CACHE. The walk takes twenty
# seconds on a real tree and can be interrupted; the invariant this ordering buys
# is that a present sidecar means the list beside it is whole. An unwritable
# destination is the reachable shape of that failure.
set CDGOOD [file join $CDOUT keep.txt]
lassign [CdirsRun $FX -out $CDGOOD] cdex cdout cderr
set CDKEEP [CdirsLines $CDGOOD]
set CDBLOCK [file join $CDOUT blocker.txt]
set cdfh [open $CDBLOCK w] ; puts $cdfh x ; close $cdfh
check "an unwritable destination raises oserror" [expr {
    [errcode_of {front cdirs $FX -out [file join $CDBLOCK sub out.txt]}]
        eq {MACHTELD FRONT oserror}}]
check "and writes neither file" [expr {
    ![file exists [file join $CDBLOCK sub]] && [file isfile $CDBLOCK]}]
check "and the previous run's artefacts are untouched" [expr {
    [CdirsLines $CDGOOD] eq $CDKEEP && [file exists [file join $CDOUT keep.json]]}]
# AND THE FAILURE THE OLD ORDERING COULD NOT SURVIVE, which is the one CD11 was
# not pointed at. The check above uses a `file mkdir` failure, which aborts
# BEFORE the publish block -- so the only path in this command that can destroy
# anything was the one path with no gate on it. Here the temporaries are written
# and the RENAME is what fails, with the destination held open by a reader.
# Measured on the shipped build: `oserror` raised, list intact, and the previous
# run's report GONE -- because the old sidecar was deleted before the rename.
set CDHOLD [file join $CDOUT held.txt]
lassign [CdirsRun $FX -out $CDHOLD] cdex cdout cderr
set CDHELD [CdirsLines $CDHOLD]
set cdfh [open $CDHOLD r]
set cdcode [errcode_of {front cdirs $FX -out $CDHOLD}]
close $cdfh
check "a publish that cannot replace the list raises oserror" [expr {
    $cdcode eq {MACHTELD FRONT oserror}}]
check "and the previous run's list AND report both survive it" [expr {
    [CdirsLines $CDHOLD] eq $CDHELD && $CDHELD ne ""
    && [file isfile [file join $CDOUT held.json]]
    && [dict exists [valof {json decode \
            [lindex [CdirsLines [file join $CDOUT held.json]] 0]}] dirs]}]

# `-out` NAMING A DIRECTORY IS AN ERROR, NOT A SUCCESS. `file rename` moves a
# file INTO a directory target, so this reported `[COMPLETE]`, exit 0, named the
# directory as the `list` and wrote a sidecar claiming `"bytes":96` about it --
# while the list itself sat orphaned inside as `<dir>/<dir>.tmp`. That is the
# invariant this command states in its own doc, "a present report means the list
# beside it is whole", broken in the one direction nothing else here could see.
set CDDIR [file join $CDOUT adir]
file mkdir $CDDIR
check "-out naming an existing directory is an oserror" [expr {
    [errcode_of {front cdirs $FX -out $CDDIR}] eq {MACHTELD FRONT oserror}}]
check "and it wrote nothing at all, not even a temporary" [expr {
    [glob -nocomplain -directory $CDDIR *] eq ""
    && ![file exists $CDDIR.json]}]
# AND THE SIDECAR PATH IS NOT `rm -rf`'d. The publish step used to delete
# whatever stood at `<name>.json`, so `-out notes.txt` beside a DIRECTORY called
# `notes.json` removed it and everything under it, silently, before writing a
# byte. Overwriting a FILE there is documented; deleting a tree is not.
set CDJDIR [file join $CDOUT notes.json]
file mkdir [file join $CDJDIR deep]
set cdfh [open [file join $CDJDIR deep c.txt] w] ; puts $cdfh keep ; close $cdfh
check "a directory standing at the report's path is an oserror" [expr {
    [errcode_of {front cdirs $FX -out [file join $CDOUT notes.txt]}]
        eq {MACHTELD FRONT oserror}}]
check "and the directory and its contents are still there" [expr {
    [file isfile [file join $CDJDIR deep c.txt]]
    && ![file exists [file join $CDOUT notes.txt]]}]

# AN EMPTY VALUE IS A VALUE, NOT AN ABSENCE, and all three surfaces read it as
# absence. The verb is the oracle for the first two: `dirs $root -depth {}` and
# `dirs {}` both raise `badvalue`, and a front door that swallows what its own
# verb refuses is "the command ignoring something the caller wrote" -- the exact
# failure the -out/-stdout refusal above exists to name. `mt cdirs $r -depth
# $limit` with an empty `$limit` is the ordinary shape of an optional limit.
check "-depth {} is refused, exactly as the verb refuses it" [expr {
    [errcode_of {front cdirs $FX -depth {} -stdout}] eq {MACHTELD FRONT badvalue}
    && [lindex [errcode_of {dirs $FX -depth {}}] 2] eq "badvalue"}]
check "an empty root is refused, exactly as the verb refuses it" [expr {
    [errcode_of {front cdirs {} -stdout}] eq {MACHTELD FRONT badvalue}
    && [lindex [errcode_of {dirs {}}] 2] eq "badvalue"}]
# AND AN EMPTY ROOT IS STILL A ROOT for the one-root rule, or `mt cdirs "" ""`
# escapes the guard that "front cdirs takes one root, not two".
check "two roots are two roots even when both are empty" [expr {
    [errcode_of {front cdirs {} {} -stdout}] eq {MACHTELD FRONT usage}}]
# `-out {}` WENT TO THE DEFAULT CACHE PATH -- a caller who NAMED a disposition
# and got a different one. The two guards even disagreed: `-out {} -stdout` was
# refused as two dispositions while `-out {}` alone counted as no `-out` at all.
check "-out {} is refused rather than silently becoming the default" [expr {
    [errcode_of {front cdirs $FX -out {}}] eq {MACHTELD FRONT badvalue}}]
# `-out` MUST STAY ABSOLUTE THROUGH THE CLEAN. `FrontClean` popped `..` past the
# drive letter, so the report's `list` key named a file only the original working
# directory could open -- in the report whose stated job is to name a file a
# later script can open.
#
# THIS CHECK USED TO ASSERT A REFUSAL, AND IT WAS RESTING ON THE BUG. It ran
# `front cdirs $FX -out C:/../../esc_zzz.txt` and expected `badvalue` -- which is
# what happened only because the clean turned that into the RELATIVE
# `esc_zzz.txt` and the absoluteness guard then caught it. Windows and
# `filepath.Clean` both read `C:/../..` as `C:\`, so the correct answer is
# `C:/esc_zzz.txt`: absolute, openable, exactly what the caller asked for. Fixing
# `FrontClean` turned this check red, which is the gate working -- it noticed the
# behaviour change -- but its EXPECTATION was wrong.
#
# Re-pointed at the property, and asserted on `FrontClean` itself rather than by
# running the command: with the volume now preserved, the old subject would
# genuinely write `C:\esc_zzz.txt`, and a suite that creates files at the root of
# the system drive to test a path cleaner is worse than the bug.
check "the clean keeps the volume when .. climbs past the root" [expr {
    [::machteld::FrontClean C:/../../esc_zzz.txt] eq "C:/esc_zzz.txt"}]
check "the clean does not turn a drive root into nothing" [expr {
    [::machteld::FrontClean C:/..] eq "C:" && [::machteld::FrontClean C:/../] eq "C:"}]
check "the clean keeps a UNC share whole" [expr {
    [::machteld::FrontClean //srv/share/a/../../z] eq "//srv/share/z"}]
check "the clean still keeps a relative .. relative" [expr {
    [::machteld::FrontClean ../x] eq "../x"}]
# AND `-out` STILL LANDS SOMEWHERE ABSOLUTE, which is the property that gate was
# always about. A relative `-out` is ANCHORED at the working directory rather
# than refused -- it always was, and my replacement check asserted the opposite
# and failed, which is the second time in this batch that a new test encoded an
# expectation the code never had. `front cdirs`'s own absoluteness guard is now
# unreachable by construction and is kept as a tripwire, so what is asserted here
# is the outcome rather than the refusal.
check "-out lands on an absolute path" [expr {
    [file pathtype [dict get [json decode \
        [front cdirs $FX -out [file join $CDOUT rel_ok.txt] -json]] list]] eq "absolute"}]

# NO STRAY TEMPORARIES. The publish step writes `.tmp` files and renames them;
# one left behind is a half-written list sitting where a later reader might find
# a plausible name. `.prev` too, since the sidecar is now moved aside rather than
# deleted and a leftover would be a stale report wearing a plausible name.
check "no .tmp or .prev files are left behind" [expr {
    [glob -nocomplain -directory $CDOUT *.tmp] eq ""
    && [glob -nocomplain -directory $CDOUT *.prev] eq ""}]

# CD12: THE CONSEQUENCE, ON THE ONLY SUBJECT THAT HAS ONE. No fixture can create
# a non-surrogate reparse point without elevation or FSCTL_SET_REPARSE_POINT, so
# the subject is the real cloud tree that gate 8 already found with `fsutil`, and
# its absence is SAID rather than passed over. THE ORACLE IS A SECOND WALK ROOTED
# AT THE CLOUD DIRECTORY -- a different root, a different depth budget, none of
# cdirs' Tcl involved.
if {$NONSURR eq ""} {
    puts "     SKIP cdirs consequence: no non-surrogate reparse point under $HOMEDIR"
    puts "          (the `entered` block is then never exercised against a real one)"
} else {
    set CDCAP 3
    set cdf [file join $CDOUT home.txt]
    lassign [CdirsRun $HOMEDIR -out $cdf -depth $CDCAP -json] cdex cdjs cderr
    set CDJ [valof {json decode $cdjs}]
    set cdent {}
    foreach e [valof {dict get $CDJ entered}] {
        if {[dict exists $e path] && [dict get $e path] eq $NONSURR} { set cdent $e }
    }
    check "the descended cloud root is reported, tag and all" [expr {
        $cdex == 0 && $cdent ne "" && [dict get $cdent surrogate] == 0
        && [dict get $cdent tag] == $NONTAG}]
    # THE EXTRAS ARE ATTRIBUTABLE AND THEY ARE REAL. The set below cdirs' own
    # cloud row is compared against an INDEPENDENT walk of that subtree, and then
    # every member is probed with Tcl's own stat -- a third implementation, asked
    # one path at a time. Exhaustive rather than sampled: measured at 594 probes
    # in 26 ms at this depth, and a sample is the shape that misses the one bad
    # name in two hundred thousand.
    set cddepth [llength [split [string trimleft \
        [string range $NONSURR [string length $HOMEDIR] end] /] /]]
    set CDSUB [valof {dirs $NONSURR -depth [expr {$CDCAP - $cddepth}]}]
    set cdbelow {} ; set cdphantom {}
    foreach p [CdirsLines $cdf] {
        if {![string equal -length [expr {[string length $NONSURR] + 1}] $NONSURR/ $p]} continue
        lappend cdbelow $p
        if {![file isdirectory $p]} { lappend cdphantom $p }
    }
    check "what lies below the cloud root equals an independent walk of it" [expr {
        $CDSUB ne "" && [llength $cdbelow] == [dict get $CDSUB dirs] - 1}]
    check "and it is not zero -- the divergence from z is under test" [expr {
        [llength $cdbelow] > 0}]
    check "every directory found behind the cloud root exists" [expr {$cdphantom eq ""}]
    if {$cdphantom ne ""} { puts "     phantom: [lrange $cdphantom 0 5]" }
    # AND THE REPORT SAYS HOW BIG IT IS, on the only subject where the number is
    # large. Naming the place and giving no number is z's "counted, consequence
    # invisible" with the terms swapped -- and unlike `refused`, where the size
    # genuinely cannot be had without entering, this walk DID enter and the paths
    # are in hand. The oracle is the list file, counted by the test.
    check "and the entered row carries that count, not just the place" [expr {
        $cdent ne "" && [dict exists $cdent below]
        && [dict get $cdent below] == [llength $cdbelow]}]
    # NARROWING TO THE DIVERGENT SUBTREE MUST NOT LOSE THE DISCLOSURE. `mt cdirs
    # <the cloud root>` used to print no `entered` block at all, because the
    # root's tag is read through a handle and the cloud filter consumes its own
    # reparse point on open -- so the one invocation aimed straight at the
    # divergence was the one that said nothing about it.
    lassign [CdirsRun $NONSURR -depth 1 -out [file join $CDOUT nsroot.txt] -json] cdex cdjs cderr
    set CDNRJ [valof {json decode $cdjs}]
    set cdnrent {}
    foreach e [valof {dict get $CDNRJ entered}] {
        if {[dict exists $e path] && [dict get $e path] eq $NONSURR} { set cdnrent $e }
    }
    check "the cloud root discloses itself when it IS the root" [expr {
        $cdex == 0 && $cdnrent ne "" && [dict get $cdnrent surrogate] == 0
        && [dict get $cdnrent tag] == $NONTAG}]
    lassign [CdirsRun $NONSURR -depth 1 -out [file join $CDOUT nsroot.txt]] cdex cdnrtx cderr
    check "and says so in the text, where a person would read it" [expr {
        [string match "*content, not a second name for*" $cdnrtx]
        && [string first $NONSURR $cdnrtx] >= 0}]
    puts "     cdirs consequence: [llength $cdbelow] directories below $NONSURR at depth $CDCAP"
}

# CD13: it is a real front-door command, reachable the way z's was.
check "cdirs is a front-door command"  [expr {"cdirs" in [::machteld::FrontCommands]}]
check "and mt cdirs resolves in-process" [expr {
    [dict get [valof {front env cdirs}] kind] eq "command"}]
# EVERY OPTION IT TAKES IS DECLARED. `front`'s `set opts {...}` line IS the
# manifest's answer, and this exact hole has been fallen into once already:
# `front run -inherit` worked, the manifest denied it, and the docs gate called
# the working example a typo.
foreach o {-depth -out -prune -stdout} {
    check "`$o` is declared in front's option table" [expr {
        $o in [dict get [manifest] front options]}]
}
foreach o {-depth -out -prune} {
    check "`$o` with no value is a usage error" [expr {
        [lindex [errcode_of {front cdirs $FX $o}] 2] eq "usage"}]
}
check "an unknown option is a usage error" [expr {
    [errcode_of {front cdirs $FX -nosuch v}] eq {MACHTELD FRONT usage}}]
check "a second root is a usage error" [expr {
    [errcode_of {front cdirs $FX $FX}] eq {MACHTELD FRONT usage}}]
# THE FOUR CODES, AND WHY THIS GATE EXISTS AT ALL. The DIRS->FRONT re-raise is
# written as a switch with four LITERAL arms rather than the tempting
# `Fail FRONT $code $msg`, because the manifest reads a Tcl verb's codes with
# `{Fail\s+([A-Z]+)\s+([a-z]+)\s}` and a variable in the code position matches
# nothing. The one-liner would leave `manifest front codes` denying two codes the
# command really raises, with every other check in this file still green -- the
# identical shape that once made the build report `dirs codes=1` against a truth
# of four.
foreach c {badvalue oserror} {
    check "manifest front declares `$c`" [expr {$c in [dict get [manifest] front codes]}]
}
foreach {cdlabel cdscript cdwant} [list \
    "a missing root"      {front cdirs $FX/nope_zzz -stdout}     notfound \
    "a root that is a file" {front cdirs [file join $FX afile.txt] -stdout} notfound \
    "a drive-relative root" {front cdirs C: -stdout}             badvalue \
    "a bad -depth"        {front cdirs $FX -depth nope -stdout}  badvalue \
    "a malformed -prune"  "front cdirs \$FX -prune \\{ -stdout"  badvalue] {
    check "$cdlabel is FRONT $cdwant, not DIRS" [expr {
        [errcode_of $cdscript] eq "MACHTELD FRONT $cdwant"}]
}
# `front verify` MUST STILL SEE NO COLLISION. The workspace gains tools without
# asking anybody, and a promoted name that is also a curated tool is a name that
# means two things.
check "cdirs collides with nothing the workspace curates" [expr {
    "cdirs" ni [::machteld::FrontToolNames]
    && ![llength [lsearch -all -inline -glob \
             [dict get [valof {json decode [front verify -json]}] problems] "*cdirs*"]]}]

# CD14: THE DOC SCANNER CAN SEE THIS COMMAND'S OPTIONS -- and this gate exists
# because the answer was nearly no. The doc-accuracy check five hundred lines
# above filters option tokens with `^-[a-z]+$`, which rejects `--root`, `--out`
# and `--max-depth`: had `cdirs` been spelled z's way, the ONLY gate coupling the
# docs to the option table would have been structurally blind to every option it
# has, and green. Spelling the options the VERB's way -- `-depth`, `-prune` --
# keeps them inside the scanner's reach for free, which is a second, mechanical
# argument for [rule 1] on top of the readability one.
#
# Widening the scanner instead was considered and refused: `--json` is accepted
# at the seam and deliberately NOT declared, so a wider regexp would call a
# working documented example a typo -- the `front run -inherit` failure with the
# sign flipped. So the blindness itself is gated here rather than papered over,
# and the day someone adds a `--long-option` to a Tcl verb this fails and says
# what to do about it.
set cdblind {}
foreach o [dict get [manifest] front options] {
    if {![regexp {^-[a-z]+$} $o]} { lappend cdblind $o }
}
check "every declared front option is a shape the doc scanner checks" [expr {$cdblind eq ""}]
if {$cdblind ne ""} {
    puts "     invisible to the doc-accuracy scanner: $cdblind"
    puts "     (widen its `^-\[a-z\]+\$` filter, or spell the option the palette's way)"
}

# --- the divergence from z cannot become folklore -----------------------------
# PROSE-MATCHING IS VACUOUS: a gate asserting that some paragraph contains the
# word "OneDrive" is satisfied by writing the word. These three tie the doc to a
# VALUE instead.

# CDD1: THE RULE AS THE DOC STATES IT PREDICTS THE WALKER'S OWN CLASSIFICATION.
# The mask is EXTRACTED FROM THE DOC and applied to tags the walker reported for
# real directories on this machine. Change the doc and it fires; change the veto
# in dirs.c and the walker's `surrogate` field flips and it fires from the other
# side.
set CDPAL [help palette]
set CDMASK ""
regexp {surrogate bit\s+`?(0x[0-9a-fA-F]+)`?} $CDPAL -> CDMASK
check "the palette states the surrogate bit as a value" [expr {$CDMASK ne ""}]
if {$CDMASK ne ""} {
    set cdwrong {}
    foreach l [dict get [valof {dirs $HOMEDIR -depth 1}] links] {
        # BOTH SIDES AS BOOLEANS. The first version of this line compared the
        # masked tag to the flag directly -- `0x20000000 != 1` -- so it fired on
        # every junction on the machine and would have gone on firing whatever
        # either side said. A gate that cannot be green is as useless as one that
        # cannot be red.
        set cdpredicted [expr {([dict get $l tag] & $CDMASK) != 0}]
        if {$cdpredicted != [dict get $l surrogate]} { lappend cdwrong $l }
    }
    check "the documented rule predicts every classification the walker made" [expr {
        $cdwrong eq ""}]
    foreach w $cdwrong { puts "     doc and walker disagree: $w" }
}

# CDD2: EVERY TAG THE SOURCE VETOES IS NAMED IN THE DOC. The DFS pair is refused
# although it does NOT set the bit, and it has never been observed on this
# machine -- so it is unreachable from any fixture, and the only thing that can
# keep it honest is the doc and the #defines agreeing. Adding a fourth vetoed tag
# without documenting it fires this.
set CDSRC [file join $HERE .. src dirs.c]
if {![file exists $CDSRC]} {
    puts "     SKIP veto/doc coupling (no src/ beside the test)"
} else {
    set cdfh [open $CDSRC r] ; set cdtext [read $cdfh] ; close $cdfh
    set cdvetoed {}
    # `[A-Z0-9_]` AND NOT `[A-Z0-9]`, and the underscore is the whole gate. The
    # class without it cannot match the standard spelling of a reparse constant
    # -- `IO_REPARSE_TAG_MOUNT_POINT`, `WCI_1`, `CLOUD_1` are how every one of
    # them is written -- so a real fourth vetoed tag added as
    # `#define DIRS_TAG_WCI_1 0x80000018u` and left undocumented was INVISIBLE
    # here, the `>= 3` floor was met by the three survivors, and all 701 checks
    # were green. This gate's stated purpose is "adding a fourth vetoed tag
    # without documenting it fires this", and it did not hold for any tag anyone
    # is likely to add.
    foreach {_ nm val} [regexp -all -inline \
            {#define\s+DIRS_(SURROGATE|TAG_[A-Z0-9_]+)\s+(0x[0-9a-fA-F]+)u?} $cdtext] {
        dict set cdvetoed [string tolower $val] DIRS_$nm
    }
    # AND THE SCANNER'S OWN BLINDNESS IS GATED, rather than trusted a second
    # time. A LOOSE count of the same defines is compared with what the strict
    # pattern actually saw, so the next spelling it cannot read fails HERE and
    # says what to widen -- instead of silently shrinking the set of tags the doc
    # is held to. This is the same shape as CD14, which gates the doc scanner's
    # `^-[a-z]+$` blindness rather than papering over it.
    set cdloose [regexp -all -- {#define\s+DIRS_(?:SURROGATE|TAG_\S+)\s} $cdtext]
    check "the source declares its veto constants where they can be read" [expr {
        [dict size $cdvetoed] >= 3}]
    check "and the scanner reads every one of them, not a subset" [expr {
        $cdloose >= 3 && [dict size $cdvetoed] == $cdloose}]
    if {[dict size $cdvetoed] != $cdloose} {
        puts "     $cdloose veto constants declared, [dict size $cdvetoed] matched:\
              widen the `DIRS_(SURROGATE|TAG_...)` pattern above"
    }
    set cdlowpal [string tolower $CDPAL]
    set cdundoc {}
    dict for {v nm} $cdvetoed {
        if {![string match "*$v*" $cdlowpal]} { lappend cdundoc "$nm=$v" }
    }
    check "every tag the walker vetoes is named in the palette doc" [expr {$cdundoc eq ""}]
    if {$cdundoc ne ""} { puts "     undocumented veto constants: $cdundoc" }
}

# CDD3: EVERY PROMOTED COMMAND IS DOCUMENTED -- the direction the doc scanner
# does not go. It checks doc->code; nothing has ever checked code->doc for the
# front door, so a command could ship undocumented and nothing would say so. The
# palette has had this since `watch` and `manifest` went missing from a
# hand-kept list. Written against COMMAND-SHAPED mentions rather than a bare
# backticked word, because a word appearing anywhere in the file is satisfied by
# the paragraph that REFUSES to build the command -- which is exactly the state
# `cdirs` was in until today.
set CDFD [help front-door]
set cdundocumented {}
foreach c [::machteld::FrontCommands] {
    if {![string match "*`mt $c*" $CDFD] && ![string match "*`front $c*" $CDFD]
        && ![regexp -line "^\\s*(mt|front)\\s+$c\\M" $CDFD]} {
        lappend cdundocumented $c
    }
}
check "the front-door plan documents every promoted command" [expr {$cdundocumented eq ""}]
if {$cdundocumented ne ""} { puts "     undocumented commands: $cdundocumented" }

# CDD4: AND THE STALE CLAIM IS GONE. front-door.md said "it wants a C verb or it
# stays outside machteld", which was true the day it was written and is false the
# day the command lands. A false sentence in a shipped doc is the thing this
# whole file exists to prevent, so it is asserted as a fact about the code: if
# the command exists, the doc must not still be refusing it.
if {"cdirs" in [::machteld::FrontCommands]} {
    check "the doc no longer says cdirs stays outside machteld" [expr {
        ![string match "*stays outside machteld*" $CDFD]}]
}

file delete -force $CDOUT
check "the cdirs fixture tore down completely" [expr {![file exists $CDOUT]}]

# --- `mirror`: the one command that can delete ------------------------------
#
# NOTHING HERE RUNS ROBOCOPY. Every gate below is on a pure function or on a
# REFUSAL, because the two things worth testing without a fixture destination
# are "does it decline the dangerous cases" and "does it read robocopy's answer
# correctly". The dry run against the live workspace is `front_agree`'s job.

# MR1: THE REFUSAL THAT MATTERS MOST. A real /MIR run deletes destination
# extras; the ownership record z gates that on is not ported, so the destructive
# path must refuse -- and the refusal must be UNCONDITIONAL, not a flag away.
#
# AIMED AT A THROWAWAY DESTINATION, NOT AT THE LIVE BACKUP. The first version of
# these three checks ran bare `front mirror`, which resolves OneDrive and heads
# for the real `z-backup`. That is safe only while the refusal WORKS: the moment
# it regresses -- which is the single thing these checks exist to detect -- each
# of the three would sail past it and `file mkdir` the OneDrive log directory,
# walk all of C:\dev, write a link manifest into OneDrive and launch robocopy
# with a one-hour timeout. Three times. A test whose failure mode is "spend ten
# minutes writing into the user's backup directory" is a test that punishes the
# regression it was written to find.
set MRDEST [file join [file dirname $FX] mt_mirror_never z-backup]
proc MirrorRefused {args} {
    global MRDEST
    return [errcode_of {front mirror --dest $MRDEST {*}$args}]
}
check "mirror refuses a destructive run" [expr {
    [MirrorRefused] eq {MACHTELD MIRROR unsupported}}]
check "mirror refuses it with --force-dest too" [expr {
    [MirrorRefused --force-dest] eq {MACHTELD MIRROR unsupported}}]
check "mirror refuses it with --adopt-dest too" [expr {
    [MirrorRefused --adopt-dest] eq {MACHTELD MIRROR unsupported}}]
# AND THE REFUSAL LEAVES NOTHING BEHIND. If it ever starts happening after the
# first write rather than before it, this is what says so.
check "the refusal writes nothing" [expr {![file exists [file dirname $MRDEST]]}]

# MR2: option parsing, including the two combinations z refuses.
check "mirror parses z's short dry-run flag" [expr {
    [dict get [::machteld::MirrorOpts {-n}] dryrun] == 1}]
check "mirror parses --dest with a value" [expr {
    [dict get [::machteld::MirrorOpts {--dest X:/somewhere}] dest] eq "X:/somewhere"}]
check "mirror parses --dest=value" [expr {
    [dict get [::machteld::MirrorOpts {--dest=X:/somewhere}] dest] eq "X:/somewhere"}]
check "mirror refuses --dest with no path" [expr {
    [errcode_of {::machteld::MirrorOpts {--dest}}] eq {MACHTELD MIRROR usage}}]
check "mirror refuses --dest followed by a flag" [expr {
    [errcode_of {::machteld::MirrorOpts {--dest --quiet}}] eq {MACHTELD MIRROR usage}}]
check "mirror refuses an unknown argument" [expr {
    [errcode_of {::machteld::MirrorOpts {--wat}}] eq {MACHTELD MIRROR usage}}]
check "mirror refuses --dry-run with --no-preflight" [expr {
    [errcode_of {::machteld::MirrorOpts {--dry-run --no-preflight}}] eq {MACHTELD MIRROR usage}}]
check "mirror refuses --dry-run with --adopt-dest" [expr {
    [errcode_of {::machteld::MirrorOpts {--dry-run --adopt-dest}}] eq {MACHTELD MIRROR usage}}]

# MR3: the destination refusals, which are the whole safety surface. Asserted on
# NAMES here; the identity half needs real directories and is exercised by the
# dry run.
check "mirror refuses a destination not named z-backup" [expr {
    [errcode_of {::machteld::MirrorValidatePaths C:/dev C:/somewhere/else 0}] eq
    {MACHTELD MIRROR badvalue}}]
check "mirror accepts that destination with --force-dest" [expr {
    [catch {::machteld::MirrorValidatePaths C:/dev C:/somewhere/else 1}] == 0}]
check "mirror refuses a destination inside the source" [expr {
    [errcode_of {::machteld::MirrorValidatePaths C:/dev C:/dev/z-backup 0}] eq
    {MACHTELD MIRROR badvalue}}]
check "mirror refuses a source inside the destination" [expr {
    [errcode_of {::machteld::MirrorValidatePaths C:/backups/z-backup/inner C:/backups/z-backup 0}]
    eq {MACHTELD MIRROR badvalue}}]
# AND ACCEPTS TWO TREES THAT MERELY SHARE A PARENT, which the first version of
# the check above got wrong -- it asserted that `C:/dev/sub` into
# `C:/dev/z-backup` must be refused, and neither contains the other. A test that
# demands a refusal the code should not make is a test that would have been
# "fixed" by making the code refuse valid work.
check "mirror allows siblings under one parent" [expr {
    [catch {::machteld::MirrorValidatePaths C:/dev/sub C:/dev2/z-backup 0}] == 0}]
check "mirror refuses a drive root as destination" [expr {
    [errcode_of {::machteld::MirrorValidatePaths C:/dev D:/ 1}] eq {MACHTELD MIRROR badvalue}}]

# MR3b: THE ATTACK THAT GOT THROUGH. A destination JUNCTION pointing into the
# mirror source passed every clause above, because `file normalize` does not
# resolve a reparse point that is the final component and `file stat` describes
# the junction rather than its target -- so `physical` was not physical and the
# containment tests were asking about the wrong object. Reproduced end to end by
# adversarial review: robocopy's own /L verdict named a file INSIDE THE SOURCE
# as a destination extra, which is to say a real /MIR would have deleted it.
#
# Fixed by the `canon` verb, and this is the regression test. It builds the
# reviewer's fixture rather than describing it, because the whole failure was
# that the code's model of a junction and Windows' model of one disagreed.
set MRJFX [file join [file dirname $FX] mt_mirror_jn]
file delete -force $MRJFX
file mkdir [file join $MRJFX ws sub]
file mkdir [file join $MRJFX away]
FxWrite [file join $MRJFX ws sub PRECIOUS.txt] "do not delete\n"
set MRJ [file join $MRJFX away z-backup]
catch {exec cmd /c mklink /J [file nativename $MRJ] [file nativename [file join $MRJFX ws sub]]}
if {![file exists $MRJ]} {
    puts "     (no junction: mklink /J failed -- the junction-destination check needs one)"
} else {
    check "canon resolves a destination junction to its target" [expr {
        [string equal -nocase [valof {dict get [canon $MRJ] path}] \
                              [valof {dict get [canon [file join $MRJFX ws sub]] path}]]}]
    check "mirror refuses a destination junction pointing into the source" [expr {
        [errcode_of {::machteld::MirrorPlan [file join $MRJFX ws] $MRJ 0}]
        eq {MACHTELD MIRROR badvalue}}]
    # AND THE SOURCE-SIDE MIRROR IMAGE: a SOURCE reached through a junction that
    # lands inside the destination.
    check "mirror still allows two genuinely separate trees" [expr {
        [catch {::machteld::MirrorPlan [file join $MRJFX ws] \
                    [file join $MRJFX away2 z-backup] 0}] == 0}]
}
file delete -force $MRJFX

# MR4: robocopy's exit code is a BITFIELD. Reading it as an ordinal is the
# classic way to call a successful mirror a failure -- 3 is the everyday code.
check "mirror reads exit 0"  [expr {
    [::machteld::MirrorExitMeaning 0] eq "no changes; destination already matched source"}]
check "mirror reads exit 3 as two facts" [expr {
    [::machteld::MirrorExitMeaning 3] eq "copied files; destination extras noticed or removed"}]
check "mirror reads exit 8 as failure" [expr {
    [string first "copy failures" [::machteld::MirrorExitMeaning 8]] >= 0}]
check "mirror reads exit 16 as fatal" [expr {
    [string first "fatal robocopy error" [::machteld::MirrorExitMeaning 16]] >= 0}]

# MR5: robocopy's summary block, parsed out of a real log tail.
set MRLOG "
                 Total     Copied    Skipped  Mismatch    FAILED     Extras
    Dirs :       21892      15362       6530         0         0      10985
   Files :      280406     191533      88873         0         0     151812
   Bytes : 16136895273 8703969842 7432925431         0         0 6557800025
   Times :     0:00:10    0:00:00                        0:00:00    0:00:10
   Ended : Tuesday, August 11, 2026 22:32:32
"
set MRS [::machteld::MirrorParseSummary $MRLOG]
check "mirror parses the dirs row"  [expr {[dict get $MRS dirs total] eq "21892"}]
check "mirror parses the files row" [expr {[dict get $MRS files extras] eq "151812"}]
check "mirror parses the bytes row" [expr {[dict get $MRS bytes copied] eq "8703969842"}]
check "mirror parses the ended line" [expr {
    [dict get $MRS ended] eq "Tuesday, August 11, 2026 22:32:32"}]
check "mirror renders the summary z's way" [expr {
    [lindex [::machteld::MirrorSummaryLines "  would change" $MRS] 1] eq
    "  dirs  total=21892 copied=15362 skipped=6530 failed=0 extras=10985"}]
# AND SAYS SO WHEN THERE IS NOTHING. A summary silently rendered as blank is a
# preflight reporting no drift when it simply could not read the log.
check "mirror says when it found no summary" [expr {
    [lindex [::machteld::MirrorSummaryLines "x" [::machteld::MirrorParseSummary "nothing"]] 1]
    eq "  (robocopy summary not found)"}]

# MR6: the reserved-extra correction. The destination's own link manifest has no
# source-side counterpart during a run, so /MIR counts it as an extra and sets
# bit 2 -- drift that is entirely this command's own bookkeeping.
set MRONE [::machteld::MirrorParseSummary "
    Dirs :  1  0  1  0  0  0
   Files :  1  0  0  0  0  1
   Bytes : 10  0  0  0  0 10
"]
lassign [::machteld::MirrorNormalizeReservedSize 3 $MRONE 10] MRCODE MRFIX
check "mirror subtracts the reserved extra" [expr {[dict get $MRFIX files extras] == 0}]
check "mirror subtracts its bytes too" [expr {[dict get $MRFIX bytes extras] == 0}]
check "mirror clears the extras bit only when nothing is left" [expr {$MRCODE == 1}]
# ...and NOT when there is real drift beside it.
set MRTWO [::machteld::MirrorParseSummary "
    Dirs :  1  0  1  0  0  2
   Files :  1  0  0  0  0  5
   Bytes : 10  0  0  0  0 99
"]
lassign [::machteld::MirrorNormalizeReservedSize 3 $MRTWO 10] MRCODE2 MRFIX2
check "mirror keeps the extras bit when drift remains" [expr {$MRCODE2 == 3}]
check "mirror leaves the other extras alone" [expr {[dict get $MRFIX2 files extras] == 4}]

# MR7: the quoting a command line needs before it goes in a report.
check "mirror quotes an argument with spaces" [expr {
    [::machteld::MirrorCommandLine {C:\x\rc.exe} {a b {c d}}] eq {C:\x\rc.exe a b "c d"}}]
check "mirror escapes an embedded quote" [expr {
    [string first {\"} [::machteld::MirrorCommandLine x [list {a"b}]]] >= 0}]

# MR8: the state and artefact writers produce parseable JSON with z's key names,
# because `z status` and `z logs` read them.
set MRSTATE [::machteld::LedgerJson [list o [::machteld::MirrorStateObj \
    [dict create stage preflight updatedAt 2026-01-01T00:00:00 heartbeat 1 pid 2 \
                 runId r1 dryRun 1 source S dest D logDir L reportPath R]]]]
set MRD [valof {json decode $MRSTATE}]
check "mirror's state file is valid JSON"      [expr {[dict exists $MRD stage]}]
check "mirror's state names the run"           [expr {[valof {dict get $MRD runId}] eq "r1"}]
check "mirror's state spells dryRun as a bool" [expr {[string first {"dryRun": true} $MRSTATE] > 0}]
check "the json writer has a boolean type"     [expr {
    [::machteld::LedgerJson {b 0}] eq "false" && [::machteld::LedgerJson {b 1}] eq "true"}]

# MR9: mirror is a promoted front-door command, and the manifest knows it.
check "mirror is a promoted front-door command" [expr {"mirror" in [::machteld::FrontCommands]}]
check "the manifest declares the mirror subcommand" [expr {
    "mirror" in [dict get [manifest] front subcommands]}]

# --- `links`: the same walk, asked what redirects and what is shared ----------
#
# THE VERB `mirror` IS BUILT ON. A fixture rather than the live tree, because the
# facts have to be arranged: two junctions in 302,654 real entries is not a test,
# it is a coincidence that happens to hold today.
set LKFX [file join [file dirname $FX] mt_links_fx]
file delete -force $LKFX
file mkdir [file join $LKFX plain sub]
file mkdir [file join $LKFX target]
FxWrite [file join $LKFX plain a.txt] "a\n"
FxWrite [file join $LKFX target t.txt] "t\n"
# A junction and a hardlink both work without elevation; a SYMLINK needs either
# admin or Developer Mode, so it is attempted and skipped WITH A NOTICE rather
# than silently dropped -- a check that quietly does not run is the shape this
# suite exists to refuse.
set LKJ [file join $LKFX jn]
catch {exec cmd /c mklink /J [file nativename $LKJ] [file nativename [file join $LKFX target]]}
set LKHAVEJ [file exists $LKJ]
set LKSYM [file join $LKFX sym.txt]
catch {exec cmd /c mklink [file nativename $LKSYM] [file nativename [file join $LKFX plain a.txt]]}
set LKHAVES [file exists $LKSYM]
catch {exec cmd /c mklink /H [file nativename [file join $LKFX plain b.txt]] \
                             [file nativename [file join $LKFX plain a.txt]]}
set LKHAVEH [file exists [file join $LKFX plain b.txt]]
if {!$LKHAVEJ} { puts "     (no junction: mklink /J failed -- the links junction checks need one)" }
if {!$LKHAVES} { puts "     (no symlink: mklink needs admin or Developer Mode -- that check is skipped)" }
if {!$LKHAVEH} { puts "     (no hardlink: mklink /H failed -- the -hardlinks checks need one)" }

set LK [links $LKFX]
# FIELD ACCESS THAT CANNOT ABORT THE RUN. `dict get` on a row that is not there
# raises, and a raise here takes the remaining two hundred checks with it -- the
# `valof` lesson, which this suite has now learned six times. A missing row
# yields "" and fails its own check, loudly, alone.
proc lkat {d kind path field} {
    if {[catch {dict get $d $kind} rows]} { return "" }
    foreach e $rows {
        if {[catch {dict get $e path} p]} continue
        if {[string match "*$path" $p]} {
            if {[catch {dict get $e $field} v]} { return "" }
            return $v
        }
    }
    return ""
}
proc lkslash {p} { return [string tolower [string map {\\ /} $p]] }
check "links counts the files it walked past" [expr {[valof {dict get $LK files}] >= 2}]
check "links counts directories like dirs does" [expr {[valof {dict get $LK dirs}] >= 4}]
if {$LKHAVEJ} {
    check "links names a junction as z names it" [expr {
        [lkat $LK links /jn type] eq "junction"}]
    check "links reads the junction's target" [expr {
        [lkslash [lkat $LK links /jn target]] eq [lkslash [file join $LKFX target]]}]
    check "links reports the junction's tag" [expr {
        [lkat $LK links /jn tag] eq "0xa0000003"}]
    # AND DOES NOT DESCEND IT. `target/t.txt` is reachable through the junction
    # as well as through `target` itself, so a walker that entered the junction
    # would count it twice.
    check "links does not descend a name surrogate" [expr {[valof {dict get $LK files}] <= 5}]
}
if {$LKHAVES} {
    check "links names a file symlink" [expr {
        [lkat $LK links /sym.txt type] eq "file symlink"}]
    check "links reads the symlink's target" [expr {
        [lkat $LK links /sym.txt target] ne ""}]
}
# WITHOUT -hardlinks THE HANDLE IS NEVER TAKEN, which is the whole reason it is
# an option: one open per file at ~66 us against ~3.3 us for the walk.
check "links reports no multilinks unless asked" [expr {[dict get $LK multilinked] eq ""}]
if {$LKHAVEH} {
    set LKH [links $LKFX -hardlinks]
    check "links -hardlinks finds both names of the shared file" [expr {
        [llength [valof {dict get $LKH multilinked}]] == 2}]
    check "links -hardlinks reports the link count" [expr {
        [lkat $LKH multilinked /a.txt links] == 2}]
    # A reparse point's bytes are a link payload, not shared content, so it is
    # never opened for a count it cannot have.
    if {$LKHAVES} {
        check "links -hardlinks ignores reparse points" [expr {
            [lkat $LKH multilinked /sym.txt links] eq ""}]
    }
}
check "links refuses an unknown option" [expr {
    [errcode_of {links $LKFX -nope 1}] eq {MACHTELD DIRS usage}}]
check "dirs refuses the option only links takes" [expr {
    [errcode_of {dirs $LKFX -hardlinks}] eq {MACHTELD DIRS usage}}]
check "links refuses a missing root like dirs does" [expr {
    [errcode_of {links [file join $LKFX no_such_dir_zzz]}] eq {MACHTELD DIRS notfound}}]
# The palette's two verbs must not drift apart on the shared half.
check "links and dirs count the same directories" [expr {
    [dict get $LK dirs] == [dict get [dirs $LKFX] dirs]}]
check "links honours -depth" [expr {[dict get [links $LKFX -depth 0] dirs] == 1}]

file delete -force $LKFX
check "the links fixture tore down completely" [expr {![file exists $LKFX]}]

# --- `ledger`: the payload inventory, and Go's JSON transcribed ---------------
#
# THE FORMAT IS THE WHOLE PROBLEM. `book/payloads.lock.json` is written into a
# workspace BOTH front doors share, so it has to match `json.MarshalIndent` byte
# for byte or the two tools call each other's output stale forever. The
# agreement test diffs against the live z; these gates pin the rules that make
# that possible, one Go behaviour at a time, so a break says WHICH rule went.

# LJ1: Go's string escaping, including the three nobody expects. `encoding/json`
# HTML-escapes by default -- z calls `MarshalIndent`, not an Encoder with
# SetEscapeHTML(false) -- so `<`, `>` and `&` come out as \u escapes in a file no
# browser will ever load.
check "ledger escapes < as \\u003c"  [expr {[::machteld::LedgerJsonStr "a<b"] eq {"a\u003cb"}}]
check "ledger escapes > as \\u003e"  [expr {[::machteld::LedgerJsonStr "a>b"] eq {"a\u003eb"}}]
check "ledger escapes & as \\u0026"  [expr {[::machteld::LedgerJsonStr "a&b"] eq {"a\u0026b"}}]
check "ledger escapes the quote"     [expr {[::machteld::LedgerJsonStr "a\"b"] eq {"a\"b"}}]
check "ledger escapes the backslash" [expr {[::machteld::LedgerJsonStr "a\\b"] eq {"a\\b"}}]
check "ledger uses the short escapes" [expr {
    [::machteld::LedgerJsonStr "a\nb\tc\rd"] eq {"a\nb\tc\rd"}}]
# Every other C0 control is \u00xx in LOWERCASE hex -- Go uses neither \b nor \f.
check "ledger spells other controls \\u00xx" [expr {
    [::machteld::LedgerJsonStr "a\u0007b"] eq {"a\u0007b"}}]
check "ledger does not use \\b for backspace" [expr {
    [::machteld::LedgerJsonStr "a\u0008b"] eq {"a\u0008b"}}]
check "ledger spells U+2028 and U+2029" [expr {
    [::machteld::LedgerJsonStr "a\u2028b\u2029c"] eq {"a\u2028b\u2029c"}}]
check "ledger leaves DEL alone (Go does)" [expr {
    [::machteld::LedgerJsonStr "a\u007fb"] eq "\"a\u007fb\""}]

# LJ2: the indenter. An EMPTY object stays on one line, which is not a corner
# case here -- every payload without a source ends `"restore": {}`.
check "ledger writes an empty object as {}"   [expr {[::machteld::LedgerJson {o {}}] eq "\{\}"}]
check "ledger writes an empty array as \[\]"  [expr {[::machteld::LedgerJson {a {}}] eq "\[\]"}]
check "ledger writes null"                    [expr {[::machteld::LedgerJson {n {}}] eq "null"}]
check "ledger indents two spaces per level" [expr {
    [::machteld::LedgerJson [list o [list k [list a [list {i 1} {i 2}]]]]] eq
    "\{\n  \"k\": \[\n    1,\n    2\n  \]\n\}"}]

# LJ3: the version rules, which are not guessable from the output. A payload's
# version is not its directory name: `cpython-3.12.13-windows-x86_64-none` is
# reported as `3.12.13`, and `winsdk` has no version in its path at all.
check "ledger reads the semantic version out of a python dir" [expr {
    [::machteld::LedgerSemantic cpython-3.12.13-windows-x86_64-none] eq "3.12.13"}]
check "ledger takes a bare version as itself" [expr {[::machteld::LedgerSemantic 9.0.4] eq "9.0.4"}]
check "ledger finds no version in a bare name" [expr {[::machteld::LedgerSemantic winsdk] eq ""}]
check "ledger does not call a lone dot a version" [expr {![::machteld::LedgerLooksVersion "."]}]

# LJ4: a cached download is claimed by DIGIT-BOUNDED version match, so `1.25`
# does not claim `1.25.11`'s archive and `1.4` does not claim `21.4`'s.
check "ledger matches a version at a boundary" [expr {
    [::machteld::LedgerContainsVersion "node-v24.16.0-win-x64.zip" "24.16.0"]}]
check "ledger refuses a version that is a prefix" [expr {
    ![::machteld::LedgerContainsVersion "go1.25.11.windows-amd64.zip" "1.25"]}]
check "ledger refuses a version preceded by a digit" [expr {
    ![::machteld::LedgerContainsVersion "v21.4.zip" "1.4"]}]
check "ledger compacts to letters and digits" [expr {
    [::machteld::LedgerCompact "SQLite-3.53.2_x64"] eq "sqlite3532x64"}]
# The compact token is used only when it is long enough to mean something: Go's
# threshold is 4, so `1.2.3` (compact `123`) never contributes one.
check "ledger drops a compact version token under 4 chars" [expr {
    [lindex [::machteld::LedgerMatcher sqlite 1.2.3 0] 2] eq ""}]
check "ledger keeps a compact version token of 4+" [expr {
    [lindex [::machteld::LedgerMatcher sqlite 3.53.2 0] 2] eq "3532"}]

# LJ5: `filepath.IsAbs` on Windows -- a ROOTED path is not an absolute one, and
# only absolute `pre` arguments become entrypoints.
check "ledger calls a drive path absolute"   [::machteld::LedgerAbsolute {C:\x\y.exe}]
check "ledger calls a UNC path absolute"     [::machteld::LedgerAbsolute {\\srv\share\y.exe}]
check "ledger calls a rooted path relative"  [expr {![::machteld::LedgerAbsolute {\x\y.exe}]}]
check "ledger calls a bare arg relative"     [expr {![::machteld::LedgerAbsolute {-Q}]}]
check "ledger relativises with forward slashes" [expr {
    [::machteld::LedgerRelSlash {C:\dev\.z} {C:\dev\.z\t\rg\rg.exe}] eq "t/rg/rg.exe"}]

# LJ6: A WHOLE WORKSPACE, AND THE EXACT BYTES IT PRODUCES.
#
# The fixture is small enough to write the expected document out in full, which
# is the point: a golden file is the only test that catches a field emitted in
# the wrong ORDER, or an `omitempty` applied where Go does not apply one. The
# three hashes are computed rather than pasted, because they are facts about the
# fixture's contents and nothing is learned by hard-coding them.
#
# `Zed` EARNS ITS PLACE TWICE. It is the only fixture payload the manifest does
# not describe, so it is the only one that produces the bare `"restore": {}` --
# the Go-ism this file calls the easiest thing in the world to leave out, and
# which two sourced payloads would never have exercised. And its capital letter
# pins the SORT: ids are ordered by byte, so `tool:Zed` comes before
# `tool:toolone`, where any case-folding comparison puts it after.
set LFX [file join [file dirname $FX] mt_ledger_fx]
file delete -force $LFX
file mkdir [file join $LFX .z t toolone]
file mkdir [file join $LFX .z t Zed]
file mkdir [file join $LFX .z r gh]
file mkdir [file join $LFX .z cache downloads]
FxWrite [file join $LFX .z t toolone toolone.exe] "toolone\n"
FxWrite [file join $LFX .z t Zed Zed.exe] "zed\n"
FxWrite [file join $LFX .z r gh gh.exe] "gh\n"
FxWrite [file join $LFX .z cache downloads toolone-1.2.3-win.zip] "zip\n"
FxWrite [file join $LFX .z manifest.json] {{"tools": {
  "toolone": {"version": "1.2.3", "license": "MIT",
              "source": "https://example.invalid/toolone?a=1&b=2", "exe": "toolone.exe"},
  "ghcli":   {"version": "2.0.0", "source": "https://example.invalid/gh",
              "exeFromRoot": "r/gh/gh.exe"}
}}}

# The fixture runs in a CHILD, because FrontRoots resolves the workspace once per
# process and this suite is already standing in the real one.
proc LedgerMt {root args} {
    global MT
    return [run -timeout 120s -env [list MT_ROOT $root MT_HOME [file join $root .z]] \
                -- $MT {*}$args]
}
proc LedgerLines {r} { return [split [string map {\r\n \n} [string trim [dict get $r out]]] \n] }
proc LedgerSlurp {path} {
    if {[catch {open $path rb} fh]} { return "" }
    set d [read $fh]
    close $fh
    return [encoding convertfrom utf-8 $d]
}

set r [LedgerMt $LFX ledger check]
check "ledger check reports a missing lock" [expr {
    [lindex [LedgerLines $r] 0] eq "missing book/payloads.lock.json"}]
check "ledger check exits 1 when something is missing" [expr {[dict get $r exit] == 1}]
# THE ONE LINE THAT IS NOT z's, and it is deliberate: a front door replacing z
# does not answer a problem by telling you to go and run z.
check "ledger check names the front door in its advice" [expr {
    [lindex [LedgerLines $r] end] eq "run: mt ledger refresh"}]

set r [LedgerMt $LFX ledger refresh]
check "ledger refresh exits 0" [expr {[dict get $r exit] == 0}]
# ONE file, not two: with no msys2 payload there is no package lock to write, and
# z omits the key rather than writing an empty file.
check "ledger refresh writes only what it has" [expr {
    [LedgerLines $r] eq {{updated book/payloads.lock.json}}}]

set LGOT [LedgerSlurp [file join $LFX .z book payloads.lock.json]]
set LH1 [valof {hash file sha256 [file join $LFX .z r gh gh.exe]}]
set LH2 [valof {hash file sha256 [file join $LFX .z t toolone toolone.exe]}]
set LH3 [valof {hash file sha256 [file join $LFX .z cache downloads toolone-1.2.3-win.zip]}]
set LH4 [valof {hash file sha256 [file join $LFX .z t Zed Zed.exe]}]
set LWANT [join [list \
"\{" \
{  "schema": 1,} \
{  "generatedBy": "z ledger refresh",} \
{  "policy": "git tracks z code/docs/manifests/bookkeeping under Z_HOME; fetchable payload roots under t/, r/, go/, deno/, and cache/ are ignored",} \
"  \"files\": \{" \
{    "resolver": "manifest.json",} \
{    "payloadLock": "book/payloads.lock.json",} \
{    "msys2PackageLock": "book/msys2-packages.lock.txt"} \
"  \}," \
"  \"payloads\": \[" \
"    \{" \
{      "id": "runtime:gh:2.0.0",} \
{      "kind": "runtime",} \
{      "name": "gh",} \
{      "version": "2.0.0",} \
{      "path": "r/gh",} \
{      "source": "https://example.invalid/gh",} \
"      \"aliases\": \[" \
{        "ghcli"} \
"      \]," \
"      \"entrypoints\": \[" \
"        \{" \
{          "path": "r/gh/gh.exe",} \
"          \"aliases\": \[" \
{            "ghcli"} \
"          \]," \
"          \"sha256\": \"$LH1\"," \
{          "bytes": 3} \
"        \}" \
"      \]," \
"      \"restore\": \{" \
{        "method": "manual download or package-manager install, then run z ledger refresh",} \
{        "source": "https://example.invalid/gh"} \
"      \}" \
"    \}," \
"    \{" \
{      "id": "tool:Zed",} \
{      "kind": "tool",} \
{      "name": "Zed",} \
{      "path": "t/Zed",} \
"      \"aliases\": \[" \
{        "Zed"} \
"      \]," \
"      \"entrypoints\": \[" \
"        \{" \
{          "path": "t/Zed/Zed.exe",} \
"          \"aliases\": \[" \
{            "Zed"} \
"          \]," \
"          \"sha256\": \"$LH4\"," \
{          "bytes": 4} \
"        \}" \
"      \]," \
"      \"restore\": \{\}" \
"    \}," \
"    \{" \
{      "id": "tool:toolone",} \
{      "kind": "tool",} \
{      "name": "toolone",} \
{      "version": "1.2.3",} \
{      "path": "t/toolone",} \
{      "source": "https://example.invalid/toolone?a=1\u0026b=2",} \
{      "license": "MIT",} \
"      \"aliases\": \[" \
{        "toolone"} \
"      \]," \
"      \"entrypoints\": \[" \
"        \{" \
{          "path": "t/toolone/toolone.exe",} \
"          \"aliases\": \[" \
{            "toolone"} \
"          \]," \
"          \"sha256\": \"$LH2\"," \
{          "bytes": 8} \
"        \}" \
"      \]," \
"      \"cachedDownloads\": \[" \
"        \{" \
{          "path": "cache/downloads/toolone-1.2.3-win.zip",} \
"          \"sha256\": \"$LH3\"," \
{          "bytes": 4} \
"        \}" \
"      \]," \
"      \"restore\": \{" \
{        "method": "manual download or package-manager install, then run z ledger refresh",} \
{        "source": "https://example.invalid/toolone?a=1\u0026b=2"} \
"      \}" \
"    \}" \
"  \]" \
"\}" \
{}] \n]
check "ledger writes the document Go would write, byte for byte" [expr {$LGOT eq $LWANT}]
if {$LGOT ne $LWANT} {
    set la [split $LGOT \n] ; set lb [split $LWANT \n]
    set n [expr {[llength $la] > [llength $lb] ? [llength $la] : [llength $lb]}]
    for {set i 0} {$i < $n} {incr i} {
        if {[lindex $la $i] ne [lindex $lb $i]} {
            puts "     first difference at line [expr {$i + 1}]:"
            puts "       got:  [lindex $la $i]"
            puts "       want: [lindex $lb $i]"
            break
        }
    }
}
# THE AMPERSAND IS IN THE FIXTURE ON PURPOSE. `?a=1&b=2` is the one Go-ism no
# amount of staring at the real workspace would reveal, because not one of its
# 275 tools has a query string in its source URL. If HTML escaping is ever
# dropped, this is the check that says so.
check "ledger HTML-escapes an ampersand in real output" [expr {
    [string first {a=1\u0026b=2} $LGOT] > 0}]

set r [LedgerMt $LFX ledger check]
check "ledger check calls a fresh lock current" [expr {
    [LedgerLines $r] eq {{ok: payload ledgers are current}}}]
check "ledger check exits 0 when current" [expr {[dict get $r exit] == 0}]

# A PAYLOAD CHANGED IS A STALE LEDGER, which is what the hashes are for.
FxWrite [file join $LFX .z t toolone toolone.exe] "toolone-v2\n"
set r [LedgerMt $LFX ledger check]
check "ledger check notices a changed payload" [expr {
    [lindex [LedgerLines $r] 0] eq "stale book/payloads.lock.json"}]
check "ledger check exits 1 when stale" [expr {[dict get $r exit] == 1}]
LedgerMt $LFX ledger refresh
set r [LedgerMt $LFX ledger check]
check "ledger refresh makes it current again" [expr {[dict get $r exit] == 0}]

# An empty workspace: `payloads` has no `omitempty` in Go, so a nil slice is
# `null` and not `[]`. Easy to get wrong, invisible in the real workspace.
set LFXE [file join [file dirname $FX] mt_ledger_empty]
file delete -force $LFXE
file mkdir [file join $LFXE .z]
FxWrite [file join $LFXE .z manifest.json] {{"tools": {}}}
LedgerMt $LFXE ledger refresh
set LEMPTY [LedgerSlurp [file join $LFXE .z book payloads.lock.json]]
check "ledger writes null, not \[\], for no payloads" [expr {
    [string first "\"payloads\": null\n\}" $LEMPTY] > 0}]

# LJ7: usage, and the front-door wiring.
check "ledger is a promoted front-door command" [expr {"ledger" in [::machteld::FrontCommands]}]
check "the manifest declares the ledger subcommand" [expr {
    "ledger" in [dict get [manifest] front subcommands]}]
check "front ledger with no subcommand is a usage error" [expr {
    [errcode_of {front ledger}] eq {MACHTELD FRONT usage}}]
check "front ledger with a bad subcommand is a usage error" [expr {
    [errcode_of {front ledger polish}] eq {MACHTELD FRONT usage}}]

# LJ8: THE EXIT CODE A VERDICT COMMAND REPORTS. `mt verify` printed problems and
# exited 0 until 2026-08-11, so `mt verify && deploy` deployed on a broken
# workspace. FrontStatus is the mechanism; both its users are checked.
check "FrontStatus is zero after a command with nothing to report" [expr {
    [front roots] ne "" && [::machteld::FrontStatus] == 0}]
set r [LedgerMt $LFX verify]
check "verify exits 0 on a clean fixture workspace" [expr {[dict get $r exit] == 0}]
# ...and 1 where there is something to report. Asserted against the OUTPUT
# rather than against a count, so this stays true the day the real workspace's
# five layout problems are fixed.
set r [run -timeout 120s -- $MT verify]
check "verify's exit code follows its verdict" [expr {
    [string match "problems:*" [string trim [dict get $r out]]]
        ? [dict get $r exit] == 1 : [dict get $r exit] == 0}]

file delete -force $LFX $LFXE
check "the ledger fixtures tore down completely" [expr {
    ![file exists $LFX] && ![file exists $LFXE]}]

DirsWipe $FX
DirsWipe $FXO
check "the fixture tore down completely" [expr {![file exists $FX] && ![file exists $FXO]}]

file delete $CHILD
puts "\n[expr {$fails == 0 ? {ALL PASS} : {FAILURES}}]: $fails failure(s)"
exit $fails
