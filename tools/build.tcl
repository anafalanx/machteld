# Build the self-contained Windows hosts from the repository-local dependency
# prefix created by tools/bootstrap.ps1.
#
# Prefer tools/build.ps1, which verifies/bootstraps the cache and owns a unique
# work directory plus an absent output candidate. Direct callers must provide
# MACHTELD_BUILD_ROOT and MACHTELD_REFERENCE_ROOT with the same guarantees.
#
# What gets compiled, with which flags, against which libraries, and what the
# prelude is made of, is described once in tools/buildlib.tcl and shared with
# the development loop (tools/dev.tcl). This file only owns the hermetic
# invocation: an absent output candidate, a unique work directory, the
# reference pack, and packaging.

set ROOT [file dirname [file dirname [file normalize [info script]]]]
proc Rp {args} { return [file join $::ROOT {*}$args] }
source [Rp tools buildlib.tcl]
namespace import ::machteld::build::run

set GCC [expr {[info exists ::env(MACHTELD_GCC)] ? $::env(MACHTELD_GCC) : ""}]
set STRIP [expr {[info exists ::env(MACHTELD_STRIP)] ? $::env(MACHTELD_STRIP) : ""}]
set WINDRES [expr {[info exists ::env(MACHTELD_WINDRES)] ? $::env(MACHTELD_WINDRES) : ""}]
if {$GCC eq ""} { error "build.tcl: MACHTELD_GCC is not set; use tools/build.ps1" }
if {$WINDRES eq ""} { error "build.tcl: MACHTELD_WINDRES is not set; use tools/build.ps1" }
foreach {label path} [list gcc $GCC windres $WINDRES] {
    if {![file exists $path]} { error "build.tcl: missing $label: $path" }
}
if {[catch {::machteld::build::paths [::machteld::build::cache_root $ROOT]} PATHS]} {
    error "build.tcl: $PATHS"
}
set TCLSH [dict get $PATHS tclsh]
set PREFIX [dict get $PATHS prefix]

set OUT [lindex $argv 0]
if {$OUT eq ""} { set OUT [Rp out machteld.exe] }
set OUT [file normalize $OUT]
set OUTDIR [file dirname $OUT]
if {![catch {file lstat $OUT ignored}]} {
    error "build.tcl: output already exists (an absent candidate is required): $OUT"
}
if {![info exists ::env(MACHTELD_BUILD_ROOT)] ||
        $::env(MACHTELD_BUILD_ROOT) eq ""} {
    error "MACHTELD_BUILD_ROOT is not set by tools/build.ps1"
}
set BUILDROOT [file normalize $::env(MACHTELD_BUILD_ROOT)]
if {![file isdirectory $BUILDROOT]} {
    error "invocation build directory not found: $BUILDROOT"
}
if {![regexp {^\.machteld-build-([0-9a-f]{32})\.exe$} \
        [file tail $OUT] -> outputBuildId] ||
        ![regexp {^\.machteld-build-([0-9a-f]{32})\.work$} \
        [file tail $BUILDROOT] -> rootBuildId] ||
        $outputBuildId ne $rootBuildId ||
        ![string equal -nocase [file dirname $BUILDROOT] $OUTDIR]} {
    error "build.tcl: output and build root are not one same-parent invocation pair"
}
set OBJDIR [file join $BUILDROOT obj]
file mkdir $OUTDIR $OBJDIR

set toolBin [file dirname [file normalize $GCC]]
set ::env(PATH) "[file nativename $toolBin];$::env(PATH)"

set common [::machteld::build::common_flags $PATHS]

# Pinned third-party sources compile with their own flags (buildlib.tcl); the
# warning gate applies to every authored translation unit under src/.
set sqliteObj [file join $OBJDIR sqlite3.o]
puts "cc   sqlite3.c (pinned amalgamation)"
run $GCC {*}$::machteld::build::SQLITE_FLAGS \
    -c [file join [dict get $PATHS sqlite] sqlite3.c] -o $sqliteObj
set yyjsonObj [file join $OBJDIR yyjson.o]
puts "cc   yyjson.c (pinned reader core)"
run $GCC {*}$::machteld::build::YYJSON_FLAGS \
    -c [file join [dict get $PATHS yyjson] yyjson.c] -o $yyjsonObj

set consoleMain [Rp src machteld_main.c]
set guiMain [Rp src machteld_gui_main.c]
set objects {}
foreach source [lsort [glob -directory [Rp src] *.c]] {
    if {$source eq $consoleMain || $source eq $guiMain} continue
    set object [file join $OBJDIR [file rootname [file tail $source]].o]
    puts "cc   [file tail $source]"
    run $GCC {*}$common -c $source -o $object
    lappend objects $object
}
set consoleObj [file join $OBJDIR machteld_main.o]
puts "cc   machteld_main.c"
run $GCC {*}$common -municode -c $consoleMain -o $consoleObj
set guiObj [file join $OBJDIR machteld_gui_main.o]
puts "cc   machteld_gui_main.c"
run $GCC {*}$common -municode -c $guiMain -o $guiObj

# Windows Explorer and installer tooling read VERSIONINFO without starting the
# program. Both host variants derive from the one canonical version macro.
set consoleVersionObj [file join $OBJDIR machteld-console-resource.o]
set guiVersionObj [file join $OBJDIR machteld-gui-resource.o]
puts "rc   machteld-console.rc"
::machteld::build::version_resource $TCLSH $WINDRES $ROOT console \
    [file join $OBJDIR machteld-console.rc] $consoleVersionObj
puts "rc   machteld-gui.rc"
::machteld::build::version_resource $TCLSH $WINDRES $ROOT gui \
    [file join $OBJDIR machteld-gui.rc] $guiVersionObj

# The linker intermediates live in the invocation's work directory, never
# beside the requested output, so no output name can collide with them.
set bare [file join $BUILDROOT machteld-bare.exe]
puts "ld   [file tail $bare]"
::machteld::build::link_host $GCC $STRIP console $consoleObj $consoleVersionObj \
    $objects $sqliteObj $yyjsonObj $PATHS $bare
set bareGui [file join $BUILDROOT machteld-bare-gui.exe]
puts "ld   [file tail $bareGui]"
::machteld::build::link_host $GCC $STRIP gui $guiObj $guiVersionObj \
    $objects $sqliteObj $yyjsonObj $PATHS $bareGui

set generatedManifest [file join $OBJDIR manifest.tcl]
run $TCLSH [Rp tools genmanifest.tcl] [Rp src] $generatedManifest
set staged [file join $OBJDIR prelude.tcl]
::machteld::build::stage_prelude $ROOT $generatedManifest $staged

if {![info exists ::env(MACHTELD_REFERENCE_ROOT)] ||
        $::env(MACHTELD_REFERENCE_ROOT) eq ""} {
    error "MACHTELD_REFERENCE_ROOT is not set by tools/build.ps1"
}
set referenceRoot [file normalize $::env(MACHTELD_REFERENCE_ROOT)]
if {![file isdirectory $referenceRoot]} {
    error "generated reference pack not found: $referenceRoot"
}

run $TCLSH [Rp tools package.tcl] \
    --prefix $PREFIX --prelude $staged --wrapper $bare --out $OUT \
    --licenses [Rp licenses] --apache-license [Rp LICENSE] \
    --reference $referenceRoot \
    --embed-console $bare --embed-gui $bareGui

puts "built [file nativename $OUT] ([file size $OUT] bytes)"
