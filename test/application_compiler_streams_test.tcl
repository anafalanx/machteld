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
    wait {after 5000}
}}
    variable entry {package require machteld
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
            throw {error "consumer fault"}
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
    if {$::streamTest::action eq "terminal_fault"} {error "terminal consumer fault"}
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

    reset terminal_fault
    set oldHandler [interp bgerror {}]
    try {
        interp bgerror {} ::streamTest::background
        start $exe [list $script echo] {} 65536 5000
        finish
        equal [string match {*terminal consumer fault*} [waitFor ::streamTest::backgroundMessage]] 1 "terminal callback fault reaches the background handler"
        equal [list $terminals [::machteld::child list]] {1 {}} "terminal callback fault does not leak or retry"
    } finally {interp bgerror {} $oldHandler}
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
proc ::streamTest::portable {work script packed} {
    variable source
    variable entry
    set author [file join $work author]
    set delivery [file join $work {recipient 雪}]
    foreach dir [list $author $delivery] {
        file mkdir [file join $dir bin]
        file copy [info nameofexecutable] [file join $dir bin {byte helper.exe}]
    }
    write [file join $author flow.src] $source
    write [file join $author main.tcl] $entry
    set manifest [file join $author project.dict]
    write $manifest {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {flow flow.src}}
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
