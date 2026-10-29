package require machteld 0.21

# test/version_resource_test.tcl -- every host carries exact, release-flagged
# VERSIONINFO derived from the one canonical version, names its publisher, and
# carries no path of the machine that built it.
#
#     machteld.exe test/version_resource_test.tcl RUNTIME ?--cache DIR? ?--no-wrap?
#
# The Tcl port (2026-10-28) of test/version_resource_test.ps1. Neither Tcl nor
# the runtime offers Windows' version API, so the resource is read from the PE
# file itself: the resource directory to RT_VERSION, then VS_VERSIONINFO's
# fixed part and its 040904B0 string table. --no-wrap skips the checks that
# write wrapped executables (for a machine that must not build any).

namespace eval ::vr {
    namespace path ::machteld
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

proc ::vr::u16 {data offset} {
    set offset [expr {$offset}]
    binary scan $data @${offset}su value
    return $value
}

proc ::vr::u32 {data offset} {
    set offset [expr {$offset}]
    binary scan $data @${offset}iu value
    return $value
}

# A zero-terminated UTF-16LE string at offset; returns {text nextOffset}.
proc ::vr::wstring {data offset} {
    set end $offset
    while {[u16 $data $end] != 0} {
        incr end 2
    }
    list [encoding convertfrom utf-16le [string range $data $offset [expr {$end - 1}]]] [expr {$end + 2}]
}

proc ::vr::align4 {offset} {
    expr {($offset + 3) & ~3}
}

# The VS_VERSIONINFO block of a PE file, as bytes; empty when there is none.
proc ::vr::versionBlock {path} {
    set channel [open $path rb]
    set data [read $channel]
    close $channel
    if {[string range $data 0 1] ne "MZ"} {
        return ""
    }
    set pe [u32 $data 0x3c]
    if {[string range $data $pe [expr {$pe + 3}]] ne "PE\0\0"} {
        return ""
    }
    set coff [expr {$pe + 4}]
    set sections [u16 $data [expr {$coff + 2}]]
    set optionalSize [u16 $data [expr {$coff + 16}]]
    set optional [expr {$coff + 20}]
    set magic [u16 $data $optional]
    set directories [expr {$optional + ($magic == 0x20b ? 112 : 96)}]
    set resourceRva [u32 $data [expr {$directories + 2 * 8}]]
    if {$resourceRva == 0} {
        return ""
    }
    set table [expr {$optional + $optionalSize}]
    set map {}
    for {set i 0} {$i < $sections} {incr i} {
        set s [expr {$table + 40 * $i}]
        lappend map [list [u32 $data [expr {$s + 12}]] [u32 $data [expr {$s + 8}]] [u32 $data [expr {$s + 20}]]]
    }
    set toOffset {{map rva} {
        foreach section $map {
            lassign $section address size raw
            if {$rva >= $address && $rva < $address + max($size, 1)} {
                return [expr {$raw + $rva - $address}]
            }
        }
        error "RVA $rva lies in no section"
    }}
    set base [apply $toOffset $map $resourceRva]
    # Type RT_VERSION (16), then its first name and its first language.
    set entry [findEntry $data $base $base 16]
    if {$entry eq ""} {
        return ""
    }
    for {set level 0} {$level < 2} {incr level} {
        if {!($entry & 0x80000000)} {
            break
        }
        set directory [expr {$base + ($entry & 0x7fffffff)}]
        set entry [u32 $data [expr {$directory + 16 + 4}]]
    }
    set dataEntry [expr {$base + ($entry & 0x7fffffff)}]
    set offset [apply $toOffset $map [u32 $data $dataEntry]]
    string range $data $offset [expr {$offset + [u32 $data [expr {$dataEntry + 4}]] - 1}]
}

proc ::vr::findEntry {data base directory id} {
    set named [u16 $data [expr {$directory + 12}]]
    set ids [u16 $data [expr {$directory + 14}]]
    for {set i 0} {$i < $named + $ids} {incr i} {
        set e [expr {$directory + 16 + 8 * $i}]
        if {[u32 $data $e] == $id} {
            return [u32 $data [expr {$e + 4}]]
        }
    }
    return ""
}

# Fixed numbers, flags and the 040904B0 strings of a VS_VERSIONINFO block.
proc ::vr::parse {block} {
    set info [dict create strings {}]
    lassign [wstring $block 6] key next
    if {$key ne "VS_VERSION_INFO"} {
        error "not a VS_VERSIONINFO block"
    }
    set fixed [align4 $next]
    if {[u32 $block $fixed] != 0xfeef04bd} {
        error "VS_FIXEDFILEINFO signature missing"
    }
    foreach {name at} {fileMS 8 fileLS 12 productMS 16 productLS 20 flagsMask 24 flags 28} {
        dict set info $name [u32 $block [expr {$fixed + $at}]]
    }
    set child [align4 [expr {$fixed + [u16 $block 2]}]]
    set total [u16 $block 0]
    while {$child < $total} {
        set length [u16 $block $child]
        if {$length == 0} {
            break
        }
        lassign [wstring $block [expr {$child + 6}]] childKey childNext
        if {$childKey eq "StringFileInfo"} {
            set table [align4 $childNext]
            set tableEnd [expr {$child + $length}]
            while {$table < $tableEnd} {
                set tableLength [u16 $block $table]
                lassign [wstring $block [expr {$table + 6}]] language at
                set string [align4 $at]
                set stringsEnd [expr {$table + $tableLength}]
                while {$string < $stringsEnd} {
                    set stringLength [u16 $block $string]
                    if {$stringLength == 0} {
                        break
                    }
                    lassign [wstring $block [expr {$string + 6}]] name valueAt
                    set value ""
                    if {[u16 $block [expr {$string + 2}]] > 0} {
                        lassign [wstring $block [align4 $valueAt]] value
                    }
                    if {[string toupper $language] eq "040904B0"} {
                        dict set info strings $name $value
                    }
                    set string [align4 [expr {$string + $stringLength}]]
                }
                set table [align4 [expr {$table + $tableLength}]]
            }
        }
        set child [align4 [expr {$child + $length}]]
    }
    return $info
}

proc ::vr::field {info name} {
    if {[dict exists $info strings $name]} {
        return [dict get $info strings $name]
    }
    return ""
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
    set actual [list [expr {[dict get $info fileMS] >> 16}] [expr {[dict get $info fileMS] & 0xffff}] \
        [expr {[dict get $info fileLS] >> 16}] [expr {[dict get $info fileLS] & 0xffff}] \
        [expr {[dict get $info productMS] >> 16}] [expr {[dict get $info productMS] & 0xffff}] \
        [expr {[dict get $info productLS] >> 16}] [expr {[dict get $info productLS] & 0xffff}]]
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
    if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([0-9]+)\.([0-9]+)(?:\.([0-9]+))?"\s*$} $text -> major minor patch]} {
        error "src/machteld.h has no canonical MACHTELD_VERSION"
    }
    set version $major.$minor
    set numeric [list $major $minor 0 0]
    if {$patch ne ""} {
        append version .$patch
        lset numeric 2 $patch
    }

    set work [file join [file normalize $::env(TEMP)] machteld-version-resource-test-[pid]-[binary encode hex [hash random 8]]]
    file mkdir $work
    try {
        checkResource "full executable" $runtime "Machteld machine-control runtime" machteld machteld.exe $version $numeric
        set paths [embeddedBuildPaths $runtime $cache]
        check "full executable carries no repository or dependency-cache path" [expr {[llength $paths] == 0}] [join $paths {, }]
        if {$wrap} {
            set entry [file join $work main.tcl]
            set channel [open $entry wb]
            puts -nonewline $channel "package require machteld\nexit 0\n"
            close $channel
            foreach {kind exe description internal original} {
                console wrapped-console.exe "Machteld machine-control runtime" machteld machteld.exe
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
