package require machteld 0.21

# tools/dev.tcl -- the fast development loop for machteld. NOT the release gate.
#
# Run on the build runtime, as every tool here is (dist/0.21/machteld.exe,
# the signed machteld 0.21; MSYS2 from MSYS2_ROOT or C:/msys64):
#     machteld.exe tools/dev.tcl docs           docs checks only, no build (seconds)
#     machteld.exe tools/dev.tcl build ?-ref?   incremental build -> out/machteld.exe
#     machteld.exe tools/dev.tcl test LANE ...  named pure-Tcl lane(s) against the existing executable
#     machteld.exe tools/dev.tcl clean          delete the dev cache
#
# Speed comes from a PERSISTENT cache in .cache/dev that the hermetic release
# build never uses: the 9 MB SQLite amalgamation is compiled once and reused;
# authored src/*.c recompile only when their recorded content/configuration
# inputs change; reference generations are immutable and reused by content.
#
# Freshness uses SHA-256 of contents, names and configuration, never mtimes.
# A changed dependency recipe requires bootstrap rather than blessing an old
# installed prefix. The release gate, tools/gate.tcl, still adds a clean
# reconstruction and comprehensive validation. Compilation/linking share
# tools/buildlib.tcl.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
proc Rp {args} { return [file join $::ROOT {*}$args] }
set LOADED_RECIPES {}
proc load_recipe {path {evaluate 1}} {
    set ch [open $path rb]
    try { set bytes [read $ch] } finally { close $ch }
    dict set ::LOADED_RECIPES $path $bytes
    # Evaluate the exact captured bytes, not a second mutable read, with
    # `info script` naming the helper itself, as `source` would: bootstrap.tcl
    # finds its root by it and runs its main only as the entry script.
    if {$evaluate} {
        set caller [info script]
        info script $path
        try {
            uplevel #0 [encoding convertfrom -profile strict utf-8 $bytes]
        } finally {
            info script $caller
        }
    }
}
proc verify_loaded_recipes {} {
    dict for {path loaded} $::LOADED_RECIPES {
        set ch [open $path rb]
        try { set current [read $ch] } finally { close $ch }
        if {$current ne $loaded} { error "build recipe changed after loading; restart development build: $path" }
    }
}
# Capture the running coordinator before slow bootstrap verification too; an
# edit during that interval must not pair old procedures with a new input key.
load_recipe [Rp tools dev.tcl] 0
load_recipe [Rp tools buildlib.tcl]
load_recipe [Rp tools devcache.tcl]
load_recipe [Rp tools bootstrap.tcl]
# Global `run` is buildlib's streaming exec; the runtime's own run stays
# reachable as ::machteld::run.
namespace import ::machteld::build::run

# ---- toolchain discovery: bootstrap's order, MSYS2_ROOT then C:/msys64 ----

set MSYS2 [::boot::msysRoot ""]
set GCC     [file join $MSYS2 ucrt64 bin gcc.exe]
set STRIP   [file join $MSYS2 ucrt64 bin strip.exe]
set WINDRES [file join $MSYS2 ucrt64 bin windres.exe]
if {![file exists $WINDRES]} { error "dev.tcl: missing windres: $WINDRES" }
set ::env(PATH) "[file nativename [file join $MSYS2 ucrt64 bin]];$::env(PATH)"

# ---- machteld's own bootstrapped dependency cache (from a prior release build) ----

set CACHE [::machteld::build::cache_root $ROOT]
if {[catch {::machteld::build::paths $CACHE} PATHS]} {
    error "dev.tcl: $PATHS\n  run tools/bootstrap.tcl once to bootstrap [file nativename $CACHE]"
}
set TCLSH  [dict get $PATHS tclsh]
set PREFIX [dict get $PATHS prefix]

# ---- the persistent dev cache (absent from the release build) ----

set DEV [Rp .cache dev]
set OBJ [file join $DEV obj]
set REF [file join $DEV reference]
file mkdir $OBJ

set common [::machteld::build::common_flags $PATHS]

# Snapshot the C toolchain's transitive implementation, headers and libraries,
# not the entire MSYS installation. This relatively expensive group is hashed
# once per guard snapshot, never once per object. Include DLLs
# because gcc/as/ld can change behavior without their own executable changing.
proc toolchain_key {} {
    return [::machteld::devcache::toolchain_digest $::MSYS2]
}

proc guard_spec {{toolchainKey ""}} {
    if {$toolchainKey eq ""} { set toolchainKey [toolchain_key] }
    set spec [dict create files {} trees {}]
    foreach name {src tcl docs licenses tools} { dict lappend spec trees [Rp $name] }
    foreach name {prefix sqlite yyjson downloads} { dict lappend spec trees [file join $::CACHE $name] }
    dict lappend spec files [Rp LICENSE]
    # Reject untracked external search paths rather than assuming a stable path
    # string proves the contents of headers/libraries located through it.
    dict set spec values [list toolchain $toolchainKey environment [::machteld::devcache::compiler_environment]]
    return $spec
}

proc compile_candidate {src flags label candidate} {
    puts "  cc  $label"
    ::machteld::devcache::with_native_environment $::MSYS2 {
        run $::GCC {*}$flags -c $src -o $candidate
    }
}

proc cc {obj src flags label {shared 1}} {
    set spec [dict create files [list $src [Rp tools buildlib.tcl]] \
        values [list flags $flags toolchain $::TOOLCHAIN_KEY dependencies $::DEPS_KEY environment $::BUILD_ENV]]
    if {$shared} {
        dict lappend spec values headers $::HEADERS_KEY
    } else {
        dict set spec trees [list [file dirname $src]]
    }
    return [::machteld::devcache::ensure $obj.record $spec $obj [list compile_candidate $src $flags $label]]
}

proc resource_candidate {kind candidate} {
    puts "  rc  machteld-$kind.rc"
    ::machteld::devcache::with_native_environment $::MSYS2 {
        ::machteld::build::version_resource $::TCLSH $::WINDRES $::ROOT $kind \
            [file join $::OBJ "machteld-$kind.rc"] $candidate
    }
}

proc version_resource {kind obj} {
    set spec [dict create files [list [Rp src machteld.h] [Rp tools generate-version-resource.tcl] \
        [Rp tools buildlib.tcl] $::TCLSH] values [list $kind $::TOOLCHAIN_KEY $::BUILD_ENV]]
    return [::machteld::devcache::ensure $obj.record $spec $obj [list resource_candidate $kind]]
}

proc link_candidate {kind main resource objects sqlite yyjson candidate} {
    puts "  ld  $kind host"
    ::machteld::devcache::with_native_environment $::MSYS2 {
        ::machteld::build::link_host $::GCC $::STRIP $kind $main $resource $objects $sqlite $yyjson $::PATHS $candidate
    }
}

proc prelude_candidate {candidate} {
    set manifest [file join $::OBJ manifest.tcl]
    run $::TCLSH [Rp tools genmanifest.tcl] [Rp src] $manifest
    ::machteld::build::stage_prelude $::ROOT $manifest $candidate
}

proc reference_candidate {candidate} {
    puts "  ref generating corpus (previous generations remain untouched)"
    run [info nameofexecutable] [Rp tools reference.tcl] \
        --cache $::CACHE --output $candidate --tclsh $::TCLSH
}

proc package_candidate {staged bare bareGui reference candidate} {
    # The input guard covers shared group snapshots used by compilation. Check
    # both before and after packaging so an edit during a long generation is
    # never published as a verified current build.
    ::machteld::devcache::verify_guard $::GUARD_KEY guard_spec
    set identity [::machteld::devcache::cache_candidate [file join $::OBJ build-info.dict]]
    source [Rp tools build_identity.tcl]
    set ch [open [Rp src machteld.h] r]
    try { set header [read $ch] } finally { close $ch }
    if {![regexp -line {^#define\s+MACHTELD_VERSION\s+"([0-9.]+)"} $header -> version]} {
        error "missing canonical runtime version"
    }
    set ch [open [file join $reference catalog.dict] r]
    fconfigure $ch -encoding utf-8 -translation lf
    try { set catalog [read $ch] } finally { close $ch }
    try {
        ::machteld::buildidentity::create $identity $version $::SOURCE_REVISION $::PACKAGE_INPUT_KEY [dict get $catalog corpus_sha256]
        run $::TCLSH [Rp tools package.tcl] --prefix $::PREFIX --prelude $staged --wrapper $bare --out $candidate \
            --licenses [Rp licenses] --apache-license [Rp LICENSE] --reference $reference \
            --embed-console $bare --embed-gui $bareGui --build-info $identity
    } finally { if {[file exists $identity]} { file delete $identity } }
    ::machteld::devcache::verify_guard $::GUARD_KEY guard_spec
}

# ---- the incremental build ----

proc dev_build {{forceRef 0}} {
    set lock [file join $::DEV build.lock]
    if {[catch {::machteld::devcache::lock $lock} reason]} {
        error "development cache is in use by another build: $reason"
    }
    try { dev_build_unlocked $forceRef } finally { catch {::machteld::devcache::unlock $lock} }
}

proc dev_build_unlocked {{forceRef 0}} {
    puts "build: incremental (cache [file nativename $::DEV])"
    ::machteld::devcache::compiler_environment
    run [info nameofexecutable] [Rp tools bootstrap.tcl] --cache $::CACHE --msys $::MSYS2 --verify-only
    # Missing/legacy records cause a rebuild. In particular a timestamp-only
    # reference.stamp is never accepted as proof of a generated pack's inputs.
    set ::TOOLCHAIN_KEY [toolchain_key]
    set ::GUARD_SPEC [guard_spec $::TOOLCHAIN_KEY]
    set ::GUARD_KEY [::machteld::devcache::fingerprint $::GUARD_SPEC]
    verify_loaded_recipes
    set ::BUILD_ENV [::machteld::devcache::native_environment $::MSYS2]
    set ::DEPS_KEY [::machteld::devcache::fingerprint [::machteld::devcache::dependency_spec $::ROOT $::CACHE]]
    set ::HEADERS_KEY [::machteld::devcache::fingerprint [::machteld::devcache::native_shared_spec $::ROOT $::PATHS $::TOOLCHAIN_KEY]]
    set changed 0

    # Pinned third-party sources: SQLite and yyjson, cached across builds with
    # their own flags from buildlib.tcl, never the authored -Werror set.
    set sqliteObj [file join $::OBJ sqlite3.o]
    set yyjsonObj [file join $::OBJ yyjson.o]
    incr changed [cc $sqliteObj [file join [dict get $::PATHS sqlite] sqlite3.c] \
        $::machteld::build::SQLITE_FLAGS sqlite3.c 0]
    incr changed [cc $yyjsonObj [file join [dict get $::PATHS yyjson] yyjson.c] \
        $::machteld::build::YYJSON_FLAGS yyjson.c 0]
    # Authored translation units.
    set consoleMain [Rp src machteld_main.c]
    set guiMain     [Rp src machteld_gui_main.c]
    set objects {}
    foreach s [lsort [glob -directory [Rp src] *.c]] {
        if {$s eq $consoleMain || $s eq $guiMain} continue
        set o [file join $::OBJ [file rootname [file tail $s]].o]
        incr changed [cc $o $s $::common [file tail $s]]
        lappend objects $o
    }
    set consoleObj [file join $::OBJ machteld_main.o]
    incr changed [cc $consoleObj $consoleMain [concat $::common -municode] machteld_main.c]
    set guiObj [file join $::OBJ machteld_gui_main.o]
    incr changed [cc $guiObj $guiMain [concat $::common -municode] machteld_gui_main.c]
    set consoleVersionObj [file join $::OBJ machteld-console-resource.o]
    set guiVersionObj [file join $::OBJ machteld-gui-resource.o]
    incr changed [version_resource console $consoleVersionObj]
    incr changed [version_resource gui $guiVersionObj]

    # Link keys include static libraries and toolchain/configuration identity,
    # not merely whether this invocation compiled an object.
    set bare    [file join $::DEV machteld-bare.exe]
    set bareGui [file join $::DEV machteld-bare-gui.exe]
    foreach kind {console gui} main [list $consoleObj $guiObj] resource [list $consoleVersionObj $guiVersionObj] output [list $bare $bareGui] {
        set inputs [list $main $resource {*}$objects $sqliteObj $yyjsonObj [Rp tools buildlib.tcl]]
        foreach name {tcllib tklib tclstub} { lappend inputs [dict get $::PATHS $name] }
        set spec [dict create files $inputs values [list $kind $::TOOLCHAIN_KEY $::DEPS_KEY $::BUILD_ENV]]
        ::machteld::devcache::ensure $output.record $spec $output [list link_candidate $kind $main $resource $objects $sqliteObj $yyjsonObj]
    }

    # Manifest + prelude: unchanged builds invoke neither generator.
    set staged [file join $::OBJ prelude.tcl]
    set inputs [list $::TCLSH [Rp tools genmanifest.tcl] [Rp tools manifest_spec.tcl] [Rp tools buildlib.tcl]]
    foreach name $::machteld::build::PRELUDE_PARTS { lappend inputs [Rp tcl $name] }
    set spec [dict create files $inputs trees [list [Rp src]]]
    ::machteld::devcache::ensure $staged.record $spec $staged prelude_candidate

    set ::REF [::machteld::devcache::immutable [file join $::DEV reference.record] \
        [::machteld::devcache::reference_spec $::ROOT $::CACHE $::TCLSH] \
        $::DEV reference_candidate $forceRef]

    set final [Rp out machteld.exe]
    file mkdir [Rp out]
    set spec [::machteld::devcache::package_spec $::ROOT $::PATHS $staged $bare $bareGui $::REF]
    if {[catch {exec git -C $::ROOT rev-parse HEAD} ::SOURCE_REVISION]} { set ::SOURCE_REVISION unknown }
    set ::SOURCE_REVISION [string trim $::SOURCE_REVISION]
    dict set spec values [list source_revision $::SOURCE_REVISION build_inputs $::GUARD_KEY]
    set ::PACKAGE_INPUT_KEY [::machteld::devcache::fingerprint $spec]
    if {[::machteld::devcache::ensure [file join $::DEV package.record] $spec $final \
            [list package_candidate $staged $bare $bareGui $::REF]]} {
        puts "build: out/machteld.exe ([file size $final] bytes)"
    } else {
        # Cache hits skip package_candidate, but must not skip the final guard.
        ::machteld::devcache::verify_guard $::GUARD_KEY guard_spec
        puts "build: out/machteld.exe current ([file size $final] bytes)"
    }
}

# ---- docs checks: no build ----

proc dev_docs {} {
    set fail 0
    # 1. Front matter and balanced code fences on every guide.
    foreach f [lsort [glob -nocomplain [Rp docs *.md]]] {
        set fh [open $f r]; fconfigure $fh -encoding utf-8; set text [read $fh]; close $fh
        set name [file tail $f]
        if {![string match "---\n*" $text]} {
            puts "  FAIL $name: no YAML front matter"; incr fail
        }
        set fences 0
        foreach line [split $text \n] { if {[string match "```*" $line]} { incr fences } }
        if {$fences % 2} { puts "  FAIL $name: unbalanced ``` fences ($fences)"; incr fail }
    }
    if {!$fail} { puts "  ok   front matter and code fences balanced ([llength [glob [Rp docs *.md]]] guides)" }

    # 2. The reference coverage/link checker (pure Tcl, no build).
    puts "  check_reference.tcl:"
    if {[catch {run $::TCLSH [Rp tools check_reference.tcl]} err]} {
        puts "  FAIL check_reference: $err"; incr fail
    } else {
        puts "  ok   reference links and coverage"
    }

    # 3. Every prose version claim agrees with src/machteld.h.
    if {[catch {run $::TCLSH [Rp tools check_version.tcl]} err]} {
        puts "  FAIL check_version: $err"; incr fail
    } else {
        puts "  ok   version claims agree with the header"
    }

    # 4. If a built exe exists, confirm each guide resolves in its corpus.
    set exe [Rp out machteld.exe]
    if {[file exists $exe]} {
        set probe [file join $::DEV docprobe.tcl]
        set ids {}
        foreach f [lsort [glob -nocomplain [Rp docs *.md]]] {
            lappend ids "machteld/guide/[file rootname [file tail $f]]"
        }
        set p [open $probe w]; fconfigure $p -translation lf
        puts $p "package require machteld"
        puts $p "set bad 0"
        puts $p "foreach id {$ids} {"
        puts $p {  if {[catch {docs get $id} e]} { puts "  FAIL corpus missing $id"; incr bad }}
        puts $p "}"
        puts $p {if {!$bad} { puts "  ok   built corpus resolves every guide" }}
        puts $p {exit [expr {$bad != 0}]}
        close $p
        if {[catch {run $exe $probe} err]} {
            puts "  FAIL corpus probe (built exe may be stale; dev.tcl build to refresh)"; incr fail
        }
    } else {
        puts "  --   no out/machteld.exe yet; dev.tcl build to check the built corpus"
    }
    if {$fail} { puts "docs: $fail problem(s)"; exit 1 }
    puts "docs: ok"
}

# ---- targeted test lanes (the pure-Tcl ones you iterate on) ----

# Lanes needing compiled C fixtures or basekit extraction (process, native,
# store, wrap, entry) and the full conversion/determinism check (the reference
# generator) run in tools/gate.tcl, alone with --group integration, packaging
# or reference-generator.
set ::LANES {
    filesystem test/filesystem_test.tcl
    runtime    test/runtime_test.tcl
    protocol   test/protocol_test.tcl
    gui_model  test/gui_model_test.tcl
    reference  test/reference_test.tcl
    json       test/json_test.tcl
}

proc dev_test {lanes} {
    set exe [Rp out machteld.exe]
    if {![file isfile $exe]} { error "missing $exe; run dev.tcl build explicitly first" }
    puts "test: existing executable [file nativename $exe]"
    set exeHash [::machteld::devcache::file_digest $exe]
    puts "test: SHA-256 $exeHash"
    if {![llength $lanes]} {
        puts "test: name one or more lanes: [dict keys $::LANES]"; exit 2
    }
    set fail 0
    foreach lane $lanes {
        if {![dict exists $::LANES $lane]} {
            puts "test: unknown lane '$lane' (known: [dict keys $::LANES]);"
            puts "      fixture-heavy lanes (process native store wrap entry) use tools/gate.tcl --group integration or packaging"
            incr fail; continue
        }
        set path [Rp {*}[split [dict get $::LANES $lane] /]]
        puts "== lane $lane"
        if {[catch {run $exe $path} err]} { puts "  FAIL $lane"; incr fail } \
        else { puts "  ok   $lane" }
    }
    if {[::machteld::devcache::file_digest $exe] ne $exeHash} { error "tested executable changed during the test run" }
    if {$fail} { puts "test: $fail lane(s) failed"; exit 1 }
    puts "test: ok"
}

proc dev_clean {} {
    set expected [file normalize [Rp .cache dev]]
    if {[file normalize $::DEV] ne $expected} { error "refusing unexpected development cache path: $::DEV" }
    ::machteld::devcache::clean $expected
    puts "cleaned [file nativename $expected] (its build.lock released last)"
}

# ---- dispatch ----

set task [lindex $argv 0]
set rest [lrange $argv 1 end]
switch -- $task {
    ""      { puts "tasks: docs | build ?-ref? | test LANE ... | clean" }
    docs    { dev_docs }
    build   { dev_build [expr {[lindex $rest 0] eq "-ref"}] }
    test    { dev_test $rest }
    clean   { dev_clean }
    default { error "unknown task '$task' (docs build test clean)" }
}
