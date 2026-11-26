package require machteld
package require sqlite3

# Only the test entry is added to the sample. Both GUI and worker run from
# the relocated image with the original application entry and assets.
set here [file dirname [file normalize [info script]]]
set example [file join $here .. examples sqlite-lookup]
set work [file tempdir]
set stage [file join $work stage]
set deployed [file join $work {moved application 雪}]
set cwd [file join $work {unrelated cwd}]
file mkdir $stage $deployed $cwd
try {
    set f [open [file join $example app.dict]]
    try { set files [dict get [read $f] files] } finally { close $f }
    foreach name $files { file copy [file join $example $name] [file join $stage $name] }
    file copy [file join $here fixtures sqlite_lookup_gui.tcl] [file join $stage acceptance.tcl]
    set project [file join $stage project.dict]
    set f [open $project {WRONLY CREAT EXCL}]
    try {puts $f [dict create schema 1 entry acceptance.tcl files [linsert $files end acceptance.tcl]]} finally {close $f}
    set app [file join $deployed {Lookup test.machteld}]
    ::machteld::PackArchive $project -o $app
    set runtime [file join $deployed machteld.exe]
    file copy [info nameofexecutable] $runtime
    file delete -force -- $stage

    set database [file join $work {catalogue 雪.db}]
    set result [run -timeout 30s -dir $cwd -- $runtime $app --create-demo $database]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0 || ![file exists $database]} {
        error "the archived demo generator failed: $result"
    }
    sqlite3 catalogue $database -readonly 1
    try {
        if {[catalogue onecolumn {SELECT count(*) FROM items}] != 125000} {
            error "expected 125,000 synthetic catalogue rows"
        }
    } finally { catalogue close }
    set original [hash file sha256 $database]
    set scenario 0
    foreach arguments [list [list $database] {}] {
        set observations [file join $work "scenario-[incr scenario]"]
        file mkdir $observations
        set report [file join $observations result.txt]
        set result [run -timeout 90s -dir $cwd -env [list MACHTELD_LOOKUP_TEST_DIR $observations] -- $runtime $app {*}$arguments]
        if {[file exists $report]} {
            set f [open $report]
            try { set detail [read $f] } finally { close $f }
        } else { set detail "missing test report" }
        if {[dict get $result status] ne "ok" || [dict get $result exit] != 0 || [string trim $detail] ne "PASS"} {
            error "archived SQLite lookup failed for arguments [list $arguments]: $detail ($result)"
        }
        set workers [glob -nocomplain -directory $observations -tails worker-*]
        if {![llength $workers]} {error "no SQLite lookup worker reported startup"}
        foreach worker $workers {
            set id [string range $worker [string length worker-] end]
            if {[file exists [file join $observations tk-$id]]} {error "SQLite lookup worker $id initialized Tk"}
        }
    }
    if {[hash file sha256 $database] ne $original} { error "lookup changed the catalogue" }
    # On Windows a lingering connection/file lock can prevent this rename.
    file rename $database [file join $work closed.db]
    puts "PASS relocated GUI: two pages, UI event during query, cancellation, replacement, active window close and worker cleanup"
    puts "PASS first launch: generated demo, first visible page, temporary catalogue cleanup"
    puts "PASS GUI initialized Tk and every observed SQLite worker stayed Tk-free"
} finally {
    file delete -force -- $work
}
