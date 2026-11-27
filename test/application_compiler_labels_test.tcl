package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::labelsTest {
    variable checks 0
    variable library {export fn .transfer(from $origin: text, $via: text, to $destination: text) -> text =>
    $"$origin|$via|$destination"
example .transfer(from: 'A', 'B', to: 'C') => 'A|B|C'
export fn .first<.t>(choose $value: .t, over $fallback: .t) -> .t => $value
export extern fn .pair(left $a: text, right $b: text) -> text = ['::string', 'cat']
export fn .keyword(in $value: text) -> text => $value
}
    variable client {import library
extern fn .note($v: text) -> text = ['::observe']
export fn .observed() -> text =>
    .library::transfer(from: .note('A'), .note('B'), to: .note('C'))
export fn .render($value: text) -> text =>
    .library::transfer(from:
        .library::first(choose: $value, over: 'none'),
        .library::keyword(in: 'X'),
        to: .library::pair(left: '0', right: .library::first<text>(choose: '07', over: 'never')))
example .render('007') => '007|X|007'
fn .main($args: list<text>) -> result<unit,problem> => match $args {
    [$value] => write_stdout_utf8(.render($value))
    _ => err(problem('expected one value'))
}}
}

proc ::labelsTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::labelsTest::bad {fragment codes {span {}}} {
    variable library
    set source "import library\n$fragment"
    set diagnostics [::appcompiler::check [dict create library $library client $source]]
    equal [lmap d $diagnostics {dict get $d code}] $codes "diagnostics in $fragment"
    if {$span ne {}} {
        set node [dict get [lindex $diagnostics 0] node]
        equal [dict get $node module] client "diagnostic module"
        set row [lindex [split $source \n] [expr {[dict get $node line] - 1}]]
        equal [string range $row [expr {[dict get $node column] - 1}] [expr {[dict get $node endColumn] - 2}]] $span "diagnostic location"
    }
}

proc ::labelsTest::direct {} {
    variable library
    variable client
    set sources [dict create client $client library $library]
    equal [::appcompiler::check $sources] {} "labelled examples, generics, externs and calls"
    set app [interp create]
    try {
        $app eval [dict get [::appcompiler::compile $sources ::labelApp] script]
        $app eval {set ::calls {}; proc ::observe {v} {lappend ::calls $v; return $v}}
        equal [$app eval {::labelApp::client::observed}] A|B|C "labelled arguments passed at their original positions"
        equal [$app eval {set ::calls}] {A B C} "argument expressions evaluated once in source order"
        equal [$app eval {::labelApp::client::render 007}] 007|X|007 "nested generic and extern calls"
        equal [$app eval {::labelApp::library::transfer 1 2 3}] 1|2|3 "Tcl caller uses ordinary positional arguments"
        equal [$app eval {::labelApp::library::first text 007 9}] 007 "generic ABI accepts its usual explicit type list"
    } finally {interp delete $app}

    bad {fn .bad() -> text => .library::transfer('A', 'B', to: 'C')} ARGUMENT_LABEL {'A'}
    bad {fn .bad() -> text => .library::transfer(From: 'A', 'B', to: 'C')} ARGUMENT_LABEL From
    bad {fn .bad() -> text => .library::transfer(from: 'A', via: 'B', to: 'C')} ARGUMENT_LABEL via
    bad {fn .bad() -> text => .library::transfer(to: 'C', 'B', from: 'A')} {ARGUMENT_LABEL ARGUMENT_LABEL} to
    bad {fn .bad() -> text => .library::transfer(from: 'A', 'B')} CALL_ARITY
    bad {fn .bad() -> text => .library::transfer(from: 'A', 'B', to: 'C', 'D')} CALL_ARITY
    bad {fn .bad() -> text => .library::first<text>(choose: 'a', fallback: 'b')} ARGUMENT_LABEL fallback
    bad {fn .bad() -> text => .library::pair(left: 'A', left: 'B')} ARGUMENT_LABEL left
    bad {fn .self(to $value: int) -> int => $value
example .self(1) => 1} ARGUMENT_LABEL 1
    bad {choice .event { found(text) }
fn .bad() -> .event => .event::found(item: 'north')} ARGUMENT_LABEL item
    bad {choice .library { transfer(text) }
fn .bad() -> .library => .library::transfer(from: 'A')} AMBIGUOUS_CALL
}

proc ::labelsTest::packed {} {
    variable library
    variable client
    set tmp [file normalize [file tempdir]]
    try {
        set project [file join $tmp source]
        file mkdir $project
        set manifest [file join $project project.dict]
        ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {client main} modules {library library.src client client.src}}
        foreach module {library client} {
            ::appcompiler::project::stageBytes [file join $project $module.src] [encoding convertto utf-8 [set $module]]
        }
        set tested [::appcompiler::project::test $manifest]
        equal [dict get $tested total] 2 "both labelled examples run"
        equal [dict get $tested failures] {} "labelled examples pass"
        set app [file join $tmp routes.machteld]
        ::appcompiler::project::pack $manifest $app
        file rename -- $project [file join $tmp retired]
        foreach {member signature} {
            transfer {export fn .transfer(from $origin: text, $via: text, to $destination: text)}
            first {export fn .first<.t>(choose $value: .t, over $fallback: .t)}
            pair {export extern fn .pair(left $a: text, right $b: text)}
        } {
            set page [::appcompiler::reference::query $app get fn/library/$member]
            equal [expr {[string first $signature $page] >= 0}] 1 "offline signature for $member"
        }
        set result [::machteld::run -dir $tmp -timeout 30s -- [info nameofexecutable] $app 007]
        equal [dict get $result exit] 0 "packed app exit: [dict get $result err]"
        equal [dict get $result out] 007|X|007 "packed app preserves argument identity"
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::labelsTest::direct
if {$argv eq "-pack"} {::labelsTest::packed}
puts "application compiler argument labels: $::labelsTest::checks assertions passed"
