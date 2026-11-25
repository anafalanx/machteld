package require machteld 30-
package require Tk
source -encoding utf-8 [file normalize [file join [file dirname [info script]] .. examples graphviz-table view.tcl]]
try {
    wm geometry . +30+30
    pack [canvas .c -background white -highlightthickness 0]
    ::diagram::show .c
    update
    set picked 0
    foreach item [.c find withtag node:orders] {
        if {[.c type $item] ne "text" || [.c itemcget $item -text] ne "Orders"} {continue}
        lassign [.c bbox $item] x1 y1 x2 y2
        set x [expr {($x1+$x2)/2}]
        set y [expr {($y1+$y2)/2}]
        event generate .c <Motion> -x $x -y $y
        event generate .c <ButtonPress-1> -x $x -y $y
        update
        set picked [expr {$::diagram::selected eq "orders" && [llength [.c find withtag selection]] == 1}]
    }
    set fills [lmap i [.c find withtag node:orders] {
        if {[.c type $i] ne "polygon"} {continue}; .c itemcget $i -fill
    }]
    if {!$picked || "#aad7de" ni $fills || ![llength [.c find withtag edge]]} {error "table fill, routing or selection failed"}
    set text {Café 雪}
    set length [string length [encoding convertto utf-8 $text]]
    ::diagram::draw .c "T 0 0 -1 50 $length -$text" {0 0} unicode
    if {[.c itemcget unicode -text] ne $text} {error "xdot UTF-8 text did not round-trip through the canvas"}
    puts "Tk drew the named-port graph and selected its Orders node"
} finally {
    destroy .
}
