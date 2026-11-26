package require -exact machteld 30

# Drive the same application scenario through each public distribution form.
namespace eval ::corpus {
    variable repo [file dirname [file dirname [file normalize [info script]]]]
    variable caseLabel
}

proc ::corpus::check {label expression} {
    variable caseLabel
    try {
        set passed [uplevel 1 [list expr $expression]]
    } on error {message options} {
        dict set options -errorinfo "$label: [dict get $options -errorinfo]"
        return -options $options "$label: $message"
    }
    if {!$passed} {error "$label (expected $expression)"}
    puts "ok   $caseLabel: $label"
}

proc ::corpus::runWithTimeout {ctx timeout prefix args} {
    set result [::machteld::run -dir [dict get $ctx cwd] -timeout $timeout -- {*}$prefix {*}$args]
    foreach stream {out err} {
        dict set result $stream [encoding convertfrom -profile strict utf-8 [dict get $result $stream]]
    }
    return $result
}

proc ::corpus::run {ctx prefix args} {
    runWithTimeout $ctx 45s $prefix {*}$args
}

# The caller stages a private copy of the app with its own manifest. Remove
# that build-time pathname before the app runs, including for loose sources.
proc ::corpus::build {ctx sourceDir name} {
    set root [dict get $ctx root]
    set form [dict get $ctx form]
    set sourceDir [file normalize $sourceDir]
    if {[file dirname $sourceDir] ne $root || ![file isfile [file join $sourceDir app.dict]]} {
        error "expected a staged project directly under the case directory: $sourceDir"
    }
    set depot [file join $root versions $name]
    file mkdir $depot
    if {$form eq "source"} {
        set artifact [file join $depot app]
        file rename -- $sourceDir $artifact
        return $artifact
    }
    if {$form eq "archive"} {
        set command pack
        set filename Application.machteld
    } else {
        set command wrap
        set filename Application.exe
    }
    # wrap stages Tcl's deep library tree beside its output. Keep the build
    # directly in this private temp directory, even when TEMP is already long.
    set output [file join $root $filename]
    set result [runWithTimeout $ctx 5m [list [info nameofexecutable] $command] [file join $sourceDir app.dict] -o $output]
    if {[dict get $result status] ne "ok"} {error "building $name with $command failed: $result"}
    set artifact [file join $depot $filename]
    file rename -- $output $artifact
    file delete -force -- $sourceDir
    return $artifact
}

proc ::corpus::home {ctx {slot current}} {
    return [file join [dict get $ctx root] {移動 installation} $slot]
}

proc ::corpus::install {ctx artifact {slot current}} {
    set directory [home $ctx $slot]
    file mkdir $directory
    set form [dict get $ctx form]
    if {$form ne "wrapped"} {
        set host [file join $directory machteld.exe]
        if {![file exists $host]} {file copy -- [info nameofexecutable] $host}
    }
    set target [file join $directory [file tail $artifact]]
    if {$form eq "source"} {
        # No application process is running during a corpus source upgrade.
        if {[file exists $target]} {file delete -force -- $target}
        file copy -- $artifact $target
        set channel [open [file join $target app.dict] r]
        try {
            fconfigure $channel -encoding utf-8
            set entry [dict get [read $channel] entry]
        } finally {close $channel}
        return [list $host [file join $target $entry]]
    }
    set staged [file join $directory update-staged]
    file copy -- $artifact $staged
    ::machteld::publish file $target $staged
    if {$form eq "archive"} {return [list $host $target]}
    return [list $target]
}

proc ::corpus::main {args} {
    variable repo
    variable caseLabel
    set cases [dict create project-inspector project_inspector sqlite-profile sqlite_profile]
    set forms {source archive wrapped}
    lassign $args which form
    if {[llength $args] > 2 || ([llength $args] >= 1 && ![dict exists $cases $which]) ||
            ([llength $args] == 2 && $form ni $forms)} {
        error "usage: application_corpus_test.tcl ?project-inspector|sqlite-profile? ?source|archive|wrapped?"
    }
    if {[llength $args] >= 1} {set cases [dict create $which [dict get $cases $which]]}
    if {[llength $args] == 2} {set forms [list $form]}
    set passed 0
    dict for {app procName} $cases {
        source -encoding utf-8 [file join $repo test corpus $procName.tcl]
        foreach form $forms {
            set caseLabel "$app/$form"
            set root [file normalize [file tempdir]]
            try {
                set cwd [file join $root {empty working directory}]
                file mkdir $cwd
                set ctx [dict create repo $repo root $root cwd $cwd app $app form $form]
                ::corpus::$procName $ctx
            } on error {message options} {
                dict set options -errorinfo "FAIL $caseLabel: [dict get $options -errorinfo]"
                return -options $options "FAIL $caseLabel: $message"
            } finally {file delete -force -- $root}
            puts "PASS $caseLabel"
            incr passed
        }
    }
    puts "Application corpus: $passed scenarios passed."
}

::corpus::main {*}$argv
