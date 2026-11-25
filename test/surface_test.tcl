# Actual back-buffer samples, including after resize/device recreation. This
# lane needs a Windows desktop. Hardware and WARP are distinguished in stdout.
package require machteld 30-
package require Tk
set checks 0
proc check {expression message} {
    if {![uplevel 1 [list expr $expression]]} {error $message}
    incr ::checks
}
proc sampleDips {s points} {
    set props [$s info]
    set factor [expr {[dict get $props dpi] * [dict get $props scale] / 96.0}]
    set pixels {}
    foreach pt $points {
        lassign $pt x y
        lappend pixels [list [expr {int($x*$factor)}] [expr {int($y*$factor)}]]
    }
    $s pixels $pixels
}
proc clockScene {spriteX} {
    set ops [list {ellipse 44 44 36 36 #ffeeaa}]
    for {set i 0} {$i < 12} {incr i} {
        set theta [expr {$i*acos(-1)/6}]
        set x [expr {sin($theta)}]
        set y [expr {cos($theta)}]
        lappend ops [list line [expr {44+30*$x}] [expr {44+30*$y}] \
                              [expr {44+34*$x}] [expr {44+34*$y}] 2 #403020]
    }
    lappend ops {line 44 44 44 20 4 #204060} [list sprite token $spriteX 8 12 12]
    return $ops
}
proc test2d {driver pace} {
    set s [::machteld::surface d2d .drawing -width 256 -height 224 -driver $driver]
    pack $s
    update
    $s image token 2 2 [binary decode hex [string repeat 22cc44ff 4]]
    $s draw #102030 [clockScene 96]
    set info [$s info]
    puts "Direct2D $info"
    check {[dict get $info backend] eq "d2d" && [dict get $info driver] in {hardware warp}} "missing device"
    if {$driver ne "auto"} {check {[dict get $info driver] eq $driver} "incorrect forced driver"}
    check {[dict get $info adapter] ne "" &&
        ($driver ne "warp" || [dict get $info software])} "missing or inconsistent DXGI adapter details"
    check {[sampleDips $s {{2 2} {30 44} {44 30} {100 12}}] eq
        {{#102030ff} #ffeeaaff #204060ff #22cc44ff}} "clock, background, hand and sprite pixels"
    $s draw #102030 [clockScene 110]
    check {[sampleDips $s {{100 12} {114 12}}] eq {{#102030ff} #22cc44ff}} "sprite did not move"
    check {[catch {$s draw #eeeeee {{sprite missing 0 0 4 4}}} msg opts] &&
        [dict get $opts -errorcode] eq {MACHTELD SURFACE format}} "missing image accepted"
    check {[sampleDips $s {{114 12}}] eq {{#22cc44ff}}} "invalid drawing replaced the last scene"
    $s image token 1 1 [binary decode hex 0066ffff]
    check {[sampleDips $s {{114 12}}] eq {{#0066ffff}}} "replaced bitmap kept stale pixels"
    set initialGeneration [dict get $info generation]
    $s configure -width 384 -height 288 -scale 1.25
    update
    set info [$s info]
    check {[dict get $info width] == 384 && [dict get $info height] == 288 && [dict get $info scale] == 1.25} "resize and scale"
    check {[sampleDips $s {{114 12} {44 30}}] eq {{#0066ffff} #204060ff}} "scaled sprite and clock hand"
    check {[dict get $info generation] == $initialGeneration} "resize unnecessarily discarded device"
    $s recreate
    check {[dict get [$s info] generation] > $initialGeneration &&
        [sampleDips $s {{114 12} {44 30}}] eq {{#0066ffff} #204060ff}} "device recovery lost sprite or scene"
    $s draw #000000 {{rect 4 4 12 12 #ffffff80}}
    set blended [lindex [sampleDips $s {{6 6}}] 0]
    check {$blended in {{#808080ff} #7f7f7fff}} "unexpected alpha composition $blended"
    check {[catch {$s pixels {{-1 0}}} m o] && [dict get $o -errorcode] eq {MACHTELD SURFACE size}} "out-of-bounds sample"
    set ::clicked {}
    bind $s <ButtonPress-1> {set ::clicked [list %x %y]}
    if {$pace} {
        bind $s <ButtonPress-1> {set ::clicked [list %x %y]; set ::inputLag [expr {[clock clicks -microseconds]-$::queued}]}
        measurePacing $s
    } else {
        event generate $s <ButtonPress-1> -x 14 -y 20 -when tail
    }
    update
    check {$::clicked eq {14 20}} "Tk input binding did not run during drawing"
    destroy $s
    update
    check {![llength [info commands $s]]} "destroy did not release widget command"
    return [dict get $info driver]
}

proc paceFrame {s} {
    set now [clock clicks -microseconds]
    lappend ::times $now
    set i [llength $::times]
    if {$i == 60} {
        set ::queued $now
        event generate $s <ButtonPress-1> -x 14 -y 20 -when tail
    }
    $s draw #102030 [clockScene [expr {94 + $i % 24}]]
    lappend ::drawTimes [expr {([clock clicks -microseconds] - $now)/1000.0}]
    if {$i >= 121} {set ::paced done; return}
    # Use absolute deadlines, dropping a missed interval when the event loop
    # falls behind. Drawing does not pump messages or own an animation thread.
    set elapsed [expr {[clock clicks -microseconds] - $::origin}]
    set next [expr {max($::slot+1, int(floor($elapsed*60.0/1000000))+1)}]
    set ::slot $next
    set wait [expr {max(1, round(($next*1000000.0/60 - $elapsed)/1000))}]
    set ::paceTimer [after $wait [list safeFrame $s]]
}
proc safeFrame {s} {
    if {[catch {paceFrame $s} message]} {set ::paced $message}
}
proc measurePacing {s} {
    set ::times {}; set ::drawTimes {}; set ::slot 0; set ::paced {}; set ::paceTimer {}
    set ::origin [clock clicks -microseconds]
    set timeout [after 20000 {set ::paced timeout}]
    set first [after 0 [list safeFrame $s]]
    try {vwait ::paced} finally {after cancel $first; after cancel $timeout; after cancel $::paceTimer}
    check {$::paced eq "done"} "frame loop: $::paced"
    check {[info exists ::inputLag] && $::inputLag < 1000000} "input delivery stalled while rendering"
    set deltas {}
    foreach prev [lrange $::times 0 end-1] next [lrange $::times 1 end] {
        lappend deltas [expr {($next-$prev)/1000.0}]
    }
    set sorted [lsort -real $deltas]
    set hz [expr {120000000.0 / ([lindex $::times end] - [lindex $::times 0])}]
    puts [format "Direct2D 60 Hz target: actual %.2f Hz over 120 intervals, median %.2f ms, p95 %.2f ms, max %.2f ms" \
        $hz [lindex $sorted 59] [lindex $sorted 113] [lindex $sorted end]]
    set render [lsort -real $::drawTimes]
    puts [format "Direct2D draw+present median %.2f ms, p95 %.2f ms, max %.2f ms; queued Tk input %.2f ms" \
        [lindex $render 60] [lindex $render 114] [lindex $render end] [expr {$::inputLag/1000.0}]]
}

proc triangle {angle} {
    set vertices {}
    for {set i 0} {$i < 3} {incr i} {
        set a [expr {$angle + $i * 2 * acos(-1) / 3}]
        lappend vertices [list [expr {.78*sin($a)}] [expr {.78*cos($a)}] 0 #ff0000]
    }
    return $vertices
}
proc test3d {driver} {
    set s [::machteld::surface d3d .three -width 200 -height 200 -driver $driver]
    pack $s
    update
    $s shader {
        struct V {float4 pos : SV_POSITION; float4 c : COLOR;};
        V main(float3 pos : POSITION, float4 c : COLOR) {
            V v; v.pos=float4(pos,1); v.c=c; return v;
        }
    } {
        float4 main(float4 pos : SV_POSITION, float4 c : COLOR) : SV_TARGET {return c.bgra;}
    }
    $s draw #102030 [triangle 0]
    set info [$s info]
    puts "Direct3D $info"
    check {[dict get $info driver] eq $driver && [dict get $info backend] eq "d3d"} "incorrect D3D device"
    check {[$s pixels {{0 0} {100 100} {100 42}}] eq {{#102030ff} #0000ffff #0000ffff}} "triangle shader or clear color"
    $s draw #102030 [triangle [expr {acos(-1)/3}]]
    check {[$s pixels {{0 0} {100 100} {100 42}}] eq {{#102030ff} #0000ffff #102030ff}} "rotation did not change coverage"
    check {[catch {$s shader broken broken} msg opts] && [dict get $opts -errorcode] eq {MACHTELD SURFACE shader}} "invalid shader accepted"
    check {[$s pixels {{100 100}}] eq {{#0000ffff}}} "invalid shader replaced last program"
    $s configure -width 320 -height 240
    update
    check {[dict get [$s info] width] == 320 && [dict get [$s info] height] == 240} "D3D viewport resize"
    check {[$s pixels {{0 0} {160 120}}] eq {{#102030ff} #0000ffff}} "pixels after resize"
    $s recreate
    check {[dict get [$s info] generation] > [dict get $info generation] &&
        [$s pixels {{0 0} {160 120}}] eq {{#102030ff} #0000ffff}} "recreated shader and scene"
    rename $s {}
    update
    check {![winfo exists $s]} "deleting command retained the window"
}

proc lifecycle {driver} {
    # A Tk exposure, shader change or bitmap upload may have armed an idle
    # repaint just before a dialog/application closes.
    for {set i 0} {$i < 12} {incr i} {
        set s [::machteld::surface d2d .closing -driver $driver]
        pack $s
        $s image marker 1 1 [binary decode hex 112233ff]
        if {$i % 2} {rename $s {}} else {destroy $s}
        update
        check {![winfo exists $s] && ![llength [info commands $s]]} "stale idle callback after destruction"
    }
    set s [::machteld::surface d2d .closing -driver $driver]
    pack $s
    update
    $s draw #123456 {}
    foreach {script code} {
        {$s draw #fff {}} format
        {$s draw #abcdef {{rect Inf 0 2 2 #000000}}} format
        {$s draw #abcdef {{ellipse 1 1 -2 3 #000000}}} format
        {$s image marker 2 2 [binary format x15]} format
        {$s image marker 4097 1 {}} size
        {$s configure -height 0} size
        {$s configure -scale NaN} size
        {$s pixels {{0 0} {99999 0}}} size
    } {
        check {[catch $script m o] && [dict get $o -errorcode] eq [list MACHTELD SURFACE $code]} "unexpected result for $script"
    }
    check {[$s pixels {{0 0}}] eq {{#123456ff}}} "failed validation mutated the scene"
    pack forget $s
    update
    pack $s
    update
    check {[$s pixels {{0 0}}] eq {{#123456ff}}} "map/unmap lost the scene"
    destroy $s
}

try {
    set auto [test2d auto 1]
    test3d $auto
    if {$auto ne "warp"} {test2d warp 0; test3d warp}
    lifecycle $auto
    puts "surface tests: $checks passed"
} finally {
    destroy .
}
