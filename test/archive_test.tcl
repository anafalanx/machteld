package require machteld

# Run on the candidate executable. The --tk lane needs an interactive desktop.
# All applications and malformed archives are built inside a fresh temp folder.
proc check {label pass} {
    if {!$pass} { error "FAIL $label" }
    puts "ok   $label"
}
proc writeBytes {path bytes} {
    file mkdir [file dirname $path]
    set f [open $path wb]
    try { puts -nonewline $f $bytes } finally { close $f }
}
proc writeScript {path script} { writeBytes $path [encoding convertto utf-8 $script] }
proc host {directory exitCode args} {
    set r [run -dir $directory -timeout 30s -- [info nameofexecutable] {*}$args]
    set out [encoding convertfrom -profile strict utf-8 [dict get $r out]]
    set err [encoding convertfrom -profile replace utf-8 [dict get $r err]]
    set status [dict get $r status]
    set code [dict get $r exit]
    if {$status ni {ok error} || ($exitCode eq "failure" ? $code == 0 : $code != $exitCode)} {
        error "command [list {*}$args] returned $status (exit $code), expected $exitCode\n$out\n$err"
    }
    return [string trimright $out "\r\n"]
}
proc samePath {actual expected} {
    set left [canon $actual]
    set right [canon $expected]
    expr {[dict get $left volume] eq [dict get $right volume] && [dict get $left file] eq [dict get $right file]}
}

proc tkArchive {work} {
    set program [file join $work view.tcl]
    writeScript $program {package require machteld
package require Tk
label .sample -text "archive window"
pack .sample
after idle {
    puts [winfo manager .sample]
    destroy .
}
}
    host $work 0 pack view.tcl -o widget.machteld
    file delete $program
    set result [host $work 0 widget.machteld]
    check "an archived Tk app enters its event loop and uses the Tk pack geometry manager" \
        [expr {$result eq "pack"}]
}

proc consoleArchives {work} {
    set source [file join $work {source tree}]
    set caller [file join $work {caller dir}]
    set moved [file join $caller {release files}]
    file mkdir $moved
    set standalone [file join $source {résumé tool.tcl}]
    set arguments [list --help {} {two words} {a"b} "trailing slash\\" {[$5];} 世界]
    set program {package require machteld
puts [list $argc $argv $argv0 [info script] [pwd]]
if {$argv eq {finish}} {exit 37}
}
    set utf8 [encoding convertto utf-8 [string map [list \n \r\n] $program]]
    writeBytes $standalone [binary format a*a* [binary decode hex efbbbf] $utf8]
    lassign [host $caller 0 $standalone {*}$arguments] argc words argv0 script cwd
    check "a BOM/CRLF Tcl file retains arguments and its startup context" [expr {
        $argc == [llength $arguments] && $words eq $arguments && [samePath $argv0 $standalone] &&
        [samePath $script $standalone] && [samePath $cwd $caller]}]

    set zip [file join $work app.machteld]
    host $caller 0 pack $standalone -o $zip
    set f [open $zip rb]
    try { set magic [binary encode hex [read $f 4]] } finally { close $f }
    set mount [zipfs mount $zip inspect-[pid]]
    try {
        check "single-file archive is an ordinary ZIP containing only main.tcl" \
            [expr {$magic eq "504b0304" && [glob -tails -directory $mount *] eq {main.tcl}}]
    } finally { zipfs unmount $mount }
    file delete $standalone
    set relative [file join {release files} {réunion.MACHTELD}]
    file rename $zip [set archive [file join $caller $relative]]
    lassign [host $caller 0 $relative {*}$arguments] argc words argv0 script cwd
    check "relocated uppercase archive receives exact arguments, physical argv0, mounted script and caller cwd" [expr {
        $argc == [llength $arguments] && $words eq $arguments && [file pathtype $argv0] eq "absolute" &&
        [samePath $argv0 $archive] && [string match {//zipfs:/*/main.tcl} $script] && [samePath $cwd $caller]}]
    host $caller 37 $relative finish
    puts "ok   archive preserves an explicit exit status"

    set bytes [binary decode hex 00ff100d0a00e59bbd]
    writeBytes [file join $source assets {catalogue data.bin}] $bytes
    writeScript [file join $source lib demo pkgIndex.tcl] {
package ifneeded catalogue 1 [list source [file join $dir catalogue.tcl]]
}
    writeScript [file join $source lib demo catalogue.tcl] {
proc catalogueTitle {} {return "Répertoire"}
package provide catalogue 1
}
    writeScript [file join $source main.tcl] {package require machteld
set root [file dirname [info script]]
lappend auto_path [file join $root lib]
package require catalogue 1
set path [file join $root assets {catalogue data.bin}]
set f [open $path rb]
try {set bytes [read $f]} finally {close $f}
set refused [catch {set f [open $path wb]}]
if {!$refused} {puts -nonewline $f altered; close $f}
puts [list [catalogueTitle] [binary encode hex $bytes] $refused]
}
    host $caller 0 pack $source -o $archive
    file delete -force $source
    set digest [hash file sha256 $archive]
    set result [host $caller 0 $relative]
    check "directory archive loads its own package and reads its binary asset after source removal" \
        [expr {[lrange $result 0 1] eq [list Répertoire [binary encode hex $bytes]]}]
    check "writing to an existing archive asset is refused and leaves the distributed bytes intact" \
        [expr {[lindex $result 2] eq "1" && [hash file sha256 $archive] eq $digest}]

    # Untrusted contents are never evaluated by pack. If a refused input runs
    # at startup, its marker is left in the caller's working directory.
    set marker [file join $caller unexpected-execution]
    writeScript [file join $source note.tcl] {close [open unexpected-execution w]}
    host $caller failure pack $source -o $archive
    check "packing a directory without main.tcl preserves an existing output" \
        [expr {[hash file sha256 $archive] eq $digest}]
    file rename [file join $source note.tcl] [file join $source main.tcl]
    host $caller failure pack $source -o $archive
    host $caller failure [file join $source main.tcl]
    check "a missing opt-in prevents both direct execution and replacement of an archive" \
        [expr {![file exists $marker] && [hash file sha256 $archive] eq $digest}]
    set bad [file join $work invalid.machteld]
    zipfs mkzip $bad $source $source
    host $caller failure $bad
    check "a valid ZIP with a non-opted-in main.tcl is rejected before entry" [expr {![file exists $marker]}]
    file delete $bad
    file rename [file join $source main.tcl] [file join $source other.tcl]
    zipfs mkzip $bad $source $source
    host $caller failure $bad
    check "a valid ZIP without main.tcl is rejected" [expr {![file exists $marker]}]
    writeScript $bad "package require machteld\nclose \[open unexpected-execution w\]\n"
    host $caller failure $bad
    check "a malformed archive never falls back to evaluating its bytes as Tcl" [expr {![file exists $marker]}]

    set entry [file join $source main.tcl]
    set prefix [encoding convertto utf-8 "package require machteld\nclose \[open unexpected-execution w\]\n#"]
    writeBytes $entry [binary format a*a* $prefix [binary decode hex ff]]
    host $caller failure pack $source -o $archive
    file delete $bad
    zipfs lmkzip $bad [list $entry main.tcl]
    host $caller failure $bad
    check "invalid UTF-8 after an opt-in prevents publication and evaluation" \
        [expr {![file exists $marker] && [hash file sha256 $archive] eq $digest}]

    writeScript [file join $source main.tcl] "package require machteld\n"
    set held [open $archive rb]
    try {
        host $caller failure pack $source -o $archive
    } finally { close $held }
    check "a failed final replacement leaves the complete previous archive intact" \
        [expr {[hash file sha256 $archive] eq $digest}]
    set nested [file join $source saved.machteld]
    host $caller failure pack $source -o $nested
    check "pack refuses an output inside its own input tree" [expr {![file exists $nested]}]
    writeScript [file join $caller pack] "package require machteld\nputs DIRECT-SCRIPT\n"
    check "an actual script named pack retains direct-entry precedence" \
        [expr {[host $caller 0 pack] eq "DIRECT-SCRIPT"}]
}

set work [file tempdir]
try {
    switch -- $argv {
        {} { consoleArchives $work }
        --tk { tkArchive $work }
        default { error "usage: archive_test.tcl ?--tk?" }
    }
} finally { file delete -force $work }
puts "ALL ARCHIVE CHECKS PASSED"
