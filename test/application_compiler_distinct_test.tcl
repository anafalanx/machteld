package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::distinctTest {variable count 0}
proc ::distinctTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::distinctTest::call {app name args} {
    $app eval [list ::distinctApp::client::$name {*}$args]
}
proc ::distinctTest::badBoundary {app name args} {
    set status [catch {call $app $name {*}$args} message opts]
    equal [list $status [dict get $opts -errorcode]] {1 {APPCOMPILER ARGUMENT TYPE}} \
        "exported function $name checks the underlying Tcl value"
}

proc ::distinctTest::runtime {sources} {
    equal [::appcompiler::check $sources] {} "distinct types, reexports, and a forward primitive alias check"
    set generated [::appcompiler::compile $sources ::distinctApp]
    set app [interp create]
    try {
        $app eval [dict get $generated script]
        foreach value [list {} 007 {é 雪 $v [x]}] {
            equal [call $app identify $value] $value "text identity has the original Tcl representation"
            equal [call $app spell [call $app identify $value]] $value "explicit extraction preserves text"
        }
        equal [call $app same 007 7] 0 "nominal text equality preserves distinct spellings"
        equal [call $app same 007 007] 1 "two aliases of one nominal identity compare equal"
        equal [call $app relabel 007] 007 "explicit extraction and reconstruction can cross two same-module identities"
        set big 90071992547409931234567890123456789
        equal [call $app plus_one +000$big] [expr {$big + 1}] "explicitly extracted integer can be incremented and reconstructed"
        equal [call $app normalized -0.0100] -0.01 "extraction exposes a canonical exact decimal"
        equal [call $app same_decimal 9007199254740992.0001 9007199254740992.0002] 0 \
            "exact equality of one nominal decimal type"
        equal [call $app bool_value false] 0 "boolean distinct uses the bool representation"
        set binary [binary decode hex 00ff80]
        equal [binary encode hex [call $app bytes_value $binary]] 00ff80 "explicitly constructed bytes preserve all octets"
        badBoundary $app plus_one 2.5
        badBoundary $app normalized 1e2
        badBoundary $app bool_value 7
        badBoundary $app unblob 雪

        set catalog [call $app text_map 007 7]
        equal [dict keys $catalog] {007 7} "nominal text map keys retain their underlying spellings"
        equal [call $app lookup $catalog 007] {some first} "nominal optional lookup"
        equal [call $app lookup $catalog 8] none "missing nominal key"
        equal [call $app integers [dict create $big big -0009 small +002 mid]] [list -9 2 $big] \
            "nominal integer keys use exact numeric sorting and boundary normalization"
        equal [call $app decimals [dict create 9007199254740992.0002 b -0.10 neg 9007199254740992.00010 a]] \
            {-0.1 9007199254740992.0001 9007199254740992.0002} "nominal decimal keys use exact ordering"
        badBoundary $app integers [dict create 007 a 7 b]
        set leaf [dict create here 007 edges [list [list id 007] stop]]
        set tree [dict create here root edges [list [list branch $leaf]]]
        equal [call $app trees $tree $tree] 1 "recursive record and choice equality recognizes comparable distinct payloads"
        set changed [dict replace $tree edges [list [list branch [dict replace $leaf here 7]]]]
        equal [call $app trees $tree $changed] 0 "deep text identity still distinguishes leading zeroes"
        equal [call $app required [dict create 007 4] 007] {ok 4} "typed lookup accepts an explicitly constructed key"
        lassign [call $app required {} 007] tag problem
        set origin [dict get $problem origin]
        set line [lsearch -exact [split [dict get $sources client] \n] {    $n ::= require_key($m, make<.api::key>($spelling))?}]
        equal [list $tag [dict get $problem code] [dict get $origin module] [dict get $origin line]] \
            [list err MISSING_KEY client [expr {$line + 1}]] "typed failure with an explicitly constructed key keeps its source location"
    } finally {interp delete $app}
}

proc ::distinctTest::diagnostics {types} {
    foreach {expected body} {
        OPERAND_TYPE {fn .bad($a: .left::id, $b: .right::id) -> bool { return $a == $b }}
        OPERAND_TYPE {fn .bad($a: .left::id, $b: .left::other_id) -> bool { return $a == $b }}
        OPERAND_TYPE {fn .bad($a: .left::id) -> bool { return $a == 'id' }}
        OPERAND_TYPE {fn .bad($a: .left::count) -> int { return $a + 1 }}
        RETURN_TYPE {fn .bad($x: .left::id) -> .right::id { return $x }}
        RETURN_TYPE {fn .bad($x: text) -> .left::id { return $x }}
        RETURN_TYPE {fn .bad($x: .left::id) -> text { return $x }}
        ARGUMENT_TYPE {fn .wants($x: .left::id) -> unit { return unit }
fn .bad($x: .right::id) -> unit { return .wants($x) }}
        ARGUMENT_TYPE {fn .wants($x: text) -> unit { return unit }
fn .bad($x: .left::id) -> unit { return .wants($x) }}
        ARGUMENT_TYPE {fn .bad($x: .right::id) -> .left::id { return make<.left::id>($x) }}
        EXPECTED_DISTINCT {fn .bad($s: text) -> text { return make<text>($s) }}
        EXPECTED_DISTINCT {fn .bad($s: text) -> text { return underlying($s) }}
        MAP_KEY_TYPE {fn .bad($m: map<.left::id,int>, $k: text) -> int? { return $m[$k] }}
        RETURN_TYPE {fn .bad($m: map<.left::id,int>) -> list<text> { return sorted_keys($m) }}
        MAP_KEY_TYPE {fn .bad($m: map<.left::id,int>, $k: .right::id) -> map<.left::id,int> {
    return map_put($m, $k, 1)
}}
        MAP_KEY_TYPE {alias .bad = map<.left::blob,int>}
        NOT_COMPARABLE {fn .bad($x: .left::blob) -> bool { return $x == $x }}
        NOT_COMPARABLE {choice .edge { finish
    next(.tree)
    raw(.left::blob) }
record .tree { children: list<.edge> }
fn .bad($x: .tree) -> bool { return $x == $x }}
        DISTINCT_BASE_TYPE {distinct .bad = .left::id}
        DISTINCT_BASE_TYPE {distinct .bad = list<int>}
    } {
        set source "import left\nimport right\n$body"
        set ds [::appcompiler::check [dict merge $types [dict create bad $source]]]
        equal [lmap d $ds {dict get $d code}] [list $expected] "distinct diagnostic $expected for [lindex [split $body \n] 0]"
    }
    set source {import left
fn .bad() -> .left::id { return make<.left::id>(23) }
fn .other() -> int { return $absent }}
    set ds [::appcompiler::check [dict merge $types [dict create bad $source]]]
    equal [lsort [lmap d $ds {dict get $d code}]] {ARGUMENT_TYPE UNKNOWN_BINDING} \
        "invalid construction and an independent binding error"
    foreach d $ds {
        if {[dict get $d code] ne "ARGUMENT_TYPE"} continue
        set n [dict get $d node]
        set span [string range [lindex [split $source \n] 1] [expr {[dict get $n column]-1}] [expr {[dict get $n endColumn]-2}]]
        equal [list [dict get $n module] [dict get $n line] $span] {bad 2 23} "constructor diagnostic identifies its wrong scalar argument"
    }
    set cycle {distinct .a = .b
alias .b = .a
fn .other() -> bool { return 1 }}
    set ds [::appcompiler::check [dict create cycle $cycle]]
    equal [lsort -unique [lmap d $ds {dict get $d code}]] {DISTINCT_CYCLE RETURN_TYPE} "cycle involving a distinct base preserves independent errors"
    set source {import left
fn .main($args: list<.left::id>) -> result<unit,problem> { return ok(unit) }}
    set project [dict merge $types [dict create entry $source]]
    equal [::appcompiler::check $project] {} "a nominal list element is valid for an ordinary function"
    set status [catch {::appcompiler::application $project entry} message opts]
    equal [list $status [dict get $opts -errorcode]] {1 {APPCOMPILER CHECK}} "entry has no implicit conversion of its argv element"
    equal [lmap d [dict get $opts -diagnostics] {dict get $d code}] ENTRY_TYPE "entry identity mismatch is diagnosed"
}

namespace eval ::distinctTest {
    set left {export distinct .id = .spelling
export distinct .other_id = text
export alias .public_id = .id
export distinct .count = .number
export distinct .price = decimal
export distinct .flag = bool
export distinct .blob = bytes
alias .spelling = text
alias .number = int
export record .tree { here: .id
    edges: list<.edge> }
export choice .edge { stop
    id(.id)
    branch(.tree) }}
    set right {export distinct .id = text}
    set api {import left
export alias .key = .left::public_id
export alias .same_key = .left::id
export alias .other_key = .left::other_id
export alias .number = .left::count
export alias .price = .left::price
export alias .flag = .left::flag
export alias .blob = .left::blob
export alias .tree = .left::tree}
    set client {import api
export fn .identify($s: text) -> .api::key { return make<.api::key>($s) }
export fn .spell($s: .api::key) -> text { return underlying($s) }
export fn .same($a: .api::key, $b: .api::same_key) -> bool { return $a == $b }
export fn .relabel($s: .api::key) -> .api::other_key { return make<.api::other_key>(underlying($s)) }
export fn .plus_one($a: .api::number) -> .api::number { return make<.api::number>(underlying($a) + 1) }
export fn .normalized($x: .api::price) -> decimal { return underlying($x) }
export fn .same_decimal($a: .api::price, $b: .api::price) -> bool { return $a == $b }
export fn .bool_value($flag: .api::flag) -> bool { return underlying($flag) }
export fn .bytes_value($raw: bytes) -> bytes { return underlying(make<.api::blob>($raw)) }
export fn .unblob($raw: .api::blob) -> bytes { return underlying($raw) }
export fn .text_map($a: text, $b: text) -> map<.api::key,text> {
    $m := map<.api::key,text>()
    $m = map_put($m, make<.api::key>($a), 'first')
    return map_put($m, make<.api::key>($b), 'second')
}
export fn .lookup($m: map<.api::key,text>, $k: .api::key) -> text? { return $m[$k] }
export fn .integers($m: map<.api::number,text>) -> list<.api::number> { return sorted_keys($m) }
export fn .decimals($m: map<.api::price,text>) -> list<.api::price> { return sorted_keys($m) }
export fn .trees($a: .api::tree, $b: .api::tree) -> bool { return $a == $b }
export fn .required($m: map<.api::key,int>, $spelling: text) -> result<int,problem> {
    $n ::= require_key($m, make<.api::key>($spelling))?
    return ok($n)
}}
    set types [dict create left $left right $right]
    set sources [dict merge $types [dict create client $client api $api]]
    runtime $sources
    diagnostics $types
    puts "application compiler distinct scalars: $count assertions passed"
}
