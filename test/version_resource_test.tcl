package require machteld 0.21

# test/version_resource_test.tcl -- every host carries exact, milestone-aware
# VERSIONINFO derived from the one canonical version, names its publisher, and
# carries no path of the machine that built it.
#
#     machteld.exe test/version_resource_test.tcl RUNTIME ?--cache DIR?
#
# Read RT_MANIFEST and RT_VERSION directly from the runtime PE image.

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
    # Tcl nor the runtime can read that attribute (commentary.md, its entry of
    # 2026-10-28 on porting the runtime's tests).
    set data [bytes $path]
    set manifest [resource $data 24 1]
    variable root
    set peHeader [::pe::u32 $data 0x3c]
    check "$label keeps the Windows console subsystem" \
        [expr {[::pe::u16 $data [expr {$peHeader + 24 + 68}]] == 3}]
    check "$label embeds the authored detached-console manifest" \
        [expr {$manifest eq [bytes [file join $root src machteld.manifest]] &&
            [string match {*consoleAllocationPolicy*2024/WindowsSettings">detached</consoleAllocationPolicy>*} $manifest]}]
    if {[catch {parse [resource $data 16]} info]} {
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
    set expectedFlags [expr {[string match *-dev $version] ? 2 : 0}]
    check "$label carries the declared prerelease flag" \
        [expr {([dict get $info flags] & [dict get $info flagsMask] & 0x2f) == $expectedFlags}] "flags=[dict get $info flags]"
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
    while {[llength $argv]} {
        set argv [lassign $argv word]
        switch -- $word {
            --cache {set argv [lassign $argv cache]}
            default {set runtime [file normalize $word]}
        }
    }
    set header [open [file join $root src machteld.h] r]
    set text [read $header]
    close $header
    # Windows' fixed version keeps the package API; the strings display the product.
    if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([1-9][0-9]*)"\s*$} $text -> version]} {
        error "src/machteld.h has no canonical MACHTELD_VERSION"
    }
    set numeric [list $version 0 0 0]
    if {![regexp -line {^#define\s+MACHTELD_PRODUCT_VERSION\s+"([^"]+)"} $text -> product]} {
        error "src/machteld.h has no canonical MACHTELD_PRODUCT_VERSION"
    }

    checkResource "full executable" $runtime "machteld runtime" machteld machteld.exe $product $numeric
    set paths [embeddedBuildPaths $runtime $cache]
    check "full executable carries no repository or dependency-cache path" [expr {[llength $paths] == 0}] [join $paths {, }]
    if {$failures} {
        puts stderr "$failures VERSIONINFO test(s) failed"
        exit 1
    }
    puts "ALL VERSIONINFO TESTS PASSED"
}

::vr::main $argv
