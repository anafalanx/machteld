# test/pe_resources.tcl -- the resources of a PE file, read from its bytes.
# Neither Tcl nor the runtime offers Windows' resource or version API, so the
# tests that check what a host carries walk the resource directory themselves:
# type, then name, then language, to the data entry and its bytes; and parse
# VS_VERSIONINFO's fixed part and its 040904B0 string table.
#
# Sourced by test/version_resource_test.tcl and test/app_identity_test.tcl.
# Plain Tcl 9: no runtime command is used.

namespace eval ::pe {}

proc ::pe::u16 {data offset} {
    set offset [expr {$offset}]
    binary scan $data @${offset}su value
    return $value
}

proc ::pe::u32 {data offset} {
    set offset [expr {$offset}]
    binary scan $data @${offset}iu value
    return $value
}

# A zero-terminated UTF-16LE string at offset; returns {text nextOffset}.
proc ::pe::wstring {data offset} {
    set end $offset
    while {[u16 $data $end] != 0} {
        incr end 2
    }
    list [encoding convertfrom utf-16le [string range $data $offset [expr {$end - 1}]]] [expr {$end + 2}]
}

proc ::pe::align4 {offset} {
    expr {($offset + 3) & ~3}
}

proc ::pe::bytes {path} {
    set channel [open $path rb]
    try {
        return [read $channel]
    } finally {
        close $channel
    }
}

# Where the resource directory is: {base sections}, base its file offset and
# sections the {rva size raw} of every section; empty when there is none.
proc ::pe::layout {data} {
    if {[string range $data 0 1] ne "MZ"} {
        return ""
    }
    set pe [u32 $data 0x3c]
    if {[string range $data $pe [expr {$pe + 3}]] ne "PE\0\0"} {
        return ""
    }
    set coff [expr {$pe + 4}]
    set count [u16 $data [expr {$coff + 2}]]
    set optionalSize [u16 $data [expr {$coff + 16}]]
    set optional [expr {$coff + 20}]
    set magic [u16 $data $optional]
    set directories [expr {$optional + ($magic == 0x20b ? 112 : 96)}]
    set resourceRva [u32 $data [expr {$directories + 2 * 8}]]
    if {$resourceRva == 0} {
        return ""
    }
    set table [expr {$optional + $optionalSize}]
    set sections {}
    for {set i 0} {$i < $count} {incr i} {
        set s [expr {$table + 40 * $i}]
        lappend sections [list [u32 $data [expr {$s + 12}]] [u32 $data [expr {$s + 8}]] [u32 $data [expr {$s + 20}]]]
    }
    list [offset $sections $resourceRva] $sections
}

proc ::pe::offset {sections rva} {
    foreach section $sections {
        lassign $section address size raw
        if {$rva >= $address && $rva < $address + max($size, 1)} {
            return [expr {$raw + $rva - $address}]
        }
    }
    error "RVA $rva lies in no section"
}

# The entries of one resource directory, in order: {id target} pairs, id a
# number or the entry's name, target the raw offset word (high bit: a
# subdirectory).
proc ::pe::entries {data base directory} {
    set named [u16 $data [expr {$directory + 12}]]
    set ids [u16 $data [expr {$directory + 14}]]
    set found {}
    for {set i 0} {$i < $named + $ids} {incr i} {
        set e [expr {$directory + 16 + 8 * $i}]
        set id [u32 $data $e]
        if {$id & 0x80000000} {
            set at [expr {$base + ($id & 0x7fffffff)}]
            set id [encoding convertfrom utf-16le [string range $data [expr {$at + 2}] [expr {$at + 1 + 2 * [u16 $data $at]}]]]
        }
        lappend found $id [u32 $data [expr {$e + 4}]]
    }
    return $found
}

# Whether a directory entry's id is the one wanted ("" wants any): numbers
# compare as numbers (24, 0x409), names as text.
proc ::pe::same {id wanted} {
    if {$wanted eq ""} {
        return 1
    }
    if {[string is entier -strict $id] && [string is entier -strict $wanted]} {
        return [expr {$id == $wanted}]
    }
    return [expr {$id eq $wanted}]
}

# The bytes of one resource: type and name are numbers, or "" for the first;
# language is a number, or "" for the first. Empty when there is none.
proc ::pe::resource {data type {name ""} {language ""}} {
    set layout [layout $data]
    if {$layout eq ""} {
        return ""
    }
    lassign $layout base sections
    set directory $base
    foreach wanted [list $type $name $language] level {0 1 2} {
        set target ""
        foreach {id candidate} [entries $data $base $directory] {
            if {[same $id $wanted]} {
                set target $candidate
                break
            }
        }
        if {$target eq "" || ($level < 2) != (($target & 0x80000000) != 0)} {
            return ""
        }
        set directory [expr {$base + ($target & 0x7fffffff)}]
    }
    set dataEntry [expr {$base + $target}]
    set at [offset $sections [u32 $data $dataEntry]]
    string range $data $at [expr {$at + [u32 $data [expr {$dataEntry + 4}]] - 1}]
}

# The names (ids) of every resource of one type, in directory order.
proc ::pe::names {data type} {
    set layout [layout $data]
    if {$layout eq ""} {
        return {}
    }
    lassign $layout base sections
    foreach {id target} [entries $data $base $base] {
        if {[same $id $type] && ($target & 0x80000000)} {
            return [dict keys [entries $data $base [expr {$base + ($target & 0x7fffffff)}]]]
        }
    }
    return {}
}

# The VS_VERSIONINFO block of a PE file: its first RT_VERSION resource.
proc ::pe::versionBlock {path} {
    resource [bytes $path] 16
}

# Fixed numbers, flags and the 040904B0 strings of a VS_VERSIONINFO block.
proc ::pe::parse {block} {
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

# One string of a parsed VS_VERSIONINFO; empty when absent.
proc ::pe::field {info name} {
    if {[dict exists $info strings $name]} {
        return [dict get $info strings $name]
    }
    return ""
}

# The four 16-bit parts of a parsed version's file and product numbers.
proc ::pe::numbers {info} {
    list [expr {[dict get $info fileMS] >> 16}] [expr {[dict get $info fileMS] & 0xffff}] \
        [expr {[dict get $info fileLS] >> 16}] [expr {[dict get $info fileLS] & 0xffff}] \
        [expr {[dict get $info productMS] >> 16}] [expr {[dict get $info productMS] & 0xffff}] \
        [expr {[dict get $info productLS] >> 16}] [expr {[dict get $info productLS] & 0xffff}]
}
