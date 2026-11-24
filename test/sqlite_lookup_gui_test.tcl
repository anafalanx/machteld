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
    set built [file join $work built.exe]
    wrap $stage -o $built --entry acceptance.tcl --gui
    set app [file join $deployed {Lookup test.exe}]
    file rename $built $app
    file delete -force -- $stage

    set database [file join $work {catalogue 雪.db}]
    set result [run -timeout 30s -dir $cwd -- $app --create-demo $database]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0 || ![file exists $database]} {
        error "the wrapped demo generator failed: $result"
    }
    sqlite3 catalogue $database -readonly 1
    try {
        if {[catalogue onecolumn {SELECT count(*) FROM items}] != 125000} {
            error "expected 125,000 synthetic catalogue rows"
        }
    } finally { catalogue close }
    set original [hash file sha256 $database]
    set result [run -timeout 90s -dir $cwd -env [list MACHTELD_LOOKUP_TEST_DIR $work] -- $app $database]
    set report [file join $work result.txt]
    if {[file exists $report]} {
        set f [open $report]
        try { set detail [read $f] } finally { close $f }
    } else { set detail "missing test report" }
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0 || [string trim $detail] ne "PASS"} {
        error "wrapped SQLite lookup failed: $detail ($result)"
    }
    if {[hash file sha256 $database] ne $original} { error "lookup changed the catalogue" }
    # On Windows a lingering connection/file lock can prevent this rename.
    file rename $database [file join $work closed.db]
    puts "PASS relocated GUI: two pages, UI event during query, cancellation, replacement, active window close and worker cleanup"
} finally {
    file delete -force -- $work
}
