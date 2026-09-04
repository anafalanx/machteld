# json_bench.tcl -- J8 (plan-machteld-015): plain-decode throughput of the
# yyjson reader vs the old hand parser, two legs. NOT a gate: numbers.
#   machteld.exe test/json_bench.tcl
# The benchmark document is generated deterministically and pinned by hash;
# the small frame is a representative protocol reply.

package require machteld

set devdir [file join [file dirname [file dirname \
    [file normalize [info script]]]] .cache dev]
file mkdir $devdir
set doc [file join $devdir json-bench-1mib.json]
if {![file exists $doc]} {
    set parts {}
    set S 20260824
    for {set i 0} {$i < 9600} {incr i} {
        set S [expr {($S * 1103515245 + 12345) % 2147483648}]
        lappend parts [format {{"id":%d,"pad":"/api/v1/r%d","ok":%s,"n":%d.%02d,"tags":["a","b%d"],"note":"regel %d met wat tekst erbij"}} \
            $i [expr {$S % 1000}] [expr {$S % 2 ? "true" : "false"}] \
            [expr {$S % 9}] [expr {$S % 100}] [expr {$S % 7}] $i]
    }
    set f [open $doc wb]
    puts -nonewline $f "\[[join $parts ,]\]"
    close $f
}
set fh [open $doc rb]; set big [read $fh]; close $fh
puts "doc: [file size $doc] bytes  sha256 [string range [hash file sha256 $doc] 0 15]..."

set frame {{"id":7,"ok":true,"value":{"n":398366,"rows":[[1784844000,"/api/v1/users",200,51234]]},"ms":0.42}}

proc median {xs} { lindex [lsort -real $xs] [expr {[llength $xs] / 2}] }

set xs {}
for {set r 0} {$r < 9} {incr r} {
    set t0 [clock microseconds]
    json decode $big
    lappend xs [expr {([clock microseconds] - $t0) / 1000.0}]
}
puts [format "1MiB decode: %.2f ms median of 9" [median $xs]]

set xs {}
for {set r 0} {$r < 9} {incr r} {
    set t0 [clock microseconds]
    for {set i 0} {$i < 20000} {incr i} { json decode $frame }
    lappend xs [expr {([clock microseconds] - $t0) / 1000.0}]
}
puts [format "small frame x20000: %.2f ms median of 9 (%.2f us/frame)" \
    [median $xs] [expr {[median $xs] / 20.0}]]
