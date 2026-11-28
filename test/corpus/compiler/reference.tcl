namespace eval ::hand {}

proc ::hand::gcd_sum {n} {
    set u 17
    set v 23
    set total 0
    for {set i 0} {$i < $n} {incr i} {
        incr u 37
        if {$u >= 509} {incr u -509}
        incr v 71
        if {$v >= 503} {incr v -503}
        set a [expr {$u + 1}]
        set b [expr {$v + 1}]
        while {$a != $b} {
            if {$a > $b} {
                set a [expr {$a - $b}]
            } else {
                set b [expr {$b - $a}]
            }
        }
        incr total $a
    }
    return $total
}

proc ::hand::escape_grid {width height limit} {
    set xstep [expr {3.0 / $width}]
    set ystep [expr {2.0 / $height}]
    set total 0
    for {set y 0} {$y < $height} {incr y} {
        set cy [expr {$y * $ystep - 1.0}]
        for {set x 0} {$x < $width} {incr x} {
            set cx [expr {$x * $xstep - 2.0}]
            set zx 0.0
            set zy 0.0
            set iterations 0
            while {$iterations < $limit && $zx*$zx + $zy*$zy <= 4.0} {
                set nextX [expr {$zx*$zx - $zy*$zy + $cx}]
                set nextY [expr {(2.0 * $zx) * $zy + $cy}]
                set zx $nextX
                set zy $nextY
                incr iterations
            }
            incr total $iterations
        }
    }
    return [list ok $total]
}

proc ::hand::histogram {words} {
    set counts {}
    foreach word $words {
        dict incr counts $word
    }
    return $counts
}

proc ::hand::merge_sorted {left right} {
    set leftCount [llength $left]
    set rightCount [llength $right]
    set i 0
    set j 0
    set merged {}
    while {$i < $leftCount && $j < $rightCount} {
        set a [lindex $left $i]
        set b [lindex $right $j]
        if {$a <= $b} {
            lappend merged $a
            incr i
        } else {
            lappend merged $b
            incr j
        }
    }
    while {$i < $leftCount} {
        lappend merged [lindex $left $i]
        incr i
    }
    while {$j < $rightCount} {
        lappend merged [lindex $right $j]
        incr j
    }
    return $merged
}

proc ::hand::fib {n} {
    if {$n < 2} {return $n}
    return [expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]}]
}

proc ::hand::compact_ids {ids} {
    set compact {}
    foreach id $ids {
        if {![llength $compact] || [lindex $compact end] != $id} {
            lappend compact $id
        }
    }
    return $compact
}

proc ::hand::window_readings {events channel start end} {
    set values {}
    foreach e $events {
        set tick [dict get $e tick]
        if {$tick < $start || $tick >= $end || [dict get $e channel] ne $channel} continue
        lassign [dict get $e reading] tag value
        if {$tag eq "some"} {lappend values $value}
    }
    return $values
}

proc ::hand::snapshot {events cutoff} {
    set state {}
    foreach e $events {
        if {[dict get $e tick] > $cutoff} break
        lassign [dict get $e reading] tag value
        if {$tag eq "some"} {dict set state [dict get $e channel] $value}
    }
    return $state
}

# The currency corpus uses two minor-unit digits. Accumulate signed bignums.
proc ::hand::formatCents {cents} {
    set magnitude [expr {abs($cents)}]
    set units [expr {$magnitude / 100}]
    set fraction [string trimright [format %02d [expr {$magnitude % 100}]] 0]
    if {$fraction ne ""} {append units . $fraction}
    if {$cents < 0} {set units -$units}
    return $units
}

proc ::hand::reconcile {postings} {
    set balance 0
    set low 0
    set high 0
    foreach amount $postings {
        if {![regexp {^(-?)([0-9]+)(?:\.([0-9]{1,2}))?$} $amount -> sign whole fraction]} {
            error "outside the corpus's fixed currency scale: $amount"
        }
        set digits $whole[string range ${fraction}00 0 1]
        scan $digits %lld cents
        if {$sign eq "-"} {set cents [expr {-$cents}]}
        incr balance $cents
        set low [expr {min($low, $balance)}]
        set high [expr {max($high, $balance)}]
    }
    return [lmap n [list $balance $low $high] {formatCents $n}]
}

# SQLite parses the same raw documents independently of the X JSON decoder.
# All JSON integer fixtures and their sums fit in SQLite's signed 64-bit range.
package require sqlite3
sqlite3 ::hand::jsonRef :memory:
proc ::hand::json_intake {documents} {
    set out {}
    foreach wire $documents {
        set value [jsonRef onecolumn {
            SELECT CASE
                WHEN NOT json_valid($wire) THEN NULL
                WHEN json_type($wire) <> 'object' THEN NULL
                WHEN EXISTS (SELECT 1 FROM json_tree($wire) GROUP BY parent, key HAVING count(*) > 1) THEN NULL
                WHEN json_type($wire, '$.source') IS NOT 'text' THEN NULL
                WHEN json_type($wire, '$.amount') IS NOT 'integer' THEN NULL
                WHEN coalesce(json_type($wire, '$.adjustment'), 'integer') <> 'integer' THEN NULL
                ELSE json_extract($wire, '$.amount') + coalesce(json_extract($wire, '$.adjustment'), 0)
            END
        }]
        if {$value eq ""} {
            lappend out none
        } else {
            lappend out [list some $value]
        }
    }
    return $out
}
