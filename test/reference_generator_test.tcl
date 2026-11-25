package require machteld 0.21

# test/reference_generator_test.tcl -- the reference generator is
# deterministic (two runs, byte for byte, below a path with spaces) and keeps
# the catalog contracts: the 249/177 core manuals, lowercase IDs, no
# auto-discovered extension, an exact inventory partition, the manifest.
#
#     machteld.exe test/reference_generator_test.tcl --cache DIR --tclsh EXE ?--keep-work?
#
# The Tcl port (2026-10-28) of test/reference_generator_test.ps1; the
# generator is tools/reference.tcl, run on this same runtime. The work folder
# is this run's own, "machteld reference determinism <pid>-<random hex>" in
# TEMP: one that exists already is refused, and only that exact folder is
# deleted afterwards, unless --keep-work keeps it (machteld 8bcc1ec).

namespace eval ::rgt {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
}

# A failure unwinds, so the work folder is still deleted (or kept).
proc ::rgt::fail {message} {
    return -code error -errorcode {RGT fail} "reference generator test: $message"
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
    set keepWork 0
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --cache - --tclsh {
                set argv [lassign $argv value]
                set [string range $option 2 end] $value
            }
            --keep-work {set keepWork 1}
            default {fail "unknown option $option"}
        }
    }
    if {$cache eq "" || $tclsh eq ""} {
        fail "usage: reference_generator_test.tcl --cache DIR --tclsh EXE ?--keep-work?"
    }
    set temp [file normalize $::env(TEMP)]
    set leaf "machteld reference determinism [pid]-[binary encode hex [hash random 16]]"
    set work [file join $temp $leaf]
    if {[file exists $work]} {
        fail "the work folder exists already: [file nativename $work]"
    }
    set first [file join $work "first pack"]
    set second [file join $work "second pack"]
    file mkdir $work
    puts "reference test work: [file nativename $work]"
    try {
        set header [readUtf8 [file join $root src machteld.h]]
        set prelude [readUtf8 [file join $root tcl machteld.tcl]]
        if {![regexp {(?n)^#define\s+MACHTELD_VERSION\s+"([1-9][0-9]*)"\s*$} $header -> runtimeVersion]} {
            fail "native canonical version is absent"
        }
        if {![regexp {(?n)^\s*variable\s+version\s+([1-9][0-9]*)\s*$} $prelude -> preludeVersion] ||
                $preludeVersion ne $runtimeVersion} {
            fail "C and Tcl package versions disagree"
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
        set expected {AGENTS.md START-HERE.md identity.dict licenses/Apache-2.0.txt licenses/Tcl-9.0.4.txt licenses/Tk-9.0.4.txt
                      licenses/cffi-2.0.3.txt manifest.sha256 reference.db schema.json}
        if {[lsort $expected] ne [lsort $firstFiles]} {fail "schema 2 pack inventory mismatch: $firstFiles"}
        set identity [readUtf8 [file join $first identity.dict]]
        if {[dict get $identity schema] != 2 || [dict get $identity machteld_version] ne $runtimeVersion ||
                [dict get $identity corpus_sha256] ne [hash file sha256 [file join $first reference.db]]} {
            fail "compact corpus identity mismatch"
        }
        if {![llength [info commands ::sqlite3]]} {load [file join $cache prefix bin refsqlite.dll] Sqlite3}
        sqlite3 ::rgt::fixture [file join $first reference.db] -readonly 1
        try {
            if {[fixture eval {SELECT name,documents,manual_pages FROM product WHERE name IN ('tcl','tk','cffi') ORDER BY name}]
                    ne {cffi 5 4 tcl 250 249 tk 178 177}} {fail "unexpected upstream manual counts"}
            foreach required {tcl/command/dict tcl/command/http tcl/c-api/crtobjcmd tk/command/bind machteld/agent machteld/license tcl/license tk/license} {
                if {![fixture exists {SELECT 1 FROM page WHERE id=$required}]} {fail "missing stable page $required"}
            }
            fixture eval {SELECT id,path,body,sha256,characters,bytes FROM page ORDER BY id} {
                if {$id ne [string tolower $id] || $id in {machteld/command/macht machteld/guide/engine} ||
                        [regexp {/(?:tdbc|sqlite3|itcl|tclx|tktable)(?:/|$)} $id] ||
                        ([regexp {/thread(?:/|$)} $id] && $id ne "tcl/c-api/thread")} {fail "invalid page $id"}
                set utf8 [encoding convertto utf-8 $body]
                if {[string length $body] != $characters || [string length $utf8] != $bytes ||
                        [hash sum sha256 $utf8] ne $sha256} {fail "page content changed for $id"}
            }
            if {[fixture exists {SELECT 1 FROM section s JOIN page p ON s.id=p.id WHERE s.start<0 OR s.end<s.start OR s.end>p.characters}] ||
                    [fixture onecolumn {PRAGMA integrity_check}] ne "ok" || [fixture eval {PRAGMA foreign_key_check}] ne ""} {
                fail "database or section bounds failed verification"
            }
            if {![string match {*Donal K. Fellows*} [fixture onecolumn {SELECT text FROM notice WHERE id='tcl/command/dict'}]]} {
                fail "the dict manual lost its original roff attribution"
            }
            foreach {var id} {dict tcl/command/dict filesystem tcl/c-api/filesystem canvas tk/command/canvas colors tk/command/colors} {
                set $var [fixture onecolumn {SELECT body FROM page WHERE id=$id}]
            }
        } finally {
            fixture close
        }
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
        if {[lindex $rows 0] ne "# machteld reference pack v2; SHA-256 consistency manifest (self excluded)"} {
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
        if {$keepWork} {
            puts "reference test work kept: [file nativename $work]"
        } elseif {[file tail $work] eq $leaf && [file dirname $work] eq $temp && [file isdirectory $work]} {
            file delete -force $work
        }
    }
}

try {
    ::rgt::main $argv
} trap {RGT fail} {message} {
    puts stderr $message
    exit 1
}
