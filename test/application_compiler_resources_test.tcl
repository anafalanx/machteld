package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::resourceTest {
    variable checks 0
    variable events {}
    variable library {export distinct .handle = text
resource .handle using .close
export extern fn .open($name: text) -> result<.handle,problem> = ['::resourceTest::acquire']
extern fn .release_native($h: .handle) -> result<unit,problem> = ['::resourceTest::release']
fn .close($h: .handle) -> result<unit,problem> {
    return .release_native($h)
}
export distinct .plain = text
resource .plain using .plain_close
export extern fn .custom_open($name: text) -> result<.plain,text> = ['::resourceTest::acquire']
extern fn .plain_close($h: .plain) -> unit = ['::resourceTest::plainRelease']
export record .box<.t> { value: .t }
resource .box using .drop
export fn .borrow<.t>($box: .box<.t>) -> result<.box<.t>,problem> => ok($box)
extern fn .inspect<.t>($value: .t) -> .t = ['::resourceTest::inspect']
fn .drop<.t>($box: .box<.t>) -> unit {
    $checked ::= .inspect($box.value)
    return unit
}}
    variable consumer {import handles
alias .lease = .handles::handle
extern fn .mark($text: text) -> unit = ['::resourceTest::mark']
extern fn .crash() -> unit = ['::resourceTest::crash']
fn .fail() -> result<unit,problem> => err(problem('propagated'))
fn .alias($name: text) -> result<.lease,problem> => .handles::open($name)
export fn .nested($outer: text, $inner: text, $mode: text) -> result<text,problem> {
    using $a ::= .alias($outer)? {
        using $b ::= .handles::open($inner)? {
            .mark('body')
            if $mode == 'early' { return ok('early') }
            if $mode == 'typed' { return err(problem('body problem')) }
            if $mode == 'propagated' { .fail()? }
            if $mode == 'fault' { .crash() }
        }
        .mark('between')
    }
    return ok('done')
}
export fn .generic<.t>($box: .handles::box<.t>) -> result<.t,problem> {
    using $resource ::= .handles::borrow($box)? { return ok($resource.value) }
}
export fn .custom($closer: text) -> result<int,text> {
    using $handle ::= .handles::custom_open($closer)? { return err('007') }
}
export fn .cross_loops($closer: text) -> result<unit,problem> {
    for .outer $index in 0..3 {
        using $a ::= .handles::open('outer')? {
            for $column in 0..2 {
                using $b ::= .handles::open($closer)? {
                    if $index == 0 { continue .outer }
                    break .outer
                }
            }
        }
    }
    return ok(unit)
}
export fn .local_loops() -> result<unit,problem> {
    for $index in 0..3 {
        using $a ::= .handles::open('local')? {
            if $index == 0 { continue }
            break
        }
    }
    return ok(unit)
}}
}

proc ::resourceTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}
proc ::resourceTest::acquire {name} {
    variable events
    lappend events "open:$name"
    if {$name eq "fail-open"} {return [list err [dict create code OPEN message {opening failed}]]}
    return [list ok $name]
}
proc ::resourceTest::release {name} {
    variable events
    lappend events "close:$name"
    if {[string match typed-* $name]} {return [list err [dict create code CLOSE message $name]]}
    if {[string match fault-* $name]} {return -code error -errorcode {RESOURCE FIXTURE CLOSE} $name}
    return [list ok {}]
}
proc ::resourceTest::plainRelease {name} {
    release $name
    return
}
proc ::resourceTest::mark {value} {
    variable events
    lappend events $value
    return
}
proc ::resourceTest::inspect {value} {
    mark "inspect:$value"
    return $value
}
proc ::resourceTest::crash {} {return -code error -errorcode {RESOURCE FIXTURE BODY} {body exception}}
proc ::resourceTest::unlocated {command operation} {error "unlocated Tcl fault"}

proc ::resourceTest::lineOf {source fragment} {
    set index 0
    foreach line [split $source \n] {
        incr index
        if {[string first $fragment $line] >= 0} {return $index}
    }
    error "fixture line absent: $fragment"
}
proc ::resourceTest::static {} {
    foreach {code source} {
        RESOURCE_REQUIRED {fn .f() -> result<unit,problem> {
            using $x ::= ok(7)? { return ok(unit) }
        }}
        RESOURCE_TYPE {alias .a = text
            resource .a using .close
            fn .close($h: .a) -> unit => unit}
        RESOURCE_CLOSER {distinct .a = text
            resource .a using .close
            fn .close($h: text) -> unit => unit}
        RESOURCE_DUPLICATE {distinct .a = text
            resource .a using .close
            resource .a using .close
            fn .close($h: .a) -> unit => unit}
    } {
        set errors [::appcompiler::check [dict create sample $source]]
        equal [expr {$code in [lmap d $errors {dict get $d code}]}] 1 "expected diagnostic $code, got $errors"
    }
}

proc ::resourceTest::direct {} {
    variable library
    variable consumer
    variable events
    set sources [dict create handles $library app $consumer]
    set artifact [::appcompiler::compile $sources ::scopeApp]
    namespace eval :: [dict get $artifact script]
    foreach {mode want trace} {
        normal {ok done} {open:A open:B body close:B between close:A}
        early {ok early} {open:A open:B body close:B close:A}
    } {
        set events {}
        equal [::scopeApp::app::nested A B $mode] $want "$mode return"
        equal $events $trace "$mode cleanup order"
    }
    foreach {outer inner want} {
        fail-open ignored {open:fail-open}
        A fail-open {open:A open:fail-open close:A}
    } {
        set events {}
        lassign [::scopeApp::app::nested $outer $inner normal] tag body
        equal [list $tag [dict get $body code]] {err OPEN} "acquisition failure"
        equal $events $want "acquisition registers cleanup only after success"
    }
    foreach {mode message site} {
        typed {body problem} {if $mode == 'typed'}
        propagated propagated {fn .fail()}
    } {
        set events {}
        lassign [::scopeApp::app::nested fault-outer typed-inner $mode] tag body
        equal [list $tag [dict get $body message]] [list err $message] "$mode primary result"
        equal [dict get $body origin line] [lineOf $consumer $site] "$mode original source"
        set secondary [dict get $body cleanupFailures]
        equal [lmap detail $secondary {dict get $detail message}] {typed-inner fault-outer} "both cleanup failures retained"
        equal [lmap detail $secondary {dict get $detail code}] {CLOSE CLEANUP_FAULT} "cleanup kinds"
        equal [dict get [lindex $secondary 1] errorCode] {RESOURCE FIXTURE CLOSE} "Tcl cleanup error code"
        equal [lmap detail $secondary {dict get $detail origin module}] {handles handles} "cleanup origins"
        equal $events {open:fault-outer open:typed-inner body close:typed-inner close:fault-outer} "both closers run exactly once"
    }
    set status [catch {::scopeApp::app::nested typed-outer fault-inner fault} message options]
    equal [list $status $message [dict get $options -errorcode]] {1 {body exception} {RESOURCE FIXTURE BODY}} "body exception preserved"
    equal [dict get $options -appcompilerlocation line] [lineOf $consumer {extern fn .crash(}] "body exception location"
    equal [lmap detail [dict get $options -appcompilercleanup] {dict get $detail message}] \
        {fault-inner typed-outer} "body exception carries both cleanup failures"
    # Tcl extensions and interpreter traces can fail before the called
    # procedure starts, without attaching any application source location.
    trace add execution ::scopeApp::app::mark enter ::resourceTest::unlocated
    try {
        equal [catch {::scopeApp::app::nested A typed-inner normal} message options] 1 "raw body fault"
        equal $message "unlocated Tcl fault" "raw fault message survives both scopes"
        set where [::scopeApp::@rt::mappedLocation $options [dict get $artifact sourceMap]]
        equal [list [dict get $where module] [dict get $where line]] \
            [list app [lineOf $consumer {.mark('body')}]] "raw fault maps to its body expression"
    } finally {trace remove execution ::scopeApp::app::mark enter ::resourceTest::unlocated}
    trace add execution ::scopeApp::handles::close enter ::resourceTest::unlocated
    try {
        equal [catch {::scopeApp::app::nested A B early} message options] 1 "raw closer fault"
        set where [::scopeApp::@rt::mappedLocation $options [dict get $artifact sourceMap]]
        equal [list [dict get $where module] [dict get $where line]] \
            [list app [lineOf $consumer {using $b}]] "a call fault at finalization maps to its using statement"
    } finally {trace remove execution ::scopeApp::handles::close enter ::resourceTest::unlocated}
    trace add execution ::scopeApp::handles::release_native enter ::resourceTest::unlocated
    try {
        lassign [::scopeApp::app::nested A B typed] tag primary
        equal [list $tag [dict get $primary message]] {err {body problem}} "primary body failure still wins"
        set where [dict get [lindex [dict get $primary cleanupFailures] 0] origin]
        equal [list [dict get $where module] [dict get $where line]] \
            [list handles [lineOf $library {return .release_native($h)}]] "secondary raw cleanup fault maps inside the closer"
        equal [catch {::scopeApp::app::nested A B early} message options] 1 "standalone raw failure inside closer"
        equal [dict get $options -appcompilerlocation] $where "standalone and secondary closer faults have identical origins"
    } finally {trace remove execution ::scopeApp::handles::release_native enter ::resourceTest::unlocated}
    foreach mode {normal early} {
        lassign [::scopeApp::app::nested A typed-inner $mode] tag body
        equal [list $tag [dict get $body code] [dict get $body message]] {err CLOSE typed-inner} "failed closer overrides $mode success"
        equal [dict get $body origin line] [lineOf $library {extern fn .release_native(}] "closer original location"
    }
    equal [catch {::scopeApp::app::nested A fault-inner early} message options] 1 "faulty closer overrides success"
    equal [dict get $options -errorcode] {RESOURCE FIXTURE CLOSE} "closer retains its Tcl code"
    set events {}
    equal [::scopeApp::app::generic text [dict create value 007]] {ok 007} "generic scope preserves concrete type"
    equal $events {inspect:007} "private generic closer gets correctly typed payload"
    equal [::scopeApp::app::custom normal] {err 007} "unit closer preserves a custom error value"
    equal [catch {::scopeApp::app::custom fault-plain} message options] 1 "unexpected closer fault surfaced"
    equal [dict get $options -appcompilerprimary] {err 007} "custom error payload survives in fault options"
    equal [dict get $options -errorcode] {RESOURCE FIXTURE CLOSE} "fault options preserve native code"
    set events {}
    equal [::scopeApp::app::cross_loops inner] {ok {}} "labelled loop control"
    equal $events {open:outer open:inner close:inner close:outer open:outer open:inner close:inner close:outer} "cleanup along each labelled jump"
    set events {}
    equal [::scopeApp::app::local_loops] {ok {}} "unlabelled loop control"
    equal $events {open:local close:local open:local close:local} "cleanup along ordinary loop exits"
    set events {}
    lassign [::scopeApp::app::cross_loops typed-loop] tag body
    equal [list $tag [dict get $body code]] {err CLOSE} "cleanup failure takes precedence over outer continue"
    equal $events {open:outer open:typed-loop close:typed-loop close:outer} "remaining nested resources close"
}

proc ::resourceTest::packed {} {
    set tmp [file normalize [file tempdir]]
    try {
        set root [file join $tmp author]
        set delivery [file join $tmp delivery]
        file mkdir $root $delivery
        set source {distinct .channel = text
            resource .channel using .close
            extern fn .open($path: text) -> result<.channel,problem> = ['::open_file']
            extern fn .close($h: .channel) -> unit = ['::close']
            extern fn .line($h: .channel) -> text = ['::gets']
            export fn .first($path: text) -> result<text,problem> {
                using $h ::= .open($path)? { return ok(.line($h)) }
            }}
        set main {package require machteld
            chan configure stdout -translation lf -encoding utf-8
            proc ::open_file {path} {return [list ok [set ::opened [open $path rb]]]}
            set path [lindex $argv 0]
            set answer [::application::files::first $path]
            if {$::opened in [chan names]} {error "channel still open after return"}
            puts $answer}
        foreach {name data} [list project.dict {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {files files.src}} \
                files.src $source main.tcl $main] {
            ::appcompiler::project::stageBytes [file join $root $name] [encoding convertto utf-8 $data]
        }
        set app [file join $delivery read.machteld]
        ::appcompiler::project::pack [file join $root project.dict] $app
        file rename $root [file join $tmp retired]
        set executable [file join $delivery machteld.exe]
        file copy [info nameofexecutable] $executable
        set data [file join $tmp example.txt]
        ::appcompiler::project::stageBytes $data "007\nsecond\n"
        set rebuilt [file join $delivery rebuilt.machteld]
        ::appcompiler::project::rebuild $app $rebuilt
        foreach archive [list $app $rebuilt] {
            set result [::machteld::run -dir $delivery -timeout 30s -- $executable $archive $data]
            equal [dict get $result exit] 0 "relocated reader exit: [dict get $result err]"
            equal [dict get $result out] "ok 007\n" "file contents and close on early return"
        }
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::resourceTest::static
::resourceTest::direct
if {$argv eq "-pack"} {::resourceTest::packed}
puts "application compiler scoped resources: $::resourceTest::checks assertions passed"
