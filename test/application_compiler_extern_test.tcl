package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::externTest {variable count 0}
proc ::externTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::externTest::invoke {app fn args} {
    $app eval [list ::externApp::bridge::$fn {*}$args]
}
proc ::externTest::site {sources fn literal} {
    set line 0
    foreach text [split [dict get $sources bridge] \n] {
        incr line
        if {[string first "fn .${fn}(" $text] < 0} continue
        set column [string first "'$literal'" $text]
        if {$column >= 0} {return [list bridge $line [expr {$column + 1}]]}
    }
    error "fixture lacks the extern declaration for $fn"
}
proc ::externTest::position {origin} {
    list [dict get $origin module] [dict get $origin line] [dict get $origin column]
}
proc ::externTest::failure {app sources fn literal args} {
    set status [catch {invoke $app $fn {*}$args} message options]
    equal $status 1 "$fn raises a Tcl integration error"
    equal [position [dict get $options -appcompilerlocation]] [site $sources $fn $literal] \
        "$fn identifies the responsible literal in the extern declaration"
    return [dict get $options -errorcode]
}

proc ::externTest::direct {sources host} {
    namespace eval :: $host
    equal [::appcompiler::check $sources] {} "extern declarations check without probing runtime availability"
    set built [::appcompiler::compile $sources ::externApp]
    equal [list $::ExternFixture::calls $::ExternFixture::loads] {0 0} "checking and compilation call no host code"
    set app [interp create]
    try {
        $app alias ::machteld::json ::machteld::json
        $app eval $host
        $app eval {set ::ExternFixture::target ::externApp}
        $app eval [dict get $built script]
        equal [$app eval {list $::ExternFixture::calls $::ExternFixture::loads [info commands ::ExternFixture::late]}] \
            {0 0 {}} "loading generated Tcl neither invokes a command nor loads its package"
        set data "two words\n\u0000雪; \[clock seconds\] \$name"
        set nested [list {} {a b} {{*}$x} 雪]
        set fixed {two words; [clock seconds] $env \path {braces}}
        equal [invoke $app words $data $nested] [list {} $fixed $data $nested] \
            "command alias receives inert prefix words and unexpanded argument data"
        equal [$app eval {set ::ExternFixture::calls}] 1 "literal prefix dispatch invokes the host exactly once"
        equal [invoke $app characters $data] [string length $data] "native Tcl ensemble and its fixed subcommand need no procedure metadata"
        equal [$app eval {::externApp::client::relay {two words}}] {two words} "imported extern and private wrapper call"
        equal [invoke $app late value] {loaded value} "package registers its command at first invocation"
        equal [invoke $app late {}] [list loaded {}] "loaded command preserves an empty argument"
        equal [$app eval {set ::ExternFixture::loads}] 1 "package ifneeded initializer runs only once"
        equal [invoke $app nominal +0009] 9 "nominal input and result use the integer representation"
        set before [$app eval {set ::ExternFixture::calls}]
        equal [catch {invoke $app nominal wrong}] 1 "bad native input is rejected"
        equal [$app eval {set ::ExternFixture::calls}] $before "bad native input never calls its command"
        equal [invoke $app row good] [dict create id 9 marks [list none [list some 7]]] \
            "record return validates and normalizes nested nominal and optional values"
        equal [invoke $app sink] {} "empty return satisfies unit"
        equal [invoke $app reply good] {ok 7} "typed success validates its payload"
        lassign [invoke $app reply fail] tag problem
        equal [list $tag [dict get $problem code] [dict get $problem message]] {err FIXTURE {ordinary problem}} \
            "well-formed typed failure is an ordinary returned value"
        equal [position [dict get $problem origin]] [site $sources reply ::ExternFixture::response] \
            "extern supplies an origin when a typed problem has none"
        lassign [invoke $app reply located] tag problem
        equal [position [dict get $problem origin]] {upstream 4 7} "extern preserves an existing problem origin"

        foreach {fn args} {row bad nominal_result {} sink_bad {} reply malformed reply wrong_payload reply bad_problem} {
            equal [failure $app $sources $fn ::ExternFixture::response {*}$args] {APPCOMPILER EXTERN RESULT} \
                "$fn rejects the malformed host result"
        }
        equal [failure $app $sources throws ::ExternFixture::raises] {EXTERN_FIXTURE THROW} \
            "a native exception stays an exception even when the declared return is result"
        equal [lrange [failure $app $sources absent ::ExternFixture::absent] 0 2] {TCL LOOKUP COMMAND} \
            "native missing-command error code survives"
        equal [failure $app $sources unavailable ExternFixtureMissing] {TCL PACKAGE UNFOUND} \
            "package resolution failure identifies its package literal"
        set status [catch {invoke $app adapter} message opts]
        equal [list $status $message [dict get $opts -errorcode]] {1 {host threw} {EXTERN_FIXTURE THROW}} \
            "native adapter preserves the inner command's exception"
        equal [position [dict get $opts -appcompilerlocation]] [site $sources throws ::ExternFixture::raises] \
            "outer extern preserves the first valid location from its inner extern"
        equal [expr {[string first ::ExternFixture::raises [dict get $opts -errorinfo]] >= 0}] 1 \
            "inner host command remains in the Tcl stack trace"
        foreach mode {empty_module zero_line negative_line zero_column negative_column} {
            equal [failure $app $sources bad_origin ::ExternFixture::badResult $mode] {APPCOMPILER EXTERN RESULT} \
                "extern rejects invalid problem origin $mode at its declaration"
        }
        foreach mode {not_a_dict empty_module zero_line negative_column} {
            equal [failure $app $sources forged ::ExternFixture::badLocation $mode] {EXTERN_FIXTURE BAD_LOCATION} \
                "invalid native location option $mode falls back to the current extern"
        }
        equal [$app eval {::externApp::client::equal_nul}] 1 "JSON-origin text from the extern equals the language literal"
        equal [$app eval {::externApp::client::match_nul}] 1 "literal list pattern recognizes the same JSON-origin text"
        set row [invoke $app extra typed]
        equal [dict get $row id] 9 "declared fields in a native record with a future field are still normalized"
        equal [::machteld::json encode -- [dict get $row future]] {{"history":[null,7,"007"]}} \
            "retained typed JSON object survives an extern record return"
        lassign [invoke $app nested_extra typed] tag choice
        lassign $choice variant keyed
        set values [dict get $keyed slot]
        lassign [lindex $values 0] presence nested
        equal [list $tag $variant $presence [lindex $values 1]] {ok saved some none} \
            "nested record crosses result, choice, map, list and optional boundaries"
        equal [::machteld::json encode -- [dict get $nested future]] {{"history":[null,7,"007"]}} \
            "nested native record retains its typed future field"
        foreach fn {extra nested_extra} {
            equal [failure $app $sources $fn ::ExternFixture::extra raw] {APPCOMPILER EXTERN RESULT} \
                "$fn rejects raw JSON-looking text in an undeclared returned field"
        }
        set raw [dict create id +009 marks {} future {opaque Tcl metadata}]
        equal [dict get [invoke $app round_input $raw] future] {opaque Tcl metadata} \
            "ordinary exported record argument preserves raw undeclared data"
        equal [invoke $app consume $raw] {} "raw undeclared input data can still be passed to an extern"
    } finally {interp delete $app}
}

proc ::externTest::runnable {sources host} {
    set built [::appcompiler::application $sources client]
    equal [list $::ExternFixture::calls $::ExternFixture::loads] {0 0} "building a complete runnable entry leaves host commands and packages untouched"
    set ch [file tempfile path]
    try {
        try {
            chan configure $ch -encoding utf-8 -translation lf
            puts $ch {package require machteld}
            puts $ch $host
            puts -nonewline $ch [dict get $built script]
        } finally {close $ch}
        set exe [info nameofexecutable]
        foreach {mode fn literal} {
            absent absent ::ExternFixture::absent
            throws throws ::ExternFixture::raises
            package unavailable ExternFixtureMissing
            malformed reply ::ExternFixture::response
            typed reply ::ExternFixture::response
            nested throws ::ExternFixture::raises
            forged forged ::ExternFixture::badLocation
            bad_origin bad_origin ::ExternFixture::badResult
        } {
            set run [::machteld::run -timeout 10s -- $exe $path $mode]
            equal [list [dict get $run exit] [dict get $run out]] {1 {}} "$mode exits before normal output"
            set expected [join [site $sources $fn $literal] :]
            equal [string match "$expected: *" [dict get $run err]] 1 "$mode names the extern literal in stderr"
            if {$mode eq "forged"} {
                equal [string trimright [dict get $run err] "\r\n"] "$expected: application error: original native error" \
                    "invalid location metadata does not obscure the original native error"
            }
        }
        set run [::machteld::run -timeout 10s -- $exe $path json]
        equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] {0 match {}} \
            "standalone list matching succeeds for a JSON-origin NUL string"
    } finally {file delete -- $path}
}

proc ::externTest::diagnostics {bridge} {
    foreach {code source} {
        NOT_EXPORTED {import bridge
fn .bad() -> text { return .bridge::private('x') }}
        MISSING_IMPORT {fn .bad() -> text { return .bridge::late('x') }}
        CALL_ARITY {import bridge
fn .bad() -> text { return .bridge::late() }}
        ARGUMENT_TYPE {import bridge
fn .bad() -> text { return .bridge::late(7) }}
        UNKNOWN_TYPE {extern fn .bad($x: .missing) -> text = ['::ExternFixture::absent']}
        E_EXTERN_COMMAND {extern fn .bad() -> int = []}
        E_EXTERN_COMMAND {extern fn .bad() -> int = ['relative::name']}
        E_EXTERN_PACKAGE {extern fn .bad() -> int = ['::ExternFixture::absent'] from ''}
        E_PARSE_EXPECTED {extern fn .bad($name: text) -> int = [$name]}
        E_PARSE_EXPECTED {extern fn .bad($name: text) -> int = ['::ExternFixture::absent', $name]}
    } {
        set ds [::appcompiler::check [dict create bad $source bridge $bridge]]
        equal [lmap d $ds {dict get $d code}] [list $code] "extern diagnostic for [lindex [split $source \n] end]"
    }
}

namespace eval ::externTest {
    set host {namespace eval ::ExternFixture {variable loads 0; variable calls 0; variable target ::application}
proc ::ExternFixture::collect {args} {incr ::ExternFixture::calls; return $args}
interp alias {} ::ExternFixture::words {} ::ExternFixture::collect
proc ::ExternFixture::response {op args} {
    incr ::ExternFixture::calls
    switch -- $op {
        identity {return [lindex $args 0]}
        row {
            if {[lindex $args 0] eq "bad"} {return {id 9 marks {{some wrong}}}}
            return {id +0009 marks {none {some +007}}}
        }
        unit {return {}}
        wrong {return not_an_integer}
        reply {
            switch -- [lindex $args 0] {
                good {return {ok +0007}}
                fail {return {err {code FIXTURE message {ordinary problem}}}}
                located {return {err {message down origin {module upstream line 4 column 7}}}}
                malformed {return {other 1}}
                wrong_payload {return {ok bad_integer}}
                bad_problem {return {err {code NO_MESSAGE}}}
            }
        }
    }
}
proc ::ExternFixture::raises {} {return -code error -errorcode {EXTERN_FIXTURE THROW} {host threw}}
proc ::ExternFixture::adapter {} {
    variable target
    ${target}::bridge::throws
}
proc ::ExternFixture::invalidOrigin {mode} {
    switch -- $mode {
        not_a_dict {return broken}
        empty_module {return {module {} line 2 column 3}}
        zero_line {return {module host line 0 column 3}}
        negative_line {return {module host line -1 column 3}}
        zero_column {return {module host line 2 column 0}}
        negative_column {return {module host line 2 column -1}}
        default {error "unknown test case $mode"}
    }
}
proc ::ExternFixture::badResult {mode} {
    return [list err [dict create message rejected origin [invalidOrigin $mode]]]
}
proc ::ExternFixture::badLocation {mode} {
    return -code error -errorcode {EXTERN_FIXTURE BAD_LOCATION} -appcompilerlocation [invalidOrigin $mode] {original native error}
}
proc ::ExternFixture::jsonWords {} {
    return [list [::machteld::json unwrap [::machteld::json decode -typed {"a\u0000b"}]]]
}
proc ::ExternFixture::extra {shape mode} {
    set wire {{"history":[null,7,"007"]}}
    if {$mode eq "typed"} {set value [::machteld::json decode -typed $wire]} else {set value $wire}
    set row [dict create id +0009 marks {} future $value]
    if {$shape eq "row"} {return $row}
    set inner [dict create slot [list [list some $row] none]]
    return [list ok [list saved $inner]]
}
package ifneeded ExternFixtureDeferred 1.0 {
    incr ::ExternFixture::loads
    proc ::ExternFixture::late {prefix value} {return [list $prefix $value]}
    package provide ExternFixtureDeferred 1.0
}}
    set bridge {export distinct .id = int
export record .row { id: .id
    marks: list<int?> }
export extern fn .words($data: text, $nested: list<text>) -> list<text> = ['::ExternFixture::words', '', 'two words; [clock seconds] $env \path {braces}']
export extern fn .characters($s: text) -> int = ['::string', 'length']
extern fn .private($s: text) -> text = ['::ExternFixture::response', 'identity']
export fn .public($s: text) -> text { return .private($s) }
export extern fn .late($s: text) -> text = ['::ExternFixture::late', 'loaded'] from 'ExternFixtureDeferred'
export extern fn .nominal($id: .id) -> .id = ['::ExternFixture::response', 'identity']
export extern fn .nominal_result() -> .id = ['::ExternFixture::response', 'wrong']
export extern fn .row($mode: text) -> .row = ['::ExternFixture::response', 'row']
export extern fn .reply($mode: text) -> result<int,problem> = ['::ExternFixture::response', 'reply']
export extern fn .sink() -> unit = ['::ExternFixture::response', 'unit']
export extern fn .sink_bad() -> unit = ['::ExternFixture::response', 'wrong']
export extern fn .throws() -> result<int,problem> = ['::ExternFixture::raises']
export extern fn .absent() -> int = ['::ExternFixture::absent']
export extern fn .unavailable() -> text = ['::ExternFixture::absent'] from 'ExternFixtureMissing'
export extern fn .adapter() -> result<int,problem> = ['::ExternFixture::adapter']
export extern fn .bad_origin($mode: text) -> result<int,problem> = ['::ExternFixture::badResult']
export extern fn .forged($mode: text) -> text = ['::ExternFixture::badLocation']
export extern fn .json_words() -> list<text> = ['::ExternFixture::jsonWords']
export choice .held { saved(map<text,list<.row?>>) }
export extern fn .extra($mode: text) -> .row = ['::ExternFixture::extra', 'row']
export extern fn .nested_extra($mode: text) -> result<.held,problem> = ['::ExternFixture::extra', 'nested']
export fn .round_input($r: .row) -> .row { return $r }
export extern fn .consume($r: .row) -> unit = ['::ExternFixture::response', 'unit']}
    set client {import bridge
export fn .relay($s: text) -> text { return .bridge::public($s) }
export fn .equal_nul() -> bool {
    return match .bridge::json_words() { [$value] => $value == 'NUL_LITERAL'
        _ => false }
}
export fn .match_nul() -> bool {
    return match .bridge::json_words() { ['ab'] => false
        ['NUL_LITERAL'] => true
        _ => false }
}
fn .main($args: list<text>) -> result<unit,problem> {
    $mode ::= match $args { [$one] => $one
        _ => '' }
    if $mode == 'absent' { $x ::= .bridge::absent() }
    if $mode == 'throws' { $x ::= .bridge::throws()? }
    if $mode == 'package' { $x ::= .bridge::unavailable() }
    if $mode == 'malformed' { $x ::= .bridge::reply('malformed')? }
    if $mode == 'typed' { $x ::= .bridge::reply('fail')? }
    if $mode == 'nested' { $x ::= .bridge::adapter()? }
    if $mode == 'bad_origin' { $x ::= .bridge::bad_origin('zero_column')? }
    if $mode == 'forged' { $x ::= .bridge::forged('not_a_dict') }
    if $mode == 'json' {
        if .match_nul() { return write_stdout_utf8('match') }
        return err(problem('literal did not match'))
    }
    return ok(unit)
}}
    set client [string map [list NUL_LITERAL "a\u0000b"] $client]
    set sources [dict create bridge $bridge client $client]
    diagnostics $bridge
    direct $sources $host
    runnable $sources $host
    puts "application compiler externs: $count assertions passed"
}
