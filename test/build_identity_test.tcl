# Run with the bundled static Tcl 9 interpreter; optional argv[0] is a built
# Machteld executable to inspect (including provenance inherited by wrappers).
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT tools build_identity.tcl]
set failures 0
proc check {name ok} {
    if {$ok} { puts "ok   $name" } else { incr ::failures; puts "FAIL $name" }
}
proc bytes {path value} {
    file mkdir [file dirname $path]
    set f [open $path wb]
    try { puts -nonewline $f $value } finally { close $f }
}
proc slurp {path} {
    set f [open $path rb]
    try { return [read $f] } finally { close $f }
}
set marker [file tempfile claim [file join $env(TEMP) machteld-build-identity-]]
set work ${claim}.d
if {[file exists $work]} { close $marker; error "test namespace collision: $work" }
file mkdir $work
try {
    regexp -line {^#define MACHTELD_VERSION "([^"]+)"} \
        [slurp [file join $ROOT src machteld.h]] -> runtime
    set good [dict create schema 1 channel development runtime_version $runtime \
        source_revision [string repeat a 40] input_sha256 [string repeat b 64] \
        reference_sha256 [string repeat c 64]]
    check "identity separates API version, build inputs and reference" \
        [expr {[::machteld::buildidentity::validate $good] eq $good}]
    set path [file join $work identity.dict]
    ::machteld::buildidentity::write $path $good
    check "identity round-trips as inert data" \
        [expr {[::machteld::buildidentity::read $path] eq $good}]
    check "identity writer refuses replacement" \
        [expr {[catch {::machteld::buildidentity::write $path $good}] &&
            [::machteld::buildidentity::read $path] eq $good}]
    foreach {label record} [list \
            missing [dict remove $good channel] \
            duplicate [concat $good {schema 1}] \
            unknown [dict replace $good unexpected value] \
            schema [dict replace $good schema 2] \
            channel [dict replace $good channel release] \
            "dotted version" [dict replace $good runtime_version 0.22] \
            "zero-padded version" [dict replace $good runtime_version 022] \
            "zero version" [dict replace $good runtime_version 0] \
            revision [dict replace $good source_revision {C:/private/source}] \
            input [dict replace $good input_sha256 BAD] \
            reference [dict replace $good reference_sha256 {}]] {
        check "identity refuses $label" [catch {::machteld::buildidentity::validate $record}]
    }
    set ::identityWasExecuted 0
    bytes [file join $work script.dict] {set ::identityWasExecuted 1}
    check "identity data is never evaluated" [expr {
        [catch {::machteld::buildidentity::read [file join $work script.dict]}] && !$::identityWasExecuted}]
    bytes [file join $work huge.dict] [string repeat x 4097]
    check "identity reader bounds file size" \
        [catch {::machteld::buildidentity::read [file join $work huge.dict]}]
    bytes [file join $work utf8.dict] [binary format H* ff]
    check "identity reader refuses invalid UTF-8" \
        [catch {::machteld::buildidentity::read [file join $work utf8.dict]}]

    # Exercise the actual packager with deliberately tiny dependency fixtures.
    set prefix [file join $work prefix]
    bytes [file join $prefix lib tcl9.0 init.tcl] {# fixture}
    bytes [file join $prefix lib tcl9 9.0 msgcat-1.7.1.tm] {# fixture}
    bytes [file join $prefix lib tk9.0 tk.tcl] {# fixture}
    set prelude [file join $work prelude.tcl]
    bytes $prelude "namespace eval ::machteld \{\n    variable version $runtime\n\}\n"
    set reference [file join $work reference]
    foreach name {catalog.dict catalog.json search.dict manifest.sha256 schema.json START-HERE.md AGENTS.md} {
        bytes [file join $reference $name] fixture
    }
    bytes [file join $reference catalog.dict] [dict create corpus_sha256 [dict get $good reference_sha256]]
    set arguments [list [info nameofexecutable] [file join $ROOT tools package.tcl] \
        --prefix $prefix --prelude $prelude --wrapper [info nameofexecutable] \
        --licenses [file join $ROOT licenses] --apache-license [file join $ROOT LICENSE] \
        --reference $reference]
    set serial 0
    foreach mode {absent valid version-mismatch reference-mismatch invalid} {
        incr serial
        set output [file join $work .machteld-build-[format %032x $serial].exe]
        set command [concat $arguments [list --out $output]]
        if {$mode ne "absent"} {
            set infoPath [file join $work $mode.dict]
            set record $good
            # A valid runtime version, but not the staged prelude's.
            if {$mode eq "version-mismatch"} { dict set record runtime_version [expr {$runtime + 1}] }
            if {$mode eq "reference-mismatch"} { dict set record reference_sha256 [string repeat d 64] }
            if {$mode eq "invalid"} { dict set record source_revision wrong }
            bytes $infoPath $record
            lappend command --build-info $infoPath
        }
        set failed [catch {exec {*}$command 2>@1} message]
        if {$mode in {absent valid}} {
            check "package accepts $mode identity" [expr {!$failed && [file isfile $output]}]
            if {!$failed} {
                zipfs mount $output identityProbe
                try {
                    set embedded //zipfs:/identityProbe/build-info.dict
                    if {$mode eq "absent"} {
                        check "legacy packaging does not invent development provenance" [expr {![file exists $embedded]}]
                    } else {
                        check "package embeds exact validated provenance" \
                            [expr {[::machteld::buildidentity::read $embedded] eq $good}]
                    }
                } finally { zipfs unmount identityProbe }
            } else { puts $message }
        } else {
            check "package refuses $mode without output" [expr {$failed && ![file exists $output]}]
        }
    }

    if {[llength $argv]} {
        set runtimeExe [file normalize [lindex $argv 0]]
        zipfs mount $runtimeExe actualBuild
        try {
            set hasIdentity [file exists //zipfs:/actualBuild/build-info.dict]
            if {$hasIdentity} {
                set actual [::machteld::buildidentity::read //zipfs:/actualBuild/build-info.dict]
                check "actual build identifies development without changing runtime version" [expr {
                    [dict get $actual channel] eq "development" &&
                    [dict get $actual runtime_version] eq $runtime}]
                set actualCorpus [dict get [slurp //zipfs:/actualBuild/reference/catalog.dict] corpus_sha256]
                check "actual build identifies its exact reference" [expr {
                    [dict get $actual reference_sha256] eq $actualCorpus}]
            } else {
                puts "ok   runtime has no optional development identity (normal for release packaging)"
            }
        } finally { zipfs unmount actualBuild }
        set app [file join $work app.tcl]
        bytes $app "package require machteld\nexit\n"
        foreach kind {console gui} {
            set wrapped [file join $work $kind.exe]
            exec $runtimeExe wrap $app -o $wrapped --$kind
            zipfs mount $wrapped actualWrap
            try {
                if {$hasIdentity} {
                    check "$kind wrapper inherits runtime provenance without reference" [expr {
                        [::machteld::buildidentity::read //zipfs:/actualWrap/build-info.dict] eq $actual &&
                        ![file exists //zipfs:/actualWrap/reference]}]
                } else {
                    check "$kind wrapper preserves absent development identity" [expr {
                        ![file exists //zipfs:/actualWrap/build-info.dict]}]
                }
            } finally { zipfs unmount actualWrap }
        }
    }
} finally {
    # Delete only this invocation's exclusively claimed sibling directory.
    if {[file normalize [file dirname $work]] eq [file normalize $env(TEMP)] &&
            [file tail $work] eq "[file tail $claim].d"} {
        file delete -force $work
    }
    close $marker
    file delete $claim
}
if {$failures} { puts stderr "$failures build identity checks failed"; exit 1 }
puts "ALL BUILD IDENTITY TESTS PASSED"
