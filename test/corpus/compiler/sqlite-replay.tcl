package require machteld
package require sqlite3

set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set example [file join $root examples typed-import]
set rounds 12
set rows 240
set mode {}
set tclReferences 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set option [lindex $argv $i]] {
        --once {set mode once}
        --timings {set mode timings}
        --tcl-references {set tclReferences 1}
        --embedded {
            if {[info exists compiler]} {error "select the candidate compiler once"}
            set compiler [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with - --rounds - --rows-per-source {
            if {[incr i] >= [llength $argv]} {error "$option needs an argument"}
            set value [lindex $argv $i]
            switch -- $option {
                --compiler {
                    if {[info exists compiler]} {error "select the candidate compiler once"}
                    set compiler $value
                }
                --compare-with {set baseline $value}
                --rows-per-source {
                    if {![string is integer -strict $value] || $value < 0} {
                        error "expected a nonnegative number of claims per source"
                    }
                    set rows $value
                }
                --rounds {
                    if {![string is integer -strict $value] || $value < 2 || $value % 2} {
                        error "expected an even number of timed rounds, at least two"
                    }
                    set rounds $value
                    set mode timings
                }
            }
        }
        default {error "usage: sqlite-replay.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--tcl-references? ?--once | --timings | --rounds count? ?--rows-per-source count?"}
    }
}
if {![info exists compiler]} {set compiler [file join $root packages application-compiler]}
if {$mode eq {}} {set mode [expr {[info exists baseline] || $tclReferences ? "timings" : "once"}]}
set compilers [dict create X $compiler]
if {[info exists baseline]} {dict set compilers baseline $baseline}

set fd [open [file join $example observations.src] r]
try {chan configure $fd -encoding utf-8; set observations [read $fd]} finally {close $fd}
set driver {import observations
export fn .count($wire: text) -> result<int,problem> {
    $batch ::= decode_json<.observations::batch>($wire)?
    return ok(len($batch.claims))
}
export fn .merge_wire($path: text, $wire: text) -> result<int,problem> =>
    .observations::merge($path, decode_json<.observations::batch>($wire)?)
export fn .query_wire($path: text, $at: int) -> result<list<text>,problem> {
    $findings ::= .observations::at($path, 'E7', $at)?
    $lines := list<text>()
    for $row in $findings { $lines = list_append($lines, encode_json($row)?) }
    return ok($lines)
}}
dict for {tag directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set result [$child eval [list ::appcompiler::compile [dict create observations $observations bench $driver] ::replay_$tag]]
        namespace eval :: [dict get $result script]
    } finally {interp delete $child}
}

proc feed {source rows} {
    set claims {}
    for {set id 0} {$id < $rows} {incr id} {
        set start [expr {5 * ($id / 20)}]
        set samples {}
        for {set s 0} {$s < 12} {incr s} {
            lappend samples [format {{"tick":%d,"values":[%d,1.000e+2,5.75],"unit":"mm"}} \
                [expr {$start + $s}] [expr {$id + $s}]]
        }
        lappend claims [format {{"id":"%d","entity":"E%d","field":"reading","starts":%d,"ends":%d,"value":"%s-%d","trace":%d,"sensor_samples":[%s]}} \
            $id [expr {$id % 20}] $start [expr {$start + 8}] $source $id $id [join $samples ,]]
    }
    return [format {{"source":"%s","claims":[%s]}} $source [join $claims ,]]
}

# Reconstruct the expected active claims directly from the input intervals.
proc expectedQuery {instant rows} {
    set ids {}
    for {set id 7} {$id < $rows} {incr id 20} {
        set start [expr {5 * ($id / 20)}]
        if {$start <= $instant && $instant < $start + 8} {lappend ids $id}
    }
    set findings {}
    foreach source {north south} {
        foreach id [lsort -ascii $ids] {
            set start [expr {5 * ($id / 20)}]
            lappend findings [format {{"source":"%s","id":"%d","entity":"E7","field":"reading","starts":%d,"ends":%d,"value":"%s-%d","disputed":true}} \
                $source $id $start [expr {$start + 8}] $source $id]
        }
    }
    return $findings
}

# SQLite parses the fixture independently. Keep the entire serialized claim,
# including the original spelling of every number inside the sensor samples.
proc makeOracle {path feeds rows} {
    sqlite3 oracle $path -create 0
    try {
        dict for {source wire} $feeds {
            oracle eval {
                INSERT INTO claims(source,id,entity,field,starts,ends,value,payload)
                SELECT $source, value->>'id', value->>'entity', value->>'field',
                       value->>'starts', value->>'ends', value->>'value', value
                  FROM json_each($wire, '$.claims')
            }
        }
        if {[oracle onecolumn {
            SELECT count(*) FROM claims WHERE json_array_length(payload, '$.sensor_samples') = 12
        }] != [dict size $feeds] * $rows} {error "incomplete input fixture"}
    } finally {oracle close}
}
proc verifyDatabase {database oraclePath} {
    sqlite3 db $database -readonly 1 -create 0
    try {
        db eval {ATTACH $oraclePath AS oracle}
        if {[db onecolumn {
            SELECT EXISTS (SELECT * FROM main.claims EXCEPT SELECT * FROM oracle.claims)
                OR EXISTS (SELECT * FROM oracle.claims EXCEPT SELECT * FROM main.claims)
        }]} {error "persisted claim columns or JSON payload differ from the input"}
    } finally {db close}
}

proc measured {durationsVar name command} {
    upvar 1 $durationsVar durations
    set start [clock microseconds]
    lassign [{*}$command] status result
    dict set durations $name [expr {[clock microseconds] - $start}]
    if {$status ne "ok"} {error "$name failed: $result"}
    return $result
}
proc exercise {tag database feeds queries rows} {
    set prefix ::replay_${tag}::bench
    set durations {}
    if {[measured durations decode [list ${prefix}::count [dict get $feeds north]]] != $rows} {
        error "$tag decoded the wrong number of north claims"
    }
    foreach {name source expected} [list north north $rows south south $rows replay north 0] {
        set count [measured durations $name [list ${prefix}::merge_wire $database [dict get $feeds $source]]]
        if {$count != $expected} {error "$tag $name inserted $count claims, expected $expected"}
    }
    dict for {instant expected} $queries {
        set lines [measured durations query-$instant [list ${prefix}::query_wire $database $instant]]
        if {$lines ne $expected} {error "$tag query at $instant returned $lines, expected $expected"}
    }
    dict set durations whole [::tcl::mathop::+ {*}[dict values [dict remove $durations decode]]]
    return $durations
}

foreach source {north south} {dict set feeds $source [feed $source $rows]}
foreach instant {0 7 17 20000} {dict set queries $instant [expectedQuery $instant $rows]}
set work [file normalize [file tempdir]]
try {
    set empty [file join $work empty.db]
    set child [::machteld::run -timeout 30s -- [info nameofexecutable] [file join $example create_sample.tcl] $empty]
    if {[dict get $child exit]} {error "could not create the example database: [dict get $child err]"}
    set oracle [file join $work oracle.db]
    file copy -- $empty $oracle
    makeOracle $oracle $feeds $rows

    set last [expr {$mode eq "once" ? 0 : $rounds}]
    if {$last} {puts "round\tcompiler\toperation\tmicroseconds"}
    set tags [dict keys $compilers]
    if {$tclReferences} {
        source -encoding utf-8 [file join [file dirname [info script]] sqlite-replay-ordinary.tcl]
        lappend tags Tcl
        foreach tag $tags {::replayChecks::verify $tag $empty $work}
    }
    for {set round 0} {$round <= $last} {incr round} {
        set order [expr {$round % 2 ? $tags : [lreverse $tags]}]
        if {[llength $tags] > 2} {
            set offset [expr {($round / 2) % [llength $tags]}]
            set order [concat [lrange $order $offset end] [lrange $order 0 $offset-1]]
        }
        foreach tag $order {
            set database [file join $work trial.db]
            file copy -- $empty $database
            set durations [exercise $tag $database $feeds $queries $rows]
            verifyDatabase $database $oracle
            file delete -- $database
            if {$round} {
                dict for {name elapsed} $durations {puts [join [list $round $tag $name $elapsed] \t]}
            }
        }
    }
    if {!$last} {
        set total [expr {[dict size $feeds] * $rows}]
        puts "compiler SQLite replay: $total claims, [expr {12 * $total}] retained samples and four temporal queries verified"
    }
} finally {file delete -force -- $work}
