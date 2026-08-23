# col_bench.tcl -- the 0.13.0 bench lane (plan-machteld-013 section 3).
# NOT a gate: numbers, not verdicts on correctness. Speaks the wire
# directly for engine-side ms; every ratio is same-session, interleaved,
# warm; step-0 floors are measured before any grade. Prints the grades
# table the plan's Executed section records.

package require machteld 0.14.0

set exe [info nameofexecutable]

# ---------- fixtures (deterministic; hashes logged) ----------

set devdir [file join [file dirname [file dirname \
    [file normalize [info script]]]] .cache dev]
file mkdir $devdir
proc gen_csv {path rows} {
    if {[file exists $path]} { return }
    set f [open $path wb]
    puts $f "status,bytes,ratio,tijd"
    set s 20260822
    set statuses {200 200 200 404 500}
    for {set i 0} {$i < $rows} {incr i} {
        set s [expr {($s * 1103515245 + 12345) % 2147483648}]
        set st [lindex $statuses [expr {$s % 5}]]
        set by [expr {($s >> 3) % 100000}]
        set ra [format %d.%02d [expr {$s % 9}] [expr {$s % 100}]]
        set ti [expr {$s % 86400}]
        puts $f "$st,$by,$ra,$ti"
    }
    close $f
}
set big [file join $devdir col-bench-1m.csv]
set small [file join $devdir col-bench-64k.csv]
gen_csv $big 1000000
gen_csv $small 65536
puts "fixture 1M:  [file size $big] bytes  sha256 [string range [hash file sha256 $big] 0 15]..."
puts "fixture 64k: [file size $small] bytes  sha256 [string range [hash file sha256 $small] 0 15]..."

# ---------- wire ----------

proc sendraw {payload} {
    global W
    set b [encoding convertto utf-8 $payload]
    chan puts -nonewline $W [binary format i [string length $b]]
    chan puts -nonewline $W $b
    chan flush $W
}
proc recvf {} {
    global R
    set hdr [chan read $R 4]
    binary scan $hdr iu len
    return [json decode [encoding convertfrom utf-8 [chan read $R $len]]]
}
set SEQ 0
proc req {op args} {
    global SEQ
    sendraw [json encode -dict [dict create id [incr SEQ] op $op {*}$args]]
    set r [recvf]
    if {![dict get $r ok]} { error "engine refused $op: [dict get $r error]" }
    return $r
}
proc runk {name h} {
    return [req run name $name args [list [dict create handle $h]]]
}
proc median {xs} {
    set s [lsort -real $xs]
    return [lindex $s [expr {[llength $s] / 2}]]
}

scope {
    set C [child start -channels -- $exe --machteld-engine 12]
    set io [child info $C]
    set W [dict get $io stdin]
    set R [dict get $io stdout]
    chan configure $W -translation binary -buffering none
    chan configure $R -translation binary -blocking 1
    req hello protocol 1 host machteld version [version]

    set schema [list status i bytes i ratio f tijd i]
    set H [dict get [req load format csv path $big header 1 schema $schema] handle]
    set H64 [dict get [req load format csv path $small header 1 schema $schema] handle]

    # The pinned Lua baseline (plan section 3, P2) and the col kernels.
    req def name base404 chunk {function base404(h)
        local acc = 0
        local st, by = h.status, h.bytes
        for i = 1, h.rows do
            if st[i] == 404 then acc = acc + by[i] end
        end
        return acc
    end}
    req def name col404 chunk {function col404(h)
        return col.sum(h, "bytes", col.filter(h, "status", "eq", 404))
    end}
    req def name col404w chunk {function col404w(h)
        return col.sumwhere(h, "bytes", "status", "eq", 404)
    end}
    req def name s_sum chunk {function s_sum(h) return col._scalar.sum(h, "bytes") end}
    req def name a_sum chunk {function a_sum(h) return col._avx2.sum(h, "bytes") end}
    req def name s_flt chunk {function s_flt(h)
        return col.count(col._scalar.filter(h, "bytes", "lt", 50000))
    end}
    req def name a_flt chunk {function a_flt(h)
        return col.count(col._avx2.filter(h, "bytes", "lt", 50000))
    end}
    req def name s_feq chunk {function s_feq(h)
        return col.count(col._scalar.filter(h, "status", "eq", 404))
    end}
    req def name a_feq chunk {function a_feq(h)
        return col.count(col._avx2.filter(h, "status", "eq", 404))
    end}
    req def name bw chunk {function bw() return col._bw(256) end}
    req def name k42 chunk {function k42() return 42 end}

    # Warm-ups: view materialization charged here, per the plan's boundary.
    foreach k {base404 col404 col404w s_sum a_sum s_flt a_flt s_feq a_feq} {
        runk $k $H
        runk $k $H64
    }

    puts "\n== step 0: the floors =="
    # (a) noise band of the baseline, warm, median of 7.
    set xs {}
    for {set i 0} {$i < 7} {incr i} {
        lappend xs [dict get [runk base404 $H] ms]
    }
    set med [median $xs]
    set noise [expr {(([lindex [lsort -real $xs] end] -
                       [lindex [lsort -real $xs] 0]) / $med) * 100.0}]
    puts [format "0a  baseline warm median %.2f ms; run-to-run band %.0f%%" $med $noise]
    # (b) A/A ratio band: the baseline against itself, 7 interleaved pairs.
    set ratios {}
    for {set i 0} {$i < 7} {incr i} {
        set t1 [dict get [runk base404 $H] ms]
        set t2 [dict get [runk base404 $H] ms]
        lappend ratios [expr {$t1 / $t2}]
    }
    set aaLo [lindex [lsort -real $ratios] 0]
    set aaHi [lindex [lsort -real $ratios] end]
    set aaBand [expr {max($aaHi, 1.0 / $aaLo)}]
    puts [format "0b  A/A ratio band: %.2f .. %.2f  (bar floor %.2fx)" $aaLo $aaHi $aaBand]
    # (c) single-thread streaming bandwidth.
    set r [req run name bw args {}]
    set mbs [lindex [dict get $r value] 0]
    if {$mbs eq ""} { set mbs [dict get $r value] }
    set bwLimit [expr {8.0 / ($mbs / 1000.0)}]
    puts [format "0c  streaming bandwidth %.0f MB/s -> 8 MB limit %.2f ms" $mbs $bwLimit]
    # (d) verb-level no-op round trip, warm, median of 7 (through macht).
    macht def k42v {function k42v() return 42 end}
    macht run k42v
    set ws {}
    for {set i 0} {$i < 7} {incr i} {
        set t0 [clock microseconds]
        macht run k42v
        lappend ws [expr {([clock microseconds] - $t0) / 1000.0}]
    }
    puts [format "0d  verb no-op round-trip floor %.2f ms (median of 7)" [median $ws]]
    macht stop

    puts "\n== the grades =="
    # P1: col.sum vs the bandwidth limit.
    set xs {}
    for {set i 0} {$i < 7} {incr i} {
        lappend xs [dict get [runk s_sum $H] ms]
    }
    set p1 [median $xs]
    set p1v [expr {$p1 <= 2.0 * $bwLimit ? "HELD" :
                   ($p1 > 4.0 * $bwLimit ? "KILLED" : "MISSED")}]
    puts [format "P1  col.sum 1M i64: %.3f ms vs limit %.2f (<=%.2f held, >%.2f killed)  %s" \
        $p1 $bwLimit [expr {2 * $bwLimit}] [expr {4 * $bwLimit}] $p1v]
    # P2: the fused form vs the pinned Lua baseline, interleaved (the
    # graded form after the 2026-08-23 stop-and-decide); the composed
    # filter+sum ratio is reported beside it for the record.
    set rf {}
    set rc2 {}
    set basev ""
    set fusedv ""
    set compv ""
    for {set i 0} {$i < 7} {incr i} {
        set rb [runk base404 $H]
        set rw [runk col404w $H]
        set rcc [runk col404 $H]
        set basev [dict get $rb value]
        set fusedv [dict get $rw value]
        set compv [dict get $rcc value]
        lappend rf [expr {[dict get $rb ms] / [dict get $rw ms]}]
        lappend rc2 [expr {[dict get $rb ms] / [dict get $rcc ms]}]
    }
    set p2f [median $rf]
    set p2c [median $rc2]
    if {!($fusedv == $basev && $compv == $basev)} {
        puts "P2  VALUES DISAGREE: base $basev fused $fusedv composed $compv"
    }
    puts [format "P2  fused sumwhere vs Lua loop: %.1fx (>=10x)  %s" \
        $p2f [expr {$p2f >= 10.0 ? "HELD" : "MISSED"}]]
    puts [format "P2r composed filter+sum vs Lua loop: %.1fx (for the record)" $p2c]
    puts [format "P2r fused vs composed: %.1fx" [expr {$p2f / $p2c}]]
    # P3: hand AVX2 vs autovectorized scalar, per primitive, both sizes.
    foreach {label sk ak} {sum s_sum a_sum filter-lt s_flt a_flt filter-eq s_feq a_feq} {
        foreach {size hh} [list 1M $H 64k $H64] {
            set ratios {}
            for {set i 0} {$i < 7} {incr i} {
                set ts [dict get [runk $sk $hh] ms]
                set ta [dict get [runk $ak $hh] ms]
                lappend ratios [expr {$ts / $ta}]
            }
            set lo [lindex [lsort -real $ratios] 0]
            set med3 [median $ratios]
            set bar [expr {max(1.5, $aaBand)}]
            set verdict [expr {$lo > $bar ? "EARNS RESIDENCE" : "stays scalar"}]
            puts [format "P3  %-9s @%-3s avx2/scalar %.2fx (worst %.2fx, bar %.2fx)  %s" \
                $label $size $med3 $lo $bar $verdict]
        }
    }
    # P4: the honest sharding question. Headline: col single-thread vs the
    # 12-shard Lua path (needs >=1.5x to clear noise); engineering
    # comparison: col single vs col 8-shard, reported with guidance.
    req def name sum_of chunk {function sum_of(ps)
        local s = 0
        for i = 1, #ps do s = s + ps[i] end
        return s
    end}
    proc runsh {name h shards} {
        return [req run name $name args [list [dict create handle $h]] \
            shards $shards reduce sum_of]
    }
    runsh base404 $H 12
    runsh col404w $H 8
    set rSingle {}
    set rLua12 {}
    set rCol8 {}
    for {set i 0} {$i < 7} {incr i} {
        lappend rSingle [dict get [runk col404w $H] ms]
        lappend rLua12 [dict get [runsh base404 $H 12] ms]
        lappend rCol8 [dict get [runsh col404w $H 8] ms]
    }
    set p4s [median $rSingle]
    set p4l [median $rLua12]
    set p4c [median $rCol8]
    set head [expr {$p4l / $p4s}]
    puts [format "P4  col single %.2f ms | 12-shard Lua %.2f ms | col 8-shard %.2f ms" \
        $p4s $p4l $p4c]
    puts [format "P4  headline col-single vs 12-shard Lua: %.1fx (>=1.5x)  %s" \
        $head [expr {$head >= 1.5 ? "HELD" : "reported, no verdict"}]]
    puts [format "P4  guidance: col single vs col 8-shard: %.2fx %s" \
        [expr {$p4s / $p4c}] \
        [expr {$p4s <= $p4c ? "(sharding buys nothing here)" : "(sharding still pays)"}]]

    # P6a: the demo question (200k, demo-shaped fixture) via col,
    # engine-side, warm; P6b wall through the verb reported beside 0d.
    set demo [file join $devdir col-bench-200k.csv]
    if {![file exists $demo]} {
        set f [open $demo wb]
        puts $f "pad,status,bytes,tijd"
        set s 4711
        set paden {/api/users /api/orders /static/app.js /index.html /health}
        set statuses {200 200 200 404 500}
        for {set i 0} {$i < 200000} {incr i} {
            set s [expr {($s * 1103515245 + 12345) % 2147483648}]
            puts $f "[lindex $paden [expr {$s % 5}]],[lindex $statuses [expr {($s >> 2) % 5}]],[expr {($s >> 3) % 100000}],[expr {$s % 86400}]"
        }
        close $f
    }
    set HD [dict get [req load format csv path $demo header 1 \
        schema [list pad s status i bytes i tijd i]] handle]
    runk col404w $HD
    set xs {}
    for {set i 0} {$i < 7} {incr i} {
        lappend xs [dict get [runk col404w $HD] ms]
    }
    set p6a [median $xs]
    puts [format "P6a demo question via col, engine-side warm: %.3f ms (<0.5 held, >1.5 killed)  %s" \
        $p6a [expr {$p6a < 0.5 ? "HELD" : ($p6a > 1.5 ? "KILLED" : "MISSED")}]]
    macht def dem {function dem(h)
        return col.sumwhere(h, "bytes", "status", "eq", 404)
    end}
    set hd2 [macht load -csv $demo -header -schema {pad s status i bytes i tijd i}]
    macht run dem $hd2
    set ws {}
    for {set i 0} {$i < 7} {incr i} {
        set t0 [clock microseconds]
        macht run dem $hd2
        lappend ws [expr {([clock microseconds] - $t0) / 1000.0}]
    }
    puts [format "P6b demo question wall through the verb: %.2f ms (reported beside the 0d floor, not graded)" \
        [median $ws]]
    macht stop

    # P5 spot confirmation (full matrix lives in the gate lane).
    set ok [expr {
        [dict get [runk s_sum $H] value] == [dict get [runk a_sum $H] value] &&
        [dict get [runk s_flt $H] value] == [dict get [runk a_flt $H] value] &&
        [dict get [runk s_feq $H] value] == [dict get [runk a_feq $H] value]}]
    puts "P5  scalar/avx2 agree on 1M (sum, filter-lt, filter-eq): $ok"

    # ---------- the string grades (plan-machteld-014, S1-S4) ----------
    puts "\n== the string grades (0.14) =="
    set sbig [file join $devdir col-bench-1m-s.csv]
    if {![file exists $sbig]} {
        set f [open $sbig wb]
        puts $f "pad,status,bytes"
        set s 20260823
        set paden {/api/users /api/orders /static/app.js /index.html /health}
        set statuses {200 200 200 404 500}
        for {set i 0} {$i < 1000000} {incr i} {
            set s [expr {($s * 1103515245 + 12345) % 2147483648}]
            puts $f "[lindex $paden [expr {$s % 5}]],[lindex $statuses [expr {($s >> 2) % 5}]],[expr {($s >> 3) % 100000}]"
        }
        close $f
    }
    puts "fixture 1M-s: [file size $sbig] bytes  sha256 [string range [hash file sha256 $sbig] 0 15]..."
    set sschema [list pad s status i bytes i]

    # S1 toll: interleaved dictionary/span loads, wall ms, 7 pairs.
    set tolls {}
    set tds {}
    set tss {}
    for {set i 0} {$i < 7} {incr i} {
        set t0 [clock microseconds]
        set r [req load format csv path $sbig header 1 schema $sschema]
        set d [expr {([clock microseconds] - $t0) / 1000.0}]
        req free handle [dict get $r handle]
        set t0 [clock microseconds]
        set r [req load format csv path $sbig header 1 schema $sschema dict 0]
        set sp [expr {([clock microseconds] - $t0) / 1000.0}]
        req free handle [dict get $r handle]
        lappend tds $d
        lappend tss $sp
        lappend tolls [expr {$d / $sp}]
    }
    set s1 [median $tolls]
    set s1v [expr {$s1 <= 1.25 ? "HELD" : ($s1 > 1.5 ? "KILLED" : "MISSED")}]
    puts [format "S1  dictionary toll on the 1M load: %.2fx (dict %.0f ms, span %.0f ms; <=1.25x held, >1.5x killed)  %s" \
        $s1 [median $tds] [median $tss] $s1v]

    # S1m memory: a FRESH engine per mode (no heap history), three 1M
    # pools held, commit delta per pool. Codes cost 4 B/row where spans
    # cost 16; the dictionary pool must be smaller.
    proc commitkb {pid} {
        return [expr {[exec powershell.exe -NoProfile -Command \
            "(Get-Process -Id $pid).PrivateMemorySize64"] / 1024}]
    }
    proc memload {exe sbig sschema extra} {
        global W R
        set saveW $W
        set saveR $R
        set c [child start -channels -- $exe --machteld-engine 4]
        set io [child info $c]
        set W [dict get $io stdin]
        set R [dict get $io stdout]
        chan configure $W -translation binary -buffering none
        chan configure $R -translation binary -blocking 1
        req hello protocol 1 host machteld version [version]
        set pid [dict get $io pid]
        set c0 [commitkb $pid]
        for {set i 0} {$i < 3} {incr i} {
            req load format csv path $sbig header 1 schema $sschema {*}$extra
        }
        set c1 [commitkb $pid]
        req quit
        child wait $c
        child close $c
        set W $saveW
        set R $saveR
        return [expr {($c1 - $c0) / 3.0}]
    }
    set s1md [memload $exe $sbig $sschema {}]
    set s1ms [memload $exe $sbig $sschema {dict 0}]
    puts [format "S1m per-pool commit: dictionary %.1f MB vs span %.1f MB (smaller holds)  %s" \
        [expr {$s1md / 1024.0}] [expr {$s1ms / 1024.0}] \
        [expr {$s1md < $s1ms ? "HELD" : "MISSED"}]]

    # S2/S3: eq and match via col vs the pinned Lua loops, dictionary
    # pool graded, span pool reported for the record, interleaved.
    set SD [dict get [req load format csv path $sbig header 1 schema $sschema] handle]
    set SS [dict get [req load format csv path $sbig header 1 schema $sschema dict 0] handle]
    req def name base_seq chunk {function base_seq(h, x)
        local acc = 0
        local pad = h.pad
        for i = 1, h.rows do
            if pad[i] == x then acc = acc + 1 end
        end
        return acc
    end}
    req def name col_seq chunk {function col_seq(h, x)
        return col.count(col.filter(h, "pad", "eq", x))
    end}
    req def name base_match chunk {function base_match(h, pat)
        local lp = pat:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
        lp = "^" .. lp:gsub("%%%*", ".*") .. "$"
        local acc = 0
        local pad = h.pad
        local find = string.find
        for i = 1, h.rows do
            if find(pad[i], lp) then acc = acc + 1 end
        end
        return acc
    end}
    req def name col_match chunk {function col_match(h, pat)
        return col.count(col.filter(h, "pad", "match", pat))
    end}
    req def name base_sw chunk {function base_sw(h, pat)
        local lp = pat:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
        lp = "^" .. lp:gsub("%%%*", ".*") .. "$"
        local acc = 0
        local pad, by = h.pad, h.bytes
        local find = string.find
        for i = 1, h.rows do
            if find(pad[i], lp) then acc = acc + by[i] end
        end
        return acc
    end}
    req def name col_sw chunk {function col_sw(h, pat)
        return col.sumwhere(h, "bytes", "pad", "match", pat)
    end}
    proc runk2 {name h x} {
        return [req run name $name args [list [dict create handle $h] $x]]
    }
    foreach k {base_seq col_seq base_match col_match base_sw col_sw} {
        runk2 $k $SD /api/users
        runk2 $k $SS /api/users
    }
    set rd {}
    set rs {}
    set bv ""
    set cv ""
    set bmsq {}
    set cmsq {}
    for {set i 0} {$i < 7} {incr i} {
        set rb [runk2 base_seq $SD /api/users]
        set rc [runk2 col_seq $SD /api/users]
        set bv [dict get $rb value]
        set cv [dict get $rc value]
        lappend bmsq [dict get $rb ms]
        lappend cmsq [dict get $rc ms]
        lappend rd [expr {[dict get $rb ms] / [dict get $rc ms]}]
        set rb [runk2 base_seq $SS /api/users]
        set rc [runk2 col_seq $SS /api/users]
        lappend rs [expr {[dict get $rb ms] / [dict get $rc ms]}]
    }
    if {$bv != $cv} { puts "S2  VALUES DISAGREE: lua $bv col $cv" }
    set s2 [median $rd]
    puts [format "S2  eq via col vs the Lua loop (dictionary): %.1fx (lua %.1f ms, col %.3f ms; >=20x)  %s" \
        $s2 [median $bmsq] [median $cmsq] \
        [expr {$s2 >= 20.0 ? "HELD" : "MISSED"}]]
    puts [format "S2r span mode for the record: %.1fx" [median $rs]]
    set rd {}
    set rs {}
    set cms {}
    set bms {}
    for {set i 0} {$i < 7} {incr i} {
        set rb [runk2 base_match $SD /api/*]
        set rc [runk2 col_match $SD /api/*]
        set bv [dict get $rb value]
        set cv [dict get $rc value]
        lappend bms [dict get $rb ms]
        lappend cms [dict get $rc ms]
        lappend rd [expr {[dict get $rb ms] / [dict get $rc ms]}]
        set rb [runk2 base_match $SS /api/*]
        set rc [runk2 col_match $SS /api/*]
        lappend rs [expr {[dict get $rb ms] / [dict get $rc ms]}]
    }
    if {$bv != $cv} { puts "S3  VALUES DISAGREE: lua $bv col $cv" }
    set s3ms [median $cms]
    set s3x [median $rd]
    set s3v [expr {$s3ms <= 5.0 && $s3x >= 20.0 ? "HELD" : "MISSED"}]
    puts [format "S3  match via col (dictionary): %.3f ms engine-side (<=5) and %.1fx vs the Lua glob loop (>=20x)  %s" \
        $s3ms $s3x $s3v]
    puts [format "S3r Lua glob loop %.1f ms (the reken-lineage class); span mode %.1fx" \
        [median $bms] [median $rs]]

    # O1 (the follow-through): groupsum vs the pinned Lua group loop on
    # the 1M dictionary pool - exact agreement, >= 10x.
    req def name base_grp chunk {function base_grp(h)
        local pad, by = h.pad, h.bytes
        local sum = {}
        for i = 1, h.rows do
            local p = pad[i]
            sum[p] = (sum[p] or 0) + by[i]
        end
        local acc = 0
        for _, v in pairs(sum) do acc = acc + v end
        return acc
    end}
    req def name col_grp chunk {function col_grp(h)
        local g = col.groupsum(h, "bytes", "pad")
        local acc = 0
        for d = 1, #g.sums do acc = acc + g.sums[d] end
        return acc
    end}
    runk base_grp $SD
    runk col_grp $SD
    set rg {}
    set bv ""
    set cv ""
    for {set i 0} {$i < 7} {incr i} {
        set rb [runk base_grp $SD]
        set rc [runk col_grp $SD]
        set bv [dict get $rb value]
        set cv [dict get $rc value]
        lappend rg [expr {[dict get $rb ms] / [dict get $rc ms]}]
    }
    if {$bv != $cv} { puts "O1  VALUES DISAGREE: lua $bv col $cv" }
    set o1 [median $rg]
    puts [format "O1  groupsum vs the Lua group loop (dictionary, 1M): %.1fx (>=10x)  %s" \
        $o1 [expr {$o1 >= 10.0 ? "HELD" : "MISSED"}]]

    # S4 spot: dict, span, and the Lua twins agree on the 1M (the full
    # hostile differential lives in the gate lane's engine test).
    set ok [expr {
        [dict get [runk2 col_seq $SD /api/users] value] ==
            [dict get [runk2 col_seq $SS /api/users] value] &&
        [dict get [runk2 col_match $SD /api/*] value] ==
            [dict get [runk2 col_match $SS /api/*] value] &&
        [dict get [runk2 base_seq $SD /api/users] value] ==
            [dict get [runk2 col_seq $SD /api/users] value] &&
        [dict get [runk2 base_sw $SD /api/*] value] ==
            [dict get [runk2 col_sw $SD /api/*] value] &&
        [dict get [runk2 col_sw $SD /api/*] value] ==
            [dict get [runk2 col_sw $SS /api/*] value]}]
    puts "S4  dict/span/Lua agree on the 1M (eq, match, sumwhere): $ok"

    req quit
}
puts "\ncol bench complete."
