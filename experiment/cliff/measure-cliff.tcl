# measure-cliff.tcl -- the dictionary cardinality cliff, measured
# (plan-machteld-014, the follow-through: C1, C2, C3).
#
# The contracted limit stays 65,536; this instrument raises it through
# the UNCONTRACTED bench escape MACHTELD_DICT_LIMIT (the dict:0
# precedent) to see what a bigger dictionary would cost and buy at
# k in {100k, 250k, 1M} distinct values over 25M rows (the scale the cliff models - the panel killed the 5M fixture: at n/k=5 the match bar sat above the arithmetic ceiling). The output is a
# recommendation with numbers; the limit itself is the owner's ruling.
#
# usage: machteld measure-cliff.tcl

package require machteld 0.13.0

set exe [info nameofexecutable]
set devdir [file join [file dirname [file dirname [file dirname \
    [file normalize [info script]]]]] .cache dev]
file mkdir $devdir

# ------------- fixtures: 25M rows, exactly k distinct keys -------------
proc genfix {path k rows} {
    if {[file exists $path]} { return }
    set f [open $path wb]
    chan configure $f -buffersize 4194304
    puts $f "key,bytes"
    set buf ""
    set buflen 0
    set S 20260823
    for {set i 0} {$i < $rows} {incr i} {
        set S [expr {($S * 1103515245 + 12345) % 2147483648}]
        set line "[format w%07d [expr {$i % $k}]],[expr {$S % 100000}]\n"
        append buf $line
        incr buflen [string length $line]
        if {$buflen >= 2097152} {
            puts -nonewline $f $buf
            set buf ""
            set buflen 0
        }
    }
    puts -nonewline $f $buf
    close $f
}

# ---------------- wire ----------------
proc sendraw {p} {
    global W
    set b [encoding convertto utf-8 $p]
    chan puts -nonewline $W [binary format i [string length $b]]
    chan puts -nonewline $W $b
    chan flush $W
}
proc recvf {} {
    global R
    binary scan [chan read $R 4] iu len
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
proc median {xs} {
    set s [lsort -real $xs]
    return [lindex $s [expr {[llength $s] / 2}]]
}
proc commitkb {pid} {
    return [expr {[exec powershell.exe -NoProfile -Command \
        "(Get-Process -Id $pid).PrivateMemorySize64"] / 1024}]
}
proc engstart {} {
    global W R EPID ECHILD exe env
    set ECHILD [child start -channels -- $exe --machteld-engine 4]
    set io [child info $ECHILD]
    set W [dict get $io stdin]
    set R [dict get $io stdout]
    set EPID [dict get $io pid]
    chan configure $W -translation binary -buffering none
    chan configure $R -translation binary -blocking 1
    req hello protocol 1 host machteld version [version]
}
proc engstop {} {
    global ECHILD
    req quit
    child wait $ECHILD
    child close $ECHILD
}

# The bench escape: the spawned engines read this at dictionary build.
set env(MACHTELD_DICT_LIMIT) 1048576
set SCHEMA [list key s bytes i]

scope {
    # Default sweep: 25M rows. "-pair ROWS K" measures one extra point
    # (the n/k=8 boundary runs as -pair 8000000 1000000).
    set PAIRS {25000000 100000 25000000 250000 25000000 1000000}
    if {[lindex $argv 0] eq "-pair"} {
        set PAIRS [lrange $argv 1 2]
    }
    foreach {rows k} $PAIRS {
        set fix [file join $devdir "cliff[expr {$rows / 1000000}]-k$k.csv"]
        genfix $fix $k $rows
        puts [format "k=%-8d fixture %d bytes  sha256 %s..." $k \
            [file size $fix] [string range [hash file sha256 $fix] 0 15]]

        engstart
        # Toll: interleaved dict/span loads, 5 pairs.
        set td {}
        set ts {}
        for {set i 0} {$i < 5} {incr i} {
            set t0 [clock milliseconds]
            set r [req load format csv path $fix header 1 schema $SCHEMA]
            lappend td [expr {[clock milliseconds] - $t0}]
            req free handle [dict get $r handle]
            set t0 [clock milliseconds]
            set r [req load format csv path $fix header 1 schema $SCHEMA dict 0]
            lappend ts [expr {[clock milliseconds] - $t0}]
            req free handle [dict get $r handle]
        }
        set toll [expr {double([median $td]) / [median $ts]}]

        # The pools for the speed runs: one dict, one span, same engine.
        set r [req load format csv path $fix header 1 schema $SCHEMA]
        set HD [dict get $r handle]
        set s [req stats]
        set dcols [dict get [lindex [dict get $s pools] 0] dict_cols]
        set HS [dict get [req load format csv path $fix header 1 \
            schema $SCHEMA dict 0] handle]
        req def name f_eq chunk {function f_eq(h)
            return col.count(col.filter(h, "key", "eq", "w0000123"))
        end}
        req def name f_match chunk {function f_match(h)
            return col.count(col.filter(h, "key", "match", "w00001*"))
        end}
        foreach kn {f_eq f_match} {
            req run name $kn args [list [dict create handle $HD]]
            req run name $kn args [list [dict create handle $HS]]
        }
        set eqd {}
        set eqs {}
        set mad {}
        set mas {}
        set vd 0
        set vs 0
        for {set i 0} {$i < 7} {incr i} {
            lappend eqd [dict get [req run name f_eq \
                args [list [dict create handle $HD]]] ms]
            lappend eqs [dict get [req run name f_eq \
                args [list [dict create handle $HS]]] ms]
            set rd [req run name f_match args [list [dict create handle $HD]]]
            set rs [req run name f_match args [list [dict create handle $HS]]]
            set vd [dict get $rd value]
            set vs [dict get $rs value]
            lappend mad [dict get $rd ms]
            lappend mas [dict get $rs ms]
        }
        engstop

        # Memory: fresh engine per mode, one held pool, commit delta.
        engstart
        set c0 [commitkb $EPID]
        req load format csv path $fix header 1 schema $SCHEMA
        set memd [expr {([commitkb $EPID] - $c0) / 1024.0}]
        engstop
        engstart
        set c0 [commitkb $EPID]
        req load format csv path $fix header 1 schema $SCHEMA dict 0
        set mems [expr {([commitkb $EPID] - $c0) / 1024.0}]
        engstop

        if {$vd != $vs} { puts "  VALUES DISAGREE: dict $vd span $vs" }
        puts [format "  mode check: dict_cols=%d, dict_limit_override=%d (1 and 1048576 = the instrument held)" $dcols [dict get $s dict_limit_override]]
        puts [format "  toll dict/span:  %.2fx   (dict %d ms, span %d ms)" \
            $toll [median $td] [median $ts]]
        puts [format "  eq    dict %7.2f ms | span %7.2f ms | %5.1fx" \
            [median $eqd] [median $eqs] \
            [expr {[median $eqs] / [median $eqd]}]]
        puts [format "  match dict %7.2f ms | span %7.2f ms | %5.1fx  (%d rows hit)" \
            [median $mad] [median $mas] \
            [expr {[median $mas] / [median $mad]}] $vd]
        puts [format "  pool  dict %7.1f MB | span %7.1f MB  %s" \
            $memd $mems [expr {$memd < $mems ? "(dict smaller)" : "(SPAN SMALLER)"}]]
        set G($k) [list $toll [median $eqd] [median $mad] \
            [expr {[median $mas] / [median $mad]}] \
            [expr {[median $eqs] / [median $eqd]}] $memd $mems]
    }

    # ---------------- the grades ----------------
    if {[llength $PAIRS] == 2} {
        # A single -pair point: the C4 boundary grades (n/k = 8).
        foreach {rows k} $PAIRS {}
        set matchx [lindex $G($k) 3]
        set eqx [lindex $G($k) 4]
        set toll [lindex $G($k) 0]
        set memok [expr {[lindex $G($k) 5] < [lindex $G($k) 6]}]
        puts [format "\nC4a match dict/span at n/k=%d: %.1fx (>=2x)  %s" \
            [expr {$rows / $k}] $matchx \
            [expr {$matchx >= 2.0 ? "HELD" : "MISSED"}]]
        puts [format "C4b dict pool smaller: %s  %s   (eq ratio %.1fx beside it)" \
            [expr {$memok ? "yes" : "NO"}] \
            [expr {$memok ? "HELD" : "MISSED"}] $eqx]
        puts [format "C4c toll: %.2fx (<=1.5)  %s" $toll \
            [expr {$toll <= 1.5 ? "HELD" : "MISSED"}]]
    } else {
    set t1m [lindex $G(1000000) 0]
    set c1 [expr {$t1m <= 1.5 ? "HELD" : ($t1m > 2.0 ? "KILLED" : "MISSED")}]
    puts [format "\nC1 toll at k=1M: %.2fx (<=1.5 held, >2.0 killed)  %s" $t1m $c1]
    set ok2 1
    foreach k {100000 250000 1000000} {
        if {[lindex $G($k) 3] < 5.0} { set ok2 0 }
    }
    set eq1m [lindex $G(1000000) 1]
    set eqx1m [lindex $G(1000000) 4]
    set c2 [expr {$ok2 && $eq1m <= 15.0 && $eqx1m >= 3.0 ? "HELD" : "MISSED"}]
    puts [format "C2 match >=5x span at every k: %s; eq at k=1M %.2f ms (<=15) and %.1fx span (>=3)  %s" \
        [expr {$ok2 ? "yes" : "NO"}] $eq1m $eqx1m $c2]
    set ok3 1
    foreach k {100000 250000 1000000} {
        if {[lindex $G($k) 5] >= [lindex $G($k) 6]} { set ok3 0 }
    }
    puts [format "C3 dict pool smaller at every k: %s  %s" \
        [expr {$ok3 ? "yes" : "NO"}] [expr {$ok3 ? "HELD" : "MISSED"}]]
    }
}
unset env(MACHTELD_DICT_LIMIT)
puts "\ncliff measured."
