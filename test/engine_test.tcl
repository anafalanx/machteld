# engine_test.tcl -- protocol-1 conformance of the built-in engine
# (docs/engine.md). Drives `machteld --machteld-engine` as a supervised
# child over binary frames, using the palette's json organ for the wire --
# one map, both organs, by contract.

package require machteld 0.11.0

set exe [info nameofexecutable]
set fails 0
proc check {name ok} {
    global fails
    if {$ok} { puts "ok   $name" } else { puts "FAIL $name"; incr fails }
}

# ---------- frames ----------

proc sendraw {payload} {
    global W
    set bytes [encoding convertto utf-8 $payload]
    chan puts -nonewline $W [binary format i [string length $bytes]]
    chan puts -nonewline $W $bytes
    chan flush $W
}
proc recvf {} {
    global R
    set hdr [chan read $R 4]
    if {[string length $hdr] != 4} { error "engine closed the pipe" }
    binary scan $hdr iu len
    return [json decode [encoding convertfrom utf-8 [chan read $R $len]]]
}
set SEQ 0
proc req {op args} {
    global SEQ
    set d [dict create id [incr SEQ] op $op {*}$args]
    sendraw [json encode -dict $d]
    set r [recvf]
    if {[dict get $r id] != $SEQ} { error "reply id mismatch for $op" }
    return $r
}
proc reqok {op args} {
    set r [req $op {*}$args]
    if {![dict get $r ok]} {
        error "engine refused $op: [dict get $r error]"
    }
    return $r
}
proc errcode {r} { dict get $r error code }

scope {
    set C [child start -channels -- $exe --machteld-engine 4]
    set io [child info $C]
    set W [dict get $io stdin]
    set R [dict get $io stdout]
    chan configure $W -translation binary -buffering none
    chan configure $R -translation binary -blocking 1

    # Ops before hello are protocol errors; hello negotiates.
    set r [req stats]
    check "the first request must be hello" \
        [expr {![dict get $r ok] && [errcode $r] eq "protocol"}]
    set h [reqok hello protocol 1 host machteld version 0.11.0]
    check "hello names the engine and protocol" [expr {
        [dict get $h engine] eq "machteld" && [dict get $h protocol] == 1}]
    set caps [dict get $h capabilities]
    check "hello declares the phase-2 capabilities" [expr {
        "lua" in $caps && "load.lines" in $caps && "shards" in $caps &&
        "reduce" in $caps && "stats" in $caps}]

    # Kernels: definition, caching, execution.
    set r [reqok def name double chunk {function double(x) return 2*x end}]
    check "def compiles and reports a hash" [dict exists $r hash]
    set r [reqok def name double chunk {function double(x) return 2*x end}]
    check "an identical chunk is a cache hit" \
        [expr {[dict exists $r cached] && [dict get $r cached]}]
    set r [reqok run name double args [list 21]]
    check "a kernel runs over a scalar argument" [expr {[dict get $r value] == 42}]
    check "a run reports engine-side ms" [dict exists $r ms]

    # The boundary's edge laws.
    reqok def name echo chunk {function echo(x) return x end}
    set r [reqok run name echo args [list 9007199254740993]]
    check "int64 crosses exactly (2^53+1)" \
        [expr {[dict get $r value] == 9007199254740993}]
    reqok def name istrue chunk {function istrue() return true end}
    check "lua true returns as 1" \
        [expr {[dict get [reqok run name istrue] value] == 1}]
    reqok def name nada chunk {function nada() return nil end}
    check "top-level nil returns as empty (null)" \
        [expr {[dict get [reqok run name nada] value] eq ""}]
    reqok def name half chunk {function half() return 0.5 end}
    check "floats stay floats" \
        [expr {[dict get [reqok run name half] value] == 0.5}]
    reqok def name notnum chunk {function notnum() return 0/0 end}
    set v [dict get [reqok run name notnum] value]
    check "NaN leaves as the tagged float object" [expr {
        [dict exists $v float] && [dict get $v float] eq "nan"}]
    reqok def name hi chunk {function hi() return "héllo" end}
    check "UTF-8 strings round-trip" \
        [expr {[dict get [reqok run name hi] value] eq "héllo"}]
    reqok def name bin chunk {function bin() return string.char(255) end}
    set r [req run name bin]
    check "a non-UTF-8 string is a type error" \
        [expr {![dict get $r ok] && [errcode $r] eq "type"}]
    reqok def name holed chunk {function holed()
        local t = {}
        t[1] = 1
        t[3] = 3
        return t
    end}
    set r [req run name holed]
    check "a hole in a sequence is a type error" \
        [expr {![dict get $r ok] && [errcode $r] eq "type"}]
    reqok def name boom chunk {function boom() error("kapot") end}
    set r [req run name boom]
    check "a kernel error is code lua with the message" [expr {
        ![dict get $r ok] && [errcode $r] eq "lua" &&
        [string match *kapot* [dict get $r error message]]}]
    set r [req run name nosuch]
    check "an unknown kernel is refused by name" \
        [expr {![dict get $r ok] && [errcode $r] eq "lua"}]

    # Road 3: the lines loader (CRLF mix, empty line, unterminated tail).
    set fixture [file join [pwd] engine_test_fixture.txt]
    set f [open $fixture wb]
    puts -nonewline $f "alpha\r\nbeta\n\ngamma"
    close $f
    set r [reqok load format lines path $fixture]
    set pool [dict get $r handle]
    check "load lines counts CRLF, empty, and unterminated rows" [expr {
        [dict get $r rows] == 4 && [dict get $r fields] eq "line"}]

    reqok def name nonempty chunk {function nonempty(h)
        local n = 0
        for i = 1, h.rows do
            if #h.line[i] > 0 then n = n + 1 end
        end
        return n
    end}
    set r [reqok run name nonempty args [list [dict create handle $pool]]]
    check "a kernel reads a pool view (rows and columns)" \
        [expr {[dict get $r value] == 3}]

    # Sharding: partials, reduce, and the thread bound.
    set r [reqok run name nonempty args [list [dict create handle $pool]] shards 4]
    set parts [dict get $r value]
    check "sharded runs return the partials in shard order" [expr {
        [llength $parts] == 4 && [tcl::mathop::+ {*}$parts] == 3}]
    reqok def name sum_of chunk {function sum_of(ps)
        local s = 0
        for i = 1, #ps do s = s + ps[i] end
        return s
    end}
    set r [reqok run name nonempty args [list [dict create handle $pool]] \
        shards 4 reduce sum_of]
    check "-reduce folds the partials engine-side" \
        [expr {[dict get $r value] == 3}]
    set r [req run name nonempty args [list [dict create handle $pool]] shards 5]
    check "shards above the engine's threads are refused" \
        [expr {![dict get $r ok] && [errcode $r] eq "badvalue"}]

    # Spill: the value ceiling turns a big result into a handle.
    reqok def name bigstr chunk {function bigstr()
        return string.rep("x", 2000000)
    end}
    set r [reqok run name bigstr]
    check "an oversized result spills to a handle" [expr {
        [dict exists $r spilled] && [dict get $r spilled] &&
        [string match res#* [dict get $r handle]]}]
    set res [dict get $r handle]
    reqok free handle $res
    set r [req free handle $res]
    check "a freed handle is nohandle" \
        [expr {![dict get $r ok] && [errcode $r] eq "nohandle"}]

    # Free the pool; uses after free are nohandle.
    reqok free handle $pool
    set r [req run name nonempty args [list [dict create handle $pool]]]
    check "a freed pool is nohandle" \
        [expr {![dict get $r ok] && [errcode $r] eq "nohandle"}]

    # Stats and protocol hygiene.
    set r [reqok stats]
    check "stats counts threads, runs, and spills" [expr {
        [dict get $r threads] == 4 && [dict get $r runs] > 0 &&
        [dict get $r spills] == 1 && [dict get $r pools] eq ""}]
    sendraw "this is not json"
    set r [recvf]
    check "a malformed frame is a protocol error with id 0" [expr {
        [dict get $r id] == 0 && ![dict get $r ok] &&
        [errcode $r] eq "protocol"}]
    set r [req cancel]
    check "cancel is acknowledged (advisory)" [dict get $r ok]

    # Graceful end.
    set r [req quit]
    check "quit replies before exit" [dict get $r ok]
    set w [child wait $C -timeout 5s]
    check "the engine exits cleanly" [expr {[dict get $w exit] == 0}]
    file delete -- $fixture
}

puts [expr {$fails == 0 ? "ALL ENGINE TESTS PASSED" : "$fails ENGINE CHECK(S) FAILED"}]
exit [expr {$fails != 0}]
