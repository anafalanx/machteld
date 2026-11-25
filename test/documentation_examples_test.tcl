package require machteld

if {[llength $argv]} {error "usage: documentation_examples_test.tcl"}
set ROOT [file dirname [file dirname [file normalize [info script]]]]
set HOST [info nameofexecutable]
set checks 0
set fails 0
proc check {name condition} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc read_text {path} {
    set channel [open $path rb]
    try { return [encoding convertfrom -profile strict utf-8 [read $channel]] } finally { close $channel }
}
proc write_text {path text} {
    set channel [open $path {WRONLY CREAT EXCL}]
    try {
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel $text
    } finally { close $channel }
}
proc snippets {text} {
    set found {}
    set pending {}
    set active {}
    foreach row [split [string map [list \r\n \n] $text] \n] {
        if {$active ne {}} {
            if {$row eq {```}} {
                dict set found $active [dict create language $language body [join $lines \n]]
                set active {}
            } else { lappend lines $row }
        } elseif {[regexp {^<!-- machteld-example: ([a-z-]+) -->$} $row -> name]} {
            if {$pending ne {} || [dict exists $found $name]} { error "duplicate/unconsumed example marker: $name" }
            set pending $name
        } elseif {[regexp {^```(.*)$} $row -> language]} {
            if {$pending eq {}} { error "unmarked README code block: $row" }
            if {$language ni {tcl text}} { error "unsupported example language: $language" }
            set active $pending
            set pending {}
            set lines {}
        } elseif {$pending ne {} && [string trim $row] ne {}} {
            error "example marker must immediately precede its code block: $pending"
        }
    }
    if {$active ne {} || $pending ne {}} { error "unterminated README example" }
    if {[lsort [dict keys $found]] ne {app archive direct docs supervise supervised}} {
        error "update documentation acceptance for changed README examples: [dict keys $found]"
    }
    foreach name {app supervise} {
        if {[dict get $found $name language] ne {tcl}} { error "expected Tcl example: $name" }
    }
    foreach name {archive direct docs supervised} {
        if {[dict get $found $name language] ne {text}} { error "expected command example: $name" }
    }
    return $found
}
proc command {line} {
    # These documented commands use list-compatible quotes, not shell operators.
    # Refuse new executables until their acceptance is deliberately implemented.
    if {![llength $line]} { error "empty example command" }
    set program [lindex $line 0]
    switch -exact -- $program {
        machteld.exe { set executable $::HOST }
        default { error "unrecognized README executable: $program" }
    }
    # Bundling the complete reference processes every embedded file. Give
    # this packaging step the same bound as the legacy compatibility lane.
    set deadline 120s
    if {[lrange $line 0 1] eq {machteld.exe wrap} && "--with-docs" in $line} {
        set deadline 600s
    }
    set result [run -timeout $deadline -- $executable {*}[lrange $line 1 end]]
    check "README command succeeds: $line" [expr {
        [dict get $result status] eq "ok" && [dict get $result exit] == 0}]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        error "README command failed: $line: $result"
    }
    return [encoding convertfrom -profile strict utf-8 [dict get $result out]]
}
proc documentation_pages {directory {examples 0}} {
    set pages {}
    foreach path [glob -nocomplain -directory $directory *] {
        if {[file type $path] eq {directory}} {
            lappend pages {*}[documentation_pages $path $examples]
        } elseif {[file extension $path] eq {.md} && (!$examples || [file tail $path] eq {README.md})} {
            lappend pages $path
        }
    }
    return $pages
}
set examples [snippets [read_text [file join $ROOT README.md]]]
check {all documented README examples are covered} [expr {
    [lsort [dict keys $examples]] eq {app archive direct docs supervise supervised}}]

# File links are checked in authored sources, not the immutable release corpus.
# The present authored inline links have no local fragments or escaped targets.
# A link must name a file every clone has: one inside the repository and
# outside the root folders .gitignore ignores (/dist/, /out/ and the like),
# which only the machine that filled them has. Existence alone is not enough:
# on the build PC the ignored dist/0.21 holds the signed runtime's notes.
set IGNORED {}
foreach row [split [string map [list \r\n \n] [read_text [file join $ROOT .gitignore]]] \n] {
    if {[regexp {^/([^/*?\[\]!#]+)/$} [string trim $row] -> folder]} { lappend IGNORED $folder }
}
check "the root folders git ignores are read from .gitignore: $IGNORED" [expr {[llength $IGNORED] > 0}]
proc clone_problem {page target} {
    set path [file normalize [file join [file dirname $page] $target]]
    if {![file exists $path]} { return "missing" }
    if {![string equal -length [string length $::ROOT/] $::ROOT/ $path]} { return "outside the repository" }
    set folder [lindex [file split [string range $path [string length $::ROOT/] end]] 0]
    if {$folder in $::IGNORED} { return "in $folder/, which git ignores" }
    return ""
}
set pages [concat [glob -directory $ROOT *.md] \
    [documentation_pages [file join $ROOT docs]] \
    [documentation_pages [file join $ROOT examples] 1]]
foreach page $pages {
    foreach {whole target} [regexp -all -inline {\]\(([^)]+)\)} [read_text $page]] {
        if {[regexp {^[a-zA-Z][a-zA-Z0-9+.-]*:} $target]} { continue }
        if {[string first # $target] >= 0 || [string first % $target] >= 0} {
            error "extend link checker for fragment/escaped target in $page: $target"
        }
        set problem [clone_problem $page $target]
        if {$problem ne {}} { puts "     $target: $problem" }
        check "local link in [file tail $page]: $target" [expr {$problem eq {}}]
        # Embedded guides cannot link to checkout-only files. Match the
        # generator's supported authored-link shapes before a slow refresh.
        set relative [string range $page [expr {[string length $ROOT] + 1}] end]
        if {[string match docs/* $relative]} {
            if {[file dirname $page] eq [file join $ROOT docs]} {
                set supported [regexp {^(?:[a-z0-9-]+\.md|reference/machteld/(?:index|agent)\.md|reference/machteld/command/[a-z0-9-]+\.md)$} $target]
            } else {
                set supported [regexp {^(?:command/[a-z0-9-]+\.md|(?:index|agent)\.md)$} $target]
            }
            check "embedded link has a stable reference mapping: $target" $supported
        }
    }
}

set TEMP_ROOT [file normalize $env(TEMP)]
set WORK [file normalize [file join $TEMP_ROOT machteld-readme-[pid]-[clock clicks]]]
if {[file dirname $WORK] ne $TEMP_ROOT || [file exists $WORK]} { error "unsafe README test workspace" }
file mkdir $WORK
set previousDirectory [pwd]
try {
    cd $WORK
    write_text app.tcl [dict get $examples app body]
    write_text supervise.tcl [dict get $examples supervise body]
    file mkdir myapp
    file copy app.tcl myapp/main.tcl
    set lines [split [dict get $examples archive body] \n]
    check {two archive invocations are covered} [expr {[llength $lines] == 2}]
    command [lindex $lines 0]
    check {archived README app prints the documented greeting} [expr {
        [string trimright [command [lindex $lines 1]] \r\n] eq {Hello, world!}}]
    foreach name {direct supervised} {
        set lines [split [dict get $examples $name body] \n]
        check "$name has one invocation" [expr {[llength $lines] == 1}]
        foreach line $lines {
            check "$name prints the documented greeting" [expr {
                [string trimright [command $line] \r\n] eq {Hello, world!}}]
        }
    }
    set lines [split [dict get $examples docs body] \n]
    check {three reference invocations are covered} [expr {[llength $lines] == 3}]
    foreach line $lines {
        set response [json decode [command $line]]
        check "reference example returns a success envelope: $line" [expr {
            [dict get $response ok] && [dict exists $response result]}]
    }
} finally {
    cd $previousDirectory
    if {[file dirname $WORK] eq $TEMP_ROOT &&
            [string match machteld-readme-* [file tail $WORK]]} {
        file delete -force $WORK
    }
}
puts "documentation examples: $checks checks, $fails failures"
exit [expr {$fails != 0}]
