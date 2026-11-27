package require machteld

namespace eval ::exampleTest {variable count 0}
proc ::exampleTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::exampleTest::write {path text} {
    set ch [open $path wb]
    try {puts -nonewline $ch [encoding convertto -profile strict utf-8 $text]} finally {close $ch}
}
proc ::exampleTest::readText {path} {
    set ch [open $path rb]
    try {return [encoding convertfrom -profile strict utf-8 [read $ch]]} finally {close $ch}
}
proc ::exampleTest::invoke {exe cwd args} {
    set r [::machteld::run -dir $cwd -timeout 20s -- $exe {*}$args]
    if {[dict get $r exit] eq {} || [dict get $r truncated] ne {}} {error "incomplete command: [list {*}$args]"}
    foreach key {out err} {
        set text [encoding convertfrom -profile strict utf-8 [dict get $r $key]]
        dict set r $key [string trimright [string map [list \r\n \n] $text] \n]
    }
    return $r
}
proc ::exampleTest::clean {exe cwd args} {
    set r [invoke $exe $cwd {*}$args]
    if {[dict get $r exit] != 0} {error "failed [list {*}$args]: [dict get $r err] [dict get $r out]"}
    equal [dict get $r err] {} "successful command stderr"
    return [dict get $r out]
}
proc ::exampleTest::log {cwd} {
    set path [file join $cwd calls]
    if {![file exists $path]} {return {}}
    return [split [string trimright [string map [list \r\n \n] [readText $path]] \n] \n]
}
proc ::exampleTest::project {directory} {
    file mkdir [file join $directory lib]
    write [file join $directory project.dict] {schema 1 edition 1 minApi 0.21 entry {app main}
modules {app main.src calc calc.src} assets {lib/pkgIndex.tcl lib/demo.tcl} packageDirs lib}
    write [file join $directory main.src] {import calc
extern fn .entered() -> unit = ['::file', 'mkdir', 'entry-started']
fn .main($args: list<text>) -> result<unit,problem> => ok(.entered())
}
    write [file join $directory lib pkgIndex.tcl] {
        file mkdir index-read
        package ifneeded ExampleOps 1.0 [list source [file join $dir demo.tcl]]
    }
    write [file join $directory lib demo.tcl] {namespace eval ::exampleOps {
    proc mark {label} {
        set ch [open calls a]
        try {puts $ch $label} finally {close $ch}
    }
    proc count {label n} {mark $label; return $n}
    proc reply {mode} {
        mark $mode
        switch -- $mode {
            success {return {ok 2}}
            throws {return -code error -errorcode {FIXTURE IMPORT} {provider raised an exception}}
        }
        set p [dict create code IMPORT message "wording $mode" \
            origin [dict create module "origin-$mode" line 9 column 3] byteOffset 2 tag 007]
        if {$mode ne "missing"} {dict set p empty {}}
        if {$mode eq "no_code"} {dict unset p code}
        if {$mode eq "bad_native_field"} {dict set p rank two}
        return [list err $p]
    }
}
package provide ExampleOps 1.0}
    set calculation {extern fn .count($tag: text, $n: int) -> int = ['::exampleOps::count'] from 'ExampleOps'
fn .seconds($n: int) -> int => $n * 60
example .seconds(.count('actual', 2)) => .count('expected', 120)
extern fn .reply($mode: text) -> result<int,problem> = ['::exampleOps::reply'] from 'ExampleOps'
example .reply('first') => error 'IMPORT'
example .reply('second') => error 'IMPORT' { byteOffset = .count('offset', 2), tag = '007', empty = '' }
example .reply('success') => .count('unwrapped', 2)
}
    write [file join $directory calc.src] $calculation
    return $calculation
}

proc ::exampleTest::exampleSpan {source row} {
    set lines [split $source \n]
    set at [lsearch -exact $lines $row]
    if {$at < 0} {error "example not present in fixture: $row"}
    set line [expr {$at + 1}]
    return [format {calc:%d:1..%d:%d} $line $line [expr {[string length $row] + 1}]]
}

proc ::exampleTest::failureLine {errors source row} {
    set span [exampleSpan $source $row]
    foreach line [split $errors \n] {
        if {[string first "$span \[EXAMPLE_FAILED\]" $line] == 0} {return $line}
    }
    error "missing located failure $span in: $errors"
}

proc ::exampleTest::operandSpans {} {
    set source {fn .value($n: int) -> int => $n
example .value(
  1 # preserve this part of the call
) =>
  (1 +
   0)
extern fn .reply($s: text) -> result<int,problem> = ['::unused::reply']
example .reply('雪') =>
  error 'E' {
    message = '雪'
  }}
    set source [string map [list \n \r\n] $source]
    set module [::appcompiler::parseModule calc $source]
    lassign [dict get $module examples] value failure
    foreach item [list $value $value $failure $failure] key {actualLocation expectedLocation actualLocation expectedLocation} \
            span {{2 9 4 2} {5 3 6 6} {8 9 8 20} {9 3 11 4}} {
        set pos [dict get $item $key]
        set actual [lmap part {module line column endLine endColumn} {dict get $pos $part}]
        equal $actual [list calc {*}$span] "$key retains the complete expression or error expectation"
    }
}

proc ::exampleTest::direct {exe dir driver source} {
    set path [file join $dir calc.src]
    write $path {}
    equal [clean $exe $dir $driver test project.dict] {0 examples: 0 passed, 0 failed} "a project with no examples has no test work"
    write $path $source
    set check [clean $exe $dir $driver check --json project.dict]
    set report [::machteld::json unwrap [::machteld::json decode -typed $check]]
    equal [dict get $report diagnostics] {} "checked examples with local private and extern declarations"
    equal [file exists [file join $dir index-read]] 0 "checking did not load the fixture package"
    equal [log $dir] {} "checking did not evaluate examples"
    equal [file exists [file join $dir entry-started]] 0 "checking did not run the entry"
    clean $exe $dir $driver run project.dict
    equal [file exists [file join $dir entry-started]] 1 "ordinary execution runs the entry"
    equal [log $dir] {} "ordinary execution leaves example expressions inert"
    file delete -- [file join $dir entry-started]

    equal [clean $exe $dir $driver test project.dict] {4 examples: 4 passed, 0 failed} "regular values, ok payload and selected error fields"
    equal [log $dir] {actual expected first second offset success unwrapped} "each requested expression runs once, actual before expected"
    equal [file exists [file join $dir entry-started]] 0 "explicit test leaves entry inert"
    file delete -- [file join $dir calls]
    set failures {
        {example .reply('success') => error 'IMPORT'}
        {example .reply('throws') => error 'IMPORT'}
        {example .reply('missing') => error 'IMPORT' { empty = '' }}
        {example .reply('wrong_code') => error 'OTHER'}
        {example .reply('wrong_field') => error 'IMPORT' { tag = '7' }}
        {example .reply('wanted_ok') => 2}
        {example .reply('no_code') => error 'IMPORT'}
        {example .reply('bad_native_field') => error 'IMPORT' { rank = 2 }}
        {example .reply('last') => error 'IMPORT' { message = 'wording last' }}
    }
    set broken "$source[join $failures \n]\n"
    write $path $broken
    set r [invoke $exe $dir $driver test project.dict]
    equal [dict get $r exit] 1 "independent failures exit nonzero"
    equal [dict get $r out] {13 examples: 5 passed, 8 failed} "independent outcomes include the last passing example"
    set errors [dict get $r err]
    foreach row [lrange $failures 0 end-1] fragment {ok {Tcl error} empty OTHER tag {expected success} {without code} rank} {
        set line [failureLine $errors $broken $row]
        equal [string match -nocase "*$fragment*" $line] 1 "located mismatch identifies $fragment"
    }
    equal [log $dir] {actual expected first second offset success unwrapped success throws missing wrong_code wrong_field wanted_ok no_code bad_native_field last} \
        "each actual runs once and later examples run after a native fault"
    file delete -- [file join $dir calls]

    # Compile-time errors in different declarations are available to editors
    # without invoking either the actual or expected expression.
    set invalid {fn .scalar($n: int) -> int => $n
example .scalar(1) => error 'WRONG'
extern fn .reply($mode: text) -> result<int,problem> = ['::exampleOps::reply'] from 'ExampleOps'
example .reply('bad') => error 'IMPORT' { byteOffset = 'two' }
fn .value($n: int) -> int => $n
example .value(1) => 'one'
extern fn .data() -> bytes = ['::unused::data']
example .data() => .data()
example .value(1) => 1
extern fn .another($s: text) -> result<int,problem> = ['::unused::reply']
example .another('x') => error 'E' { message = 'first', message = 'again' }
}
    write $path $invalid
    set r [invoke $exe $dir $driver check --json project.dict]
    equal [dict get $r exit] 1 "bad example declarations fail checking"
    equal [dict get $r err] {} "bad example JSON check uses stdout"
    set report [::machteld::json unwrap [::machteld::json decode -typed [dict get $r out]]]
    set found {}
    foreach d [dict get $report diagnostics] {
        set node [dict get $d node]
        dict set found [dict get $d code] [list [dict get $node module] [dict get $node line] \
            [dict get $node column] [dict get $node endLine] [dict get $node endColumn]]
    }
    foreach {code line token} {
        EXAMPLE_ERROR_TYPE 2 'WRONG' EXAMPLE_FIELD_TYPE 4 'two' OPERAND_TYPE 6 'one'
        NOT_COMPARABLE 8 .data EXAMPLE_OWNER 9 .value EXAMPLE_DUPLICATE_FIELD 11 message
    } {
        set row [lindex [split $invalid \n] $line-1]
        set column [expr {1 + [string last $token $row]}]
        equal [dict get $found $code] [list calc $line $column $line [expr {$column + [string length $token]}]] \
            "located $code at its offending token"
    }
    equal [log $dir] {} "invalid examples are checked without executing code"
    set multiline {fn .value($n: int) -> int => $n
example .value(
    3) =>
    4}
    write $path [string map [list \n \r\n] $multiline]
    set r [invoke $exe $dir $driver test project.dict]
    equal [dict get $r exit] 1 "a multiline failed example exits nonzero"
    equal [string first {calc:2:1..4:6 [EXAMPLE_FAILED]} [dict get $r err]] 0 "failed example spans both operands across physical CRLF lines"
    write $path $source
}
proc ::exampleTest::packed {exe original driver source work} {
    set kit [file join $work recipient]
    file mkdir $kit
    set archive [file join $kit sample.machteld]
    set marker [file join $original index-read]
    file delete -- $marker
    clean $exe $original $driver pack project.dict $archive
    equal [file exists $marker] 0 "packing does not load a declared fixture"
    equal [log $original] {} "packing does not execute examples"
    equal [file exists [file join $original entry-started]] 0 "packing does not execute the entry"
    set copied [file join $kit machteld.exe]
    file copy -- $exe $copied
    equal [lsort [glob -tails -directory $kit *]] {machteld.exe sample.machteld} "two-file recipient starts alone"
    set mount [zipfs mount $archive examples-test]
    try {
        ::machteld::ArchiveEntry $mount
        file copy -- [file join $mount compiler] [file join $kit compiler]
        file copy -- [file join $mount project inputs] [file join $kit inputs]
    } finally {zipfs unmount $mount}
    file rename -- $archive [file join $work detached.machteld]
    set args {compiler/driver.tcl check --json inputs/application.dict}
    set checked [::machteld::json unwrap [::machteld::json decode -typed [clean $copied $kit {*}$args]]]
    equal [dict get $checked ok] 1 "recipient checks the extracted project"
    foreach name {calls index-read entry-started} {
        equal [file exists [file join $kit $name]] 0 "recipient check does not create $name"
    }
    set edited [string map [list {$n * 60} {$n * 61}] $source]
    write [file join $kit inputs calc.src] $edited
    set r [invoke $copied $kit compiler/driver.tcl test inputs/application.dict]
    equal [dict get $r exit] 1 "recipient's changed arithmetic fails its preserved example"
    equal [dict get $r out] {4 examples: 3 passed, 1 failed} "recipient gets independent results after editing"
    set row {example .seconds(.count('actual', 2)) => .count('expected', 120)}
    set mismatch [failureLine [dict get $r err] $edited $row]
    equal [regexp -nocase {expected[^0-9]*120.*got[^0-9]*122} $mismatch] 1 "recipient sees expected 120 and got 122"
    equal [log $kit] {actual expected first second offset success unwrapped} "recipient uses the bundled package and sources"
    equal [file exists [file join $kit entry-started]] 0 "testing the revision does not start it"
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set driver [file normalize [file join [file dirname [info script]] .. tools application_project.tcl]]
source -encoding utf-8 [file join [file dirname $driver] .. packages application-compiler compiler.tcl]
::exampleTest::operandSpans
set work [file normalize [file tempdir]]
try {
    set original [file join $work original]
    set source [::exampleTest::project $original]
    ::exampleTest::direct [info nameofexecutable] $original $driver $source
    if {$argv eq "-pack"} {::exampleTest::packed [info nameofexecutable] $original $driver $source $work}
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler examples: $::exampleTest::count assertions passed"
