package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

proc expect {actual expected label} {
    if {$actual ne $expected} {error "$label: expected [list $expected], received [list $actual]"}
    incr ::checks
}

proc example {} {
    set model {export record .item {
    version: int
    id: .item_id
    note: text?
    amount: .amount?
    metadata: .metadata?
    counts: map<.index,int>?
    tags: list<text>?
    quantity: int?
}
distinct .item_id = text
distinct .amount = decimal
distinct .index = int
record .entry { description: text }
alias .metadata = map<.item_id,.entry>
export choice .edit {
    keep
    clear
    set(text)
}
export fn .apply($item: .item, $edit: .edit) -> .item {
    return match $edit {
        .edit::keep => $item
        .edit::clear => $item with {note = none}
        .edit::set($text) => $item with {note = some($text)}
    }
}}
    set entry {import model
fn .arguments($args: list<text>) -> result<.model::edit, problem> {
    return match $args {
        [] => ok(.model::edit::keep)
        ['--clear'] => ok(.model::edit::clear)
        ['--set', $text] => ok(.model::edit::set($text))
        _ => err(problem('expected --clear or --set TEXT'))
    }
}
fn .main($args: list<text>) -> result<unit, problem> {
    $edit ::= .arguments($args)?
    $bytes ::= read_stdin_bytes()?
    $text ::= decode_utf8($bytes)?
    $item ::= decode_json<.model::item>($text)?
    if $item.version != 1 {return err(problem('unsupported version'))}
    $output ::= encode_json(.model::apply($item, $edit))?
    write_stdout_utf8($output)?
    return ok(unit)
}}
    return [dict create model $model entry $entry]
}

proc runCase {exe app arguments input exitCode expectedOut errorPattern} {
    set run [::machteld::run -timeout 20s -stdin $input -- $exe $app {*}$arguments]
    set label "[file tail $app] [list {*}$arguments]"
    expect [dict get $run exit] $exitCode "$label exit (stderr: [dict get $run err])"
    expect [dict get $run truncated] {} "$label complete streams"
    expect [binary encode hex [dict get $run out]] \
        [binary encode hex [encoding convertto utf-8 $expectedOut]] "$label stdout bytes"
    set err [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run err]] "\r\n"]
    if {![string match $errorPattern $err]} {error "$label stderr: expected [list $errorPattern], got [list $err]"}
    incr ::checks
}

proc exercise {exe app} {
    set document {{"version":1,"id":"007","note":"old","é":{"flags":[true,null,0.01000e+08],"large":999999999999999999999999999999}}}
    set clear [string map [list {"note":"old",} {}] $document]
    set input [encoding convertto utf-8 $document]
    runCase $exe $app {} $input 0 $document {}
    runCase $exe $app {--clear} $input 0 $clear {}
    runCase $exe $app [list --set {}] $input 0 [string map [list {"old"} {""}] $document] {}
    runCase $exe $app [list --set {雪 $[1]}] $input 0 \
        [string map [list {"old"} {"雪 $[1]"}] $document] {}
    runCase $exe $app {} [encoding convertto utf-8 $clear] 0 $clear {}
    runCase $exe $app {--set} [binary decode hex ff] 1 {} {entry:3:*: expected --clear or --set TEXT}
    runCase $exe $app {} [binary decode hex 61ff] 1 {} {entry:13:*: invalid UTF-8 at byte offset 1}
    runCase $exe $app {} [string map {{"version":1} {"version":2}} $document] 1 {} \
        {entry:15:*: unsupported version}
    runCase $exe $app {} [string map {{"007"} 7} $document] 1 {} {entry:14:*: *id*expects text*}
    runCase $exe $app {} [string map {{"old"} null} $document] 1 {} {entry:14:*: *note*expects text*}
    runCase $exe $app {} [string map [list {"id":"007",} {}] $document] 1 {} \
        {entry:14:*: *missing required field id}
    runCase $exe $app {} [encoding convertto utf-8 "\{"] 1 {} {entry:14:*}
    set amount {{"version":1,"id":"007","amount":-987654321012345678900.0012300,"future":1e+50}}
    set expected [string map {.0012300 .00123} $amount]
    runCase $exe $app {} [encoding convertto utf-8 $amount] 0 $expected {}
    runCase $exe $app {} [string map [list -987654321012345678900.0012300 {"1.23"}] $amount] \
        1 {} {entry:14:*: *amount*expects a decimal number*}
    runCase $exe $app {} [string map {-987654321012345678900.0012300 1e99} $amount] \
        1 {} {entry:14:*: *amount*expects a fixed-point JSON number}
    set metadata {{"version":1,"id":"a","metadata":{"007":{"description":"","future":[null,1e80]},"7":{"description":"é"},"":{"description":"雪"}}}}
    runCase $exe $app {} [encoding convertto utf-8 $metadata] 0 $metadata {}
    set nulKey [string map [list {"007":} {"a\u0000b":}] $metadata]
    runCase $exe $app {} [encoding convertto utf-8 $nulKey] 0 $nulKey {}
    set bad [string map [list {"description":"é"} {"description":false}] $metadata]
    runCase $exe $app {} [encoding convertto utf-8 $bad] 1 {} {entry:14:*: *description*expects text*}
    runCase $exe $app {} {{"version":1,"id":"a","counts":{"1":7}}} 1 {} {entry:14:*: *text*}
    set values {{"version":1,"id":"x","amount":-0.000,"quantity":340282366920938463463374607431768211457,"tags":["","a\u0000b","雪"],"future":[true,null,1.00e+7]}}
    runCase $exe $app {} [encoding convertto utf-8 $values] 0 [string map {-0.000 0} $values] {}
    set fraction [string map {-0.000 -0.00012000} $values]
    runCase $exe $app {} [encoding convertto utf-8 $fraction] 0 [string map {-0.00012000 -0.00012} $fraction] {}
    runCase $exe $app {} {{"version":1,"id":"x","quantity":1e2}} 1 {} {entry:14:*: *quantity expects an integer JSON literal}
    runCase $exe $app {} {{"version":1,"id":"x","quantity":1.00}} 1 {} {entry:14:*: *quantity expects an integer JSON literal}
    runCase $exe $app {} {{"version":1,"id":"x","tags":["ok",null,false]}} 1 {} {entry:14:*: *tags\[1\] expects text, got null}
    runCase $exe $app {} {{"version":1,"id":"x","tags":[null],"amount":1E+2}} 1 {} {entry:14:*: *amount expects a fixed-point JSON number}
}

proc checkJsonRowLists {} {
    set fields {flag: bool
        title: text
        detail: int?}
    set wide {}
    for {set i 0} {$i < 17} {incr i} {lappend wide "k$i: int"}
    set data "record .row {$fields}\nrecord .second {$fields}\nrecord .wide {[join $wide \n]}\n"
    append data {record .box<.t> { value: .t }
record .table {
    first: list<.row>
    other: list<.second>
    generic: list<.box<int>>?
    wide: list<.wide>?
}
export fn .read($wire: text) -> result<.table,problem> => decode_json<.table>($wire)}
    append data {
record .item { title: text }
record .unused { label: text }
record .page<.t,.other> {
    items: list<.t>
    unused: .other?
    next: .page<list<.t>,.other>?
}
export fn .page_read($wire: text) -> result<.page<.item,.unused>,problem> =>
    decode_json<.page<.item,.unused>>($wire)
}
    set compiled [::appcompiler::compile [dict create fixtures $data] ::jsonRows]
    namespace eval :: [dict get $compiled script]
    set readers [::jsonRows::@rt::jsonListReaders]
    expect [lsort [dict keys $readers]] {.fixtures::item .fixtures::row .fixtures::second} "only concrete small row lists get readers"
    expect [llength [lsort -unique [dict values $readers]]] 2 "share identical ordered row layouts"
    lassign [::jsonRows::fixtures::page_read {{"items":[{"title":"coil","future":[1.00e+2]}]}}] tag page
    expect $tag ok "generic page of concrete records"
    set item [lindex [dict get $page items] 0]
    expect [dict get $item title] coil "declared page item field"
    expect [::machteld::json encode -- [dict get $item future]] {[1.00e+2]} "page item retains unknown evidence"
    lassign [::jsonRows::fixtures::page_read {{"items":[{"title":"coil"},{"title":1}]}}] tag problem
    expect [list $tag [dict get $problem message]] [list err {value.items[1].title expects text, got number}] "generic page diagnostic"
    set reader [dict get $readers .fixtures::row]
    set ::reads 0
    set count [list apply {{command operation} {incr ::reads}}]
    trace add execution $reader enter $count
    try {
        set wire {{"first":[{"flag":true,"title":"x","detail":5,"extra":[true,1.00e+7]},{"flag":false,"title":"雪\u0000"}],"other":[],"generic":[{"value":11}]}}
        lassign [::jsonRows::fixtures::read $wire] tag value
        expect $tag ok "typed rows decode"
        lassign [dict get $value first] first next
        expect [dict get $first detail] {some 5} "present optional in first row"
        expect [list [dict get $next title] [dict exists $next detail]] [list "雪\u0000" 0] "omitted optional stays absent in following row"
        expect [::machteld::json type [dict get $first extra]] array "unknown field retains its JSON type"
        expect [::machteld::json encode -- [dict get $first extra]] {[true,1.00e+7]} "unknown field retains number spelling"
        expect [dict get [lindex [lindex [dict get $value generic] 1] 0] value] 11 "nested generic uses its schema"
        expect [expr {$::reads > 0}] [::jsonRows::@rt::jsonHasChildren] "only capable hosts call the generated reader"
    } finally {trace remove execution $reader enter $count; unset ::reads}
    foreach {bad message} {
        {[]} {value.first[1] expects an object, got array}
        {{"title":"text"}} {value.first[1] is missing required field flag}
        {{"flag":1,"title":false}} {value.first[1].flag expects a boolean, got number}
        {{"flag":true,"title":false}} {value.first[1].title expects text, got boolean}
    } {
        set wire [format {{"other":[],"first":[{"title":"ok","flag":true},%s]}} $bad]
        lassign [::jsonRows::fixtures::read $wire] tag problem
        expect [list $tag [dict get $problem code] [dict get $problem message]] [list err JSON_SCHEMA $message] "first failing row and field"
    }
}

proc writeArtifact {sources directory} {
    set artifact [::appcompiler::application $sources entry]
    set ch [open [file join $directory main.tcl] wb]
    try {puts -nonewline $ch [encoding convertto utf-8 [dict get $artifact script]]} finally {close $ch}
}

set checks 0
checkJsonRowLists
set argspec [lrange $argv 0 end]
if {$argspec ni {{} -pack}} {error "expected optional -pack"}
set exe [info nameofexecutable]
set sources [example]
set root [file normalize [file tempdir]]
try {
    set source [file join $root {source directory}]
    file mkdir $source
    writeArtifact $sources $source
    exercise $exe [file join $source main.tcl]
    foreach {entryModule entryFn code} {unknown main ENTRY_NAME model apply ENTRY_TYPE} {
        expect [catch {::appcompiler::application $sources $entryModule $entryFn} msg opts] 1 $code
        expect [dict get [lindex [dict get $opts -diagnostics] 0] code] $code "entry diagnostic"
    }
    if {$argspec eq "-pack"} {
        set delivery [file join $root {relocated release}]
        file mkdir $delivery
        set archive [file join $delivery example.machteld]
        set packed [::machteld::run -timeout 20s -- $exe pack $source -o $archive]
        if {[dict get $packed exit] != 0} {error "pack: [dict get $packed err]"}
        set copy [file join $delivery machteld.exe]
        file copy $exe $copy
        exercise $copy $archive
    }
} finally {
    if {[file normalize $root] eq $root && [file dirname $root] ne $root} {file delete -force -- $root}
}
puts "compiled application I/O: $checks assertions passed"
