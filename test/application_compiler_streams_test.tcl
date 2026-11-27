package require machteld
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

namespace eval ::streamTest {
    variable checks 0
    variable source {export tool .helper = 'bin/byte helper.exe'
extern fn .receive($side: text, $data: bytes) -> result<unit,problem> = ['::received']
extern fn .terminal($r: result<process_exit,problem>) -> unit = ['::terminal']
export fn .open($exe: text, $argv: list<text>, $input: bytes, $n: int, $ms: int) -> result<process_stream,problem> =>
    stream_process($exe, $argv, $input, $n, $ms, bind(.receive,'stdout'), bind(.receive,'stderr'), .terminal)
export fn .run($args: list<text>, $input: bytes) -> result<process_stream,problem> =>
    .open(.helper()?, $args, $input, 64, 5000)
export fn .scoped($exe: text, $args: list<text>, $input: bytes) -> result<unit,problem> {
    using $job ::= .open($exe,$args,$input,32,5000)? { return ok(unit) }
}
export fn .cancel($handle: process_stream) -> unit => cancel_process($handle)
export fn .close($handle: process_stream) -> unit => close_process($handle)
export fn .find($name: text) -> result<text,problem> => find_executable($name)
fn .count($counter: ref<int>, $data: bytes) -> result<unit,problem> {
    ref_set($counter,ref_get($counter) + 1)
    return ok(unit)
}
export fn .escaped($exe: text, $args: list<text>, $input: bytes) -> result<process_stream,problem> {
    using $counter ::= ref(0) {
        return stream_process($exe,$args,$input,8,5000,bind(.count,$counter),bind(.count,$counter),.terminal)
    }
}}
    variable fixture {package require machteld
foreach c {stdin stdout stderr} {chan configure $c -translation binary -buffering none}
switch -- [lindex $argv 0] {
    echo {
        puts -nonewline stderr [binary decode hex 00ffc328]
        puts -nonewline stdout [read stdin]
        exit 17
    }
    argv {puts -nonewline stdout [encoding convertto utf-8 [lrange $argv 1 end]]}
    flood {
        set left [binary format H* [string repeat 00ff 2048]]
        set right [binary format H* [string repeat f080 2048]]
        for {set i 0} {$i < 257} {incr i} {
            puts -nonewline stdout $left
            puts -nonewline stderr $right
        }
        puts -nonewline stdout [read stdin]
    }
    early {close stdin; puts -nonewline stdout early; exit 9}
    stderr {puts -nonewline stderr E}
    gated {
        set deadline [expr {[clock milliseconds] + 5000}]
        while {![file exists [lindex $argv 1]]} {
            if {[clock milliseconds] >= $deadline} {exit 2}
            after 10
        }
        puts -nonewline stdout ready
    }
    wait {after 5000}
}}
    variable namedSource {extern fn .part($name: text, $bytes: bytes) -> result<unit,problem> = ['::receivePart']
extern fn .done($name: text, $result: result<process_exit,problem>) -> unit = ['::complete']
export fn .named($name: text, $args: list<text>, $input: bytes) -> result<process_stream,problem> =>
    stream_process(.helper()?, $args, $input, 16, 8000,
        bind(.part,$name), bind(.part,$name), bind(.done,$name))
}
    variable entry {package require machteld
if {[lindex $argv 0] eq "--retirement"} {
    source -encoding utf-8 [file join [file dirname [info script]] retirement.tcl]
    return
}
array set ::bytes {stdout {} stderr {}}
proc ::received {side data} {append ::bytes($side) $data; return {ok {}}}
proc ::terminal {r} {set ::outcome $r; return {}}
chan configure stdin -translation binary
set startup [::application::flow::run $argv [read stdin]]
if {[lindex $startup 0] ne "ok"} {error $startup}
vwait ::outcome
lassign $::outcome tag result
if {$tag ne "ok"} {error $result}
puts [list [dict get $result status] [dict get $result exit] [binary encode hex $::bytes(stdout)] [binary encode hex $::bytes(stderr)]]
}
}
proc ::streamTest::equal {got want label} {
    variable checks
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
    incr checks
}
proc ::streamTest::write {name text} {::appcompiler::project::stageBytes $name [encoding convertto utf-8 $text]}
proc ::streamTest::api {name args} {::typedStream::flow::$name {*}$args}
proc ::streamTest::reset {{mode collect}} {
    variable action $mode
    variable depth 0
    variable largest 0
    variable terminals 0
    variable chunks 0
    variable output
    variable outcome
    array set output {stdout {} stderr {}}
    unset -nocomplain outcome
}
proc ::received {side data} {
    variable ::streamTest::output
    variable ::streamTest::action
    variable ::streamTest::ticket
    variable ::streamTest::depth
    variable ::streamTest::largest
    variable ::streamTest::chunks
    if {[incr depth] != 1} {error "reentrant chunk callback"}
    try {
        incr chunks
        append output($side) $data
        set largest [expr {max($largest, [string length $data])}]
        switch -- $action {
            reject {return {err {code TEST_REJECT message {consumer declined}}}}
            throw {return -code error -errorcode {TEST CHUNK} -chunkdetail original "consumer fault"}
            cancel {::streamTest::api cancel $ticket}
            close {::streamTest::api close $ticket; set ::streamTest::closed 1}
            nest {update}
        }
        return {ok {}}
    } finally {incr depth -1}
}
proc ::terminal {result} {
    if {$::streamTest::depth} {error "terminal delivered inside chunk callback"}
    incr ::streamTest::terminals
    set ::streamTest::outcome $result
    if {$::streamTest::action eq "terminal_fault"} {return -code error -errorcode {TEST TERMINAL} "terminal consumer fault"}
    return {}
}
proc ::streamTest::background {message options} {set ::streamTest::backgroundMessage $message}
proc ::streamTest::waitFor {name} {
    set timer [after 16000 [list set $name WATCHDOG]]
    try {
        if {![info exists $name]} {vwait $name}
        if {[set $name] eq "WATCHDOG"} {error "event loop exceeded deadline"}
        return [set $name]
    } finally {after cancel $timer}
}
proc ::streamTest::start {exe args input chunk timeout} {
    variable ticket
    lassign [api open $exe $args $input $chunk $timeout] tag ticket
    equal $tag ok "async start: $ticket"
}
proc ::streamTest::finish {} {
    variable terminals
    set value [waitFor ::streamTest::outcome]
    equal $terminals 1 "terminal callback delivered once"
    equal [::machteld::child list] {} "native child released before terminal notification"
    return $value
}
proc ::streamTest::exercise {exe script} {
    variable output
    variable ticket
    variable largest
    variable terminals
    variable chunks
    reset nest
    set small [binary decode hex ff000affe08080]
    start $exe [list $script echo] $small 2 5000
    lassign [finish] tag r
    equal [list $tag [dict get $r status] [dict get $r exit] [dict get $r stdout_bytes] [dict get $r stderr_bytes]] {ok error 17 7 4} "counts include final bytes before nonzero exit"
    equal [binary encode hex $output(stdout)] ff000affe08080 "binary stdin and separate stdout"
    equal [binary encode hex $output(stderr)] 00ffc328 "invalid UTF-8 preserved as bytes"
    equal $largest 2 "chunk bound with nested event loop"
    set old $ticket
    reset
    set args [list {} {a b} {x; [error BAD]} {a"b} 雪]
    start $exe [list $script argv {*}$args] {} 13 5000
    api cancel $old
    api close $old
    finish
    equal [encoding convertfrom -profile strict utf-8 $output(stdout)] $args "exact argv and stale handles"

    reset
    set input [binary decode hex [string repeat a5e0ff00 73728]]
    start $exe [list $script flood] $input 8192 12000
    lassign [finish] tag r
    equal [list $tag [dict get $r status]] {ok ok} "concurrent drain while filling stdin"
    set n [expr {4096*257}]
    equal [dict get $r stdout_bytes] [expr {$n + [string length $input]}] "stdout beyond capture cap"
    equal [dict get $r stderr_bytes] $n "stderr beyond capture cap"
    set expected [binary decode hex [string repeat 00ff [expr {$n/2}]]]
    append expected $input
    equal [expr {$output(stdout) eq $expected}] 1 "stdout flood and input echo are exact"
    equal [expr {$output(stderr) eq [binary decode hex [string repeat f080 [expr {$n/2}]]]}] 1 "stderr flood is exact"
    equal [expr {$largest <= 8192}] 1 "large stream remains bounded per callback"
    reset
    start $exe [list $script early] $input 4096 5000
    lassign [finish] tag r
    equal [list $tag [dict get $r exit] $output(stdout)] {ok 9 early} "child may finish before consuming stdin"

    foreach {mode code} {reject TEST_REJECT throw PROCESS_CALLBACK} {
        reset $mode
        start $exe [list $script flood] {} 7 5000
        lassign [finish] tag r
        equal [list $tag [dict get $r code] $chunks] [list err $code 1] "chunk failure $mode closes stream once"
        if {$mode eq "throw"} {
            equal [list [dict get $r options -errorcode] [dict get $r options -chunkdetail] [dict get $r origin module]] \
                {{TEST CHUNK} original flow} "chunk fault preserves options and mapped source for the completion consumer"
            equal [::typedStream::@events::last_fault] {} "handled chunk fault is not reported again"
        }
    }
    reset cancel
    start $exe [list $script flood] {} 7 5000
    lassign [finish] tag r
    equal [list $tag [dict get $r status] [dict get $r exit] $chunks] {ok canceled -1 1} "cancel from callback finishes after its return"
    reset close
    start $exe [list $script flood] {} 7 5000
    waitFor ::streamTest::closed
    update
    equal [list $terminals [::machteld::child list]] {0 {}} "close inside callback suppresses all later callbacks"
    equal [::typedStream::@events::last_fault] {} "ordinary cancellation and closure do not report a fault"
    reset
    start $exe [list $script wait] {} 100 100
    lassign [finish] tag r
    equal [list $tag [dict get $r status] $chunks] {ok timeout 0} "autonomous timeout"
    reset
    equal [api scoped $exe [list $script wait] {}] {ok {}} "scope returns before process completion"
    update
    equal [list $terminals [::machteld::child list]] {0 {}} "scope exit silently releases child"
    reset
    lassign [api escaped $exe [list $script echo] $small] tag ticket
    lassign [finish] tag r
    equal [list $tag [dict get $r code] $chunks] {err PROCESS_CALLBACK 0} "expired reference prevents late chunk delivery"
    equal [dict get $r origin module] flow "capture validation falls back to stream source"

    reset terminal_fault
    set oldHandler [interp bgerror {}]
    try {
        interp bgerror {} ::streamTest::background
        ::typedStream::@events::on_fault [list set ::streamTest::terminalReport]
        start $exe [list $script echo] {} 65536 5000
        finish
        set report [waitFor ::streamTest::terminalReport]
        equal [list [dict get $report operation] [dict get $report message] [dict get $report options -errorcode]] \
            {process-done {terminal consumer fault} {TEST TERMINAL}} "completion fault goes to application sink"
        equal [dict get $report options -appcompilerlocation module] flow "completion fault preserves source"
        update
        equal [info exists ::streamTest::backgroundMessage] 0 "completion fault bypasses interpreter background errors"
        equal [list $terminals [::machteld::child list]] {1 {}} "terminal callback fault does not leak or retry"
    } finally {::typedStream::@events::on_fault {}; interp bgerror {} $oldHandler}
}

proc ::streamTest::invalid {exe work} {
    foreach {candidate args chunk timeout code} [list relative.exe {} 8 100 PROCESS_PATH \
            $exe [list "bad\u0000arg"] 8 100 PROCESS_ARGUMENT $exe {} 0 100 PROCESS_LIMIT \
            $exe {} 65537 100 PROCESS_LIMIT $exe {} 32 -1 PROCESS_TIMEOUT \
            [file join $work missing.exe] {} 8 100 PROCESS_NOT_FOUND] {
        lassign [api open $candidate $args {} $chunk $timeout] tag detail
        equal [list $tag [dict get $detail code]] [list err $code] "start rejects $code"
    }
    equal [catch {api close {anotherApplication unrelated}} msg options] 1 "foreign ticket rejected"
    equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "foreign ticket typed error"
    set bad {fn .bad($exe:text, $args:list<text>, $in:bytes) -> result<process_stream,problem> =>
        stream_process($exe,$args,$in,32,0,.wrong,.wrong,.wrong)
        fn .wrong($x:text) -> unit => unit}
    equal [lmap d [::appcompiler::check [dict create wrong $bad]] {dict get $d code}] {ARGUMENT_TYPE ARGUMENT_TYPE ARGUMENT_TYPE} "callback signatures checked at compile time"
    set saved $::env(PATH)
    set previous [pwd]
    try {
        cd $work
        set ::env(PATH) {;.}
        lassign [api find [file tail $exe]] tag detail
        equal [list $tag [dict get $detail code]] {err PROCESS_NOT_FOUND} "no implicit cwd lookup"
        set ::env(PATH) "\"[file dirname $exe]\""
        equal [api find [file tail $exe]] [list ok [file normalize $exe]] "explicit absolute PATH entry"
        foreach bad [list $exe {sub/tool.exe} tool.cmd {x:y.exe} {app}] {
            lassign [api find $bad] tag detail
            equal [list $tag [dict get $detail code]] {err PROCESS_PATH} "PATH lookup requires a bare explicit .exe"
        }
    } finally {set ::env(PATH) $saved; cd $previous}
}
# The healthy stream is already running when its siblings fault. Its child
# writes only after the fault reporter has seen both callbacks.
set ::streamTest::retirement {package require machteld
set reports {}
set completions {}
set chunks {}
set finished 0
set background {}
interp bgerror {} [list lappend ::background]
proc ::receivePart {name bytes} {
    dict append ::chunks $name $bytes
    if {$name eq "healthy"} {return {ok {}}}
    ::application::flow::$name [dict get $::jobs $name]
    return -code error -errorcode [list TEST RETIRED $name] -retiremode $name "$name callback fault"
}
proc ::complete {name result} {
    dict lappend ::completions $name $result
    if {$name eq "healthy"} {set ::finished 1}
    return {}
}
proc ::saveFault {report} {
    lappend ::reports $report
    if {[llength $::reports] == 2} {close [open $::gateFile {WRONLY CREAT EXCL}]}
}
proc ::require {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error "$message, reports=$::reports completions=$::completions"}
}
::application::@events::on_fault ::saveFault
set dir [file tempdir]
try {
    set gateFile [file join $dir ready]
    set helper [lindex $argv 1]
    foreach {name cmd} [list healthy [list gated $gateFile] cancel {argv C} close stderr] {
        lassign [::application::flow::named $name [list $helper {*}$cmd] [binary format a0 {}]] tag ticket
        require {$tag eq "ok"} "failed to start $name"
        dict set jobs $name $ticket
    }
    set timer [after 10000 {set ::finished timeout}]
    try {if {!$finished} {vwait ::finished}} finally {after cancel $timer}
    update
    require {$finished eq "1" && [llength $reports] == 2} "expected one report from each faulting callback"
    set found {}
    foreach report $reports {
        set opts [dict get $report options]
        set name [dict get $opts -retiremode]
        require {$name in {close cancel} && ![dict exists $found $name]} "duplicate or unrelated report"
        dict set found $name 1
        set operation [expr {$name eq "close" ? "process-stderr" : "process-stdout"}]
        require {[dict get $report operation] eq $operation && [dict get $report message] eq "$name callback fault"} "original fault identity"
        require {[dict get $opts -errorcode] eq [list TEST RETIRED $name] && [dict get $opts -appcompilerlocation module] eq "flow"} "original error options and source"
        require {[string first "$name callback fault" [dict get $opts -errorinfo]] >= 0} "missing Tcl error trace"
    }
    require {![dict exists $completions close] && [llength [dict get $completions cancel]] == 1} "close suppressed completion and cancel delivered exactly once"
    lassign [lindex [dict get $completions cancel] 0] tag result
    require {$tag eq "ok" && [dict get $result status] eq "canceled"} "canceled status retained"
    lassign [lindex [dict get $completions healthy] 0] tag result
    require {$tag eq "ok" && [dict get $result status] eq "ok" && [dict get $chunks healthy] eq "ready"} "other stream completes after both faults"
    require {$background eq {} && [::machteld::child list] eq {}} "background fault or retained child"
    puts ok
} finally {file delete -force -- $dir}
}

proc ::streamTest::portable {work script packed} {
    variable source
    variable entry
    variable namedSource
    variable retirement
    set author [file join $work author]
    set delivery [file join $work {recipient 雪}]
    foreach dir [list $author $delivery] {
        file mkdir [file join $dir bin]
        file copy [info nameofexecutable] [file join $dir bin {byte helper.exe}]
    }
    write [file join $author flow.src] "$source\n$namedSource"
    write [file join $author main.tcl] $entry
    write [file join $author retirement.tcl] $retirement
    set manifest [file join $author project.dict]
    write $manifest {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {flow flow.src} assets retirement.tcl}
    set entries [list [list [file join $::appcompiler::compilerDirectory driver.tcl] run $manifest]]
    if {$packed} {
        file copy [info nameofexecutable] [file join $delivery machteld.exe]
        set archive [file join $delivery flow.machteld]
        ::appcompiler::project::pack $manifest $archive
        set rebuilt [file join $delivery rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        lappend entries [list $archive] [list $rebuilt]
    }
    foreach args $entries {
        set host [info nameofexecutable]
        if {[llength $args] == 1} {
            set host [file join $delivery machteld.exe]
            set original [file join $author bin {byte helper.exe}]
            if {[file exists $original]} {file rename $original [file join $author bin retired.exe]}
        }
        set launched [::machteld::run -dir $work -stdin [binary decode hex 4aff004b] -timeout 15s -- $host {*}$args $script echo]
        equal [list [dict get $launched exit] [dict get $launched err]] {0 {}} "source or relocated archive runs"
        equal [string trim [dict get $launched out]] {error 17 4aff004b 00ffc328} "terminal status and separate raw bytes"
        set retired [::machteld::run -dir $work -timeout 15s -- $host {*}$args --retirement $script]
        equal [list [dict get $retired exit] [dict get $retired err] [string trim [dict get $retired out]]] {0 {} ok} "self-cancel and self-close faults and an independent stream"
    }
}
if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set work [file normalize [file tempdir]]
try {
    set exe [file join $work {stream helper.exe}]
    file copy [info nameofexecutable] $exe
    set childScript [file join $work {child program.tcl}]
    ::streamTest::write $childScript $::streamTest::fixture
    set modules [dict create flow $::streamTest::source]
    ::streamTest::equal [::appcompiler::check $modules] {} "stream source checks"
    namespace eval :: [dict get [::appcompiler::compile $modules ::typedStream] script]
    ::streamTest::exercise $exe $childScript
    ::streamTest::invalid $exe $work
    ::streamTest::portable $work $childScript [expr {$argv eq "-pack"}]
} finally {file delete -force -- $work}
puts "application compiler streams: $::streamTest::checks assertions passed"
