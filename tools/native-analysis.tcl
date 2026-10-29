package require machteld 0.21

# tools/native-analysis.tcl -- native validation beyond the ordinary build, in
# two parts.
#
# The UB-trapped drivers (::na::trappedSteps) are ordinary steps of the gate's
# native-validation group. The authored code at the native boundaries is
# compiled with -fsanitize=undefined -fsanitize-undefined-trap-on-error and
# -Werror, after a canary shows that the traps fire (a signed overflow and an
# array-bounds error end in STATUS_ILLEGAL_INSTRUCTION), and driven headless:
# the command-line quoting and its allocation failures, UTF-8/UTF-16
# conversion and Windows argv round trips, the JSON reader, emitter and typed
# tree with yyjson over the JSON corpus and the adversarial inputs, the
# filesystem and SQLite result boundaries, and the hash token sequence's
# exhaustion; in the gate also the identity primitives, which parse the ICO
# and PE bytes wrap stamps (test/fixtures/identity_driver.c, which nothing ran
# in the candidate). Tcl/Tk and SQLite are linked as built, not instrumented.
#
# The full harness is diagnostic rather than a gate: the gate's
# --native-analysis option runs it, or it runs alone,
#
#     machteld.exe tools/native-analysis.tcl ?--cache DIR? ?--msys DIR? ?--output DIR?
#
# It verifies the dependency cache (bootstrap --verify-only: nothing is
# rebuilt or installed), hashes its inputs and refuses a result whose sources
# changed under it, runs GCC's -fanalyzer over every src/*.c once a
# use-after-free canary shows that the analyzer reports, probes the ASan and
# UBSan runtimes (reported unsupported where the pinned toolchain has none),
# runs the trapped drivers, links the real pinned Tk index formatter and runs
# it headless, and compiles to an ASCII path with spaces and to a CJK path.
# Everything goes into a fresh out/native-analysis-<id>/: one log per
# invocation and report.json. The Tcl port of tools/native-analysis.ps1
# (machteld 8bcc1ec); tools/native-analysis-config.tcl, its bridge to the
# build recipe, is not needed, as this file reads tools/buildlib.tcl itself.

namespace eval ::na {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
    # STATUS_ILLEGAL_INSTRUCTION: how a trapped undefined behavior ends.
    variable trapped 0xC000001D
    variable runs {}
    variable output ""
}
if {[info commands ::boot::msysRoot] eq ""} {
    source -encoding utf-8 [file join $::na::root tools bootstrap.tcl]
}
if {[info commands ::machteld::build::common_flags] eq ""} {
    source -encoding utf-8 [file join $::na::root tools buildlib.tcl]
}

proc ::na::fail {message} {
    return -code error -errorcode {NATIVE fail} "native analysis: $message"
}

proc ::na::say {line} {
    puts $line
    flush stdout
}

# The dependency cache's files these drivers read: the build's own lookup
# (::machteld::build::paths), so the drivers link what the runtime links.
# Without a complete cache the steps are still planned, on the names
# tools/bootstrap.tcl installs, and their compiles say what is missing.
proc ::na::layout {cache} {
    if {![catch {::machteld::build::paths $cache} paths]} {
        return $paths
    }
    set prefix [file join $cache prefix]
    dict create cache $cache prefix $prefix include [file join $prefix include] \
        sqlite [file join $cache sqlite] yyjson [file join $cache yyjson] \
        tcllib [file join $prefix lib libtcl90.a] tklib [file join $prefix lib libtcl9tk90.a] \
        tclstub [file join $prefix lib libtclstub.a]
}

# The UB-trapped drivers as steps (label, argv, and expect and timeout where
# they differ from exit 0 and no deadline), their products in out. Given the
# runtime under test, the identity primitives come too: identity_driver.c
# with src/resource.c, which parses the ICO and PE bytes wrap stamps, over
# test/identity_native_test.tcl and that runtime's packaged basekits (the
# step's extract, put in place before it and deleted after with its work).
proc ::na::trappedSteps {layout gcc out {runtime ""}} {
    variable root
    variable trapped
    set src [file join $root src]
    set test [file join $root test]
    set fixtures [file join $test fixtures]
    set trap {-fsanitize=undefined -fsanitize-undefined-trap-on-error}
    set flags [list -std=c23 -O1 -g -Wall -Wextra -Werror -DSTATIC_BUILD=1 \
        -I[dict get $layout include] -I$src {*}$trap]
    set tcl [list [dict get $layout tcllib] -static-libgcc {*}$::machteld::build::SYSLIBS]
    set steps {}
    set canary [file join $out trap-canary.exe]
    lappend steps [dict create label "UB-trap canary" \
        argv [list $gcc -std=c23 -O1 {*}$trap [file join $fixtures native_analysis_canary.c] -o $canary]]
    lappend steps [dict create label "UB-trap canary runs clean" argv [list $canary]]
    foreach fault {overflow bounds} {
        lappend steps [dict create label "UB-trap canary traps $fault" argv [list $canary $fault] \
            expect $trapped timeout 30s]
    }
    set cmdline [file join $out cmdline-trap.exe]
    lappend steps [dict create label "trapped command line: compile" argv [list $gcc {*}$flags \
        [file join $test cmdline_test.c] [file join $src winjob_cmdline.c] -static-libgcc -o $cmdline]]
    lappend steps [dict create label "trapped command line" argv [list $cmdline]]
    set allocation [file join $out cmdline-allocation-trap.exe]
    lappend steps [dict create label "trapped command-line allocation failures: compile" argv [list $gcc {*}$flags \
        [file join $test cmdline_alloc_test.c] -static-libgcc -o $allocation]]
    lappend steps [dict create label "trapped command-line allocation failures" argv [list $allocation]]
    set wintext [file join $out wintext-trap.exe]
    lappend steps [dict create label "trapped Unicode conversion: compile" argv [list $gcc {*}$flags \
        [file join $test wintext_test.c] [file join $src wintext.c] [file join $src winjob_cmdline.c] \
        -static-libgcc -lshell32 -o $wintext]]
    lappend steps [dict create label "trapped Unicode conversion" argv [list $wintext]]
    set json [file join $out json-trap.exe]
    set yyjson [dict get $layout yyjson]
    lappend steps [dict create label "trapped JSON: compile" argv [list $gcc {*}$flags -municode -I$yyjson \
        [file join $fixtures native_analysis_driver.c] [file join $src json.c] [file join $src wintext.c] \
        [file join $yyjson yyjson.c] {*}$tcl -o $json]]
    lappend steps [dict create label "trapped JSON corpus" argv [list $json [file join $test json_test.tcl]]]
    lappend steps [dict create label "trapped JSON adversarial inputs" \
        argv [list $json [file join $test native_adversarial_test.tcl] --json-only]]
    set sqlite [dict get $layout sqlite]
    set sqliteObject [file join $out sqlite-boundary.o]
    lappend steps [dict create label "SQLite for the boundary driver, uninstrumented" argv [list $gcc -O0 -w \
        -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED \
        -DSQLITE_OMIT_SHARED_CACHE -c [file join $sqlite sqlite3.c] -o $sqliteObject]]
    set boundary [file join $out native-boundary-trap.exe]
    lappend steps [dict create label "trapped native boundaries: compile" argv [list $gcc {*}$flags -I$sqlite \
        [file join $fixtures native_boundary_driver.c] [file join $src wintext.c] $sqliteObject {*}$tcl -o $boundary]]
    lappend steps [dict create label "trapped native boundaries" argv [list $boundary]]
    set hashBoundary [file join $out hash-boundary-trap.exe]
    lappend steps [dict create label "trapped hash sequence boundary: compile" argv [list $gcc {*}$flags \
        [file join $test hash_boundary_test.c] {*}$tcl -o $hashBoundary]]
    lappend steps [dict create label "trapped hash sequence boundary" argv [list $hashBoundary]]
    if {$runtime ne ""} {
        set identity [file join $out identity-trap.exe]
        set id [pid]-[binary encode hex [hash random 8]]
        set console [file join $out .identity-console-$id.exe]
        set gui [file join $out .identity-gui-$id.exe]
        set work [file join $out .identity-work-$id]
        lappend steps [dict create label "trapped identity: compile" argv [list $gcc {*}$flags -municode \
            [file join $fixtures identity_driver.c] [file join $src resource.c] [file join $src wintext.c] {*}$tcl -o $identity]]
        lappend steps [dict create label "trapped identity" \
            argv [list $identity [file join $test identity_native_test.tcl] $console $gui $work] \
            extract [list basekit/console.exe $console basekit/gui.exe $gui] cleanup [list $console $gui $work]]
    }
    return $steps
}

# ---- the full harness ----

# Runs one invocation, its output to a numbered log in the output folder, and
# records it for the report.
proc ::na::invoke {name argv {timeout 180s}} {
    variable root
    variable runs
    variable output
    say "native-analysis: $name"
    set started [clock milliseconds]
    if {[catch {run -timeout $timeout -dir $root -- {*}$argv} result]} {
        set result [dict create status error exit -1 out "" err [encoding convertto utf-8 $result] truncated {}]
    }
    set seconds [format %.3f [expr {([clock milliseconds] - $started) / 1000.0}]]
    set log [format %03d-%s.log [expr {[llength $runs] + 1}] [regsub -all {[^a-zA-Z0-9-]} $name -]]
    set channel [open [file join $output $log] wb]
    puts -nonewline $channel "[dict get $result out][dict get $result err]"
    close $channel
    lappend runs [dict create name $name program [lindex $argv 0] arguments [lrange $argv 1 end] \
        status [dict get $result status] exit [dict get $result exit] seconds $seconds log $log \
        truncated [dict get $result truncated]]
    dict create name $name status [dict get $result status] exit [dict get $result exit] log $log \
        text [encoding convertfrom -profile replace utf-8 "[dict get $result out][dict get $result err]"]
}

proc ::na::requireOk {result {expect 0}} {
    variable output
    if {[dict get $result status] ni {ok error} ||
            ([dict get $result exit] & 0xFFFFFFFF) != ($expect & 0xFFFFFFFF)} {
        fail "[dict get $result name] failed ([dict get $result status], exit [dict get $result exit]); see [file nativename [file join $output [dict get $result log]]]"
    }
}

# Runs and requires success; shows the end of the output.
proc ::na::runOk {name argv {expect 0} {timeout 180s}} {
    variable output
    set result [invoke $name $argv $timeout]
    requireOk $result $expect
    set lines [split [string trimright [dict get $result text]] \n]
    if {[llength $lines] > 8} {
        say "detailed output: [file nativename [file join $output [dict get $result log]]]"
    }
    if {[llength $lines]} {
        say [join [lrange $lines end-7 end] \n]
    }
    return $result
}

# JSON from tagged nodes: {S text} {N number} {B flag} {Z} {L items} {O dict}.
proc ::na::typed {node} {
    set value [lassign $node tag]
    set value [lindex $value 0]
    switch -- $tag {
        S {json value string $value}
        N {json value number $value}
        B {json value boolean [expr {$value ? "true" : "false"}]}
        Z {json value null}
        L {json value array [lmap item $value {typed $item}]}
        O {json value object [dict map {key item} $value {typed $item}]}
        default {error "untyped report value: $node"}
    }
}

proc ::na::strings {items} {
    list L [lmap item $items {list S $item}]
}

proc ::na::now {} {
    clock format [clock seconds] -format %Y-%m-%dT%H:%M:%SZ -gmt 1
}

proc ::na::main {argv} {
    variable root
    variable runs
    variable output
    variable trapped
    set cache [file join $root .cache deps]
    set msysRequested ""
    set output ""
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --cache - --msys - --output {
                if {![llength $argv]} {
                    fail "$option needs a value"
                }
                set argv [lassign $argv value]
                switch -- $option {
                    --cache {set cache $value}
                    --msys {set msysRequested $value}
                    --output {set output $value}
                }
            }
            default {fail "unknown option $option"}
        }
    }
    set cache [file normalize $cache]
    set msys [::boot::msysRoot $msysRequested]
    if {$output eq ""} {
        set output [file join $root out native-analysis-[binary encode hex [hash random 16]]]
    }
    set output [file normalize $output]
    # Never merged with an earlier run or with anything else.
    if {[file exists $output]} {
        fail "analysis output must be absent: [file nativename $output]"
    }
    file mkdir $output
    set gcc [file join $msys ucrt64 bin gcc.exe]
    set canary [file join $root test fixtures native_analysis_canary.c]
    set capabilities {}
    set report [dict create schema {N 1} status {S running} started_utc [list S [now]] compiler [list S [file nativename $gcc]] \
        dependency_instrumentation {S {Tcl/Tk and SQLite archives are not instrumented; yyjson is instrumented with the JSON harness.}} \
        instrumented_scope [strings {
            {command-line quoting and allocation failures}
            {UTF-8/UTF-16 conversion and Windows argv round trips}
            {JSON reader/emitter/typed-tree ownership with yyjson}
            {filesystem length/capacity boundaries}
            {SQLite result cleanup and HTTP header-key ownership}
            {hash token sequence exhaustion}}] \
        limits [strings {
            {GCC analyzer is heuristic, not a proof.}
            {Undefined-behavior traps do not detect all heap errors, leaks, or Win32 HANDLE misuse.}
            {The Tk fixture exercises the real index formatter, not GUI rendering or a multi-gigabyte text widget.}}]]
    set saved {}
    foreach name {PATH MACHTELD_WERROR UBSAN_OPTIONS ASAN_OPTIONS} {
        if {[info exists ::env($name)]} {
            dict set saved $name $::env($name)
        }
    }
    try {
        set ::env(PATH) "[file nativename [file join $msys ucrt64 bin]][expr {[dict exists $saved PATH] ? ";[dict get $saved PATH]" : ""}]"
        set ::env(MACHTELD_WERROR) 1
        set ::env(UBSAN_OPTIONS) halt_on_error=1:print_stacktrace=1
        set ::env(ASAN_OPTIONS) halt_on_error=1:detect_leaks=0
        # Hashes only: this cannot download or rebuild dependencies.
        set verified [run -inherit -- [info nameofexecutable] [file join $root tools bootstrap.tcl] \
            --cache $cache --msys $msys --verify-only]
        if {[dict get $verified exit] != 0} {
            fail "dependency verification failed"
        }
        set paths [::machteld::build::paths $cache]
        set flags [::machteld::build::common_flags $paths]
        set libraries $::machteld::build::SYSLIBS
        dict set report compiler_sha256 [list S [hash file sha256 $gcc]]
        set version [invoke compiler-version [list $gcc --version]]
        requireOk $version
        dict set report compiler_version [list S [string trim [dict get $version text]]]
        set inputs [lsort [concat [glob -directory [file join $root src] *.c] [glob -directory [file join $root src] *.h]]]
        foreach relative {
            tools/native-analysis.tcl tools/buildlib.tcl test/cmdline_test.c test/cmdline_alloc_test.c
            test/wintext_test.c test/hash_boundary_test.c test/json_test.tcl test/native_adversarial_test.tcl
            test/fixtures/native_analysis_canary.c test/fixtures/native_analysis_driver.c
            test/fixtures/native_boundary_driver.c test/fixtures/tk_index_format_test.c
        } {
            lappend inputs [file join $root {*}[split $relative /]]
        }
        set sources {}
        foreach path $inputs {
            dict set sources [string range $path [string length $root/] end] [hash file sha256 $path]
        }
        dict set report source_sha256 [list O [dict map {key value} $sources {list S $value}]]

        # A negative canary must produce the one diagnostic, not merely fail.
        set analyzerCanary [invoke analyzer-negative-canary [list $gcc -std=c23 -O0 -fanalyzer \
            -Werror=analyzer-use-after-free -DANALYZER_CANARY -c $canary -o [file join $output analyzer-canary.o]]]
        if {[dict get $analyzerCanary exit] == 0 || ![string match *analyzer-use-after-free* [dict get $analyzerCanary text]]} {
            fail "GCC's analyzer did not detect the required use-after-free canary"
        }
        dict set capabilities gcc_analyzer {S {supported; negative use-after-free canary detected}}
        foreach file [lsort [glob -directory [file join $root src] *.c]] {
            set base [file rootname [file tail $file]]
            runOk analyzer-$base [list $gcc {*}$flags -O0 -fanalyzer -fdiagnostics-path-format=separate-events \
                -c $file -o [file join $output $base.analysis.o]]
        }

        foreach mode {address undefined} {
            set exe [file join $output $mode-canary.exe]
            set probe [invoke $mode-capability [list $gcc -std=c23 -O1 -fsanitize=$mode -fno-sanitize-recover=all $canary -o $exe]]
            if {[dict get $probe exit] != 0} {
                if {![regexp {cannot find -l(asan|ubsan)|unsupported|unrecognized} [dict get $probe text]]} {
                    fail "unexpected sanitizer capability failure: [dict get $probe text]"
                }
                dict set capabilities $mode [list O [dict create status {S unsupported} \
                    reason [list S [string trim [dict get $probe text]]] log [list S [dict get $probe log]]]]
                say "UNSUPPORTED: $mode sanitizer runtime (see [dict get $probe log])"
                continue
            }
            runOk $mode-clean-canary [list $exe]
            set bad [invoke $mode-negative-canary [list $exe [expr {$mode eq "address" ? "heap" : "overflow"}]] 15s]
            if {[dict get $bad exit] == 0 || ![regexp {AddressSanitizer|runtime error} [dict get $bad text]]} {
                fail "the $mode sanitizer did not diagnose its negative canary"
            }
            dict set capabilities $mode [list O [dict create status {S supported} canary [list S [dict get $bad log]]]]
        }

        # The trapped drivers, the gate's own steps, each after the canary.
        foreach step [trappedSteps [layout $cache] $gcc $output] {
            set expect [expr {[dict exists $step expect] ? [dict get $step expect] : 0}]
            set timeout [expr {[dict exists $step timeout] ? [dict get $step timeout] : "180s"}]
            runOk [regsub -all { } [dict get $step label] -] [dict get $step argv] $expect $timeout
        }
        dict set capabilities undefined_trap {S {supported; signed-overflow and array-bounds negative canaries trapped}}

        # The linked archive is the Tk the runtime uses, not a copied snprintf;
        # only the synthetic tree's line lookup is replaced.
        set tkRoots [glob -nocomplain -types d [file join $cache src tcltk-* tk*]]
        if {[llength $tkRoots] != 1} {
            fail "expected exactly one pinned Tk source directory, found [llength $tkRoots]"
        }
        set tk [lindex $tkRoots 0]
        set tkExe [file join $output tk-index-format.exe]
        set tkIncludes [lmap dir {generic win xlib} {string cat -I [file join $tk $dir]}]
        runOk tk-real-index-formatter [list $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -I[dict get $paths include] {*}$tkIncludes \
            [file join $root test fixtures tk_index_format_test.c] [dict get $paths tklib] [dict get $paths tcllib] \
            [dict get $paths tclstub] -Wl,--wrap=TkBTreeLinesTo -static-libgcc {*}$libraries -o $tkExe]
        runOk tk-large-index-headless [list $tkExe]
        dict set capabilities tk_large_index {S {real pinned TkTextPrintIndex passed 0, 2^31, 2^32+17, INT64_MAX without Tk_Init/windows}}

        # The compiler's output paths apart from Unicode deployment.
        set ascii [file join $output "ASCII output with spaces"]
        set unicode [file join $output output-[format %c%c 0x4e16 0x754c]]
        file mkdir $ascii $unicode
        set asciiExe [file join $ascii canary.exe]
        runOk ascii-spaces-output [list $gcc -std=c23 $canary -o $asciiExe]
        runOk ascii-spaces-execution [list $asciiExe]
        set unicodeResults {}
        foreach stage {assembler linker} {
            set target [file join $unicode [expr {$stage eq "assembler" ? "canary.o" : "canary.exe"}]]
            set arguments [list -std=c23 $canary -o $target]
            if {$stage eq "assembler"} {
                set arguments [linsert $arguments 0 -c]
            }
            set probe [invoke unicode-output-$stage [list $gcc {*}$arguments]]
            if {[dict get $probe exit] != 0 && ![regexp {can.t create|cannot open output file} [dict get $probe text]]} {
                fail "unexpected Unicode output failure: [dict get $probe text]"
            }
            dict set unicodeResults $stage [list O [dict create \
                status [list S [expr {[dict get $probe exit] == 0 ? "supported" : "unsupported"}]] \
                log [list S [dict get $probe log]] detail [list S [string trim [dict get $probe text]]]]]
        }
        set deployed [file join $unicode deployed-canary.exe]
        file copy $asciiExe $deployed
        runOk unicode-deployed-execution [list $deployed]
        dict set capabilities unicode_native_output [list O $unicodeResults]

        dict for {relative digest} $sources {
            if {[hash file sha256 [file join $root {*}[split $relative /]]] ne $digest} {
                fail "source changed during native analysis: $relative; rerun on a stable checkout"
            }
        }
        dict set report source_inputs_unchanged {B 1}
        dict set report status {S passed}
    } on error {message options} {
        dict set report status {S failed}
        dict set report error [list S $message]
        return -options $options $message
    } finally {
        dict set report finished_utc [list S [now]]
        dict set report capabilities [list O $capabilities]
        dict set report runs [list L [lmap item $runs {
            list O [dict create name [list S [dict get $item name]] program [list S [dict get $item program]] \
                arguments [strings [dict get $item arguments]] status [list S [dict get $item status]] \
                exit [list N [dict get $item exit]] seconds [list N [dict get $item seconds]] \
                log [list S [dict get $item log]] truncated [strings [dict get $item truncated]]]
        }]]
        set channel [open [file join $output report.json] wb]
        puts -nonewline $channel [encoding convertto utf-8 "[json encode [typed [list O $report]]]\n"]
        close $channel
        foreach name {PATH MACHTELD_WERROR UBSAN_OPTIONS ASAN_OPTIONS} {
            if {[dict exists $saved $name]} {
                set ::env($name) [dict get $saved $name]
            } else {
                unset -nocomplain ::env($name)
            }
        }
        say "native analysis report: [file nativename [file join $output report.json]]"
    }
}

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    try {
        ::na::main $argv
    } trap {NATIVE fail} {message} {
        puts stderr $message
        exit 1
    } trap {BOOTSTRAP fail} {message} {
        puts stderr $message
        exit 1
    }
}
