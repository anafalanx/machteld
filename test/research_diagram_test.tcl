package require machteld 30-

namespace eval ::researchTest {
    variable checks 0
    variable items {}
    variable current {}
}
proc ::researchTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

# Record Tk canvas operations so the real redraw and selection handlers can
# run on the packaging gate without loading Tk or touching the desktop.
proc ::researchTest::canvas {action args} {
    variable items
    variable current
    switch -- $action {
        create {
            set tags [lindex $args [expr {[lsearch -exact $args -tags]+1}]]
            set text {}
            if {[lindex $args 0] eq "text"} {set text [lindex $args [expr {[lsearch -exact $args -text]+1}]]}
            lappend items [list [lindex $args 0] $tags $text]
        }
        delete {
            set tag [lindex $args 0]
            set items [lmap item $items {
                if {$tag eq "all" || $tag in [lindex $item 1]} continue
                set item
            }]
        }
        bbox {
            foreach item $items {if {$args in [lindex $item 1]} {return {0 0 20 15}}}
            return {}
        }
        gettags {return $current}
        configure {return}
        default {error "unhandled canvas command: $action"}
    }
}
proc ::researchTest::labels {tag} {
    variable items
    lmap item $items {
        if {[lindex $item 0] ne "text" || $tag ni [lindex $item 1]} continue
        lindex $item 2
    }
}
proc ::researchTest::edit {db time} {
    set ::research::input $time
    ::research::apply $db ::researchTest::canvas
}
proc ::researchTest::controller {db} {
    variable items
    variable current
    proc ::diagram::font {args} {
        if {[lindex $args 0] ne "metrics" || [lindex $args end] ne "-descent"} {error "unexpected font query"}
        return 3
    }
    edit $db 2026-11-01T10:15:00+01:00
    set state [::research::report]
    equal [dict get $state at] 2026-11-01T09:15:00.000000000Z "offset resolves before SQL"
    equal [dict get $state visible] {007-A 007-B} "both observations overlap the research instant"
    set tag node:[::research::nodeId occurrence 007-B]
    equal [labels $tag] {{Bay 07} Open} "real xdot HTML-table text"
    equal [labels node:[::research::nodeId occurrence 007-A]] [labels $tag] "same label on two occurrences"
    equal [llength [dict get $::research::snapshot graph edges]] 2 "one source edge per observation"
    set current [list node $tag]
    ::research::click ::researchTest::canvas
    equal [dict get [::research::report] selected] 007-B "click identifies the occurrence"
    equal [dict get [::research::report] observation reference] {Card 12} "selection shows original source"
    equal [lindex $items end] {rectangle selection {}} "selection drawn above the graph"
    sqlite3 updateSample $db -create 0
    try {
        updateSample eval {UPDATE occurrence SET reference='Card 12, revised' WHERE occurrence_id='007-B'}
        updateSample eval {INSERT INTO occurrence VALUES ('001-C','Bay 01','Closed','desk','Sheet 5',
            '2026-11-01T09:20:00.000000000Z','2026-11-01T09:30:00.000000000Z')}
    } finally {updateSample close}
    edit $db 2026-11-01T09:29:59.999999999Z
    equal [dict get [::research::report] visible] {001-C 007-A 007-B} "new observation changes row positions"
    equal [dict get [::research::report] selected] 007-B "redraw preserves the selected key after reordering"
    equal [dict get [::research::report] observation reference] {Card 12, revised} "provenance reread for surviving selection"
    equal [lindex $items end] {rectangle selection {}} "redraw restores the highlight"
    set before [list $::research::snapshot $items $::research::details]
    edit $db 2026-11-01T09:30:00
    equal [string match {Could not apply the time.*} $::research::status] 1 "bad input reported"
    equal [list $::research::snapshot $items $::research::details] $before "failed edit leaves graph and source intact"
    edit $db 2026-11-01T09:30:00Z
    equal [dict get [::research::report] visible] {007-A 009-A} "end exclusive; simultaneous new start inclusive"
    equal [list [dict get [::research::report] selected] $::research::details] {{} {}} "departed occurrence cleared"
    equal [labels node:[::research::nodeId occurrence 009-A]] {{Café & stores} Checked} "UTF-8 and ampersand survive Graphviz"
    set current [list node node:[::research::nodeId occurrence 007-A]]
    ::research::click ::researchTest::canvas
    equal [dict get [::research::report] observation reference] {Sheet 4, row 7} "other identical label has its own provenance"
    edit $db 2026-11-01T10:00:00Z
    equal [dict get [::research::report] visible] {} "uncovered research instant"
    equal $items {} "empty graph clears stale canvas items"

    # IDs may contain Tcl/Tk tag operators or DOT punctuation. Displayed
    # values may contain markup. Neither representation is executable.
    set key {007;"&[x]}
    set asset {Meter <A> & "B"}
    sqlite3 updateSample $db -create 0
    try {
        updateSample eval {INSERT INTO occurrence VALUES ($key,$asset,'Read','desk','p. 8',
            '2026-11-01T10:00:00.000000000Z','2026-11-01T10:00:00.000000001Z')}
    } finally {updateSample close}
    edit $db 2026-11-01T10:00:00Z
    set encoded node:[::research::nodeId occurrence $key]
    equal [labels $encoded] [list $asset Read] "quoted text and arbitrary occurrence ID survive layout"
    set current [list node $encoded]
    ::research::click ::researchTest::canvas
    equal [dict get [::research::report] selected] $key "opaque canvas tag maps back to exact key"
    edit $db 2026-11-01T10:00:00.000000001Z
    equal [dict get [::research::report] visible] {} "one-nanosecond occurrence ends exactly"

    proc ::diagram::bind {canvas event command} {set ::researchTest::onClick $command}
    ::diagram::show ::researchTest::canvas
    equal [labels node:orders] {Orders Customer Item} "original order diagram uses the shared painter"
    set current {node node:orders}
    {*}$::researchTest::onClick
    equal $::diagram::selected orders "original order diagram selects the clicked table"
    rename ::diagram::bind {}
    rename ::diagram::font {}
}

proc ::researchTest::invoke {exe dir args} {
    set run [::machteld::run -dir $dir -timeout 30s -- $exe {*}$args]
    set err [encoding convertfrom -profile strict utf-8 [dict get $run err]]
    equal [list [dict get $run status] [dict get $run exit] [dict get $run truncated] $err] {ok 0 {} {}} "headless entry"
    return [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run out]] "\r\n"]
}
proc ::researchTest::portable {project root work} {
    set exe [info nameofexecutable]
    set driver [file join $root tools application_project.tcl]
    set delivery [file join $work {recipient 雪}]
    file mkdir $delivery
    set archive [file join $delivery research.machteld]
    set db [file join $work {notes 雪.db}]
    invoke $exe $work $driver pack $project $archive
    set copy [file join $delivery machteld.exe]
    file copy $exe $copy
    invoke $copy $work $archive --create-sample $db
    foreach {time key expected} {
        2026-11-01T09:15:00Z 007-B {007-B {Card 12}}
        2026-11-01T09:30:00Z 007-B {{} {}}
        2026-11-01T09:30:00Z 009-A {009-A {Card 13}}
        2026-11-01T10:00:00Z 007-A {{} {}}
    } {
        set args [list --headless $db $time $key]
        set original [invoke $exe $work $driver run $project {*}$args]
        set relocated [invoke $copy $work $archive {*}$args]
        equal $relocated $original "source and relocated app agree at $time"
        equal [list [dict get $relocated selected] [dict getdef $relocated observation reference {}]] $expected "packed selection"
        if {$key eq "009-A"} {equal [dict get $relocated observation asset] {Café & stores} "UTF-8 headless output"}
    }
}

# An owner-attended check on a real canvas. Only --tk enters this path.
proc ::researchTest::tkClick {db} {
    package require Tk
    pack [::canvas .c -width 640 -height 300]
    bind .c <Button-1> {::research::click .c}
    set ::research::input 2026-11-01T09:15:00Z
    ::research::apply $db .c
    update
    set item [lindex [.c find withtag node:[::research::nodeId occurrence 007-B]] end]
    lassign [.c bbox $item] x0 y0 x1 y1
    set x [expr {($x0+$x1)/2}]
    set y [expr {($y0+$y1)/2}]
    event generate .c <Motion> -x $x -y $y
    event generate .c <Button-1> -x $x -y $y
    update
    equal [dict get [::research::report] observation reference] {Card 12} "Tk pointer selects source"
    set ::research::input 2026-11-01T09:29:00Z
    ::research::apply $db .c
    equal [llength [.c find withtag selection]] 1 "real canvas retains selection after edit"
    set ::research::input 2026-11-01T09:30:00Z
    ::research::apply $db .c
    equal [llength [.c find withtag selection]] 0 "real canvas clears selection at boundary"
    destroy .
}

if {$argv ni {{} -pack --tk}} {error "usage: [file tail [info script]] ?-pack|--tk?"}
set root [file dirname [file dirname [file normalize [info script]]]]
set sample [file join $root examples graphviz-table]
set project [file join $sample research.dict]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]
set sources [dict get [::appcompiler::project::load $project] sources]
namespace eval :: [dict get [::appcompiler::compile $sources ::application] script]
source -encoding utf-8 [file join $sample research.tcl]
source -encoding utf-8 [file join $sample view.tcl]
set work [file normalize [file tempdir]]
try {
    set db [file join $work views.db]
    ::research::createSample $db
    ::researchTest::controller $db
    if {$argv eq "-pack"} {::researchTest::portable $project $root $work}
    if {$argv eq "--tk"} {
        set tkDb [file join $work desktop.db]
        ::research::createSample $tkDb
        ::researchTest::tkClick $tkDb
    }
} finally {file delete -force -- $work}
puts "research diagram: $::researchTest::checks assertions passed"
