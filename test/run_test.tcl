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

file delete $CHILD
puts "\n[expr {$fails == 0 ? {ALL PASS} : {FAILURES}}]: $fails failure(s)"
exit $fails
