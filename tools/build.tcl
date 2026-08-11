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

puts "cc   journal.c  (the front door's record, over SQLite, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src journal.c] -o [Rp build journal.o] -I$inc -I$sqliteSrc

puts "cc   hash.c  (digests + HMAC + CSPRNG over CNG, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -c [Rp src hash.c] -o [Rp build hash.o] -I$inc

# -Wall -Wextra ON THIS LINE AND NOT THE OTHERS, which is a deliberate asymmetry.
# dirs.c was reviewed as "zero warnings under -Wall -Wextra" and that was a
# MANUAL result the build did not reproduce, so the claim could rot without
# anyone noticing -- the same shape as a gate that cannot fail. Measured before
# turning it on here: dirs.c 0, and 1 warning each in json.c and proc.c, which
# is why it is not switched on globally in the same change that has not read
# them.
puts "cc   dirs.c  (directory walk, c23)"
run $gcc -std=c23 -O2 -Wall -Wextra -DSTATIC_BUILD=1 -c [Rp src dirs.c] -o [Rp build dirs.o] -I$inc

puts "cc   machteld_appinit.c  (shared native-lib + prelude registration, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -DMACHTELD_STATIC_SQLITE -DMACHTELD_PROC -DMACHTELD_JSON -DMACHTELD_PS -DMACHTELD_HASH -DMACHTELD_JOURNAL -DMACHTELD_DIRS \
    -c [Rp src machteld_appinit.c] -o [Rp build machteld_appinit.o] -I$inc

puts "cc   machteld_main.c  (console host, c23)"
run $gcc -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
    -ffunction-sections -fdata-sections \
    -c [Rp src machteld_main.c] -o [Rp build machteld_main.o] -I$inc

puts "ld   machteld-bare.exe  (console subsystem)"
set bare [Rp build machteld-bare.exe]
run $gcc -municode -static-libgcc -Wl,--gc-sections \
    [Rp build machteld_main.o] [Rp build machteld_appinit.o] [Rp build store.o] [Rp build sqlite3.o] [Rp build json.o] [Rp build ps.o] [Rp build hash.o] [Rp build journal.o] [Rp build dirs.o] \
    [Rp build winjob_cmdline.o] [Rp build winjob_job.o] [Rp build winjob_launch.o] [Rp build proc.o] \
    [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] [file join $libd libtclstub.a] \
    {*}$syslibs -o $bare
catch {run $strip $bare}

# GUI-subsystem sibling bare (WinMain, -mwindows): same objects, different entry,
# so a windowed tool `wrap` stamps shows no console window. Shares
# machteld_appinit.o, so a C library added there lands in both.
#
# The subsystem is COMPILED IN, not a PE byte-flip: a console host running in a
# GUI subsystem has no valid standard channels and `puts stdout` throws "can not
# find channel named stdout". Two hosts, the way tclkit has always done it
# (`tclkit` vs `tclkitsh`).
puts "cc   machteld_gui_main.c  (GUI host, c23)"
run $gcc -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
    -ffunction-sections -fdata-sections \
    -c [Rp src machteld_gui_main.c] -o [Rp build machteld_gui_main.o] -I$inc

puts "ld   machteld-bare-gui.exe  (GUI subsystem)"
set baregui [Rp build machteld-bare-gui.exe]
run $gcc -municode -mwindows -static-libgcc -Wl,--gc-sections \
    [Rp build machteld_gui_main.o] [Rp build machteld_appinit.o] [Rp build store.o] [Rp build sqlite3.o] [Rp build json.o] [Rp build ps.o] [Rp build hash.o] [Rp build journal.o] [Rp build dirs.o] \
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
# `ledger.tcl` BEFORE `front.tcl`, not after: front.tcl ends with the dispatcher
# call that takes over argv, so anything sourced later would be defined after the
# front door has already run. Order is otherwise irrelevant -- Tcl resolves
# procs at call time -- and this one is not.
foreach part [list [Rp tcl machteld.tcl] [Rp tcl cli.tcl] [Rp tcl log.tcl] [Rp tcl worker.tcl] [Rp tcl pool.tcl] [Rp tcl pmap.tcl] $genman [Rp tcl ledger.tcl] [Rp tcl mirror.tcl] [Rp tcl front.tcl]] {
    set fi [open $part r]
    fconfigure $fi -translation lf
    puts $fo [read $fi]
    close $fi
}
close $fo

puts "pkg  append machteld zipfs"
run $tclshs [Rp tools package.tcl] \
    --tcltk $TCLTK --prelude $staged --wrapper $bare --out $out \
    --docs [Rp docs] --embed-console $bare --embed-gui $baregui

puts "built [file nativename $out] ([file size $out] bytes)"

# NOTHING IS STAMPED HERE. The build used to end by running the exe it had just
# produced five times, to `wrap` five tool directories into five standalone exes.
# Those five programs left the project on 2026-08-10 -- a front door does not
# host applications -- so nothing here needs stamping. `wrap` itself stayed,
# because a VERB is not an application: it is a capability this exe offers to
# whoever wants an exe of their own, and the suite proves it by stamping a
# fixture rather than by shipping five.
