package require machteld 30-
set root [file dirname [file dirname [file normalize [info script]]]]
set sample [file join $root examples graphviz-table]
set manifest [file join $sample typed-window.dict]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

namespace eval ::widgetTest {variable checks 0}
proc ::widgetTest::equal {actual expected name} {
    variable checks
    if {$actual ne $expected} {error "$name: expected [list $expected], got [list $actual]"}
    incr checks
}
proc ::widgetTest::bad {source codes} {
    set ds [::appcompiler::check [dict create sample $source]]
    equal [lmap d $ds {dict get $d code}] $codes "diagnostics for $source"
}
set probes {record .widget { value: tk_canvas }
export fn .id<.t>($v: .t) -> .t => $v
export fn .canvas($c: tk_canvas) -> tk_canvas => $c
export fn .item($i: tk_item) -> tk_item => $i
export fn .on($e: tk_click) -> unit => .receive($e)
export fn .listen($c: tk_canvas) -> unit => tk_on_click($c, .on)
extern fn .receive($e: tk_click) -> unit = ['::received']
export fn .encode($e: tk_click) -> result<text,problem> => encode_json($e)
export fn .decode($s: text) -> result<.widget,problem> => decode_json<.widget>($s)
export fn .primitives($c: tk_canvas,$key: text) -> list<tk_item> =>
    [tk_rectangle($c,$key,0,0,100,30), tk_text($c,$key,50,15,'Label')]
export fn .remove($i: tk_item) -> unit => tk_remove($i)
export fn .close($w: tk_window) -> unit => tk_close($w)
export fn .title($w: tk_window,$text: text) -> unit => tk_title($w,$text)
}
set sources [dict get [::appcompiler::project::load $manifest] sources]
dict set sources probe $probes
set generated [dict get [::appcompiler::compile $sources ::application] script]
set key {007-"%x & [literal]; $row}
set rows {}
foreach k [list $key 007-B] source {Ledger Inspector} reference {{row 7} {card 12}} {
    lappend rows [dict create occurrence_id $k asset {Bay 07} observation Open source_id $source \
        source_name $source reference $reference starts 2026-11-01T08:00:00.000000000Z ends 2026-11-01T10:00:00.000000000Z]
}

# Called inside the isolated recording interpreter with a live window.
proc ::widgetTest::recorded {window} {
    set c [paths canvas]
    set label [paths label]
    set b [paths button]
    equal [dict size $::recordTk::grid] 3 "X arranges all three widgets"
    equal [$label cget -text] {Select an occurrence} "initial X label"
    set nativeTag node:[::research::nodeId occurrence $::sampleKey]
    set ids [$c find withtag $nativeTag]
    set kinds {}
    foreach i $ids {dict set kinds [$c type $i] $i}
    foreach kind {polygon text} {
        ::recordTk::click $c [dict get $kinds $kind] 41 12
        equal [$label cget -text] "$::sampleKey · Ledger · row 7" "Graphviz $kind resolves the same occurrence"
    }
    set widgetId [string range [file tail [lindex [bindtags $c] 0]] [string length mt_binding_] end]
    set canvas [list tk_canvas $widgetId]
    set ::retainedCanvas $canvas
    equal [catch {::application::probe::canvas $c}] 1 "a raw Tk path is not a typed canvas handle"
    equal [crossInterpreter $canvas] 1 "independent interpreter rejects a copied live ticket"
    set items [::application::probe::primitives $canvas $::sampleKey]
    set first [lindex $items 0]
    equal [::application::probe::id tk_item $first] $first "generic boundary checks the live canvas item"
    equal [catch {::application::probe::canvas $first}] 1 "item rejected as canvas"
    set ::retainedItem [lindex $items 1]
    ::application::probe::remove $first
    equal [catch {::application::probe::item $first} msg opts] 1 "removed item is stale"
    equal [dict get $opts -errorcode] {APPCOMPILER TK STALE} "stale item code"
    $b invoke
    equal [$label cget -text] "$::sampleKey · Ledger · row 7" "redraw preserves selected source"
    equal [llength [$c find withtag mt_selection_$widgetId]] 1 "highlight restored on newly drawn items"
    equal [catch {::application::probe::item $::retainedItem}] 1 "redraw invalidates previous generation"
    equal [catch {::foreign::probe::canvas $canvas}] 1 "another application cannot use the canvas"
    equal [catch {::application::probe::id tk_label $canvas}] 1 "generic concrete handle kinds stay distinct"
    set original [$b cget -command]
    set buttonId [string range [lindex [bindtags $b] 0] [string length mt_binding_] end]
    ::application::@rt::tk_button_text [list tk_button $buttonId] Again
    equal [$b cget -text] Again "typed button caption update"
    destroy $b
    equal [uplevel #0 $original] {} "native destruction makes a retained button command inert"
    equal [catch {::application::probe::id tk_button [list tk_button $buttonId]}] 1 "independently destroyed widget expires"

    set tag [lindex [bindtags $c] 0]
    set ::oldScript [dict get $::recordTk::bindings [list $tag <Button-1>]]
    ::application::probe::listen $canvas
    set ::observed {}
    uplevel #0 [string map {%x 2 %y 3} $::oldScript]
    equal $::observed {} "a superseded binding is inert"
    set new [lindex [$c find withtag $nativeTag] end]
    ::recordTk::click $c $new -2 15
    equal [list [dict get $::observed x] [dict get $::observed y] [dict get $::observed occurrence]] \
        [list -2 15 [list some $::sampleKey]] "typed integer coordinates and arbitrary exact key"
    equal [dict get $::observed canvas] $canvas "event identifies its live canvas"
    set ::failEvent 1
    set literal {panel [literal]; $name}
    equal [::application::@events::last_fault] {} "empty diagnostic history on first use"
    ::application::@events::on_fault [list ::saveEvent $literal]
    equal [::application::@events::on_fault] [list ::saveEvent $literal] "registered prefix is literal Tcl data"
    equal [catch {::recordTk::click $c $new 2 3}] 0 "a failing event returns to the dispatcher"
    equal $::sinkLabel $literal "sink receives its arguments exactly"
    set fault [::application::@events::last_fault]
    equal [list [dict get $fault operation] [dict get $fault message]] {tk-click {handler failed}} "failed click is identified"
    set options [dict get $fault options]
    equal [dict get $options -errorcode] {TEST CLICK} "typed dispatch preserves the callback's error code"
    equal [dict get $options -appcompilerlocation module] probe "callback fault retains typed source"
    equal [dict get $options -fixturemetadata] preserved "arbitrary Tcl error options survive"
    equal [::foreign::@events::last_fault] {} "faults belong to the failing application"
    equal [::foreign::@events::on_fault] {} "independent apps keep independent sink preferences"
    ::application::@events::on_fault {}
    ::recordTk::click $c $new 2 3
    equal [string match {probe:*:*: tk-click error: handler failed} [lindex $::stderrLines end]] 1 "default stderr identifies the source"
    ::application::@events::on_fault [list ::failSink $c $new]
    ::recordTk::click $c $new 2 3
    equal $::badSinkCalls 1 "a fault during reporting cannot recursively invoke the same sink"
    equal [lindex $::stderrLines end] {fault sink error: broken diagnostic pane} "sink failure falls back to stderr"
    equal [dict get [::application::@events::last_fault] options -errorcode] {TEST CLICK} "sink failure preserves the application fault"
    ::application::@events::on_fault {}
    set ::stderrUnavailable 1
    equal [catch {::recordTk::click $c $new 2 3}] 0 "a launch without stderr still returns to the event loop"
    equal [dict get [::application::@events::last_fault] message] {handler failed} "diagnostic remains accessible without stderr"
    unset ::stderrUnavailable
    unset ::failEvent
    set ::retainedWindow [dict get $::observed window]
    ::application::probe::title $::retainedWindow {Bay %x [7]}
    equal [dict get $::recordTk::widgets $window title] {Bay %x [7]} "window title update treats text literally"
    lassign [::application::probe::encode $::observed] tag problem
    equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} "event with a live handle has no JSON representation"
    ::recordTk::click $c {} 0 0
    equal [dict get $::observed occurrence] none "background click"

    set empty [lindex [::application::probe::primitives $canvas {}] end]
    ::recordTk::click $c [lindex $empty end] 2 3
    equal [dict get $::observed occurrence] {some {}} "empty occurrence key differs from background"
    set ::workerHistory {}
    proc ::application::@rt::workerControl {op path} {lappend ::workerHistory $op; return windowOwner}
    proc ::application::@rt::workerHandle {owner prefix args} {lappend ::workerHistory $owner; {*}$prefix {*}$args}
    ::recordTk::click $c {} 5 6
    equal $::workerHistory {window windowOwner} "compiled worker bridge receives the owning window"
    rename ::application::@rt::workerControl {}
    rename ::application::@rt::workerHandle {}
    set ::afterClose [dict get $::recordTk::bindings [list [lindex [bindtags $c] 0] <Button-1>]]
    set ::hookRuns {}
    ::application::@events::on_fault [list ::saveEvent closing]
    ::application::@rt::tkOnClose $::retainedWindow [list ::error {close observer failed} {} {TEST CLOSE}]
    ::application::@rt::tkOnClose $::retainedWindow [list lappend ::hookRuns kept]
    set forgotten [::application::@rt::tkOnClose $::retainedWindow [list lappend ::hookRuns forgotten]]
    ::application::@rt::tkForgetClose $::retainedWindow $forgotten
    destroy $window
    equal $::hookRuns kept "later close observers fire once after an observer faults"
    equal [list [dict get $::savedEvent operation] [dict get $::savedEvent options -errorcode]] \
        {tk-destroy {TEST CLOSE}} "destroy callback faults go to the application sink"
    equal [catch {::application::probe::close $::retainedWindow}] 1 "closed window rejects updates"
    set ::observed none
    uplevel #0 [string map {%x 1 %y 1} $::afterClose]
    equal $::observed none "late event cannot touch a closed window"
}

proc ::widgetTest::headless {} {
    global sample root key rows generated probes
    set app [interp create]
    set neighbor [interp create -safe]
    try {
        $app eval [list source -encoding utf-8 [file join $root test fixtures recording_tk.tcl]]
        interp hide $app load
        interp alias $app ::machteld::hash {} ::machteld::hash
        interp alias $app ::machteld::graphviz {} ::machteld::graphviz
        interp alias $app ::machteld::json {} ::machteld::json
        interp alias $app equal {} ::widgetTest::equal
        $neighbor eval [dict get [::appcompiler::compile [dict create probe $probes] ::application] script]
        interp alias $app crossInterpreter {} ::widgetTest::crossInterpreter $neighbor
        $app eval [list lappend auto_path [file join $sample lib]]
        $app eval [list set ::sampleKey $key]
        $app eval $generated
        $app eval [dict get [::appcompiler::compile [dict create probe $probes] ::foreign] script]
        $app eval {
            set ::stderrLines {}
            set ::badSinkCalls 0
            rename ::puts ::realPuts
            proc ::puts {args} {
                if {[llength $args] == 2 && [lindex $args 0] eq "stderr"} {
                    if {[info exists ::stderrUnavailable]} {error {stderr is closed}}
                    lappend ::stderrLines [lindex $args 1]
                    return
                }
                tailcall ::realPuts {*}$args
            }
            proc ::saveEvent {label fault} {set ::sinkLabel $label; set ::savedEvent $fault}
            proc ::failSink {canvas item fault} {
                incr ::badSinkCalls
                ::recordTk::click $canvas $item 2 3
                error {broken diagnostic pane}
            }
            proc received {event} {
                if {[info exists ::failEvent]} {return -code error -errorcode {TEST CLICK} -fixturemetadata preserved "handler failed"}
                set ::observed $event
                return {}
            }
            proc paths {kind} {
                dict for {path state} $::recordTk::widgets {
                    if {[dict get $state kind] eq $kind} {return $path}
                }
                error "missing widget $kind"
            }
        }
        $app eval [list proc inspectWindow {window} [info body ::widgetTest::recorded]]
        $app eval {set ::recordTk::waiting inspectWindow}
        equal [$app eval [list ::application::browser::display $rows]] {ok {}} "X-authored Tk window and real Graphviz drawing"
        equal [$app eval {dict size $::recordTk::bindings}] 0 "private bindtags released"
        equal [$app eval {array size ::application::@rt::tkState}] 0 "all window and child records released"
        set stale [$app eval {set ::retainedCanvas}]
        equal [catch {$app eval [list ::application::probe::id tk_canvas $stale]}] 1 "generic export rejects retained stale window child"
        lassign [$app eval [list ::application::probe::decode {{"value":"a widget"}}]] tag problem
        equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} "cannot decode widget handles"
        $app eval {rename ::toplevel {}; proc ::toplevel args {error {no display}}}
        lassign [$app eval [list ::application::browser::display $rows]] tag problem
        equal [list $tag [dict get $problem code]] {err TK_OPEN} "failed acquisition returns a typed problem"
    } finally {interp delete $app; interp delete $neighbor}

    bad {fn .a($l: tk_label) -> unit => tk_clear($l)} ARGUMENT_TYPE
    bad {fn .a($c: tk_canvas<text>) -> unit => unit} UNKNOWN_TYPE
    bad {fn .a($r: tk_window) -> unit => tk_grid($r,0,1)} ARGUMENT_TYPE
    bad {fn .a($r: tk_click) -> text => $r.x} RETURN_TYPE
    bad {fn .a($c: tk_canvas) -> bool => $c == $c} NOT_COMPARABLE
    bad {fn .a($c: tk_click) -> bool => $c == $c} NOT_COMPARABLE
    bad {fn .a($w: tk_window) -> result<tk_click,problem> => sql_one<tk_click>('file','SELECT 1')} {SQL_FIELD_TYPE SQL_FIELD_TYPE}
    bad {fn .a($c: tk_canvas, $f: callable<tk_action,unit>) -> unit => tk_on_click($c,$f)} ARGUMENT_TYPE
    bad {fn .a() -> result<tk_window,problem> => tk_open('title')} TK_SCOPE
    bad {fn .a($r: result<tk_window,problem>) -> result<unit,problem> {
        using $w ::= $r? {return ok(unit)}
    }} TK_SCOPE
}

proc ::widgetTest::crossInterpreter {neighbor ticket} {
    return [catch {$neighbor eval [list ::application::probe::canvas $ticket]}]
}

# Source the verified archive entry in an interpreter with native SQLite
# and Graphviz, and the recording Tk package already installed. Its ordinary
# two-argument GUI route now tests package discovery inside zipfs as well.
proc ::widgetTest::archiveWindow {archive database} {
    global root
    set mount [zipfs mount $archive widget-archive-test]
    try {
        set entry [::machteld::ArchiveEntry $mount]
        set app [interp create]
        try {
            $app eval [list source -encoding utf-8 [file join $root test fixtures recording_tk.tcl]]
            $app eval {load {} Sqlite3}
            interp hide $app load
            $app eval [list package provide machteld [package provide machteld]]
            foreach command {hash graphviz json} {interp alias $app ::machteld::$command {} ::machteld::$command}
            $app eval [list set argv0 $archive]
            $app eval [list set argv [list $database 2026-11-01T09:15:00Z]]
            $app eval {
                proc ::exit {status} {set ::appStatus $status}
                proc ::packedClick {window} {
                    dict for {path state} $::recordTk::widgets {set w([dict get $state kind]) $path}
                    set c $w(canvas)
                    set item [lindex [$c find withtag node:[::research::nodeId occurrence 007-B]] end]
                    ::recordTk::click $c $item 5 8
                    $w(button) invoke
                    set ::packedCaption [$w(label) cget -text]
                }
                set ::recordTk::waiting ::packedClick
            }
            $app eval [list source -encoding utf-8 $entry]
            equal [$app eval {set ::appStatus}] 0 "archive GUI entry with recording Tk"
            equal [$app eval {set ::packedCaption}] {007-B · Field inspection · Card 12} "archived renderer, callback and redraw"
        } finally {interp delete $app}
    } finally {zipfs unmount $mount}
}

proc ::widgetTest::runOwner {work launch mode helper} {
    file mkdir $work
    set run [::machteld::run -dir $work -timeout 22s -- {*}$launch $mode $work $helper]
    equal [list [dict get $run status] [dict get $run exit] [string trim [dict get $run out]] [string trim [dict get $run err]]] \
        {ok 0 ok {}} "recorded window and real child lifecycle ($mode)"
}

proc ::widgetTest::owners {packed} {
    global root
    set tmp [file normalize [file tempdir]]
    try {
        set fixture [file join $root test fixtures window-owner]
        set author [file join $tmp author]
        file mkdir $author
        foreach member {requests.src faults.src synchronous.src streams.src controller.tcl lib} {
            file copy -- [file join $fixture $member] [file join $author $member]
        }
        file copy -- [file join $root test fixtures recording_tk.tcl] $author
        set helper [file join $tmp pipes.tcl]
        ::appcompiler::project::stageBytes $helper {package require machteld
            chan configure stdout -translation binary -buffering none
            if {$argv eq "parent"} {puts -nonewline stdout P}
            after 20000
        }
        set driver [file join $::appcompiler::compilerDirectory driver.tcl]
        foreach {project file modes} {managed requests.src {resume close wait_app faults} synchronous synchronous.src streams} {
            set manifest [file join $author $project.dict]
            set config [dict create schema 1 edition 1 minApi 30 tclEntry controller.tcl \
                modules [list ui $file streams streams.src] assets {recording_tk.tcl lib/pkgIndex.tcl lib/barrier.tcl} packageDirs lib]
            if {$project eq "managed"} {dict set config modules faults faults.src}
            ::appcompiler::project::stageBytes $manifest $config
            foreach mode $modes {runOwner [file join $tmp source-$mode] [list [info nameofexecutable] $driver run $manifest] $mode $helper}
            if {$packed} {
                set archive [file join $tmp $project.machteld]
                ::appcompiler::project::pack $manifest $archive
            }
        }
        if {$packed} {
            file rename -- $author [file join $tmp retired]
            set delivery [file join $tmp {colleague copy}]
            file mkdir $delivery
            set host [file join $delivery machteld.exe]
            file copy -- [info nameofexecutable] $host
            foreach {project modes} {managed {resume close wait_app faults} synchronous streams} {
                set archive [file join $delivery received-$project.machteld]
                file rename -- [file join $tmp $project.machteld] $archive
                set rebuilt [file join $delivery rebuilt-$project.machteld]
                ::appcompiler::project::rebuild $archive $rebuilt
                foreach app [list $archive $rebuilt] {
                    foreach mode $modes {
                        runOwner [file join $tmp [file tail $app]-$mode] [list $host $app] $mode $helper
                    }
                }
            }
        }
    } finally {file delete -force -- $tmp}
}

proc ::widgetTest::portable {} {
    global sample manifest
    set tmp [file normalize [file tempdir]]
    try {
        set database [file join $tmp sample.db]
        source -encoding utf-8 [file join $sample research.tcl]
        ::research::createSample $database
        set archive [file join $tmp window.machteld]
        ::appcompiler::project::pack $manifest $archive
        set rebuilt [file join $tmp rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        foreach app [list $archive $rebuilt] {
            set result [::machteld::run -dir $tmp -timeout 30s -- [info nameofexecutable] $app --lookup $database 2026-11-01T09:15:00Z 007-B]
            equal [dict get $result exit] 0 "headless packed query: [dict get $result err]"
            equal [encoding convertfrom -profile strict utf-8 [dict get $result out]] {007-B · Field inspection · Card 12} "packed example uses same typed provenance caption"
            archiveWindow $app $database
        }
    } finally {file delete -force -- $tmp}
}

# Only --tk enters this path. Exercise native item hit-testing and Destroy.
proc ::widgetTest::deliver {} {
    global key
    set top [lindex [winfo children .] 0]
    try {
        foreach w [winfo children $top] {
            switch [winfo class $w] {Canvas {set c $w} TLabel {set l $w} TButton {set b $w}}
        }
        set item [lindex [$c find withtag node:[::research::nodeId occurrence $key]] end]
        lassign [$c bbox $item] x0 y0 x1 y1
        set x [expr {($x0 + $x1) / 2}]
        set y [expr {($y0 + $y1) / 2}]
        event generate $c <Motion> -x $x -y $y
        event generate $c <Button-1> -x $x -y $y
        equal [$l cget -text] "$key · Ledger · row 7" "actual Tk event reaches typed handler"
        $b invoke
        equal [$l cget -text] "$key · Ledger · row 7" "actual Tk redraw"
        set ::widgetTest::delivered 1
    } on error {message options} {set ::widgetTest::failure [list $message $options]} finally {destroy $top}
}

if {$argv ni {{} -pack --tk}} {error "usage: [file tail [info script]] ?-pack|--tk?"}
::widgetTest::headless
if {$argv ne "--tk"} {::widgetTest::owners [expr {$argv eq "-pack"}]}
if {$argv eq "-pack"} {::widgetTest::portable}
if {$argv eq "--tk"} {
    package require Tk
    wm withdraw .
    set ::widgetTest::delivered 0
    lappend auto_path [file join $sample lib]
    namespace eval :: $generated
    set timer [after 300 ::widgetTest::deliver]
    set timeout [after 5000 {
        set ::widgetTest::failure [list {timed out waiting for the real Tk event} [dict create -code 1 -level 0]]
        foreach top [winfo children .] {destroy $top}
    }]
    try {
        ::widgetTest::equal [::application::browser::display $rows] {ok {}} "real window closed"
    } finally {
        after cancel $timer
        after cancel $timeout
        # Tcl_Main keeps running while the withdrawn Tk root exists.
        destroy .
    }
    if {[info exists ::widgetTest::failure]} {
        lassign $::widgetTest::failure message options
        return -options $options $message
    }
    ::widgetTest::equal $::widgetTest::delivered 1 "native event test completed before the window closed"
}
puts "application compiler typed Tk: $::widgetTest::checks assertions passed"
