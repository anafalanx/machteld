package require machteld 22-

proc check {condition description} {
    if {![uplevel 1 [list expr $condition]]} { error "FAIL $description" }
    puts "ok   $description"
}
proc writeFile {path text} {
    set f [open $path w]
    try { fconfigure $f -encoding utf-8 -translation lf; puts -nonewline $f $text } finally { close $f }
}
proc launch {directory environment args} {
    set r [::machteld::run -dir $directory -env $environment -timeout 75s -- [info nameofexecutable] {*}$args]
    set out [encoding convertfrom utf-8 [dict get $r out]]
    set err [encoding convertfrom utf-8 [dict get $r err]]
    if {[dict get $r status] ne "ok" || [dict get $r exit] != 0} {
        error "child $args failed with [dict get $r status], exit [dict get $r exit]\nstdout: $out\nstderr: $err"
    }
    return [string trimright $out "\r\n"]
}

if {[llength $argv] != 1} { error "usage: archives-gui-probe.tcl MACHTELD_REPO" }
set repo [file normalize [lindex $argv 0]]
set work [file tempdir]
set archive [file join $work {observed lookup 雪.machteld}]
try {
    set cwd [file join $work {unrelated cwd}]
    set catalogue [file join $work {catalogue 移動.machteld}]
    set database [file join $work {test catalogue.sqlite}]
    set inspector [file join $work {inspection.machteld}]
    set sample [file join $work {files for inspection}]
    set source [file join $work {observed project}]
    set lookup [file join $repo examples sqlite-lookup]
    file mkdir $cwd $sample
    writeFile [file join $sample {résumé.txt}] "record\n"

    set bare [file join $work {bare widget.tcl}]
    writeFile $bare {package require machteld
package require Tk
ttk::label .state -text {Native Tk}
pack .state
after 75 {
    puts [list [winfo ismapped .state] [winfo manager .state] [.state cget -text]]
    destroy .
}
}
    check {[launch $cwd {} $bare] eq [list 1 pack {Native Tk}]} {bare script maps a Tk widget and enters its event loop}

    launch $cwd {} pack [file join $repo examples project-inspector] -o $inspector
    set report [::machteld::json unwrap [::machteld::json decode -typed [launch $cwd {} $inspector --headless $sample]]]
    set rows [dict get $report rows]
    check {[dict get $report phase] eq "done" && [llength $rows] == 1 && [dict get [lindex $rows 0] name] eq "résumé.txt"} {packed Project Inspector relaunches its own worker and returns the sample entry}

    launch $cwd {} pack $lookup -o $catalogue
    launch $cwd {} $catalogue --create-demo $database
    package require sqlite3
    sqlite3 ::probeDb $database -readonly 1
    try {
        check {[::probeDb onecolumn {SELECT count(*) FROM items}] == 125000} {unmodified packed SQLite Lookup creates the 125,000-row catalogue}
    } finally { ::probeDb close }
    set output [split [launch $cwd {} $catalogue --worker page $database Kits 0] "\n"]
    set row [::machteld::json decode [lindex $output 1]]
    check {[llength $output] == 52 && [dict get $row id] == 3 && [dict get $row category] eq "Kits"} {unmodified packed SQLite Lookup reads a 50-row filtered page}

    # Observe the unchanged example code by sourcing its actual main from the packaged entry.
    file copy -- $lookup $source
    file rename [file join $source main.tcl] [file join $source example-main.tcl]
    writeFile [file join $source {note 雪.txt}] "read-only 雪"
    writeFile [file join $source main.tcl] {package require machteld 22-
set root [file dirname [info script]]
set asset [file join $root {note 雪.txt}]
if {[lindex [file system $asset] 0] ne "zipfs" || [file normalize $argv0] ne [file normalize $env(ARCHIVE_EXPECTED)]} {
    error "archive startup context incorrect: [info script] / $argv0"
}
set f [open $asset r]
try {
    fconfigure $f -encoding utf-8
    if {[read $f] ne "read-only 雪"} {error "archive asset bytes changed"}
} finally {close $f}
if {![catch {open $asset wb} f]} { close $f; error "existing archive asset accepted a write" }
if {[lindex $argv 0] eq "--worker"} {
    set f [open $env(ARCHIVE_WORKERS) a]
    try {puts $f [list [pid] {*}[lrange $argv 3 4]]} finally {close $f}
} else {
    package require Tk
    proc observe {page due} {
        try {
            if {[clock milliseconds] >= $due || $::lookup::phase eq "error"} {
                error "page $page: $::lookup::phase, $::lookup::status"
            }
            if {$::lookup::phase ne "ready" || ![winfo ismapped .results]} {
                after 20 [list observe $page $due]
                return
            }
            set ids [.results children {}]
            set first [.results item [lindex $ids 0] -values]
            set wanted [expr {$page == 1 ? [list 1 Parts {Catalogue item 000001}] : [list 3 Kits {Catalogue item 000003}]}]
            if {[llength $ids] != 50 || $first ne $wanted} { error "page $page list mismatch: [llength $ids] $first" }
            if {$page == 1} {
                .filters.category set Kits
                .filters.search invoke
                after 20 [list observe 2 $due]
            } else {
                puts [list GUI-ROWS 50 50 [pid]]
                ::lookup::close
            }
        } on error {message detail} {
            puts stderr [dict get $detail -errorinfo]
            exit 1
        }
    }
    after 20 [list observe 1 [expr {[clock milliseconds] + 45000}]]
}
source -encoding utf-8 [file join $root example-main.tcl]
}
    launch $cwd {} pack $source -o $archive
    file delete -force $source
    set before [::machteld::hash file sha256 $archive]
    file attributes $archive -readonly 1
    set workers [file join $work workers.txt]
    set result [launch $cwd [list ARCHIVE_EXPECTED $archive ARCHIVE_WORKERS $workers] $archive $database]
    check {[lrange $result 0 2] eq {GUI-ROWS 50 50}} {mapped SQLite Lookup GUI displays two correctly filtered pages}
    set f [open $workers r]
    try { set lines [split [string trim [read $f]] "\n"] } finally {close $f}
    lassign $lines a b
    check {[llength $lines] == 2 && [lrange $a 1 end] eq {All 0} && [lrange $b 1 end] eq {Kits 0} &&
           [lindex $a 0] != [lindex $result 3] && [lindex $b 0] != [lindex $result 3] &&
           [lindex $a 0] != [lindex $b 0]} {two fresh child processes each mount the same physical archive}
    check {$before eq [::machteld::hash file sha256 $archive]} {GUI and both workers read the sibling asset, reject writes, and preserve the archive hash}
} finally {
    if {[file exists $archive]} {catch {file attributes $archive -readonly 0}}
    file delete -force $work
}
puts "ALL NATIVE EXAMPLE ARCHIVE CHECKS PASSED"
