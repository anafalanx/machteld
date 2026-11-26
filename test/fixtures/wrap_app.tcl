package require machteld

# Installed by wrap_test.tcl as a nested application entry.
switch -- [lindex $argv 0] {
    --worker {
        worker on echo {value} {return $value}
        worker serve
    }
    --probe {
        set f [open [file join [file dirname [info script]] payload.bin] rb]
        try {set asset [binary encode hex [read $f]]} finally {close $f}
        set sql [package require sqlite3]
        sqlite3 db :memory:
        try {
            db eval {CREATE VIRTUAL TABLE docs USING fts5(text, tokenize='trigram')}
            db eval {INSERT INTO docs VALUES('Machteld')}
            set matches [db onecolumn {SELECT count(*) FROM docs WHERE docs MATCH 'cht'}]
        } finally {db close}
        if {![catch {docs status} message opts]} {error "wrapped app unexpectedly carries the reference"}
        set docCode [dict get $opts -errorcode]
        set launch [app launch]
        set pool [pool create -width 1 -timeout 30s -- {*}$launch --worker]
        try {
            set value {a reply with spaces}
            pool submit $pool [list [dict create op echo value $value]]
            set reply [lindex [pool wait $pool -timeout 30s] 0]
            if {![dict get $reply ok]} {error "wrapped worker failed: $reply"}
        } finally {pool close $pool}
        fconfigure stdout -translation lf -encoding utf-8
        puts [dict create asset $asset doc_code $docCode matches $matches sqlite $sql \
            reply [dict get $reply result] launch $launch argv0 $argv0 script [info script]]
    }
    --exit {exit 37}
    default {
        fconfigure stdout -translation lf -encoding utf-8
        puts [list $argc $argv]
    }
}
