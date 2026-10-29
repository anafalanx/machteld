package require machteld 0.21

# test/reference_generator_test.tcl -- the reference generator is
# deterministic (two runs, byte for byte, below a path with spaces) and keeps
# the catalog contracts: the 249/177 core manuals, lowercase IDs, no
# auto-discovered extension, an exact inventory partition, the manifest.
#
#     machteld.exe test/reference_generator_test.tcl --cache DIR --tclsh EXE
#
# The Tcl port (2026-10-28) of test/reference_generator_test.ps1; the
# generator is tools/reference.tcl, run on this same runtime.

namespace eval ::rgt {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
}

proc ::rgt::fail {message} {
    puts stderr "reference generator test: $message"
    exit 1
}

proc ::rgt::readUtf8 {path} {
    set channel [open $path rb]
    try {
        return [encoding convertfrom -profile strict utf-8 [read $channel]]
    } finally {
        close $channel
    }
}

proc ::rgt::relativeFiles {root} {
    set found {}
    set pending [list ""]
    while {[llength $pending]} {
        set pending [lassign $pending dir]
        set here [expr {$dir eq "" ? $root : [file join $root {*}[split $dir /]]}]
        foreach path [glob -nocomplain -directory $here *] {
            set relative [expr {$dir eq "" ? [file tail $path] : "$dir/[file tail $path]"}]
            if {[file isdirectory $path]} {
                lappend pending $relative
            } else {
                lappend found $relative
            }
        }
    }
    lsort $found
}

proc ::rgt::generate {cache tclsh output} {
    variable root
    set result [run -inherit -- [info nameofexecutable] [file join $root tools reference.tcl] \
        --cache $cache --output $output --tclsh $tclsh]
    if {[dict get $result exit] != 0} {
        fail "generator failed with exit code [dict get $result exit]"
    }
}

proc ::rgt::main {argv} {
    variable root
    set cache ""
    set tclsh ""
    while {[llength $argv]} {
        set argv [lassign $argv option value]
        switch -- $option {
            --cache {set cache $value}
            --tclsh {set tclsh $value}
            default {fail "unknown option $option"}
        }
    }
    if {$cache eq "" || $tclsh eq ""} {
        fail "usage: reference_generator_test.tcl --cache DIR --tclsh EXE"
    }
    set work [file join [file normalize $::env(TEMP)] "machteld reference determinism [pid]"]
    set first [file join $work "first pack"]
    set second [file join $work "second pack"]
    file mkdir $work
    try {
        set header [readUtf8 [file join $root src machteld.h]]
        set prelude [readUtf8 [file join $root tcl machteld.tcl]]
        if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([0-9]+\.[0-9]+(?:\.[0-9]+)?)"\s*$} $header -> runtimeVersion]} {
            fail "native canonical version is absent"
        }
        if {![regexp {(?n)^\s*variable\s+version\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$} $prelude -> preludeVersion] ||
                $preludeVersion ne $runtimeVersion} {
            fail "C and Tcl package versions disagree"
        }
        if {[regexp {package require machteld [0-9]} $prelude]} {
            fail "the wrap launcher must derive its pin from ::machteld::version, not carry a literal"
        }
        # The space-bearing parent exercises the converter's argv handling as
        # well as same-parent immutable publication.
        generate $cache $tclsh $first
        generate $cache $tclsh $second
        set firstFiles [relativeFiles $first]
        if {$firstFiles ne [relativeFiles $second]} {
            fail "two runs produced different file inventories"
        }
        foreach relative $firstFiles {
            if {[hash file sha256 [file join $first {*}[split $relative /]]] ne
                    [hash file sha256 [file join $second {*}[split $relative /]]]} {
                fail "two runs differ byte-for-byte at $relative"
            }
        }
        foreach required {
            catalog.dict catalog.json search.dict manifest.sha256 schema.json START-HERE.md AGENTS.md
            markdown/tcl/command/dict.md markdown/tk/command/bind.md source/tcl/doc/dict.n source/tk/doc/bind.n
            html/TclCmd/dict.html html/TkCmd/bind.html
        } {
            if {![file isfile [file join $first {*}[split $required /]]]} {
                fail "required reference path is absent: $required"
            }
        }

        set catalog [json decode [readUtf8 [file join $first catalog.json]]]
        if {[dict get $catalog schema] != 1 ||
                [dict get $catalog products tcl manual_pages] != 249 || [dict get $catalog products tk manual_pages] != 177 ||
                [dict get $catalog products tcl documents] != 250 || [dict get $catalog products tk documents] != 178} {
            fail "catalog product/manual counts do not preserve the 249/177 core-manual contract"
        }
        set documents [dict get $catalog documents]
        foreach retired {machteld/command/macht machteld/guide/engine} {
            if {[dict exists $documents $retired]} {
                fail "retired document remains in catalog: $retired"
            }
        }
        foreach id {tcl/command/dict tcl/command/http tcl/c-api/crtobjcmd tk/command/bind machteld/agent machteld/license tcl/license tk/license} {
            if {![dict exists $documents $id]} {
                fail "catalog document is absent: $id"
            }
        }
        dict for {id record} $documents {
            if {$id ne [string tolower $id]} {
                fail "canonical ID is not lowercase: $id"
            }
            # Tcl's own C API has tcl/c-api/thread; the Thread package is not shipped.
            if {[regexp {/(?:tdbc|sqlite3|itcl|tclx|tktable)(?:/|$)} $id] ||
                    ([regexp {/thread(?:/|$)} $id] && $id ne "tcl/c-api/thread")} {
                fail "unshipped extension was auto-discovered into the core catalog: $id"
            }
        }
        set inventory [dict get $catalog inventory]
        set represented [dict create]
        dict for {id record} $documents {
            dict for {name format} [dict get $record formats] {
                if {![dict exists $inventory [dict get $format path]]} {
                    fail "representation is outside inventory: [dict get $format path]"
                }
                dict set represented [dict get $format path] 1
            }
        }
        set auxiliary [dict create]
        foreach path [dict get $catalog auxiliary] {
            if {![dict exists $inventory $path] || [dict exists $represented $path] || [dict exists $auxiliary $path]} {
                fail "invalid auxiliary partition path: $path"
            }
            dict set auxiliary $path 1
        }
        if {[dict size $represented] + [dict size $auxiliary] != [dict size $inventory]} {
            fail "document representations and auxiliary paths do not exactly partition inventory"
        }

        set dict [readUtf8 [file join $first markdown tcl command dict.md]]
        set filesystem [readUtf8 [file join $first markdown tcl c-api filesystem.md]]
        set canvas [readUtf8 [file join $first markdown tk command canvas.md]]
        set colors [readUtf8 [file join $first markdown tk command colors.md]]
        if {![regexp {(?n)^## NAME\s*$} $dict] || ![regexp {(?n)^## SYNOPSIS\s*$} $dict]} {
            fail "normalized dict page lost canonical headings/synopsis"
        }
        if {![regexp {(?n)^```c\s*$} $filesystem] || ![regexp -nocase {Copyright.*Vincent Darley} $filesystem]} {
            fail "normalized C API page lost C fencing or its upstream per-page notice"
        }
        if {![regexp {(?n)^\| .+ \|\s*$} $colors]} {
            fail "normalized Tk colors page lost table structure"
        }
        foreach sample [list $dict $filesystem $canvas $colors] {
            if {[regexp -nocase {</?(?:b|i|dl|dt|dd|table|tr|td|font|pre|p|br)\y} $sample]} {
                fail "normalized representative page leaked upstream HTML markup"
            }
        }

        set rows [split [string trimright [readUtf8 [file join $first manifest.sha256]] \n] \n]
        if {[lindex $rows 0] ne "# machteld reference pack v1; SHA-256 consistency manifest (self excluded)"} {
            fail "manifest header is not canonical"
        }
        # The manifest lists files in the order Windows sorts their full paths:
        # backslashes, ordinal.
        set manifestFiles [lsort -command {apply {{a b} {
            string compare [string map {/ \\} $a] [string map {/ \\} $b]
        }}} [lmap f $firstFiles {if {$f eq "manifest.sha256"} continue; set f}]]
        if {[llength $rows] != [llength $manifestFiles] + 1} {
            fail "manifest does not cover the exact file set"
        }
        set i 1
        foreach relative $manifestFiles {
            if {[lindex $rows $i] ne "[hash file sha256 [file join $first {*}[split $relative /]]]  $relative"} {
                fail "manifest mismatch at $relative"
            }
            incr i
        }
        puts "REFERENCE GENERATOR TEST PASSED ([llength $firstFiles] byte-identical files, Tcl 249 / Tk 177)"
    } finally {
        file delete -force $work
    }
}

::rgt::main $argv
