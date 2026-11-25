namespace eval ::diagram {
    variable selected ""
    variable dot {digraph {
        graph [rankdir=LR, splines=ortho, nodesep=0.6, ranksep=0.8]
        node [shape=plain]
        orders [label=<<TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0">
            <TR><TD BGCOLOR="#aad7de">Orders</TD></TR>
            <TR><TD PORT="customer">Customer</TD></TR>
            <TR><TD PORT="item">Item</TD></TR></TABLE>>]
        customer [label=<<TABLE BORDER="0"><TR><TD BGCOLOR="#f2d29b">Customer</TD></TR></TABLE>>]
        item [label=<<TABLE BORDER="0"><TR><TD BGCOLOR="#ead1da">Item</TD></TR></TABLE>>]
        orders:customer -> customer
        orders:item -> item
    }}
}

# xdot's string lengths count UTF-8 bytes. Numeric fields and operation
# letters are ASCII, separated by spaces. Text is never evaluated as Tcl.
proc ::diagram::word {bytes cursorVar} {
    upvar 1 $cursorVar cursor
    if {![regexp -indices -start $cursor {\S+} $bytes match]} { return "" }
    lassign $match first last
    set cursor [expr {$last + 1}]
    string range $bytes $first $last
}
proc ::diagram::stringField {bytes cursorVar} {
    upvar 1 $cursorVar cursor
    set count [word $bytes cursor]
    while {[string index $bytes $cursor] eq " "} { incr cursor }
    if {![string is entier -strict $count] || $count < 0 || [string index $bytes $cursor] ne "-"} {
        error "invalid xdot string field"
    }
    incr cursor
    if {$cursor + $count > [string length $bytes]} { error "short xdot string field" }
    set text [string range $bytes $cursor [expr {$cursor + $count - 1}]]
    incr cursor $count
    encoding convertfrom utf-8 $text
}
proc ::diagram::draw {canvas script origin tags} {
    lassign $origin left top
    set bytes [encoding convertto utf-8 $script]
    set cursor 0
    set pen black
    set fill white
    set size 14
    set face Times
    while {[set op [word $bytes cursor]] ne ""} {
        switch -- $op {
            c - C {
                set color [stringField $bytes cursor]
                if {[regexp {^#[a-fA-F0-9]{8}$} $color]} {
                    set color [expr {[string range $color 7 8] eq "00" ? "" : [string range $color 0 6]}]
                }
                if {$op eq "C"} { set fill $color } else { set pen $color }
            }
            F { set size [word $bytes cursor]; set face [stringField $bytes cursor] }
            S { stringField $bytes cursor }
            t { word $bytes cursor }
            p - P - B - b - L {
                set coords {}
                set count [word $bytes cursor]
                for {set i 0} {$i < $count} {incr i} {
                    lappend coords [expr {[word $bytes cursor] - $left}] [expr {$top - [word $bytes cursor]}]
                }
                if {$op in {p P}} {
                    $canvas create polygon $coords -fill [expr {$op eq "P" ? $fill : ""}] -outline $pen -tags $tags
                } else {
                    $canvas create line $coords -fill $pen -smooth [expr {$op eq "L" ? "false" : "raw"}] -tags $tags
                }
            }
            T {
                set x [expr {[word $bytes cursor] - $left}]
                set y [expr {$top - [word $bytes cursor]}]
                set anchor [dict get {-1 sw 0 s 1 se} [word $bytes cursor]]
                word $bytes cursor
                set content [stringField $bytes cursor]
                set font [list $face [expr {-max(1, round($size))}]]
                set y [expr {$y + [font metrics $font -descent]}]
                $canvas create text $x $y -anchor $anchor -font $font -fill $pen -text $content -tags $tags
            }
            default { error "unexpected xdot operation in the table example: $op" }
        }
    }
}
proc ::diagram::select {canvas} {
    variable selected
    $canvas delete selection
    set selected ""
    foreach tag [$canvas gettags current] {
        if {[string match node:* $tag]} {
            set selected [string range $tag 5 end]
            $canvas create rectangle [$canvas bbox $tag] -outline #365e91 -width 2 -tags selection
            break
        }
    }
}
proc ::diagram::show {canvas} {
    variable dot
    set graph [::machteld::graphviz layout $dot]
    set origin [dict get $graph origin]
    foreach edge [dict get $graph edges] {
        foreach key {draw tailDraw headDraw labelDraw} {
            draw $canvas [dict get $edge $key] $origin [list edge]
        }
    }
    dict for {node card} [dict get $graph nodes] {
        foreach key {draw labelDraw} {
            draw $canvas [dict get $card $key] $origin [list node node:$node]
        }
    }
    lassign [dict get $graph size] width height
    $canvas configure -width [expr {ceil($width) + 4}] -height [expr {ceil($height) + 4}]
    bind $canvas <Button-1> [list ::diagram::select $canvas]
}
