# The isolate run measured REPEAT calls on paths Tcl had already normalised
# once. A real walk sees every path exactly once, so what matters is the FIRST
# call. This measures first-touch against repeat-touch on the same sample.
#
#   machteld.exe tcl arm_b_cold.tcl <dir> ?n?

set dir [lindex $argv 0]
set n   [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20000}]

proc gather {dir n} {
    set out {}
    set stack [list $dir]
    while {[llength $stack] && [llength $out] < $n} {
        set d [lindex $stack end] ; set stack [lrange $stack 0 end-1]
        foreach f [glob -nocomplain -directory $d -types f -- *] {
            lappend out $f
            if {[llength $out] >= $n} break
        }
        foreach s [glob -nocomplain -directory $d -types d -- *] { lappend stack $s }
    }
    return $out
}
set files [gather $dir $n]
set n [llength $files]
puts "$dir -- $n files"

set t0 [clock microseconds]
foreach f $files { file type $f }
set first [expr {[clock microseconds] - $t0}]

set t0 [clock microseconds]
foreach f $files { file type $f }
set again [expr {[clock microseconds] - $t0}]

puts [format "  first touch  : %7.1f us/file  (%.1f s for %d)" \
          [expr {$first / double($n)}] [expr {$first / 1e6}] $n]
puts [format "  second touch : %7.1f us/file  (%.1f s for %d)" \
          [expr {$again / double($n)}] [expr {$again / 1e6}] $n]
puts [format "  first/second : %.1fx" [expr {$first / double($again)}]]
