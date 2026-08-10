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
    [lsort [dict get $M0 front options]] eq {-inherit -json}}]
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
    {child cli detach front hash help journal json log manifest mtps pmap pool pty run scope store tcl version vtstrip wait watch worker}}]
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
    foreach f [list [file join $SRC proc.c] [file join $SRC store.c] [file join $SRC json.c] [file join $SRC ps.c]] {
        set fh [open $f r] ; set text [read $fh] ; close $fh
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

# --- the shipped tools, self-testing -----------------------------------------
# Each tool is pure Tcl/Tk shipped inside mt.exe, and each carries a --selftest that
# exercises its model with no window -- a hidden Tk window drops events and would
# be testing something other than the program.
#
# Driven by a LIST rather than one hardcoded call: `tasks` shipped with its
# selftest unwired, so the tool had a passing test nothing ever ran. A gate that
# covers the first tool and not the second is how that happens twice.
foreach t {changes tasks sums life lifelab} {
    set TOOL [file join $HERE .. tool $t]
    if {![file isdirectory $TOOL]} { continue }
    check "$t passes its own selftest" [expr {
        ![catch {run -timeout 60s -- $MT tcl [file join $TOOL main.tcl] --selftest} tr]
        && [dict get $tr exit] == 0}]
}

# Every tool directory in tool/ must be covered by the loop above -- otherwise
# adding a third tool silently adds an untested one.
set known {changes tasks sums life lifelab}
set present [lmap d [glob -nocomplain -types d -directory [file join $HERE .. tool] *] {file tail $d}]
check "every tool in tool/ is selftested" [expr {[lsort $present] eq [lsort $known]}]

# --- and the same tools, reached BY NAME -------------------------------------
# The checkout runs above; this runs what SHIPPED. `wrap` used to stamp each
# tool into its own exe and the build proved the stamping by doing it; the tools
# ride in this exe's zipfs now, so the equivalent proof is that `mt <name>`
# finds them there. A tool present in tool/ but missing from the package would
# otherwise pass every check above and not exist in the product.
foreach t $known {
    check "$t resolves as a shipped tool" [expr {
        [valof {dict get [front env $t] kind}] eq "script"}]
    check "$t is listed by front tools"   [expr {$t in [front tools]}]
    check "front which $t names the script, not the exe" [expr {
        [string match "*/tool/$t/main.tcl" [valof {front which $t}]]}]
}
# By name, through the argv dispatcher, in a real child: the whole path.
check "a shipped tool runs by name" [expr {
    ![catch {run -timeout 60s -- $MT sums --selftest} tr] && [dict get $tr exit] == 0}]
# A NAME IS NOT A PATH, and here that is load-bearing rather than tidy. Every
# other name the front door resolves is a key in a dict the workspace wrote;
# this one is JOINED ONTO A DIRECTORY, and the string comes from argv.
#
# THE ZIPFS RESOLVES `..`. Checked, not assumed: `file exists
# //zipfs:/app/tool/../tool/sums/main.tcl` is 1. So without the name check the
# spellings below would resolve to a real shipped tool, and enough of them in a
# row would walk out of the archive and onto the disk. Every one must be refused
# by the name, before any file is looked at.
foreach bad {../tool/sums sums/../sums ../../app/tool/sums} {
    check "a traversal that WOULD find a tool is refused ($bad)" [expr {
        [errcode_of {front which $bad}] eq {MACHTELD FRONT notfound}}]
}
foreach bad {tool/sums a/b . SUMS} {
    check "a shipped-tool name may not be \"$bad\"" [expr {
        [errcode_of {front which $bad}] ne ""}]
}

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
check "tcl on a missing script says so"     [expr {
    [errcode_of {tcl no_such_script_zzz.tcl}] eq {MACHTELD TCL notfound}}]

# The window tests are separate FILES because they need a real mapped window, but
# they are driven from here so they cannot become tests nobody runs -- which is
# exactly what happened to `tasks --selftest`. Discovered by glob, so a new
# *_ui.tcl is picked up without anyone remembering to add it.
foreach uitest [lsort [glob -nocomplain -directory $HERE *_ui.tcl]] {
    set r [run -timeout 120s -- $MT tcl $uitest]
    check "[file tail $uitest] passes" [expr {[dict get $r exit] == 0}]
    if {[dict get $r exit] != 0} {
        puts "     [string trim [dict get $r out]]"
        puts "     [string trim [dict get $r err]]"
    }
}
check "there are window tests to run" [expr {
    [llength [glob -nocomplain -directory $HERE *_ui.tcl]] >= 1}]

# --- tools reject bad arguments instead of dying in a timer -------------------
# `tasks --interval` with nothing after it set the interval to the empty string;
# `after ""` then threw out of tick, so the tool died at startup -- or, worse, if
# it was already running, stopped refreshing while still showing a list that
# looked live. The next button in that window is End Task.
set TASKS [file join $HERE .. tool tasks main.tcl]
if {[file exists $TASKS]} {
    foreach {label argl} {
        "--interval with no value"   {--interval}
        "--interval with a non-number" {--interval abc}
        "--interval below the floor" {--interval 5}
        "an unknown argument"        {--nonsense}
    } {
        set r [run -timeout 30s -- $MT tcl $TASKS {*}$argl]
        check "tasks rejects $label" [expr {[dict get $r exit] == 2}]
        check "tasks explains $label" [expr {
            [string match "*tasks:*" [dict get $r err]] ||
            [string match "*tasks:*" [dict get $r out]]}]
    }
    # A valid value must survive the parser AND still reach the mode: validation
    # runs before --selftest is honoured, so this exercises both.
    set r [run -timeout 60s -- $MT tcl $TASKS --interval 500 --selftest]
    check "tasks accepts a valid --interval" [expr {[dict get $r exit] == 0}]
    set r [run -timeout 30s -- $MT tcl $TASKS --interval bogus --selftest]
    check "a bad --interval is caught even in selftest mode" [expr {[dict get $r exit] == 2}]
}

file delete $CHILD
puts "\n[expr {$fails == 0 ? {ALL PASS} : {FAILURES}}]: $fails failure(s)"
exit $fails
