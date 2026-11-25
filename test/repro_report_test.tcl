package require machteld 0.21

set root [file dirname [file dirname [file normalize [info script]]]]
set driver [info nameofexecutable]
set work [file tempdir]
try {
    set data [file join $work manual.md]
    set images {}
    foreach {name timestamp body} {original 946728000 hello retimed 946814400 hello edited 946728000 world} {
        set ch [open $data wb]
        try {puts -nonewline $ch $body} finally {close $ch}
        file mtime $data $timestamp
        set image [file join $work $name.exe]
        zipfs lmkimg $image [list $data manual.md] {} $driver
        set output [exec -- $driver [file join $root tools repro_report.tcl] $image]
        set lines [split [string trim $output] \n]
        if {[llength $lines] != 5 ||
                [lindex $lines 0] ne "unsigned executable SHA-256 [hash file sha256 $image]" ||
                [lindex $lines 4] ne [list [hash file sha256 $data] [file size $data] manual.md]} {
            error "report disagrees with the executable or member bytes for $name"
        }
        dict set images $name $lines
    }
    lassign [dict get $images original] originalExe originalPrefix originalZip originalEntries
    lassign [dict get $images retimed] retimedExe retimedPrefix retimedZip retimedEntries
    lassign [dict get $images edited] editedExe editedPrefix editedZip editedEntries
    if {$originalExe eq $retimedExe || $originalExe eq $editedExe ||
            $originalPrefix ne $retimedPrefix || $originalPrefix ne $editedPrefix ||
            $originalZip eq $retimedZip || $originalZip eq $editedZip ||
            $originalEntries ne $retimedEntries || $originalEntries eq $editedEntries} {
        error "report failed to distinguish ZIP metadata and embedded content changes"
    }
    puts "Build hash diagnostics distinguish native bytes, ZIP metadata and uncompressed file contents."
} finally {
    file delete -force $work
}
