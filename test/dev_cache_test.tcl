package require machteld 0.21

# Content-cache and publication regressions. Run on the build runtime, as
# tools/dev.tcl runs:
#   dist/0.21/machteld.exe test/dev_cache_test.tcl ?--msys DIR?
# MSYS2 is found as tools/bootstrap.tcl finds it (--msys, MSYS2_ROOT, then
# C:/msys64). No upstream conversion, network, or active build cache is used.
# Tiny native fixtures also verify the exact compiler environment with the
# pinned tools. The tiny products below exercise the production
# cache/publisher, not a second cache implementation. The separate
# production-spec tests check input selection.

set repo [file normalize [file join [file dirname [info script]] ..]]
source [file join $repo tools devcache.tcl]
source -encoding utf-8 [file join $repo tools bootstrap.tcl]

proc write_bytes {path bytes} {
    file mkdir [file dirname $path]
    set ch [open $path wb]
    try { puts -nonewline $ch $bytes } finally { close $ch }
}
proc read_bytes {path} {
    set ch [open $path rb]
    try { return [read $ch] } finally { close $ch }
}
proc fixture_entries {root {relative ""}} {
    set entries {}
    set children [concat [glob -nocomplain -directory [file join $root $relative] *] \
        [glob -nocomplain -types hidden -directory [file join $root $relative] *]]
    foreach path [lsort -unique $children] {
        if {[file tail $path] in {. ..}} continue
        set name [file join $relative [file tail $path]]
        if {[file isdirectory $path]} {
            lappend entries {*}[fixture_entries $root $name]
        } else {
            lappend entries $name [read_bytes $path]
        }
    }
    return $entries
}
proc fixture_payload {spec} {
    set payload [list values [dict get $spec values]]
    foreach path [lsort [dict get $spec files]] {
        lappend payload file $path [read_bytes $path]
    }
    foreach path [lsort [dict get $spec trees]] {
        lappend payload tree $path [fixture_entries $path]
    }
    return [encoding convertto utf-8 $payload]
}
proc fixture_build {spec candidate} {
    incr ::builds
    if {[file exists $candidate]} { error "builder candidate must be absent" }
    write_bytes $candidate [fixture_payload $spec]
}
proc fixture_fail {candidate} {
    write_bytes $candidate partial
    error "deliberate generation failure"
}
proc fixture_mutate {input candidate} {
    write_bytes $candidate complete-but-raced
    write_bytes $input changed-during-generation
}
proc fixture_hang {candidate} {
    write_bytes $candidate partial-before-interruption
    puts READY
    flush stdout
    vwait ::never
}
proc fixture_tree {spec candidate} {
    incr ::builds
    if {[file exists $candidate]} { error "directory candidate must be absent" }
    write_bytes [file join $candidate product] [fixture_payload $spec]
}
proc fixture_tree_fail {candidate} {
    write_bytes [file join $candidate partial] partial
    error "deliberate directory generation failure"
}

# A subprocess is killed while ensure's real generation callback is active.
# This verifies the old publication/record survive an actual process interruption.
if {[lindex $argv 0] eq "--interrupt"} {
    lassign [lrange $argv 1 end] record specFile output
    set spec [read_bytes $specFile]
    ::machteld::devcache::ensure $record $spec $output fixture_hang
    exit 90
}
if {[lindex $argv 0] eq "--lock"} {
    ::machteld::devcache::lock [lindex $argv 1]
    puts LOCKED
    flush stdout
    vwait ::never
    exit 90
}
set msysRequested ""
if {[lindex $argv 0] eq "--msys" && [llength $argv] == 2} {
    set msysRequested [lindex $argv 1]
} elseif {[llength $argv]} {
    error "usage: dev_cache_test.tcl ?--msys DIR?"
}

set fails 0
set checks 0
set builds 0
proc check {name condition {detail ""}} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else {
        incr ::fails
        puts "FAIL $name $detail"
    }
}
proc expect_miss {name spec record output {expectedBuild 1}} {
    set count $::builds
    set built [::machteld::devcache::ensure $record $spec $output \
        [list fixture_build $spec]]
    check $name [expr {$built == $expectedBuild && $::builds == $count + $expectedBuild}]
    check "$name: payload" [expr {[read_bytes $output] eq [fixture_payload $spec]}]
}
proc child_readable {ch} {
    if {[gets $ch line] >= 0} {
        set ::childState $line
    } elseif {[eof $ch]} {
        set ::childState eof
    }
}
proc production_spec {stage} {
    switch -- $stage {
        dependencies {
            return [::machteld::devcache::dependency_spec $::fixtureRoot $::fixtureCache]
        }
        native {
            return [::machteld::devcache::native_shared_spec \
                $::fixtureRoot $::fixturePaths toolchain-identity]
        }
        reference {
            return [::machteld::devcache::reference_spec \
                $::fixtureRoot $::fixtureCache [dict get $::fixturePaths tclsh]]
        }
        package {
            return [::machteld::devcache::package_spec $::fixtureRoot $::fixturePaths \
                [file join $::fixtureRoot staged prelude.tcl] \
                [file join $::fixtureRoot staged console.exe] \
                [file join $::fixtureRoot staged gui.exe] \
                [file join $::fixtureRoot staged reference]]
        }
        default { error "unknown fixture stage: $stage" }
    }
}
proc production_key {stage} {
    return [::machteld::devcache::fingerprint [production_spec $stage]]
}
proc spec_tracks {stage path} {
    set before [production_key $stage]
    set bytes [read_bytes $path]
    set time [file mtime $path]
    write_bytes $path "${bytes}-changed"
    file mtime $path $time
    check "$stage dependency tracks [file tail $path] content" \
        [expr {$before ne [production_key $stage]}]
    write_bytes $path $bytes
    file mtime $path $time
    check "$stage dependency restored content restores key" \
        [expr {$before eq [production_key $stage]}]
}
proc toolchain_tracks {root relative} {
    set path [file join $root {*}[split $relative /]]
    set before [::machteld::devcache::toolchain_digest $root]
    set bytes [read_bytes $path]
    set time [file mtime $path]
    write_bytes $path "${bytes}-changed"
    file mtime $path $time
    check "shared toolchain tracks $relative with unchanged mtime" \
        [expr {$before ne [::machteld::devcache::toolchain_digest $root]}]
    write_bytes $path $bytes
    file mtime $path $time
    check {restored toolchain bytes restore the provenance key} \
        [expr {$before eq [::machteld::devcache::toolchain_digest $root]}]
}

set marker [file tempfile claim]
close $marker
set work [file normalize "${claim}.d"]
file mkdir $work
try {
    check {text digest is the exact lowercase SHA-256 of the UTF-8 bytes} \
        [expr {[::machteld::devcache::text_digest ""] eq \
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" &&
            [::machteld::devcache::text_digest "[format %c 233]\0"] eq \
                [::machteld::hash sum sha256 [binary format H* c3a900]]}]
    set source [file join $work inputs source.c]
    set header [file join $work inputs headers core.h]
    set library [file join $work inputs libs static.a]
    set license [file join $work inputs LICENSE]
    set recipe [file join $work inputs package.tcl]
    set tool [file join $work inputs compiler.exe]
    set tree [file join $work inputs runtime]
    write_bytes $source source-one
    write_bytes $header header-one
    write_bytes $library library-one
    write_bytes $license license-one
    write_bytes $recipe recipe-one
    write_bytes $tool compiler-one
    write_bytes [file join $tree init.tcl] runtime-one
    write_bytes [file join $tree .hidden] hidden-one
    set spec [dict create values {-O2 -Werror subsystem-console} \
        files [list $source $header $library $license $recipe $tool] trees [list $tree]]
    set record [file join $work object.record]
    set output [file join $work object.exe]

    check {missing record/output is a cache miss} \
        [expr {![::machteld::devcache::current $record \
            [::machteld::devcache::fingerprint $spec] [list $output]]}]
    expect_miss {first build} $spec $record $output
    set outputTime [file mtime $output]
    set recordBytes [read_bytes $record]
    expect_miss {unchanged build does not call generator} $spec $record $output 0
    check {no-op does not rewrite output or cache record} \
        [expr {[file mtime $output] == $outputTime && [read_bytes $record] eq $recordBytes}]

    set sourceTime [file mtime $source]
    write_bytes $source source-two
    file mtime $source $sourceTime
    expect_miss {same-size source edit with identical mtime invalidates} $spec $record $output
    write_bytes $source source-old
    file mtime $source [expr {$sourceTime - 86400}]
    expect_miss {older timestamp content edit invalidates} $spec $record $output
    file mtime $source [expr {$sourceTime + 86400}]
    expect_miss {timestamp-only edit remains a cache hit} $spec $record $output 0

    foreach {label path content} [list \
            header $header header-two \
            static-library $library library-two \
            license $license license-two \
            packaging-script $recipe recipe-two \
            toolchain-binary $tool compiler-two] {
        set prior [file mtime $path]
        write_bytes $path $content
        file mtime $path $prior
        expect_miss "$label content invalidates independently of mtime" $spec $record $output
    }
    dict set spec values {-O3 -Werror subsystem-console}
    expect_miss {changed compiler flags invalidate} $spec $record $output
    dict set spec values {-O3 subsystem-console}
    expect_miss {changed warning policy invalidates} $spec $record $output
    dict set spec values {-O3 subsystem-gui}
    expect_miss {changed link configuration invalidates} $spec $record $output

    write_bytes [file join $tree added.tcl] added
    expect_miss {added tree input invalidates} $spec $record $output
    file rename [file join $tree added.tcl] [file join $tree renamed.tcl]
    expect_miss {renamed tree input invalidates} $spec $record $output
    file delete [file join $tree renamed.tcl]
    expect_miss {deleted tree input invalidates} $spec $record $output
    set hiddenTime [file mtime [file join $tree .hidden]]
    write_bytes [file join $tree .hidden] hidden-two
    file mtime [file join $tree .hidden] $hiddenTime
    expect_miss {hidden tree input content invalidates} $spec $record $output

    set intact [read_bytes $output]
    set outputTime [file mtime $output]
    write_bytes $output [string repeat x [string length $intact]]
    file mtime $output $outputTime
    expect_miss {same-size output corruption is not a cache hit} $spec $record $output
    file delete $output
    expect_miss {missing output regenerates} $spec $record $output

    write_bytes $record "truncated \{"
    expect_miss {truncated cache record safely regenerates} $spec $record $output
    set ::recordExecuted 0
    write_bytes $record {set ::recordExecuted 1}
    expect_miss {Tcl-looking record is inert data} $spec $record $output
    check {reading a record never evaluates Tcl} [expr {!$::recordExecuted}]

    set oldOutput [read_bytes $output]
    set oldRecord [read_bytes $record]
    dict lappend spec values changed-after-last-good
    set failed [catch {::machteld::devcache::ensure $record $spec $output fixture_fail} message]
    check {failed generation reports the original error} \
        [expr {$failed && [string match {*deliberate generation failure*} $message]}] $message
    check {failed generation preserves the last good output and record} \
        [expr {[read_bytes $output] eq $oldOutput && [read_bytes $record] eq $oldRecord}]
    check {failed generation does not become current} \
        [expr {![::machteld::devcache::current $record \
            [::machteld::devcache::fingerprint $spec] [list $output]]}]

    set failed [catch {::machteld::devcache::ensure $record $spec $output \
        [list fixture_mutate $source]} message]
    check {inputs changing during generation reject the candidate} $failed $message
    check {raced input preserves the last good output and record} \
        [expr {[read_bytes $output] eq $oldOutput && [read_bytes $record] eq $oldRecord}]

    set specFile [file join $work interrupt-spec.dict]
    write_bytes $specFile $spec
    set pipe [open |[list [info nameofexecutable] [file normalize [info script]] \
        --interrupt $record $specFile $output] r]
    set childPids [pid $pipe]
    chan configure $pipe -blocking 0 -buffering line
    set ::childState waiting
    chan event $pipe readable [list child_readable $pipe]
    set timeout [after 20000 {set ::childState timed-out}]
    try {
        vwait ::childState
        check {interruption fixture reaches candidate generation} \
            [expr {$::childState eq "READY"}] $::childState
    } finally {
        after cancel $timeout
        chan event $pipe readable {}
        # Kill the generating process outright, as an interruption would.
        foreach child $childPids { catch {exec taskkill.exe /F /PID $child 2>@1} }
        catch {close $pipe}
    }
    check {process interruption preserves the last good output and record} \
        [expr {[read_bytes $output] eq $oldOutput && [read_bytes $record] eq $oldRecord}]
    expect_miss {build after an interrupted candidate recovers} $spec $record $output
    set cleanOutput [file join $work clean.exe]
    set cleanRecord [file join $work clean.record]
    expect_miss {independent clean fixture build} $spec $cleanRecord $cleanOutput
    check {clean and incrementally rebuilt fixture contents agree} \
        [expr {[read_bytes $output] eq [read_bytes $cleanOutput]}]

    # Objects/preludes use the generic atomic publication path rather than the
    # executable publisher. Exercise it against an output another handle holds:
    # Tcl opens files without FILE_SHARE_DELETE, so the replacement is refused.
    set objectOutput [file join $work cached-object.o]
    set objectRecord [file join $work cached-object.record]
    expect_miss {non-executable cache stage builds} $spec $objectRecord $objectOutput
    expect_miss {non-executable cache stage is a no-op when current} $spec $objectRecord $objectOutput 0
    set objectBytes [read_bytes $objectOutput]
    set objectRecordBytes [read_bytes $objectRecord]
    dict lappend spec values changed-for-locked-publication
    set held [open $objectOutput rb]
    set attempts $::machteld::devcache::publishAttempts
    set ::machteld::devcache::publishAttempts 2
    try {
        set failed [catch {::machteld::devcache::ensure $objectRecord $spec $objectOutput \
            [list fixture_build $spec]} message]
    } finally {
        set ::machteld::devcache::publishAttempts $attempts
        close $held
    }
    check {held non-executable output refuses publication} $failed $message
    check {publication failure preserves the complete object and record} \
        [expr {[read_bytes $objectOutput] eq $objectBytes && \
            [read_bytes $objectRecord] eq $objectRecordBytes}]
    expect_miss {object publication recovers once the holder closes the output} $spec $objectRecord $objectOutput
    set objectSpec $spec

    # Immutable reference-style directory generations are selected by a record.
    # A failed new generation must never remove the old selected directory.
    set treeRecord [file join $work reference.record]
    set treeParent [file join $work generations]
    file mkdir $treeParent
    set oldTree [::machteld::devcache::immutable $treeRecord $spec $treeParent \
        [list fixture_tree $spec]]
    set count $builds
    set selected [::machteld::devcache::immutable $treeRecord $spec $treeParent \
        [list fixture_tree $spec]]
    check {unchanged directory generation is reused without rebuilding} \
        [expr {$selected eq $oldTree && $builds == $count}]
    set oldTreeBytes [read_bytes [file join $oldTree product]]
    set oldTreeRecord [read_bytes $treeRecord]
    dict lappend spec values new-reference
    set failed [catch {::machteld::devcache::immutable $treeRecord $spec $treeParent \
        fixture_tree_fail} message]
    check {failed immutable generation reports failure} $failed $message
    check {failed directory generation preserves the old selection and corpus} \
        [expr {[read_bytes $treeRecord] eq $oldTreeRecord && \
            [read_bytes [file join $oldTree product]] eq $oldTreeBytes}]
    set newTree [::machteld::devcache::immutable $treeRecord $spec $treeParent \
        [list fixture_tree $spec]]
    check {successful immutable generation selects a different complete directory} \
        [expr {$newTree ne $oldTree && \
            [read_bytes [file join $newTree product]] eq [fixture_payload $spec] && \
            [read_bytes [file join $oldTree product]] eq $oldTreeBytes}]
    write_bytes [file join $newTree product] corrupted-corpus
    set count $builds
    set repairedTree [::machteld::devcache::immutable $treeRecord $spec $treeParent \
        [list fixture_tree $spec]]
    check {corrupted selected corpus is regenerated instead of trusted} \
        [expr {$builds == $count + 1 && \
            [read_bytes [file join $repairedTree product]] eq [fixture_payload $spec]}]
    write_bytes $treeRecord [dict create schema 1 outputs "\{"]
    set count $builds
    set badRecordFailed [catch {
        set recoveredTree [::machteld::devcache::immutable $treeRecord $spec $treeParent \
            [list fixture_tree $spec]]
    } message]
    check {malformed outputs list in a directory record is a cache miss} \
        [expr {!$badRecordFailed && $builds == $count + 1}] $message

    # The production lock is a file naming its holder's process and start time.
    # Killing its owner must make the lock it leaves behind reusable; a mere
    # leftover filename must not deadlock.
    set cleanRoot [file join $work clean-fixture]
    write_bytes [file join $cleanRoot object.o] keep-object
    write_bytes [file join $cleanRoot reference page.md] keep-reference
    set lockFile [file join $cleanRoot build.lock]
    set pipe [open |[list [info nameofexecutable] [file normalize [info script]] \
        --lock $lockFile] r]
    set childPids [pid $pipe]
    chan configure $pipe -blocking 0 -buffering line
    set ::childState waiting
    chan event $pipe readable [list child_readable $pipe]
    set timeout [after 20000 {set ::childState timed-out}]
    try {
        vwait ::childState
        check {build lock fixture acquires a real process-held lock} \
            [expr {$::childState eq "LOCKED"}] $::childState
        set contended [catch {::machteld::devcache::lock $lockFile} message]
        check {another process cannot acquire a held build lock} $contended $message
        set refused [catch {::machteld::devcache::clean $cleanRoot} message]
        check {clean refuses a cache owned by an active build} $refused $message
        check {contended clean preserves every cached fixture} \
            [expr {[read_bytes [file join $cleanRoot object.o]] eq "keep-object" && \
                [read_bytes [file join $cleanRoot reference page.md]] eq "keep-reference"}]
    } finally {
        after cancel $timeout
        chan event $pipe readable {}
        foreach child $childPids { catch {exec taskkill.exe /F /PID $child 2>@1} }
        catch {close $pipe}
    }
    check {killed lock owner leaves its lock filename behind} [file isfile $lockFile]
    set reacquired [expr {![catch {::machteld::devcache::lock $lockFile} message]}]
    check {a killed owner's lock is taken over} $reacquired $message
    if {$reacquired} { ::machteld::devcache::unlock $lockFile }
    check {normal unlock removes this holder's lock file} [expr {![file exists $lockFile]}]
    set reacquired [expr {![catch {::machteld::devcache::lock $lockFile} message]}]
    check {normal unlock permits another acquisition} $reacquired $message
    if {$reacquired} { ::machteld::devcache::unlock $lockFile }
    write_bytes $lockFile {}
    file mtime $lockFile [expr {[clock seconds] - 60}]
    set reacquired [expr {![catch {::machteld::devcache::lock $lockFile} message]}]
    check {an old lock file that names no holder is taken over} $reacquired $message
    if {$reacquired} { ::machteld::devcache::unlock $lockFile }
    ::machteld::devcache::clean $cleanRoot
    check {uncontended clean removes fixtures and its own lock file} \
        [expr {[glob -tails -nocomplain -directory $cleanRoot *] eq {} && \
            [glob -tails -nocomplain -types hidden -directory $cleanRoot *] eq {} && \
            [file isdirectory $cleanRoot]}]
    set reacquired [expr {![catch {::machteld::devcache::lock $lockFile} message]}]
    check {successful clean releases its lock} $reacquired $message
    if {$reacquired} { ::machteld::devcache::unlock $lockFile }

    # Input selection is tested through the production stage-spec builders.
    # Files here are tiny stand-ins; no native code or real manuals are built.
    set ::fixtureRoot [file join $work repository]
    set ::fixtureCache [file join $work dependencies]
    set prefix [file join $::fixtureCache prefix]
    set ::fixturePaths [dict create prefix $prefix \
        include [file join $prefix include] \
        sqlite [file join $::fixtureCache sqlite] \
        yyjson [file join $::fixtureCache yyjson] \
        tclsh [file join $prefix bin tclsh90s.exe]]
    foreach relative {
        tools/dependencies.lock.json tools/bootstrap.tcl tools/patches/dependency.patch tools/buildlib.tcl
        tools/reference.tcl tools/package.tcl
        tools/build_identity.tcl src/machteld.h src/other.h tcl/machteld.tcl
        tcl/pool.tcl LICENSE licenses/Tcl-9.0.4.txt licenses/Tk-9.0.4.txt
        licenses/yyjson-0.12.0.txt docs/overview.md
        docs/reference/machteld/command/help.md staged/prelude.tcl
        staged/console.exe staged/gui.exe staged/reference/manifest.sha256
        staged/reference/markdown/page.md
    } {
        write_bytes [file join $::fixtureRoot {*}[split $relative /]] "fixture:$relative"
    }
    write_bytes [file join $::fixtureRoot src machteld.h] {#define MACHTELD_VERSION "22"}
    write_bytes [file join $::fixtureRoot tcl machteld.tcl] {variable version 22}
    foreach relative {
        lock.sha256 artifacts.sha256 downloads/tcl904-src.zip downloads/tk904-src.zip
        prefix/include/tcl.h prefix/bin/tclsh90s.exe prefix/bin/wish90s.exe
        prefix/lib/tcl9.0/init.tcl prefix/lib/tcl9/9.0/msgcat.tm
        prefix/lib/tk9.0/tk.tcl sqlite/sqlite3.h yyjson/yyjson.h
    } {
        write_bytes [file join $::fixtureCache {*}[split $relative /]] "fixture:$relative"
    }
    foreach relative {
        tools/dependencies.lock.json tools/bootstrap.tcl tools/patches/dependency.patch
    } {
        spec_tracks dependencies [file join $::fixtureRoot {*}[split $relative /]]
    }
    foreach relative {lock.sha256 artifacts.sha256} {
        spec_tracks dependencies [file join $::fixtureCache $relative]
    }
    foreach relative {tools/buildlib.tcl src/machteld.h src/other.h} {
        spec_tracks native [file join $::fixtureRoot {*}[split $relative /]]
    }
    spec_tracks native [file join $prefix include tcl.h]
    spec_tracks native [file join $::fixtureCache sqlite sqlite3.h]
    spec_tracks native [file join $::fixtureCache yyjson yyjson.h]
    set before [production_key native]
    set additionalHeader [file join $::fixtureRoot src added.h]
    write_bytes $additionalHeader extra-header
    check {native dependency tracks new authored headers} [expr {$before ne [production_key native]}]
    file delete $additionalHeader
    check {native dependency notices header deletion} [expr {$before eq [production_key native]}]
    set nativeSpec [production_spec native]
    dict set nativeSpec values changed-toolchain-identity
    check {native dependency includes full toolchain identity} \
        [expr {$before ne [::machteld::devcache::fingerprint $nativeSpec]}]
    set guardKey [production_key native]
    check {unchanged shared-input guard passes} \
        [expr {![catch {::machteld::devcache::verify_guard $guardKey \
            [list production_spec native]}]}]
    write_bytes $additionalHeader guard-race
    check {completed object is still independently a cache hit} \
        [::machteld::devcache::current $objectRecord \
            [::machteld::devcache::fingerprint $objectSpec] [list $objectOutput]]
    set rejected [catch {::machteld::devcache::verify_guard $guardKey \
        [list production_spec native]} message]
    check {cache-hit path guard rejects a changed shared-input inventory} $rejected $message
    file delete $additionalHeader

    foreach relative {
        LICENSE tools/reference.tcl
        tools/dependencies.lock.json licenses/Tcl-9.0.4.txt licenses/Tk-9.0.4.txt
        docs/overview.md docs/reference/machteld/command/help.md
    } {
        spec_tracks reference [file join $::fixtureRoot {*}[split $relative /]]
    }
    foreach relative {prefix/bin/tclsh90s.exe downloads/tcl904-src.zip downloads/tk904-src.zip} {
        spec_tracks reference [file join $::fixtureCache {*}[split $relative /]]
    }
    # tools/reference.tcl runs on the build runtime; its bytes are an input.
    check {reference dependency includes the converting build runtime} \
        [expr {[file normalize [info nameofexecutable]] in \
            [lmap path [dict get [production_spec reference] files] {file normalize $path}]}]
    set before [production_key reference]
    set priorNative [production_key native]
    set renamedDoc [file join $::fixtureRoot docs renamed.md]
    set originalDoc [file join $::fixtureRoot docs overview.md]
    file rename $originalDoc $renamedDoc
    check {reference input inventory detects renamed documentation} \
        [expr {$before ne [production_key reference]}]
    check {documentation edits do not invalidate native objects} \
        [expr {$priorNative eq [production_key native]}]
    file delete $renamedDoc
    set afterDelete [production_key reference]
    write_bytes $originalDoc fixture:docs/overview.md
    check {reference input inventory detects deleted documentation} \
        [expr {$before ne $afterDelete && $before eq [production_key reference]}]
    set before [production_key reference]
    write_bytes [file join $::fixtureRoot tcl pool.tcl] changed-implementation-only
    check {implementation-only Tcl edit does not regenerate the reference} \
        [expr {$before eq [production_key reference]}]
    write_bytes [file join $::fixtureRoot tcl machteld.tcl] "variable version 22\n# implementation edit"
    check {main Tcl implementation edit does not regenerate the reference} \
        [expr {$before eq [production_key reference]}]
    set capturedReferenceSpec [production_spec reference]
    write_bytes [file join $::fixtureRoot src machteld.h] {#define MACHTELD_VERSION "23"}
    check {reference rejects inconsistent runtime versions} [catch {production_key reference}]
    write_bytes [file join $::fixtureRoot tcl machteld.tcl] {variable version 23}
    check {reference rechecks semantic version at publication time} \
        [catch {::machteld::devcache::fingerprint $capturedReferenceSpec}]
    check {runtime version change regenerates the reference} [expr {$before ne [production_key reference]}]
    # The version is one natural number; the dotted form of 0.21 and before is
    # no canonical version any more, even when both declarations agree.
    set naturalKey [production_key reference]
    write_bytes [file join $::fixtureRoot src machteld.h] {#define MACHTELD_VERSION "0.23"}
    write_bytes [file join $::fixtureRoot tcl machteld.tcl] {variable version 0.23}
    check {reference refuses a dotted runtime version} [catch {production_key reference}]
    write_bytes [file join $::fixtureRoot src machteld.h] {#define MACHTELD_VERSION "23"}
    write_bytes [file join $::fixtureRoot tcl machteld.tcl] {variable version 23}
    check {restored natural version keys the reference as before} \
        [expr {$naturalKey eq [production_key reference]}]

    foreach relative {
        LICENSE licenses/yyjson-0.12.0.txt tools/package.tcl
        tools/build_identity.tcl staged/prelude.tcl staged/console.exe staged/gui.exe
        staged/reference/manifest.sha256 staged/reference/markdown/page.md
    } {
        spec_tracks package [file join $::fixtureRoot {*}[split $relative /]]
    }
    foreach relative {
        prefix/bin/tclsh90s.exe prefix/bin/wish90s.exe prefix/lib/tcl9.0/init.tcl
        prefix/lib/tcl9/9.0/msgcat.tm prefix/lib/tk9.0/tk.tcl
    } {
        spec_tracks package [file join $::fixtureCache {*}[split $relative /]]
    }

    # The incremental build keys on this byte-level toolchain fingerprint. Use
    # a tiny fake MSYS tree to verify transitive input selection without
    # reading or altering the real toolchain and without invoking a compiler.
    set toolchainRoot [file join $work fake-msys]
    set toolchainFiles {
        ucrt64/include/windows.h
        ucrt64/lib/gcc/x86_64-w64-mingw32/16.1.0/include/stddef.h
        ucrt64/lib/gcc/x86_64-w64-mingw32/16.1.0/libgcc.a
        ucrt64/libexec/gcc/x86_64-w64-mingw32/16.1.0/cc1.exe
        ucrt64/x86_64-w64-mingw32/bin/ld.exe
        ucrt64/lib/libucrt.a ucrt64/bin/libwinpthread-1.dll
        ucrt64/bin/gcc.exe ucrt64/bin/cpp.exe ucrt64/bin/as.exe
        ucrt64/bin/ld.exe ucrt64/bin/ar.exe ucrt64/bin/ranlib.exe
        ucrt64/bin/strip.exe ucrt64/bin/windres.exe ucrt64/bin/mingw32-make.exe
        usr/bin/bash.exe usr/bin/sed.exe usr/bin/awk.exe usr/bin/make.exe
        usr/bin/zip.exe usr/bin/msys-2.0.dll
    }
    foreach relative $toolchainFiles {
        write_bytes [file join $toolchainRoot {*}[split $relative /]] "fixture:$relative"
    }
    set unrelatedPython [file join $toolchainRoot ucrt64 lib python3 site-packages arbitrary.py]
    write_bytes $unrelatedPython unrelated-python
    foreach relative $toolchainFiles { toolchain_tracks $toolchainRoot $relative }
    set before [::machteld::devcache::toolchain_digest $toolchainRoot]
    write_bytes $unrelatedPython modified-python
    check {unrelated nested Python library changes do not invalidate the C toolchain} \
        [expr {$before eq [::machteld::devcache::toolchain_digest $toolchainRoot]}]
    set extraHeader [file join $toolchainRoot ucrt64 include added.h]
    write_bytes $extraHeader added-system-header
    set added [::machteld::devcache::toolchain_digest $toolchainRoot]
    check {shared toolchain detects newly added system headers} [expr {$before ne $added}]
    set renamedHeader [file join $toolchainRoot ucrt64 include renamed.h]
    file rename $extraHeader $renamedHeader
    check {shared toolchain detects renamed system headers} \
        [expr {$added ne [::machteld::devcache::toolchain_digest $toolchainRoot]}]
    file delete $renamedHeader
    check {shared toolchain detects deleted system headers} \
        [expr {$before eq [::machteld::devcache::toolchain_digest $toolchainRoot]}]
    set extraLibrary [file join $toolchainRoot ucrt64 lib new-import.a]
    write_bytes $extraLibrary new-import-library
    check {shared toolchain detects added import libraries} \
        [expr {$before ne [::machteld::devcache::toolchain_digest $toolchainRoot]}]
    file delete $extraLibrary
    set hiddenBootstrapTool [file join $toolchainRoot usr bin .hidden-bootstrap]
    write_bytes $hiddenBootstrapTool hidden-bootstrap-input
    check {shared toolchain includes hidden bootstrap inputs} \
        [expr {$before ne [::machteld::devcache::toolchain_digest $toolchainRoot]}]
    file delete $hiddenBootstrapTool

    # Source the real development coordinator in an isolated interpreter and
    # repository. No build is requested; fake tools/prefix satisfy discovery.
    # Edit the copied scripts after startup, never the working source files.
    # A child interpreter has no runtime package of its own: it is given this
    # runtime's version and the commands the coordinator's helpers call.
    set startupRoot [file join $work coordinator-fixture]
    set recipes {dev.tcl buildlib.tcl devcache.tcl bootstrap.tcl}
    foreach name $recipes {
        write_bytes [file join $startupRoot tools $name] \
            [read_bytes [file join $repo tools $name]]
    }
    foreach relative {
        prefix/lib/libtcl90.a prefix/lib/libtcl9tk90.a prefix/lib/libtclstub.a
        sqlite/sqlite3.c yyjson/yyjson.c
    } {
        write_bytes [file join $::fixtureCache {*}[split $relative /]] "fixture:$relative"
    }
    set startupEnvNames {MSYS2_ROOT MACHTELD_DEPS_ROOT PATH}
    set savedStartupEnv {}
    foreach name $startupEnvNames {
        if {[info exists ::env($name)]} { dict set savedStartupEnv $name $::env($name) }
    }
    set startup [interp create]
    try {
        set ::env(MSYS2_ROOT) $toolchainRoot
        set ::env(MACHTELD_DEPS_ROOT) $::fixtureCache
        interp eval $startup [list package provide machteld [package require machteld]]
        interp eval $startup {namespace eval ::machteld {}}
        foreach command {hash links mtps run json Publish} {
            interp alias $startup ::machteld::$command {} ::machteld::$command
        }
        interp eval $startup [list set argv0 [file join $startupRoot tools dev.tcl]]
        interp eval $startup {set argv {}}
        interp eval $startup [list source [file join $startupRoot tools dev.tcl]]
        set loaded [interp eval $startup {set ::LOADED_RECIPES}]
        set coordinator [file join $startupRoot tools dev.tcl]
        check {development startup captures the main coordinator bytes} \
            [expr {[dict exists $loaded $coordinator] && \
                [dict get $loaded $coordinator] eq [read_bytes $coordinator]}]
        check {unchanged loaded recipes pass startup verification} \
            [expr {![catch {interp eval $startup verify_loaded_recipes}]}]
        # Exercise the real coordinator's three native entry points without
        # compiling against this deliberately fake dependency installation.
        interp eval $startup {
            set ::nativePaths {}
            rename run {}
            proc run args { lappend ::nativePaths $::env(PATH) }
            rename ::machteld::build::version_resource {}
            proc ::machteld::build::version_resource args { lappend ::nativePaths $::env(PATH) }
            rename ::machteld::build::link_host {}
            proc ::machteld::build::link_host args { lappend ::nativePaths $::env(PATH) }
            set ::inheritedPath $::env(PATH)
            compile_candidate source.c {-O2} fixture candidate.o
            resource_candidate console candidate.o
            link_candidate console main.o resource.o objects sqlite.o yyjson.o candidate.exe
        }
        set nativePaths [interp eval $startup {set ::nativePaths}]
        set expectedNativePath [interp eval $startup {
            dict get [::machteld::devcache::native_environment $::MSYS2] PATH
        }]
        check {compile, resource and link entry points apply the keyed native PATH} \
            [expr {$nativePaths eq [lrepeat 3 $expectedNativePath]}]
        check {native entry points preserve caller PATH for other build stages} \
            [interp eval $startup {expr {$::env(PATH) eq $::inheritedPath}}]
        foreach name $recipes {
            set path [file join $startupRoot tools $name]
            set bytes [read_bytes $path]
            set time [file mtime $path]
            write_bytes $path "${bytes}\n# edited after coordinator startup\n"
            file mtime $path $time
            set rejected [catch {interp eval $startup verify_loaded_recipes} message]
            check "loaded $name changes are rejected even with preserved mtime" \
                [expr {$rejected && [string match {*build recipe changed after loading*} $message]}] $message
            write_bytes $path $bytes
            file mtime $path $time
        }
        check {restoring loaded recipe bytes restores verification} \
            [expr {![catch {interp eval $startup verify_loaded_recipes}]}]
    } finally {
        interp delete $startup
        foreach name $startupEnvNames {
            if {[dict exists $savedStartupEnv $name]} { set ::env($name) [dict get $savedStartupEnv $name] } \
            else { unset -nocomplain ::env($name) }
        }
    }

    # The real pinned MSYS2, found as tools/bootstrap.tcl finds it, for the
    # constrained native PATH and the tiny native products below.
    set realMsys [::boot::msysRoot $msysRequested]
    if {![file isfile [file join $realMsys ucrt64 bin gcc.exe]]} {
        error "native environment checks require the configured MSYS2 gcc"
    }

    # Compiler lookup must be constrained in execution, not merely omitted
    # from a cache key. Real tiny compiler/resource/link products verify that
    # this PATH is sufficient, even with executable impostors in caller PATH.
    set nativeEnvNames {PATH SOURCE_DATE_EPOCH MACHTELD_WERROR}
    set savedNativeEnv {}
    foreach name $nativeEnvNames {
        if {[info exists ::env($name)]} { dict set savedNativeEnv $name $::env($name) }
    }
    try {
        unset -nocomplain ::env(SOURCE_DATE_EPOCH) ::env(MACHTELD_WERROR)
        set ::env(PATH) "[file nativename [file join $work codex-arg0-first]];$::env(PATH)"
        set firstInherited [::machteld::devcache::compiler_environment]
        set firstNative [::machteld::devcache::native_environment $realMsys]
        set nativeKey [::machteld::devcache::fingerprint [dict create values $firstNative]]
        set ::env(PATH) "[file nativename [file join $work codex-arg0-second]];$::env(PATH)"
        check {ephemeral caller PATH changes do not invalidate native keys} \
            [expr {$nativeKey eq [::machteld::devcache::fingerprint [dict create values \
                [::machteld::devcache::native_environment $realMsys]]]}]
        check {full inherited PATH remains visible to the build guard} \
            [expr {$firstInherited ne [::machteld::devcache::compiler_environment]}]
        set nativeParts [split [dict get $firstNative PATH] {;}]
        check {native PATH has only pinned tools and Windows directories} \
            [expr {$nativeParts eq [list \
                [file nativename [file normalize [file join $realMsys ucrt64 bin]]] \
                [file nativename [file normalize [file join $::env(SystemRoot) System32]]] \
                [file nativename [file normalize $::env(SystemRoot)]]]}]
        foreach name {SOURCE_DATE_EPOCH MACHTELD_WERROR} value {946684800 0} {
            set ::env($name) $value
            check "native key still tracks $name" \
                [expr {$nativeKey ne [::machteld::devcache::fingerprint [dict create values \
                    [::machteld::devcache::native_environment $realMsys]]]}]
            unset ::env($name)
        }
        set callerNativePath $::env(PATH)
        set result [::machteld::devcache::with_native_environment $realMsys {
            set actualNativePath $::env(PATH)
            set callerScopeResult success
        }]
        check {native wrapper applies the fingerprinted PATH in caller scope} \
            [expr {$actualNativePath eq [dict get $firstNative PATH] && $result eq "success" &&
                $callerScopeResult eq "success"}]
        check {successful native wrapper restores caller PATH} \
            [expr {$::env(PATH) eq $callerNativePath}]
        set failed [catch {::machteld::devcache::with_native_environment $realMsys {
            return -code error -errorcode {TEST NATIVE PATH} expected-native-failure
        }} result options]
        check {failed native wrapper preserves error and restores caller PATH} \
            [expr {$failed && $result eq "expected-native-failure" &&
                [dict get $options -errorcode] eq {TEST NATIVE PATH} &&
                $::env(PATH) eq $callerNativePath}]
        unset ::env(PATH)
        check {absent caller PATH uses the same native key} \
            [expr {$nativeKey eq [::machteld::devcache::fingerprint [dict create values \
                [::machteld::devcache::native_environment $realMsys]]]}]
        ::machteld::devcache::with_native_environment $realMsys {set applied $::env(PATH)}
        check {native wrapper restores an initially absent PATH} \
            [expr {![info exists ::env(PATH)] && $applied eq [dict get $firstNative PATH]}]
        set ::env(PATH) $callerNativePath

        set nativeDir [file join $work {native tools with spaces}]
        set fakeDir [file join $nativeDir fake-tools]
        file mkdir $fakeDir
        set gcc [file join $realMsys ucrt64 bin gcc.exe]
        set windres [file join $realMsys ucrt64 bin windres.exe]
        set strip [file join $realMsys ucrt64 bin strip.exe]
        set fakeSource [file join $nativeDir impostor.c]
        set fakeExe [file join $fakeDir gcc.exe]
        write_bytes $fakeSource {int main(void) { return 97; }}
        ::machteld::devcache::with_native_environment $realMsys {
            exec $gcc $fakeSource -o $fakeExe 2>@1
        }
        file copy $fakeExe [file join $fakeDir as.exe]
        set ::env(PATH) "[file nativename $fakeDir];$callerNativePath"
        foreach tool {gcc.exe as.exe} {
            set failed [catch {exec $tool --version 2>@1} result options]
            check "negative control: caller PATH reaches external $tool" \
                [expr {$failed && [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS" &&
                    [lindex [dict get $options -errorcode] 2] == 97}] $result
            set failed [catch {::machteld::devcache::with_native_environment $realMsys {
                exec $tool --version 2>@1
            }} result]
            check "native PATH excludes external $tool" \
                [expr {!$failed && [regexp {gcc\.exe|GNU assembler} $result]}] $result
        }
        set tinySource [file join $nativeDir tiny.c]
        set tinyObject [file join $nativeDir tiny.o]
        set tinyExe [file join $nativeDir tiny.exe]
        set tinyRc [file join $nativeDir tiny.rc]
        set tinyResource [file join $nativeDir tiny-resource.o]
        write_bytes $tinySource {int main(void) { return 0; }}
        write_bytes $tinyRc {1 RCDATA { 42 }}
        set failed [catch {::machteld::devcache::with_native_environment $realMsys {
            exec $gcc -c $tinySource -o $tinyObject 2>@1
            exec $windres --codepage=65001 -O coff -i $tinyRc -o $tinyResource 2>@1
            exec $gcc $tinyObject $tinyResource -o $tinyExe 2>@1
            exec $strip $tinyExe 2>@1
            exec $tinyExe 2>@1
        }} result]
        check {pinned compile, resource, link and strip work with constrained PATH} \
            [expr {!$failed && [file isfile $tinyObject] && [file isfile $tinyResource] &&
                [file isfile $tinyExe]}] $result
        check {real native subprocesses preserve the caller PATH with impostors} \
            [expr {$::env(PATH) eq "[file nativename $fakeDir];$callerNativePath"}]
    } finally {
        foreach name $nativeEnvNames {
            if {[dict exists $savedNativeEnv $name]} { set ::env($name) [dict get $savedNativeEnv $name] } \
            else { unset -nocomplain ::env($name) }
        }
    }

    # External include/library search overrides cannot be safely represented by
    # their strings alone. Production rejects those untracked inputs explicitly.
    set compilerNames {CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH
        TCL_LIBRARY TCLLIBPATH TCL9_0_TM_PATH TCL9_TM_PATH TCL_TM_PATH TCL9.0_TM_PATH TCL99_TM_PATH TK_LIBRARY
        CFLAGS CPP CPPFLAGS CXXFLAGS LDFLAGS LIBS ARFLAGS RCFLAGS
        MAKEFLAGS MAKEFILES MAKEOVERRIDES MFLAGS GNUMAKEFLAGS
        BASH_ENV ENV BASHOPTS SHELLOPTS CONFIG_SITE BASH_FUNC_cache_fixture%%}
    set savedCompilerEnv {}
    foreach name $compilerNames {
        if {[info exists ::env($name)]} { dict set savedCompilerEnv $name $::env($name) }
        unset -nocomplain ::env($name)
    }
    try {
        check {ordinary compiler environment is accepted} \
            [expr {![catch {::machteld::devcache::compiler_environment}]}]
        foreach name $compilerNames {
            set ::env($name) [file join $work external-search]
            set rejected [catch {::machteld::devcache::compiler_environment} message]
            check "untracked $name override is refused" \
                [expr {$rejected && [string match "*unset $name*" $message]}] $message
            unset ::env($name)
        }
        # The actual bootstrap refuses the same variables before any work on
        # its cache, in every mode: this one is never read or written.
        set rejectedCache [file join $work environment-rejected-cache]
        write_bytes [file join $rejectedCache sentinel] must-remain-unchanged
        foreach name {CPATH CFLAGS MAKEFLAGS MAKEFILES BASH_ENV ENV CONFIG_SITE BASH_FUNC_cache_fixture%% TCL9.0_TM_PATH} {
            set result [run -timeout 5m -env [list $name [file join $work external-search]] -- \
                [info nameofexecutable] [file join $repo tools bootstrap.tcl] \
                --cache $rejectedCache --msys $realMsys --verify-only]
            set message [encoding convertfrom utf-8 [dict get $result err]][encoding convertfrom utf-8 [dict get $result out]]
            check "actual bootstrap rejects untracked $name before cache work" \
                [expr {[dict get $result exit] != 0 &&
                    [string match "*unset $name for a tracked Machteld bootstrap*" $message]}] $message
        }
        check {bootstrap environment refusal preserves every cache input} \
            [expr {[fixture_entries $rejectedCache] eq {sentinel must-remain-unchanged}}]
    } finally {
        foreach name $compilerNames {
            if {[dict exists $savedCompilerEnv $name]} { set ::env($name) [dict get $savedCompilerEnv $name] } \
            else { unset -nocomplain ::env($name) }
        }
    }

    # The production bash launch (::boot::msysCommand), run on a tiny script
    # that starts through its own `#!/usr/bin/env bash` line, while the caller's
    # PATH is System32 alone: the launch names its own PATH, and its step
    # travels in the environment, so every word arrives whole.
    set shellDir [file join $work "bootstrap source Ω"]
    set shellFixture [file join $shellDir {fixture with spaces.sh}]
    write_bytes $shellFixture [encoding convertto utf-8 "#!/usr/bin/env bash\nset -euo pipefail\nprintf '<%s>\\n' \"\$@\"\n"]
    set shellUnix [::boot::unixPath $realMsys $shellFixture]
    set shellHome [file join $work {bootstrap home}]
    file mkdir $shellHome
    set sourceArgument "/source path/Ω"
    set prefixArgument "/prefix with 'apostrophe'/α"
    set probe {printf '%s\n' "$MSYSTEM" "$CHERE_INVOKING" "$CONFIG_SITE" "$LC_ALL" "$LANG" "$TZ" "$CC" "$HOME" "$PWD" "${MACHTELD_BOOTSTRAP_STEP-unset}" "$PATH"}
    set pathPresent [info exists ::env(PATH)]
    if {$pathPresent} { set savedPath $::env(PATH) }
    try {
        set ::env(PATH) [file nativename [file join $::env(SystemRoot) System32]]
        set launch [run -timeout 2m {*}[::boot::msysCommand $realMsys $shellHome $shellDir \
            "[::boot::shq $shellUnix] [::boot::shq $sourceArgument] [::boot::shq $prefixArgument] 3"]]
        set seen [run -timeout 2m {*}[::boot::msysCommand $realMsys $shellHome $shellDir $probe]]
        # Red/green: the launch that failed, the script started by name from a
        # -c line. Its words carry no apostrophe, so what fails is the #! line.
        set old [run -timeout 2m -- [file join $realMsys usr bin bash.exe] --noprofile --norc -c \
            "[::boot::shq $shellUnix] [::boot::shq /plain-source] [::boot::shq /plain-prefix] 3"]
    } finally {
        if {$pathPresent} { set ::env(PATH) $savedPath } else { unset -nocomplain ::env(PATH) }
    }
    set launchText [encoding convertfrom utf-8 [dict get $launch err]][encoding convertfrom utf-8 [dict get $launch out]]
    check {production bootstrap bash launch works with a System32-only caller PATH} \
        [expr {[dict get $launch status] eq "ok" && [dict get $launch exit] == 0}] $launchText
    check {bootstrap bash launch preserves spaces, Unicode, apostrophes and the job count} \
        [expr {[encoding convertfrom utf-8 [dict get $launch out]] eq "<$sourceArgument>\n<$prefixArgument>\n<3>\n"}] $launchText
    set seenLines [split [string trimright [encoding convertfrom utf-8 [dict get $seen out]] \n] \n]
    check {bootstrap bash step runs in the named environment, its own text not exported} \
        [expr {[dict get $seen exit] == 0 &&
            [lrange $seenLines 0 6] eq {UCRT64 1 /dev/null C C UTC gcc} &&
            [lindex $seenLines 7] eq [::boot::unixPath $realMsys $shellHome] &&
            [lindex $seenLines 8] eq [::boot::unixPath $realMsys $shellDir] &&
            [lindex $seenLines 9] eq "unset" &&
            [string match /ucrt64/bin:/usr/bin:/* [lindex $seenLines 10]] &&
            [llength [split [lindex $seenLines 10] :]] == 4}] $seenLines
    set oldText [encoding convertfrom utf-8 [dict get $old err]][encoding convertfrom utf-8 [dict get $old out]]
    check {former indirect bash launch fails at its env shebang under a System32-only PATH} \
        [expr {[dict get $old exit] != 0 && [string match {*env*bash*} $oldText]}] $oldText

    # Exercise the actual bootstrap verifier in its read-only mode. A stale
    # dependency state must fail, never bootstrap or consume an unverified prefix.
    set staleCache [file join $work stale-dependency-cache]
    write_bytes [file join $staleCache lock.sha256] [string repeat 0 64]
    set staleBefore [fixture_entries $staleCache]
    set result [run -timeout 5m -- [info nameofexecutable] [file join $repo tools bootstrap.tcl] \
        --cache $staleCache --msys $realMsys --verify-only]
    set failed [expr {[dict get $result exit] != 0}]
    set message [encoding convertfrom utf-8 [dict get $result err]][encoding convertfrom utf-8 [dict get $result out]]
    check {production bootstrap verification refuses a stale dependency lock} \
        [expr {$failed && [string match {*dependency cache is absent or stale*} $message]}] $message
    check {verify-only refusal does not mutate the dependency cache} \
        [expr {$staleBefore eq [fixture_entries $staleCache]}]
} finally {
    # Only the invocation-owned child of the exact tempfile marker is removed.
    if {[file normalize $work] eq [file normalize "${claim}.d"] && \
            [file dirname $work] eq [file dirname [file normalize $claim]] && \
            [file exists $claim]} {
        file delete -force $work
        file delete $claim
    }
}
if {$fails} { error "$fails of $checks dev cache checks failed" }
puts "ALL $checks DEV CACHE CHECKS PASSED"
