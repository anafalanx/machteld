# Execute the README's exact marked snippets, not separately maintained copies.
# Examples target the current checkout's runtime contract and documented version;
# older releases are not expected to satisfy future README requirements. Wrapping
# preserves optional runtime provenance, including its absence in clean release
# packaging. Never opens a GUI.
package require machteld

if {$argv ni {{} --packaging}} { error {usage: documentation_examples_test.tcl ?--packaging?} }
set packaging [expr {$argv eq {--packaging}}]
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
proc read_bytes {path} {
    set channel [open $path rb]
    try { return [read $channel] } finally { close $channel }
}
proc inherited_provenance {hostPath wrappedPath} {
    set present [file exists $hostPath]
    if {$present != [file exists $wrappedPath]} { return 0 }
    if {!$present} { return 1 }
    return [expr {[read_bytes $hostPath] eq [read_bytes $wrappedPath]}]
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
    if {[lsort [dict keys $found]] ne {app direct docs supervise supervised wrap}} {
        error "update documentation acceptance for changed README examples: [dict keys $found]"
    }
    foreach name {app supervise} {
        if {[dict get $found $name language] ne {tcl}} { error "expected Tcl example: $name" }
    }
    foreach name {direct docs supervised wrap} {
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
        app.exe - documented-app.exe { set executable [file join $::WORK $program] }
        default { error "unrecognized README executable: $program" }
    }
    set result [run -timeout 120s -- $executable {*}[lrange $line 1 end]]
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
check {all six README code blocks are covered} [expr {[dict size $examples] == 6}]

# File links are checked in authored sources, not the immutable release corpus.
# The present authored inline links have no local fragments or escaped targets.
set pages [concat [glob -directory $ROOT *.md] \
    [documentation_pages [file join $ROOT docs]] \
    [documentation_pages [file join $ROOT examples] 1]]
foreach page $pages {
    foreach {whole target} [regexp -all -inline {\]\(([^)]+)\)} [read_text $page]] {
        if {[regexp {^[a-zA-Z][a-zA-Z0-9+.-]*:} $target]} { continue }
        if {[string first # $target] >= 0 || [string first % $target] >= 0} {
            error "extend link checker for fragment/escaped target in $page: $target"
        }
        check "local link in [file tail $page]: $target" \
            [file exists [file join [file dirname $page] $target]]
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
    # Exercise both clean-release and development inheritance without building
    # another executable. Compare raw bytes: equivalent parsed dictionaries do
    # not establish that the wrapper copied the host's record unchanged.
    write_text provenance-source.dict {schema 1 channel development}
    write_text provenance-copy.dict {schema 1 channel development}
    write_text provenance-changed.dict {schema 1  channel development}
    check {absent runtime provenance remains absent} \
        [inherited_provenance provenance-absent-source.dict provenance-absent-copy.dict]
    check {wrapping cannot invent runtime provenance} \
        [expr {![inherited_provenance provenance-absent-source.dict provenance-copy.dict]}]
    check {wrapping cannot drop runtime provenance} \
        [expr {![inherited_provenance provenance-source.dict provenance-absent-copy.dict]}]
    check {runtime provenance bytes are inherited exactly} \
        [inherited_provenance provenance-source.dict provenance-copy.dict]
    check {semantically equivalent but changed provenance bytes are rejected} \
        [expr {![inherited_provenance provenance-source.dict provenance-changed.dict]}]
    write_text app.tcl [dict get $examples app body]
    write_text supervise.tcl [dict get $examples supervise body]
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
    if {$packaging} {
        set hostProvenance [file join [::machteld::PayloadRoot] build-info.dict]
        set lines [split [dict get $examples wrap body] \n]
        check {four wrapping invocations are covered} [expr {[llength $lines] == 4}]
        foreach line $lines {
            set output [command $line]
            if {[lindex $line 0] ne {machteld.exe}} {
                check "wrapped greeting: $line" [expr {[string trimright $output \r\n] eq {Hello, world!}}]
            }
        }
        foreach name {app.exe documented-app.exe} present {0 1} {
            set mount "readme-[pid]-[clock clicks]"
            zipfs mount [file join $WORK $name] $mount
            try {
                check "$name reference inclusion matches README" [expr {
                    [file exists //zipfs:/$mount/reference/catalog.dict] == $present}]
                check "$name inherits exact runtime provenance or its absence" \
                    [inherited_provenance $hostProvenance //zipfs:/$mount/build-info.dict]
                check "$name does not recursively embed wrapping hosts" [expr {
                    ![file exists //zipfs:/$mount/basekit]}]
            } finally { zipfs unmount $mount }
        }
    }
} finally {
    cd $previousDirectory
    if {[file dirname $WORK] eq $TEMP_ROOT &&
            [string match machteld-readme-* [file tail $WORK]]} {
        file delete -force $WORK
    }
}
puts "documentation examples: $checks checks, $fails failures; packaging=$packaging"
exit [expr {$fails != 0}]
