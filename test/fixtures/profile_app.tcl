package require -exact machteld 30
package require machteld::sqlite 1.0

# This Tcl-only application is packed with a schema version and its own
# migration SQL. All persistent paths and records come from the test driver.
fconfigure stdout -encoding utf-8 -translation lf
set root [file dirname [info script]]
proc asset {name} {
    set f [open [file join $::root $name] r]
    try {return [string trim [read $f]]} finally {close $f}
}
proc appError {code message} {
    return -code error -errorcode [list PROFILE_APP $code] $message
}
proc checkProfile {db maximum} {
    if {[$db onecolumn {PRAGMA application_id}] != 12812} {appError FOREIGN {different application profile}}
    set version [$db onecolumn {PRAGMA user_version}]
    if {$version > $maximum} {appError NEWER {profile needs a newer application}}
    return $version
}
proc main {op path args} {
    set generation [asset version.txt]
    set lock [::machteld::lock try "$path.lock"]
    if {$lock eq {}} {appError BUSY {profile already in use}}
    try {
        if {$op eq "restore"} {
            sqlite3 ::snapshot [lindex $args 0] -readonly 1 -create 0
            try {
                checkProfile ::snapshot $generation
                ::machteld::sqlite::backup ::snapshot $path
            } finally {::snapshot close}
            return restored
        }
        sqlite3 ::db $path -create [expr {$op eq "seed"}] -readonly [expr {$op eq "read"}] -foreignkeys 1 -defensive 1
        try {
            if {$op eq "seed"} {
                if {[db onecolumn {PRAGMA application_id}] != 0 || [db onecolumn {SELECT count(*) FROM sqlite_schema}] != 0} {
                    appError EXISTS {target already initialized}
                }
                db eval {PRAGMA journal_mode=WAL}
                db transaction immediate {
                    db eval {CREATE TABLE sample(id INTEGER PRIMARY KEY, label TEXT NOT NULL, payload BLOB NOT NULL);
                             PRAGMA application_id=12812; PRAGMA user_version=1}
                    set values [dict create 1 [list text [lindex $args 0]] 2 [list blob [binary decode hex [lindex $args 1]]]]
                    db eval -parameters $values {INSERT INTO sample VALUES(1,?1,?2)}
                }
                return seeded
            }
            set version [checkProfile ::db $generation]
            switch -- $op {
                read {
                    set report [dict create version $version row [db eval {SELECT label,hex(payload) FROM sample ORDER BY id}]]
                    if {$version == 2} {dict set report tags [db eval {SELECT tag FROM sample_tag ORDER BY id}]}
                    return $report
                }
                upgrade {
                    if {$version == $generation} {return current}
                    ::machteld::sqlite::backup ::db [lindex $args 0]
                    db transaction immediate {
                        db eval [asset migration.sql]
                        db eval {PRAGMA user_version=2}
                    }
                    return upgraded
                }
                default {appError USAGE {unknown operation}}
            }
        } finally {db close}
    } finally {::machteld::lock release $lock}
}
if {[catch {main {*}$argv} result options]} {
    puts [dict create ok 0 code [dict get $options -errorcode] message $result]
    exit 20
}
puts [dict create ok 1 value $result]
