package require machteld

set here [file dirname [file normalize [info script]]]
source -encoding utf-8 [file join $here fixtures compiler_prompt_rebuild.tcl]
set driver [file normalize [file join $here .. tools application_project.tcl]]

namespace eval ::projectTest {variable count 0}
proc ::projectTest::expect {actual expected name} {
    variable count
    if {$actual ne $expected} {error "$name: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::projectTest::bytes {text} {encoding convertto utf-8 $text}
proc ::projectTest::writeBytes {path data} {
    set ch [open $path wb]
    try {puts -nonewline $ch $data} finally {close $ch}
}
proc ::projectTest::readBytes {path} {
    set ch [open $path rb]
    try {read $ch} finally {close $ch}
}

proc ::projectTest::command {exe cwd arguments input {success 1}} {
    set run [::machteld::run -dir $cwd -timeout 30s -stdin $input -- $exe {*}$arguments]
    set stderr [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run err]] "\r\n"]
    if {[dict get $run exit] eq "" || ([dict get $run exit] == 0) != $success ||
        [dict get $run truncated] ne ""} {
        error "unexpected result for [list {*}$arguments]: [dict get $run status], exit [dict get $run exit]; $stderr"
    }
    return [list [dict get $run out] $stderr]
}
proc ::projectTest::appCase {exe cwd prefix arguments input expected label} {
    lassign [command $exe $cwd [list {*}$prefix {*}$arguments] $input] out err
    expect [binary encode hex $out] [binary encode hex $expected] "$label stdout bytes"
    expect $err {} "$label stderr"
}
proc ::projectTest::exercise {exe caller prefix} {
    set payload [bytes "café\r\n雪\n"]
    appCase $exe $caller $prefix {} $payload $payload "stdin with original line endings"
    appCase $exe $caller $prefix [list {}] $payload {} "one empty argument"
    appCase $exe $caller $prefix [list --flag {two words} {}] {} [bytes {two words}] \
        "flag, spaced value and trailing empty argument in order"
    appCase $exe $caller $prefix {label} {} [bytes {météo 雪}] "source literal decoded as UTF-8"
    appCase $exe $caller $prefix {rebuild} {} [bytes rebuild] "driver verb passed to the application"
    appCase $exe $caller $prefix [list --pick {} {two words}] {} [bytes {two words}] \
        "labeled list iteration selects a complete argument"
    appCase $exe $caller $prefix {--lookup 007} $payload $payload "text key preserves leading zeroes"
    appCase $exe $caller $prefix {--lookup 7} $payload {} "present map entry can contain empty text"
    lassign [command $exe $caller [list {*}$prefix --lookup absent] {} 0] failedOut failedErr
    expect $failedOut {} "required lookup writes nothing on failure"
    expect [regexp {logic:[0-9]+:[0-9]+: .*absent} $failedErr] 1 "missing key locates its source"

    lassign [command $exe $caller $prefix [binary decode hex 61ff] 0] out err
    expect $out {} "no output on invalid input"
    expect [regexp {logic:3:[0-9]+:.*UTF-8.*byte offset 1} $err] 1 "runtime error in imported source"
}

proc ::projectTest::writeProject {project} {
    file mkdir [file join $project lib] [file join $project code] [file join $project assets]
    set logic {export fn .input() -> result<text,problem> {
    $raw ::= read_stdin_bytes()?
    return decode_utf8($raw)
}
export fn .answer($args: list<text>, $data: text) -> result<text,problem> {
    return match $args {
        [] => ok($data)
        ['label'] => ok('météo 雪')
        ['--flag', $value, ''] => ok($value)
        ['--pick', $first, $second] => ok(.pick($args))
        ['--lookup', $key] => .lookup($key, $data)
        [$one] => ok($one)
        _ => err(problem('expected zero or one argument'))
    }
}
fn .pick($values: list<text>) -> text {
    $selected := ''
    for .candidates $value in $values {
        for $i in 1..=1 {
            if $value == '--pick' {continue .candidates}
            if $value == '' {continue .candidates}
            $selected = $value
            break .candidates
        }
    }
    return $selected
}
fn .lookup($key: text, $value: text) -> result<text,problem> {
    $entries ::= map_put(map<text,text>(), '007', $value)
    return require_key(map_put($entries, '7', ''), $key)
}}
    set main {import logic
fn .start($args: list<text>) -> result<unit,problem> {
    $data ::= .logic::input()?
    $out ::= .logic::answer($args, $data)?
    write_stdout_utf8($out)?
    return ok(unit)
}}
    set manifest "schema 1\r\nedition 1\r\nminApi 0.21\r\nentry {main start}\r\nmodules {logic lib/a.src main code/main.src}\r\nassets {assets/blob.bin}\r\n"
    set originals [dict create application.dict [bytes $manifest] \
        lib/a.src [bytes [string map [list "\n" "\r\n"] "$logic\n"]] \
        code/main.src [bytes "$main\n"] assets/blob.bin [binary decode hex 00ff0d0a807f00]]
    dict for {relative data} $originals {writeBytes [file join $project $relative] $data}
    return $originals
}

proc ::projectTest::inspectArchive {archive originals} {
    set mount //zipfs:/application-project-test
    zipfs mount $archive $mount
    try {
        foreach member {main.tcl compiler/pkgIndex.tcl compiler/compiler.tcl} {
            expect [file isfile [file join $mount $member]] 1 "archive contains $member"
        }
        dict for {relative data} $originals {
            set packed [readBytes [file join $mount project inputs $relative]]
            expect [binary encode hex $packed] [binary encode hex $data] "original bytes of $relative"
        }
    } finally {zipfs unmount $mount}
}

proc ::projectTest::runSuite {work driver pack} {
    set exe [info nameofexecutable]
    set caller [file join $work {unrelated cwd}]
    set project [file join $work {input project}]
    file mkdir $caller
    set originals [writeProject $project]
    set manifest [file join $project application.dict]
    set path [file join $project lib a.src]
    set direct [list $driver run $manifest]
    command $exe $caller [list $driver check $manifest] {}
    exercise $exe $caller $direct

    set manifestBytes [dict get $originals application.dict]
    foreach {field old new expected} {
        edition {edition 1} {edition 999} {edition}
        minApi {minApi 0.21} {minApi 999.0} {API}
    } {
        writeBytes $manifest [string map [list $old $new] $manifestBytes]
        lassign [command $exe $caller $direct [binary decode hex ff] 0] out err
        expect $out {} "unsupported $field starts no application output"
        expect [expr {[regexp -nocase $expected $err] && ![regexp {logic:[0-9]+:} $err]}] 1 \
            "unsupported $field is diagnosed before the application reads stdin"
    }
    writeBytes $manifest $manifestBytes

    writeBytes $path [binary decode hex 23ff0a]
    lassign [command $exe $caller [list $driver check $manifest] {} 0] out err
    expect $out {} "invalid source has no normal output"
    expect [regexp -nocase {a\.src} $err] 1 "source decoding reports the actual file"
    expect [regexp -nocase {UTF-8|UTF8} $err] 1 "source decoding reports the encoding"
    writeBytes $path [dict get $originals lib/a.src]
    if {!$pack} {return}

    set archive [file join $work original.machteld]
    command $exe $caller [list $driver pack $manifest $archive] {}
    inspectArchive $archive $originals
    set builtHash [::machteld::hash file sha256 $archive]

    writeBytes $path [bytes {export fn .input() -> result<text,problem> { return 82 }
export fn .answer($args: list<text>, $data: text) -> result<text,problem> {return ok($data)}}]
    lassign [command $exe $caller [list $driver pack $manifest $archive] {} 0] out err
    expect [regexp {logic:1:[0-9]+.*RETURN_TYPE} $err] 1 "failed pack identifies module, location and error"
    expect [::machteld::hash file sha256 $archive] $builtHash "failed pack preserves the previous archive"

    set delivery [file join $work {relocated kit}]
    file mkdir $delivery
    set relocatedExe [file join $delivery machteld.exe]
    set shipped [file join $delivery portable.machteld]
    file copy $exe $relocatedExe
    file rename $archive $shipped
    if {[file dirname [file normalize $project]] ne $work} {error "unexpected fixture path"}
    file delete -force -- $project
    expect [lsort [glob -tails -directory $delivery *]] {machteld.exe portable.machteld} "initial two-file delivery"
    exercise $relocatedExe $caller [list $shipped]

    set fresh [file join $caller rebuilt.machteld]
    command $relocatedExe $caller [list $driver rebuild $shipped $fresh] {}
    inspectArchive $fresh $originals
    exercise $relocatedExe $caller [list $fresh]
    set rebuiltHash [::machteld::hash file sha256 $fresh]
    set invalid [file join $work invalid.machteld]
    writeBytes $invalid [bytes {invalid archive}]
    command $relocatedExe $caller [list $driver rebuild $invalid $fresh] {} 0
    expect [::machteld::hash file sha256 $fresh] $rebuiltHash "failed rebuild preserves the previous archive"

    expect [lsort [glob -tails -directory $delivery *]] {machteld.exe portable.machteld} "prompt can see only delivered inputs"
    testEmbeddedRebuild $relocatedExe $delivery [file tail $shipped] fresh-from-prompt.machteld
    set fromPrompt [file join $delivery fresh-from-prompt.machteld]
    appCase $relocatedExe $caller [list $fromPrompt] {} [bytes "delivered\n"] [bytes "delivered\n"] \
        "rebuilt using only the delivered files"
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set work [file normalize [file tempdir]]
try {
    ::projectTest::runSuite $work $driver [expr {$argv eq "-pack"}]
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler project: $::projectTest::count assertions passed"
