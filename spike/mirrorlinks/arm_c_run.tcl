# Arm C / D -- the C walk, with and without classifying file entries.
#
# Run under EITHER build:
#   machteld-base.exe  tcl arm_c_run.tcl C:/dev   -> D baseline: files thrown away
#   machteld-spike.exe tcl arm_c_run.tcl C:/dev   -> C: every file entry classified
#
# The two differ by one `#ifdef` in dirs.c. Both make the same number of
# GetFileInformationByHandleEx calls -- one per DIRECTORY -- because the file
# entries are already in the buffer either way; the spike simply stops throwing
# them away and does to each one what a mirror link scanner would.

set root [lindex $argv 0]
set runs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 3}]

set d [dirs $root]                                   ;# warm
set best 1e12
for {set i 0} {$i < $runs} {incr i} {
    set t0 [clock microseconds]
    set d [dirs $root]
    set ms [expr {([clock microseconds] - $t0) / 1000.0}]
    if {$ms < $best} { set best $ms }
}
set spike [dict exists $d spikefiles]
puts [format "%-11s: %.0f ms  (%d dirs%s, %d link rows)" \
          [expr {$spike ? "ARM-C c" : "ARM-D c-base"}] $best [dict get $d dirs] \
          [expr {$spike ? ", [dict get $d spikefiles] files classified" : ", files skipped"}] \
          [llength [dict get $d links]]]
if {$spike} {
    puts [format "             file reparse points: %d, of which name surrogates: %d" \
              [dict get $d spikereparse] [dict get $d spikelinks]]
}
foreach l [dict get $d links] {
    if {[dict exists $l surrogate] && [dict get $l surrogate]} {
        puts "   link: [dict get $l path] \[[dict get $l tag] [dict get $l action]\]"
    }
}
