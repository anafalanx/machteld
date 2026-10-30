package require machteld 0.21

# test/version_resource_test.tcl -- every host carries exact, release-flagged
# VERSIONINFO derived from the one canonical version, names its publisher, and
# carries no path of the machine that built it.
#
#     machteld.exe test/version_resource_test.tcl RUNTIME ?--cache DIR? ?--no-wrap?
#
# The Tcl port (2026-10-28) of test/version_resource_test.ps1. Neither Tcl nor
# the runtime offers Windows' version API, so the resource is read from the PE
# file itself (test/pe_resources.tcl, which test/app_identity_test.tcl shares):
# the resource directory to RT_VERSION, then VS_VERSIONINFO's fixed part and
# its 040904B0 string table. --no-wrap skips the checks that write wrapped
# executables (for a machine that must not build any).

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] pe_resources.tcl]

namespace eval ::vr {
    namespace path {::machteld ::pe}
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable failures 0
}

proc ::vr::check {name condition {detail ""}} {
    variable failures
    if {$condition} {
        puts "ok   $name"
    } else {
        incr failures
        puts "FAIL $name $detail"
    }
}

proc ::vr::checkResource {label path description internalName originalFilename version numeric} {
    if {![file isfile $path]} {
        check "$label exists" 0 $path
        return
    }
    # Not checked: whether the file is marked FILE_ATTRIBUTE_TEMPORARY. Neither
    # Tcl nor the runtime can read that attribute (zef-commentary.md).
    if {[catch {parse [versionBlock $path]} info]} {
        check "$label carries a VERSIONINFO resource" 0 $info
        return
    }
    check "$label string versions are exact" \
        [expr {[field $info FileVersion] eq $version && [field $info ProductVersion] eq $version}] \
        "file={[field $info FileVersion]} product={[field $info ProductVersion]}"
    set actual [numbers $info]
    check "$label numeric versions are padded deterministically" \
        [expr {$actual eq [concat $numeric $numeric]}] "file and product=$actual"
    check "$label publisher identity is present" \
        [expr {[field $info CompanyName] eq "Vincent Vercauteren" &&
               [field $info LegalCopyright] eq "Copyright 2026 Vincent Vercauteren" &&
               [field $info ProductName] eq "Machteld"}] \
        "company={[field $info CompanyName]} copyright={[field $info LegalCopyright]} product={[field $info ProductName]}"
    check "$label custom author identity is present" \
        [expr {[field $info Author] eq "Vincent Vercauteren"}] "author={[field $info Author]}"
    check "$label host identity is present" \
        [expr {[field $info FileDescription] eq $description && [field $info InternalName] eq $internalName &&
               [field $info OriginalFilename] eq $originalFilename}] \
        "description={[field $info FileDescription]} internal={[field $info InternalName]} original={[field $info OriginalFilename]}"
    # VS_FF_DEBUG, PRERELEASE, PATCHED, PRIVATEBUILD, SPECIALBUILD.
    check "$label carries release rather than development flags" \
        [expr {([dict get $info flags] & [dict get $info flagsMask] & 0x2f) == 0}] "flags=[dict get $info flags]"
}

proc ::vr::embeddedBuildPaths {path cache} {
    variable root
    set needles {}
    foreach dir [list $root $cache] {
        if {$dir eq ""} {
            continue
        }
        set native [string trimright [file nativename [file normalize $dir]] \\]
        lappend needles $native [string map {\\ /} $native]
    }
    lappend needles /.cache/ \\.cache\\
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    set views [list [string tolower [encoding convertfrom iso8859-1 $bytes]] \
        [string tolower [encoding convertfrom -profile replace utf-16le $bytes]] \
        [string tolower [encoding convertfrom -profile replace utf-16le [string range $bytes 1 end]]]]
    set found {}
    foreach needle $needles {
        foreach view $views {
            if {[string first [string tolower $needle] $view] >= 0} {
                lappend found $needle
                break
            }
        }
    }
    lsort -unique $found
}

proc ::vr::main {argv} {
    variable root
    variable failures
    set runtime ""
    set cache ""
    set wrap 1
    while {[llength $argv]} {
        set argv [lassign $argv word]
        switch -- $word {
            --cache {set argv [lassign $argv cache]}
            --no-wrap {set wrap 0}
            default {set runtime [file normalize $word]}
        }
    }
    set header [open [file join $root src machteld.h] r]
    set text [read $header]
    close $header
    # machteld's version is one natural number; Windows' fixed version pads it
    # with three zeros (22 is 22.0.0.0), and the string versions are exact.
    if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([1-9][0-9]*)"\s*$} $text -> version]} {
        error "src/machteld.h has no canonical MACHTELD_VERSION"
    }
    set numeric [list $version 0 0 0]

    set work [file join [file normalize $::env(TEMP)] machteld-version-resource-test-[pid]-[binary encode hex [hash random 8]]]
    file mkdir $work
    try {
        checkResource "full executable" $runtime "machteld runtime" machteld machteld.exe $version $numeric
        set paths [embeddedBuildPaths $runtime $cache]
        check "full executable carries no repository or dependency-cache path" [expr {[llength $paths] == 0}] [join $paths {, }]
        if {$wrap} {
            set entry [file join $work main.tcl]
            set channel [open $entry wb]
            puts -nonewline $channel "package require machteld\nexit 0\n"
            close $channel
            foreach {kind exe description internal original} {
                console wrapped-console.exe "machteld runtime" machteld machteld.exe
                gui wrapped-gui.exe "Machteld GUI application host" machteld-gui machteld-gui.exe
            } {
                set out [file join $work $exe]
                set result [run -- $runtime wrap $entry -o $out --$kind]
                check "$kind metadata fixture wraps successfully" \
                    [expr {[dict get $result exit] == 0 && [file isfile $out]}]
                if {[file isfile $out]} {
                    checkResource "wrapped $kind" $out $description $internal $original $version $numeric
                    set paths [embeddedBuildPaths $out $cache]
                    check "wrapped $kind carries no repository or dependency-cache path" \
                        [expr {[llength $paths] == 0}] [join $paths {, }]
                }
            }
        } else {
            puts "--   wrapped-host checks skipped (--no-wrap)"
        }
    } finally {
        file delete -force $work
    }
    if {$failures} {
        puts stderr "$failures VERSIONINFO test(s) failed"
        exit 1
    }
    puts "ALL VERSIONINFO TESTS PASSED"
}

::vr::main $argv
