# engine_test.tcl -- protocol-1 conformance of the built-in engine
# (docs/engine.md). Drives `machteld --machteld-engine` as a supervised
# child over binary frames, using the palette's json organ for the wire --
# one map, both organs, by contract.

package require machteld 0.13.0

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
    set h [reqok hello protocol 1 host machteld version 0.13.0]
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

    # The kernel libraries: utf8, lpeg, cjson.
    reqok def name clen chunk {function clen(s) return utf8.len(s) end}
    check "utf8.len counts characters, not bytes" \
        [expr {[dict get [reqok run name clen args [list "héllo"]] value] == 5}]
    reqok def name fields chunk {function fields(s)
        local sep = lpeg.P(",")
        local field = lpeg.C((1 - sep)^0)
        local line = lpeg.Ct(field * (sep * field)^0)
        return line:match(s)
    end}
    set r [reqok run name fields args [list "a,b,c"]]
    check "lpeg parses in the cell" [expr {[dict get $r value] eq "a b c"}]
    reqok def name jround chunk {function jround(s)
        local doc = cjson.decode(s)
        return cjson.encode(doc.n)
    end}
    set r [reqok run name jround args [list {{"n":9007199254740993}}]]
    check "cjson round-trips int64 exactly in the cell" \
        [expr {[dict get $r value] eq "9007199254740993"}]

    # Road 3: the lines loader (CRLF mix, empty line, unterminated tail).
    set fixture [file join [pwd] engine_test_fixture.txt]
    set f [open $fixture wb]
    puts -nonewline $f "alpha\r\nbeta\n\ngamma"
    close $f
    set r [reqok load format lines path $fixture]
    set pool [dict get $r handle]
    check "load lines counts CRLF, empty, and unterminated rows" [expr {
        [dict get $r rows] == 4 && [dict get $r fields] eq "line"}]
    set r [req load format xml path $fixture]
    check "an unknown load format is refused by name" \
        [expr {![dict get $r ok] && [errcode $r] eq "refused"}]

    # Road 3: the csv loader against a hostile fixture - header, quoted
    # comma, doubled quote, embedded newline, CRLF and LF mixed, typed
    # columns.
    set csvfix [file join [pwd] engine_test_fixture.csv]
    set f [open $csvfix wb]
    puts -nonewline $f "name,note,status,ratio\r\n"
    puts -nonewline $f "alpha,\"a, quoted comma\",404,1.5\n"
    puts -nonewline $f "beta,\"a \"\"quoted\"\" word\",200,0.25\r\n"
    puts -nonewline $f "gamma,\"two\nlines\",500,2.0"
    close $f
    set r [reqok load format csv path $csvfix header 1 \
        schema [list name s note s status i ratio f]]
    set cpool [dict get $r handle]
    check "csv parses the hostile fixture into typed columns" [expr {
        [dict get $r rows] == 3 &&
        [dict get $r fields] eq "name note status ratio"}]
    reqok def name csum chunk {function csum(h)
        local acc = 0.0
        for i = 1, h.rows do
            if h.status[i] >= 400 then acc = acc + h.ratio[i] end
        end
        return acc
    end}
    set r [reqok run name csum args [list [dict create handle $cpool]]]
    check "a kernel computes over typed csv columns" \
        [expr {[dict get $r value] == 3.5}]
    reqok def name embedded chunk {function embedded(h)
        return h.note[3]
    end}
    check "an embedded newline survives quoting" [expr {
        [dict get [reqok run name embedded args \
            [list [dict create handle $cpool]]] value] eq "two\nlines"}]

    # The primitive palette (0.13.0): declared from the full vocabulary.
    check "col is a declared capability on this AVX2 host" \
        [expr {"col" in $caps}]
    reqok def name coltrio chunk {function coltrio(h)
        local sel = col.filter(h, "status", "lt", 500)
        return col.sum(h, "status") * 1000000
             + col.sum(h, "status", sel) * 1000
             + col.count(sel) * 10 + col.count(h)
    end}
    set r [reqok run name coltrio args [list [dict create handle $cpool]]]
    check "the trio computes over native columns (sum, filter, count)" \
        [expr {[dict get $r value] == 1104604023}]
    reqok def name colfused chunk {function colfused(h)
        local composed = col.sum(h, "status", col.filter(h, "status", "lt", 500))
        local fused = col.sumwhere(h, "status", "status", "lt", 500)
        return (fused == composed) and fused or -1
    end}
    check "the fused sumwhere agrees exactly with filter+sum" [expr {
        [dict get [reqok run name colfused \
            args [list [dict create handle $cpool]]] value] == 604}]
    reqok def name colerr chunk {function colerr(h, what)
        if what == 1 then return col.sum(h, "zzz") end
        if what == 2 then return col.sum(h, "note") end
        G_STASH = h
        return 0
    end}
    foreach {what pattern} {
        1 "*col: unknown field*"
        2 "*col: field note is not numeric*"
    } {
        set r [req run name colerr \
            args [list [dict create handle $cpool] $what]]
        check "col names its refusal ($pattern)" [expr {
            ![dict get $r ok] && [errcode $r] eq "lua" &&
            [string match $pattern [dict get $r error message]]}]
    }
    reqok run name colerr args [list [dict create handle $cpool] 3]
    reqok def name colleak chunk {function colleak(h)
        return col.filter(h, "status", "eq", 404)
    end}
    set r [req run name colleak args [list [dict create handle $cpool]]]
    check "a selection cannot cross the boundary" \
        [expr {![dict get $r ok] && [errcode $r] eq "type"}]
    reqok def name colforeign chunk {function colforeign(h, hb)
        local sel = col.filter(h, "status", "eq", 404)
        return col.sum(hb, "status", sel)
    end}
    set r [reqok load format csv path $csvfix header 1 \
        schema [list name s note s status i ratio f]]
    set cpool2 [dict get $r handle]
    set r [req run name colforeign args [list \
        [dict create handle $cpool] [dict create handle $cpool2]]]
    check "a foreign selection is refused by name" [expr {
        ![dict get $r ok] && [errcode $r] eq "lua" &&
        [string match "*bound to another view*" [dict get $r error message]]}]
    reqok free handle $cpool2
    reqok def name colstale chunk {function colstale()
        return col.count(G_STASH)
    end}

    # The float laws and the algebra, on a fixture that spells them out:
    # x = {1.5, nan, -0.0, 2.5, inf}, y = {10, 20, 30, 40, 50}.
    set fcsv [file join [pwd] engine_test_fixture_f.csv]
    set f [open $fcsv wb]
    puts -nonewline $f "x,y\n1.5,10\nnan,20\n-0.0,30\n2.5,40\ninf,50\n"
    close $f
    set r [reqok load format csv path $fcsv header 1 schema [list x f y i]]
    set fpool [dict get $r handle]
    reqok def name colfloat chunk {function colfloat(h)
        local gt1 = col.filter(h, "x", "gt", 1.0)
        local ne25 = col.filter(h, "x", "ne", 2.5)
        local r = {}
        r.gt1 = col.count(gt1)                 -- NaN matches nothing: 3
        r.ne25 = col.count(ne25)               -- ne matches NaN: 4
        r.both = col.count(col.band(gt1, ne25))          -- {1.5, inf}: 2
        r.either = col.count(col.bor(gt1, ne25))         -- all but 2.5? no: 5
        r.notgt1 = col.count(col.bnot(gt1))              -- {nan, -0.0}: 2
        r.demorgan = col.count(col.bnot(col.band(gt1, ne25))) ==
                     col.count(col.bor(col.bnot(gt1), col.bnot(ne25)))
        r.fmin = col.min(h, "x")               -- NaN skipped: -0.0 -> 0.0
        r.ysum = col.sumwhere(h, "y", "x", "gt", 1.0)    -- 10+40+50: 100
        r.fsum = col.sum(h, "x", gt1)          -- 1.5+2.5+inf = inf
        return r
    end}
    set v [dict get [reqok run name colfloat \
        args [list [dict create handle $fpool]]] value]
    check "float filters follow IEEE (NaN matches nothing but ne)" [expr {
        [dict get $v gt1] == 3 && [dict get $v ne25] == 4}]
    check "the selection algebra composes (band, bor, bnot, De Morgan)" [expr {
        [dict get $v both] == 2 && [dict get $v either] == 5 &&
        [dict get $v notgt1] == 2 && [dict get $v demorgan] == 1}]
    check "min skips NaN and sumwhere crosses types (f pred, i value)" [expr {
        [dict get $v fmin] == 0.0 && [dict get $v ysum] == 100}]
    check "a float sum reaching infinity leaves as the tagged float" [expr {
        [dict exists [dict get $v fsum] float] &&
        [dict get [dict get $v fsum] float] eq "inf"}]
    reqok def name colempty chunk {function colempty(h)
        return col.min(h, "x", col.filter(h, "x", "lt", -100.0))
    end}
    set r [req run name colempty args [list [dict create handle $fpool]]]
    check "min over an empty selection refuses by name" [expr {
        ![dict get $r ok] && [errcode $r] eq "lua" &&
        [string match "*col: empty selection*" [dict get $r error message]]}]
    reqok def name colnan chunk {function colnan(h)
        return col.sum(h, "x")
    end}
    set v [dict get [reqok run name colnan \
        args [list [dict create handle $fpool]]] value]
    check "a selected NaN propagates through the float sum" [expr {
        [dict exists $v float] && [dict get $v float] eq "nan"}]
    reqok def name colminmax chunk {function colminmax(h)
        return col.min(h, "y") * 1000 + col.max(h, "y")
    end}
    check "integer min and max work under no selection" [expr {
        [dict get [reqok run name colminmax \
            args [list [dict create handle $fpool]]] value] == 10050}]
    reqok free handle $fpool
    file delete -- $fcsv
    reqok free handle $cpool
    set r [req run name colstale]
    check "a stashed view outlives its pool by refusal, not by crash" [expr {
        ![dict get $r ok] && [errcode $r] eq "lua" &&
        [string match "*view outlives its pool*" [dict get $r error message]]}]
    set f [open $csvfix wb]
    puts -nonewline $f "a\n9223372036854775807\n9223372036854775807\n"
    close $f
    set r [reqok load format csv path $csvfix header 1 schema [list a i]]
    set opool [dict get $r handle]
    reqok def name colover chunk {function colover(h)
        return col.sum(h, "a")
    end}
    set r [req run name colover args [list [dict create handle $opool]]]
    check "an overflowing integer sum refuses by name" [expr {
        ![dict get $r ok] && [errcode $r] eq "lua" &&
        [string match "*col: integer overflow*" [dict get $r error message]]}]
    reqok def name coloverw chunk {function coloverw(h)
        return col.sumwhere(h, "a", "a", "gt", 0)
    end}
    set r [req run name coloverw args [list [dict create handle $opool]]]
    check "the fused path refuses overflow by name too" [expr {
        ![dict get $r ok] && [errcode $r] eq "lua" &&
        [string match "*col: integer overflow*" [dict get $r error message]]}]
    reqok free handle $opool
    set f [open $csvfix wb]
    puts -nonewline $f "1,2\n3,notanint\n"
    close $f
    set r [req load format csv path $csvfix schema [list a i b i]]
    check "a type failure names its line and field" [expr {
        ![dict get $r ok] && [errcode $r] eq "badvalue" &&
        [string match "*line 2*b*" [dict get $r error message]]}]
    set f [open $csvfix wb]
    puts -nonewline $f "a,b\n1,2,3\n"
    close $f
    set r [req load format csv path $csvfix]
    check "a ragged record names its line" [expr {
        ![dict get $r ok] && [errcode $r] eq "badvalue" &&
        [string match "*line 2*" [dict get $r error message]]}]
    set f [open $csvfix wb]
    puts -nonewline $f "\"unterminated"
    close $f
    set r [req load format csv path $csvfix]
    check "an unterminated quote is refused" [expr {
        ![dict get $r ok] && [errcode $r] eq "badvalue" &&
        [string match "*unterminated*" [dict get $r error message]]}]
    file delete -- $csvfix

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

    # First-touch sharded runs over fresh pools: every shard's view is
    # built concurrently, exercising the shared view-tracking lock (the
    # PoolTrackView race found by the 0.13.0 review panel). Best-effort
    # by nature; repeated to give a regression a real chance to bite.
    set stressOk 1
    for {set round 0} {$round < 5} {incr round} {
        set r [reqok load format lines path $fixture]
        set fp [dict get $r handle]
        set r [reqok run name nonempty \
            args [list [dict create handle $fp]] shards 4]
        if {[tcl::mathop::+ {*}[dict get $r value]] != 3} {
            set stressOk 0
        }
        reqok free handle $fp
    }
    check "five first-touch sharded runs over fresh pools stay consistent" \
        $stressOk

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

    # The three walls (PHM endurance spike, 2026-08-23), closed.
    # 1. Kernel table: the 257th distinct name evicts the least recently
    #    used kernel instead of refusing; the evicted name refuses cleanly
    #    on run and can be defined again.
    reqok def name oldest chunk {function oldest() return 1 end}
    for {set i 1} {$i <= 300} {incr i} {
        reqok def name "w$i" chunk "function w${i}() return $i end"
    }
    set r [req run name oldest]
    check "past 256 kernels the least recently used is evicted, not the engine" [expr {
        ![dict get $r ok] && [string match "*no kernel oldest*" [dict get $r error message]]}]
    check "the newest kernels survive eviction" \
        [expr {[dict get [reqok run name w300] value] == 300}]
    reqok def name oldest chunk {function oldest() return 2 end}
    check "an evicted kernel can be defined again" \
        [expr {[dict get [reqok run name oldest] value] == 2}]
    set st [reqok stats]
    check "stats gauges kernel occupancy and evictions" [expr {
        [dict get $st kernels] == [dict get $st kernel_slots] &&
        [dict get $st kernel_evictions] > 0}]
    # 2. View cache: at most two cached ranges per state per pool. Four
    #    shard variants on a 4-state engine would cache 10 views unbounded;
    #    bounded it is 2+2+2+1 = 7.
    set r [reqok load format lines path $fixture]
    set vpool [dict get $r handle]
    reqok def name vcount chunk {function vcount(h) return h.rows end}
    foreach n {1 2 3 4} {
        reqok run name vcount args [list [dict create handle $vpool]] shards $n
    }
    set st [reqok stats]
    check "the view cache is bounded per state (7 views, not 10)" [expr {
        [dict get $st views] == 7 && [dict get $st view_evictions] >= 2}]
    reqok free handle $vpool
    # 3. The cap stays the cap, but it is visible before it bites.
    check "stats exposes the state cap beside per-state use" [expr {
        [dict get $st cap_bytes] == 268435456 &&
        [llength [dict get $st mem_used]] == 4}]

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
