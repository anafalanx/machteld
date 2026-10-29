# Check explicit current-runtime claims, not arbitrary version-shaped numbers.
# Root Markdown, docs/**/*.md and examples/**/README.md are strict UTF-8.
# Named Machteld/runtime claims and version-first root/docs headings are current
# unless enclosed in balanced, standalone history markers:
#   <!-- machteld-version-history: begin -->
#   <!-- machteld-version-history: end -->
# Markers cannot exempt front matter. An inline
#   <!-- machteld-version-current -->
# marks every numeric version on that line as a current-runtime claim; use it
# for otherwise ambiguous bare result values, not mixed dependency/app versions.
# This explicit-claim gate is not a semantic proof of arbitrary Markdown prose.

set ROOT [file dirname [file dirname [file normalize [info script]]]]

proc fail {message} {
    puts stderr "check_version: $message"
    exit 1
}
if {[llength $argv]} {
    if {[llength $argv] != 2 || [lindex $argv 0] ne "--root"} {
        fail "usage: check_version.tcl ?--root checkout?"
    }
    set ROOT [file normalize [lindex $argv 1]]
}

proc slurp {path} {
    set channel [open $path rb]
    try { set bytes [read $channel] } finally { close $channel }
    if {[catch {encoding convertfrom -profile strict utf-8 $bytes} text]} {
        fail "$path is not valid UTF-8"
    }
    return $text
}

proc authored_pages {directory examples} {
    set pages {}
    foreach path [lsort [glob -nocomplain -directory $directory *]] {
        # Refuse rather than silently follow links into an unbounded/outside
        # tree. Authored documentation directories are ordinary source files.
        set type [file type $path]
        if {$type eq "link"} { fail "linked documentation path is unsupported: $path" }
        if {$type eq "directory"} {
            lappend pages {*}[authored_pages $path $examples]
        } elseif {$type eq "file" &&
                [string equal -nocase [file extension $path] .md] &&
                (!$examples || [string equal -nocase [file tail $path] README.md])} {
            lappend pages $path
        }
    }
    return $pages
}

set header [slurp [file join $ROOT src machteld.h]]
set declarations [regexp -all -inline -line \
    {^#define[ \t]+MACHTELD_VERSION[ \t]+"([0-9]+\.[0-9]+(?:\.[0-9]+)?)"[ \t]*\r?$} $header]
if {[llength $declarations] != 2} {
    fail "src/machteld.h must have one canonical MACHTELD_VERSION"
}
set current [lindex $declarations 1]

# The prelude owns the authored package literal. The wrap launcher derives its
# pin from that value and must not carry an independent one.
set prelude [slurp [file join $ROOT tcl machteld.tcl]]
set declarations [regexp -all -inline -line \
    {^[ \t]*variable version ([0-9]+\.[0-9]+(?:\.[0-9]+)?)[ \t]*\r?$} $prelude]
if {[llength $declarations] != 2} {
    fail "tcl/machteld.tcl must have one canonical version variable"
}
set preludeVersion [lindex $declarations 1]
if {$preludeVersion ne $current} {
    fail "tcl/machteld.tcl declares $preludeVersion but src/machteld.h declares $current"
}
if {[regexp {package\s+require\s+(?:-exact\s+)?machteld\s+[0-9]} $prelude]} {
    fail "tcl/machteld.tcl carries a literal launcher pin; the launcher must derive it from ::machteld::version"
}

set pages [lsort [glob -nocomplain -directory $ROOT *.md]]
if {[file join $ROOT README.md] ni $pages} { fail "README.md is missing" }
lappend pages {*}[authored_pages [file join $ROOT docs] 0]
lappend pages {*}[authored_pages [file join $ROOT examples] 1]

# Capture only the version in each expression. Positions are deduplicated when
# a line has more than one matching form. In particular a dependency/app number
# never exempts a separate Machteld claim on the same line.
set namedPatterns {
    {\mmachteld[ \t]+(?:version[ \t]+)?[*`]*([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?![0-9]|\.[0-9])}
    {\mruntime[ \t]+version[ \t]+[*`]*([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?![0-9]|\.[0-9])}
}
set prosePattern {(?:^[ \t]*(?:[-*>][ \t]+)?|[.!?][ \t]+)version[ \t]+[*`]*([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?![0-9]|\.[0-9])}
set headingPattern {^[ \t]*#{1,6}[ \t]+(?:v(?:ersion[ \t]+)?)?[*`]*([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?![0-9]|\.[0-9])}
set allVersions {(?:^|[^0-9.])([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?![0-9]|\.[0-9])}
set problems {}
set claims 0
set historicalClaims 0
set roadmapCurrent 0
set beginMarker {<!-- machteld-version-history: begin -->}
set endMarker {<!-- machteld-version-history: end -->}
set currentMarker {<!-- machteld-version-current -->}

foreach page $pages {
    set relative [string range $page [expr {[string length $ROOT] + 1}] end]
    set example [string match examples/* $relative]
    set inHistory 0
    set frontMatter 0
    set fenceChar {}
    set fenceWidth 0
    set line 0
    foreach row [split [slurp $page] \n] {
        incr line
        set row [string trimright $row \r]
        if {$line == 1} { set row [string trimleft $row \ufeff] }
        if {$line == 1 && $row eq "---"} {
            set frontMatter 1
            continue
        }
        if {$frontMatter && $row eq "---"} {
            set frontMatter 0
            continue
        }
        if {!$frontMatter && [regexp {^[ \t]{0,3}(`{3,}|~{3,})(.*)$} $row -> fence tail]} {
            if {$fenceChar eq {}} {
                set fenceChar [string index $fence 0]
                set fenceWidth [string length $fence]
                continue
            } elseif {[string index $fence 0] eq $fenceChar &&
                    [string length $fence] >= $fenceWidth && [string trim $tail] eq {}} {
                set fenceChar {}
                continue
            }
        }
        # In a fenced example, a manifest's `version 1.0` belongs to its app;
        # named Machteld/package requirements still describe the runtime.
        # Annotation examples inside fences are inert, like other code text.
        set markedCurrent [expr {$fenceChar eq {} && [string first $currentMarker $row] >= 0}]
        if {$fenceChar eq {} && [regexp -nocase {<!--[ \t]*machteld-version-} $row]} {
            if {$frontMatter} { fail "$relative:$line version annotations are forbidden in front matter" }
            set annotation [string trim $row]
            if {$annotation eq $beginMarker} {
                if {$inHistory} { fail "$relative:$line nested version history" }
                set inHistory $line
                continue
            } elseif {$annotation eq $endMarker} {
                if {!$inHistory} { fail "$relative:$line unmatched version history end" }
                set inHistory 0
                continue
            } else {
                set remainder [string map [list $currentMarker {}] $row]
                if {[regexp -nocase {<!--[ \t]*machteld-version-} $remainder] ||
                        [string first $currentMarker $row] == -1 ||
                        [regexp -all {<!-- machteld-version-current -->} $row] != 1} {
                    fail "$relative:$line malformed version annotation"
                }
                if {$inHistory} { fail "$relative:$line current annotation inside version history" }
            }
        }

        set found {}
        set patterns $namedPatterns
        if {$fenceChar eq {}} {
            lappend patterns $prosePattern
            if {!$example} { lappend patterns $headingPattern }
        }
        if {$markedCurrent} {
            set patterns [list $allVersions]
        }
        foreach pattern $patterns {
            foreach {whole range} [regexp -nocase -all -inline -indices $pattern $row] {
                lassign $range start end
                dict set found $start [string range $row $start $end]
            }
        }
        if {$markedCurrent && ![dict size $found]} {
            fail "$relative:$line current annotation has no version"
        }
        if {$inHistory} {
            incr historicalClaims [dict size $found]
            continue
        }
        if {$relative eq "docs/roadmap.md" && $fenceChar eq {} &&
                [regexp -nocase $headingPattern $row -> headingVersion] &&
                $headingVersion eq $current} {
            set roadmapCurrent 1
        }
        dict for {position version} $found {
            incr claims
            if {$version ne $current} {
                lappend problems "$relative:$line claims $version"
            }
        }
    }
    if {$inHistory} { fail "$relative:$inHistory unterminated version history" }
    if {$frontMatter} { fail "$relative has unterminated front matter" }
}
if {[llength $problems]} {
    fail "stale current-runtime claims (current is $current):\n  [join $problems "\n  "]"
}
if {!$roadmapCurrent} {
    fail "docs/roadmap.md has no current-version heading outside history for $current"
}
puts "check_version: $claims explicit current-runtime claims agree with src/machteld.h ($current); $historicalClaims historical claims retained; prelude and roadmap agree"
