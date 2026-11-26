package require machteld

if {$argv eq {--sql-worker}} {
    worker on verifyProfile {path} {
        package require sqlite3
        sqlite3 db $path -foreignkeys 1 -defensive 1
        try {
            return [expr {[db config enable_fkey] && [db config defensive] &&
                [catch {db eval {INSERT INTO child VALUES(999)}}]}]
        } finally {db close}
    }
    worker on compete {path destination barrier name} {
        package require machteld::sqlite
        sqlite3 db $path -readonly 1
        db timeout 10000
        # Rendezvous after both read-only integrity checks. Neither writer can
        # rely on an earlier test for the absence of the final filename.
        proc ::backupRendezvous {directory name cmd op} {
            set f [open [file join $directory $name] {WRONLY CREAT EXCL}]
            close $f
            set until [expr {[clock milliseconds]+30000}]
            while {![file exists [file join $directory A]] || ![file exists [file join $directory B]]} {
                if {[clock milliseconds] >= $until} {error "other backup did not reach publication"}
                after 20
            }
        }
        set hook [list ::backupRendezvous $barrier $name]
        trace add execution ::machteld::Publish enter $hook
        try {
            ::machteld::sqlite::backup db $destination
            return created
        } trap {MACHTELD SQLITE exists} {} {
            return exists
        } finally {
            trace remove execution ::machteld::Publish enter $hook
            db close
        }
    }
    worker serve
    return
}

namespace eval ::sqltest {
    proc check {name condition} {
        if {!$condition} { error "FAIL sqlite3: $name" }
        puts "ok   sqlite3: $name"
    }

    proc features {work} {
        package require machteld::sqlite
        set path [file join $work {profile and search.db}]
        sqlite3 ::sqltest::db $path -foreignkeys true -defensive true
        try {
            db eval {
                CREATE TABLE parent(id INTEGER PRIMARY KEY);
                CREATE TABLE child(parent INTEGER REFERENCES parent);
                CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT NOT NULL);
                INSERT INTO books VALUES (1,'Bruxelles-Nord'), (2,'Paris Nord');
                CREATE VIRTUAL TABLE titles USING fts5(title, content='books', content_rowid='id', tokenize='trigram');
                INSERT INTO titles(titles) VALUES('rebuild');
            }
            check "connection safeguards were applied before use" [expr {
                [db config defensive] && [db config enable_fkey] && [db onecolumn {PRAGMA foreign_keys}] &&
                [catch {db eval {INSERT INTO child VALUES(9)}}] && [catch {db eval {DELETE FROM sqlite_schema}}]}]
            check "external-content trigram index resolves the case-insensitive joined catalogue row" [expr {
                [db eval -parameters {3 {text XeLL}} {
                    SELECT b.title FROM titles JOIN books AS b ON b.id=titles.rowid WHERE titles MATCH ?3
                }] eq {Bruxelles-Nord}}]
            ::machteld::store open $path
            try {
                ::machteld::store put checkpoint ok
                check "key/value store and FTS index share one database" [expr {
                    [db eval {SELECT key FROM kv}] eq {checkpoint} && [::machteld::store get checkpoint] eq "ok"}]
            } finally {::machteld::store close}

            set bytes [binary decode hex 00ff4180]
            set text "00\u0000\U0001f31f"
            set params [dict create 1 {integer -9223372036854775808} 3 [list blob $bytes] \
                8 [list text $text] 9 {null} 10 {real 1.25}]
            set sql {SELECT ?8, ?3, ?1, typeof(?9), ?10, hex(?3), hex(?8), ?8, '?2'}
            set row [db eval -parameters $params $sql]
            check "sparse repeated slots bind bytes, signed integers, real, NULL and UTF-8 with NUL" [expr {
                $row eq [list $text $bytes -9223372036854775808 null 1.25 00FF4180 \
                    [string toupper [binary encode hex [encoding convertto utf-8 $text]]] $text ?2]}]
            check "an in-scope SQL comment or string adds no binding" [expr {
                [db eval -parameters {5 {integer 12}} {SELECT ?5 /* ?12 */, '?2'}] eq {12 ?2}}]
            check "empty blob and empty text are distinct from SQL NULL" [expr {
                [db eval -parameters [dict create 1 [list blob [binary format a0 {}]] 2 {text {}} 3 {null}] \
                    {SELECT typeof(?1),length(?1),typeof(?2),length(?2),typeof(?3)}] eq {blob 0 text 0 null}}]
            foreach bad [list {} {3 integer} {3 {integer 9223372036854775808}} {3 {null unused}} {3 {unknown 4}}] {
                check "invalid or missing typed binding is refused: $bad" [expr {
                    [catch {db eval -parameters $bad {SELECT ?3}} msg opt] &&
                    [dict get $opt -errorcode] eq {MACHTELD SQLITE parameter}}]
            }
            set values {}
            db eval -parameters {2 {integer 37}} {SELECT ?2 AS n UNION ALL SELECT ?2+1} record {
                lappend values $record(n) [db eval -parameters {2 {text nested}} {SELECT ?2}]
            }
            check "nested row callbacks retain the outer bindings" [expr {$values eq {37 nested 38 nested}}]
            check "statement caching cannot leak a numbered binding into ordinary eval" [expr {
                [db eval -parameters {2 {text bound}} {SELECT typeof(?2)}] eq "text" &&
                [db eval {SELECT typeof(?2)}] eq "null"}]
            sqlite3 ::sqltest::defaults $path
            try {
                check "default connections retain upstream settings" [expr {
                    ![defaults config defensive] && ![defaults config enable_fkey]}]
                defaults eval {INSERT INTO child VALUES(9); DELETE FROM child}
            } finally {defaults close}
            set pool [::machteld::pool create -width 2 -- [info nameofexecutable] [file normalize [info script]] --sql-worker]
            try {
                ::machteld::pool submit $pool [list [dict create op verifyProfile path $path]]
                set reply [lindex [::machteld::pool wait $pool -timeout 30s] 0]
                check "worker connection independently enforces the requested profile" [expr {
                    [dict get $reply ok] && [dict get $reply result]}]
            } finally {::machteld::pool close $pool}
            db eval {PRAGMA journal_mode=WAL}
            set dest [file join $work verified.db]
            # Keep source-database lock acquisition independent on the two
            # workers. This race deliberately synchronizes their publications.
            set otherSource [file join $work other-source.db]
            db backup $otherSource
            set barrier [file join $work barrier]
            file mkdir $barrier
            set pool [::machteld::pool create -width 2 -- [info nameofexecutable] [file normalize [info script]] --sql-worker]
            try {
                ::machteld::pool submit $pool [lmap name {A B} source [list $path $otherSource] {
                    dict create op compete path $source destination $dest barrier $barrier name $name
                }]
                set replies [::machteld::pool wait $pool -timeout 75s]
                foreach reply $replies {
                    if {![dict get $reply ok]} {error "backup contender failed: $replies"}
                }
                check "two processes finish verification before a single atomic winner publishes" [expr {
                    [lsort [lmap r $replies {dict get $r result}]] eq {created exists}}]
            } finally {::machteld::pool close $pool}
            set digest [::machteld::hash file sha256 $dest]
            check "existing backup is preserved byte-for-byte" [expr {
                [catch {::machteld::sqlite::backup db $dest} message options] &&
                [dict get $options -errorcode] eq {MACHTELD SQLITE exists} &&
                [::machteld::hash file sha256 $dest] eq $digest}]
            sqlite3 ::sqltest::snapshot $dest -readonly 1
            try {
                check "verified backup is a standalone read-only snapshot of the WAL database" [expr {
                    [snapshot onecolumn {PRAGMA journal_mode}] eq "delete" &&
                    [snapshot eval {SELECT title FROM titles WHERE titles MATCH 'xell'}] eq {Bruxelles-Nord} &&
                    [snapshot eval {PRAGMA integrity_check}] eq {ok}}]
            } finally {snapshot close}
            db eval {
                PRAGMA ignore_check_constraints=1;
                CREATE TABLE checked(n INTEGER CHECK(n>0));
                INSERT INTO checked VALUES(-1);
                PRAGMA ignore_check_constraints=0;
            }
            set invalid [file join $work invalid.db]
            set failed [catch {::machteld::sqlite::backup db $invalid} message options]
            set remaining [glob -nocomplain -directory $work .machteld-sqlite-*]
            check "failed integrity check leaves no backup or staging files ($message, $remaining)" [expr {
                $failed && [dict get $options -errorcode] eq {MACHTELD SQLITE verify} &&
                ![file exists $invalid] && ![llength $remaining]}]
            db eval {DROP TABLE checked}
            db collate NOCASE {apply {{a b} {string compare $b $a}}}
            db eval {
                CREATE TABLE names(s TEXT);
                CREATE INDEX sorted_names ON names(s COLLATE NOCASE);
                INSERT INTO names VALUES('a'),('c'),('b'),('d');
            }
            check "a read-only integrity check rejects an index requiring an app-local collation" [expr {
                [catch {::machteld::sqlite::backup db $invalid} message options] &&
                [dict get $options -errorcode] eq {MACHTELD SQLITE verify} &&
                ![file exists $invalid]}]
        } finally {db close}
    }

    proc packagedImport {work} {
        set example [file normalize [file join [file dirname [info script]] .. examples sqlite-lookup]]
        set executable [info nameofexecutable]
        set archive [file join $work catalogue.machteld]
        set database [file join $work {external catalogue.db}]
        foreach arguments [list [list pack $example -o $archive] [list $archive --create-demo $database]] {
            set run [::machteld::run -timeout 90s -dir $work -- $executable {*}$arguments]
            if {[dict get $run status] ne "ok" || [dict get $run exit] != 0} {error "packaged import failed: $run"}
        }
        sqlite3 ::sqltest::catalogue $database -readonly 1
        try {
            check "the relocated archive imports four joined categories in one external catalogue" [expr {
                [catalogue eval {SELECT category, count(*) FROM items GROUP BY category ORDER BY category}] eq
                {Kits 31250 Parts 31250 Supplies 31250 Tools 31250} &&
                [catalogue eval {PRAGMA integrity_check}] eq {ok}}]
        } finally {catalogue close}
    }

    proc documentedCallbacks {work} {
        sqlite3 ::sqltest::hooks [file join $work hooks.db]
        try {
            hooks eval {PRAGMA journal_mode=WAL; CREATE TABLE notes(title TEXT)}
            set ::sqltest::changes {}
            set ::sqltest::wal {}
            hooks update_hook [list lappend ::sqltest::changes]
            hooks wal_hook [list apply {{schema frames} {
                set ::sqltest::wal [list $schema $frames]
                return 0
            }}]
            hooks eval {INSERT INTO notes VALUES ('first')}
            check "update and WAL hooks receive the documented arguments" [expr {
                $::sqltest::changes eq {INSERT main notes 1} &&
                [lindex $::sqltest::wal 0] eq "main" && [lindex $::sqltest::wal 1] > 0}]

            set ::sqltest::rolledBack 0
            hooks rollback_hook {incr ::sqltest::rolledBack}
            hooks commit_hook {expr {1}}
            check "commit veto triggers rollback after an update notification" [expr {
                [catch {hooks eval {INSERT INTO notes VALUES ('vetoed')}}] &&
                $::sqltest::rolledBack == 1 && [hooks onecolumn {SELECT count(*) FROM notes}] == 1}]
            hooks commit_hook {}
            hooks authorizer [list apply {{action first second schema context} {
                if {$action eq "SQLITE_READ" && $first eq "notes" && $second eq "title" &&
                        $schema eq "main" && $context eq ""} {return SQLITE_IGNORE}
                return SQLITE_OK
            }}]
            check "authorizer can replace one column read with SQL NULL" [expr {
                [hooks onecolumn {SELECT title IS NULL FROM notes}]}]
            hooks authorizer {}

            hooks function lower_label -argcount 1 -deterministic -returntype text {string tolower}
            hooks function number_value -argcount 1 -returntype integer {string cat}
            check "SQL functions apply the documented result conversions" [expr {
                [hooks eval {SELECT lower_label('North'), typeof(number_value('2')),
                                    typeof(number_value('2.5')), typeof(number_value('north'))}] eq
                {north integer real text}}]
            foreach mask {statement profile row close} {
                set ::sqltest::event {}
                hooks trace_v2 [list lappend ::sqltest::event] $mask
                if {$mask eq "close"} {hooks close} else {hooks eval {SELECT 42}}
                set event $::sqltest::event
                lassign $event id detail
                switch $mask {
                    statement {set valid [expr {[llength $event] == 2 && $detail eq "SELECT 42"}]}
                    profile {set valid [expr {[llength $event] == 2 && [string is entier -strict $detail] && $detail >= 0}]}
                    row - close {set valid [expr {[llength $event] == 1}]}
                }
                check "trace_v2 $mask delivers the documented payload" [expr {[string is entier -strict $id] && $valid}]
            }
        } finally {
            if {[namespace which hooks] ne {}} {hooks close}
            unset -nocomplain ::sqltest::changes ::sqltest::wal ::sqltest::rolledBack ::sqltest::event
        }
    }

    proc run {} {
        set version [package require sqlite3]
        check "the Tcl binding is static in this interpreter" [expr {
            [list {} Sqlite3] in [info loaded {}]}]
        check "SQL and the key/value store report the same engine version" [expr {
            $version eq [::machteld::store version]}]

        set safe [interp create -safe]
        try {
            check "safe interpreter cannot acquire a filesystem-capable SQL handle" [expr {
                [catch {interp invokehidden $safe load {} Sqlite3}] &&
                [interp eval $safe {info commands sqlite3}] eq {}}]
        } finally { interp delete $safe }

        set work [file tempdir]
        try {
            documentedCallbacks $work
            features $work
            packagedImport $work
            set path [file join $work {notes 雪.db}]
            sqlite3 ::sqltest::writer $path
            writer eval {CREATE TABLE notes(id INTEGER PRIMARY KEY, label TEXT NOT NULL)}
            sqlite3 ::sqltest::reader $path -readonly 1
            set text {0007 雪 O'Brien}
            writer transaction {
                writer eval {INSERT INTO notes(label) VALUES($text)}
                check "a second connection sees only committed rows" [expr {
                    [reader onecolumn {SELECT count(*) FROM notes}] == 0}]
            }
            check "bound Unicode text is preserved after commit" [expr {
                [reader onecolumn {SELECT label FROM notes WHERE id=1}] eq $text}]
            check "a failed transaction rolls back" [expr {
                [catch {writer transaction {
                    writer eval {DELETE FROM notes}
                    error "intentional failure"
                }} message] && $message eq "intentional failure" &&
                [reader onecolumn {SELECT label FROM notes}] eq $text}]
            check "read-only connection refuses writes" [catch {reader eval {DELETE FROM notes}}]
            check "SQL extension loading stays disabled" [writer onecolumn {
                SELECT sqlite_compileoption_used('OMIT_LOAD_EXTENSION')}]
            check "SQL handle uses the linked SQLite version" [expr {
                [writer onecolumn {SELECT sqlite_version()}] eq $version}]

            set binary [binary format H* 006100ff80]
            set large [expr {wide(1) << 54 | 7}]
            writer eval {
                CREATE TEMP TABLE typed(payload BLOB, n INTEGER);
                INSERT INTO typed VALUES(@binary, $large)
            }
            check "BLOB bytes and signed 64-bit integer round-trip through SQL" [expr {
                [writer eval {SELECT typeof(payload), typeof(n) FROM typed}] eq {blob integer} &&
                [writer onecolumn {SELECT payload FROM typed}] eq $binary &&
                [writer onecolumn {SELECT n FROM typed}] == $large}]

            ::machteld::store open
            ::machteld::store put checkpoint $binary
            writer backup [file join $work snapshot.db]
            sqlite3 ::sqltest::backup [file join $work snapshot.db] -readonly 1
            writer eval {DELETE FROM notes}
            check "backup is an independent database" [expr {
                [reader onecolumn {SELECT count(*) FROM notes}] == 0 &&
                [backup onecolumn {SELECT label FROM notes}] eq $text &&
                [backup onecolumn {PRAGMA integrity_check}] eq "ok"}]
            writer close
            check "closing a SQL handle preserves the open key/value store" [expr {
                [::machteld::store get checkpoint] eq $binary}]
            ::machteld::store close
            check "closing store preserves the open SQL handles" [expr {
                [reader onecolumn {SELECT count(*) FROM notes}] == 0}]

            sqlite3 ::sqltest::writer $path
            writer eval {
                WITH RECURSIVE series(i) AS (
                    VALUES(1) UNION ALL SELECT i + 1 FROM series WHERE i < 125000
                ) INSERT INTO notes(id, label) SELECT i, 'sample' FROM series
            }
            set last 0
            set pageSize 512
            while {1} {
                set page [reader eval {SELECT id FROM notes WHERE id > $last ORDER BY id LIMIT $pageSize}]
                if {![llength $page]} break
                if {[llength $page] > $pageSize} { error "oversized SQL result page" }
                foreach id $page {
                    if {$id != [incr last]} { error "result page skipped or repeated an id" }
                }
            }
            check "125,000 synthetic rows read in bounded ordered pages" [expr {$last == 125000}]
        } finally {
            foreach db {writer reader backup} {
                if {[namespace which $db] ne {}} { $db close }
            }
            ::machteld::store close
            file delete -force -- $work
        }
    }
}

::sqltest::run
puts "ALL SQLITE3 TESTS PASSED"
