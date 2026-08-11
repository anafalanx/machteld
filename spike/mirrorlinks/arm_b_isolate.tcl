# Which part of the pure-Tcl arm is expensive? Time the three operations
# separately over a fixed sample of real paths, so the answer is an attributed
# cost rather than a total.
#
#   machteld.exe tcl arm_b_isolate.tcl <dir-with-many-files> ?n?

set dir [lindex $argv 0]
set n   [expr {[llength $argv] > 1 ? [lindex $argv 1] : 2000}]

# Collect a sample WITHOUT timing the collection.
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
if {$n == 0} { puts "no files under $dir" ; exit 1 }

proc timeit {label script} {
    upvar 1 files files n n
    # Warm once so first-touch caching is not attributed to the operation.
    uplevel 1 $script
    set best 1e12
    foreach i {1 2 3} {
        set t0 [clock microseconds]
        uplevel 1 $script
        set us [expr {[clock microseconds] - $t0}]
        if {$us < $best} { set best $us }
    }
    puts [format "  %-26s %8.1f us/file  (%.0f ms for %d)" $label \
              [expr {$best / double($n)}] [expr {$best / 1000.0}] $n]
}

puts "$dir -- $n files"
timeit "loop only (no fs call)"  {foreach f $files { set x $f }}
timeit "file exists"             {foreach f $files { file exists $f }}
timeit "file type"               {foreach f $files { file type $f }}
timeit "file stat"               {foreach f $files { file stat $f st }}
timeit "file attributes -hidden" {foreach f $files { catch {file attributes $f -hidden} }}
