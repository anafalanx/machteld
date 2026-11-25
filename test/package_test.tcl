package require machteld 0.21

# test/package_test.tcl -- tools/package.tcl refuses every incomplete input
# without leaving a partial output or work debris, packages exactly the
# allowlisted notices and the reference pack byte for byte, and never replaces
# a candidate; ::release::publish puts a candidate under its requested name
# beside it and nowhere else.
#
#     machteld.exe test/package_test.tcl --tclsh EXE
#     machteld.exe test/package_test.tcl --build-runtime
#
# EXE is the static tclsh90s package.tcl runs on. The Tcl port (2026-10-28)
# of test/package_test.ps1 and test/build_publication_test.ps1. Not checked:
# that the package lacks FILE_ATTRIBUTE_TEMPORARY, which Tcl cannot read.

namespace eval ::pt {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable failures 0
    variable work ""
    variable packager {}
    variable wrapper ""
}
if {[lindex $argv 0] eq "--run-packager"} {
    set argv [lrange $argv 1 end]
    source -encoding utf-8 [file join $::pt::root tools package.tcl]
    exit 0
}
source -encoding utf-8 [file join $::pt::root tools release.tcl]

proc ::pt::check {name condition {detail ""}} {
    variable failures
    if {$condition} {
        puts "ok   $name"
    } else {
        incr failures
        puts "FAIL $name $detail"
    }
}

proc ::pt::writeText {path text} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel [encoding convertto utf-8 $text]
    close $channel
}

proc ::pt::readBytes {path} {
    set channel [open $path rb]
    try {
        return [read $channel]
    } finally {
        close $channel
    }
}

proc ::pt::uniqueName {prefix} {
    return $prefix[binary encode hex [hash random 16]]
}

proc ::pt::runPackage {args} {
    return [runPackageInZone UTC0 {*}$args]
}

proc ::pt::runPackageInZone {zone args} {
    variable packager
    set result [run -timeout 5m -env [dict create TZ $zone] -- {*}$packager {*}$args]
    dict create exit [dict get $result exit] text \
        [encoding convertfrom -profile replace utf-8 [dict get $result out][dict get $result err]]
}

proc ::pt::refused {result pattern} {
    expr {[dict get $result exit] != 0 && [regexp -nocase -- $pattern [dict get $result text]]}
}

# The package's own work paths beside the output; there must be none after
# any run, failed or not.
proc ::pt::noWorkPaths {} {
    variable work
    expr {![llength [glob -nocomplain -types {f d hidden} -directory $work .machteld-package-*]] &&
          ![llength [glob -nocomplain -directory $work .machteld-package-*]]}
}

proc ::pt::packageTests {} {
    variable root
    variable work
    variable wrapper
    set licenseHashes {
        Tcl-9.0.4.txt c0a69a2bfd757361ec7e6143973b103c90409316b49e9c88db26ad6388e79f16
        Tk-9.0.4.txt 2cde822b93ca16ae535c954b7dfe658b4ad10df2a193628d1b358f1765e8b198
        zlib-1.3.2.txt e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2
        LibTomMath-1.3.0.txt 2fa64b163659f41965c9815882a8296d3d03ff546b76153e11445f9bdecf955a
        yyjson-0.12.0.txt 45e384d3d52c73cba3a64d6e6c25d47cd738cd8a55c30629e3201046eda62947
        cffi-2.0.3.txt cdff44ed75ce0f7c9625165bdb86cc4221fab9479eeda359f9d8268db2a9591d
        tclh-6afd306.txt 5f1172dc3b77b33f1e856cf7a6f9fafa427e914e3e1b2e300ca1eb766d4e1c76
        graphviz-16.1.2.txt 0becf16567beb77fa252b7664631dd177c8f9a1889e48995b45379c7130e5303
        graphviz-ellipse.txt 133e194718ad2183f397682ca271ff088de745d6859c524483e1c743f1b992cd
        expat-2.8.1.txt 31b15de82aa19a845156169a17a5488bf597e561b2c318d159ed583139b25e87
        libffi-3.5.2.txt d5699fa516968e3a1550e6c902b7441c78856f2603d61bedd0b0662a26655366
        xxHash-0.8.3.txt 6ffedbc0f7878612d2b23589f1ff2ab15633e1df7963a5d9fc750ec5500c7e7a
        Els-MIT.txt 6ecd1d4f5394b996f18f4c8710b78a20483cfcaa442c27b407049bc055a6c8ac
        Ann-MIT.txt 6ecd1d4f5394b996f18f4c8710b78a20483cfcaa442c27b407049bc055a6c8ac
    }

    set result [runPackage --unknown value]
    check "package parser rejects unknown options" [refused $result {unknown option}] [dict get $result text]
    set result [runPackage --prefix]
    check "package parser rejects missing option values" [refused $result {needs a value}] [dict get $result text]

    set licenses [file join $root licenses]
    dict for {notice expected} $licenseHashes {
        set actual [hash file sha256 [file join $licenses $notice]]
        check "tracked $notice notice is verbatim" [expr {$actual eq $expected}] $actual
    }

    set prefix [file join $work prefix]
    set tclLibrary [file join $prefix lib tcl9.0]
    set tclModules [file join $prefix lib tcl9 9.0]
    writeText [file join $tclLibrary init.tcl] "set ::fixture_tcl 1"
    foreach name {clock.tcl package.tcl tm.tcl} {
        writeText [file join $tclLibrary $name] "# fixture $name"
    }
    writeText [file join $tclLibrary tclIndex] "# Tcl autoload index file, version 2.0\n"
    writeText [file join $tclLibrary encoding cp1252.enc] "fixture encoding"
    writeText [file join $tclLibrary msgs nl.msg] "fixture catalog"
    writeText [file join $tclLibrary tzdata Europe Brussels] "fixture timezone"
    writeText [file join $prefix lib tk9.0 tk.tcl] "set ::fixture_tk 1"
    set prelude [file join $work machteld.tcl]
    writeText $prelude "set ::fixture_prelude 1"
    set reference [file join $work reference]
    foreach name {catalog.dict catalog.json search.dict manifest.sha256 schema.json START-HERE.md AGENTS.md} {
        writeText [file join $reference $name] "fixture $name\n"
    }
    writeText [file join $reference markdown machteld agent.md] "# Fixture agent reference\n"
    set apache [file join $root LICENSE]
    set common [list --prefix $prefix --prelude $prelude --wrapper $wrapper]

    # A collision in the output directory verifies the packager actually uses
    # a sibling path. Windows may silently ignore the directory of file tempfile.
    set id [binary encode hex [hash random 16]]
    set requested [file join $work .machteld-build-$id.exe]
    set sibling [file join $work .machteld-package-$id.candidate]
    writeText $sibling "owned by another operation"
    set r [runPackage {*}$common --licenses $licenses --apache-license $apache --reference $reference --out $requested]
    check "packaging reserves its candidate in the output directory and preserves a competing file" [expr {
        [dict get $r exit] != 0 && ![file exists $requested] && [readBytes $sibling] eq "owned by another operation"}]
    file delete $sibling

    set existing [file join $work [uniqueName .machteld-build-].exe]
    writeText $existing prior-release
    set result [runPackage {*}$common --licenses $licenses --apache-license $apache --reference $reference --out $existing]
    check "packaging refuses to replace an existing output" \
        [expr {[refused $result {output already exists}] && [readBytes $existing] eq "prior-release"}] [dict get $result text]
    check "existing-output refusal creates no work paths" [noWorkPaths]

    set out [file join $work [uniqueName .machteld-build-].exe]
    set result [runPackage --prefix $prefix --prelude [file join $work missing.tcl] --wrapper $wrapper \
        --licenses $licenses --apache-license $apache --reference $reference --out $out]
    check "failed packaging does not publish a partial output" \
        [expr {[dict get $result exit] != 0 && ![file exists $out]}] [dict get $result text]
    check "failed packaging removes only its unique work paths" [noWorkPaths]

    set result [runPackage {*}$common --licenses $licenses --apache-license $apache --reference $reference --out $out]
    check "packaging refuses a missing Tcl module tree" \
        [expr {[refused $result {Tcl module tree not found}] && ![file exists $out]}] [dict get $result text]
    check "missing-module failure cleans its unique work paths" [noWorkPaths]

    writeText [file join $tclModules msgcat-1.7.1.tm] "package provide msgcat 1.7.1"

    set result [runPackage {*}$common --licenses [file join $work missing-licenses] --apache-license $apache \
        --reference $reference --out $out]
    check "packaging refuses missing distribution notices" \
        [expr {[refused $result {license notice directory not found}] && ![file exists $out]}] [dict get $result text]

    foreach missing [dict keys $licenseHashes] {
        set incomplete [file join $work incomplete-licenses-[file rootname $missing]]
        file mkdir $incomplete
        foreach notice [dict keys $licenseHashes] {
            if {$notice ne $missing} {
                file copy [file join $licenses $notice] $incomplete
            }
        }
        set missingOut [file join $work [uniqueName .machteld-build-].exe]
        set result [runPackage {*}$common --licenses $incomplete --apache-license $apache \
            --reference $reference --out $missingOut]
        check "packaging refuses a missing $missing notice" \
            [expr {[dict get $result exit] != 0 &&
                   [string first "required license notice not found: $missing" [dict get $result text]] >= 0 &&
                   ![file exists $missingOut]}] [dict get $result text]
    }

    set result [runPackage {*}$common --licenses $licenses --apache-license [file join $work missing-apache.txt] \
        --reference $reference --out $out]
    check "packaging refuses a missing Apache license" \
        [expr {[refused $result {Apache 2.0 license not found}] && ![file exists $out]}] [dict get $result text]

    set result [runPackage {*}$common --licenses $licenses --apache-license $apache \
        --reference [file join $work missing-reference] --out $out]
    check "packaging refuses a missing reference pack" \
        [expr {[refused $result {reference pack directory not found}] && ![file exists $out]}] [dict get $result text]

    set incompleteReference [file join $work incomplete-reference]
    writeText [file join $incompleteReference catalog.dict] fixture
    set result [runPackage {*}$common --licenses $licenses --apache-license $apache \
        --reference $incompleteReference --out $out]
    check "packaging refuses an incomplete reference pack" \
        [expr {[refused $result {reference pack is incomplete}] && ![file exists $out]}] [dict get $result text]

    file delete [file join $reference catalog.json]
    set result [runPackage {*}$common --licenses $licenses --apache-license $apache --reference $reference --out $out]
    writeText [file join $reference catalog.json] "fixture catalog.json\n"
    check "packaging refuses a reference pack without its agent JSON catalog" \
        [expr {[refused $result {reference pack is incomplete: catalog\.json}] && ![file exists $out]}] [dict get $result text]

    set packagingLicenses [file join $work licenses-with-untracked-sentinel]
    file mkdir $packagingLicenses
    foreach notice [dict keys $licenseHashes] {
        file copy [file join $licenses $notice] $packagingLicenses
    }
    writeText [file join $packagingLicenses UNTRACKED-SENTINEL.txt] "must not enter the package"
    set result [runPackage {*}$common --licenses $packagingLicenses --apache-license $apache --reference $reference --out $out]
    check "successful packaging publishes only after lmkimg succeeds" \
        [expr {[dict get $result exit] == 0 && [file size $out] > 1048576 &&
               [string range [readBytes $out] 0 1] eq "MZ"}] [dict get $result text]
    check "successful packaging leaves no staging or candidate paths" [noWorkPaths]
    set problem [validatePackage $out $apache $licenses $reference]
    check "packaged image carries complete runtime and byte-identical reference payloads" \
        [expr {$problem eq ""}] $problem

    set packaged [hash file sha256 $out]
    # A new checkout can give identical input different mtimes. Read-only
    # files must stay read-only at their source when the packager stages them.
    set later 1285714800
    file mtime $prelude $later
    file attributes $prelude -readonly 1
    set rebuilt [file join $work [uniqueName .machteld-build-].exe]
    set result [runPackageInZone PST8PDT {*}$common --licenses $packagingLicenses \
        --apache-license $apache --reference $reference --out $rebuilt]
    check "identical package bytes across source timestamps and build time zones" \
        [expr {[dict get $result exit] == 0 && [hash file sha256 $rebuilt] eq $packaged}] [dict get $result text]
    check "packaging preserves input timestamps and read-only attributes" \
        [expr {[file mtime $prelude] == $later && [file attributes $prelude -readonly]}]
    file attributes $prelude -readonly 0
    set result [runPackage {*}$common --licenses $licenses --apache-license $apache --reference $reference --out $out]
    check "a packaged candidate cannot be reused or replaced" \
        [expr {[refused $result {output already exists}] && [hash file sha256 $out] eq $packaged}] [dict get $result text]
    check "existing-candidate refusal leaves no unique work paths" [noWorkPaths]
}

# Mounts the image and compares its payload with the sources; returns the
# first problem, or "" when there is none.
proc ::pt::validatePackage {image apache licenses reference} {
    set mount package-test-[pid]
    zipfs mount $image $mount
    try {
        set base //zipfs:/$mount
        foreach relative {
            tcl_library/init.tcl tcl_library/clock.tcl tcl_library/package.tcl tcl_library/tm.tcl
            tcl_library/tclIndex tcl_library/encoding/cp1252.enc tcl_library/msgs/nl.msg
            tcl_library/machteld-job/pkgIndex.tcl tcl_library/machteld-job/job.tcl tcl_library/cffi/pkgIndex.tcl
            tcl_library/tzdata/Europe/Brussels tcl9/9.0/msgcat-1.7.1.tm tk_library/tk.tcl
            licenses/Apache-2.0.txt licenses/Tcl-9.0.4.txt licenses/Tk-9.0.4.txt licenses/zlib-1.3.2.txt
            licenses/LibTomMath-1.3.0.txt licenses/yyjson-0.12.0.txt
            licenses/xxHash-0.8.3.txt licenses/cffi-2.0.3.txt licenses/libffi-3.5.2.txt licenses/tclh-6afd306.txt
            licenses/graphviz-16.1.2.txt licenses/graphviz-ellipse.txt licenses/expat-2.8.1.txt
            licenses/Els-MIT.txt
            licenses/Ann-MIT.txt
            reference/catalog.dict reference/catalog.json reference/search.dict reference/manifest.sha256
            reference/schema.json reference/START-HERE.md reference/AGENTS.md reference/markdown/machteld/agent.md
        } {
            if {![file isfile $base/$relative]} {
                return "packaged runtime file is missing: $relative"
            }
        }
        if {[readBytes $base/licenses/Apache-2.0.txt] ne [readBytes $apache]} {
            return "packaged Apache license is not the tracked LICENSE"
        }
        if {[file exists $base/licenses/UNTRACKED-SENTINEL.txt]} {
            return "packaging copied a notice outside its explicit allowlist"
        }
        foreach notice {Tcl-9.0.4.txt Tk-9.0.4.txt zlib-1.3.2.txt LibTomMath-1.3.0.txt yyjson-0.12.0.txt xxHash-0.8.3.txt cffi-2.0.3.txt libffi-3.5.2.txt tclh-6afd306.txt graphviz-16.1.2.txt graphviz-ellipse.txt expat-2.8.1.txt Els-MIT.txt Ann-MIT.txt} {
            if {[readBytes $base/licenses/$notice] ne [readBytes [file join $licenses $notice]]} {
                return "packaging changed license bytes: $notice"
            }
        }
        foreach relative {
            catalog.dict catalog.json search.dict manifest.sha256 schema.json START-HERE.md
            AGENTS.md markdown/machteld/agent.md
        } {
            if {[readBytes $base/reference/$relative] ne [readBytes [file join $reference {*}[split $relative /]]]} {
                return "packaging changed reference bytes: $relative"
            }
        }
        set savedPath $::auto_path
        try {
            set ::auto_path [list $base/tcl_library [info library]]
            set version [package require -exact machteld::job 1.0]
            set script [lindex [package ifneeded machteld::job $version] end]
            if {$script ne "$base/tcl_library/machteld-job/job.tcl"} {
                return "background job loaded from outside the packaged image: $script"
            }
            set job [::machteld::job::Job new]
            try {
                if {[dict get [$job snapshot] phase] ne "idle"} {
                    return "packaged background job did not start idle"
                }
            } finally { $job destroy }
        } finally { set ::auto_path $savedPath }
        return ""
    } finally {
        zipfs unmount $mount
    }
}

proc ::pt::publish {candidate output} {
    if {[catch {::release::publish $candidate $output} problem]} {
        return $problem
    }
    return ""
}

proc ::pt::candidate {parent text} {
    set path [file join $parent [uniqueName .machteld-build-].exe]
    writeText $path $text
    return $path
}

proc ::pt::publicationTests {} {
    variable root
    variable work
    # Its own folder: the package tests leave their fixture candidates.
    set folder [file join $work publication]
    file mkdir $folder
    set output [file join $folder released.exe]
    set candidate [candidate $folder "first release"]
    set problem [publish $candidate $output]
    check "publication creates an absent output" \
        [expr {$problem eq "" && ![file exists $candidate] && [readBytes $output] eq "first release"}] $problem

    set candidate [candidate $folder "replacement release"]
    set problem [publish $candidate $output]
    check "publication replaces an existing output" \
        [expr {$problem eq "" && ![file exists $candidate] && [readBytes $output] eq "replacement release"}] $problem

    # A Tcl channel shares neither delete nor rename, so holding the output
    # open refuses the replacement; two attempts keep the test short.
    set candidate [candidate $folder "locked replacement"]
    set held [open $output rb]
    set ::release::publishAttempts 2
    try {
        set problem [publish $candidate $output]
    } finally {
        set ::release::publishAttempts 40
        close $held
    }
    check "locked-output publication reports an error" [expr {$problem ne ""}]
    check "locked-output failure preserves both complete files" \
        [expr {[readBytes $output] eq "replacement release" && [readBytes $candidate] eq "locked replacement"}]
    file delete $candidate

    set candidate [candidate [file join $folder other] "wrong parent"]
    set problem [publish $candidate $output]
    check "cross-directory publication is rejected" \
        [expr {$problem ne "" && [readBytes $output] eq "replacement release" && [readBytes $candidate] eq "wrong parent"}] $problem
    file delete $candidate

    set unowned [file join $folder ordinary-candidate.exe]
    writeText $unowned unowned
    set problem [publish $unowned $output]
    check "non-owned candidate names are rejected without deleting either file" \
        [expr {$problem ne "" && [readBytes $output] eq "replacement release" && [readBytes $unowned] eq "unowned"}] $problem
    file delete $unowned

    # This basename used to collide with build.tcl's fixed linker output. Run
    # several publication cycles and verify that only the requested name lasts.
    set collision [file join $folder machteld-bare.exe]
    writeText $collision "prior bare"
    foreach generation {1 2 3 4} {
        set candidate [candidate $folder "generation $generation"]
        set problem [publish $candidate $collision]
        check "repeated build publication $generation succeeds" \
            [expr {$problem eq "" && [readBytes $collision] eq "generation $generation"}] $problem
    }
    # Publish keeps its .machteld-publish-backup-* only while it replaces, as
    # Tcl's `file rename -force` kept tclr*.TMP; neither may outlast it.
    set debris [lsort -unique [concat \
        [glob -nocomplain -tails -types {f hidden} -directory $folder .machteld-build-* .machteld-publish-backup-* tclr*] \
        [glob -nocomplain -tails -directory $folder .machteld-build-* .machteld-publish-backup-* tclr*]]]
    check "repeated publications leave no candidate or rename debris" [expr {![llength $debris]}] $debris

    set channel [open [file join $root tools build.tcl] rb]
    set buildTcl [read $channel]
    close $channel
    check "linker intermediates are isolated from every requested output name" \
        [expr {[string first {set bare [file join $BUILDROOT machteld-bare.exe]} $buildTcl] >= 0 &&
               [string first {[file join $OUTDIR machteld-bare.exe]} $buildTcl] < 0}]
    set channel [open [file join $root tools package.tcl] rb]
    set packageTcl [read $channel]
    close $channel
    check "package publication is a non-replacing same-directory rename" \
        [expr {[string first {file rename $outputCandidate $OUT} $packageTcl] >= 0 &&
               [string first {file rename -force $outputCandidate $OUT} $packageTcl] < 0}]
    set channel [open [file join $root tools release.tcl] rb]
    set releaseTcl [read $channel]
    close $channel
    check "release publication is the runtime's one-operation Publish, not a rename pair" \
        [expr {[string first {::machteld::Publish $candidate $output} $releaseTcl] >= 0 &&
               [string first {renameWaiting $candidate $output} $releaseTcl] < 0}]
}

proc ::pt::main {argv} {
    variable root
    variable work
    variable wrapper
    variable packager
    variable failures
    if {$argv eq "--build-runtime"} {
        # The signed runtime supplies Tcl/zipfs and a bare console PE for the
        # fixture image. Its entry gate requires the opted-in test as driver.
        set wrapper [file join [::machteld::PayloadRoot] basekit console.exe]
        set packager [list [info nameofexecutable] [file normalize [info script]] --run-packager]
    } elseif {[llength $argv] == 2 && [lindex $argv 0] eq "--tclsh"} {
        set wrapper [file normalize [lindex $argv 1]]
        set packager [list $wrapper [file join $root tools package.tcl]]
    } else {
        puts stderr "usage: package_test.tcl --tclsh EXE | --build-runtime"
        exit 2
    }
    set work [file join [file normalize $::env(TEMP)] [uniqueName machteld-package-test-[pid]-]]
    file mkdir $work
    try {
        packageTests
        publicationTests
    } finally {
        file delete -force $work
    }
    if {$failures} {
        puts stderr "$failures package test(s) failed"
        exit 1
    }
    puts "ALL PACKAGE TESTS PASSED"
}

::pt::main $argv
