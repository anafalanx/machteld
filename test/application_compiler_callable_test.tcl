package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::callableTest {
    variable checks 0
    variable library {export fn .join($a: text, $b: text, $c: text) -> text => $"$a|$b|$c"
export fn .id<.t>($v: .t) -> .t => $v
export fn .labelled(from $v: text) -> text => $v
fn .hidden($n: int) -> int => $n + 1
export fn .increment() -> callable<int,int> => .hidden
}
    variable client {import library
record .row { callback: callable<text,text> }
extern fn .observe($v: text) -> text = ['::observe']
extern fn .tcl_apply($f: callable<text,text>, $x: text) -> text = ['::tclApply']
extern fn .tcl_return() -> callable<int,int> = ['::tclReturn']
fn .adapter($v: text) -> text => .library::labelled(from: $v)
export fn .identity<.t>() -> callable<.t,.t> => .library::id<.t>
fn .bind($value: text) -> text => $"named $value"
export fn .dispatch() -> text {
    $bind ::= bind(.bind, 'local')
    return .bind($bind())
}
fn .map_read($table: map<text,text>, $key: text) -> result<text,problem> => require_key($table, $key)
export fn .saved_map() -> callable<text,result<text,problem>> {
    $table := map_put(map<text,text>(), 'code', '007')
    $f ::= bind(.map_read, $table)
    $table = map_put($table, 'code', 'new')
    return $f
}
export fn .snapshot($before: text) -> callable<text> {
    $a := $before
    $f ::= bind(.library::join, $a)
    $a = 'changed'
    return bind($f, 'B', $a)
}
export fn .observed() -> callable<text> =>
    bind(.library::join, .observe('A'), .observe('B'), .observe('C'))
export fn .apply($f: callable<int,int>, $x: int) -> int => $f($x)
export fn .tcl($x: text) -> text => .tcl_apply(.adapter, $x)
export fn .from_tcl($x: int) -> int {
    $f ::= .tcl_return()
    return $f($x)
}
export fn .field($r: .row, $x: text) -> text {
    $f ::= $r.callback
    return $f($x)
}
export fn .wire($r: .row) -> result<text,problem> => encode_json($r)
export fn .read($json: text) -> result<.row,problem> => decode_json<.row>($json)
fn .main($args: list<text>) -> result<unit,problem> {
    $f ::= .snapshot('007')
    return write_stdout_utf8($f())
}}
}

proc ::callableTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::callableTest::bad {fragment code} {
    variable library
    set diagnostics [::appcompiler::check [dict create library $library client "import library\n$fragment"]]
    equal [lmap d $diagnostics {dict get $d code}] $code "diagnostic for $fragment"
}

proc ::callableTest::direct {} {
    variable library
    variable client
    set artifact [::appcompiler::compile [dict create library $library client $client] ::calls]
    namespace eval :: [dict get $artifact script]
    set ::observations {}
    proc ::observe {v} {lappend ::observations $v; return $v}
    proc ::tclApply {f x} {{*}$f $x}
    proc ::tclReturn {} {return $::returnedCallback}
    set raw {x [literal] $name ; " ' {quoted}}
    equal [{*}[::calls::client::snapshot $raw]] "$raw|B|changed" "capture by value before reassignment"
    set f [::calls::client::observed]
    equal $::observations {A B C} "capture expressions run once, left to right"
    for {set i 0} {$i < 2} {incr i} {
        equal [{*}$f] A|B|C "reusable nullary Tcl command prefix"
    }
    equal $::observations {A B C} "invocation does not reevaluate captures"
    equal [::calls::client::dispatch] {named named local} "standard, named and local calls can share one name"
    equal [{*}[::calls::client::saved_map] code] {ok 007} "collection capture survives the caller's map update"
    set inc [::calls::library::increment]
    equal [::calls::client::apply $inc 041] 42 "private callable through exported X and Tcl"
    equal [{*}$inc 0008] 9 "canonical input to a private callable"
    set emptyTypes [lreplace $inc 2 2 " \t\n"]
    equal [{*}$emptyTypes 8] 9 "a concrete callback accepts any valid empty Tcl type list"
    set malformedTypes [lreplace $inc 2 2 \{]
    equal [catch {{*}$malformedTypes} message options] 1 "type list checked before callback argument count"
    equal [list [dict get $options -errorcode] $message] \
        [list {APPCOMPILER ARGUMENT TYPE} {expected 0 concrete type argument(s) at type arguments}] \
        "a concrete callback preserves the type-argument diagnostic"
    set ::returnedCallback $inc
    equal [::calls::client::from_tcl 2] 3 "extern returns a typed callable"
    set identity [::calls::client::identity text]
    equal [::calls::client::field [dict create callback $identity] 007] 007 "callable in a record"
    equal [::calls::client::tcl $raw] $raw "Tcl extern invokes an adapter that supplies required labels"
    set higher [::calls::client::identity callable<int,int>]
    equal [{*}[{*}$higher $inc] 6] 7 "generic higher-order callback"
    set collision {import library
choice .library { missing }
alias .transform = callable<int,int>
export fn .shared() -> .transform => .library::id<int>
export fn .worked() -> .library => .library::missing
export fn .adapter() -> callable<callable<int,int>> => .library::increment}
    namespace eval :: [dict get [::appcompiler::compile [dict create library $library client $collision] ::claims] script]
    equal [{*}[::claims::client::shared] 007] 7 "alias of a concrete generic callable"
    equal [::claims::client::worked] missing "bare local choice variant with overlapping module name"
    equal [{*}[{*}[::claims::client::adapter]] 8] 9 "module function reference with overlapping local choice"
    equal [catch {::calls::client::apply [::claims::client::shared] 2}] 1 "different generated application target"
    equal [catch {{*}$higher [lreplace $inc 3 3 invalid]}] 1 "nested callable guards captures"
    foreach value [list $identity ::observe [list ::observe A] [lreplace $inc 1 1 ::observe] \
            [lreplace $inc 2 2 unknown] [lreplace $inc 3 3 {1 2}]] {
        equal [catch {::calls::client::apply $value 8} message options] 1 "bad callback rejected"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "typed boundary diagnostic"
    }
    equal [catch {{*}$inc abc}] 1 "private target guards external arguments"
    equal [catch {{*}$inc}] 1 "prefix checks external arity"
    set ::returnedCallback ::observe
    equal [catch {::calls::client::from_tcl 2}] 1 "extern return checks callback shape"
    equal $::observations {A B C} "unregistered Tcl command never invoked"
    lassign [::calls::client::wire [dict create callback $identity]] tag problem
    equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} "cannot serialize a callback"
    lassign [::calls::client::read {{"callback":"::observe"}}] tag problem
    equal [list $tag [dict get $problem code]] {err JSON_SCHEMA} "cannot decode a callback"

    bad {fn .bad($v: int) -> int => $v()} EXPECTED_CALLABLE
    bad {fn .bad($v: callable) -> int => 1} TYPE_ARITY
    bad {fn .bad() -> callable<int> => .absent} UNKNOWN_FUNCTION
    bad {fn .bad($f: callable<int,text>) -> text => $f('x')} ARGUMENT_TYPE
    bad {fn .bad($f: callable<int,text>) -> text => $f()} CALL_ARITY
    bad {fn .bad($f: callable<int,text>) -> text => $f(from: 2)} ARGUMENT_LABEL
    bad {fn .bad() -> callable<int,int> => .library::id} TYPE_INFERENCE
    bad {fn .bad() -> callable<int,int> => .library::hidden} NOT_EXPORTED
    bad {fn .bad() -> callable<text,text> => .library::labelled} CALLABLE_LABEL
    bad {fn .bad() -> callable<int,int> => .library::id<text>} RETURN_TYPE
    bad {fn .bad() -> callable<text> => bind(.library::id<text>)} CALL_ARITY
    bad {fn .bad() -> callable<text> => bind(.library::id<text>, 3)} ARGUMENT_TYPE
    bad {fn .bad() -> callable<text> => bind(.library::id<text>, 'a', 'b')} CALL_ARITY
    bad {fn .bad() -> callable<text> => bind('abc', 1)} EXPECTED_CALLABLE
    bad {fn .bad($v: callable<int>) -> unit {
    $v()
    return unit
}} {}
    bad {fn .bad($v: callable<result<int,problem>>) -> unit {
    $v()
    return unit
}} DISCARDED_RESULT
    bad {fn .bad($x: callable<int>) -> bool => $x == $x} NOT_COMPARABLE
    bad {record .r { c: list<callable<int>> }
fn .bad($r: .r) -> bool => $r == $r} NOT_COMPARABLE
    bad {record .row { c: callable<int> }
fn .bad($p: text) -> result<.row,problem> => sql_one<.row>($p, 'SELECT 1 AS c')} SQL_FIELD_TYPE
}

proc ::callableTest::packed {} {
    variable library
    variable client
    set tmp [file normalize [file tempdir]]
    try {
        set project [file join $tmp project]
        set manifest [file join $project project.dict]
        ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {client main} modules {library library.src client client.src}}
        foreach module {library client} {
            ::appcompiler::project::stageBytes [file join $project $module.src] [encoding convertto utf-8 [set $module]]
        }
        set archive [file join $tmp callbacks.machteld]
        ::appcompiler::project::pack $manifest $archive
        file rename -- $project [file join $tmp retired]
        set rebuilt [file join $tmp rebuilt.machteld]
        ::appcompiler::project::rebuild $archive $rebuilt
        foreach app [list $archive $rebuilt] {
            set run [::machteld::run -dir $tmp -timeout 30s -- [info nameofexecutable] $app]
            equal [dict get $run exit] 0 "self-contained callback program: [dict get $run err]"
            equal [dict get $run out] 007|B|changed "packed capture result"
            set page [::appcompiler::reference::query $app get fn/client/snapshot]
            equal [expr {[string first {callable<text>} $page] >= 0}] 1 "offline reference retains callable signature"
        }
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::callableTest::direct
if {$argv eq "-pack"} {::callableTest::packed}
puts "application compiler callable values: $::callableTest::checks assertions passed"
