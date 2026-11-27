package require machteld

# Run with an archive-capable host. This test exercises the portable compiler
# package using the ordinary Tcl entry and pack command.
set compilerDir [file normalize [file join [file dirname [info script]] .. packages application-compiler]]
lappend auto_path $compilerDir
package require application-compiler 0.1

proc writeText {path value} {
    set channel [open $path wb]
    try { puts -nonewline $channel [encoding convertto utf-8 $value] } finally { close $channel }
}
proc invoke {exe cwd args} {
    set r [::machteld::run -dir $cwd -timeout 30s -- $exe {*}$args]
    if {[dict get $r status] ne "ok" || [dict get $r exit] != 0} {
        error "command [list {*}$args] failed: [encoding convertfrom utf-8 [dict get $r err]]"
    }
    return [string trimright [encoding convertfrom -profile strict utf-8 [dict get $r out]] "\r\n"]
}
proc expect {actual expected description} {
    if {$actual ne $expected} {error "$description: expected [list $expected], got [list $actual]"}
    puts "ok   $description"
}
proc buildSample {exe source sources archive} {
    set compiled [::appcompiler::compile $sources ::sample]
    writeText [file join $source generated.tcl] [dict get $compiled script]
    dict for {module program} $sources { writeText [file join $source $module.src] $program }
    invoke $exe [file dirname $source] pack $source -o $archive
}
proc exercise {work compilerDir} {
    set exe [info nameofexecutable]
    set source [file join $work {build folder}]
    set delivery [file join $work {relocated release}]
    set caller [file join $work {unrelated caller}]
    file mkdir $source $delivery $caller
    file copy $compilerDir [file join $source compiler]

    set sources [dict create units {export fn .seconds($value: int) -> int {return $value * 60}} \
        main {import units
fn .main($value: int) -> int {return .units::seconds($value)}}]
    writeText [file join $source main.tcl] {package require machteld
set here [file dirname [info script]]
switch -exact -- [lindex $argv 0] {
    run {source -encoding utf-8 [file join $here generated.tcl]}
    rebuild {
        lappend auto_path [file join $here compiler]
        package require application-compiler 0.1
        foreach module {main units} {
            set ch [open [file join $here $module.src] rb]
            try {dict set inputs $module [encoding convertfrom -profile strict utf-8 [read $ch]]} finally {close $ch}
        }
        set compiled [::appcompiler::compile $inputs ::sample]
        namespace eval :: [dict get $compiled script]
    }
    default {error "expected run or rebuild"}
}
puts [::sample::main::main [lindex $argv 1]]
}
    set archive [file join $work compile-sample.machteld]
    buildSample $exe $source $sources $archive
    expect [invoke $exe $caller [file join $source main.tcl] run 2] 120 "direct generated program"
    set original [::machteld::hash file sha256 $archive]
    set invalid [dict replace $sources units {export fn .seconds($v: int) -> int {return 'bad'}}]
    expect [catch {buildSample $exe $source $invalid $archive} message opts] 1 "broken build rejected"
    expect [dict get $opts -errorcode] {APPCOMPILER CHECK} "failure came from compiler"
    expect [::machteld::hash file sha256 $archive] $original "previous archive preserved"

    set shippedExe [file join $delivery machteld.exe]
    set shippedApp [file join $delivery example.machteld]
    file copy $exe $shippedExe
    file copy $archive $shippedApp
    expect [lsort [glob -tails -directory $delivery *]] {example.machteld machteld.exe} "two-file distribution"
    expect [invoke $shippedExe $caller $shippedApp run 2] 120 "relocated archive"
    expect [invoke $shippedExe $caller $shippedApp rebuild 3] 180 "recompile bundled originals in the relocated archive"
}
set temp [file normalize [file tempdir]]
try {
    exercise $temp $compilerDir
} finally {
    # file tempdir allocated this directory exclusively for this invocation.
    if {[file normalize $temp] eq $temp && [file dirname $temp] ne $temp} {file delete -force -- $temp}
}
