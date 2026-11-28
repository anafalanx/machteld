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
    foreach command {--title --ranked-title} {
        appCase $exe $caller $prefix [list $command {雪 $x [list]}] {} [bytes {title=雪 $x [list]}] \
            "grouped choice selects the title from either payload"
    }
    appCase $exe $caller $prefix {--literal} {} [bytes "first\n\$price\t\U0001F642\u0000"] \
        "escaped source text preserves its dollar sign, Unicode and NUL"
    appCase $exe $caller $prefix [list --format {雪; [list] $x}] {} [bytes {<雪; [list] $x>}] \
        "extern passes one text argument to the project's own package"
    appCase $exe $caller $prefix [list --caption {雪; [list] $x}] {} \
        [bytes {雪; [list] $x | <雪; [list] $x> | 4.2 | true}] "interpolate a binding, a local Tcl call and typed expressions"
    lassign [command $exe $caller [list {*}$prefix --caption-error] {} 0] failedOut failedErr
    expect $failedOut {} "a failed interpolation produces no partial output"
    expect [regexp {logic:[0-9]+:[0-9]+: .*absent} $failedErr] 1 "propagated error in an interpolation keeps a source location"
    appCase $exe $caller $prefix {--decode cp1252} [binary decode hex 636166e92080] [bytes {café €}] \
        "strict decoding uses the explicitly selected legacy encoding"
    appCase $exe $caller $prefix {--preview utf-16le} [binary decode hex 4100ff] [bytes "A\ufffd"] \
        "preview replaces a trailing UTF-16 byte"
    lassign [command $exe $caller [list {*}$prefix --decode utf-16le] [binary decode hex 4100ff] 0] failedOut failedErr
    expect $failedOut {} "strict decoding emits nothing on malformed input"
    expect [regexp {main:[0-9]+:[0-9]+: .*byte offset 2} $failedErr] 1 "strict failure locates the source and the byte"
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
    set packageDir {extensions/text $format}
    file mkdir [file join $project lib] [file join $project code] [file join $project assets] [file join $project $packageDir]
    set logic {export fn .input() -> result<text,problem> {
    $raw ::= read_stdin_bytes()?
    return decode_utf8($raw)
}
export fn .answer($args: list<text>, $data: text) -> result<text,problem> {
    return match $args {
        [] => ok($data)
        ['label'] => ok('météo 雪')
        ['--title', $s] => ok(.title(.label::plain($s)))
        ['--ranked-title', $s] => ok(.title(.label::ranked(1, $s)))
        ["--literal"] => ok("first\n$price\t\u{1f642}\0")
        ['--format', $text] => ok(.format($text))
        ['--caption', $text] => ok($"$text | ${.format($text)} | ${4.00 + 0.2} | ${true}")
        ['--caption-error'] => ok($"prefix ${.lookup('absent', '')?} suffix")
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
distinct .lookup_key = text
choice .label {
    plain(text)
    ranked(int, text)
}
fn .title($label: .label) -> text => match $label {
    .label::plain($s) | .label::ranked(_, $s) => $"title=$s"
}
fn .lookup($key: text, $value: text) -> result<text,problem> {
    $entries ::= map_put(map<.lookup_key,text>(), make<.lookup_key>('007'), $value)
    return require_key(map_put($entries, make<.lookup_key>('7'), ''), make<.lookup_key>($key))
}
extern fn .format($text: text) -> text = ['::sample::format'] from 'sample::format'
fn .unused() -> text { return .unavailable() }
extern fn .unavailable() -> text = ['::missing::test_command'] from 'sample::unused'
}
    set main {import logic
alias .arguments = list<text>
alias .outcome = result<unit,problem>
fn .start($args: .arguments) -> .outcome {
    return match $args {
        ['--decode', $encoding] => write_stdout_utf8(decode_text(read_stdin_bytes()?, $encoding)?)
        ['--preview', $encoding] => write_stdout_utf8(preview_text(read_stdin_bytes()?, $encoding)?)
        _ => .run($args)
    }
}
fn .run($args: .arguments) -> .outcome {
    $data ::= .logic::input()?
    $out ::= .logic::answer($args, $data)?
    write_stdout_utf8($out)?
    return ok(unit)
}}
    set implementation {format [impl].tcl}
    set assets [list assets/blob.bin assets/labels.src $packageDir/pkgIndex.tcl $packageDir/$implementation]
    set manifest "schema 1\r\nedition 1\r\nminApi 0.21\r\nentry {main start}\r\nmodules {logic lib/a.src main code/main.src}\r\nassets [list $assets]\r\npackageDirs [list [list $packageDir]]\r\n"
    set originals [dict create application.dict [bytes $manifest] \
        lib/a.src [bytes [string map [list "\n" "\r\n"] "$logic\n"]] \
        code/main.src [bytes "$main\n"] assets/blob.bin [binary decode hex 00ff0d0a807f00] \
        assets/labels.src [bytes {a runtime data asset with the same extension as a module}] \
        $packageDir/pkgIndex.tcl [bytes {close [open package-index-visited w]
package ifneeded sample::format 1.0 [list source -encoding utf-8 [file join $dir {format [impl].tcl}]]}] \
        $packageDir/$implementation [bytes {namespace eval ::sample {}
proc ::sample::format {text} {return "<$text>"}
package provide sample::format 1.0}]]
    dict for {relative data} $originals {writeBytes [file join $project $relative] $data}
    return $originals
}

proc ::projectTest::inspectArchive {archive originals {withSource 1} {withCompiler 1}} {
    set mount //zipfs:/application-project-test
    zipfs mount $archive $mount
    try {
        ::machteld::ArchiveEntry $mount
        foreach member {main.tcl project/reference.db} {
            expect [file isfile [file join $mount $member]] 1 "archive contains $member"
        }
        expect [file exists [file join $mount compiler]] $withCompiler "compiler directory follows the requested output mode"
        if {$withCompiler} {
            foreach member {compiler.tcl pkgIndex.tcl driver.tcl README.md} {
                expect [file isfile [file join $mount compiler $member]] 1 "snapshot contains $member"
            }
        }
        set modules [dict values [dict get $originals application.dict modules]]
        dict for {relative data} $originals {
            set path [file join $mount project inputs $relative]
            if {!$withSource && ($relative eq "application.dict" || $relative in $modules)} {
                expect [file exists $path] 0 "source-free archive omits $relative"
                continue
            }
            set packed [readBytes $path]
            expect [binary encode hex $packed] [binary encode hex $data] "original bytes of $relative"
        }
    } finally {zipfs unmount $mount}
}

proc ::projectTest::archiveModes {exe caller driver manifest archive originals} {
    foreach {action input} [list pack $manifest rebuild $archive] {
        foreach {name options withSource withCompiler} {
            source-only {--without-compiler} 1 0
            compiler-only {--without-source} 0 1
            neither {--without-compiler --without-source} 0 0
        } {
            if {$action eq "rebuild"} {set options [lreverse $options]}
            set output [file join $caller $action-$name.machteld]
            command $exe $caller [list $driver $action {*}$options $input $output] {}
            inspectArchive $output $originals $withSource $withCompiler
            appCase $exe $caller [list $output] {--format portable} {} [bytes {<portable>}] "$action $name launches with its Tcl package"
            lassign [command $exe $caller [list $driver docs $output get fn/logic/answer] {}] page err
            expect [string match {*export fn .answer(*} $page] 1 "$action $name retains its generated application reference"
            if {!$withSource} {
                set refused [file join $caller unavailable.machteld]
                lassign [command $exe $caller [list $driver rebuild $output $refused] {} 0] out err
                expect [string match {*use the original project*} $err] 1 "rebuild explains how to recover the missing source"
                expect [file exists $refused] 0 "source-free input cannot create a rebuilt archive"
                lassign [command $exe $caller [list $driver locate $output logic 1] {} 0] out err
                expect [string match {*no editable project manifest*} $err] 1 "source lookup explains the missing source"
            }
        }
        foreach options {{--without-source --without-source} {--unknown-mode}} {
            set output [file join $caller invalid-options.machteld]
            lassign [command $exe $caller [list $driver $action {*}$options $input $output] {} 0] out err
            expect [string match {usage:*--without-source*--without-compiler*} $err] 1 "unsupported $action options display supported modes"
            expect [file exists $output] 0 "unsupported options leave the destination absent"
        }
        foreach misplaced {--without-source --without-compiler} {
            lassign [command $exe $caller [list $driver $action $input $misplaced] {} 0] out err
            expect [string match {usage:*} $err] 1 "$action rejects $misplaced in place of the output"
            expect [file exists [file join $caller $misplaced]] 0 "$action never writes an archive named for the option"
        }
    }
    # An editable archive without a snapshot can still supply everything
    # the current host needs to rebuild in the ordinary default mode.
    set fresh [file join $caller restored-full.machteld]
    command $exe $caller [list $driver rebuild [file join $caller pack-source-only.machteld] $fresh] {}
    inspectArchive $fresh $originals
}

proc ::projectTest::extractKit {archive directory} {
    set mount [zipfs mount $archive project-recipient-test]
    try {
        ::machteld::ArchiveEntry $mount
        file copy -- [file join $mount compiler] [file join $directory local-compiler]
        file copy -- [file join $mount project inputs] [file join $directory working-source]
    } finally {
        zipfs unmount $mount
    }
    set readme [encoding convertfrom -profile strict utf-8 [readBytes [file join $directory local-compiler README.md]]]
    expect [regexp {file copy [^\r\n]*compiler} $readme] 1 "bundled README explains compiler extraction"
    expect [regexp -nocase {driver\.tcl[^\r\n]*check --json} $readme] 1 "bundled README explains offline checking"
}

proc ::projectTest::kitDiagnostics {exe cwd valid} {
    lassign [command $exe $cwd {local-compiler/driver.tcl check --json working-source/application.dict} {} $valid] out err
    expect $err {} "extracted driver JSON check stderr"
    set doc [::machteld::json decode -typed [encoding convertfrom -profile strict utf-8 $out]]
    set report [::machteld::json unwrap $doc]
    expect [dict get $report ok] $valid "extracted driver JSON check status"
    set found {}
    foreach item [dict get $report diagnostics] {
        set pos [dict get $item node]
        lappend found [list [dict get $pos module] [dict get $item code] \
            [dict get $pos line] [dict get $pos column] [dict get $pos endColumn]]
    }
    return [lsort $found]
}

proc ::projectTest::offlineRecipient {work executable archive originals} {
    set directory [file join $work {offline author}]
    file mkdir $directory
    set exe [file join $directory machteld.exe]
    set incoming [file join $directory portable.machteld]
    file copy -- $executable $exe
    file copy -- $archive $incoming
    expect [lsort [glob -tails -directory $directory *]] {machteld.exe portable.machteld} "offline author receives only two files"

    extractKit $incoming $directory
    # Demonstrate that the extracted driver no longer depends on the mounted
    # archive, its original native path, or the already-removed source tree.
    file rename -- $incoming [file join $work detached-original.machteld]
    expect [kitDiagnostics $exe $directory 1] {} "clean extracted project"
    set manifest working-source/application.dict
    set driver local-compiler/driver.tcl
    set mainPath [file join $directory working-source code main.src]
    set logicPath [file join $directory working-source lib a.src]
    set original [encoding convertfrom -profile strict utf-8 [dict get $originals code/main.src]]
    set edited [string map [list {.logic::answer($args, $data)?} {'offline revision 雪'}] $original]
    set changed [bytes $edited]
    writeBytes $mainPath $changed
    set answer [bytes {offline revision 雪}]
    appCase $exe $directory [list $driver run $manifest] {label} {} $answer "offline source runs directly"
    set revised [file join $directory revised.machteld]
    command $exe $directory [list $driver pack $manifest $revised] {}
    appCase $exe $directory [list $revised] {label} {} $answer "offline edit runs from revised archive"
    set digest [::machteld::hash file sha256 $revised]
    inspectArchive $revised [dict replace $originals code/main.src $changed]

    # Two invalid edits in different modules exercise the delivered reporter.
    set badMain {fn .bad() -> int { return 'bad' }}
    set badLogic {fn .bad() -> int { return $absent }}
    set logic [encoding convertfrom -profile strict utf-8 [dict get $originals lib/a.src]]
    writeBytes $mainPath [bytes "$edited$badMain\n"]
    writeBytes $logicPath [bytes "$logic$badLogic\n"]
    set mainLine [llength [split $edited \n]]
    set logicLine [llength [split $logic \n]]
    expect [kitDiagnostics $exe $directory 0] [list [list logic UNKNOWN_BINDING $logicLine 27 34] \
        [list main RETURN_TYPE $mainLine 27 32]] "offline JSON check locates both broken edits"
    command $exe $directory [list $driver pack $manifest $revised] {} 0
    expect [::machteld::hash file sha256 $revised] $digest "bad offline build leaves revised archive byte-for-byte intact"
    appCase $exe $directory [list $revised] {label} {} $answer "previously packed revision still runs"

    set next [file join $work {next recipient}]
    file mkdir $next
    extractKit $revised $next
    expect [kitDiagnostics $exe $next 1] {} "revised archive supplies working compiler and valid edited sources"
    appCase $exe $next [list $driver run $manifest] {label} {} $answer "next recipient runs the revised sources"
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
    set marker [file join $caller package-index-visited]
    # Exercise the shipped driver with generation disabled. Checking a project
    # should finish once its manifest, entry and typed sources have been checked.
    set probe [file join $caller check-only.tcl]
    writeBytes $probe [bytes {package require machteld
lassign $argv compiler driver manifest
source -encoding utf-8 $compiler
proc ::appcompiler::emitModules args {error {project check entered code generation}}
set argv [list check $manifest]
source -encoding utf-8 $driver
}]
    set compiler [file join [file dirname $driver] .. packages application-compiler compiler.tcl]
    expect [command $exe $caller [list $probe $compiler $driver $manifest] {}] {{} {}} \
        "checking a typed project skips code generation"
    set mixed [dict remove [dict get $originals application.dict] entry]
    dict set mixed tclEntry ui.tcl
    set mixedManifest [file join $project mixed.dict]
    writeBytes $mixedManifest [bytes $mixed]
    writeBytes [file join $project ui.tcl] [bytes {error {checking ran the Tcl entry}}]
    expect [command $exe $caller [list $probe $compiler $driver $mixedManifest] {}] {{} {}} \
        "checking a mixed project skips code generation and its Tcl entry"
    expect [file exists $marker] 0 "checking leaves the external package index unevaluated"
    exercise $exe $caller $direct
    expect [file exists $marker] 1 "runtime can read the explicitly declared local package index"

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
    foreach wrong [list {{extensions/missing}} {{../outside}} {{extensions/TEXT $format}} \
            [list {extensions/text $format} {extensions/text $format}]] {
        writeBytes $manifest [bytes [dict replace $manifestBytes packageDirs $wrong]]
        lassign [command $exe $caller [list $driver check $manifest] {} 0] out err
        expect $out {} "bad package directory starts no application output"
        expect [regexp -nocase {directory|component|relative|unsafe|path} $err] 1 "bad package directory explains the error"
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
    file delete -- $marker
    command $exe $caller [list $driver pack $manifest $archive] {}
    expect [file exists $marker] 0 "packing leaves the external package index unevaluated"
    inspectArchive $archive $originals
    set builtHash [::machteld::hash file sha256 $archive]
    archiveModes $exe $caller $driver $manifest $archive $originals

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
    appCase $relocatedExe $caller [list $fromPrompt] {--format portable} {} [bytes {<portable>}] \
        "the two-file rebuild includes the external Tcl package"

    offlineRecipient $work $relocatedExe $shipped $originals

    set editor [file join $work {recipient edits}]
    file mkdir $editor
    file copy $relocatedExe $shipped $editor
    set kitExe [file join $editor machteld.exe]
    set incoming [file join $editor [file tail $shipped]]
    set originalHash [::machteld::hash file sha256 $incoming]
    expect [lsort [glob -tails -directory $editor *]] {machteld.exe portable.machteld} "recipient starts with two files"
    # These are the recipient's prompt commands. Change one expression in
    # a writable copy, keeping the compiler mounted through the new build.
    set edits [list \
        {file copy [file dirname $manifest] working-source} \
        {set manifest [file join working-source application.dict]} \
        {set path [file join working-source code main.src]} \
        {set in [open $path rb]} {set text [encoding convertfrom -profile strict utf-8 [read $in]]} {close $in} \
        {set text [string map [list {.logic::answer($args, $data)?} {'edited by the recipient'}] $text]} \
        {set out [open $path wb]} {puts -nonewline $out [encoding convertto -profile strict utf-8 $text]} {close $out}]
    testEmbeddedRebuild $kitExe $editor [file tail $incoming] revised.machteld $edits
    set revised [file join $editor revised.machteld]
    appCase $kitExe $caller [list $revised] {label} {} [bytes {edited by the recipient}] "recipient's changed source executes"
    expect [::machteld::hash file sha256 $incoming] $originalHash "recipient retains the delivered archive byte for byte"
    set originals [dict replace $originals code/main.src [readBytes [file join $editor working-source code main.src]]]
    inspectArchive $revised $originals
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set work [file normalize [file tempdir]]
try {
    ::projectTest::runSuite $work $driver [expr {$argv eq "-pack"}]
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler project: $::projectTest::count assertions passed"
