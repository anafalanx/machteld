namespace eval ::lookup {
    variable pageSize 50
    variable categories {All Parts Tools Kits Supplies}
}

proc ::lookup::workerCommand {entry} {
    set cmd [list [info nameofexecutable]]
    if {[lindex [file system $entry] 0] ne "zipfs"} { lappend cmd [file normalize $entry] }
    return [linsert $cmd end --worker]
}

# The UI owns the empty temporary file or the CLI has just reserved a new one.
proc ::lookup::seed {path} {
    package require sqlite3
    sqlite3 ::lookup::database $path
    try {
        database transaction {
            database eval {
                CREATE TABLE items(id INTEGER PRIMARY KEY, category TEXT NOT NULL, name TEXT NOT NULL);
                WITH RECURSIVE ids(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM ids WHERE id<125000)
                INSERT INTO items SELECT id,
                    CASE (id-1)%4 WHEN 0 THEN 'Parts' WHEN 1 THEN 'Tools'
                                  WHEN 2 THEN 'Kits' ELSE 'Supplies' END,
                    printf('Catalogue item %06d',id)
                FROM ids;
                CREATE INDEX items_by_category ON items(category, id);
            }
        }
    } finally { database close }
}

proc ::lookup::createDemo {path} {
    if {[file exists $path]} { error "File already exists: $path" }
    set channel [file tempfile staging [file join [file dirname [file normalize $path]] .catalogue.tmp]]
    ::close $channel
    try {
        seed $staging
        file rename $staging $path
    } finally { file delete -force $staging }
}

proc ::lookup::send {record} { puts [::machteld::json encode -dict $record] }

proc ::lookup::page {path category cursor} {
    variable pageSize
    variable categories
    if {$category ni $categories} { error "Unknown category: $category" }
    if {![string is wideinteger -strict $cursor] || $cursor < 0} { error "Invalid page cursor" }
    package require sqlite3
    sqlite3 ::lookup::database $path -readonly 1
    try {
        database timeout 5000
        send [dict create type opened]
        set sql {SELECT id, substr(category, 1, 32) AS category, substr(name, 1, 160) AS name
                 FROM items WHERE id > $cursor}
        if {$category ne "All"} { append sql { AND items.category = $category} }
        append sql { ORDER BY id LIMIT $limit}
        set limit [expr {$pageSize + 1}]
        set count 0
        set more 0
        database eval $sql row {
            if {$count == $pageSize} {
                set more 1
                break
            }
            send [dict create type row id $row(id) \
                category [::machteld::json value string $row(category)] \
                name [::machteld::json value string $row(name)]]
            incr count
        }
        send [dict create type end more $more]
    } finally { database close }
}

proc ::lookup::main {entry arguments} {
    set role [lindex $arguments 0]
    if {$role in {--worker --create-demo}} {
        # A wrapped GUI host initializes Tk before it sources its own entry.
        if {[llength [info commands ::destroy]]} { ::destroy . }
        fconfigure stdout -translation lf -encoding utf-8 -buffering line
        fconfigure stderr -translation lf -encoding utf-8 -buffering line
        try {
            if {$role eq "--create-demo" && [llength $arguments] == 2} {
                createDemo [lindex $arguments 1]
            } elseif {[lrange $arguments 0 1] eq {--worker page} && [llength $arguments] == 5} {
                page {*}[lrange $arguments 2 end]
            } elseif {[lrange $arguments 0 1] eq {--worker seed} && [llength $arguments] == 3} {
                set path [lindex $arguments 2]
                if {![file isfile $path] || [file size $path] != 0} { error "Expected an empty demo file" }
                seed $path
            } else {
                error "Expected --create-demo FILE or an internal worker request"
            }
        } on error {message options} {
            puts stderr $message
            exit 1
        }
        exit 0
    }
    if {[llength $arguments] > 1} { error "Usage: Catalogue Lookup ?DATABASE?" }
    package require Tk
    source -encoding utf-8 [file join [file dirname $entry] view.tcl]
    ::lookup::open [lindex $arguments 0] [workerCommand $entry]
    tkwait window .
}
