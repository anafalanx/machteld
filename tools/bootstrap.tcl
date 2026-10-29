package require machteld 0.21

# tools/bootstrap.tcl -- the dependency cache the build stands on: the pinned
# Tcl/Tk 9.0.4, SQLite and yyjson sources, fetched and checked by SHA-256; Tcl
# patched with the exact upstream correction the lock names; static Tcl/Tk
# built with the hash-pinned MSYS2 toolchain; SQLite and yyjson staged. An
# artifact manifest hashes everything the build later reads, and a state file
# names the inputs it was made from, so a current cache is reused and a stale
# or damaged one is rebuilt from nothing.
#
#     machteld.exe tools/bootstrap.tcl ?--cache DIR? ?--msys DIR? ?--jobs N?
#         ?--verify-only? ?--sources-only?
#
# --verify-only checks a current cache and changes nothing; --sources-only
# stops before the toolchain is needed: the archives fetched and checked, Tcl
# patched, SQLite and yyjson staged. The Tcl port (2026-10-28) of
# tools/bootstrap.ps1 and tools/bootstrap-deps.sh. Upstream's configure is a
# shell script, so its steps run in MSYS2's bash; everything around them is Tcl.

namespace eval ::boot {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable script [file normalize [info script]]
    # Rename attempts, 500 ms apart: 20 s outlasts the virus scanner's hold.
    variable renameAttempts 40
}

proc ::boot::fail {message} {
    return -code error -errorcode {BOOTSTRAP fail} "bootstrap: $message"
}

proc ::boot::say {line} {
    puts $line
    flush stdout
}

proc ::boot::readText {path} {
    set channel [open $path rb]
    try {
        return [encoding convertfrom utf-8 [read $channel]]
    } finally {
        close $channel
    }
}

proc ::boot::writeText {path text} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel [encoding convertto utf-8 $text]
    close $channel
}

# Renames, waiting out the virus scanner's hold on what was just written.
proc ::boot::renameWaiting {from to} {
    variable renameAttempts
    for {set attempt 1} {1} {incr attempt} {
        if {[catch {file rename -force $from $to} problem] == 0} {
            return
        }
        if {$attempt >= $renameAttempts} {
            fail "[file nativename $from] could not be renamed to [file tail $to]: $problem"
        }
        after 500
    }
}

proc ::boot::assertUnderCache {path} {
    variable cache
    set resolved [file normalize $path]
    if {![string match -nocase "[string trimright $cache /]/*" $resolved]} {
        fail "refusing path outside dependency cache: [file nativename $resolved]"
    }
}

proc ::boot::assertHash {path expected label} {
    if {![file isfile $path]} {
        fail "missing $label: [file nativename $path]"
    }
    set actual [hash file sha256 $path]
    if {$actual ne [string tolower $expected]} {
        fail "$label SHA-256 mismatch: expected $expected, got $actual ([file nativename $path])"
    }
}

# Applies a unified diff whose every context and removed line must match the
# target exactly, hunk by hunk in order; anything else fails, so only the
# pinned patch can apply. Both are read as LF text and written back as LF.
proc ::boot::applyPinnedUnifiedPatch {patchPath targetPath expectedTarget} {
    set patchLines [split [string map [list \r\n \n] [readText $patchPath]] \n]
    set sourceLines [split [string map [list \r\n \n] [readText $targetPath]] \n]
    if {"--- a/$expectedTarget" ni $patchLines || "+++ b/$expectedTarget" ni $patchLines} {
        fail "patch headers do not name the locked target: $expectedTarget"
    }
    set result {}
    set sourceIndex 0
    set patchIndex 0
    set hunks 0
    set patchCount [llength $patchLines]
    set sourceCount [llength $sourceLines]
    while {$patchIndex < $patchCount} {
        if {![regexp {^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@} [lindex $patchLines $patchIndex] -> oldStart oldCount newStart newCount]} {
            incr patchIndex
            continue
        }
        incr hunks
        set oldExpected [expr {$oldCount eq "" ? 1 : $oldCount}]
        set newExpected [expr {$newCount eq "" ? 1 : $newCount}]
        set hunkSourceIndex [expr {$oldStart - 1}]
        if {$hunkSourceIndex < $sourceIndex || $hunkSourceIndex > $sourceCount} {
            fail "patch hunk has invalid source position: [lindex $patchLines $patchIndex]"
        }
        while {$sourceIndex < $hunkSourceIndex} {
            lappend result [lindex $sourceLines $sourceIndex]
            incr sourceIndex
        }
        set oldSeen 0
        set newSeen 0
        incr patchIndex
        while {$patchIndex < $patchCount && ![string match "@@ *" [lindex $patchLines $patchIndex]]} {
            set line [lindex $patchLines $patchIndex]
            set body [string range $line 1 end]
            switch -glob -- $line {
                " *" {
                    if {$sourceIndex >= $sourceCount || [lindex $sourceLines $sourceIndex] ne $body} {
                        fail "patch context mismatch at source line [expr {$sourceIndex + 1}]"
                    }
                    lappend result $body
                    incr sourceIndex
                    incr oldSeen
                    incr newSeen
                }
                "-*" {
                    if {$sourceIndex >= $sourceCount || [lindex $sourceLines $sourceIndex] ne $body} {
                        fail "patch removal mismatch at source line [expr {$sourceIndex + 1}]"
                    }
                    incr sourceIndex
                    incr oldSeen
                }
                "+*" {
                    lappend result $body
                    incr newSeen
                }
                "\\\\ No newline at end of file" {
                    # Every locked patch and target ends with LF; the marker is
                    # accepted only so malformed input fails by hash.
                }
                "" {
                    break
                }
                default {
                    fail "invalid unified patch line: $line"
                }
            }
            incr patchIndex
        }
        if {$oldSeen != $oldExpected || $newSeen != $newExpected} {
            fail "patch hunk count mismatch: expected -$oldExpected +$newExpected, got -$oldSeen +$newSeen"
        }
    }
    if {$hunks == 0} {
        fail "patch contains no unified-diff hunks"
    }
    while {$sourceIndex < $sourceCount} {
        lappend result [lindex $sourceLines $sourceIndex]
        incr sourceIndex
    }
    writeText $targetPath [join $result \n]
}

proc ::boot::cacheRelative {path} {
    variable cache
    set resolved [file normalize $path]
    assertUnderCache $resolved
    string range $resolved [string length [string trimright $cache /]/] end
}

proc ::boot::filesBelow {dir} {
    set found {}
    foreach path [glob -nocomplain -directory $dir -types {f hidden} *] {
        lappend found $path
    }
    foreach path [glob -nocomplain -directory $dir -types f *] {
        lappend found $path
    }
    foreach sub [concat [glob -nocomplain -directory $dir -types d *] [glob -nocomplain -directory $dir -types {d hidden} *]] {
        lappend found {*}[filesBelow $sub]
    }
    lsort -unique $found
}

# Every file in the compiler header and packaged script-library trees, and the
# exact static binaries, libraries and SQLite amalgamation the build reads.
proc ::boot::artifactManifest {} {
    variable cache
    variable prefix
    set relatives {}
    foreach tree [list [file join $prefix include] [file join $prefix lib tcl9] [file join $prefix lib tcl9.0] \
            [file join $prefix lib tk9.0] [file join $cache yyjson]] {
        if {![file isdirectory $tree]} {
            fail "dependency cache is missing artifact tree: [file nativename $tree]"
        }
        set files [filesBelow $tree]
        if {[llength $files] == 0} {
            fail "dependency artifact tree is empty: [file nativename $tree]"
        }
        foreach file $files {
            lappend relatives [cacheRelative $file]
        }
    }
    foreach file [list [file join $prefix bin tclsh90s.exe] [file join $prefix bin wish90s.exe] \
            [file join $prefix lib libtcl90.a] [file join $prefix lib libtcl9tk90.a] [file join $prefix lib libtclstub.a] \
            [file join $cache sqlite sqlite3.c] [file join $cache sqlite sqlite3.h]] {
        if {![file isfile $file]} {
            fail "dependency cache is missing artifact: [file nativename $file]"
        }
        lappend relatives [cacheRelative $file]
    }
    set lines [list "# machteld dependency artifacts v1"]
    set previous ""
    foreach relative [lsort $relatives] {
        if {[regexp {[\r\n]} $relative]} {
            fail "dependency artifact path contains a newline: $relative"
        }
        if {$relative eq $previous} {
            fail "duplicate dependency artifact path: $relative"
        }
        lappend lines "[hash file sha256 [file join $cache {*}[split $relative /]]]  $relative"
        set previous $relative
    }
    return "[join $lines \n]\n"
}

proc ::boot::writeArtifactManifest {} {
    variable cache
    variable manifestPath
    set candidate [file join $cache .artifacts-[binary encode hex [hash random 16]].tmp]
    try {
        writeText $candidate [artifactManifest]
        renameWaiting $candidate $manifestPath
    } finally {
        file delete $candidate
    }
}

proc ::boot::assertArtifactManifest {} {
    variable manifestPath
    if {![file isfile $manifestPath]} {
        fail "dependency artifact manifest is missing: [file nativename $manifestPath]"
    }
    if {[string map [list \r\n \n] [readText $manifestPath]] ne [artifactManifest]} {
        fail "dependency artifact manifest mismatch: [file nativename $manifestPath]"
    }
}

# The archive in downloads\, its hash checked; fetched first when missing,
# with Windows' own curl.exe, as before.
proc ::boot::getArchive {entry} {
    variable downloads
    file mkdir $downloads
    set target [file join $downloads [dict get $entry file]]
    if {[file exists $target]} {
        if {[catch {assertHash $target [dict get $entry sha256] [dict get $entry id]}]} {
            file delete $target
        } else {
            return $target
        }
    }
    set partial $target.partial
    assertUnderCache $partial
    file delete $partial
    say "download [dict get $entry id] [dict get $entry version]"
    set curl [file join $::env(SystemRoot) System32 curl.exe]
    set result [run -inherit -- $curl -fL --retry 2 --retry-all-errors --output $partial [dict get $entry url]]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        fail "download failed for [dict get $entry id] with exit code [dict get $result exit]"
    }
    assertHash $partial [dict get $entry sha256] [dict get $entry id]
    renameWaiting $partial $target
    return $target
}

# Unpacks an archive with Windows' own tar.exe (zip, and gzip'd tar).
proc ::boot::unpack {archive dest} {
    file mkdir $dest
    set tar [file join $::env(SystemRoot) System32 tar.exe]
    set result [run -timeout 15m -- $tar -xf $archive -C $dest]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        fail "tar could not unpack [file tail $archive]: [string trim [encoding convertfrom utf-8 [dict get $result err]]]"
    }
}

# The MSYS2 root the lock describes: --msys, MSYS2_ROOT, or C:\msys64. The
# lock checks the toolchain by hash afterwards, so a wrong guess fails loudly
# rather than building with a stranger's compiler.
proc ::boot::msysRoot {requested} {
    if {$requested ne ""} {
        return [file normalize $requested]
    }
    if {[info exists ::env(MSYS2_ROOT)] && $::env(MSYS2_ROOT) ne ""} {
        return [file normalize $::env(MSYS2_ROOT)]
    }
    if {[file isfile C:/msys64/usr/bin/bash.exe]} {
        return C:/msys64
    }
    fail "MSYS2 root not found; pass --msys or set MSYS2_ROOT"
}

proc ::boot::firstLine {result} {
    lindex [split [string trim [encoding convertfrom utf-8 [dict get $result out]]] \n] 0
}

proc ::boot::checkToolchain {msys lock} {
    set tool [dict get $lock toolchain]
    foreach {relative key label} {
        ucrt64/bin/gcc.exe gccSha256 GCC
        ucrt64/bin/strip.exe stripSha256 strip
        ucrt64/bin/windres.exe windresSha256 windres
        ucrt64/bin/mingw32-make.exe makeSha256 mingw32-make
        usr/bin/zip.exe zipSha256 zip
    } {
        assertHash [file join $msys {*}[split $relative /]] [dict get $tool $key] $label
    }
    if {![file isfile [file join $msys usr bin bash.exe]]} {
        fail "missing MSYS2 bash: [file nativename [file join $msys usr bin bash.exe]]"
    }
    set gccVersion [firstLine [run -- [file join $msys ucrt64 bin gcc.exe] -dumpfullversion]]
    if {$gccVersion ne [dict get $tool gccVersion]} {
        fail "GCC version mismatch: expected [dict get $tool gccVersion], got $gccVersion"
    }
    set makeVersion [firstLine [run -- [file join $msys ucrt64 bin mingw32-make.exe] --version]]
    set makeWanted [lindex [split [dict get $tool makePackageVersion] -] 0]
    if {![regexp "GNU Make [string map {. \\.} $makeWanted](\$|\\s)" $makeVersion]} {
        fail "make version mismatch: expected [dict get $tool makePackageVersion], got $makeVersion"
    }
    set zipResult [run -- [file join $msys usr bin zip.exe] -v]
    set zipVersion [join [lrange [split [encoding convertfrom utf-8 [dict get $zipResult out]] \n] 0 1] " "]
    if {![regexp {This is Zip 3\.0} $zipVersion]} {
        fail "zip version mismatch: expected [dict get $tool zipPackageVersion], got $zipVersion"
    }
}

# A word for bash: single quotes, each single quote spelled '\''.
proc ::boot::shq {word} {
    return "'[string map {' '\\''} $word]'"
}

# Runs one command line in MSYS2's bash as tools/bootstrap-deps.sh ran its
# steps: a login shell, the UCRT64 compiler and MSYS2's utilities first on
# PATH, the GNU names for the compiler tools. Output goes to this console.
proc ::boot::msysRun {msys dir command} {
    set bash [file join $msys usr bin bash.exe]
    set line "cd [shq [unixPath $msys $dir]] && export PATH=\"/ucrt64/bin:/usr/bin:\$PATH\" CC=gcc AR=ar RANLIB=ranlib RC=windres && $command"
    set result [run -inherit -- $bash -lc $line]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        fail "Tcl/Tk build step failed with exit code [dict get $result exit]: $command"
    }
}

proc ::boot::unixPath {msys path} {
    firstLine [run -- [file join $msys usr bin cygpath.exe] -u [file nativename $path]]
}

proc ::boot::mixedPath {msys path} {
    firstLine [run -- [file join $msys usr bin cygpath.exe] -m [file nativename $path]]
}

# Static Tcl and Tk into the prefix, as tools/bootstrap-deps.sh built them.
proc ::boot::buildTclTk {msys sourceRoot prefix jobs} {
    set tclWin [file join $sourceRoot tcl9.0.4 win]
    set tkWin [file join $sourceRoot tk9.0.4 win]
    if {![file isfile [file join $tclWin configure]] || ![file isfile [file join $tkWin configure]]} {
        fail "Tcl/Tk 9.0.4 source directories are incomplete under [file nativename $sourceRoot]"
    }
    file mkdir $prefix
    set prefixUnix [unixPath $msys $prefix]
    # The static runtime has no physical installation after packaging. Tcl's
    # public ::tcl::pkgconfig values therefore describe the paths that really
    # exist in every full and wrapped zipfs, rather than this machine's
    # dependency cache. The source-prefix map keeps __FILE__ reproducible.
    set runtimeRoot //zipfs:/app
    set map "-ffile-prefix-map=[string map {{ } {\ }} [mixedPath $msys $sourceRoot]]=tcltk-9.0.4"
    set optimize [shq "CFLAGS_OPTIMIZE=-O2 -fomit-frame-pointer $map"]
    set pkgconfig {}
    foreach {name value} [list \
            LIB_INSTALL_DIR_NATIVE $runtimeRoot BIN_INSTALL_DIR_NATIVE $runtimeRoot \
            SCRIPT_INSTALL_DIR_NATIVE $runtimeRoot/tcl_library INCLUDE_INSTALL_DIR_NATIVE $runtimeRoot \
            MAN_INSTALL_DIR_NATIVE $runtimeRoot/reference libdir_native $runtimeRoot bindir_native $runtimeRoot \
            TCL_LIBRARY_NATIVE $runtimeRoot/tcl_library includedir_native $runtimeRoot \
            mandir_native $runtimeRoot/reference] {
        lappend pkgconfig [shq $name=$value]
    }
    # Tcl 9 is always threaded; its configure no longer knows --enable-threads.
    if {![file isfile [file join $tclWin Makefile]]} {
        msysRun $msys $tclWin "./configure --enable-64bit --disable-shared --prefix=[shq $prefixUnix]"
    }
    # Only the core static runtime, headers, stubs and script libraries are
    # build inputs; upstream's all/install also build bundled extensions and
    # install manuals, neither of which is linked or packaged.
    msysRun $msys $tclWin "mingw32-make -j $jobs binaries $optimize [join $pkgconfig { }]"
    # The virtual runtime paths are not passed to installation: these targets
    # stage the files already built into the real dependency cache.
    foreach target {install-binaries install-libraries install-headers} {
        msysRun $msys $tclWin "mingw32-make $target"
    }
    if {![file isfile [file join $tkWin Makefile]]} {
        msysRun $msys $tkWin "./configure --enable-64bit --disable-shared --with-tcl=[shq [unixPath $msys $tclWin]] --prefix=[shq $prefixUnix]"
    }
    msysRun $msys $tkWin "mingw32-make -j $jobs binaries $optimize"
    foreach target {install-binaries install-libraries} {
        msysRun $msys $tkWin "mingw32-make $target"
    }
    # A stable layout, whatever upstream's install names.
    foreach {plain static} {tclsh90.exe tclsh90s.exe wish90.exe wish90s.exe} {
        if {[file isfile [file join $prefix bin $plain]] && ![file isfile [file join $prefix bin $static]]} {
            file copy [file join $prefix bin $plain] [file join $prefix bin $static]
        }
    }
}

proc ::boot::main {argv} {
    variable root
    variable script
    variable cache [file join $root .cache deps]
    set msysRequested ""
    set jobs [expr {[info exists ::env(NUMBER_OF_PROCESSORS)] ? $::env(NUMBER_OF_PROCESSORS) : 4}]
    set verifyOnly 0
    set sourcesOnly 0
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --cache {set argv [lassign $argv cache]}
            --msys {set argv [lassign $argv msysRequested]}
            --jobs {set argv [lassign $argv jobs]}
            --verify-only {set verifyOnly 1}
            --sources-only {set sourcesOnly 1}
            default {fail "unknown option $option"}
        }
    }
    set cache [file normalize $cache]
    set lockPath [file join $root tools dependencies.lock.json]
    set lock [json decode [readText $lockPath]]

    set notices [dict get $lock bundledNotices]
    if {[llength $notices] != 2 || [join [lsort [lmap n $notices {dict get $n id}]] ,] ne "tcl-libtommath,tcl-zlib"} {
        fail "dependency lock must declare the exact Tcl bundled notices"
    }
    set noticePaths {}
    foreach notice $notices {
        set source [dict get $notice source]
        if {$source eq "" || [file pathtype $source] ne "relative" || [regexp {(^|[/\\])\.\.([/\\]|$)} $source] ||
                ![string match tcl9.0.4/* $source]} {
            fail "invalid bundled-notice source path: $source"
        }
        set distribution [dict get $notice distribution]
        if {$distribution eq "" || [file pathtype $distribution] ne "relative" || ![regexp {^licenses/[^/\\]+$} $distribution]} {
            fail "invalid bundled-notice distribution path: $distribution"
        }
        if {![regexp {^[0-9a-fA-F]{64}$} [dict get $notice sha256]]} {
            fail "invalid bundled-notice SHA-256: [dict get $notice id]"
        }
        lappend noticePaths [file join $root {*}[split $distribution /]]
    }
    set patchPaths {}
    foreach patch [dict get $lock patches] {
        set file [dict get $patch file]
        if {$file eq "" || [file pathtype $file] ne "relative" || [regexp {(^|[/\\])\.\.([/\\]|$)} $file]} {
            fail "invalid dependency patch path: $file"
        }
        lappend patchPaths [file join $root tools {*}[split $file /]]
    }
    # What the cache was made from: the lock, this program, the patches and
    # the notices. Any change rebuilds it.
    set material {}
    foreach path [concat [list $lockPath $script] $patchPaths $noticePaths] {
        if {![file isfile $path]} {
            fail "missing bootstrap input: [file nativename $path]"
        }
        lappend material "[file tail $path] [hash file sha256 $path]"
    }
    set stateHash [hash sum sha256 [encoding convertto utf-8 [join $material \n]]]
    variable prefix [file join $cache prefix]
    set sourceRoot [file join $cache src]
    variable downloads [file join $cache downloads]
    set statePath [file join $cache lock.sha256]
    variable manifestPath [file join $cache artifacts.sha256]
    foreach entry [dict get $lock archives] {
        dict set archives [dict get $entry id] $entry
    }

    if {!$sourcesOnly} {
        set msys [msysRoot $msysRequested]
        checkToolchain $msys $lock
        set stateMatches [expr {[file isfile $statePath] && [string trim [readText $statePath]] eq $stateHash}]
        if {$verifyOnly} {
            if {!$stateMatches} {
                fail "dependency cache is absent or stale; run tools/bootstrap.tcl"
            }
            assertArtifactManifest
            say "dependency cache verified ($stateHash)"
            return
        }
        if {$stateMatches} {
            if {[catch {assertArtifactManifest} problem] == 0} {
                say "dependency cache already current ($stateHash)"
                return
            }
            say "warning: dependency cache content verification failed; rebuilding: $problem"
        }
    }

    file mkdir $cache $sourceRoot $prefix
    # A stale or interrupted cache is never configured in place: downloaded
    # archives stay (their hashes are checked again), every derived tree is
    # made again from an empty directory.
    foreach derived [list $prefix $sourceRoot [file join $cache sqlite] [file join $cache yyjson]] {
        assertUnderCache $derived
        if {[file exists $derived]} {
            foreach file [filesBelow $derived] {
                catch {file attributes $file -readonly 0}
            }
            file delete -force $derived
        }
        file mkdir $derived
    }
    file delete $statePath $manifestPath

    set tclArchive [getArchive [dict get $archives tcltk]]
    set tkArchive [getArchive [dict get $archives tk]]
    set extract [file join $sourceRoot tcltk-9.0.4]
    set temp [file join $sourceRoot .tcltk-extract-[binary encode hex [hash random 16]]]
    assertUnderCache $temp
    try {
        unpack $tclArchive $temp
        unpack $tkArchive $temp
        if {![file isfile [file join $temp tcl9.0.4 win configure]] || ![file isfile [file join $temp tk9.0.4 win configure]]} {
            fail "Tcl/Tk archives are incomplete after extraction"
        }
        renameWaiting $temp $extract
    } finally {
        if {[file exists $temp]} {
            file delete -force $temp
        }
    }

    # Tcl's static archive carries its bundled zlib and LibTomMath; their exact
    # notices in the locked source are the copies every runtime carries.
    foreach notice $notices {
        assertHash [file join $extract {*}[split [dict get $notice source] /]] [dict get $notice sha256] "[dict get $notice id] source notice"
        assertHash [file join $root {*}[split [dict get $notice distribution] /]] [dict get $notice sha256] "[dict get $notice id] distributed notice"
    }
    set patches [lmap p [dict get $lock patches] {if {[dict get $p id] ne "tcl-windows-acl-normalize"} continue; set p}]
    if {[llength $patches] != 1} {
        fail "dependency lock must contain exactly one tcl-windows-acl-normalize patch"
    }
    set patch [lindex $patches 0]
    set patchPath [file join $root tools {*}[split [dict get $patch file] /]]
    set patchTarget [file join $extract {*}[split [dict get $patch target] /]]
    assertHash $patchPath [dict get $patch sha256] [dict get $patch id]
    assertHash $patchTarget [dict get $patch beforeSha256] "[dict get $patch id] input"
    applyPinnedUnifiedPatch $patchPath $patchTarget [dict get $patch target]
    assertHash $patchTarget [dict get $patch afterSha256] "[dict get $patch id] output"

    if {!$sourcesOnly} {
        buildTclTk $msys $extract $prefix $jobs
    }

    set sqlite [dict get $archives sqlite]
    set sqliteArchive [getArchive $sqlite]
    set sqliteExtract [file join $sourceRoot sqlite-[dict get $sqlite version]]
    assertUnderCache $sqliteExtract
    file delete -force $sqliteExtract
    unpack $sqliteArchive $sqliteExtract
    set sqliteC [lindex [lsort [lmap f [filesBelow $sqliteExtract] {if {[file tail $f] ne "sqlite3.c"} continue; set f}]] 0]
    if {$sqliteC eq ""} {
        fail "SQLite archive contains no sqlite3.c"
    }
    file mkdir [file join $cache sqlite]
    foreach name {sqlite3.c sqlite3.h} {
        file copy -force [file join [file dirname $sqliteC] $name] [file join $cache sqlite $name]
    }

    # yyjson: the json command's reader core; one .c and .h and its license.
    set yyjson [dict get $archives yyjson]
    set yyjsonArchive [getArchive $yyjson]
    set yyjsonExtract [file join $sourceRoot .yyjson-extract-[binary encode hex [hash random 16]]]
    assertUnderCache $yyjsonExtract
    try {
        unpack $yyjsonArchive $yyjsonExtract
        set yyjsonSource [file join $yyjsonExtract yyjson-[dict get $yyjson version]]
        if {![file isfile [file join $yyjsonSource src yyjson.c]]} {
            fail "yyjson archive contains no src/yyjson.c after extraction"
        }
        file mkdir [file join $cache yyjson]
        foreach relative {src/yyjson.c src/yyjson.h LICENSE} {
            file copy -force [file join $yyjsonSource {*}[split $relative /]] [file join $cache yyjson [file tail $relative]]
        }
    } finally {
        file delete -force $yyjsonExtract
    }

    if {$sourcesOnly} {
        say "dependency sources ready in [file nativename $cache] (Tcl/Tk not built; no state written)"
        return
    }
    writeArtifactManifest
    writeText $statePath "$stateHash\n"
    say "dependency cache ready ($stateHash)"
}

# Only as the entry: tools/release.tcl loads these procs.
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    try {
        ::boot::main $argv
    } trap {BOOTSTRAP fail} {message} {
        puts stderr $message
        exit 1
    }
}
