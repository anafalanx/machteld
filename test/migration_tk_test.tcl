package require machteld 30-

if {![info exists env(MACHTELD_TEST_EXPECT_DESKTOP)] ||
    ![regexp {^MachteldDesktopTest-[0-9]+-[0-9]+$} $env(MACHTELD_TEST_EXPECT_DESKTOP)]} {
    error "run migration_tk_test.tcl through the private desktop runner"
}

namespace eval ::migrationTk {}
proc ::migrationTk::invoke {cwd environment command} {
    set child [::machteld::child start -console none -timeout 30s -dir $cwd -env $environment -- {*}$command]
    try {return [::machteld::child wait $child]} finally {::machteld::child close $child}
}

proc ::migrationTk::command {cwd host args} {
    set result [invoke $cwd {} [list $host {*}$args]]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0 || [dict get $result err] ne {}} {
        error "failed [list {*}$args]: $result"
    }
    return [string trimright [encoding convertfrom -profile strict utf-8 [dict get $result out]] "\r\n"]
}

proc ::migrationTk::expectCaption {variant delivery actual} {
    if {$actual ne [list $variant $delivery {Shelf: A-17}]} {error "$variant $delivery returned [list $actual]"}
    puts "PASS $variant $delivery refreshed the real Tk label"
}

set here [file dirname [file normalize [info script]]]
set sample [file join [file dirname $here] examples mixed-migration]
set exe [info nameofexecutable]
set work [file tempdir]
try {
    set cwd [file join $work {unrelated working directory}]
    file mkdir $cwd
    # Exercise the rejection on the same private desktop. The expected name
    # still has the right form, but belongs to a different Windows desktop.
    set other [dict create MACHTELD_TEST_EXPECT_DESKTOP "${env(MACHTELD_TEST_EXPECT_DESKTOP)}0"]
    set fixture [file join $here fixtures migration_ui.tcl]
    set rejected [::migrationTk::invoke $cwd $other [list $exe $fixture tcl source]]
    if {[dict get $rejected status] ne "error" || [dict get $rejected exit] != 1 ||
        [string first "outside the gate's private desktop" [dict get $rejected err]] < 0} {
        error "a mismatched desktop did not stop the fixture before Tk: $rejected"
    }
    puts "PASS a mismatched private desktop name is refused before loading Tk"
    foreach variant {tcl mixed} {
        set author [file join $work $variant]
        file copy -- $sample $author
        set project [file join $author project.dict]
        set ch [open $project r]
        try {set manifest [read $ch]} finally {close $ch}
        # The test entry instruments the existing widgets, then sources the
        # sample's unmodified main.tcl. The original package directory stays intact.
        dict set manifest tclEntry migration_ui.tcl
        dict lappend manifest assets main.tcl
        file copy -- $fixture $author
        if {$variant eq "tcl"} {
            dict set manifest modules {}
            file copy -force -- [file join $author before captions.tcl] [file join $author lib captions.tcl]
        }
        set ch [open $project w]
        try {puts $ch $manifest} finally {close $ch}
        ::migrationTk::expectCaption $variant source [::migrationTk::command $cwd $exe project run $project $variant source]

        set draft [file join $author cards.machteld]
        ::migrationTk::command $cwd $exe project pack $project $draft
        set recipient [file join $work "recipient $variant 雪"]
        file mkdir $recipient
        set archive [file join $recipient cards.machteld]
        set host [file join $recipient machteld.exe]
        file rename -- $draft $archive
        file copy -- $exe $host
        file delete -force -- $author
        ::migrationTk::expectCaption $variant archive [::migrationTk::command $cwd $host $archive $variant archive]
    }
} finally {file delete -force -- $work}
