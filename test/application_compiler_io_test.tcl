package require machteld
lappend auto_path [file join [file dirname [info script]] .. packages application-compiler]
package require application-compiler 0.1

proc expect {actual expected label} {
    if {$actual ne $expected} {error "$label: expected [list $expected], received [list $actual]"}
    incr ::checks
}

proc example {} {
    set model {export record .item {
    version: int
    id: text
    note: text?
    amount: decimal?
    metadata: .metadata?
    counts: map<int,int>?
}
record .entry { description: text }
alias .metadata = map<text,.entry>
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
}

proc writeArtifact {sources directory} {
    set artifact [::appcompiler::application $sources entry]
    set ch [open [file join $directory main.tcl] wb]
    try {puts -nonewline $ch [encoding convertto utf-8 [dict get $artifact script]]} finally {close $ch}
}

set checks 0
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
