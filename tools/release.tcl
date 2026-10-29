package require machteld 0.21

# tools/release.tcl -- the hermetic release build: the dependency cache
# bootstrapped or verified, the reference generated, the hosts compiled and
# packaged by tools/build.tcl on the cache's static tclsh, and the result
# published under the requested name in one rename.
#
#     machteld.exe tools/release.tcl ?--output FILE? ?--cache DIR? ?--msys DIR? ?--skip-bootstrap?
#
# The package and every linker intermediate get names this invocation owns
# (.machteld-build-<32 hex>.exe and .work beside the output), so publication is
# one same-volume rename and cleanup deletes only what this run made. The Tcl
# port (2026-10-28) of tools/build.ps1 and tools/publish-output.ps1.

namespace eval ::release {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
}
source -encoding utf-8 [file join $::release::root tools bootstrap.tcl]

proc ::release::fail {message} {
    return -code error -errorcode {RELEASE fail} "release: $message"
}

# Runs a program on this console; a failure names it and its exit code.
proc ::release::step {label args} {
    set result [run -inherit -- {*}$args]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        fail "$label failed with exit code [dict get $result exit]"
    }
}

proc ::release::plainDirectory {path} {
    expr {[file isdirectory $path] && [file type $path] eq "directory"}
}

proc ::release::main {argv} {
    variable root
    set output [file join $root out machteld.exe]
    set cache [file join $root .cache deps]
    set msysRequested ""
    set skipBootstrap 0
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --output {set argv [lassign $argv output]}
            --cache {set argv [lassign $argv cache]}
            --msys {set argv [lassign $argv msysRequested]}
            --skip-bootstrap {set skipBootstrap 1}
            default {fail "unknown option $option"}
        }
    }
    set cache [file normalize $cache]
    set msys [::boot::msysRoot $msysRequested]
    set runtime [info nameofexecutable]

    set bootstrap [list $runtime [file join $root tools bootstrap.tcl] --cache $cache --msys $msys]
    if {$skipBootstrap} {
        lappend bootstrap --verify-only
    }
    step "dependency bootstrap" {*}$bootstrap

    set prefix [file join $cache prefix]
    set tclsh ""
    foreach candidate [list [file join $prefix bin tclsh90s.exe] [file join $prefix bin tclsh90.exe]] {
        if {[file isfile $candidate]} {
            set tclsh $candidate
            break
        }
    }
    if {$tclsh eq ""} {
        fail "dependency prefix has no static tclsh: [file nativename $prefix]"
    }

    set saved [dict create]
    foreach name {MACHTELD_DEPS_ROOT MACHTELD_GCC MACHTELD_STRIP MACHTELD_WINDRES MACHTELD_REFERENCE_ROOT MACHTELD_BUILD_ROOT} {
        if {[info exists ::env($name)]} {
            dict set saved $name $::env($name)
        }
    }
    set ::env(MACHTELD_DEPS_ROOT) [file nativename $cache]
    set ::env(MACHTELD_GCC) [file nativename [file join $msys ucrt64 bin gcc.exe]]
    set ::env(MACHTELD_STRIP) [file nativename [file join $msys ucrt64 bin strip.exe]]
    set ::env(MACHTELD_WINDRES) [file nativename [file join $msys ucrt64 bin windres.exe]]

    set output [file normalize $output]
    set parent [file dirname $output]
    file mkdir $parent
    while 1 {
        set id [binary encode hex [hash random 16]]
        set candidateLeaf .machteld-build-$id.exe
        set workLeaf .machteld-build-$id.work
        set candidate [file join $parent $candidateLeaf]
        set buildRoot [file join $parent $workLeaf]
        if {![file exists $candidate] && ![file exists $buildRoot]} {
            break
        }
    }
    set workReady 0
    set candidateReady 0
    try {
        file mkdir $buildRoot
        if {![plainDirectory $buildRoot]} {
            fail "invocation build directory must not be a reparse point: [file nativename $buildRoot]"
        }
        set workReady 1
        set reference [file join $buildRoot reference]
        set ::env(MACHTELD_REFERENCE_ROOT) [file nativename $reference]
        set ::env(MACHTELD_BUILD_ROOT) [file nativename $buildRoot]

        # The generator publishes into the absent reference path inside this
        # invocation's work directory.
        step "reference generation" $runtime [file join $root tools reference.tcl] \
            --cache $cache --output $reference --tclsh $tclsh
        step "build" $tclsh [file join $root tools build.tcl] $candidate

        if {![file isfile $candidate]} {
            fail "build produced no publication candidate: [file nativename $candidate]"
        }
        if {[file type $candidate] ne "file"} {
            fail "build candidate must not be a reparse point: [file nativename $candidate]"
        }
        set candidateReady 1
        publish $candidate $output
    } finally {
        foreach name {MACHTELD_REFERENCE_ROOT MACHTELD_BUILD_ROOT} {
            if {[dict exists $saved $name]} {
                set ::env($name) [dict get $saved $name]
            } else {
                unset -nocomplain ::env($name)
            }
        }
        # Delete only what this invocation both named and made.
        if {$candidateReady && [file isfile $candidate] && [file type $candidate] eq "file"} {
            catch {file delete $candidate}
        }
        if {$workReady && [plainDirectory $buildRoot]} {
            catch {file delete -force $buildRoot}
        }
    }
}

# Publishes the candidate under the output name, beside it. The PowerShell
# publisher made this one MoveFileExW call; the runtime has none, so this is
# Tcl's `file rename -force`: the old file renamed aside in the same folder,
# the candidate renamed in, the old one deleted, or put back if the second
# rename fails. A held output fails the first rename and leaves both files
# whole; the name is absent only between two renames in one folder.
proc ::release::publish {candidate output} {
    set candidate [file normalize $candidate]
    set output [file normalize $output]
    if {![string equal -nocase [file dirname $candidate] [file dirname $output]]} {
        fail "publication candidate must be beside the requested output"
    }
    if {[string equal -nocase $candidate $output]} {
        fail "publication candidate and requested output must be different paths"
    }
    if {![regexp {^\.machteld-build-[0-9a-f]{32}\.exe$} [file tail $candidate]]} {
        fail "publication candidate is not an invocation-owned build path: [file tail $candidate]"
    }
    if {![file isfile $candidate] || [file type $candidate] ne "file"} {
        fail "publication candidate is not a plain file: [file nativename $candidate]"
    }
    if {[file isdirectory $output]} {
        fail "requested output is a directory: [file nativename $output]"
    }
    ::boot::renameWaiting $candidate $output
    puts "published [file nativename $output]"
}

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    try {
        ::release::main $argv
    } trap {RELEASE fail} {message} {
        puts stderr $message
        exit 1
    } trap {BOOTSTRAP fail} {message} {
        puts stderr $message
        exit 1
    }
}
