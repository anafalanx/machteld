package require machteld

namespace eval ::referenceTest {variable count 0}

proc ::referenceTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}

proc ::referenceTest::write {path text} {
    set file [open $path wb]
    try {puts -nonewline $file [encoding convertto -profile strict utf-8 $text]} finally {close $file}
}

proc ::referenceTest::invoke {directory driver succeeds args} {
    set run [::machteld::run -dir $directory -timeout 30s -- [info nameofexecutable] $driver {*}$args]
    set exit [dict get $run exit]
    set out [encoding convertfrom -profile strict utf-8 [dict get $run out]]
    set err [encoding convertfrom -profile strict utf-8 [dict get $run err]]
    if {$exit eq "" || [dict get $run truncated] ne "" || ($exit == 0) != $succeeds} {
        error "unexpected result for [list {*}$args]: exit $exit, stdout [list $out], stderr [list $err]"
    }
    if {$succeeds} {
        equal $err {} "successful command stderr"
        return $out
    }
    equal $out {} "failed command stdout"
    equal [expr {$err ne {}}] 1 "failed command explains the error"
}

proc ::referenceTest::ids {output} {
    set output [string trimright $output "\r\n"]
    if {$output eq ""} {return {}}
    return [split [string map [list "\r\n" "\n"] $output] \n]
}

proc ::referenceTest::fixture {project} {
    file mkdir $project
    write [file join $project project.dict] {schema 1
edition 1
minApi 0.21
entry {guide main}
modules {guide app.src}}
    set example {example .decorate(
  'horloge 雪'  # keep this comment and spacing
) => 'horloge 雪'}
    set example [string map [list \n \r\n] $example]
    set source {## sharedneedle glossary
export alias .word = text
## A@NUL@B雪
export distinct .serial = int
## A record for catalog entries.
export record .note {
    title: .word
    serial: .serial
}
export choice .phase {
    empty
    active(.word, int)
}
extern fn .entry_marker() -> text = ['::open', 'entry-ran', 'w']
extern fn .example_marker() -> text = ['::open', 'example-ran', 'w']
## privateindexneedle
fn .private() -> int => 4
## sharedneedle cadenceprobe
## Before 🚆雪 after. Keep **Markdown** and literal [brackets].
## Cafébrise and @DECOMPOSED@.
export fn .decorate($value: .word) -> .word {
    $ignored ::= .example_marker()
    return $value
}
@EXAMPLE@
export extern fn .count($v: .word) -> int = ['::string','length']
example .count('ab') => 2
fn .main($args: list<text>) -> result<unit,problem> {
    $ignored ::= .entry_marker()
    return ok(unit)
}}
    set source [string map [list @EXAMPLE@ $example @DECOMPOSED@ "E\u0301cureuil" @NUL@ \u0000] $source]
    write [file join $project app.src] $source
    return $example
}

proc ::referenceTest::run {work checkoutDriver} {
    set project [file join $work author]
    set example [fixture $project]
    set initial [file join $work original.machteld]
    invoke $work $checkoutDriver 1 pack [file join $project project.dict] $initial
    foreach name {entry-ran example-ran} {equal [file exists [file join $work $name]] 0 "pack leaves $name absent"}
    file delete -- [file join $project app.src] [file join $project project.dict] $project

    set recipient [file join $work {offline recipient 雪}]
    file mkdir $recipient
    set archive [file join $recipient {renamed reference.machteld}]
    file rename -- $initial $archive
    set mount [zipfs mount $archive reference-test]
    try {
        ::machteld::ArchiveEntry $mount
        equal [file isfile [file join $mount project reference.db]] 1 "reference present in the verified archive"
        file copy -- [file join $mount compiler] [file join $recipient local-compiler]
    } finally {zipfs unmount $mount}
    # All remaining CLI calls use the copied driver after closing the mount.
    set driver [file join $recipient local-compiler driver.tcl]
    set prefix [list docs [file tail $archive]]
    set fn fn/guide/decorate
    set page [invoke $recipient $driver 1 {*}$prefix get $fn]
    foreach fragment [list {# .guide::decorate} {export fn .decorate($value: .word) -> .word} \
            {Before 🚆雪 after. Keep **Markdown** and literal [brackets].} $example] {
        equal [expr {[string first $fragment $page] >= 0}] 1 "function reference preserves [list $fragment]"
    }
    equal [string first $example $page] [string last $example $page] "one copy of the executable example"
    set extern [invoke $recipient $driver 1 {*}$prefix get fn/guide/count]
    equal [expr {[string first {export extern fn .count($v: .word) -> int} $extern] >= 0}] 1 "external function signature"
    equal [expr {[string first {example .count('ab') => 2} $extern] >= 0}] 1 "external function owns its example"
    equal [string first $example $extern] -1 "another function's example is excluded"
    equal [string first {example .count('ab') => 2} $page] -1 "examples stay with their owner"
    equal [ids [invoke $recipient $driver 1 {*}$prefix search cadenceprobe]] [list $fn] "doc comments are searchable"
    foreach term [list cafébrise "cafe\u0301brise" Écureuil "E\u0301cureuil"] {
        equal [ids [invoke $recipient $driver 1 {*}$prefix search $term]] [list $fn] \
            "composed and decomposed source and query accents match for [list $term]"
    }
    equal [lsort [ids [invoke $recipient $driver 1 {*}$prefix search sharedneedle]]] \
        [lsort [list $fn type/guide/word]] "search includes both documented exports"
    equal [llength [ids [invoke $recipient $driver 1 {*}$prefix search sharedneedle 1]]] 1 "search limit"
    equal [ids [invoke $recipient $driver 1 {*}$prefix search privateindexneedle]] {} "private docs excluded from the index"
    invoke $recipient $driver 0 {*}$prefix get fn/guide/private
    foreach {id fragments} {
        type/guide/word {{export alias .word = text}}
        type/guide/serial {{export distinct .serial = int}}
        type/guide/note {{export record .note} {    title: .word} {    serial: .serial}}
        type/guide/phase {{export choice .phase} {    empty} {    active(.word, int)}}
    } {
        set typePage [invoke $recipient $driver 1 {*}$prefix get $id]
        foreach fragment $fragments {
            equal [expr {[string first $fragment $typePage] >= 0}] 1 "$id contains [list $fragment]"
        }
    }
    set at [string first 🚆 $page]
    equal [invoke $recipient $driver 1 {*}$prefix get $fn $at 2] 🚆雪 "get uses Unicode character offsets"
    set nulPage [invoke $recipient $driver 1 {*}$prefix get type/guide/serial]
    set nulAt [string first "A\u0000B雪" $nulPage]
    equal [expr {$nulAt >= 0}] 1 "a doc comment preserves an embedded NUL"
    equal [invoke $recipient $driver 1 {*}$prefix get type/guide/serial [expr {$nulAt+1}] 3] "\u0000B雪" \
        "documentation slices include text beyond an embedded NUL"
    equal [invoke $recipient $driver 1 {*}$prefix get $fn [string length $page] 10] {} "get at end is empty"
    foreach invalid [list [list get $fn -1 2] [list get $fn 2147483648 2] [list get $fn 0 1048577] \
            [list search sharedneedle 0] [list search sharedneedle 201]] {
        invoke $recipient $driver 0 {*}$prefix {*}$invalid
    }

    set query {channel encoding}
    set native [::machteld::docs search $query -limit 2]
    set expected [lmap hit [dict get $native items] {dict get $hit id}]
    equal [expr {[llength $expected] > 0}] 1 "runtime search fixture finds pages"
    equal [ids [invoke $recipient $driver 1 docs --runtime search $query 2]] $expected "runtime search uses native IDs"
    set runtimeId tcl/command/dict
    set native [dict get [::machteld::docs get $runtimeId -offset 3 -limit 19] text]
    equal [invoke $recipient $driver 1 docs --runtime get $runtimeId 3 19] $native "exact slice of native runtime Markdown"
    invoke $recipient $driver 0 docs --runtime get no/such/page

    # A verified archive predating the application reference still has an
    # executable entry. A docs request must not fall back to executing it.
    set old [file join $work old]
    file mkdir $old
    write [file join $old main.tcl] "package require machteld\nclose \[open old-entry-ran w\]\n"
    ::machteld::PackArchive $old -o [file join $recipient old.machteld]
    invoke $recipient $driver 0 docs old.machteld search sharedneedle
    file mkdir [file join $old project]
    write [file join $old project reference.db] {invalid SQLite bytes}
    ::machteld::PackArchive $old -o [file join $recipient broken-reference.machteld]
    invoke $recipient $driver 0 docs broken-reference.machteld get $fn
    write [file join $recipient corrupt.machteld] {invalid archive}
    invoke $recipient $driver 0 docs corrupt.machteld get $fn
    foreach name {entry-ran example-ran old-entry-ran} {
        equal [file exists [file join $recipient $name]] 0 "query leaves $name absent"
    }
}

set driver [file normalize [file join [file dirname [info script]] .. tools application_project.tcl]]
set work [file normalize [file tempdir]]
try {
    ::referenceTest::run $work $driver
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler reference: $::referenceTest::count assertions passed"
