# sums -- digest every file in a tree, using a pool of copies of itself.
#
#   sums ?dir? ?--alg sha256? ?--width n? ?--seq? ?--time? ?--json?
#   sums --selftest
#
# THE END-TO-END PROOF FOR THE POOL, and the reason it is a shipped tool rather
# than a benchmark script: a wrapped exe spawns ITSELF as its workers. There is
# no tclsh on the box, no worker script on disk, no second artefact to keep in
# step -- `[info nameofexecutable] --worker` is the same file the user ran, with
# the whole palette inside it. That was the riskiest assumption in the plan and
# this is the thing that would notice if it stopped being true.
#
# It is also the first tool that is not a window. `changes` and `tasks` are Tk;
# this one is a console program, so it exercises `wrap --console`, and it prints
# a format `sha256sum -c` would recognise: digest, two spaces, path.
#
# The work suits a pool in shape: a file needs nothing from the director but a
# path and returns 64 bytes, and files vary hugely in size -- the case a fixed
# split handles badly and a pool handles by construction, since a worker that
# draws the 400 MB file is simply still busy when the others come back for more.
#
# IT DOES NOT SUIT ONE IN SIZE, and the numbers say so plainly (docs/parallel.md):
# 1.27x over this project's own tree of 45 KB files, and 0.38x -- a LOSS -- at
# width 1, where the round trip is paid with no concurrency to pay for it. On a
# gigabyte in 272 files it reaches 2.34x for sha256 and 3.51x for md5, and that
# ordering is the finding: sha256 is the fastest of the four sequentially and
# parallelises worst, because this CPU hashes it in hardware and what is left is
# reading, which does not parallelise. Hashing is a bandwidth problem wearing a
# CPU problem's clothes. The tool is honest about it rather than shipping the
# flattering half.
#
# A FILE THAT VANISHES between the walk and its digest stops the run, with the
# worker's own `{MACHTELD HASH ...}` errorcode. Deliberate: a digest list with a
# hole in it that looks complete is worse than an error that says which path.

namespace eval ::sums {
    # The palette is on the GLOBAL namespace path and Tcl does not consult that
    # from inside another namespace. Asked for once, here; then `pmap`, `hash`
    # and `cli` are written bare below -- including inside the worker handler,
    # which is compiled in this namespace because that is where it is written.
    namespace path ::machteld

    variable ALGS {sha256 sha512 sha1 md5}

    # WHERE THIS TOOL LIVES, captured while it is being sourced -- `info script`
    # answers "" once loading is over, so asking at request time would be too
    # late. Shipped inside mt.exe it is a path in that exe's own zipfs; run from
    # a checkout it is a file on disk. Both are paths the same exe can source.
    variable SELF [info script]
}

# The command that starts a copy of this tool as a worker.
#
# ONE SPELLING, since `wrap` was retired. There used to be two: a wrapped
# sums.exe re-entered itself as `sums.exe --worker`, because there the exe WAS
# the tool and its main.tcl was auto-run; a script under machteld.exe had to
# name the script as well. Only the second case is left -- mt.exe is the
# interpreter and the tool is a script it sources, whether that script sits in
# the zipfs or in a checkout. A child of mt.exe mounts the very same zipfs, so
# the zipfs path is as reachable from the worker as it is from here.
#
# What has NOT changed is the property the whole pool design rests on: the
# worker is the same file the director is running. No second artefact to keep in
# step, and no tclsh on the box.
proc ::sums::worker_command {} {
    variable SELF
    set exe [info nameofexecutable]
    if {$SELF eq ""} { return [list $exe sums --worker] }
    if {[string match {//zipfs:*} $SELF]} { return [list $exe $SELF --worker] }
    return [list $exe [file normalize $SELF] --worker]
}

# --- the worker side ---------------------------------------------------------
# Registered inside a proc so nothing is defined in a director that will never
# serve. `worker serve` blocks until the director closes the pipe, which is what
# `pool close` does, so a worker's whole lifetime is decided by its parent -- and
# the job object decides it a second time if the parent dies badly.
proc ::sums::serve {} {
    worker on digest {path {alg sha256}} { hash file $alg $path }
    worker serve
}

# --- the director side -------------------------------------------------------

# Every file under $dir, depth first. Plain Tcl: `glob` and `file` are what a
# stock interpreter already does well, and a verb that only wrapped them would
# be a verb that has to be maintained for nothing (rule 4).
#
# Unreadable directories are SKIPPED, not fatal. A tree of any size on Windows
# contains at least one directory this process may not open, and a tool that
# dies on the first of them cannot be used on the trees worth hashing.
proc ::sums::walk {dir} {
    set out {}
    set pending [list $dir]
    while {[llength $pending]} {
        set d [lindex $pending end]
        set pending [lrange $pending 0 end-1]
        if {[catch {glob -nocomplain -directory $d -types f *} files]} continue
        foreach f $files { lappend out $f }
        if {[catch {glob -nocomplain -directory $d -types d *} subs]} continue
        foreach s $subs {
            # Junctions and symlinks are not followed: a link back up the tree is
            # an infinite walk, and Windows ships several by default.
            if {[catch {file type $s} t] || $t ne "directory"} continue
            lappend pending $s
        }
    }
    return $out
}

# The parallel half. One request per file; the reply is the digest. `pmap`
# rather than `pool` because this is a map: every item is independent, the
# results are wanted in order, and a failure should propagate rather than be
# collected -- and the pool is closed on every path including that one.
proc ::sums::parallel {files alg width} {
    set reqs [lmap p $files {list op digest path $p alg $alg}]
    return [pmap $reqs -width $width -- {*}[worker_command]]
}

# The sequential half, kept because a parallel result nobody compared against a
# sequential one is a number, not a proof.
proc ::sums::sequential {files alg} {
    return [lmap p $files {hash file $alg $p}]
}

proc ::sums::emit {files digests json} {
    if {$json} {
        set rows [lmap p $files d $digests {dict create path $p digest $d}]
        puts [json encode $rows]
        return
    }
    foreach p $files d $digests { puts "$d  $p" }
}

# --- selftest ----------------------------------------------------------------
# Everything here is a claim the tool makes and the suite would otherwise take on
# trust. It runs with no window and no arguments, so the suite drives it the same
# way it drives the two Tk tools.
proc ::sums::selftest {} {
    set fails 0
    proc ck {name ok} {
        if {$ok} { puts "ok   $name" } else { incr ::sums::fails_ ; puts "FAIL $name" }
    }
    set ::sums::fails_ 0

    # A tree with enough files to need every worker, and of different sizes so
    # the run is not a lockstep march that would hide an ordering bug.
    if {[info exists ::env(TEMP)] && [file isdirectory $::env(TEMP)]} {
        set tmp $::env(TEMP)
    } else {
        set tmp [file dirname [info nameofexecutable]]
    }
    set root [file join $tmp _sums_selftest_[pid]]
    catch {file delete -force $root}
    file mkdir [file join $root sub deep]
    set made {}
    for {set i 0} {$i < 24} {incr i} {
        set d [expr {$i % 3 == 0 ? $root : ($i % 3 == 1 ? [file join $root sub]
                                                        : [file join $root sub deep])}]
        set p [file join $d "f$i.bin"]
        set fh [open $p wb]
        puts -nonewline $fh [string repeat "machteld-$i-" [expr {1 + $i * 37}]]
        close $fh
        lappend made $p
    }

    set files [lsort [walk $root]]
    ck "walk finds every file, at every depth" [expr {[llength $files] == 24}]

    # THE CORRECTNESS CLAIM. Not "the pool produced 24 digests" but "it produced
    # the same 24 digests this process computes alone" -- a pool that answers
    # fast and wrong would pass the first and fail this.
    set seq [sequential $files sha256]
    set par [parallel $files sha256 6]
    ck "parallel digests equal sequential ones" [expr {$par eq $seq}]
    ck "results come back in submission order" [expr {
        [lindex $par 0] eq [hash file sha256 [lindex $files 0]]}]

    # Width 1 is the degenerate pool: one worker, still over the protocol. It
    # exists to separate "the pool is broken" from "concurrency is broken".
    ck "a pool of width 1 agrees too" [expr {[parallel $files sha256 1] eq $seq}]
    ck "a second algorithm works"     [expr {
        [parallel [lrange $files 0 3] sha512 4] eq [sequential [lrange $files 0 3] sha512]}]
    ck "an empty file list needs no pool" [expr {[parallel {} sha256 4] eq ""}]

    # THE ERROR CONTRACT, END TO END. `hash file` on a path that is not there
    # raises inside a worker process; the code has to arrive here intact, or
    # every failure in a pooled tool degrades to prose.
    set code ""
    if {[catch {parallel [list [file join $root nosuchfile.bin]] sha256 2} m opts]} {
        set code [dict get $opts -errorcode]
    }
    ck "a worker's failure arrives as an error"        [expr {$code ne ""}]
    ck "and keeps the domain it was raised in"         [expr {
        [lrange $code 0 1] eq {MACHTELD HASH}}]

    # NO ORPHANS, which is the whole reason this is a machteld pool and not
    # `open |cmd r+`. pmap closes on every path, including the raising one just
    # taken, and a closed pool leaves nothing behind for `scope` to reap.
    ck "no children survive the pools above" [expr {[llength [child list]] == 0}]

    catch {file delete -force $root}
    if {$::sums::fails_} {
        puts "FAILURES: $::sums::fails_"
        exit 1
    }
    puts "ALL PASS: 0 failure(s)"
    exit 0
}

# --- arguments ---------------------------------------------------------------
# Declared once, including --worker: the flag is internal but it is not secret,
# and a tool whose --help omits a mode it has is a tool that lies about itself.
set SPEC {
    dir        {type string default .      help "directory to hash, recursively"}
    --alg      {type string default sha256 choices {sha256 sha512 sha1 md5}
                help "digest algorithm"}
    --width    {type int    default 0 min 0 max 64
                help "worker processes; 0 means one per processor"}
    --seq      {type flag   help "hash in this process instead of a pool"}
    --time     {type flag   help "report wall clock for both, and the speedup"}
    --json     {type flag   help "emit a JSON array instead of digest-space-space-path"}
    --worker   {type flag   help "internal: serve as a pool worker, one JSON line in and out"}
    --selftest {type flag   help "run the tool's own tests and exit"}
}
if {[catch {::machteld::cli parse $argv $SPEC} opt]} {
    puts stderr "sums: $opt"
    puts stderr ""
    puts stderr [::machteld::cli usage $SPEC sums]
    exit 2
}
if {[dict get $opt help]} { puts [::machteld::cli usage $SPEC sums] ; exit 0 }

# Checked before anything else: a worker must not walk a tree, print a banner, or
# write ONE byte to stdout that is not a reply.
if {[dict get $opt worker]}   { ::sums::serve ; exit 0 }
if {[dict get $opt selftest]} { ::sums::selftest }

set dir [dict get $opt dir]
if {![file isdirectory $dir]} {
    puts stderr "sums: not a directory: $dir"
    exit 2
}
set alg   [dict get $opt alg]
set width [dict get $opt width]
if {$width == 0} {
    set width 8
    if {[info exists ::env(NUMBER_OF_PROCESSORS)]
        && [string is integer -strict $::env(NUMBER_OF_PROCESSORS)]} {
        set width [expr {min(64, max(1, $::env(NUMBER_OF_PROCESSORS)))}]
    }
}

set files [::sums::walk $dir]
if {![llength $files]} { exit 0 }

if {[dict get $opt time]} {
    # A COLD PASS FIRST, AND ITS TIME IS NOT THE SEQUENTIAL TIME.
    #
    # The first draft ran sequential first and called that conservative, on the
    # reasoning that the pool must not inherit a warm file cache. That is exactly
    # backwards, and the tree this tool lives in proved it: sequential 73.6 s,
    # pool 1.9 s, a 38x "speedup" on twelve logical cores. Whatever that measured
    # it was not parallelism -- no arrangement of 12 cores makes 12 of anything go
    # 38 times faster. The first pass pays for every cold read, and on Windows for
    # the antivirus filter's first look at each file; the second pass reads from
    # the OS cache. Running first is a PENALTY, not an advantage, so "first" was
    # handing the win to whichever half went second.
    #
    # So: one discarded pass to warm the cache, then both halves timed warm. The
    # cold number is worth printing on its own -- for a tree read once it is the
    # number a user actually experiences -- but it belongs on its own line and
    # not in a ratio, because it measures the disk and not the design.
    set t0 [clock microseconds]
    ::sums::sequential $files $alg
    set t1 [clock microseconds]
    set seq [::sums::sequential $files $alg]
    set t2 [clock microseconds]
    set par [::sums::parallel $files $alg $width]
    set t3 [clock microseconds]
    set ms0 [expr {($t1 - $t0) / 1000.0}]
    set ms1 [expr {($t2 - $t1) / 1000.0}]
    set ms2 [expr {($t3 - $t2) / 1000.0}]
    puts stderr [format "%d files, %s, width %d" [llength $files] $alg $width]
    puts stderr [format "first pass  %9.1f ms   (cold: disk and filters, discarded)" $ms0]
    puts stderr [format "sequential  %9.1f ms" $ms1]
    puts stderr [format "pool        %9.1f ms   %.2fx" $ms2 [expr {$ms2 > 0 ? $ms1 / $ms2 : 0}]]
    if {$par ne $seq} {
        puts stderr "sums: the pool disagreed with sequential -- results NOT written"
        exit 1
    }
    ::sums::emit $files $par [dict get $opt json]
    exit 0
}

if {[dict get $opt seq]} {
    ::sums::emit $files [::sums::sequential $files $alg] [dict get $opt json]
} else {
    ::sums::emit $files [::sums::parallel $files $alg $width] [dict get $opt json]
}
