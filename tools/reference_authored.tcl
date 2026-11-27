# Authored reference sources and their stable links. Loaded by the generator
# on the build host and by coverage checks on Tcl and on the candidate.
namespace eval ::ref {}

proc ::ref::fail {message} {
    return -code error -errorcode {REFERENCE fail} "generate-reference: $message"
}

proc ::ref::authoredSources {root} {
    set sources {}
    set docs [file join [file normalize $root] docs]
    set reference [file join $docs reference machteld]
    set pages {}
    foreach directory [list $reference [file join $reference command]] {
        foreach path [glob -nocomplain -type f -directory $directory *.md] {
            # Preserve the catalog generation order on Windows.
            lappend pages [list [string map {/ \\} [file nativename $path]] $path]
        }
    }
    foreach page [lsort -index 0 $pages] {dict set sources [lindex $page 1] reference}
    foreach path [lsort [glob -nocomplain -type f -directory $docs *.md]] {
        dict set sources $path guide
    }
    return $sources
}

proc ::ref::guideBase {path} {
    return [file rootname [file tail $path]]
}

proc ::ref::authoredTarget {sourceKind target} {
    if {[regexp {^[A-Za-z][A-Za-z0-9+.-]*:} $target] || [string match #* $target]} {return $target}
    set hash [string first # $target]
    if {$hash >= 0} {
        set path [string range $target 0 [expr {$hash - 1}]]
        set fragment [string range $target $hash end]
    } else {
        set path $target
        set fragment ""
    }
    if {$sourceKind eq "guide"} {
        if {[regexp -nocase {^reference/machteld/(index|agent)\.md$} $path -> m]} {
            set stable machteld/$m
        } elseif {[regexp -nocase {^reference/machteld/command/([a-z0-9-]+)\.md$} $path -> m]} {
            set stable machteld/command/$m
        } elseif {[regexp -nocase {^([a-z0-9-]+)\.md$} $path -> m]} {
            set stable machteld/guide/$m
        } else {
            fail "unsupported authored guide link target $target"
        }
    } else {
        if {[regexp -nocase {^command/([a-z0-9-]+)\.md$} $path -> m]} {
            set stable machteld/command/$m
        } elseif {[regexp -nocase {^(index|agent)\.md$} $path -> m]} {
            set stable machteld/$m
        } else {
            fail "unsupported authored reference link target $target"
        }
    }
    return $stable$fragment
}

proc ::ref::rewriteAuthoredLinks {text sourceKind} {
    # Section offsets address the canonical LF text that ships.
    set text [string map [list \r\n \n \r \n] $text]
    set out ""
    set at 0
    foreach {whole target} [regexp -all -inline -indices {\[[^\]]+\]\(([^)]+)\)} $text] {
        lassign $target from to
        append out [string range $text $at [expr {$from-1}]]
        append out [authoredTarget $sourceKind [string range $text $from $to]]
        set at [expr {$to+1}]
    }
    append out [string range $text $at end]
}
