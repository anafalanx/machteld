# macht_test.tcl -- the macht family at the verb level (docs/engine.md).
# The wire itself is proven by engine_test.tcl; this lane proves the host
# side: lifecycle, the lazy default, addressing, budget-by-kill with a
# clean respawn, capability refusal, and conform.

package require machteld 0.11.0

set fails 0
proc check {name ok} {
    global fails
    if {$ok} { puts "ok   $name" } else { puts "FAIL $name"; incr fails }
}
proc code_of {script} {
    if {[catch [list uplevel 1 $script] msg opts]} {
        return [lindex [dict get $opts -errorcode] 2]
    }
    return "(no error: $msg)"
}

scope {
    # The lazy default: the first work subcommand starts an engine.
    check "def returns the kernel name (lazy default engine starts)" \
        [string equal [macht def dub {function dub(x) return 2*x end}] dub]
    check "run calls a kernel with a scalar" [expr {[macht run dub 21] == 42}]

    set st [macht status]
    check "status observes the default engine" [expr {
        [dict get $st threads] >= 1 && [dict get $st pid] > 0 &&
        "lua" in [dict get $st capabilities]}]

    # Explicit engines and addressing.
    set e [macht start -threads 2]
    check "start returns an engine token" [string match macht#* $e]
    macht def -engine $e half {function half(x) return x // 2 end}
    check "-engine addresses a specific engine" \
        [expr {[macht run half 84 -engine $e] == 42}]
    check "the second engine reports its thread bound" \
        [expr {[dict get [macht status $e] threads] == 2}]
    check "a kernel of one engine is unknown to another" \
        [string equal [code_of {macht run half 84}] lua]

    # Road 3 plus handles, shards, reduce, through the verb.
    set fixture [file join [pwd] macht_test_fixture.txt]
    set f [open $fixture wb]
    puts -nonewline $f "alpha\r\nbeta\n\ngamma"
    close $f
    set h [macht load -lines $fixture]
    check "load -lines returns a pool handle" [string match pool#* $h]
    macht def nonempty {function nonempty(h)
        local n = 0
        for i = 1, h.rows do
            if #h.line[i] > 0 then n = n + 1 end
        end
        return n
    end}
    check "a kernel runs over the pool" [expr {[macht run nonempty $h] == 3}]
    set parts [macht run nonempty $h -shards 2]
    check "-shards returns the partials" [expr {
        [llength $parts] == 2 && [tcl::mathop::+ {*}$parts] == 3}]
    macht def sum_of {function sum_of(ps)
        local s = 0
        for i = 1, #ps do s = s + ps[i] end
        return s
    end}
    check "-reduce folds engine-side" \
        [expr {[macht run nonempty $h -shards 2 -reduce sum_of] == 3}]

    # Structured arguments cross once as -json, by the json organ's rules.
    macht def first_of {function first_of(xs) return xs[1] end}
    check "-json carries a structured argument" \
        [expr {[macht run first_of -json {[10,20,30]}] == 10}]

    # The boundary's tagged floats arrive as the tagged dict, undisturbed.
    macht def notnum {function notnum() return 0/0 end}
    set v [macht run notnum]
    check "non-finite floats arrive tagged" [expr {
        [dict exists $v float] && [dict get $v float] eq "nan"}]

    # Refusals, by name and by capability.
    check "an undeclared capability is refused" \
        [string equal [code_of {macht load -csv $fixture}] refused]
    check "an unknown subcommand is usage" \
        [string equal [code_of {macht nonsense}] usage]
    macht free $h
    check "a freed pool is nohandle" \
        [string equal [code_of {macht run nonempty $h}] nohandle]

    # Budget is a kill, and the default engine respawns lazily after it.
    macht def hang {function hang() while true do end end}
    check "a budget breach kills the engine and is coded budget" \
        [string equal [code_of {macht run hang -budget 300ms}] budget]
    check "the default engine respawns lazily after the kill" [expr {
        [macht def dub {function dub(x) return 2*x end}] eq "dub" &&
        [macht run dub 21] == 42}]

    # Stop semantics.
    macht stop $e
    check "a stopped engine is noengine" \
        [string equal [code_of {macht run half 84 -engine $e}] noengine]
    macht stop
    check "after stopping the default, work restarts it fresh" [expr {
        [macht def dub {function dub(x) return 2*x end}] eq "dub" &&
        [macht run dub 21] == 42}]

    # Conform: the built-in engine passes its own suite.
    set rep [macht conform [info nameofexecutable] --machteld-engine 2]
    set names [lmap chk [dict get $rep checks] {lindex $chk 0}]
    check "conform reports its named checks" [expr {
        "hello-negotiates" in $names && "quit-clean" in $names}]
    check "the built-in engine passes its own conformance suite" \
        [dict get $rep ok]
    check "conform on a non-engine fails closed" \
        [string equal [code_of {macht conform no-such-engine.exe}] noengine]

    macht stop
    file delete -- $fixture
}

puts [expr {$fails == 0 ? "ALL MACHT TESTS PASSED" : "$fails MACHT CHECK(S) FAILED"}]
exit [expr {$fails != 0}]
