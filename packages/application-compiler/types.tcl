# Split the parser's canonical type spelling at the outermost commas. This
# procedure is also embedded in the generated runtime for boundary checks.
proc ::appcompiler::typeParts {type} {
    if {[string index $type end] eq "?"} {
        return [list optional [string range $type 0 end-1]]
    }
    set open [string first < $type]
    if {$open < 0} {return [list $type]}
    if {[string index $type end] ne ">"} {error "malformed type [list $type]"}
    set parts [list [string range $type 0 $open-1]]
    set depth 0
    set start [expr {$open + 1}]
    for {set i $start} {$i < [string length $type] - 1} {incr i} {
        switch -- [string index $type $i] {
            < {incr depth}
            > {incr depth -1}
            , {
                if {$depth == 0} {
                    lappend parts [string range $type $start $i-1]
                    set start [expr {$i + 1}]
                }
            }
        }
    }
    lappend parts [string range $type $start end-1]
    return $parts
}
