package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::interpolationTest {variable count 0}
proc ::interpolationTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::interpolationTest::call {app fn args} {
    $app eval [list ::interpolationApp::words::$fn {*}$args]
}
proc ::interpolationTest::runtime {sources} {
    equal [::appcompiler::check $sources] {} "interpolation expressions check across ordinary and nested syntax"
    set generated [::appcompiler::compile $sources ::interpolationApp]
    set app [interp create]
    try {
        $app eval {namespace eval ::Visit {variable calls {}; variable probe 0}
            proc ::Visit::record {text} {lappend ::Visit::calls $text; return $text}}
        $app eval [dict get $generated script]
        equal [call $app next 8] next=9 "documented numeric example"
        equal [call $app next 9999999999999999999999] next=10000000000000000000000 "numeric expression uses exact integer arithmetic"
        set payload [format "%s\n%c%s" {A; [incr ::Visit::probe] $name \path} 0 雪]
        equal [call $app values $payload +0009 -000.1200 true] "$payload|9|-0.12|true" \
            "text is verbatim and integer, decimal alias and bool use canonical spellings"
        equal [call $app values {} -0 -0.000 false] {|0|0|false} "empty text, numeric zero and false"
        equal [call $app dollars value] {$name|${name}|$name|${word}|value} \
            "escaped and Unicode-escaped dollars stay literal even before a name or brace"
        equal [call $app identifiers a ab] {a.ab.ab} "unbraced names consume exactly one identifier"
        equal [call $app punctuation] {$|$7|$!|$} "a dollar without a binding name or opening brace stays literal"
        equal [call $app empty] {} "empty prefixed text"
        equal [call $app literal] [format {%s %c} {plain [incr ::Visit::probe]} 92] "prefixed text without holes emits data"
        equal [call $app explicit 007] {id=007} "explicit extraction permits a declared scalar's underlying text"
        set brace [format %c 125]
        equal [call $app nested $payload] "outer=<$payload|inner=<$brace#\"|raw $brace>>:done" \
            "interpolated expressions use normal quoting, comment, forward-choice, match and nested interpolation syntax"
        equal [$app eval {set ::Visit::probe}] 0 "literal and inserted Tcl punctuation remains inert"

        equal [call $app order true] [list ok "first\nmiddle\nlast"] "successful propagation inside a multiline interpolation"
        equal [$app eval {set ::Visit::calls}] {first mid last} "each interpolated expression runs exactly once, left to right"
        $app eval {set ::Visit::calls {}}
        lassign [call $app order false] tag problem
        equal [list $tag [dict get $problem code]] {err MISSING_KEY} "failed interpolation propagates its typed problem"
        equal [$app eval {set ::Visit::calls}] {first mid} "later expressions do not run after propagation"
        set lines [split [dict get $sources words] \n]
        set index [lsearch -exact $lines {${require_key($m, .visit('mid'))?}}]
        if {$index < 0} {error "fixture lookup line is missing"}
        set column [expr {[string first ? [lindex $lines $index]] + 1}]
        set origin [dict get $problem origin]
        equal [list [dict get $origin module] [dict get $origin line] [dict get $origin column]] \
            [list words [expr {$index + 1}] $column] "the propagation operator retains its original physical source location"
    } finally {interp delete $app}

    set out [file tempfile path]
    try {
        try {
            chan configure $out -encoding utf-8 -translation lf
            puts -nonewline $out [dict get [::appcompiler::application $sources words] script]
        } finally {close $out}
        set arg {007 雪 [incr ::Visit::probe] $name}
        set run [::machteld::run -timeout 10s -- [info nameofexecutable] $path $arg]
        set brace [format %c 125]
        equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] \
            [list 0 [encoding convertto utf-8 "outer=<$arg|inner=<$brace#\"|raw $brace>>:done"] {}] \
            "standalone interpolation preserves nested syntax and literal argument bytes"
    } finally {file delete -- $path}
}

proc ::interpolationTest::syntaxAt {source code line column endColumn label} {
    set ds [::appcompiler::check [dict create sample $source]]
    equal [lmap d $ds {dict get $d code}] [list $code] "$label diagnostic"
    set n [dict get [lindex $ds 0] node]
    equal [list [dict get $n module] [dict get $n line] [dict get $n column] [dict get $n endLine] [dict get $n endColumn]] \
        [list sample $line $column $line $endColumn] "$label points to the original source"
}
proc ::interpolationTest::negative {} {
    foreach type {bytes unit problem {text?} {list<text>} {map<text,int>} {result<int,problem>} .id .row .state} {
        set code [format {distinct .id = text
record .row { name: text }
choice .state { ready }
fn .bad($value: %s) -> text { return $"cannot=$value" }} $type]
        set ds [::appcompiler::check [dict create sample $code]]
        equal [lmap d $ds {dict get $d code}] INTERPOLATION_TYPE "reject interpolation of $type"
        set n [dict get [lindex $ds 0] node]
        set text [lindex [split $code \n] 3]
        set column [expr {[string last {$value} $text] + 1}]
        equal [list [dict get $n line] [dict get $n column] [dict get $n endColumn]] \
            [list 4 $column [expr {$column + 6}]] "unsupported $type identifies the interpolated name"
    }
    set unknown {fn .bad($x: text) -> text {
    return $"first=$x
missing=${$absent}"
}}
    set ds [::appcompiler::check [dict create sample $unknown]]
    equal [lmap d $ds {dict get $d code}] UNKNOWN_BINDING "ordinary name resolution inside interpolation"
    set node [dict get [lindex $ds 0] node]
    equal [list [dict get $node module] [dict get $node line] [dict get $node column]] {sample 3 11} \
        "embedded expression diagnostic uses the original multiline source"
    set quote [format {$%c} 34]
    set hole [format {$%c} 123]
    set head [format "fn .bad() -> text %c\r\n    return %s" 123 $quote]
    set inside "$head first\r\n雪\U0001F680 "
    syntaxAt "$inside$hole[format %c 125]" E_PARSE_INTERPOLATION 3 6 7 "empty braced expression"
    syntaxAt "$inside${hole}1 + 2" E_PARSE_INTERPOLATION 3 4 6 "unclosed braced expression"
    syntaxAt "$head unfinished" E_PARSE_STRING 2 12 14 "unterminated prefixed string"
    syntaxAt "$inside[format %c 92]q" E_PARSE_ESCAPE 3 4 5 "invalid escape inside prefixed text"
    syntaxAt "$inside$hole.echo(\"unfinished" E_PARSE_STRING 3 12 13 "unfinished double-quoted call argument inside a hole"
    syntaxAt "$inside${hole}1 + \"unfinished" E_PARSE_STRING 3 10 11 "unfinished double-quoted right operand inside a hole"
    syntaxAt "$inside$hole.echo(\r\n  \"unfinished" E_PARSE_STRING 4 3 4 "nested quote after a physical newline"
    syntaxAt "$inside${hole}7\"" E_PARSE_INTERPOLATION 3 4 6 "closing quote after a complete operand with its hole unclosed"
    foreach code {
        {extern fn .bad() -> int = [$"::unused"]}
        {extern fn .bad() -> int = ['::unused', $"fixed"]}
        {extern fn .bad() -> int = ['::unused'] from $"Package"}
        {fn .bad($xs: list<text>) -> bool { return match $xs { [$"constant"] => true
            _ => false } }}
    } {
        set col [expr {[string first $quote $code] + 1}]
        syntaxAt $code E_PARSE_EXPECTED 1 $col [expr {$col + 2}] "literal-only context rejects prefixed string even without holes"
    }
}

namespace eval ::interpolationTest {
    set model {alias .amount = decimal
distinct .id = text
extern fn .visit($word: text) -> text = ['::Visit::record']
export fn .next($x: int) -> text { return $"next=${$x + 1}" }
export fn .values($txt: text, $i: int, $d: .amount, $flag: bool) -> text { return $"$txt|$i|$d|$flag" }
export fn .dollars($name: text) -> text { return $"\$name|\${name}|\u{24}name|\u{24}{word}|$name" }
export fn .identifiers($x: text, $xy: text) -> text { return $"$x.$xy.${$xy}" }
export fn .punctuation() -> text { return $"$|$7|$!|$" }
export fn .empty() -> text { return $"" }
export fn .literal() -> text { return $"plain [incr ::Visit::probe] \\" }
export fn .explicit($value: .id) -> text { return $"id=${underlying($value)}" }
fn .pair($a: text, $b: text) -> text { return $"<$a|$b>" }
export fn .nested($s: text) -> text {
    return $"outer=${match .event::set($s) {
        .event::empty => "unused CLOSE"
        .event::set($part) => .pair($part,
            # CLOSE " and DOLLAR_OPEN inside this comment are inert
            $"inner=${.pair("CLOSE#\"", 'raw CLOSE')}")
    }}:done"
}
export fn .order($present: bool) -> result<text,problem> {
    $m := map<text,text>()
    if $present { $m = map_put($m, 'mid', 'middle') }
    return ok($"${.visit('first')}
${require_key($m, .visit('mid'))?}
${.visit('last')}")
}
choice .event { empty
    set(text) }
fn .main($args: list<text>) -> result<unit,problem> {
    $input ::= match $args { [$one] => $one
        _ => '' }
    return write_stdout_utf8(.nested($input))
}}
    set model [string map [list CLOSE [format %c 125] DOLLAR_OPEN [format {$%c} 123]] $model]
    runtime [dict create words $model]
    negative
    puts "application compiler interpolation: $count assertions passed"
}
