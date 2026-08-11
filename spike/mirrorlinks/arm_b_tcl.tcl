# Arm B -- mirror's link scan, in pure Tcl.
#
# The same question z's `discoverMirrorLinks` asks: walk the whole source tree
# without following name-surrogate reparse points, and report every symlink and
# junction with its type and target.
#
# WHAT TCL CAN AND CANNOT SEE. `file type` reports `link` for a symbolic link
# and `directory` for a junction, so Tcl alone cannot tell a junction from a
# plain directory -- `file link` is the only lever, and on a junction it either
# returns the target or raises. That is the honest pure-Tcl implementation: try
# `file link` on every directory, and treat success as "this redirects".
#
#   machteld.exe tcl arm_b_tcl.tcl C:/dev ?runs?

set root [lindex $argv 0]
set runs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 3}]

proc scan {root entriesVar} {
    upvar 1 $entriesVar entries
    set links {}
    set stack [list $root]
    set entries 0
    while {[llength $stack]} {
        set dir [lindex $stack end]
        set stack [lrange $stack 0 end-1]

        # Children, hidden ones included -- `glob -types d` alone misses the
        # hidden ATTRIBUTE, which is the blind spot that cost `cdirs` 786
        # directories.
        set kids {}
        foreach types {f {f hidden} d {d hidden}} {
            foreach p [glob -nocomplain -directory $dir -types $types -- *] {
                dict set kids $p 1
            }
        }
        foreach p [dict keys $kids] {
            incr entries
            # A symlink: Tcl says so directly.
            if {[catch {file type $p} t]} continue
            if {$t eq "link"} {
                set target ""
                catch {set target [file link $p]}
                lappend links [list $p symlink $target]
                continue
            }
            if {$t ne "directory"} continue
            # A directory that `file link` can read is a junction or a
            # directory symlink; one that raises is an ordinary directory.
            if {![catch {file link $p} target]} {
                lappend links [list $p junction $target]
                continue                       ;# do not descend a name surrogate
            }
            lappend stack $p
        }
    }
    return $links
}

# Warm, then `runs` timed passes; the minimum is the least-noise estimator.
set entries 0
scan $root entries
set best 1e12
for {set i 0} {$i < $runs} {incr i} {
    set t0 [clock microseconds]
    set links [scan $root entries]
    set ms [expr {([clock microseconds] - $t0) / 1000.0}]
    if {$ms < $best} { set best $ms }
}
puts [format "ARM-B tcl  : %.0f ms  (%d links, %d entries)" $best [llength $links] $entries]
foreach l $links { puts "   link: [lindex $l 0] \[[lindex $l 1] -> [lindex $l 2]\]" }
