package require machteld 30-
if {$argv ne {--isolated}} {
    set script [file normalize [info script]]
    set work [file tempdir]
    try {
        set exe [file join $work machteld.exe]
        file copy [info nameofexecutable] $exe
        set result [::machteld::run -timeout 2m -dir $work \
            -env [list PATH [file nativename [file join $::env(SystemRoot) System32]] GVBINDIR [file join $work absent]] \
            -- $exe $script --isolated]
        if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
            error "standalone Graphviz failed: [encoding convertfrom utf-8 [dict get $result err]]"
        }
        puts -nonewline [encoding convertfrom utf-8 [dict get $result out]]
    } finally {
        file delete -force $work
    }
    return
}
# Real DOT geometry. These fixtures first distinguished the engine profiles in
# the Windows size prototype. Keep edge routes and HTML dimensions measurable.
proc diamond {routing card} {
    set source [format {digraph {
        graph [rankdir=LR,nodesep=1.5,ranksep=1.0,splines=%s];
        node [%s];
        a -> b [id=ab]; a -> c [id=ac]; b -> d [id=bd]; c -> d [id=cd];
    }} $routing $card]
    set geometry [::machteld::graphviz layout $source]
    if {[lsort [dict keys [dict get $geometry nodes]]] ne {a b c d}} { error "diamond nodes" }
    return $geometry
}

# Graphviz represents a connected series of cubics as 3n+1 points. A cubic
# is axis-aligned only if all four points lie on the same horizontal or vertical.
proc routeCounts {geometry} {
    set ids {}
    set diagonal 0
    set bends 0
    foreach edge [dict get $geometry edges] {
        lappend ids [dict get $edge id]
        set pieces [dict get $edge splines]
        if {![llength $pieces]} { error "missing route" }
        foreach piece $pieces {
            set points [dict get $piece points]
            set n [llength $points]
            if {$n < 4 || ($n - 1) % 3} { error "incomplete cubic" }
            set previous ""
            for {set i 0} {$i < $n - 1} {incr i 3} {
                lassign [lindex $points $i] x0 y0
                set width 0
                set height 0
                foreach point [lrange $points $i [expr {$i+3}]] {
                    lassign $point x y
                    set width [expr {max($width, abs($x - $x0))}]
                    set height [expr {max($height, abs($y - $y0))}]
                }
                if {$width < 0.001 && $height < 0.001} { continue }
                if {$width < 0.001} {
                    set axis V
                } elseif {$height < 0.001} {
                    set axis H
                } else {
                    incr diagonal
                    set axis D
                }
                if {$axis in {V H} && $previous in {V H} && $previous ne $axis} { incr bends }
                set previous $axis
            }
        }
    }
    if {[lsort $ids] ne {ab ac bd cd}} { error "diamond routes" }
    return [list $diagonal $bends]
}

proc htmlCard {width height} {
    return [format {shape=plain,label=<<TABLE BORDER="0" CELLBORDER="0" CELLSPACING="0" CELLPADDING="0"><TR><TD WIDTH="%d" HEIGHT="%d">X</TD></TR></TABLE>>} $width $height]
}

proc tableSize {w h} {
    set geometry [::machteld::graphviz layout [format {digraph { a [%s] }} [htmlCard $w $h]]]
    return [dict get $geometry nodes a size]
}

# Keep the targets and ranks identical, changing only which table cell the
# single edge leaves. Measure its clipped start relative to the table center.
proc portOffset {port {routing spline}} {
    set source [format {digraph {
        graph [splines=%s];
        a [shape=plain,label=<<TABLE BORDER="0" CELLBORDER="0" CELLSPACING="0" CELLPADDING="0"><TR><TD PORT="left" WIDTH="80" HEIGHT="30">L</TD><TD PORT="right" WIDTH="80" HEIGHT="30">R</TD></TR></TABLE>>];
        b [shape=box,label="",width=0.3,height=0.3];
        a:%s:s -> b;
    }} $routing $port]
    set g [::machteld::graphviz layout $source]
    lassign [dict get $g nodes a center] centerX
    set edge [lindex [dict get $g edges] 0]
    set piece [lindex [dict get $edge splines] 0]
    lassign [lindex [dict get $piece points] 0] startX
    return [expr {$startX - $centerX}]
}

lassign [routeCounts [diamond ortho {shape=box,fixedsize=true,label="",width=1.25,height=0.5}]] diagonal bends
if {$diagonal || $bends < 2} { error "expected right-angle routes, got $diagonal diagonal segments and $bends bends" }
lassign [tableSize 52 26] baseW baseH
lassign [tableSize 180 26] wideW wideH
lassign [tableSize 52 98] tallW tallH
if {abs($wideW - $baseW - 128) > 1 || abs($tallH - $baseH - 72) > 1 ||
    abs($wideH - $baseH) > 1 || abs($tallW - $baseW) > 1} { error "incorrect table dimensions" }
if {abs([portOffset left] + 40) > 2 || abs([portOffset right] - 40) > 2} { error "named cell ports lost" }
set table {digraph {
    a [shape=plain,label=<<TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0">
        <TR><TD BGCOLOR="#ffdd88">Alpha</TD><TD>café 雪</TD></TR></TABLE>>]
    a -> a [id=loop]; a -> b [id=first]; a -> b [id=second]
}}
for {set i 0} {$i < 8} {incr i} {
    set g [::machteld::graphviz layout $table]
    set xdot [::machteld::graphviz xdot $table]
    set labels [dict get $g nodes a labelDraw]
    if {[lsort [lmap e [dict get $g edges] {dict get $e id}]] ne {first loop second} ||
        [regexp -all {\m[Pp]\s+4\s} $labels] < 3 || [string first "#ffdd88" $labels] < 0 ||
        [string first "café 雪" $labels] < 0 || [string first "_ldraw_" $xdot] < 0} { error "invalid drawing" }
    foreach {input code} [list {not a DOT graph} input "digraph {a}\0trailing" input] {
        if {![catch {::machteld::graphviz layout $input} msg opt] ||
            [dict get $opt -errorcode] ne [list MACHTELD GRAPHVIZ $code]} { error "invalid input accepted" }
    }
}
if {![catch {::machteld::graphviz exec $table} msg opts] ||
        [dict get $opts -errorcode] ne {MACHTELD GRAPHVIZ usage}} { error "unexpected operation accepted" }
puts "Graphviz geometry, right-angle routes, named ports, drawing, Unicode and error recovery passed"
