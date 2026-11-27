package require machteld 0.21

# test/reference_generator_test.tcl -- the reference generator is
# deterministic (two runs, byte for byte, below a path with spaces) and keeps
# the catalog contracts: the 249/177 core manuals, lowercase IDs, no
# auto-discovered extension, one SQLite file and its page/section identities.
#
#     machteld.exe test/reference_generator_test.tcl --cache DIR --tclsh EXE ?--keep-work?
#
# The generator is tools/reference.tcl, run on this same runtime. A short,
# exclusively created directory leaves room for its source tree in Windows
# TEMP. --keep-work retains both generated databases for inspection.

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

proc ::rgt::databaseFile {root} {
    set entries {}
    foreach name [concat [glob -tails -nocomplain -directory $root *] \
            [glob -tails -nocomplain -types hidden -directory $root *]] {
        if {$name ni {. ..}} {lappend entries $name}
    }
    set path [file join $root reference.db]
    if {[lsort -unique $entries] ne {reference.db} || [file type $path] ne "file"} {
        fail "unexpected reference directory entries: $entries"
    }
    return $path
}

proc ::rgt::generate {cache tclsh output} {
    variable root
    set result [run -inherit -- [info nameofexecutable] [file join $root tools reference.tcl] \
        --cache $cache --output $output --tclsh $tclsh]
    if {[dict get $result exit] != 0} {
        fail "generator failed with exit code [dict get $result exit]"
    }
}

proc ::rgt::sourceNames {lines file} {
    set start [lsearch -exact $lines {.SH NAME}]
    if {$start < 0} {fail "$file has no upstream NAME field"}
    set field ""
    foreach line [lrange $lines [expr {$start+1}] end] {
        if {[string match .* $line]} break
        append field { } $line
        set at [string first { \- } $field]
        if {$at >= 0} {
            return [lmap name [split [string range $field 0 $at-1] ,] {
                string trim [regsub -all {\s+} $name { }]
            }]
        }
    }
    fail "unsupported upstream NAME in $file"
}

proc ::rgt::checkManualSections {id product file lines body totalsVar} {
    upvar 1 $totalsVar totals
    set headings [fixture eval {SELECT heading FROM section WHERE id=$id ORDER BY start}]
    set next 0
    set standardOptions 0
    foreach line $lines {
        if {[regexp {^\.(?:SH|SS)\s+(.+)$} $line -> title]} {
            set title [string trim [string trim $title] {"}]
            set found [lsearch -start $next -nocase -exact $headings $title]
            if {$found < 0} {fail "$file lost or reordered upstream heading $title"}
            set next [expr {$found+1}]
            dict incr totals headings
        }
        if {$product ne "tk"} continue
        if {[regexp {^\.SO(?:\s|$)} $line]} {set standardOptions 1; continue}
        if {$line eq {.SE}} {set standardOptions 0; continue}
        if {$standardOptions || [string match {.OP *} $line]} {
            # A quoted .OP may also name a short option, such as -bg.
            foreach escaped [regexp -all -inline {\\-[A-Za-z][[:alnum:]-]*} $line] {
                set flag [string range $escaped 1 end]
                if {![regexp -- "$flag\\M" $body]} {fail "$file lost widget option $flag"}
                dict incr totals options
            }
        }
    }
}

# Read the pinned archive's actual man sources independently of the HTML
# converter. An unchanged total cannot detect two swapped pages, a lost alias
# inside a large C manual, or a section title damaged during conversion.
proc ::rgt::checkCoreManuals {cache} {
    set checked {}
    set totals [dict create names 0 headings 0 options 0]
    foreach {product archive} {tcl tcl904-src.zip tk tk904-src.zip} {
        set mount [zipfs mount [file join $cache downloads $archive] rgt-$product-[pid]]
        try {
            set directory $mount/${product}9.0.4/doc
            foreach path [lsort [glob -types f -directory $directory -- *.1 *.3 *.n]] {
                set file [file tail $path]
                set base [string tolower [file rootname $file]]
                set section [string range [file extension $file] 1 end]
                set kind [dict get {1 application 3 c-api n command} $section]
                set id $product/$kind/$base
                lappend checked $id
                set row [fixture eval {SELECT names,body FROM page WHERE id=$id AND kind=$kind AND version='9.0.4'}]
                if {[llength $row] != 2} {fail "missing pinned $product 9.0.4 manual $file ($id)"}
                lassign $row dbNames body
                set input [open $path rb]
                try {set bytes [read $input]} finally {close $input}
                set original [list $file source/$product/doc/$file [hash sum sha256 $bytes]]
                if {[fixture eval {SELECT source_file,raw_path,source_sha256 FROM provenance WHERE id=$id}] ne $original} {
                    fail "$file source identity or original checksum differs from its pinned archive"
                }
                set source [encoding convertfrom -profile strict utf-8 $bytes]
                set lines [split [string map {\r\n \n} $source] \n]
                set names [sourceNames $lines $file]
                if {$names ne $dbNames} {fail "$file NAME field changed during conversion"}
                set aliases [list $file]
                foreach name $names {
                    lappend aliases $name "$product:$name" "${name}($section)"
                    dict incr totals names
                }
                if {$kind eq "application"} {lappend aliases ${base}9.0 ${base}90.exe ${base}90s.exe}
                foreach alias $aliases {
                    set alias [string tolower $alias]
                    if {![fixture exists {SELECT 1 FROM alias WHERE name=$alias AND id=$id}]} {
                        fail "$file lost lookup alias $alias"
                    }
                }
                set phrase "names:\"[lindex $names 0]\""
                if {![fixture exists {SELECT 1 FROM search WHERE search MATCH $phrase AND rowid=(SELECT rowid FROM page WHERE id=$id)}]} {
                    fail "$file is missing from the FTS5 index"
                }
                checkManualSections $id $product $file $lines $body totals
            }
        } finally {zipfs unmount $mount}
    }
    set published [fixture eval {SELECT id FROM page WHERE product IN ('tcl','tk') AND kind IN ('application','c-api','command') ORDER BY id}]
    if {[lsort $checked] ne $published || $totals ne {names 1249 headings 3204 options 795}} {
        fail "published manuals differ from the pinned 9.0.4 sources: $totals"
    }
    puts "matched [llength $checked] upstream manuals, [dict get $totals names] names, [dict get $totals headings] headings and [dict get $totals options] Tk option declarations"
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
    set work [file normalize [file tempdir [file join $temp {ref test}]]]
    set owned [::machteld::_canon_key [canon $work]]
    set first [file join $work "first pack"]
    set second [file join $work "second pack"]
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
        set firstDb [databaseFile $first]
        set firstHash [hash file sha256 $firstDb]
        set secondHash [hash file sha256 [databaseFile $second]]
        if {$firstHash ne $secondHash} {
            fail "reference.db differs between runs: $firstHash and $secondHash"
        }
        if {![llength [info commands ::sqlite3]]} {load [file join $cache prefix bin refsqlite.dll] Sqlite3}
        sqlite3 ::rgt::fixture $firstDb -readonly 1
        try {
            if {[fixture onecolumn {SELECT value FROM metadata WHERE key='machteld_version'}] ne $runtimeVersion ||
                [fixture onecolumn {PRAGMA application_id}] != 1296323122 || [fixture onecolumn {PRAGMA user_version}] != 2} {
                fail "the reference database lacks its runtime/schema identity"
            }
            if {![fixture exists {SELECT 1 FROM search WHERE search MATCH 'embedded' AND id='machteld/start-here'}] ||
                ![fixture exists {SELECT 1 FROM alias WHERE name='agents.md' AND id='machteld/agent'}]} {
                fail "start and agent instructions are not discoverable as Markdown pages"
            }
            set manualId machteld/guide/application-compiler
            set relative packages/application-compiler/README.md
            set original [string map [list \r\n \n \r \n] [readUtf8 [file join $root $relative]]]
            if {[fixture onecolumn {SELECT body FROM page WHERE id=$manualId AND kind='guide'}] ne $original ||
                    [fixture onecolumn {SELECT count(*) FROM page WHERE body=$original}] != 1 ||
                    [fixture onecolumn {SELECT source_sha256 FROM provenance WHERE id=$manualId AND source_file=$relative}]
                        ne [hash file sha256 [file join $root $relative]]} {
                fail "the compiler manual must be a single page from the original packaged README"
            }
            if {![fixture exists {SELECT 1 FROM search WHERE search MATCH '"scrutinee"' AND id=$manualId}] ||
                    [fixture eval {SELECT id,slug FROM fragment WHERE name='project check'}] ne
                        [list $manualId migrating-a-tcl-tk-project-one-file-at-a-time]} {
                fail "the compiler's language text or exact project command is missing from the reference"
            }
            if {[fixture onecolumn {SELECT count(*) FROM provenance}] != [fixture onecolumn {SELECT count(*) FROM page}] ||
                ![fixture exists {SELECT 1 FROM provenance WHERE id='tcl/command/dict' AND length(source_sha256)=64}]} {
                fail "the database lost original source provenance"
            }
            if {![fixture exists {SELECT 1 FROM notice_block WHERE id='tcl/command/dict' AND typeof(body)='blob'
                    AND instr(CAST(body AS TEXT),'Donal K. Fellows') AND instr(CAST(body AS TEXT),char(92)||'"')}]} {
                fail "the upstream roff attribution no longer has its verbatim bytes"
            }
            foreach {id file} {machteld LICENSE tcl licenses/Tcl-9.0.4.txt tk licenses/Tk-9.0.4.txt cffi licenses/cffi-2.0.3.txt} {
                set id $id/license
                if {[hash file sha256 [file join $root $file]] ne
                        [hash sum sha256 [fixture onecolumn {SELECT CAST(body AS BLOB) FROM page WHERE id=$id}]]} {
                    fail "verbatim distribution notice changed for $id"
                }
            }
            if {[fixture eval {SELECT name,documents,manual_pages FROM product WHERE name IN ('tcl','tk','cffi') ORDER BY name}]
                    ne {cffi 5 4 tcl 250 249 tk 178 177}} {fail "unexpected upstream manual counts"}
            checkCoreManuals $cache
            set id cffi/manual/commands
            set path [file join $cache cffi-doc cffi-cffi.3tcl]
            if {[hash file sha256 $path] ne [fixture onecolumn {SELECT source_sha256 FROM provenance WHERE id=$id}]} {
                fail "cffi command documentation no longer identifies its original source"
            }
            # Each outdented label in the Ruff manual introduces one distinct
            # command or method. Verify against the pinned input independently
            # of the generator's aliases or slug normalization.
            set labels 0
            set previous ""
            foreach line [split [readUtf8 $path] \n] {
                set line [string trimright $line \r]
                if {$previous eq ".RS -4n"} {
                    set heading [string map [list {\fB} "" {\fR} ""] $line]
                    if {![fixture exists {SELECT 1 FROM section WHERE id=$id AND heading=$heading
                            AND end-start BETWEEN 50 AND 8192}]} {fail "missing bounded cffi entry: $heading"}
                    incr labels
                }
                set previous $line
            }
            if {$labels != 137} {fail "unexpected upstream cffi command and method count: $labels"}
            foreach required {tcl/command/dict tcl/command/http tcl/c-api/crtobjcmd tk/command/bind machteld/package/sqlite3 machteld/agent machteld/license tcl/license tk/license} {
                if {![fixture exists {SELECT 1 FROM page WHERE id=$required}]} {fail "missing stable page $required"}
            }
            fixture eval {SELECT id,path,body,sha256,characters,bytes FROM page ORDER BY id} {
                if {$id ne [string tolower $id] || $id in {machteld/command/macht machteld/guide/engine} ||
                        [regexp {/(?:tdbc|itcl|tclx|tktable)(?:/|$)} $id] ||
                        ([regexp {/sqlite3(?:/|$)} $id] && $id ne "machteld/package/sqlite3") ||
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

        puts "REFERENCE GENERATOR TEST PASSED (one byte-identical reference.db, SHA-256 $firstHash, Tcl 249 / Tk 177)"
    } finally {
        if {$keepWork} {
            puts "reference test work kept: [file nativename $work]"
        } elseif {[file dirname $work] eq $temp && [file isdirectory $work] &&
                ![catch {::machteld::_canon_key [canon $work]} identity] && $identity eq $owned} {
            file delete -force -- $work
        }
    }
}

try {
    ::rgt::main $argv
} trap {RGT fail} {message} {
    puts stderr $message
    exit 1
}
