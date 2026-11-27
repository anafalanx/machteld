package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::processTest {
    variable checks 0
    variable tools {## Resolves the converter installed with the application.
export tool .converter = 'tools/helper with spaces.exe'
export fn .capture($exe: text, $argv: list<text>, $input: bytes, $cap: int, $timeout: int) -> result<process_output,problem> =>
    capture_process($exe, $argv, $input, $cap, $timeout)
fn .available() -> result<bool,problem> {
    $path ::= .converter()?
    return ok(true)
}
example .available() => true
}
    variable app {import tools
fn .main($args: list<text>) -> result<unit,problem> {
    $exe ::= .tools::converter()?
    $input ::= read_stdin_bytes()?
    $r ::= .tools::capture($exe, $args, $input, 1048576, 10000)?
    return write_stdout_utf8(decode_utf8($r.stdout)?)
}}
    variable fixture {package require machteld
foreach c {stdin stdout stderr} {chan configure $c -translation binary}
switch -- [lindex $argv 0] {
    argv {puts -nonewline stdout [encoding convertto utf-8 [lrange $argv 1 end]]}
    bytes {puts -nonewline stdout [read stdin]; puts -nonewline stderr [binary format H* 00ff800a]; exit 17}
    flood {
        set chunk [binary format H* [string repeat ffa0 4096]]
        for {set i 0} {$i < 130} {incr i} {
            puts -nonewline stdout $chunk
            puts -nonewline stderr $chunk
        }
    }
    wait {after 5000}
}}
}

proc ::processTest::equal {got want label} {
    variable checks
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
    incr checks
}

proc ::processTest::invalid {source code} {
    set diagnostics [::appcompiler::check [dict create main $source]]
    equal [expr {$code in [lmap d $diagnostics {dict get $d code}]}] 1 "$code in $diagnostics"
}

proc ::processTest::problem {result expected} {
    lassign $result tag detail
    equal $tag err "problem $expected"
    equal [dict get $detail code] $expected "problem code"
}

proc ::processTest::write {path text} {
    ::appcompiler::project::stageBytes $path [encoding convertto utf-8 $text]
}

proc ::processTest::fixture {root} {
    set directory [file join $root tools]
    file mkdir $directory
    set exe [file join $directory {helper with spaces.exe}]
    file copy -- [info nameofexecutable] $exe
    return $exe
}

proc ::processTest::invoke {cwd args} {
    set result [::machteld::run -dir $cwd -stdin {} -timeout 20s -- [info nameofexecutable] {*}$args]
    if {[dict get $result status] ne "ok"} {
        error "test host: [encoding convertfrom utf-8 [dict get $result err]]"
    }
    return [encoding convertfrom -profile strict utf-8 [dict get $result out]]
}

proc ::processTest::exercise {tmp packed} {
    variable tools
    variable app
    variable fixture
    set author [file join $tmp author]
    set elsewhere [file join $tmp elsewhere]
    file mkdir $author $elsewhere
    set helper [fixture $author]
    set script [file join $tmp fixture.tcl]
    write $script $fixture
    set manifest [file join $author application.dict]
    write $manifest {schema 1 edition 1 minApi 0.21 entry {main main} modules {tools tools.src main main.src}}
    write [file join $author tools.src] $tools
    write [file join $author main.src] $app
    set mixed [file join $author mixed.dict]
    write $mixed {schema 1 edition 1 minApi 0.21 tclEntry ui/app.tcl modules {tools tools.src}}
    write [file join $author ui app.tcl] {
        set ::argv0 [file join [pwd] changed-by-app.machteld]
        lassign [::application::tools::converter] tag path
        if {$tag ne "ok"} {error [dict get $path message]}
        lassign [::application::tools::capture $path $::argv {} 4096 10000] tag output
        if {$tag ne "ok"} {error [dict get $output message]}
        chan configure stdout -translation binary
        puts -nonewline stdout [dict get $output stdout]
    }
    set artifact [::appcompiler::compile [dict create tools $tools] ::typedProcess]
    namespace eval :: [dict get $artifact script]
    problem [::typedProcess::tools::converter] PROCESS_CONTEXT
    set argcases [list {} {with spaces} {a"b} "a\\" {&|;%VALUE%} {雪}]
    set args [list $script argv {*}$argcases]
    set byteArgs [list $script bytes]
    lassign [::typedProcess::tools::capture $helper $args {} 4096 10000] tag r
    equal $tag ok "capture argv: $r"
    equal [list [dict get $r status] [dict get $r exit] [encoding convertfrom utf-8 [dict get $r stderr]]] {ok 0 {}} "fixture started"
    equal [encoding convertfrom utf-8 [dict get $r stdout]] $argcases "one Windows argument per list element"
    set bytes [binary format H* 000aff808d00]
    lassign [::typedProcess::tools::capture $helper $byteArgs $bytes 3 10000] tag r
    equal $tag ok "nonzero exit is an observed outcome"
    equal [dict get $r status] error "native process outcome"
    equal [dict get $r exit] 17 "original exit code"
    equal [binary encode hex [dict get $r stdout]] 000aff "bounded binary stdout"
    equal [binary encode hex [dict get $r stderr]] 00ff80 "bounded binary stderr"
    equal [dict get $r stdout_truncated] 1 "stdout clipped"
    equal [dict get $r stderr_truncated] 1 "stderr clipped"
    equal [dict get $r stdout_retained] 3 "reported stdout bytes retained"
    equal [dict get $r stderr_retained] 3 "reported stderr bytes retained"
    lassign [::typedProcess::tools::capture $helper $byteArgs $bytes 6 10000] tag r
    equal [binary encode hex [dict get $r stdout]] 000aff808d00 "complete binary stdin and stdout"
    equal [dict get $r stdout_truncated] 0 "exact limit retains complete stream"
    equal [dict get $r stderr_truncated] 0 "short stream complete"
    lassign [::typedProcess::tools::capture $helper $byteArgs {} 0 10000] tag r
    equal [dict get $r stdout_truncated] 0 "empty stream and zero cap"
    equal [dict get $r stderr_truncated] 1 "nonempty stream and zero cap"
    equal [dict get $r stderr] {} "zero cap retains zero bytes"
    lassign [::typedProcess::tools::capture $helper [list $script flood] {} 1048576 10000] tag r
    foreach key {stdout stderr} {
        equal [string length [dict get $r $key]] 1048576 "$key reaches native byte limit"
        equal [dict get $r ${key}_truncated] 1 "$key native truncation remains visible"
    }
    lassign [::typedProcess::tools::capture $helper [list $script wait] {} 1 100] tag r
    equal $tag ok "deadline outcome"
    equal [dict get $r status] timeout "deadline recorded separately from nonzero exit"
    foreach path {helper.exe C:helper.exe /helper.exe ~/helper.exe} {
        problem [::typedProcess::tools::capture $path {} {} 1 1] PROCESS_PATH
    }
    problem [::typedProcess::tools::capture $helper [list "bad\u0000arg"] {} 1 1] PROCESS_ARGUMENT
    problem [::typedProcess::tools::capture [file join $tmp missing.exe] {} {} 1 1] PROCESS_NOT_FOUND
    problem [::typedProcess::tools::capture $helper [list [string repeat x 33000]] {} 1 100] PROCESS_LAUNCH
    foreach limit {-1 1048577} {problem [::typedProcess::tools::capture $helper {} {} $limit 1] PROCESS_LIMIT}
    foreach timeout {-1 4294967295} {problem [::typedProcess::tools::capture $helper {} {} 1 $timeout] PROCESS_TIMEOUT}

    set driver [file join $::appcompiler::compilerDirectory driver.tcl]
    equal [string trim [invoke $elsewhere $driver test $manifest]] {1 examples: 1 passed, 0 failed} "source examples resolve tools from the manifest"
    equal [invoke $elsewhere $driver run $manifest {*}$args] $argcases "source tool belongs beside manifest"
    equal [invoke $elsewhere $driver run $mixed {*}$args] $argcases "Tcl entry in subdirectory resolves project tools"
    if {!$packed} {return}

    set delivery [file join $tmp {copied 雪}]
    file mkdir $delivery
    set appFile [file join $delivery renamed.machteld]
    ::appcompiler::project::pack $manifest $appFile
    set mount [zipfs mount $appFile process-artifact-test]
    try {
        set channel [open [file join $mount main.tcl] rb]
        try {set startup [read $channel]} finally {close $channel}
        equal [string first $author $startup] -1 "packed startup omits author's directory"
        equal [string first [info nameofexecutable] $startup] -1 "packed startup omits build runtime's absolute path"
        equal [file exists [file join $mount project inputs tools {helper with spaces.exe}]] 0 "external tool is distributed separately"
    } finally {zipfs unmount $mount}
    set mixedFile [file join $delivery mixed.machteld]
    ::appcompiler::project::pack $mixed $mixedFile
    file rename -- [file join $author tools] [file join $delivery tools]
    equal [invoke $elsewhere [file join .. [file tail $delivery] [file tail $appFile]] {*}$args] $argcases "relocated archive uses external sibling tool"
    equal [invoke $elsewhere $mixedFile {*}$args] $argcases "packed Tcl entry resolves external sibling tool"
    set doc [::appcompiler::reference::query $appFile get fn/tools/converter]
    equal [expr {[string first {export tool .converter = "tools/helper with spaces.exe"} $doc] >= 0}] 1 "tool declaration in offline reference"
    file rename -- [file join $delivery tools] [file join $elsewhere tools]
    set failed [::machteld::run -dir $elsewhere -timeout 20s -- [info nameofexecutable] $appFile argv]
    equal [dict get $failed exit] 1 "missing declared tool never falls back to caller cwd"
    equal [string match {*application tool not found*} [dict get $failed err]] 1 "typed problem reaches entry"
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
foreach path {{../tool.exe} {C:/tool.exe} {C:tool.exe} {/bin/tool.exe} {foo.cmd} {dir//x.exe}} {
    ::processTest::invalid "tool .c = '$path'" TOOL_PATH
}
::processTest::invalid {fn .bad($p: text, $args: list<list<text>>, $data: bytes) -> result<process_output,problem> =>
    capture_process($p, $args, $data, 256, 500)} ARGUMENT_TYPE
set work [file normalize [file tempdir]]
try {
    ::processTest::exercise $work [expr {$argv eq "-pack"}]
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler process capture: $::processTest::checks assertions passed"
