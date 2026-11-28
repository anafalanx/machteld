# Review half-open character selections in a retained Unicode document.
package require machteld
set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set compilers {}
set mode {}
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set option [lindex $argv $i]] {
        --once {set mode once}
        --timings {set mode timings}
        --embedded {
            if {[dict exists $compilers X]} {error "select the candidate compiler once"}
            dict set compilers X [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$option needs a compiler directory"}
            set label [expr {$option eq "--compiler" ? "X" : "baseline"}]
            if {[dict exists $compilers $label]} {error "select the $label compiler once"}
            dict set compilers $label [lindex $argv $i]
        }
        default {error {usage: document-selections.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--once | --timings?}}
    }
}
if {![dict exists $compilers X]} {dict set compilers X [file join $root packages application-compiler]}
set timed [expr {$mode eq "timings" || ($mode eq {} && [dict exists $compilers baseline])}]

set source {export record .selection {start: int
    stop: int}
export record .review {accepted: int
    covered: int
    invalid: list<int>}
export fn .review_selections($document: text, $selections: list<.selection>) -> .review {
    $accepted := 0
    $covered := 0
    $invalid := list<int>()
    $index := 0
    for $s in $selections {
        if $s.start >= 0 && $s.start <= $s.stop && $s.stop <= len($document) {
            $accepted = $accepted + 1
            $covered = $covered + $s.stop - $s.start
        } else {
            $invalid = list_append($invalid,$index)
        }
        $index = $index + 1
    }
    return make<.review>(accepted:$accepted,covered:$covered,invalid:$invalid)
}
export fn .byte_count($payload: bytes) -> int => len($payload)
}
dict for {label directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set artifact [$child eval [list ::appcompiler::compile [dict create doc $source] ::selection_$label]]
        namespace eval :: [dict get $artifact script]
    } finally {interp delete $child}
}

# Each character count is supplied by the fixture independently of X or Tcl length.
proc selections {size count} {
    set rows {}
    for {set i 0} {$i < $count} {incr i} {
        set start [expr {($i * 997) % ($size + 1)}]
        set stop [expr {min($size, $start + $i % 27)}]
        switch [expr {$i % 7}] {
            0 {set stop [expr {$size + 1}]}
            1 {set start -1}
            2 {set stop [expr {$start - 1}]}
            3 {set start $size; set stop $size}
        }
        lappend rows [dict create start $start stop $stop]
    }
    return $rows
}
proc oracle {size rows} {
    set invalid {}
    set widths {}
    set pos 0
    foreach row $rows {
        set a [dict get $row start]
        set b [dict get $row stop]
        if {$b > $size || $a < 0 || $b < $a} {
            lappend invalid $pos
        } else {
            lappend widths [expr {$b - $a}]
        }
        incr pos
    }
    return [dict create accepted [llength $widths] covered [tcl::mathop::+ {*}$widths] invalid $invalid]
}
proc check {result expected label} {
    if {[dict size $result] != [dict size $expected]} {error "$label returned unexpected fields"}
    dict for {key value} $expected {
        if {[dict get $result $key] ne $value} {error "$label $key: expected [list $value], got [list [dict get $result $key]]"}
    }
}
set block "Aé雪🧪\u0000e\u0301"
set encoded [encoding convertto utf-8 $block]
set wire {{"digit":1.00e+2}}
set wireRows [selections 17 32]
set emptyRows [selections 0 14]
set bounds [list {start -1 stop 0} {start 0 stop 7} {start 7 stop 7} {start 2 stop 1} \
    {start 1 stop 5} {start 0 stop 0} {start 3 stop 8}]
dict for {label directory} $compilers {
    set cmd ::selection_${label}::doc::review_selections
    check [$cmd {} {}] {accepted 0 covered 0 invalid {}} "$label empty"
    check [$cmd $block $bounds] {accepted 4 covered 11 invalid {0 3 6}} "$label Unicode"
    check [$cmd {} $emptyRows] [oracle 0 $emptyRows] "$label zero-width boundaries"
    if {[::selection_${label}::doc::byte_count $encoded] != 14} {error "$label wrong byte count"}
    set node [::machteld::json decode -typed $wire]
    check [$cmd $node $wireRows] [oracle 17 $wireRows] "$label retained JSON"
    if {[::machteld::json type $node] ne "object" || [::machteld::json encode -- $node] ne $wire} {
        error "$label changed the caller's typed JSON object or its wire spelling"
    }
    foreach index {0 3 6} {
        set bad [lreplace $bounds $index $index [dict replace [lindex $bounds $index] stop wrong]]
        set code [catch {$cmd $block $bad} message opts]
        if {!$code || [dict get $opts -errorcode] ne {APPCOMPILER ARGUMENT TYPE} ||
                $message ne [format {expected int at $selections.%d.stop} $index]} {
            error "$label wrong diagnostic at index $index: $message"
        }
    }
}

if {!$timed} {
    puts {compiler document selections: verified Unicode bounds, ordered rejections, byte counts, retained JSON and three error paths}
    return
}
puts [join {round compiler characters selections elapsed_us} \t]
foreach repeats {4 512 16384} {
    set document [string repeat $block $repeats]
    set size [expr {7 * $repeats}]
    set rows [selections $size 384]
    set expected [oracle $size $rows]
    for {set round 0} {$round <= 12} {incr round} {
        set order [dict keys $compilers]
        if {$round % 2} {set order [lreverse $order]}
        foreach label $order {
            set command ::selection_${label}::doc::review_selections
            set start [clock microseconds]
            set result [$command $document $rows]
            set us [expr {[clock microseconds] - $start}]
            check $result $expected "$label $size characters"
            if {$round} {puts [join [list $round $label $size [llength $rows] $us] \t]}
        }
    }
}
