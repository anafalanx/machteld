package require machteld 0.21

# Print byte-level evidence that can be compared without exchanging either
# unsigned executable. The entry hashes cover uncompressed application data.
if {[llength $argv] != 1} {error "usage: repro_report.tcl EXECUTABLE"}
set exe [file normalize [lindex $argv 0]]
set root [zipfs mount $exe /machteldRepro]
try {
    set offset [lindex [zipfs info $root] 3]
    if {$offset <= 0 || $offset >= [file size $exe]} {error "missing native prefix or ZIP payload"}
    puts "unsigned executable SHA-256 [hash file sha256 $exe]"
    set ch [open $exe rb]
    try {
        puts "native prefix SHA-256 [hash sum sha256 [read $ch $offset]] ($offset bytes)"
        puts "ZIP container SHA-256 [hash sum sha256 [read $ch]]"
    } finally {close $ch}
    set entries {}
    set prefixLength [string length "$root/"]
    foreach path [lsort [zipfs list -glob "$root/*"]] {
        if {![file isfile $path]} continue
        set name [string range $path $prefixLength end]
        lappend entries [list [hash file sha256 $path] [file size $path] $name]
    }
    if {![llength $entries]} {error "empty ZIP inventory"}
    set inventory [join $entries \n]
    puts "uncompressed inventory SHA-256 [hash sum sha256 [encoding convertto utf-8 $inventory]] ([llength $entries] entries)"
    puts $inventory
} finally {
    zipfs unmount $root
}
