package require machteld
package require sqlite3

if {[llength $argv] != 1} {error "usage: [file tail [info script]] NEW_DATABASE"}
set path [file normalize [lindex $argv 0]]
# Reserve a new filename before SQLite opens it.
close [open $path {WRONLY CREAT EXCL}]
sqlite3 sample $path -create 0
try {
    sample transaction {
        sample eval {
            CREATE TABLE observations(entity TEXT NOT NULL, starts INTEGER NOT NULL,
                                      ends INTEGER NOT NULL, note TEXT, CHECK(starts < ends));
            CREATE INDEX observation_start ON observations(entity, starts);
            INSERT INTO observations VALUES
                ('007', 10, 20, NULL),
                ('007', 20, 30, ''),
                ('007', 30, 40, 'ready'),
                ('007', 33, 35, 'also active');
        }
    }
} finally {sample close}
