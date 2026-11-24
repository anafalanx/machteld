package require machteld

namespace eval ::sqltest {
    proc check {name condition} {
        if {!$condition} { error "FAIL sqlite3: $name" }
        puts "ok   sqlite3: $name"
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
