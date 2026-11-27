package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::sharedTest {
    variable count 0
    variable library {export fn .observe<.t>($r: ref<.t>) -> .t => ref_get($r)
export fn .write<.t>($r: ref<.t>, $value: .t) -> unit => ref_set($r, $value)
export fn .id<.t>($v: .t) -> .t => $v
export fn .read_later<.t>($r: ref<.t>) -> callable<.t> => bind(.observe<.t>, $r)
}
    variable client {import library
extern fn .register($r: ref<text>, $snapshot: callable<text>, $live: callable<text>) -> text = ['::register']
extern fn .save($r: ref<int>) -> unit = ['::save']
extern fn .fail() -> text = ['::fail']
record .row { state: ref<text> }
choice .link { empty
    next(ref<.link>) }
fn .call($f: callable<text>) -> text => $f()
fn .captions() -> text {
    using $state ::= ref('draft') {
        $snapshot ::= bind(.library::id<text>, ref_get($state))
        $live ::= .library::read_later($state)
        ref_set($state, 'final')
        return $"${$snapshot()} / ${$live()}"
    }
}
example .captions() => 'draft / final'
export fn .run($before: text) -> text {
    using $state ::= ref($before) {
        $fixed ::= bind(.library::id<text>, ref_get($state))
        $live ::= bind(.call, .library::read_later($state))
        .library::write($state, 'new')
        return .register($state, $fixed, $live)
    }
}
export fn .same() -> bool {
    using $a ::= ref(1) {
        using $b ::= ref(1) {
            if ref_same($a, $b) { return false }
            return ref_same(.library::id($a), $a)
        }
    }
}
export fn .cycle() -> bool {
    using $a ::= ref(.link::empty) {
        ref_set($a, .link::next($a))
        return match ref_get($a) {
            .link::empty => false
            .link::next($alias) => ref_same($a, $alias)
        }
    }
}
export fn .generic<.t>($v: .t) -> .t {
    using $r ::= ref<.t>($v) {return ref_get($r)}
}
export fn .stale() -> ref<int> {
    using $r ::= ref(1) {return $r}
}
export fn .use_stale() -> int => ref_get(.stale())
export fn .optional() -> text? {
    using $r ::= ref<text?>(none) {
        ref_set($r, some('007'))
        return ref_get($r)
    }
}
export fn .nested() -> text {
    using $outer ::= ref('old') {
        using $inner ::= ref($outer) {
            ref_set(ref_get($inner), 'new')
        }
        return ref_get($outer)
    }
}
export fn .loop() -> int {
    for $i in 0..100 {
        using $r ::= ref($i) {
            if $i == 3 { break }
            continue
        }
    }
    return 3
}
export fn .error() -> text {
    using $r ::= ref(6) { return .fail() }
}
export fn .failed() -> result<text,problem> {
    using $r ::= ref(7) {
        .save($r)
        $v ::= .problem()?
        return ok('success')
    }
}
fn .problem() -> result<int,problem> => err(problem('failed'))
export fn .encode($r: ref<text>) -> result<text,problem> {
    return encode_json(.row_from($r))
}
extern fn .row_from($r: ref<text>) -> .row = ['::rowFrom']
export fn .decode($json: text) -> result<.row,problem> => decode_json<.row>($json)
fn .main($args: list<text>) -> result<unit,problem> {
    using $r ::= ref('old') {
        $f ::= .library::read_later($r)
        ref_set($r, '007')
        return write_stdout_utf8($f())
    }
}}
}

proc ::sharedTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}

proc ::sharedTest::rejected {script code label} {
    equal [catch {uplevel 1 $script} message options] 1 $label
    equal [dict get $options -errorcode] $code $label
}

proc ::sharedTest::bad {source code} {
    set diagnostics [::appcompiler::check [dict create sample $source]]
    equal [lmap d $diagnostics {dict get $d code}] $code "diagnostic for $source"
}

# Run the same delivery mechanism available to Tk while staying headless.
proc ::register {state fixed live} {
    set ::saved $state
    set ::live $live
    after idle [list ::onIdle $state $fixed $live]
    vwait ::observed
    return $::observed
}
proc ::onIdle {state fixed live} {
    try {
        set snapshot [{*}$fixed]
        set first [{*}$live]
        ::shared::library::write text $state later
        set second [{*}$live]
        set ::observed [list $snapshot $first $second]
    } on error {message options} {
        set ::observed [list failed $message]
    }
}
proc ::save {r} {set ::saved $r; return {}}
proc ::fail {} {error "expected failure"}
proc ::rowFrom {r} {return [dict create state $r]}

proc ::sharedTest::direct {} {
    variable library
    variable client
    set artifact [::appcompiler::compile [dict create entry $client library $library] ::shared]
    namespace eval :: [dict get $artifact script]
    set fault {APPCOMPILER REFERENCE EXPIRED}
    equal [::shared::entry::run 007] {007 new later} "snapshot and shared callbacks during event delivery"
    rejected {{*}$::live} $fault "escaped callback detects closed owner"
    rejected {::shared::library::observe text $::saved} $fault "expired Tcl ticket"
    equal [::shared::entry::same] 1 "distinct allocated cells and equal aliases"
    equal [::shared::entry::cycle] 1 "cell holds a reference to itself"
    equal [::shared::entry::optional] {some 007} "explicit element type for absent initial value"
    equal [::shared::entry::generic text 007] 007 "generic scope with concrete element type"
    equal [::shared::entry::nested] new "an inner cell can share an outer cell"
    equal [::shared::entry::loop] 3 "loop exits unwind reference owners"
    rejected {::shared::library::write int [::shared::entry::stale] 9} $fault "stale write faults"
    rejected {::shared::entry::use_stale} $fault "dereference of an escaped value faults inside X"
    equal [catch {::shared::entry::error}] 1 "foreign fault unwinds owner"
    equal [lindex [::shared::entry::failed] 0] err "ordinary typed failure propagates"
    rejected {::shared::library::observe int $::saved} $fault "propagated failure closes owner"
    equal [array size ::shared::@rt::referenceCells] 0 "no cell retained after return, break, continue, fault or cycle"

    set other [interp create]
    try {
        namespace eval :: [dict get [::appcompiler::compile [dict create library $library] ::neighbor] script]
        interp alias $other ::machteld::hash {} ::machteld::hash
        $other eval [dict get $artifact script]
        $other eval {::shared::entry::same}
        proc ::register {r fixed live} {
            ::sharedTest::rejected {::shared::library::observe int $r} {APPCOMPILER ARGUMENT TYPE} "wrong concrete cell type"
            ::sharedTest::rejected {::shared::library::observe text abc} {APPCOMPILER ARGUMENT TYPE} "invalid ticket"
            ::sharedTest::rejected {::neighbor::library::observe text $r} {APPCOMPILER ARGUMENT TYPE} "different application in the same interpreter"
            set foreign $::foreignInterp
            ::sharedTest::rejected {$foreign eval [list ::shared::library::observe text $r]} {APPCOMPILER ARGUMENT TYPE} "cannot transfer a live ticket to an independent interpreter"
            lassign [::shared::entry::encode $r] tag problem
            ::sharedTest::equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} "JSON encoding rejects ref values"
            return ok
        }
        set ::foreignInterp $other
        equal [::shared::entry::run 007] ok "check refs while their owner is live"
    } finally {interp delete $other}
    lassign [::shared::entry::decode {{"state":"anything"}}] tag problem
    equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} "cannot import a reference from JSON"
    for {set i 0} {$i < 100} {incr i} {::shared::entry::cycle}
    equal [array size ::shared::@rt::referenceCells] 0 "repeated short-lived cycles release all entries"

    bad {fn .a() -> ref<int> => ref(1)} REF_SCOPE
    bad {fn .a() -> ref<int> => ref<int>(1)} REF_SCOPE
    bad {fn .a() -> int { using $r ::= ref(none) { return 0 } }} TYPE_INFERENCE
    bad {fn .a() -> int { using $r ::= ref<text>(2) { return 0 } }} ARGUMENT_TYPE
    bad {fn .a() -> int { using $r ::= ref<int,text>(2) { return 0 } }} TYPE_ARITY
    bad {fn .a() -> int { using $r ::= ref(1,2) { return 0 } }} CALL_ARITY
    bad {fn .a($r: ref<int,text>) -> unit => unit} TYPE_ARITY
    bad {fn .a($r: ref<int>) -> unit => ref_set($r,'abc')} ARGUMENT_TYPE
    bad {fn .a($r: int) -> unit => ref_set($r,2)} EXPECTED_REF
    bad {fn .a($r: ref<int>) -> int => ref_get($r,$r)} CALL_ARITY
    bad {fn .a($r: ref<int>, $s: ref<text>) -> bool => ref_same($r,$s)} ARGUMENT_TYPE
    bad {fn .a($r: ref<int>) -> bool => $r == $r} NOT_COMPARABLE
    bad {record .row { state: list<ref<int>> }
fn .a($r: .row) -> bool => $r == $r} NOT_COMPARABLE
    bad {record .row { state: ref<int> }
fn .a($p: text) -> result<.row,problem> => sql_one<.row>($p, 'SELECT 1 AS state')} SQL_FIELD_TYPE
    bad {fn .a($r: result<ref<int>,problem>) -> result<int,problem> {
    using $borrowed ::= $r? {return ok(1)}
}} REF_SCOPE
}

proc ::sharedTest::packed {} {
    variable library
    variable client
    set tmp [file normalize [file tempdir]]
    try {
        set project [file join $tmp project]
        set manifest [file join $project project.dict]
        ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {entry main} modules {library library.src entry entry.src}}
        foreach module {library entry} text [list $library $client] {
            ::appcompiler::project::stageBytes [file join $project $module.src] [encoding convertto utf-8 $text]
        }
        set report [::appcompiler::project::test $manifest]
        equal [dict get $report passed] 1 "documented snapshot and live capture example"
        equal [dict get $report failures] {} "source examples pass"
        set archive [file join $tmp state.machteld]
        ::appcompiler::project::pack $manifest $archive
        file rename -- $project [file join $tmp retired]
        set rebuilt [file join $tmp rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        foreach app [list $archive $rebuilt] {
            set run [::machteld::run -dir $tmp -timeout 30s -- [info nameofexecutable] $app]
            equal [dict get $run exit] 0 "self-contained ref program: [dict get $run err]"
            equal [dict get $run out] 007 "packed callback reads current state"
            set page [::appcompiler::reference::query $app get fn/library/observe]
            equal [expr {[string first {ref<.t>} $page] >= 0}] 1 "offline reference includes generic ref signature"
        }
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::sharedTest::direct
if {$argv eq "-pack"} {::sharedTest::packed}
puts "application compiler shared references: $::sharedTest::count assertions passed"
