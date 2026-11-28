package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::groupTest {variable count 0}
proc ::groupTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::groupTest::codes {errors} {lmap e $errors {dict get $e code}}
proc ::groupTest::expected {outer id note child n} {format {%s=>%s|%s:%s:%s|%s:%s} $outer $id $n $child $note $id $note}

proc ::groupTest::direct {sources} {
    equal [::appcompiler::check $sources] {} "grouped match checks through local and imported aliases"
    set compiled [::appcompiler::compile $sources ::groupApp]
    set app [interp create]
    try {
        $app eval [dict get $compiled script]
        $app eval {set ::calls {}; set ::probe 0; proc ::seen {name args} {lappend ::calls $name}}
        set procBody [$app eval {info body ::groupApp::view::@render}]
        foreach name {observed nested_body group_body} {
            set command ::groupApp::view::$name
            equal [expr {[string first $command $procBody] >= 0 && [string first $command $procBody] == [string last $command $procBody]}] \
                1 "the emitted function contains one $name call site"
        }
        foreach name {observed nested_body group_body other_body} {
            $app eval [list trace add execution ::groupApp::view::$name enter [list ::seen $name]]
        }
        set id {007 [] ; $id}
        set note "雪\u0000note"
        set child {child [incr ::probe] \data}
        foreach event [list [list open $id 31 $note] [list resume 94 $note $id]] {
            foreach side [list [list before $child 5] [list after 5 $child]] {
                $app eval {set ::calls {}}
                equal [$app eval [list ::groupApp::view::render $event $side caller]] [expected caller $id $note $child 5] \
                    "reordered captures, nested shadowing and enclosing scope"
                equal [$app eval {set ::calls}] {observed nested_body group_body} "scrutinee and selected shared bodies each run once"
            }
        }
        equal [$app eval {set ::probe}] 0 "captured Tcl punctuation remains inert inside nested interpolation"
        set opaque [list opaque [binary decode hex 00ff] [list none [list some 4]]]
        foreach {event expected} [list [list ignored 71 ignored_value] ignored $opaque control default control while control] {
            $app eval {set ::calls {}}
            equal [$app eval [list ::groupApp::view::render $event [list before unused 0] caller]] "caller=>$expected" \
                "discard-only or parameterless arm for [lindex $event 0]"
            equal [$app eval {set ::calls}] {observed other_body} "other grouped bodies do not run"
        }
        set repeatedBody [$app eval {info body ::groupApp::view::repeat_captures}]
        set positions {}
        foreach {match table} [regexp -all -inline {\[::dict get \{([^{}]+)\} } $repeatedBody] {
            lappend positions [list [dict get $table before] [dict get $table after]]
        }
        equal [lsort $positions] {{1 2} {2 1}} "one emitted tag-to-slot lookup per varying capture, regardless of use count"
        foreach side [list [list before $id 66] [list after 66 $id]] {
            equal [$app eval [list ::groupApp::view::underscore $side]] $id {$_ is a named capture across alternatives}
            equal [$app eval [list ::groupApp::view::repeat_captures $side]] [join [list $id 66 $id $id 66 $id $id $id] |] \
                "repeated uses read both captures from the selected variant"
        }
    } finally {interp delete $app}
}

proc ::groupTest::standalone {sources} {
    set script [dict get [::appcompiler::application $sources view] script]
    set ch [file tempfile path]
    try {
        try {chan configure $ch -encoding utf-8 -translation lf; puts -nonewline $ch $script} finally {close $ch}
        set id {007 $id}
        set note {note 雪}
        set child {child [a] \b}
        foreach {args wanted} [list [list resume $id $note $child] [expected caller $id $note $child 9] {default} {caller=>control}] {
            set run [::machteld::run -timeout 10s -- [info nameofexecutable] $path {*}$args]
            equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] [list 0 [encoding convertto utf-8 $wanted] {}] \
                "standalone grouped match for [lindex $args 0]"
        }
    } finally {file delete -- $path}
}

proc ::groupTest::negative {sources} {
    set declarations {alias .num = int
distinct .key = int
choice .c { a(int)
    b(.num) }
choice .d { a(int)
    b(.key) }}
    foreach {code arms} {
        PATTERN_BINDINGS {.c::a($x) | .c::b($y) => 1}
        PATTERN_BINDINGS {.c::a($x) | .c::b(_) => 1}
        DUPLICATE_ARM {.c::a($x) | .c::a($x) => 1
        .c::b(_) => 2}
        DUPLICATE_ARM {.c::a($x) | .c::b($x) => 1
        .c::b(_) => 2}
        PATTERN_TYPE {.c::a(_) | .d::b(_) => 1}
        PATTERN_ARITY {.c::a(_) | .c::b(_, _) => 1}
        UNKNOWN_BINDING {.c::a(_) | .c::b(_) => $_}
        E_PARSE_EXPECTED {.c::a(_) | _ => 1}
        E_PARSE_EXPECTED {_ | .c::a(_) => 1}
        E_PARSE_EXPECTED {.c::a(_) | [] => 1}
        E_PARSE_EXPECTED {[] | .c::a(_) => 1}
    } {
        set fn [format {fn .bad($v: .c) -> int { return match $v { %s } }} $arms]
        set ds [::appcompiler::check [dict create sample "$declarations\n$fn"]]
        equal [codes $ds] [list $code] "group diagnostic $code for [lindex [split $arms \n] 0]"
    }
    set wrong {fn .bad($v: .d) -> int {
    return match $v { .d::a($id) | .d::b($id) => 1 }
}}
    set ds [::appcompiler::check [dict create sample "$declarations\n$wrong"]]
    equal [codes $ds] PATTERN_BINDING_TYPE "nominal and underlying scalar captures cannot share a name"
    set node [dict get [lindex $ds 0] node]
    set column [expr {[string last {$id} [lindex [split $wrong \n] 1]] + 1}]
    equal [list [dict get $node column] [dict get $node endColumn]] [list $column [expr {$column + 3}]] \
        "binding type disagreement identifies the second capture"

    set missing {fn .bad($v: .c) -> int { return match $v {
        .c::a($x) | .c::b($x) => $unbound
    } }}
    set ds [::appcompiler::check [dict create sample "$declarations\n$missing"]]
    equal [codes $ds] UNKNOWN_BINDING "a bad shared body produces its diagnostic once"
    set pair {choice .both { a(int,int)
    b(int,int) }
fn .bad($v: .both) -> int { return match $v {
    .both::a($x,$x) | .both::b($x,_) => 1
} }}
    equal [codes [::appcompiler::check [dict create sample $pair]]] DUPLICATE_BINDING "a name cannot be bound twice in one alternative"
    set events [string map [list {    default} "    added\n    default"] [dict get $sources events]]
    set ds [::appcompiler::check [dict replace $sources events $events]]
    equal [codes $ds] MATCH_NONEXHAUSTIVE "adding one variant invalidates an otherwise exhaustive grouped match"
    equal [string match {*added*} [dict get [lindex $ds 0] message]] 1 "exhaustiveness names the new uncovered variant"
}

namespace eval ::groupTest {
    set events {export alias .label = text
export choice .event {
    open(.label, int, text)
    resume(int, text, text)
    ignored(int, text)
    opaque(bytes, list<int?>)
    default
    while
}
export alias .notice = .event
export choice .side {
    before(.label, int)
    after(int, text)
}}
    set view {import events
alias .local = .events::notice
fn .observed($e: .local) -> .local => $e
fn .nested_body($value: text) -> text => $value
fn .group_body($value: text) -> text => $value
fn .other_body($value: text) -> text => $value
export fn .render($event: .local, $side: .events::side, $id: text) -> text {
    $value ::= match .observed($event) {
        .local::open($id, _, $note) | .events::event::resume(_, $note, $id) =>
            .group_body($"$id|${match $side {
                .events::side::before($id, $n) | .events::side::after($n, $id) => .nested_body($"$n:$id:$note")
            }}|$id:$note")
        .local::ignored(_, _) => .other_body('ignored')
        .local::while | .events::notice::default | .local::opaque(_, _) => .other_body('control')
    }
    return $"$id=>$value"
}
export fn .underscore($side: .events::side) -> text {
    return match $side {
        .events::side::before($_, _) | .events::side::after(_, $_) => $_
    }
}
export fn .repeat_captures($side: .events::side) -> text {
    return match $side {
        .events::side::before($id, $n) | .events::side::after($n, $id) => $"$id|$n|$id|$id|$n|$id|$id|$id"
    }
}
fn .main($args: list<text>) -> result<unit,problem> {
    $output ::= match $args {
        ['resume', $id, $note, $child] => .render(.local::resume(0, $note, $id), .events::side::after(9, $child), 'caller')
        ['default'] => .render(.local::default, .events::side::before('', 0), 'caller')
        _ => 'unsupported'
    }
    return write_stdout_utf8($output)
}}
    set sources [dict create events $events view $view]
    direct $sources
    standalone $sources
    negative $sources
    puts "application compiler grouped choice: $count assertions passed"
}
