# measure.tcl -- the headless 5 GB session (plan-machteld-014: G2, G3, G6).
# Speaks the wire directly for engine-side ms; the GUI drive (G4/G5) is
# gui.tcl -drive. usage: machteld measure.tcl CSVPATH

package require machteld 0.13.0

set exe [info nameofexecutable]
set csv [lindex $argv 0]
if {$csv eq ""} { puts stderr "usage: measure.tcl CSVPATH"; exit 1 }

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
    return [recvf]
}
proc reqok {op args} {
    set r [req $op {*}$args]
    if {![dict get $r ok]} { error "engine refused $op: [dict get $r error]" }
    return $r
}
proc median {xs} {
    set s [lsort -real $xs]
    return [lindex $s [expr {[llength $s] / 2}]]
}
proc pmem {pid what} {
    return [exec powershell.exe -NoProfile -Command \
        "(Get-Process -Id $pid).$what"]
}

scope {
    set C [child start -channels -- $exe --machteld-engine 4]
    set io [child info $C]
    set W [dict get $io stdin]
    set R [dict get $io stdout]
    set epid [dict get $io pid]
    chan configure $W -translation binary -buffering none
    chan configure $R -translation binary -blocking 1
    reqok hello protocol 1 host machteld version [version]

    set fsz [file size $csv]
    puts [format "file: %lld bytes" $fsz]

    # ---- G2: the load ----
    set t0 [clock milliseconds]
    set r [reqok load format csv path $csv header 1 schema [list \
        tijd i ip s method s pad s query s status i bytes i dur i \
        verwijzer s agent s]]
    set wall [expr {([clock milliseconds] - $t0) / 1000.0}]
    set H [dict get $r handle]
    set rows [dict get $r rows]
    set commit [pmem $epid PrivateMemorySize64]
    set peakws [pmem $epid PeakWorkingSet64]
    set ws [pmem $epid WorkingSet64]
    set s [reqok stats]
    set pool [lindex [dict get $s pools] 0]
    set g2t [expr {$wall <= 120 ? "HELD" : ($wall > 240 ? "KILLED" : "MISSED")}]
    set ratio [expr {double($commit) / $fsz}]
    set g2m [expr {$ratio <= 2.6 ? "HELD" : "MISSED"}]
    puts [format "G2  load: %.1f s (<=120 held, >240 killed)  %s" $wall $g2t]
    puts [format "G2  rows %d; pool modes dict_cols %d span_cols %d (5/1 expected)" \
        $rows [dict get $pool dict_cols] [dict get $pool span_cols]]
    puts [format "G2  steady commit %.2f GB = %.2fx the file (<=2.6x)  %s" \
        [expr {$commit / 1073741824.0}] $ratio $g2m]
    puts [format "G2  peak working set %.2f GB; steady ws %.2f GB (reported, no bar)" \
        [expr {$peakws / 1073741824.0}] [expr {$ws / 1073741824.0}]]

    # ---- G3: the cap law on the real pool ----
    reqok def name touchq chunk {function touchq(h) return h.query[1] end}
    set r [req run name touchq args [list [dict create handle $H]]]
    set g3a [expr {![dict get $r ok] &&
        [dict get $r error code] eq "lua" &&
        [string match "*not enough memory*" [dict get $r error message]]}]
    puts [format "G3  touching a 25M column: %s" \
        [expr {$g3a ? "refused as MACHT lua not-enough-memory" :
                      "UNEXPECTED: [dict get $r ok] $r"}]]
    reqok def name gc chunk {function gc() collectgarbage("collect") return 0 end}
    reqok run name gc
    reqok def name vraag chunk {function vraag(h, veld, pat, first, count)
        local sel = col.filter(h, veld, "match", pat)
        return { n = col.count(sel), rows = col.rows(h, sel, first, count) }
    end}
    set r [reqok run name vraag args \
        [list [dict create handle $H] pad "/api/v1/users*" 1 50]]
    set v [dict get $r value]
    set g3b [expr {[dict get $v n] > 0 && [llength [dict get $v rows]] == 50}]
    puts [format "G3  col-only kernel on the same view: n=%d, 50 rows fetched, engine alive  %s" \
        [dict get $v n] [expr {$g3a && $g3b ? "HELD" : "MISSED"}]]

    # ---- G6: the fetch, timed alone ----
    reqok def name selprep chunk {function selprep(h)
        G_SEL = col.filter(h, "pad", "match", "/api/v1/users*")
        return col.count(G_SEL)
    end}
    set n [dict get [reqok run name selprep args [list [dict create handle $H]]] value]
    reqok def name fetch1 chunk {function fetch1(h)
        return #col.rows(h, G_SEL, 1, 50)
    end}
    reqok def name fetchdeep chunk {function fetchdeep(h, at)
        return #col.rows(h, G_SEL, at, 50)
    end}
    set deep [expr {$n - 49}]
    reqok run name fetch1 args [list [dict create handle $H]]
    reqok run name fetchdeep args [list [dict create handle $H] $deep]
    set m1 {}
    set m2 {}
    set mv {}
    for {set i 0} {$i < 7} {incr i} {
        lappend m1 [dict get [reqok run name fetch1 \
            args [list [dict create handle $H]]] ms]
        lappend m2 [dict get [reqok run name fetchdeep \
            args [list [dict create handle $H] $deep]] ms]
        lappend mv [dict get [reqok run name vraag args \
            [list [dict create handle $H] pad "/api/v1/users*" 1 50]] ms]
    }
    set g6 [expr {[median $m1] <= 10.0 && [median $m2] <= 10.0 ? "HELD" : "MISSED"}]
    puts [format "G6  fetch 50 of %d selected from %d rows: page-1 %.2f ms, deepest page %.2f ms (<=10)  %s" \
        $n $rows [median $m1] [median $m2] $g6]
    puts [format "G6r the whole keystroke kernel (filter+count+fetch) engine-side: %.1f ms median of 7" \
        [median $mv]]

    reqok quit
}
puts "measure complete."
