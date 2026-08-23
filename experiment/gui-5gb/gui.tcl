# gui.tcl -- the 5 GB filter GUI (plan-machteld-014, the GUI spike).
#
# One entry, one count label, one 50-row table over the full pool. Every
# keystroke re-filters ALL rows through one engine round trip - no
# debounce in the measured lane; the point is to measure what a
# keystroke costs, and debounce is a remedy to prescribe from evidence.
#
# The wire call blocks inside a Tk event handler, and macht's deadline
# reads vwait - a nested event loop. A second keystroke arriving during
# the wait would re-enter the handler; the spike serializes: one query
# in flight, the newest text queued behind it, intermediate states
# dropped (they were stale the moment the next key landed).
#
# usage:  machteld gui.tcl CSVPATH ?-drive?
#   -drive: no human - after load, the GUI types against itself
#           (12 keystrokes on the dictionary column, then the span
#           column), prints the per-keystroke numbers, and exits.

package require machteld 0.13.0
package require Tk

set csv [lindex $argv 0]
set drive [expr {[lindex $argv 1] eq "-drive"}]
if {$csv eq ""} { puts stderr "usage: gui.tcl CSVPATH ?-drive?"; exit 1 }

set FIELDS {tijd ip method pad query status bytes dur verwijzer agent}
set SCHEMA {tijd i ip s method s pad s query s status i bytes i dur i verwijzer s agent s}

# ---------------- the widgets ----------------
wm title . "machteld - 5 GB"
ttk::frame .top -padding 6
ttk::label .top.veldlab -text "column:"
ttk::combobox .top.veld -values {pad ip agent verwijzer method query} \
    -state readonly -width 10
.top.veld set pad
ttk::entry .top.filter -width 40
ttk::label .top.count -text "-"
pack .top.veldlab .top.veld .top.filter -side left -padx 4
pack .top.count -side left -padx 12
pack .top -fill x
ttk::treeview .t -columns $FIELDS -show headings -height 25
foreach f $FIELDS w {90 110 60 170 170 50 70 50 220 300} {
    .t heading $f -text $f
    .t column $f -width $w -stretch 0
}
pack .t -fill both -expand 1
ttk::label .status -text "loading $csv ..." -padding 4
pack .status -fill x
update

# ---------------- the load ----------------
set t0 [clock milliseconds]
macht def vraag {function vraag(h, veld, pat, first, count)
    local sel = col.filter(h, veld, "match", pat)
    return { n = col.count(sel), rows = col.rows(h, sel, first, count) }
end}
macht def alles {function alles(h, first, count)
    return { n = col.count(h), rows = col.rows(h, nil, first, count) }
end}
set H [macht load -csv $csv -header -schema $SCHEMA]
set loadms [expr {[clock milliseconds] - $t0}]
set stats [macht stats]
.status configure -text [format "loaded in %.1f s   %s" \
    [expr {$loadms / 1000.0}] $stats]
puts [format "load: %.1f s" [expr {$loadms / 1000.0}]]
puts "stats: $stats"
# The mode assertion (panel: a silent ip escape crossing must never
# masquerade as a fluency miss): 5 dictionary columns, 1 span column.
set pool [lindex [dict get $stats pools] 0]
if {[dict get $pool dict_cols] != 5 || [dict get $pool span_cols] != 1} {
    puts "MODE ASSERTION FAILED: [dict get $pool dict_cols] dict, [dict get $pool span_cols] span (5/1 expected)"
    exit 1
}
puts "modes: 5 dict, 1 span - asserted"

# ---------------- the query lane (serialized) ----------------
set busy 0
set pending ""
set have ""
# Per-query measurement: list of {wall run n} in ms.
set META {}

proc paintrows {rows} {
    .t delete [.t children {}]
    foreach r $rows {
        .t insert {} end -values $r
    }
}

proc runquery {} {
    global busy pending have META
    if {$busy} { return }
    set text [.top.filter get]
    set veld [.top.veld get]
    set want [list $veld $text]
    if {$want eq $have} { return }
    set busy 1
    set t0 [clock microseconds]
    if {$text eq ""} {
        set r [macht run alles $::H 1 50]
    } elseif {[catch {macht run vraag $::H $veld "*$text*" 1 50} r]} {
        # e.g. a typed ? or [ hits match's refusal: show it, keep living.
        .top.count configure -text $r
        set have $want
        set busy 0
        return
    }
    set trun [expr {([clock microseconds] - $t0) / 1000.0}]
    set have $want
    .top.count configure -text "[dict get $r n] rows"
    paintrows [dict get $r rows]
    update idletasks
    set twall [expr {([clock microseconds] - $t0) / 1000.0}]
    lappend META [list $twall $trun [dict get $r n]]
    set busy 0
    # The newest text may have moved on while we were on the wire.
    if {[.top.filter get] ne $text || [.top.veld get] ne $veld} {
        after idle runquery
    }
}

bind .top.filter <KeyRelease> { after idle runquery }
bind .top.veld <<ComboboxSelected>> {
    set have ""
    after idle runquery
}
runquery

# ---------------- the drive (-drive: the GUI proves itself) ----------------
proc median {xs} {
    set s [lsort -real $xs]
    return [lindex $s [expr {[llength $s] / 2}]]
}
proc drivecol {veld keys} {
    global META have
    .top.veld set $veld
    .top.filter delete 0 end
    set have ""
    set META {}
    focus -force .top.filter
    foreach ch [split $keys ""] {
        .top.filter insert end $ch
        # a keysym is required or the binding never fires; the binding
        # reads the entry, so which keysym does not matter
        event generate .top.filter <KeyRelease> -keysym a
        update
    }
    # every keystroke measured: {wall run n} per query actually run
    set walls {}
    set runs {}
    foreach m $META {
        lappend walls [lindex $m 0]
        lappend runs [lindex $m 1]
    }
    set worst [lindex [lsort -real $walls] end]
    puts [format "drive %-9s %2d keystrokes -> %2d queries: wall median %.1f ms worst %.1f ms; run median %.1f ms; final %s rows" \
        $veld [string length $keys] [llength $META] \
        [median $walls] $worst [median $runs] [lindex [lindex $META end] 2]]
    return [list [median $walls] $worst [median $runs]]
}

if {$drive} {
    update
    # G4: the dictionary column, 12 keystrokes of a real narrowing query.
    set g4 [drivecol pad "/api/v1/user"]
    # And a second dictionary lane for the record: agent narrowing.
    drivecol agent "Firefox/128"
    # G5: the span column, same drive shape, measured not graded.
    set g5 [drivecol query "s=00"]
    puts [format "G4 dictionary keystroke-to-repaint: median %.1f ms (<=150) worst %.1f ms (<=400)  %s" \
        [lindex $g4 0] [lindex $g4 1] \
        [expr {[lindex $g4 0] <= 150 && [lindex $g4 1] <= 400 ? "HELD" : "MISSED"}]]
    puts [format "G5 span column, same drive: median %.1f ms worst %.1f ms (measured, no bar)" \
        [lindex $g5 0] [lindex $g5 1]]
    # The BURST (panel: the serial drive cannot exercise the
    # serialization lane): inject characters WITHOUT pumping the queries
    # between them. Correctness bar: fewer queries than keystrokes
    # (coalescing), no error, and the final answer equals the final
    # text's serial answer.
    .top.veld set pad
    .top.filter delete 0 end
    set have ""
    set META {}
    focus -force .top.filter
    foreach ch [split "/api/v2/ord" ""] {
        .top.filter insert end $ch
        event generate .top.filter <KeyRelease> -keysym a
    }
    update
    # Drain any trailing coalesced query scheduled by the busy recheck -
    # bounded pumping (never `while after info`: Tk keeps recurring
    # timers of its own, e.g. the cursor blink).
    for {set i 0} {$i < 10} {incr i} {
        update
        after 20 {set ::_tick 1}
        vwait ::_tick
    }
    set burstq [llength $META]
    set burstn [lindex [lindex $META end] 2]
    .top.filter delete 0 end
    .top.filter insert end "/api/v2/ord"
    set have ""
    set META {}
    runquery
    set serialn [lindex [lindex $META end] 2]
    puts [format "G4b burst: 11 keystrokes -> %d query(ies), final %s rows == serial %s rows  %s" \
        $burstq $burstn $serialn \
        [expr {$burstq < 11 && $burstn == $serialn ? "HELD" : "MISSED"}]]
    exit 0
}
