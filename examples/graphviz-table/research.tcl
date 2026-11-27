namespace eval ::research {
    variable snapshot {}
    variable input {2026-11-01T09:15:00Z}
    variable status {}
    variable details {}
}

proc ::research::createSample {path} {
    package require sqlite3
    close [open $path {WRONLY CREAT EXCL}]
    sqlite3 db $path -create 0
    try {
        db eval {PRAGMA foreign_keys = ON}
        db transaction {
            db eval {
                CREATE TABLE source (
                    source_id TEXT PRIMARY KEY, name TEXT NOT NULL
                ) STRICT;
                CREATE TABLE occurrence (
                    occurrence_id TEXT PRIMARY KEY CHECK (occurrence_id <> ''),
                    asset TEXT NOT NULL, observation TEXT NOT NULL,
                    source_id TEXT NOT NULL REFERENCES source(source_id),
                    reference TEXT NOT NULL, starts TEXT NOT NULL, ends TEXT NOT NULL,
                    CHECK (starts < ends)
                ) STRICT;
                CREATE INDEX occurrence_start ON occurrence(starts);
                INSERT INTO source VALUES ('desk', 'Desk ledger'), ('field', 'Field inspection');
                INSERT INTO occurrence VALUES
                    ('007-A', 'Bay 07', 'Open', 'desk', 'Sheet 4, row 7',
                     '2026-11-01T08:00:00.000000000Z', '2026-11-01T10:00:00.000000000Z'),
                    ('007-B', 'Bay 07', 'Open', 'field', 'Card 12',
                     '2026-11-01T09:00:00.000000000Z', '2026-11-01T09:30:00.000000000Z'),
                    ('009-A', 'Café & stores', 'Checked', 'field', 'Card 13',
                     '2026-11-01T09:30:00.000000000Z', '2026-11-01T10:00:00.000000000Z');
            }
        }
    } finally {db close}
}

proc ::research::unwrap {result} {
    lassign $result tag value
    if {$tag eq "err"} {
        return -code error -errorcode [list RESEARCH [dict getdef $value code FAILURE]] [dict get $value message]
    }
    return $value
}

# Arbitrary source text stays out of DOT identifiers and Tk tag expressions.
proc ::research::nodeId {kind key} {
    return ${kind}_[binary encode hex [encoding convertto utf-8 $key]]
}
proc ::research::html {value} {
    string map [list & {&amp;} < {&lt;} > {&gt;} {"} {&quot;}] $value
}

proc ::research::diagram {rows} {
    set lines [list {graph [rankdir=LR, splines=ortho, nodesep=0.35, ranksep=0.8]} {node [shape=plain]}]
    set sources {}
    set occurrences {}
    foreach row $rows {
        set key [dict get $row occurrence_id]
        set source [dict get $row source_id]
        set from [nodeId source $source]
        set to [nodeId occurrence $key]
        if {![dict exists $sources $source]} {
            dict set sources $source 1
            lappend lines [format {%s [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="6"><TR><TD PORT="log" BGCOLOR="#efdfa9">%s</TD></TR></TABLE>>]} \
                $from [html [dict get $row source_name]]]
        }
        dict set occurrences $to $key
        lappend lines [format {%s [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5"><TR><TD PORT="entry" BGCOLOR="#c5e5df">%s</TD></TR><TR><TD>%s</TD></TR></TABLE>>]} \
            $to [html [dict get $row asset]] [html [dict get $row observation]]]
        lappend lines [format {%s:log -> %s:entry} $from $to]
    }
    set graph [::machteld::graphviz layout "digraph Research {\n[join $lines \n]\n}"]
    return [list $graph $occurrences]
}

# A failed parse, database read or layout leaves the displayed snapshot intact.
proc ::research::refresh {database instant} {
    variable snapshot
    set at [unwrap [::application::timeline::at $instant]]
    set rows [unwrap [::application::timeline::occurrences $database $at]]
    set visible {}
    foreach row $rows {dict set visible [dict get $row occurrence_id] $row}
    lassign [diagram $rows] graph occurrenceNodes
    set selected [dict getdef $snapshot selected {}]
    if {![dict exists $visible $selected]} {set selected {}}
    set snapshot [dict create at $at visible $visible graph $graph occurrenceNodes $occurrenceNodes selected $selected]
}

proc ::research::pick {key} {
    variable snapshot
    if {![dict exists $snapshot visible $key]} {set key {}}
    dict set snapshot selected $key
}

proc ::research::report {} {
    variable snapshot
    set selected [dict get $snapshot selected]
    dict create at [dict get $snapshot at] visible [dict keys [dict get $snapshot visible]] \
        selected $selected observation [dict getdef $snapshot visible $selected {}]
}

proc ::research::selection {canvas} {
    variable snapshot
    variable details
    set key [dict get $snapshot selected]
    if {$key eq {}} {
        ::diagram::highlight $canvas {}
        set details {}
        return
    }
    ::diagram::highlight $canvas [nodeId occurrence $key]
    set row [dict get $snapshot visible $key]
    set details [format "%s  ·  %s  ·  %s\n%s to %s (end exclusive)" $key \
        [dict get $row source_name] [dict get $row reference] [dict get $row starts] [dict get $row ends]]
}
proc ::research::click {canvas} {
    variable snapshot
    pick [dict getdef $snapshot occurrenceNodes [::diagram::hitNode $canvas] {}]
    selection $canvas
}
proc ::research::apply {database canvas} {
    variable input
    variable snapshot
    variable status
    if {[catch {refresh $database $input} message]} {
        set status "Could not apply the time. $message"
        return
    }
    set graph [dict get $snapshot graph]
    $canvas delete all
    ::diagram::paint $canvas $graph
    lassign [dict get $graph size] width height
    $canvas configure -scrollregion [list -4 -4 [expr {ceil($width)+4}] [expr {ceil($height)+4}]]
    selection $canvas
    set count [dict size [dict get $snapshot visible]]
    set status [format {%s  ·  %d %s} [dict get $snapshot at] $count [expr {$count == 1 ? "occurrence" : "occurrences"}]]
}
