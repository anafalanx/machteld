# Read complete timestamped occurrences through the real research application.
package require machteld
package require sqlite3
set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set example [file join $root examples graphviz-table]
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
        default {error {usage: temporal-rows.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--once | --timings?}}
    }
}
if {![dict exists $compilers X]} {dict set compilers X [file join $root packages application-compiler]}
set timed [expr {$mode eq "timings" || ($mode eq {} && [dict exists $compilers baseline])}]

set fd [open [file join $example research.src] r]
try {chan configure $fd -encoding utf-8; set source [read $fd]} finally {close $fd}
set fd [open [file join [file dirname [info script]] temporal-intake.src] r]
try {chan configure $fd -encoding utf-8; set intake [read $fd]} finally {close $fd}
dict for {label directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set compiled [$child eval [list ::appcompiler::compile [dict create research $source intake $intake] ::temporal_$label]]
        namespace eval :: [dict get $compiled script]
    } finally {interp delete $child}
}
source -encoding utf-8 [file join $example research.tcl]

proc stamp {tick} {format {2024-02-29T23:59:59.%09dZ} $tick}
proc fixture {db rows} {
    set ledger [dict create north {Café & ledger} south {Dépôt 雪}]
    set periods {}
    $db transaction {
        dict for {site title} $ledger {$db eval {INSERT INTO source VALUES ($site,$title)}}
        # Insert in reverse order so the real BINARY ordering is observable.
        for {set i $rows} {$i >= 0} {incr i -1} {
            set id [format {claim-%04d} $i]
            set low [expr {$i == 0 ? 1 : 3 + $i % 2}]
            set high [expr {$i == 0 ? 2 : 6 + $i % 3}]
            set starts [stamp $low]
            set ends [stamp $high]
            set asset "Device [expr {$i % 17}]"
            set observation [lindex {{In service} {Under repair} {Held for inspection}} [expr {$i % 3}]]
            set site [expr {$i % 2 ? "north" : "south"}]
            set reference "sheet <$i>"
            $db eval {INSERT INTO occurrence VALUES ($id,$asset,$observation,$site,$reference,$starts,$ends)}
            set record [dict create occurrence_id $id asset $asset observation $observation source_id $site \
                source_name [dict get $ledger $site] reference $reference starts $starts ends $ends]
            lappend periods [list $low $high $record]
        }
    }
    return [lreverse $periods]
}

# The oracle uses integer nanoseconds and the fixture's source names, independent
# of the SQL comparison, BINARY sort, join and temporal conversion.
proc expectedAt {periods tick} {
    set rows {}
    foreach period $periods {
        lassign $period low high record
        if {$low <= $tick && $tick < $high} {lappend rows $record}
    }
    return $rows
}
proc checkRows {result expected} {
    lassign $result tag rows
    if {$tag ne "ok" || [llength $rows] != [llength $expected]} {error "unexpected row count or status: $tag"}
    foreach row $rows want $expected {
        if {[dict size $row] != [dict size $want]} {error "wrong field count for [dict get $want occurrence_id]"}
        dict for {field value} $want {
            if {[dict get $row $field] ne $value} {error "wrong $field for [dict get $want occurrence_id]"}
        }
    }
}

# Fixture order defines the source ID. Equal instants retain both observations.
proc checkIntake {path prefix} {
    set inputs {
        2000-03-01T00:44:59.999999999+00:45
        2000-02-29T18:30:00-05:30
        2000-03-01T00:00:00Z
        2000-03-01T00:00:00.000000001Z
        1999-12-31T23:30:00-01:00
    }
    set midnight 2000-03-01T00:00:00.000000000Z
    set before 2000-02-29T23:59:59.999999999Z
    set after 2000-03-01T00:00:00.000000001Z
    set newYear 2000-01-01T00:30:00.000000000Z
    sqlite3 intakeReader $path
    try {
        intakeReader eval {CREATE TABLE observed(id INTEGER PRIMARY KEY,stamp TEXT NOT NULL) STRICT}
        if {[${prefix}::ingest $path $inputs] ne {ok 5}} {error "failed to commit the observation fixture"}
        if {[intakeReader eval {SELECT id,stamp FROM observed ORDER BY id}] ne
                [list 0 $before 1 $midnight 2 $midnight 3 $after 4 $newYear]} {
            error "persisted order, identity or normalized time changed"
        }
        checkRows [${prefix}::window $path $before $after] [list \
                [dict create id 0 stamp $before] [dict create id 1 stamp $midnight] [dict create id 2 stamp $midnight]]
        intakeReader eval {DELETE FROM observed}
        lassign [${prefix}::ingest $path [linsert $inputs end 2000-03-01T00:00:00-00:00]] tag problem
        if {$tag ne "err" || ![string match {*known numeric offset*} [dict get $problem message]] ||
                [intakeReader onecolumn {SELECT count(*) FROM observed}] != 0} {
            error "late invalid observation lost its diagnostic or committed earlier rows"
        }
    } finally {intakeReader close}
}

set dir [file normalize [file tempdir]]
try {
    dict for {label directory} $compilers {
        checkIntake [file join $dir intake-$label.db] ::temporal_${label}::intake
    }
    set path [file join $dir research.db]
    ::research::createSample $path
    sqlite3 writer $path
    try {
        set count [expr {$timed ? 384 : 12}]
        set periods [fixture writer $count]
        set cases {}
        foreach tick {0 1 2 3 4 6 8} {
            dict set cases $tick [expectedAt $periods $tick]
            dict for {label directory} $compilers {
                checkRows [::temporal_${label}::research::occurrences $path [stamp $tick]] [dict get $cases $tick]
            }
        }
        if {$timed} {
            puts [join {round compiler rows elapsed_us} \t]
            for {set round 1} {$round <= 12} {incr round} {
                set order [dict keys $compilers]
                if {$round % 2} {set order [lreverse $order]}
                set ticks [expr {$round % 2 ? {0 1 4} : {4 1 0}}]
                foreach tick $ticks {
                    set at [stamp $tick]
                    set expected [dict get $cases $tick]
                    foreach label $order {
                        set query ::temporal_${label}::research::occurrences
                        set begin [clock microseconds]
                        set result [$query $path $at]
                        set elapsed [expr {[clock microseconds]-$begin}]
                        checkRows $result $expected
                        unset result
                        puts [join [list $round $label [llength $expected] $elapsed] \t]
                    }
                }
            }
        }
        # Poison the last selected record with the same instant in noncanonical
        # notation. The row still satisfies the SQL predicate and must be rejected.
        set last [lindex [dict get $cases 4] end]
        set id [dict get $last occurrence_id]
        set bad [string replace [dict get $last ends] end end +00:00]
        writer eval {UPDATE occurrence SET ends=$bad WHERE occurrence_id=$id}
        dict for {label directory} $compilers {
            lassign [::temporal_${label}::research::occurrences $path [stamp 4]] tag problem
            if {$tag ne "err" || [dict get $problem code] ne "SQL_TYPE" ||
                    [dict get $problem message] ne "column ends requires canonical instant text"} {
                error "$label accepted a malformed stored timestamp or returned the wrong diagnostic"
            }
        }
        if {!$timed} {puts "compiler temporal rows: verified mixed-offset import and rollback, seven instants, $count overlapping rows and late SQL_TYPE"}
    } finally {writer close}
} finally {file delete -force -- $dir}
