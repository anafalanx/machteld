# Build the self-contained Windows hosts from the repository-local dependency
# prefix created by tools/bootstrap.ps1.
#
# Prefer tools/build.ps1, which verifies/bootstrap the cache and owns a unique
# work directory plus an absent output candidate. Direct callers must provide
# MACHTELD_BUILD_ROOT and MACHTELD_REFERENCE_ROOT with the same guarantees.

proc repository_root {} {
    set script [file normalize [info script]]
    return [file dirname [file dirname $script]]
}
set ROOT [repository_root]
proc Rp {args} { return [file join $::ROOT {*}$args] }

set CACHE [expr {[info exists ::env(MACHTELD_DEPS_ROOT)] &&
                 $::env(MACHTELD_DEPS_ROOT) ne ""
                 ? [file normalize $::env(MACHTELD_DEPS_ROOT)]
                 : [Rp .cache deps]}]
set PREFIX [file join $CACHE prefix]
set SQLITE [file join $CACHE sqlite]
set YYJSON [file join $CACHE yyjson]
set GCC [expr {[info exists ::env(MACHTELD_GCC)] ? $::env(MACHTELD_GCC) : ""}]
set STRIP [expr {[info exists ::env(MACHTELD_STRIP)] ? $::env(MACHTELD_STRIP) : ""}]
set WINDRES [expr {[info exists ::env(MACHTELD_WINDRES)] ? $::env(MACHTELD_WINDRES) : ""}]
if {$GCC eq ""} { error "build.tcl: MACHTELD_GCC is not set; use tools/build.ps1" }
if {$WINDRES eq ""} { error "build.tcl: MACHTELD_WINDRES is not set; use tools/build.ps1" }

proc first_existing {label candidates} {
    foreach path $candidates { if {[file exists $path]} { return $path } }
    error "build.tcl: missing $label; tried [join $candidates {, }]"
}

set INCLUDE [file join $PREFIX include]
set TCLSH [first_existing "static tclsh" [list \
    [file join $PREFIX bin tclsh90s.exe] [file join $PREFIX bin tclsh90.exe]]]
set TCLLIB [first_existing "static Tcl library" [list \
    [file join $PREFIX lib libtcl90.a] [file join $PREFIX lib libtcl9.0.a]]]
set TKLIB [first_existing "static Tk library" [list \
    [file join $PREFIX lib libtcl9tk90.a] [file join $PREFIX lib libtk90.a] \
    [file join $PREFIX lib libtk9.0.a]]]
set TCLSTUB [first_existing "Tcl stub library" [list \
    [file join $PREFIX lib libtclstub.a] [file join $PREFIX lib libtclstub90.a]]]
foreach {label path} [list gcc $GCC windres $WINDRES tcl.h [file join $INCLUDE tcl.h] \
        sqlite3.c [file join $SQLITE sqlite3.c] sqlite3.h [file join $SQLITE sqlite3.h] \
        yyjson.c [file join $YYJSON yyjson.c]] {
    if {![file exists $path]} { error "build.tcl: missing $label: $path" }
}

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

proc run {args} {
    puts [join [lmap arg $args {file tail $arg}] " "]
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} message options]} {
        if {[dict exists $options -errorcode] &&
            [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
            error "command failed (exit [lindex [dict get $options -errorcode] 2])"
        }
        return -options $options $message
    }
}

set warnings {-Wall -Wextra -Wpedantic -Wformat=2 -Wundef}
if {[info exists ::env(MACHTELD_WERROR)] && $::env(MACHTELD_WERROR) eq "1"} {
    lappend warnings -Werror
}
set defines {
    -DUNICODE -D_UNICODE -DSTATIC_BUILD=1
    -DMACHTELD_STATIC_SQLITE -DMACHTELD_PROC -DMACHTELD_JSON
    -DMACHTELD_PS -DMACHTELD_HASH -DMACHTELD_DIRS -DMACHTELD_HTTP
}
set common [list -std=c23 -O2 {*}$warnings {*}$defines \
    -ffunction-sections -fdata-sections -I$INCLUDE -I$SQLITE -I$YYJSON]

# SQLite is third-party generated source. It is pinned and compiled separately;
# the warning gate applies to every authored C translation unit under src/.
set sqliteObj [file join $OBJDIR sqlite3.o]
puts "cc   sqlite3.c (pinned amalgamation)"
run $GCC -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION \
    -c [file join $SQLITE sqlite3.c] -o $sqliteObj

# yyjson is third-party pinned source: the palette json organ's reader
# core (plan-machteld-015). Same separation from the warning gate.
set yyjsonObj [file join $OBJDIR yyjson.o]
puts "cc   yyjson.c (pinned 0.12.0)"
run $GCC -O2 -ffunction-sections -fdata-sections -c [file join $YYJSON yyjson.c] -o $yyjsonObj

set consoleMain [Rp src machteld_main.c]
set guiMain [Rp src machteld_gui_main.c]
set objects {}
foreach source [lsort [glob -directory [Rp src] *.c]] {
    if {$source eq $consoleMain || $source eq $guiMain} continue
    set stem [file rootname [file tail $source]]
    set object [file join $OBJDIR ${stem}.o]
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
# program. Generate both host variants from the one canonical version macro.
set versionGenerator [Rp tools generate-version-resource.tcl]
set consoleRc [file join $OBJDIR machteld-console.rc]
set guiRc [file join $OBJDIR machteld-gui.rc]
set consoleVersionObj [file join $OBJDIR machteld-console-resource.o]
set guiVersionObj [file join $OBJDIR machteld-gui-resource.o]
run $TCLSH $versionGenerator [Rp src machteld.h] console $consoleRc
run $TCLSH $versionGenerator [Rp src machteld.h] gui $guiRc
puts "windres machteld-console.rc"
run $WINDRES --codepage=65001 -O coff -i $consoleRc -o $consoleVersionObj
puts "windres machteld-gui.rc"
run $WINDRES --codepage=65001 -O coff -i $guiRc -o $guiVersionObj

set syslibs {
    -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
    -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
    -loleaut32 -lwinspool -lpsapi -lbcrypt -lwinhttp
}
set bare [file join $BUILDROOT machteld-bare.exe]
puts "ld   [file tail $bare]"
run $GCC -municode -static-libgcc -Wl,--gc-sections \
    $consoleObj $consoleVersionObj {*}$objects $sqliteObj $yyjsonObj $TKLIB $TCLLIB $TCLSTUB \
    {*}$syslibs -o $bare
if {$STRIP ne "" && [file exists $STRIP]} { run $STRIP $bare }

set bareGui [file join $BUILDROOT machteld-bare-gui.exe]
puts "ld   [file tail $bareGui]"
run $GCC -municode -mwindows -static-libgcc -Wl,--gc-sections \
    $guiObj $guiVersionObj {*}$objects $sqliteObj $yyjsonObj $TKLIB $TCLLIB $TCLSTUB \
    {*}$syslibs -o $bareGui
if {$STRIP ne "" && [file exists $STRIP]} { run $STRIP $bareGui }

set generatedManifest [file join $OBJDIR manifest.tcl]
run $TCLSH [Rp tools genmanifest.tcl] [Rp src] $generatedManifest

set staged [file join $OBJDIR prelude.tcl]
set output [open $staged w]
fconfigure $output -translation lf
foreach part [list [Rp tcl machteld.tcl] [Rp tcl docs.tcl] [Rp tcl cli.tcl] [Rp tcl log.tcl] \
        [Rp tcl worker.tcl] [Rp tcl pool.tcl] [Rp tcl pmap.tcl] $generatedManifest] {
    set input [open $part r]
    fconfigure $input -translation lf
    puts $output [read $input]
    close $input
}
close $output

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
