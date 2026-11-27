package require machteld
package require sqlite3

if {[llength $argv] != 1} {error "usage: [file tail [info script]] NEW_DATABASE"}
set path [file normalize [lindex $argv 0]]
close [open $path {WRONLY CREAT EXCL}]
sqlite3 sample $path -create 0
try {
    sample transaction {
        sample eval {
            CREATE TABLE claims(
                source TEXT NOT NULL CHECK(source <> ''),
                id TEXT NOT NULL CHECK(id <> ''),
                entity TEXT NOT NULL CHECK(entity <> ''),
                field TEXT NOT NULL CHECK(field <> ''),
                starts INTEGER NOT NULL,
                ends INTEGER NOT NULL CONSTRAINT starts_must_precede_ends CHECK(starts < ends),
                value TEXT NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(source, id)
            ) STRICT;
            CREATE INDEX claims_at ON claims(entity, starts);
        }
    }
} finally {sample close}
