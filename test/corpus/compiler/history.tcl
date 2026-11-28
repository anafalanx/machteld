package require machteld

# History acceptance and entry-cost experiment. Run from any working directory.
set here [file dirname [file normalize [info script]]]
set timings 0
set tclReferences 0
set rows 480
set shape mixed
for {set i 0} {$i < [llength $argv]} {incr i} {
    set flag [lindex $argv $i]
    switch -exact -- $flag {
        --timings {set timings 1}
        --tcl-references {set tclReferences 1; set timings 1}
        --embedded {
            if {[info exists compiler]} {error "select the candidate compiler once"}
            set compiler [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with - --rows - --shape {
            if {[incr i] >= [llength $argv]} {error "$flag requires an argument"}
            set value [lindex $argv $i]
            switch -exact -- $flag {
                --compiler {
                    if {[info exists compiler]} {error "select the candidate compiler once"}
                    set compiler $value
                }
                --compare-with {set baseline $value; set timings 1}
                --rows {
                    if {![string is integer -strict $value] || $value < 0} {error "expected a nonnegative row count"}
                    set rows $value
                }
                --shape {
                    if {$value ni {mixed distinct dense}} {error "expected mixed, distinct or dense"}
                    set shape $value
                }
            }
        }
        default {error "usage: history.tcl ?--compiler directory | --embedded? ?--timings? ?--tcl-references? ?--compare-with directory? ?--rows count? ?--shape mixed|distinct|dense?"}
    }
}
if {![info exists compiler]} {set compiler [file join $here .. .. .. packages application-compiler]}
source -encoding utf-8 [file join $here reference.tcl]
source -encoding utf-8 [file join $here history-checked.tcl]
set sources {}
foreach unit {kernels history} {
    set file [open [file join $here $unit.src] r]
    try {chan configure $file -encoding utf-8; dict set sources $unit [read $file]} finally {close $file}
}
set compilers [dict create X $compiler]
if {[info exists baseline]} {dict set compilers baseline $baseline}
dict for {tag directory} $compilers {
    set build [interp create]
    try {
        $build eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set artifact [$build eval [list ::appcompiler::compile $sources ::$tag]]
    } finally {interp delete $build}
    namespace eval :: [dict get $artifact script]
}

proc feeds {rows {shape mixed}} {
    set channels [list Amber amber "zero\0part" 雪 {}]
    set feeds {}
    foreach source {0 1} count [list [expr {($rows+1)/2}] [expr {$rows/2}]] {
        set feed {}
        for {set i 0} {$i < $count} {incr i} {
            set reading none
            if {$shape ne "mixed" || ($i+2*$source)%9} {
                set reading [list some [expr {($i*29)%53 - 26 + 100*$source}]]
            }
            switch $shape {
                mixed {set channel [lindex $channels [expr {$i%5}]]}
                distinct {set channel "$source-$i"}
                dense {set channel R}
            }
            lappend feed [dict create tick [expr {$i/2}] channel $channel reading $reading]
        }
        lappend feeds $feed
    }
    return $feeds
}

# A stable general sort of concatenated feeds is independent of the X merge.
proc expectedMerge {first second} {
    set tagged {}
    foreach event [concat $first $second] {lappend tagged [list [dict get $event tick] $event]}
    return [lmap pair [lsort -integer -index 0 $tagged] {lindex $pair 1}]
}

proc queries {rows {shape mixed}} {
    set last [expr {max(0,($rows+3)/4-1)}]
    set out {}
    foreach cutoff [list -1 0 1 [expr {$last/3}] [expr {$last/2}] $last [expr {$last+1}]] \
            channel [list Amber amber {} 雪 "zero\0part" Amber missing] {
        set start [expr {max(0,$cutoff-12)}]
        if {$shape eq "dense"} {set channel R; set start 0}
        lappend out [dict create cutoff $cutoff channel $channel start $start stop [expr {$cutoff+1}]]
    }
    return $out
}

proc publicQuery {prefix events query} {
    dict with query {
        set state [${prefix}::snapshot $events $cutoff]
        set readings [${prefix}::window_readings $events $channel $start $stop]
    }
    return [dict create state $state readings $readings]
}

proc publicQueries {prefix events requests} {
    return [lmap request $requests {publicQuery $prefix $events $request}]
}

proc assertAnswers {label got expected} {
    if {[llength $got] != [llength $expected]} {error "$label: wrong number of answers"}
    foreach answer $got reference $expected {
        if {[lsort [dict keys $answer]] ne {readings state}} {error "$label: incorrect answer fields"}
        set state [dict get $answer state]
        set want [dict get $reference state]
        if {[dict size $state] != [dict size $want]} {error "$label: incorrect snapshot size"}
        dict for {k v} $want {
            if {![dict exists $state $k] || [dict get $state $k] ne $v} {error "$label: incorrect reading at key [list $k]"}
        }
        set values [dict get $answer readings]
        set want [dict get $reference readings]
        if {[llength $values] != [llength $want]} {error "$label: incorrect window length"}
        foreach v $values w $want {if {$v ne $w} {error "$label: incorrect window element"}}
    }
}

proc requireOk {pair} {
    lassign $pair tag payload
    if {$tag ne "ok"} {error "unexpected X result: $pair"}
    return $payload
}

proc badInput {command path} {
    if {![catch {{*}$command} message options]} {error "accepted invalid integer at $path"}
    if {[dict get $options -errorcode] ne {APPCOMPILER ARGUMENT TYPE} || $message ne "expected int at $path"} {
        error "wrong boundary diagnostic for $path: [dict get $options -errorcode] / $message"
    }
}

proc verifyHistory {tag first second imported requests expected} {
    set h ::${tag}::history
    set k ::${tag}::kernels
    set actual [requireOk [${h}::merge_feeds $first $second]]
    if {$actual ne $imported} {error "$tag: input row lost or reordered during import"}
    assertAnswers "$tag public" [publicQueries $k $actual $requests] $expected
    assertAnswers "$tag batch" [${h}::query_batch $actual $requests] $expected
    assertAnswers "$tag pipeline" [requireOk [${h}::import_and_query $first $second $requests]] $expected
    if {[${h}::snapshot_entry $actual 0] != 0 || [${h}::window_entry $actual a 0 1] != 0} {error "$tag: bad entry probe"}
    foreach index [lsort -unique -integer [list 0 [expr {[llength $actual]-1}]]] {
        if {$index < 0 || ![llength $actual]} continue
        set bad $actual
        set event [lindex $bad $index]
        dict set event tick not_an_integer
        lset bad $index $event
        set path [format {$events.%d.tick} $index]
        # Even a query that would stop on its first row validates the entire input.
        foreach command [list [list ${k}::snapshot $bad -1] [list ${h}::snapshot_entry $bad -1] \
                [list ${k}::window_readings $bad absent 0 0] [list ${h}::window_entry $bad absent 0 0] \
                [list ${h}::query_batch $bad {}]] {badInput $command $path}
    }
    foreach command [list [list ${k}::snapshot $actual invalid] [list ${h}::snapshot_entry $actual invalid]] {
        badInput $command {$cutoff}
    }
    foreach command [list [list ${k}::window_readings $actual absent 0 invalid] [list ${h}::window_entry $actual absent 0 invalid]] {
        badInput $command {$end}
    }
    if {[llength $second]} {
        set bad $second
        set event [lindex $bad end]
        dict set event tick not_an_integer
        lset bad end $event
        set path [format {$second.%d.tick} [expr {[llength $bad]-1}]]
        badInput [list ${h}::merge_feeds $first $bad] $path
        badInput [list ${h}::import_and_query $first $bad {}] $path
    }
}

# A known overlap: ties within and across feeds, an absent reading after a
# present one, and a later replacement. The fixture fixes the oracle's meaning.
set a [dict create tick 7 channel R reading {some 1}]
set b [dict replace $a reading {some 2}]
set c [dict replace $a reading {some 3}]
set d [dict replace $a reading none]
set e [dict replace $a tick 8 reading {some -7}]
set first [list $a $b $e]
set second [list $c $d]
set merged [expectedMerge $first $second]
if {$merged ne [list $a $b $c $d $e]} {error "stable-sort oracle lost tie order"}
set requests {}
foreach cutoff {6 7 8} {lappend requests [dict create cutoff $cutoff channel R start 7 stop [expr {$cutoff+1}]]}
set expected [list [dict create state {} readings {}] [dict create state {R 3} readings {1 2 3}] [dict create state {R -7} readings {1 2 3 -7}]]
assertAnswers golden [publicQueries ::hand $merged $requests] $expected
assertAnswers {checked Tcl golden} [::checkedHistory::batch $merged $requests] $expected

# The ordinary reference receives canonical observations. Both public entry
# points must accept these equivalent spellings and check rows past the cutoff.
set opaque [::machteld::json decode -typed {{"evidence":[true,1.00]}}]
set raw [list [dict create tick +0007 channel R reading {some +003} future $opaque] \
    [dict create tick 0007 channel R] [dict create tick +0008 channel R reading {some -007}]]
set canonical [list [dict create tick 7 channel R reading {some 3}] \
    [dict create tick 7 channel R reading none] [dict create tick 8 channel R reading {some -7}]]
set answers [publicQueries ::hand $canonical $requests]
foreach prefix [concat ::checkedHistory [lmap tag [dict keys $compilers] {format {::%s::kernels} $tag}]] {
    assertAnswers "$prefix canonicalizes public input" [publicQueries $prefix $raw $requests] $answers
    set broken [concat $raw [list [dict create tick 11 channel R reading {some bad}]]]
    badInput [list ${prefix}::snapshot $broken -1] {$events.3.reading}
    badInput [list ${prefix}::window_readings $broken absent 0 0] {$events.3.reading}
}
if {[::machteld::json encode -- $opaque] ne {{"evidence":[true,1.00]}}} {error "lost future observation fields"}
dict for {tag compilerDir} $compilers {verifyHistory $tag $first $second $merged $requests $expected}

set fixtures {{0 mixed} {1 mixed} {12 mixed} {480 mixed} {1920 mixed} {64 distinct} {64 dense}}
set selected [list $rows $shape]
if {$selected ni $fixtures} {lappend fixtures $selected}
foreach fixture $fixtures {
    lassign $fixture size distribution
    lassign [feeds $size $distribution] first second
    set merged [expectedMerge $first $second]
    set requests [queries $size $distribution]
    set expected [publicQueries ::hand $merged $requests]
    assertAnswers {checked Tcl batch} [::checkedHistory::batch $merged $requests] $expected
    dict for {tag compilerDir} $compilers {verifyHistory $tag $first $second $merged $requests $expected}
}
if {!$timings} {
    puts "compiler history corpus: stable two-feed import, public and batched queries, and boundary errors passed"
    return
}

# Warm, separately calibrated batches estimate mean per-call cost. Each real
# public query is also timed individually to report the distribution of latency.
proc timed {command calls} {lindex [time {{*}$command} $calls] 0}
proc batchSize {command} {
    set n 1
    while {1} {
        set us [timed $command $n]
        if {$us*$n >= 15000} {return $n}
        set n [expr {max($n+1,min($n*8,int(ceil(20000/max(.001,$us)))))}]
    }
}
proc pct {values p} {
    set xs [lsort -real $values]
    set x [expr {$p*([llength $xs]-1)}]
    set a [expr {int(floor($x))}]
    set b [expr {int(ceil($x))}]
    return [expr {[lindex $xs $a]+($x-$a)*([lindex $xs $b]-[lindex $xs $a])}]
}
proc row {kind metric tag index query batch us rate} {
    puts [join [list $kind $metric $tag $index $query $batch [format %.4f $us] $rate] "\t"]
}
proc importRate {metric rows us} {
    if {$metric eq "import"} {return [format %.1f [expr {$rows*1e6/max($us,.001)}]]}
    return -
}

proc trialOrder {variants round} {
    if {[llength $variants] <= 2} {return [expr {$round % 2 ? [lreverse $variants] : $variants}]}
    set count [llength $variants]
    if {($round / $count) % 2} {set variants [lreverse $variants]}
    set first [expr {$round % $count}]
    return [concat [lrange $variants $first end] [lrange $variants 0 [expr {$first-1}]]]
}

lassign [feeds $rows $shape] first second
set merged [expectedMerge $first $second]
set requests [queries $rows $shape]
set q [lindex $requests 4]
set window [list $merged [dict get $q channel] [dict get $q start] [dict get $q stop]]
set commands {}
dict for {tag compilerDir} $compilers {
    set h ::${tag}::history
    set k ::${tag}::kernels
    dict set prefixes $tag $k
    dict set commands import $tag [list ${h}::merge_feeds $first $second]
    dict set commands snapshot $tag [list ${k}::snapshot $merged [dict get $q cutoff]]
    dict set commands snapshot_entry $tag [list ${h}::snapshot_entry $merged [dict get $q cutoff]]
    dict set commands window $tag [list ${k}::window_readings {*}$window]
    dict set commands window_entry $tag [list ${h}::window_entry {*}$window]
    dict set commands public_batch $tag [list publicQueries $k $merged $requests]
    dict set commands typed_batch $tag [list ${h}::query_batch $merged $requests]
    dict set commands pipeline $tag [list ${h}::import_and_query $first $second $requests]
}
if {$tclReferences} {
    set expected [publicQueries ::hand $merged $requests]
    foreach {tag prefix} {checked_tcl ::checkedHistory ordinary_tcl ::hand} {
        dict set prefixes $tag $prefix
        assertAnswers "$tag public" [publicQueries $prefix $merged $requests] $expected
        dict set commands snapshot $tag [list ${prefix}::snapshot $merged [dict get $q cutoff]]
        dict set commands window $tag [list ${prefix}::window_readings {*}$window]
        dict set commands public_batch $tag [list publicQueries $prefix $merged $requests]
    }
    assertAnswers "checked Tcl batch" [::checkedHistory::batch $merged $requests] $expected
    dict set commands typed_batch checked_tcl [list ::checkedHistory::batch $merged $requests]
}
puts [join {kind metric implementation round query calls microseconds rows_per_second} "\t"]
dict for {metric variants} $commands {
    dict for {tag command} $variants {set count($metric,$tag) [batchSize $command]}
}
# Across two cycles each path occupies every slot, including first and last,
# and both revisions take a turn at each position. Inert and real calls share
# the same rounds so entry-cost fractions can be computed within a round.
set metrics [dict keys $commands]
set width [llength $metrics]
for {set i 0} {$i < 2*$width} {incr i} {
    set order $metrics
    if {$i >= $width} {set order [lreverse $order]}
    for {set pos 0} {$pos < $width} {incr pos} {
        set metric [lindex $order [expr {($i+$pos)%$width}]]
        foreach tag [trialOrder [dict keys [dict get $commands $metric]] $i] {
            set n $count($metric,$tag)
            set us [timed [dict get $commands $metric $tag] $n]
            lappend times($metric,$tag) $us
            row sample $metric $tag [expr {$i+1}] - $n $us [importRate $metric $rows $us]
        }
    }
}
foreach metric $metrics {
    foreach tag [dict keys [dict get $commands $metric]] {
        set us [pct $times($metric,$tag) .5]
        row median $metric $tag - - $count($metric,$tag) $us [importRate $metric $rows $us]
    }
}
foreach tag [dict keys $prefixes] {set latency($tag) {}}
for {set round 1} {$round <= 12} {incr round} {
    set index 0
    foreach q $requests {
        foreach tag [trialOrder [dict keys $prefixes] [expr {$round+$index}]] {
            set us [timed [list publicQuery [dict get $prefixes $tag] $merged $q] 1]
            lappend latency($tag) $us
            row sample public_query $tag $round $index 1 $us -
        }
        incr index
    }
}
set expected [publicQueries ::hand $merged $requests]
foreach tag [dict keys $prefixes] {
    foreach {name p} {median .5 p95 .95} {row $name public_query $tag - - 1 [pct $latency($tag) $p] -}
}
foreach tag [dict keys $compilers] {
    verifyHistory $tag $first $second $merged $requests $expected
}
