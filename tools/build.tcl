# tools/build.tcl -- build the machteld console host.
#
# Compiles the C host (src/machteld_main.c + src/store.c), statically links
# Tcl/Tk 9 and the SQLite amalgamation, and appends the zipfs (machteld.tcl +
# tcl_library/ + tk_library/) -> one self-contained CONSOLE exe. Builds against
# the SHARED z-workspace payloads (els-style: machteld carries no private
# toolchain), and runs the packaging step under the static tclsh90s so gcc sees
# native Windows paths (no MSYS translation).
#
#   tclsh90s.exe tools/build.tcl [out.exe]

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    # tools/build.tcl -> machteld root is two dirs up.
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
proc Rp {args} { return [file join $::ROOT {*}$args] }

# Payload root: the shared z-workspace .z/r tree.
set R ""
set candidates {}
if {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne ""} {
    lappend candidates [file join $::env(Z_HOME) r]
}
lappend candidates [file join [file dirname $ROOT] .z r]
foreach cand $candidates {
    if {[file isdirectory [file join $cand tcltk]]} { set R $cand; break }
}
if {$R eq ""} { error "build.tcl: z-workspace payloads not found under Z_HOME/r" }

# The pinned Tcl/Tk payload. Chosen deliberately, not by inertia (docs/direction.md).
# Coupled to the `package ifneeded Tk` line in tcl/machteld.tcl: the version claimed
# there must match what is linked in, or `package require Tk` fails the version check.
set TCLTK     [file join $R tcltk 9.0.4]
set gcc       [file join $R msys2 ucrt64 bin gcc.exe]

# gcc needs its own bin directory on PATH to find cc1 and its DLLs; invoked by
# absolute path from a clean shell it exits 1 with no output at all. The old
# C:\z environment arranged this ambiently; after the .z migration, arrange it
# here so the build works from any shell.
set ::env(PATH) "[file nativename [file join $R msys2 ucrt64 bin]];$::env(PATH)"
set strip     [file join $R msys2 ucrt64 bin strip.exe]
set tclshs    [file join $TCLTK tcl9s bin tclsh90s.exe]
set inc       [file join $TCLTK tcl9 include]
set libd      [file join $TCLTK tcl9s lib]
set sqliteSrc [file join $R sqlite 3.51.0]

foreach {label p} [list gcc $gcc tclshs $tclshs inc $inc libd $libd \
                        sqlite [file join $sqliteSrc sqlite3.c]] {
    if {![file exists $p]} { error "build.tcl: missing $label: $p" }
}

set out [lindex $argv 0]
if {$out eq ""} { set out [Rp build machteld.exe] }
file mkdir [Rp build]

proc run {args} {
    puts [join [lmap a $args {file tail $a}] " "]
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            error "command failed (exit [lindex [dict get $opts -errorcode] 2])"
        }
        return -options $opts $err
    }
}

# System libraries Tk's static build pulls in (verbatim from els/sturm).
set syslibs {
    -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
    -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
    -loleaut32 -lwinspool -lpsapi -lbcrypt
}

# SQLite: statically compile the amalgamation (shared payload) into the host.
# The ~9 MB object is cached -- it never changes between builds.
set sqliteObj [Rp build sqlite3.o]
if {![file exists $sqliteObj] ||
    [file mtime [file join $sqliteSrc sqlite3.c]] > [file mtime $sqliteObj]} {
    puts "cc   sqlite3.c  (amalgamation; slow, cached)"
    run $gcc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION \
        -c [file join $sqliteSrc sqlite3.c] -o $sqliteObj
}

puts "cc   store.c  (bridge, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 \
    -c [Rp src store.c] -o [Rp build store.o] -I$inc -I$sqliteSrc

# winjob process-supervision substrate + the ::machteld::run bridge.
puts "cc   winjob_cmdline.c  (c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src winjob_cmdline.c] -o [Rp build winjob_cmdline.o]
puts "cc   winjob_job.c  (c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src winjob_job.c] -o [Rp build winjob_job.o]
puts "cc   winjob_launch.c  (c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src winjob_launch.c] -o [Rp build winjob_launch.o]
puts "cc   proc.c  (bridge, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src proc.c] -o [Rp build proc.o] -I$inc

puts "cc   json.c  (hand-rolled into Tcl_Obj, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src json.c] -o [Rp build json.o] -I$inc

puts "cc   ps.c  (machine-wide process view, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src ps.c] -o [Rp build ps.o] -I$inc

puts "cc   hash.c  (digests + HMAC + CSPRNG over CNG, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src hash.c] -o [Rp build hash.o] -I$inc

puts "cc   machteld_appinit.c  (shared native-lib + prelude registration, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -DMACHTELD_STATIC_SQLITE -DMACHTELD_PROC -DMACHTELD_JSON -DMACHTELD_PS -DMACHTELD_HASH \
    -c [Rp src machteld_appinit.c] -o [Rp build machteld_appinit.o] -I$inc

puts "cc   machteld_main.c  (console host, c23)"
run $gcc -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
    -ffunction-sections -fdata-sections \
    -c [Rp src machteld_main.c] -o [Rp build machteld_main.o] -I$inc

puts "ld   machteld-bare.exe  (console subsystem)"
set bare [Rp build machteld-bare.exe]
run $gcc -municode -static-libgcc -Wl,--gc-sections \
    [Rp build machteld_main.o] [Rp build machteld_appinit.o] [Rp build store.o] [Rp build sqlite3.o] [Rp build json.o] [Rp build ps.o] [Rp build hash.o] \
    [Rp build winjob_cmdline.o] [Rp build winjob_job.o] [Rp build winjob_launch.o] [Rp build proc.o] \
    [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] [file join $libd libtclstub.a] \
    {*}$syslibs -o $bare
catch {run $strip $bare}

# GUI-subsystem sibling bare (WinMain, -mwindows): same objects, different entry,
# so windowed tools packaged on it show no console window. Shares machteld_appinit.o.
puts "cc   machteld_gui_main.c  (GUI host, c23)"
run $gcc -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
    -ffunction-sections -fdata-sections \
    -c [Rp src machteld_gui_main.c] -o [Rp build machteld_gui_main.o] -I$inc

puts "ld   machteld-bare-gui.exe  (GUI subsystem)"
set baregui [Rp build machteld-bare-gui.exe]
run $gcc -municode -mwindows -static-libgcc -Wl,--gc-sections \
    [Rp build machteld_gui_main.o] [Rp build machteld_appinit.o] [Rp build store.o] [Rp build sqlite3.o] [Rp build json.o] [Rp build ps.o] [Rp build hash.o] \
    [Rp build winjob_cmdline.o] [Rp build winjob_job.o] [Rp build winjob_launch.o] [Rp build proc.o] \
    [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] [file join $libd libtclstub.a] \
    {*}$syslibs -o $baregui
catch {run $strip $baregui}

# The manifest is DERIVED from the C, then appended to the prelude, so the exe
# ships a self-description that cannot disagree with the code it describes
# (creed 4). Generating into build/ rather than tcl/ keeps a generated file out
# of the hand-edited source tree; the staged prelude is what gets packaged.
puts "gen  manifest  (from src/*.c)"
set genman [Rp build manifest.tcl]
run $tclshs [Rp tools genmanifest.tcl] [Rp src] $genman

set staged [Rp build prelude.tcl]
set fo [open $staged w]
fconfigure $fo -translation lf
foreach part [list [Rp tcl machteld.tcl] [Rp tcl cli.tcl] [Rp tcl log.tcl] [Rp tcl worker.tcl] [Rp tcl pool.tcl] [Rp tcl pmap.tcl] $genman] {
    set fi [open $part r]
    fconfigure $fi -translation lf
    puts $fo [read $fi]
    close $fi
}
close $fo

puts "pkg  append machteld zipfs"
run $tclshs [Rp tools package.tcl] \
    --tcltk $TCLTK --prelude $staged --wrapper $bare --out $out \
    --embed-console $bare --embed-gui $baregui --docs [Rp docs]

puts "built [file nativename $out] ([file size $out] bytes)"

# The tools machteld ships are built by machteld, with the exe just produced --
# which is also the standing proof that `wrap` works on the artefact we are
# about to release, not on the one from last time.
foreach {tooldir toolexe subsystem} [list \
        [Rp tool changes] [Rp build changes.exe] --gui \
        [Rp tool tasks]   [Rp build tasks.exe]   --gui] {
    if {![file isdirectory $tooldir]} continue
    set script [Rp build .wrap.tcl]
    set fh [open $script w]
    puts $fh [list ::machteld::wrap $tooldir -o $toolexe $subsystem]
    puts $fh "exit 0"
    close $fh
    run $out $script
    file delete $script
    puts "built [file nativename $toolexe] ([file size $toolexe] bytes)"
}
