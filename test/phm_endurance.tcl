# phm_endurance.tcl -- the PHM endurance spike (z/spike-phm-endurance.md).
# NOT a gate. Does a long-lived engine wear, and along which curves?
# Predictions E1-E7 were registered before this ran. Usage:
#   machteld.exe test/phm_endurance.tcl ?cycles?     (default 500)

package require machteld

set exe [info nameofexecutable]
set CYCLES [expr {[llength $argv] ? [lindex $argv 0] : 500}]

set devdir [file join [file dirname [file dirname \
    [file normalize [info script]]]] .cache dev]
file mkdir $devdir
proc gen_csv {path rows seed} {
    if {[file exists $path]} { return }
    set f [open $path wb]
    puts $f "status,bytes,ratio,tijd"
    set s $seed
    set statuses {200 200 200 404 500}
    for {set i 0} {$i < $rows} {incr i} {
        set s [expr {($s * 1103515245 + 12345) % 2147483648}]
        puts $f "[lindex $statuses [expr {$s % 5}]],[expr {($s >> 3) % 100000}],[format %d.%02d [expr {$s % 9}] [expr {$s % 100}]],[expr {$s % 86400}]"
    }
    close $f
}
set big   [file join $devdir col-bench-1m.csv]
set mid   [file join $devdir phm-200k.csv]
set small [file join $devdir col-bench-64k.csv]
gen_csv $big 1000000 20260822
gen_csv $mid 200000 8823
gen_csv $small 65536 20260822
set schema [list status i bytes i ratio f tijd i]

# ---------- wire (per engine: a dict of channels) ----------

proc eng_start {threads} {
    global exe
    set c [child start -channels -- $exe --machteld-engine $threads]
    set io [child info $c]
    set w [dict get $io stdin]
    set r [dict get $io stdout]
    chan configure $w -translation binary -buffering none
    chan configure $r -translation binary -blocking 1
    set e [dict create child $c w $w r $r pid [dict get $io pid] seq 0]
    ask e hello protocol 1 host machteld version [version]
    return $e
}
proc req {eVar op args} {
    upvar 1 $eVar e
    dict incr e seq
    set payload [json encode -dict [dict create id [dict get $e seq] op $op {*}$args]]
    set b [encoding convertto utf-8 $payload]
    set w [dict get $e w]
    chan puts -nonewline $w [binary format i [string length $b]]
    chan puts -nonewline $w $b
    chan flush $w
    set r [dict get $e r]
    binary scan [chan read $r 4] iu len
    set reply [json decode [encoding convertfrom utf-8 [chan read $r $len]]]
    return [list $e $reply]
}
# req is awkward through upvar in expressions; wrap:
proc ask {eVar op args} {
    upvar 1 $eVar e
    lassign [req e $op {*}$args] e reply
    return $reply
}
proc ok? {reply} { dict get $reply ok }
proc errmsg {reply} { dict get $reply error message }
proc spread {xs} {
    set s [lsort -real $xs]
    return [expr {100.0 * ([lindex $s end] - [lindex $s 0]) / [lindex $s [expr {[llength $s] / 2}]]}]
}
proc median {xs} {
    set s [lsort -real $xs]
    return [lindex $s [expr {[llength $s] / 2}]]
}
proc ws {pid} {
    set i [mtps info $pid]
    return [list [dict get $i mem] [dict get $i private]]
}
proc mem0 {eVar} {
    upvar 1 $eVar e
    # GC-normalized: mem_used counts garbage awaiting the collector, which
    # the pilot showed swings +-25 MB with GC phase. Collect first.
    ask e run name gc
    return [lindex [dict get [ask e stats] mem_used] 0]
}

set verdicts {}
proc grade {id measured registered held} {
    global verdicts
    lappend verdicts [list $id $measured $registered [expr {$held ? "HELD" : "REFUTED"}]]
}

scope {
    # ================= the deterministic walls: a fresh engine =================
    set A [eng_start 2]
    # E1: 257th distinct kernel name; redefinition consumes nothing.
    set failAt 0
    set e1msg "(none)"
    for {set i 1} {$i <= 300} {incr i} {
        set r [ask A def name "k$i" chunk "function k${i}() return $i end"]
        if {![ok? $r]} { set failAt $i; set e1msg [errmsg $r]; break }
    }
    # Closed 2026-08-23: the 257th name evicts the least recently used
    # kernel instead of refusing; k1 (never run) is the first to go.
    set evicted [expr {![ok? [ask A run name k1]]}]
    set newest [expr {[ok? [ask A run name k300]]}]
    set redefOk 1
    for {set i 1} {$i <= 50} {incr i} {
        if {![ok? [ask A def name k1 chunk "function k1() return [expr {$i * 2}] end"]]} {
            set redefOk 0
        }
    }
    grade E1 "300 distinct defs, failure at #$failAt; k1 evicted=$evicted, k300 live=$newest" \
        "wall CLOSED: never refuses, LRU evicts" \
        [expr {$failAt == 0 && $evicted && $newest && $redefOk}]
    puts "E1  300 distinct kernel names: failure at #$failAt ($e1msg); k1 evicted=$evicted, k300 live=$newest, redefinitions ok=$redefOk"
    ask A quit
    child close [dict get $A child]
    # E6: spilled results without free - on its OWN fresh engine (the
    # pilot showed a full kernel table blocks every later def, including
    # this one: the wall blast radius is the whole engine).
    set A [eng_start 2]
    ask A def name spill chunk {function spill() return string.rep("x", 1048577) end}
    set spillAt 0
    set e6msg ""
    for {set i 1} {$i <= 300} {incr i} {
        set r [ask A run name spill]
        if {![ok? $r]} { set spillAt $i; set e6msg [errmsg $r]; break }
    }
    grade E6 "fails at spill #$spillAt: [string range $e6msg 0 40]" "257, result table full" \
        [expr {$spillAt == 257 && [string match "*result table is full*" $e6msg]}]
    puts "E6  spilled results fail at #$spillAt: $e6msg"
    ask A quit
    child close [dict get $A child]

    # ================= the endurance cycles: a long-lived engine =================
    set E [eng_start 12]
    ask E def name fixed chunk {function fixed(h)
        local acc = 0
        local st, by = h.status, h.bytes
        for i = 1, h.rows do
            if st[i] == 404 then acc = acc + by[i] end
        end
        return acc
    end}
    ask E def name q chunk {function q(h)
        return col.sumwhere(h, "bytes", "status", "eq", 404)
    end}
    ask E def name gc chunk {function gc() collectgarbage("collect") return 0 end}
    ask E def name sum_of chunk {function sum_of(ps)
        local s = 0
        for i = 1, #ps do s = s + ps[i] end
        return s
    end}
    # The persistent pool for E7 (never freed).
    set P [dict get [ask E load format csv path $small header 1 schema $schema] handle]
    ask E run name fixed args [list [dict create handle $P]]

    proc refop {eVar path} {
        upvar 1 $eVar e
        global schema
        set t0 [clock microseconds]
        set h [dict get [ask e load format csv path $path header 1 schema $schema] handle]
        set loadMs [expr {([clock microseconds] - $t0) / 1000.0}]
        set r [ask e run name q args [list [dict create handle $h]]]
        set runMs [dict get $r ms]
        ask e free handle $h
        return [list $loadMs $runMs]
    }
    proc fixedop {eVar P} {
        upvar 1 $eVar e
        return [dict get [ask e run name fixed args [list [dict create handle $P]]] ms]
    }

    puts "\n== endurance: $CYCLES cycles (alternating 200k / 64k) =="
    set series {}
    set base {}
    for {set c 1} {$c <= $CYCLES} {incr c} {
        set path [expr {$c % 2 ? $mid : $small}]
        refop E $path
        if {$c == 10} {
            set refs {}
            set fixeds {}
            for {set i 0} {$i < 9} {incr i} {
                lappend refs [lindex [refop E $mid] 0]
                lappend fixeds [fixedop E $P]
            }
            set base [dict create ref [median $refs] fixed [median $fixeds] \
                refSpread [spread $refs] fixedSpread [spread $fixeds] \
                mem0 [mem0 E] ws [ws [dict get $E pid]]]
            puts [format "  cycle %4d  baseline: ref-op %.1f ms, fixed-kernel %.2f ms, mem0 %d, ws %s" \
                $c [dict get $base ref] [dict get $base fixed] [dict get $base mem0] [dict get $base ws]]
        }
        if {$c % 50 == 0 || $c == $CYCLES} {
            set m0 [mem0 E]
            set w [ws [dict get $E pid]]
            lappend series [list $c $m0 $w]
            puts [format "  cycle %4d  mem0 %d  ws %s" $c $m0 $w]
        }
    }
    set refs {}
    set fixeds {}
    for {set i 0} {$i < 9} {incr i} {
        lappend refs [lindex [refop E $mid] 0]
        lappend fixeds [fixedop E $P]
    }
    set endRef [median $refs]
    set endFixed [median $fixeds]
    set endMem0 [mem0 E]
    set endWs [ws [dict get $E pid]]

    # E2: Lua-level memory returns to baseline.
    set memDrift [expr {100.0 * ($endMem0 - [dict get $base mem0]) / [dict get $base mem0]}]
    grade E2 [format "mem0 drift %+.1f%%" $memDrift] "within 5%" [expr {abs($memDrift) <= 5.0}]
    # E3: working-set creep (private bytes, the honest fragmentation signal).
    set wsBase [lindex [dict get $base ws] 1]
    set wsEnd [lindex $endWs 1]
    set wsGrowth [expr {100.0 * ($wsEnd - $wsBase) / $wsBase}]
    grade E3 [format "private bytes %+.1f%% (%d -> %d)" $wsGrowth $wsBase $wsEnd] ">10% (wear real; <3% refutes)" \
        [expr {$wsGrowth > 10.0}]
    # E4: reference-op latency drift.
    set refDrift [expr {100.0 * ($endRef - [dict get $base ref]) / [dict get $base ref]}]
    set refNoise [expr {max([dict get $base refSpread], [spread $refs])}]
    grade E4 [format "ref-op %+.1f%% (%.1f -> %.1f ms; spread %.0f%%)" \
        $refDrift [dict get $base ref] $endRef $refNoise] \
        ">5% slower (wear real; <2% refutes)" [expr {$refDrift > 5.0}]
    if {abs($refDrift) < $refNoise} {
        puts "E4  NOTE: the drift sits inside the sample spread - suggestive, not evidence"
    }
    # E7: fixed kernel on the persistent pool.
    set fixDrift [expr {100.0 * ($endFixed - [dict get $base fixed]) / [dict get $base fixed]}]
    set fixNoise [expr {max([dict get $base fixedSpread], [spread $fixeds])}]
    grade E7 [format "fixed-kernel %+.1f%% (%.2f -> %.2f ms; spread %.0f%%)" \
        $fixDrift [dict get $base fixed] $endFixed $fixNoise] \
        "within 10% (no GC drift)" [expr {abs($fixDrift) <= 10.0}]
    if {abs($fixDrift) < $fixNoise} {
        puts "E7  NOTE: the drift sits inside the sample spread"
    }

    # E5: the view cache on a persistent pool under shards 1..12.
    puts "\n== view cache: shards 1..12 on one 1M pool =="
    set H [dict get [ask E load format csv path $big header 1 schema $schema] handle]
    ask E run name q args [list [dict create handle $H]] shards 1 reduce sum_of
    set v1 [mem0 E]
    set e5msg ""
    set reached 1
    for {set n 2} {$n <= 12} {incr n} {
        set r [ask E run name q args [list [dict create handle $H]] shards $n reduce sum_of]
        if {![ok? $r]} { set e5msg "shards $n: [errmsg $r]"; break }
        set reached $n
    }
    set v12 [mem0 E]
    puts [format "  state-0 mem after shards 1: %d; after shards up to %d: %d (%.1fx) %s" \
        $v1 $reached $v12 [expr {double($v12) / $v1}] $e5msg]
    grade E5 [format "%.1fx (reached shards %d) %s" [expr {double($v12) / $v1}] $reached $e5msg] \
        "wall CLOSED: bounded cache, < 2x" [expr {double($v12) / $v1 < 2.0}]
    ask E free handle $H
    ask E quit
    child close [dict get $E child]
}

puts "\n== grades (registered in z/spike-phm-endurance.md before the run) =="
foreach v $verdicts {
    lassign $v id measured registered verdict
    puts [format "  %-3s %-52s registered %-36s %s" $id $measured $registered $verdict]
}
