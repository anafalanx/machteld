# The Tcl half of the head-to-head: `file stat` over a FIXED list of paths,
# the same list hazard.exe reads in `list` mode.
#
# Tcl's `file stat` DOES report a real `nlink` on Windows -- 2 for a hardlinked
# pair, 1 for an ordinary file, verified against a fixture built with `mklink
# /H`. So the destination hazard check is expressible in pure Tcl, and the only
# question is what it costs against the same probe written in C.
#
#   machteld.exe tcl arm_stat_tcl.tcl <listfile> ?runs?  -- measure
#   machteld.exe tcl arm_stat_tcl.tcl --make <root> <listfile> ?n?  -- build the list

if {[lindex $argv 0] eq "--make"} {
    lassign $argv _ root out n
    if {$n eq ""} { set n 20000 }
    set files {}
    set stack [list $root]
    while {[llength $stack] && [llength $files] < $n} {
        set d [lindex $stack end] ; set stack [lrange $stack 0 end-1]
        foreach f [glob -nocomplain -directory $d -types f -- *] {
            lappend files $f
            if {[llength $files] >= $n} break
        }
        foreach s [glob -nocomplain -directory $d -types d -- *] { lappend stack $s }
    }
    set fh [open $out w] ; fconfigure $fh -encoding utf-8 -translation lf
    foreach f $files { puts $fh [file nativename $f] }
    close $fh
    puts "wrote [llength $files] paths to $out"
    exit 0
}

set listfile [lindex $argv 0]
set runs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 3}]
set fh [open $listfile r] ; fconfigure $fh -encoding utf-8 -translation lf
set files [lsearch -all -inline -not -exact [split [string trim [read $fh]] \n] ""]
close $fh

proc probe {files} {
    set multi 0
    foreach f $files {
        if {[catch {file stat $f st}]} continue
        if {$st(nlink) > 1} { incr multi }
    }
    return $multi
}

probe $files                                   ;# warm
set best 1e12
for {set i 0} {$i < $runs} {incr i} {
    set t0 [clock microseconds]
    set multi [probe $files]
    set ms [expr {([clock microseconds] - $t0) / 1000.0}]
    if {$ms < $best} { set best $ms }
}
puts [format "Tcl file stat       : %8.1f ms  %6.2f us/file  (%d files, %d multilink)" \
          $best [expr {$best * 1000.0 / [llength $files]}] [llength $files] $multi]
