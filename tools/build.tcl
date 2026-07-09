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

# Payload root: the shared z-workspace r/ tree.
set R ""
foreach cand {C:/z/r C:/zmal/r} {
    if {[file isdirectory [file join $cand tcltk]]} { set R $cand; break }
}
if {$R eq ""} { error "build.tcl: z-workspace payloads not found (C:/z/r, C:/zmal/r)" }

set TCLTK     [file join $R tcltk 9.0.3]
set gcc       [file join $R msys2 ucrt64 bin gcc.exe]
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
    -loleaut32 -lwinspool
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

puts "cc   machteld_appinit.c  (shared native-lib + prelude registration, c23)"
run $gcc -std=c23 -O2 -DSTATIC_BUILD=1 -DMACHTELD_STATIC_SQLITE -DMACHTELD_PROC \
    -c [Rp src machteld_appinit.c] -o [Rp build machteld_appinit.o] -I$inc

puts "cc   machteld_main.c  (console host, c23)"
run $gcc -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
    -ffunction-sections -fdata-sections \
    -c [Rp src machteld_main.c] -o [Rp build machteld_main.o] -I$inc

puts "ld   machteld-bare.exe  (console subsystem)"
set bare [Rp build machteld-bare.exe]
run $gcc -municode -static-libgcc -Wl,--gc-sections \
    [Rp build machteld_main.o] [Rp build machteld_appinit.o] [Rp build store.o] [Rp build sqlite3.o] \
    [Rp build winjob_cmdline.o] [Rp build winjob_job.o] [Rp build winjob_launch.o] [Rp build proc.o] \
    [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] [file join $libd libtclstub.a] \
    {*}$syslibs -o $bare
catch {run $strip $bare}

puts "pkg  append machteld zipfs"
run $tclshs [Rp tools package.tcl] \
    --tcltk $TCLTK --prelude [Rp tcl machteld.tcl] --wrapper $bare --out $out

puts "built [file nativename $out] ([file size $out] bytes)"
