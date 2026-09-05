# Validate the authored Machteld command-reference corpus against public
# metadata. This checker deliberately understands only the corpus's tiny front
# matter grammar and explicit HTML anchors; it does not parse Markdown prose.

set ROOT [file dirname [file dirname [file normalize [info script]]]]
set REFDIR [file join $ROOT docs reference machteld command]

proc fail message {
    puts stderr "check_reference: $message"
    exit 1
}
proc read_utf8_lf path {
    set ch [open $path rb]
    set bytes [read $ch]
    close $ch
    if {[string first "\r" $bytes] >= 0} { fail "$path is not LF-only" }
    if {[catch {encoding convertfrom utf-8 $bytes} text]} {
        fail "$path is not valid UTF-8: $text"
    }
    return $text
}
proc front_matter {path text} {
    set lines [split $text \n]
    if {[lindex $lines 0] ne "---"} { fail "$path has no front matter" }
    set out {}
    set end [lsearch -exact [lrange $lines 1 end] ---]
    if {$end < 0} { fail "$path has unterminated front matter" }
    incr end
    foreach line [lrange $lines 1 [expr {$end - 1}]] {
        if {![regexp {^([a-z_]+):[ ]?(.*)$} $line -> key value]} {
            fail "$path has unsupported front matter line {$line}"
        }
        if {[dict exists $out $key]} { fail "$path repeats front matter key $key" }
        dict set out $key $value
    }
    set required {id type title summary commands}
    if {[lsort [dict keys $out]] ne [lsort $required]} {
        fail "$path front matter keys must be exactly {$required}"
    }
    foreach key {id type title summary} {
        if {[dict get $out $key] eq ""} { fail "$path has empty $key" }
    }
    return $out
}
proc comma_list value {
    set out {}
    foreach item [split $value ,] {
        set item [string trim $item]
        if {$item ne ""} { lappend out $item }
    }
    return $out
}

if {![file isdirectory $REFDIR]} { fail "missing $REFDIR" }
source [file join $ROOT tools manifest_spec.tcl]
set expected $::machteld::manifest::native

# Source the real Tcl metadata in an isolated interpreter. A stub native PTY
# lets machteld.tcl install its public Tcl extension without loading the host;
# no command body is invoked. This exercises exactly the authored MetaDefine
# values, including subcommands and documentation IDs.
# The same files in the same order as the packaged prelude (tools/build.tcl);
# every one is required, so a missing module fails here as it fails the build.
set tclFiles {}
foreach name {machteld docs cli log worker pool pmap} {
    set tclFile [file join $ROOT tcl $name.tcl]
    if {![file exists $tclFile]} { error "check_reference: missing prelude module $tclFile" }
    lappend tclFiles $tclFile
}
set slave [interp create]
interp eval $slave {namespace eval ::machteld {}; proc ::machteld::pty args {}}
foreach path $tclFiles {
    read_utf8_lf $path
    if {[catch {interp eval $slave [list source $path]} message options]} {
        interp delete $slave
        fail "cannot evaluate metadata from $path: $message"
    }
}
set tclManifest [interp eval $slave {set ::machteld::TCL_MANIFEST}]
interp delete $slave
dict for {verb entry} $tclManifest {
    if {![dict exists $entry doc]} {
        fail "Tcl metadata for $verb has no explicit doc field"
    }
    if {[dict exists $expected $verb]} {
        set merged [dict get $expected $verb]
        if {[dict exists $entry subcommands]} {
            set subs [expr {[dict exists $merged subcommands]
                            ? [dict get $merged subcommands] : {}}]
            dict for {sub facts} [dict get $entry subcommands] {
                if {[dict exists $subs $sub]} {
                    fail "Tcl metadata duplicates native $verb subcommand $sub"
                }
                dict set subs $sub $facts
            }
            dict set merged subcommands $subs
        }
        dict set merged doc [dict get $entry doc]
        dict set expected $verb $merged
    } else {
        dict set expected $verb $entry
    }
}

set requiredSections {Synopsis {Arguments and options} Results Errors \
    {Lifetime and timeouts} Examples Constraints {See also}}
set seen {}
set pageText {}
set anchors {}
foreach path [lsort [glob -nocomplain -directory $REFDIR *.md]] {
    set text [read_utf8_lf $path]
    set fm [front_matter $path $text]
    set verb [file rootname [file tail $path]]
    set wantId "machteld/command/$verb"
    if {[dict get $fm id] ne $wantId} { fail "$path id is not $wantId" }
    if {![dict exists $expected $verb doc]} {
        fail "metadata for $verb has no explicit doc field"
    }
    if {[dict get $expected $verb doc] ne $wantId} {
        fail "metadata doc for $verb is not $wantId"
    }
    if {[dict get $fm type] ne "command"} { fail "$path type is not command" }
    set commands [comma_list [dict get $fm commands]]
    if {$verb ni $commands} { fail "$path commands does not name $verb" }
    if {[dict exists $seen $verb]} { fail "duplicate page for $verb" }
    dict set seen $verb 1
    dict set pageText $wantId $text
    set pageAnchors {}
    foreach {_ anchor} [regexp -all -inline {<a id="([a-z][a-z0-9-]*)"></a>} $text] {
        if {$anchor in $pageAnchors} { fail "$path repeats anchor $anchor" }
        lappend pageAnchors $anchor
    }
    dict set anchors $wantId $pageAnchors
    set lines [split $text \n]
    foreach section $requiredSections {
        if {[lsearch -exact $lines "## $section"] < 0} {
            fail "$path lacks mandatory section {$section}"
        }
    }
    if {[dict exists $expected $verb subcommands]} {
        dict for {sub subentry} [dict get $expected $verb subcommands] {
            set subId "$wantId#$sub"
            if {![dict exists $subentry doc] || [dict get $subentry doc] ne $subId} {
                fail "metadata doc for $verb $sub is not $subId"
            }
            if {[string first "<a id=\"$sub\"></a>" $text] < 0} {
                fail "$path lacks explicit anchor for subcommand $sub"
            }
            set marker "<a id=\"$sub\"></a>"
            set begin [string first $marker $text]
            set finish [string first {<a id="} $text [expr {$begin + [string length $marker]}]]
            if {$finish < 0} { set finish end }
            set subtext [string range $text $begin $finish]
            set sublines [split $subtext \n]
            foreach section $requiredSections {
                if {[lsearch -exact $sublines "#### $section"] < 0} {
                    fail "$path subcommand $sub lacks section {$section}"
                }
            }
            if {"$verb $sub" ni $commands} {
                fail "$path commands omits {$verb $sub}"
            }
        }
    }
    set expectedCommands [list $verb]
    if {[dict exists $expected $verb subcommands]} {
        foreach sub [dict keys [dict get $expected $verb subcommands]] {
            lappend expectedCommands "$verb $sub"
        }
    }
    if {[lsort -unique $commands] ne [lsort $expectedCommands] ||
            [llength $commands] != [llength [lsort -unique $commands]]} {
        fail "$path commands must be exactly {[lsort $expectedCommands]}"
    }
}

foreach verb [dict keys $expected] {
    if {![dict exists $seen $verb]} { fail "public command $verb has no reference page" }
}
foreach verb [dict keys $seen] {
    if {![dict exists $expected $verb]} { fail "reference page $verb is not a public command" }
}

# Resolve authored Machteld IDs and fragments. Upstream Tcl/Tk IDs are checked
# by the reference generator against its own inventories.
set valid [dict create machteld/index 1 machteld/agent 1]
foreach special {index.md agent.md} {
    set specialPath [file join $ROOT docs reference machteld $special]
    if {![file isfile $specialPath]} { fail "missing $specialPath" }
    set fm [front_matter $specialPath [read_utf8_lf $specialPath]]
    set expectedId [expr {$special eq "index.md" ? "machteld/index" : "machteld/agent"}]
    if {[dict get $fm id] ne $expectedId} { fail "$specialPath id is not $expectedId" }
}
dict for {id text} $pageText { dict set valid $id 1 }
foreach guide [glob -nocomplain -directory [file join $ROOT docs] *.md] {
    dict set valid "machteld/guide/[file rootname [file tail $guide]]" 1
}
set referenceFiles [concat [glob -nocomplain -directory [file join $ROOT docs reference machteld] *.md] \
    [glob -nocomplain -directory $REFDIR *.md]]
foreach path $referenceFiles {
    set text [read_utf8_lf $path]
    foreach ref [regexp -all -inline {machteld/(?:command/[a-z][a-z0-9-]*(?:#[a-z][a-z0-9-]*)?|guide/[a-z][a-z0-9-]*|agent|index)} $text] {
        lassign [split $ref #] base fragment
        if {![dict exists $valid $base]} { fail "$path links to missing ID $base" }
        if {$fragment ne "" && (![dict exists $anchors $base] ||
                $fragment ni [dict get $anchors $base])} {
            fail "$path links to missing fragment $ref"
        }
    }
}

puts "check_reference: [dict size $seen] command pages cover every public command and subcommand"
