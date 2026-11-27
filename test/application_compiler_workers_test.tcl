package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::workerTest {
    variable checks 0
    variable typed {export record .request {
    text: text
    raw: bytes
    child: int
    delay: int
}
extern fn .pause($ms: int) -> unit = ['::after']
extern fn .pid() -> int = ['::pid']
extern fn .abnormal($mode: text) -> unit = ['::workFixture::perform'] from 'work-fixture'
export worker .lookup($q: .request) -> result<.request,problem> {
    $ignored ::= .pause($q.delay)
    return ok($q with {child = .pid()})
}
export fn .start_local($q: .request) -> task<.request> => start .lookup($q)
export fn .start_app($q: .request) -> task<.request> => start_app .lookup($q)
export fn .finish($task: task<.request>) -> result<.request,problem> => await($task)
export fn .stop($task: task<.request>) -> unit => cancel($task)
worker .variant($mode: text) -> result<text,problem> {
    $ignored ::= .abnormal($mode)
    if $mode == 'domain' {return err(problem('invalid value'))}
    return ok($mode)
}
export fn .variant_result($mode: text) -> result<text,problem> => await(start .variant($mode))
record .query {
    database: text
    id: text
}
record .station { label: text }
worker .station_by_id($q: .query) -> result<.station,problem> =>
    sql_one<.station>($q.database, 'SELECT label FROM stations WHERE id=?1', $q.id)
export fn .read_station($q: .query) -> result<.station,problem> => await(start .station_by_id($q))
distinct .code = text
distinct .gain = binary64
record .observation {
    id: .code
    value: .gain
}
record .pair {
    left: .observation
    right: .observation
}
worker .ordered($q: .pair) -> result<list<.observation>,problem> {
    if $q.left.id <= $q.right.id {return ok([$q.left, $q.right])}
    return ok([$q.right, $q.left])
}
export fn .observations($q: .pair) -> result<list<.observation>,problem> => await(start .ordered($q))
tool .local_host = 'machteld.exe'
worker .sibling($input: unit) -> result<text,problem> => .local_host()
export fn .host_path() -> result<text,problem> => await(start .sibling(unit))
}
}

proc ::workerTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::workerTest::bad {source code} {
    set report [::appcompiler::check [dict create test $source]]
    equal [expr {$code in [lmap issue $report {dict get $issue code}]}] 1 "$code in $report"
}

proc ::workerTest::staticChecks {} {
    variable typed
    equal [::appcompiler::check [dict create jobs $typed]] {} "worker/body/call signatures"
    bad {worker .w($v: int) -> int => $v} WORKER_SIGNATURE
    bad {worker .w<.t>($v: .t) -> result<.t,problem> => ok($v)} WORKER_SIGNATURE
    bad {worker .w($v: text) -> result<text,problem> => ok($v)
fn .illegal() -> result<text,problem> => .w('x')} WORKER_REQUIRED
    bad {fn .f($v: int) -> int => $v
fn .bad() -> task<int> => start .f(1)} WORKER_REQUIRED
    bad {worker .w($v: text) -> result<text,problem> => ok($v)
fn .bad() -> task<text> => start .w(7)} ARGUMENT_TYPE
    bad {fn .bad() -> result<int,problem> => await(7)} TASK_REQUIRED
    bad {record .message { pending: list<task<text>> }
worker .w($v: .message) -> result<int,problem> => ok(1)} WORKER_MESSAGE
    set nested {record .cell<.v> {data: .v}
choice .response {found(.cell<list<task<text>>>)}
worker .bad($value: int) -> result<.response,problem> => err(problem('empty'))}
    bad $nested WORKER_MESSAGE
    foreach local {ref<int> callable<int,text> task<int>} {
        bad [string map [list LOCAL $local] {record .leaf { value: LOCAL }
choice .envelope { send(list<.leaf>) }
worker .bad($v: map<text,.envelope>) -> result<int,problem> => ok(1)}] WORKER_MESSAGE
        bad [string map [list LOCAL $local] {record .box<.v> {value: .v?}
worker .bad($key: text) -> result<list<.box<LOCAL>>,problem> => err(problem('bad'))}] WORKER_MESSAGE
    }
    bad {worker .lookup($id: text) -> result<text,problem> => ok($id)
fn .bad() -> callable<text,result<text,problem>> => .lookup} WORKER_REQUIRED
    set localWorld [dict create resources {} runtimeSchemas [dict create widget_token {distinct text}]]
    equal [::appcompiler::checker::workerData list<widget_token> $localWorld] 0 "host capabilities require explicit wire support"
    bad {distinct .cursor = text
fn .close($c: .cursor) -> unit => unit
resource .cursor using .close
record .box<.item> { data: list<.item> }
worker .w($v: .box<.cursor>) -> result<int,problem> => ok(1)} WORKER_MESSAGE
    set artifact [::appcompiler::compile [dict create jobs $typed] ::workerChecks]
    namespace eval :: [dict get $artifact script]
    set rt ::workerChecks::@rt
    set data [dict create text "037\n雪" raw [binary format H* 00ff80] child 0 delay 0]
    set frame [${rt}::workerEncode .jobs::request $data]
    equal [${rt}::workerDecode .jobs::request $frame] $data "schema-bound round trip"
    equal [catch {${rt}::workerDecode text $frame}] 1 "wrong reply schema"
    equal [catch {${rt}::workerDecode text X1.!!!!}] 1 "malformed typed frame"
    equal [catch {${rt}::workerEncode list<int> {1 2}}] 1 "unregistered descriptor refused even for valid data"
    equal [catch {${rt}::workerEncode task<text> handle}] 1 "runtime refuses process-local descriptor"
    foreach type {ref<int> callable<int,text> list<ref<int>>} {
        equal [catch {${rt}::workerEncode $type {local-token}}] 1 "wire registry rejects $type"
    }
    foreach display {3 12 17 24} {
        foreach {bits canonical} {
            3ff0000000000001 1.0000000000000002
            7fefffffffffffff 1.7976931348623157e+308
            0000000000000001 4.9406564584124654e-324
            400921fb54442d18 3.1415926535897931
        } {
            binary scan [binary decode hex $bits] Q number
            # Displaying a value can request fewer digits than a wire round trip.
            set shown [format %.*g $display $number]
            set row [dict create id 007 value $number]
            set wire [${rt}::workerEncode .jobs::pair [dict create left $row right $row]]
            set encoded [encoding convertfrom -profile strict utf-8 [binary decode base64 [string range $wire 3 end]]]
            equal [dict get [lindex $encoded 1] left value] $canonical "canonical .gain when displayed as $shown"
            set result [${rt}::workerDecode .jobs::pair $wire]
            equal [binary encode hex [binary format Q [dict get $result left value]]] $bits "stable .gain bits at $display"
        }
    }
    equal [catch {${rt}::workerEncode .jobs::request [dict merge $data {extra handle}]}] 1 "undeclared field"
    equal [catch {${rt}::workerEncode .jobs::request [concat $data {child 7}]}] 1 "repeated field"
    equal [catch {::workerChecks::jobs::start_local $data} message opts] 1 "window-bound start needs a managed handler"
    equal [dict get $opts -errorcode] {APPCOMPILER WORKER CONTEXT} "unowned work cannot silently outlive a window"
    namespace eval $rt {
        variable tags {.fixture Toplevel all}
        variable binding {}
        proc winfo {op w} {if {$op eq "exists"} {return 1}; return $w}
        proc bindtags {w args} {variable tags; if {[llength $args]} {set tags [lindex $args 0]}; return $tags}
        proc bind {tag event script} {variable binding; set binding $script}
    }
    set owner [${rt}::workerControl window .fixture]
    equal [${rt}::workerControl window .fixture] $owner "one owner per window generation"
    set hook [set ${rt}::binding]
    namespace eval :: [string map {%W .fixture.child} $hook]
    equal [${rt}::workerControl window .fixture] $owner "child destruction leaves toplevel alive"
    namespace eval :: [string map {%W .fixture} $hook]
    equal [set ${rt}::binding] {} "closing removes the private Destroy binding"
    equal [set ${rt}::tags] {.fixture Toplevel all} "original bindtags restored"
    equal [expr {$owner ne [${rt}::workerControl window .fixture]}] 1 "recreated window gets a distinct scope"
}

proc ::workerTest::write {base path contents} {
    ::appcompiler::project::stageBytes [file join $base $path] [encoding convertto utf-8 $contents]
}

# This Tcl entry represents a window's handlers. Its headless owner follows
# the identical close path used by the Tk Destroy binding.
proc ::workerTest::entry {} {
    return {
proc assert {value message} {if {!$value} {error $message}}
proc submit {scope request} {
    set ::task [::application::jobs::$scope $request]
    try {
        set ::answer [::application::jobs::finish $::task]
        incr ::delivered
    } finally {incr ::unwound}
}
proc waitFor {name} {
    if {[info exists $name]} return
    vwait $name
}
proc timeout {} {puts stderr {worker test timed out}; exit 3}
after 15000 timeout
set data [dict create text "雪 007\n{\u0000}" raw [binary format H* 00ff80] child 0 delay 150]
set mode [lindex $argv 0]
set owner [::application::workers owner]
set delivered 0
set unwound 0
after 0 {set ::tick 1}
if {$mode eq "ordered"} {
    ::application::workers handle $owner apply [list {} {
        binary scan [binary decode hex 3ff0000000000001] Q aboveOne
        binary scan [binary decode hex 0000000000000001] Q subnormal
        assert [expr {[format %.3g $aboveOne] eq "1"}] {fixture no longer distinguishes display and wire digits}
        set pair [dict create left [dict create id 7 value $subnormal] right [dict create id 007 value $aboveOne]]
        set ::answer [::application::jobs::observations $pair]
    }]
    waitFor ::answer
    lassign $answer tag rows
    assert [expr {$tag eq "ok"}] "worker order failed: $rows"
    set ids [lmap row $rows {dict get $row id}]
    set bits [lmap row $rows {binary encode hex [binary format Q [dict get $row value]]}]
    assert [expr {$ids eq {007 7} && $bits eq {3ff0000000000001 0000000000000001}}] "worker order/measurements changed: $ids $bits"
    puts ok
    return
}
if {$mode eq "sibling"} {
    ::application::workers handle $owner apply [list {} {set ::answer [::application::jobs::host_path]}]
    waitFor ::answer
    set base [file dirname $::argv0]
    if {[file extension $::argv0] eq ".tcl"} {set base [file dirname $base]}
    assert [expr {$answer eq [list ok [file join $base machteld.exe]]}] "worker sibling lookup returned $answer"
    puts ok
    return
}
if {$mode eq "sql"} {
    ::application::workers handle $owner apply [list {} {
        set ::answer [::application::jobs::read_station [dict create database [file join [pwd] observations.db] id 007]]
    }]
    waitFor ::answer
    assert [expr {$answer eq {ok {label West}}}] "typed SQL worker returned $answer"
    puts ok
    return
}
if {$mode in {fault domain malformed exited limit native_limit deadline}} {
    if {$mode eq "deadline"} {::application::workers timeout 200}
    set control [expr {$mode eq "limit" ? [string repeat x 66000] : $mode}]
    ::application::workers handle application apply [list {arg} {set ::answer [::application::jobs::variant_result $arg]}] $control
    waitFor ::answer
    lassign $answer tag details
    assert [expr {$tag eq "err"}] "worker fault became success: $mode"
    if {$mode eq "domain"} {
        assert [expr {[dict get $details message] eq "invalid value"}] {domain error lost its message}
    } else {
        set expect [dict get {fault WORKER_FAULT malformed WORKER_PROTOCOL exited WORKER_FAILED limit WORKER_LIMIT native_limit WORKER_LIMIT deadline WORKER_FAILED} $mode]
        assert [expr {[dict get $details code] eq $expect}] "expected $expect from $mode, got $details"
        if {$mode eq "fault"} {assert [dict exists $details origin line] {worker fault lost source location}}
    }
    puts ok
    return
}
::application::workers handle $owner submit [expr {$mode in {detached late} ? "start_app" : "start_local"}] $data
assert [expr {[llength [::machteld::child list]] == 1}] {start must launch exactly one supervised child}
switch -- $mode {
    normal {
        waitFor ::answer
        assert [info exists ::tick] {owner event loop was blocked}
        lassign $answer tag result
        assert [expr {$tag eq "ok"}] "worker failed: $result"
        assert [expr {[dict get $result child] != [pid]}] {worker executed in parent}
        assert [expr {[dict get $result text] eq [dict get $data text]}] {text did not round trip}
        assert [expr {[binary encode hex [dict get $result raw]] eq "00ff80"}] {bytes did not round trip}
    }
    cancel {
        ::application::jobs::stop $task
        assert [expr {![llength [::machteld::child list]]}] {explicit cancel left a supervised child running}
        waitFor ::answer
        assert [expr {[lindex $answer 0] eq "err" && [dict get [lindex $answer 1] code] eq "WORKER_CANCELED"}] {explicit cancellation lost}
    }
    close - detached - late {
        if {$mode eq "late"} {
            # Close after a real reply queued its idle delivery, before the
            # coroutine resumes. The surviving scope can still consume it.
            proc closeReady {args} {::application::workers close $::owner; set ::closed 1}
            trace add execution ::machteld::compiledApplication::@rt::workerReady leave closeReady
            waitFor ::closed
            trace remove execution ::machteld::compiledApplication::@rt::workerReady leave closeReady
        } else {::application::workers close $owner}
        if {$mode eq "close"} {assert [expr {![llength [::machteld::child list]]}] {window closed without releasing its native child}}
        if {$mode eq "detached"} {assert [expr {[llength [::machteld::child list]] == 1}] {window close canceled application-owned work}}
        assert [expr {$unwound == 1 && $delivered == 0}] {closed handler resumed or failed to unwind}
        if {$mode in {detached late}} {
            ::application::workers handle application apply [list {task} {set ::other [::application::jobs::finish $task]}] $task
            waitFor ::other
            assert [expr {[lindex $other 0] eq "ok"}] "application task failed: $other"
        }
        after 350 {set ::settled 1}
        waitFor ::settled
        assert [expr {$delivered == 0}] {late UI delivery}
    }
}
puts ok
}
}

proc ::workerTest::run {cwd prefix mode {host {}}} {
    if {$host eq {}} {set host [info nameofexecutable]}
    set r [::machteld::run -dir $cwd -stdin {} -timeout 22s -- $host {*}$prefix $mode]
    equal [list [dict get $r status] [dict get $r exit] [string trim [dict get $r out]] [string trim [dict get $r err]]] \
        {ok 0 ok {}} "worker $mode"
}

proc ::workerTest::exercise {tmp packed} {
    variable typed
    set author [file join $tmp author]
    set elsewhere [file join $tmp caller]
    file mkdir $author $elsewhere
    file copy -- [info nameofexecutable] [file join $author machteld.exe]
    package require sqlite3
    sqlite3 ::workerTest::db [file join $elsewhere observations.db]
    try {
        db eval {CREATE TABLE stations(id TEXT PRIMARY KEY, label TEXT);
            INSERT INTO stations VALUES('007','West'),('7','East')}
    } finally {db close}
    set manifestBody {schema 1 edition 1 minApi 30 tclEntry ui/main.tcl modules {jobs jobs.src}
assets {lib/pkgIndex.tcl lib/work-fixture.tcl}
packageDirs {lib}}
    write $author project.dict $manifestBody
    write $author lib/pkgIndex.tcl {package ifneeded work-fixture 1.0 [list source -encoding utf-8 [file join $dir work-fixture.tcl]]}
    write $author lib/work-fixture.tcl {namespace eval ::workFixture {}
proc ::workFixture::perform {mode} {
    switch -- $mode {
        fault {error {fixture error}}
        exited {exit 17}
        malformed {puts stdout {{"id":0,"ok":1,"result":"wrong-schema"}}; flush stdout; after 5000}
        native_limit {puts stdout [string repeat x 90020]; flush stdout; after 5000}
        deadline {after 5000}
    }
    return {}
}
package provide work-fixture 1.0}
    write $author ui/main.tcl [entry]
    write $author jobs.src $typed
    set manifest [file join $author project.dict]
    set driver [file join $::appcompiler::compilerDirectory driver.tcl]
    set modes {normal cancel close detached late sql ordered sibling domain fault malformed exited limit native_limit deadline}
    foreach mode $modes {run $elsewhere [list $driver run $manifest] $mode}
    set cliManifest [file join $author console.dict]
    write $author console.dict [string map {{tclEntry ui/main.tcl} {entry {cli main}} {jobs jobs.src} {jobs jobs.src cli cli.src}} $manifestBody]
    write $author cli.src {import jobs
worker .identity($v: text) -> result<text,problem> => ok($v)
fn .main($args: list<text>) -> result<unit,problem> {
    $value ::= await(start .identity('ok'))?
    return write_stdout_utf8($value)
}}
    run $elsewhere [list $driver run $cliManifest] {}
    if {!$packed} return
    set recipient [file join $tmp {copied 雪}]
    file mkdir $recipient
    set deliveredHost [file join $recipient machteld.exe]
    file copy -- [info nameofexecutable] $deliveredHost
    set archive [file join $recipient renamed.machteld]
    ::appcompiler::project::pack $manifest $archive
    set page [::appcompiler::reference::query $archive get fn/jobs/lookup]
    equal [expr {[string first {export worker .lookup($q: .request) -> result<.request,problem>} $page] >= 0}] 1 "offline worker declaration"
    set cliArchive [file join $recipient console.machteld]
    ::appcompiler::project::pack $cliManifest $cliArchive
    file rename -- $author [file join $tmp hidden-source]
    foreach mode $modes {run $elsewhere [list $archive] $mode $deliveredHost}
    run $elsewhere [list $cliArchive] {} $deliveredHost
}

if {$argv ni {{} -pack -check}} {error {expected -pack, -check, or no arguments}}
::workerTest::staticChecks
if {$argv ne "-check"} {
    set tmp [file normalize [file tempdir]]
    try {::workerTest::exercise $tmp [expr {$argv eq "-pack"}]} finally {
        if {[file normalize $tmp] eq $tmp && [file dirname $tmp] ne $tmp} {file delete -force -- $tmp}
    }
}
puts "application compiler workers: $::workerTest::checks assertions passed"
