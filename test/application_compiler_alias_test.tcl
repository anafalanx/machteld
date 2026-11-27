package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::aliasTest {variable count 0}
proc ::aliasTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::aliasTest::call {app name args} {
    $app eval [list ::aliasApp::client::$name {*}$args]
}
proc ::aliasTest::badArgument {app name args} {
    set status [catch {call $app $name {*}$args} message opts]
    equal $status 1 "exported $name rejects invalid input"
    equal [dict get $opts -errorcode] {APPCOMPILER ARGUMENT TYPE} "$name uses the underlying type guard"
}
proc ::aliasTest::problemLine {sources} {
    set lines [split [dict get $sources client] \n]
    set pos [lsearch -exact $lines {    $chosen ::= require_key($values, 'message')?}]
    if {$pos < 0} {error "missing fixture line for propagated error"}
    return [expr {$pos + 1}]
}

proc ::aliasTest::direct {sources} {
    equal [::appcompiler::check $sources] {} "forward, imported and reexported aliases check"
    set built [::appcompiler::compile $sources ::aliasApp]
    set app [interp create]
    try {
        $app eval [dict get $built script]
        equal [call $app exchange +0007 11] 11 "a base value assigns to and returns through its alias"
        equal [call $app exchange 10000000000000000000000000000 -0009] -9 "scalar alias shares exact integer representation"
        set notes [list none [list some {}] [list some 007]]
        set original [call $app created +0007 $notes]
        equal $original [dict create 7 $notes] "generic constructor resolves aliased map keys and nested values"
        equal [call $app fetch $original 007] [list ok $notes] "concrete map and alias are interchangeable"
        equal [lindex [call $app fetch $original 8] 0] err "aliased result returns typed failure"
        set item [dict create id +0004 notes $notes extra preserved]
        set empty [call $app empty]
        equal $empty empty "qualify a parameterless choice through an imported alias"
        equal [call $app set_local +0012] {set 12} "construct a choice through a forward local alias"
        equal [call $app set_imported 12] {set 12} "construct a payload variant through a reexported alias"
        equal [call $app change $item $empty] [dict replace $item id 4] "alias record guard retains extra fields"
        equal [call $app change $item [call $app set_imported 12]] [dict replace $item id 12] \
            "alias choice match and alias record update use their defining nominal types"
        set tree [dict create children [list [dict create children {}]]]
        equal [call $app tree $tree] $tree "a nominal record can recurse through a transparent alias"
        badArgument $app exchange not_an_int 1
        badArgument $app fetch [dict create 7 $notes +007 $notes] 7
        badArgument $app fetch [dict create 7 [list [list some too many]]] 7
        badArgument $app change [dict remove $item id] empty
        badArgument $app change $item {set not_an_int}
        equal [call $app select [list say {007 雪}]] [list ok {007 雪}] "aliased list parameter and result"
        lassign [call $app select {}] tag problem
        set origin [dict get $problem origin]
        equal [list $tag [dict get $problem code] [dict get $origin module] [dict get $origin line]] \
            [list err MISSING_KEY client [problemLine $sources]] "aliased problem result keeps the lookup's source location"
    } finally {interp delete $app}
}
proc ::aliasTest::entry {sources} {
    set artifact [::appcompiler::application $sources client]
    set ch [file tempfile path]
    try {
        try {
            chan configure $ch -encoding utf-8 -translation lf
            puts -nonewline $ch [dict get $artifact script]
        } finally {close $ch}
        set exe [info nameofexecutable]
        set run [::machteld::run -timeout 10s -- $exe $path say {007 雪}]
        equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] \
            [list 0 [encoding convertto utf-8 {007 雪}] {}] "standalone entry accepts reexported argv and result aliases"
        set run [::machteld::run -timeout 10s -- $exe $path]
        equal [list [dict get $run exit] [dict get $run out]] {1 {}} "aliased entry propagates a typed failure"
        set expected "client:[problemLine $sources]:*: *missing map key*"
        equal [string match $expected [string trimright [dict get $run err] "\r\n"]] 1 "entry reports original lookup"
    } finally {file delete -- $path}
}
proc ::aliasTest::diagnostics {sources} {
    set base [dict create base [dict get $sources base] facade [dict get $sources facade]]
    foreach {expected source} {
        NOT_EXPORTED {import base
alias .hidden = .base::raw_id}
        NOT_EXPORTED {import facade
alias .hidden = .facade::private}
        MISSING_IMPORT {import facade
alias .missing = .base::ident}
        UNKNOWN_TYPE {import facade
alias .bad_case = .facade::Count}
        UNKNOWN_MODULE {import Facade}
        DUPLICATE_TYPE {alias .same = int
record .same { v: int }}
        MAP_KEY_TYPE {alias .bad_key = list<int>
alias .bad = map<.bad_key,int>}
        RETURN_TYPE {record .a { value: int }
record .b { value: int }
alias .first = .a
fn .bad($x: .first) -> .b { return $x }}
    } {
        set diagnostics [::appcompiler::check [dict merge $base [dict create bad $source]]]
        equal [lsort -unique [lmap d $diagnostics {dict get $d code}]] [list $expected] "alias diagnostic $expected"
    }

    set bad {alias .wrong = map<text,list<.absent>>
fn .independent() -> int { return 'text' }}
    set diagnostics [::appcompiler::check [dict create bad $bad]]
    equal [lsort [lmap d $diagnostics {dict get $d code}]] {RETURN_TYPE UNKNOWN_TYPE} \
        "bad target and independent function each report their own diagnostic"
    foreach d $diagnostics {
        if {[dict get $d code] ne "UNKNOWN_TYPE"} continue
        set node [dict get $d node]
        set token [string range [lindex [split $bad \n] 0] \
            [expr {[dict get $node column]-1}] [expr {[dict get $node endColumn]-2}]]
        equal [list [dict get $node module] [dict get $node line] $token] {bad 1 .absent} "underline the nested unresolved alias target"
    }
    foreach cyclic [list {alias .one = .one} {alias .one = map<text,list<.two?>>
alias .two = .one}] {
        set sources [dict create cycle "$cyclic\nfn .other() -> bool {return 1}"]
        set diagnostics [::appcompiler::check $sources]
        equal [lsort -unique [lmap d $diagnostics {dict get $d code}]] {ALIAS_CYCLE RETURN_TYPE} \
            "alias cycle terminates and independent checking continues"
        set status [catch {::appcompiler::compile $sources ::badAlias} message opts]
        equal [list $status [dict get $opts -errorcode]] {1 {APPCOMPILER CHECK}} "cyclic alias fails before emission"
    }
    set across [dict create first {import second
export alias .left = list<.second::right>} second {import first
export alias .right = .first::left}]
    set diagnostics [::appcompiler::check $across]
    equal [lsort -unique [lmap d $diagnostics {dict get $d code}]] ALIAS_CYCLE "cycle through reexported aliases in two modules"
}

proc ::aliasTest::expansionLimit {} {
    set plain {}
    for {set n 0} {$n < 64} {incr n} {
        lappend plain "alias .a$n = .a[expr {$n + 1}]"
    }
    lappend plain {alias .a64 = int} {fn .id($n: .a0) -> int { return $n }}
    equal [::appcompiler::check [dict create plain [join $plain \n]]] {} "64 forward aliases can resolve to a short scalar type"

    # A binary result tree with n int leaves uses 3*n + 9*(n-1) characters.
    # Join 512+128+32+8+2+1 leaves, then add five optional suffixes for 8192.
    set lines [list {alias .t0 = int}]
    for {set n 1} {$n <= 9} {incr n} {
        set child .t[expr {$n - 1}]
        lappend lines "alias .t$n = result<$child,$child>"
    }
    lappend lines {alias .tree = result<.t9,result<.t7,result<.t5,result<.t3,result<.t1,.t0>>>>>}
    lappend lines {alias .edge = .tree?????}
    equal [::appcompiler::check [dict create limit [join $lines \n]]] {} "a canonical spelling of exactly 8192 characters is accepted"

    set offending {alias .too = .edge?}
    lappend lines $offending
    set line [llength $lines]
    lappend lines {alias .dependent = list<.too>} \
        {fn .uses($x: .dependent) -> .dependent { return $x }} \
        {fn .unrelated() -> int { return 'text' }}
    set errors [::appcompiler::check [dict create limit [join $lines \n]]]
    equal [lsort [lmap d $errors {dict get $d code}]] {RETURN_TYPE TYPE_EXPANSION_LIMIT} \
        "one excess character yields one diagnostic while an independent error survives"
    foreach d $errors {
        if {[dict get $d code] ne "TYPE_EXPANSION_LIMIT"} continue
        set node [dict get $d node]
        set span [string range $offending [expr {[dict get $node column]-1}] [expr {[dict get $node endColumn]-2}]]
        equal [list [dict get $node module] [dict get $node line] $span] [list limit $line .edge?] \
            "the limit points to the first overflowing target instead of a dependent use"
    }
}

namespace eval ::aliasTest {
    set base {export alias .ident = .raw_id
export alias .bag = map<.ident,.notes>
export alias .notes = list<.note>
export alias .note = text?
export alias .row_name = .row
export alias .kind_name = .kind
export alias .tree = .node
export alias .args = list<text>
export alias .status = result<unit,problem>
export alias .message = result<text,problem>
alias .raw_id = int
export record .row { id: .ident
    notes: .notes }
export record .node { children: list<.tree> }
export choice .kind { empty
    set(.ident) }}
    set facade {import base
export alias .count = .base::ident
export alias .catalog = .base::bag
export alias .notes = .base::notes
export alias .item = .base::row_name
export alias .decision = .base::kind_name
export alias .tree = .base::tree
export alias .args = .base::args
export alias .status = .base::status
export alias .message = .base::message
alias .private = text}
    set client {import facade
fn .plain($n: int) -> int { return $n }
export fn .exchange($n: .facade::count, $other: int) -> .facade::count {
    $value := $n
    $value = $other
    return .plain($value)
}
export fn .created($n: int, $v: list<text?>) -> .facade::catalog {
    $m ::= map<.facade::count,.facade::notes>()
    return map_put($m, $n, $v)
}
export fn .fetch($catalog: .facade::catalog, $n: .facade::count) -> result<list<text?>,problem> {
    return require_key($catalog, $n)
}
export fn .set_local($n: int) -> .local { return .local::set($n) }
export fn .set_imported($n: int) -> .local { return .facade::decision::set($n) }
export fn .empty() -> .local { return .facade::decision::empty }
export fn .tree($value: .facade::tree) -> .facade::tree { return $value }
export fn .change($r: .facade::item, $update: .local) -> .facade::item {
    return match $update {
        .local::empty => $r
        .facade::decision::set($n) => $r with { id = $n }
    }
}
export fn .select($args: .facade::args) -> .facade::message {
    $empty ::= map<text,text>()
    $values ::= match $args {
        ['say', $v] => map_put($empty, 'message', $v)
        _ => $empty
    }
    $chosen ::= require_key($values, 'message')?
    return ok($chosen)
}
fn .main($args: .facade::args) -> .facade::status {
    $message ::= .select($args)?
    return write_stdout_utf8($message)
}
alias .local = .facade::decision}
    set sources [dict create client $client facade $facade base $base]
    direct $sources
    entry $sources
    diagnostics $sources
    expansionLimit
    puts "application compiler aliases: $count assertions passed"
}
