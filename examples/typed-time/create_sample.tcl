package require machteld
package require sqlite3

if {[llength $argv] != 1} {error "usage: [file tail [info script]] NEW_DATABASE"}
set path [file normalize [lindex $argv 0]]
close [open $path {WRONLY CREAT EXCL}]
sqlite3 sample $path -create 0
try {
    sample transaction {
        sample eval {
            CREATE TABLE periods(
                starts TEXT PRIMARY KEY, ends TEXT NOT NULL CHECK(starts < ends), source TEXT NOT NULL
            ) STRICT;
            INSERT INTO periods VALUES
                ('2026-10-25T00:30:00.000000000Z', '2026-10-25T00:30:00.000000001Z', 'first log'),
                ('2026-10-25T00:30:00.000000001Z', '2026-10-25T00:30:00.000000002Z', 'next log'),
                ('2026-10-25T01:30:00.000000000Z', '2026-10-25T01:30:00.000000001Z', 'second log');
        }
    }
} finally {sample close}
