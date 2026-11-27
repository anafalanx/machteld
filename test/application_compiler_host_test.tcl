package require machteld

# Run on the packaged host. The built-in command uses a temporary delivery
# tree. The compatibility checks also exercise the checkout and extracted drivers.
namespace eval ::hostCompiler {variable count 0}

proc ::hostCompiler::expect {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}

proc ::hostCompiler::writeText {path data} {
    set ch [open $path wb]
    try {puts -nonewline $ch [encoding convertto -profile strict utf-8 $data]} finally {close $ch}
}

proc ::hostCompiler::call {exe cwd args} {
    set result [::machteld::run -timeout 30s -dir $cwd -env {TCLLIBPATH {}} -- $exe {*}$args]
    set err [encoding convertfrom -profile strict utf-8 [dict get $result err]]
    if {[dict get $result exit] != 0 || [dict get $result status] ne "ok" ||
            [dict get $result truncated] ne {} || $err ne {}} {
        error "[list {*}$args]: [dict get $result status], exit [dict get $result exit]; $err"
    }
    return [string trimright [encoding convertfrom -profile strict utf-8 [dict get $result out]] "\r\n"]
}

proc ::hostCompiler::exercise {work checkoutDriver} {
    set author [file join $work {project sources}]
    set delivery [file join $work {relocated installation}]
    file mkdir $author $delivery
    set exe [file join $delivery machteld.exe]
    file copy -- [info nameofexecutable] $exe
    set manifest [file join $author project.dict]
    writeText $manifest {schema 1 edition 1 minApi 30 entry {labels main} modules {labels labels.src}}
    writeText [file join $author labels.src] {## Returns the supplied label unchanged.
export fn .label($name: text) -> text => $name
example .label('007') => '007'
extern fn .launch() -> list<text> = ['::machteld::app', 'launch']
fn .main($args: list<text>) -> result<unit,problem> =>
    match $args {
        ['--manifest'] => match .launch() {
            [$exe, '--project', 'run', $path] => write_stdout_utf8($path)
            _ => err(problem('missing project launch prefix'))
        }
        [$text] => write_stdout_utf8(.label($text))
        _ => err(problem('expected one label'))
    }}
    set probe [file join $author inspect.tcl]
    writeText $probe {package require machteld
set before [package provide application-compiler]
set version [package require application-compiler]
set expected [file join [::machteld::PayloadRoot] tcl_library application-compiler]
puts [list $before $version [expr {$::appcompiler::compilerDirectory eq [file normalize $expected]}] [package provide Tk]]
}
    expect [call $exe $delivery $probe] [list {} 0.1 1 {}] "package loads lazily from the executable without Tk"
    expect [string match {*check*MANIFEST*pack*rebuild*} [call $exe $delivery project --help]] 1 "project help succeeds on stdout"
    writeText $probe {package require machteld
package require application-compiler
set argv [linsert $argv 0 check]
set argc [llength $argv]
source -encoding utf-8 [file join $::appcompiler::compilerDirectory driver.tcl]
puts "checked twice"
source -encoding utf-8 [file join $::appcompiler::compilerDirectory driver.tcl]
}
    expect [call $exe $delivery $probe $manifest] {checked twice} "driver can reuse the same loaded compiler"
    set check [::machteld::json decode [call $exe $delivery project check --json $manifest]]
    expect [dict get $check ok] 1 "inspect project without an external driver"
    set bad [::machteld::run -timeout 15s -dir $delivery -- $exe project check --json missing.dict]
    expect [dict get $bad exit] 1 "failed check preserves process exit status"
    expect [dict get $bad err] {} "structured diagnostics stay on stdout"
    expect [dict get [::machteld::json decode [dict get $bad out]] ok] 0 "failed check returns structured diagnostics"
    expect [call $exe $delivery project test $manifest] {1 examples: 1 passed, 0 failed} "embedded example runner"
    expect [call $exe $delivery project locate $manifest labels] labels.src "embedded source locator"
    expect [call $exe $author project run project.dict --manifest] $manifest "source application launch prefix"
    set label {two words 雪}
    expect [call $exe $delivery project run $manifest $label] $label "source application argv and Unicode"
    set archive [file join $delivery labels.machteld]
    expect [call $exe $delivery project pack $manifest $archive] $archive "package using only the embedded compiler"
    set workerProject [file join $author worker.dict]
    writeText $workerProject {schema 1 edition 1 minApi 30 tclEntry worker.tcl modules {}}
    writeText [file join $author worker.tcl] {package require machteld
if {[lindex $argv 0] eq "child"} {
    puts -nonewline [lindex $argv 1]
    return
}
set run [::machteld::run -timeout 15s -dir [lindex $argv 0] -- {*}[::machteld::app launch] child {two words}]
if {[dict get $run exit] != 0} {error [dict get $run err]}
puts -nonewline [dict get $run out]
}
    set other [file join $delivery {worker cwd}]
    file mkdir $other
    writeText [file join $other project] {package require machteld
puts "script: $argv"}
    expect [call $exe $author project run worker.dict $other] {two words} "source application relaunches across a cwd with a real project file"
    expect [call $exe $author $checkoutDriver run worker.dict $other] {two words} "checkout driver relaunches the same source application"
    set mount [zipfs mount $archive author-tools]
    set tools [file join $work {extracted compiler}]
    try {file copy -- [file join $mount compiler] $tools} finally {zipfs unmount $mount}
    expect [call $exe $author [file join $tools driver.tcl] run worker.dict $other] {two words} "extracted driver relaunches the same source application"
    writeText $probe {package require machteld
package require application-compiler
set root [zipfs mount [lindex $argv 0] driver-version]
set argv {}
set argc 0
source -encoding utf-8 [file join $root compiler driver.tcl]
}
    set mismatch [::machteld::run -dir $delivery -timeout 30s -- $exe $probe $archive]
    expect [dict get $mismatch exit] 1 "a distinct pinned driver cannot replace an already loaded compiler"
    expect [string match {*different application compiler is already loaded*} [dict get $mismatch err]] 1 "actionable mismatch diagnostic"
    file rename -- $author [file join $work put-away]
    expect [call $exe $delivery labels.machteld $label] $label "relocated application"
    expect [call $exe $delivery project locate labels.machteld labels 2] "labels.src:2\nexport fn .label(\$name: text) -> text => \$name" "embedded archive locator reads retained source after relocation"
    expect [call $exe $delivery project docs labels.machteld search label] fn/labels/label "archive reference via host"
    set rebuilt [file join $delivery rebuilt.machteld]
    expect [call $exe $delivery project rebuild labels.machteld $rebuilt] $rebuilt "rebuild without the source directory"
    expect [call $exe $delivery $rebuilt $label] $label "rebuilt application"

    expect [call $exe $other project local] {script: local} "real program named project takes precedence"
    expect [call $exe $other --project docs $archive search label] fn/labels/label "reserved project selector"
}

set work [file normalize [file tempdir]]
set checkoutDriver [file normalize [file join [file dirname [info script]] .. tools application_project.tcl]]
try {::hostCompiler::exercise $work $checkoutDriver} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "embedded application compiler: $::hostCompiler::count assertions passed"
