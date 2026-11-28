# Compare the indexed, persisted version with the independent tick-by-tick
# oracle. A test schedule is fixed here. Evidence has a separate receipt time.
proc verifyProbeArchive {implementations} {
    package require sqlite3
    set area [file normalize [file tempdir]]
    set database [file join $area probe.db]
    set runs {}
    set evidence {}
    try {
        sqlite3 probeFixture $database
        try {
            probeFixture eval {
                CREATE TABLE instrument_run(run_id INTEGER PRIMARY KEY, bench TEXT, starts INTEGER, ends INTEGER) STRICT;
                CREATE INDEX run_bench_start ON instrument_run(bench,starts,ends);
                CREATE TABLE evidence(source TEXT, id TEXT, run_id INTEGER, probe TEXT, starts INTEGER,
                    ends INTEGER, recorded INTEGER, PRIMARY KEY(source,id)) STRICT, WITHOUT ROWID;
                CREATE INDEX observations_by_run ON evidence(run_id,starts,ends,recorded);
            }
            probeFixture transaction {
                foreach spec {{1 Alpha 0 18} {2 Alpha 3 9} {3 Alpha 4 4} {4 Other 1 16} {5 Alpha 12 18}} {
                    lassign $spec id bench lo hi
                    lappend runs [runRow $id $bench $lo $hi]
                    probeFixture eval {INSERT INTO instrument_run VALUES ($id,$bench,$lo,$hi)}
                }
                foreach spec {
                    {north a 1 007 -2 5 5} {south a 1 7 2 4 4} {north b 1 雪 5 7 9}
                    {north c 1 🧪 9 13 13} {south d 1 雪 6 9 30} {south e 2 7 5 7 12}
                    {north nul 1 embedded_nul 3 4 5} {north z 1 empty 6 6 0}
                    {north edge 1 clipped 18 23 0} {north hidden 4 other 0 16 1}
                } {
                    lassign $spec source id run probe lo hi received
                    if {$id eq "nul"} {set probe "P\u0000A"}
                    lappend evidence [list $source $received [assignment $id $run $probe $lo $hi]]
                    set bytes [encoding convertto -profile strict utf-8 $probe]
                    probeFixture eval {INSERT INTO evidence VALUES ($source,$id,$run,cast(@bytes AS TEXT),$lo,$hi,$received)}
                }
            }
        } finally {probeFixture close}

        foreach sample {{Alpha 0 18 4} {Alpha 0 18 12} {Alpha 0 18 13} {Alpha 0 18 30}
                        {Alpha 4 15 30} {Alpha 7 7 30} {Alpha 15 4 30} {missing 0 18 30}} {
            lassign $sample bench lo hi known
            set feeds [dict create north {} south {}]
            foreach claim $evidence {
                lassign $claim source recorded row
                if {$recorded <= $known} {dict lappend feeds $source $row}
            }
            set expected [oracle $runs [dict get $feeds north] [dict get $feeds south] $bench $lo $hi]
            set bounds {}
            foreach row $runs {
                set id [dict get $row id]
                if {$id in [dict get $expected runs]} {
                    dict set bounds $id [list [expr {max($lo,[dict get $row start])}] [expr {min($hi,[dict get $row stop])}]]
                }
            }
            set want {}
            foreach id [dict get $expected runs] {lappend want [list 1 $id {*}[dict get $bounds $id]]}
            foreach probe [dict get $expected probes] {lappend want [list 2 $probe 0 0]}
            foreach gap [dict get $expected gaps] {
                lappend want [list 3 [dict get $gap run] [dict get $gap start] [dict get $gap stop]]
            }
            lappend want [list 4 0 [dict get $expected evidence] 0]
            dict for {label command} $implementations {
                lassign [$command $database {*}$sample] tag result
                if {$tag ne "ok"} {error "archive query failed for $label: $result"}
                set actual {}
                foreach row $result {lappend actual [list [dict get $row kind] [dict get $row name] [dict get $row low] [dict get $row high]]}
                if {$actual ne $want} {error "archive query changed evidence or covered time for $label, $sample: $actual"}
            }
        }
    } finally {
        if {[file isfile $database]} {file delete -- $database}
        file delete -- $area
    }
}
