source -encoding utf-8 [file join [file dirname [info script]] .. view.tcl]
source -encoding utf-8 [file join [file dirname [info script]] .. research.tcl]

namespace eval ::typedDiagram {}
proc ::typedDiagram::paint {canvas rows} {
    set c [::application::@tk::canvas_path $canvas]
    lassign [::research::diagram $rows] graph occurrenceNodes
    ::diagram::paint $c $graph
    dict for {node key} $occurrenceNodes {
        ::application::@tk::attach_items $canvas $key [$c find withtag node:$node]
    }
    return {}
}
package provide example::typed_diagram 1.0
