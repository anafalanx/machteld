# Every current-version claim in the prose must agree with src/machteld.h.
#
# The 0.15.1 checkpoint recorded why this exists: the release gate derived
# every TEST expectation from the header, but fourteen pages of prose still
# named the previous version, because prose was never in the gate's remit.
# This check puts it there. Release history (docs/roadmap.md) legitimately
# names old versions and is exempt from the literal sweep, but it must carry a
# section for the current version. Every other authored page and the README
# must name exactly the header's version wherever they name a Machteld version
# at all.

set ROOT [file dirname [file dirname [file normalize [info script]]]]

proc fail {message} {
    puts stderr "check_version: $message"
    exit 1
}
proc slurp {path} {
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    if {[catch {encoding convertfrom -profile strict utf-8 $bytes} text]} {
        fail "$path is not valid UTF-8"
    }
    return $text
}

set header [slurp [file join $ROOT src machteld.h]]
if {![regexp -line {^#define[ \t]+MACHTELD_VERSION[ \t]+"([0-9]+\.[0-9]+(?:\.[0-9]+)?)"[ \t]*$} \
        $header -> current]} {
    fail "src/machteld.h has no canonical MACHTELD_VERSION"
}

# The prelude's package version is the one authored Tcl literal; the wrap
# launcher derives its pin from it at run time and must not carry its own.
set prelude [slurp [file join $ROOT tcl machteld.tcl]]
if {![regexp -line {^\s*variable version ([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$} $prelude -> preludeVersion]} {
    fail "tcl/machteld.tcl has no canonical version variable"
}
if {$preludeVersion ne $current} {
    fail "tcl/machteld.tcl declares $preludeVersion but src/machteld.h declares $current"
}
if {[regexp {package require machteld [0-9]} $prelude]} {
    fail "tcl/machteld.tcl carries a literal launcher pin; the launcher must derive it from ::machteld::version"
}

# A Machteld version literal is a two- or three-part 0.NN version. It is not
# preceded by another version component (so Tcl's 9.0.4 does not match its 0.4
# tail) and it is not the pinned yyjson release, the one other 0.NN version the
# prose legitimately names.
set pages [list [file join $ROOT README.md]]
foreach directory [list [file join $ROOT docs] \
        [file join $ROOT docs reference machteld] \
        [file join $ROOT docs reference machteld command]] {
    foreach page [lsort [glob -nocomplain -directory $directory *.md]] {
        if {[file tail $page] eq "roadmap.md"} continue
        lappend pages $page
    }
}
set pattern {(?:^|[^0-9.])(0\.[0-9]{2}(?:\.[0-9]+)?)(?![0-9.])}
set problems {}
set claims 0
foreach page $pages {
    set line 0
    foreach row [split [slurp $page] \n] {
        incr line
        foreach {whole range} [regexp -all -inline -indices $pattern $row] {
            lassign $range start end
            set version [string range $row $start $end]
            set before [string range $row 0 [expr {$start - 1}]]
            if {[regexp -nocase {yyjson[- ]$} $before]} continue
            incr claims
            if {$version ne $current} {
                lappend problems "[file tail $page]:$line names $version"
            }
        }
    }
}
if {[llength $problems]} {
    fail "stale version claims (current is $current):\n  [join $problems "\n  "]"
}

set roadmap [slurp [file join $ROOT docs roadmap.md]]
if {![regexp -line "^## $current\\M" $roadmap]} {
    fail "docs/roadmap.md has no section for the current version $current"
}

puts "check_version: $claims prose claims agree with src/machteld.h ($current); prelude and roadmap agree"
