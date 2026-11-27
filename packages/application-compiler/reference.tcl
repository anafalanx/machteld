namespace eval ::appcompiler::reference {variable serial 0}

proc ::appcompiler::reference::signature {decl} {
    set kind [dict get $decl kind]
    set head "export $kind .[dict get $decl name]"
    if {$kind eq "extern"} {set head "export extern fn .[dict get $decl name]"}
    if {[llength [dict getdef $decl typeParams {}]]} {
        set parameters [lmap name [dict get $decl typeParams] {format ".%s" $name}]
        append head < [join $parameters {, }] >
    }
    switch -- $kind {
        tool {
            set path [string map [list \\ {\\} \" {\"}] [dict get $decl path]]
            return "$head = \"$path\""
        }
        fn - extern - worker {
            set params [lmap param [dict get $decl params] {
                set signature [format {$%s: %s} [dict get $param name] [dict get $param type]]
                if {[dict exists $param label]} {set signature "[dict get $param label] $signature"}
                set signature
            }]
            return "${head}([join $params {, }]) -> [dict get $decl result]"
        }
        alias - distinct {return "$head = [dict get $decl target]"}
        record {
            set members [lmap field [dict get $decl fields] {
                format {    %s: %s} [dict get $field name] [dict get $field type]
            }]
        }
        choice {
            set members [lmap variant [dict get $decl variants] {
                set member "    [dict get $variant name]"
                set payload [dict get $variant payload]
                if {[llength $payload]} {append member ( [join $payload {, }] )}
                set member
            }]
        }
    }
    return "$head \{\n[join $members \n]\n\}"
}

proc ::appcompiler::reference::codeBlock {source} {
    set width 3
    foreach run [regexp -all -inline {~+} $source] {
        set width [expr {max($width, 1 + [string length $run])}]
    }
    set fence [string repeat ~ $width]
    return "${fence}text\n$source\n$fence"
}

proc ::appcompiler::reference::connection {} {
    variable serial
    if {[catch {package require sqlite3}]} {
        error "application references require a Machteld host with SQLite and FTS5"
    }
    set db [namespace current]::db[incr serial]
    ::sqlite3 $db :memory: -defensive 1
    return $db
}

proc ::appcompiler::reference::build {modules} {
    set db [connection]
    try {
        $db eval {
            PRAGMA page_size=1024;
            PRAGMA application_id=0x41505246;
            PRAGMA user_version=1;
            CREATE TABLE page(id TEXT NOT NULL UNIQUE, body TEXT NOT NULL, has_nul INTEGER NOT NULL);
            CREATE VIRTUAL TABLE search USING fts5(id,body,content='page',tokenize='unicode61');
        }
        $db transaction {
            foreach module [lsort -ascii [dict keys $modules]] {
                set definition [dict get $modules $module]
                set examples {}
                set closers {}
                foreach resource [dict getdef $definition resources {}] {
                    dict set closers [dict get $resource name] [dict get $resource closer]
                }
                foreach item [dict get $definition examples] {
                    dict lappend examples [dict get $item owner] [dict get $item source]
                }
                foreach {key category} {types type functions fn} {
                    foreach decl [dict get $definition $key] {
                        if {![dict get $decl exported]} {continue}
                        set name [dict get $decl name]
                        set id "$category/$module/$name"
                        set body "# .$module\::$name\n\n[codeBlock [signature $decl]]\n"
                        if {$category eq "type" && [dict exists $closers $name]} {
                            append body "\n[codeBlock [format {resource .%s using .%s} $name [dict get $closers $name]]]\n"
                        }
                        if {[dict exists $decl doc]} {append body \n [dict get $decl doc] \n}
                        if {$category eq "fn" && [dict exists $examples $name]} {
                            append body "\n## Examples\n"
                            foreach source [dict get $examples $name] {append body \n [codeBlock $source] \n}
                        }
                        set hasNul [expr {[string first \u0000 $body] >= 0}]
                        $db eval {INSERT INTO page(id,body,has_nul) VALUES($id,$body,$hasNul)}
                    }
                }
            }
            $db eval {
                INSERT INTO search(search) VALUES('rebuild');
                INSERT INTO search(search,rank) VALUES('integrity-check',1);
            }
        }
        return [$db serialize]
    } finally {$db close}
}

# The host verifies the archive. Only its data member is read.
proc ::appcompiler::reference::readArchive {archive} {
    if {![llength [info commands ::machteld::ArchiveEntry]]} {
        error "reading application references requires a Machteld host with archive verification"
    }
    set mount [zipfs mount [file normalize $archive] "ref-[binary encode hex [::machteld::hash random 16]]"]
    try {
        ::machteld::ArchiveEntry $mount
        set path [file join $mount project reference.db]
        if {![file isfile $path]} {
            error "archive has no application reference; rebuild it with a compiler that generates project/reference.db"
        }
        set ch [open $path rb]
        try {return [read $ch]} finally {close $ch}
    } finally {zipfs unmount $mount}
}

proc ::appcompiler::reference::number {value name min max} {
    if {[string length $value] > 10 || ![regexp {^(0|[1-9][0-9]*)$} $value] ||
        $value < $min || $value > $max} {error "$name must be an integer from $min through $max"}
    return $value
}

# Use the index's own tokenizer for punctuation, combining marks and case
# folding. Treat each token as literal text, including words like AND or NOT.
proc ::appcompiler::reference::searchExpression {db value} {
    $db eval {
        CREATE VIRTUAL TABLE temp.query_input USING fts5(body,tokenize='unicode61');
        CREATE VIRTUAL TABLE temp.query_terms USING fts5vocab(temp,query_input,instance);
        INSERT INTO temp.query_input(body) VALUES($value);
    }
    set terms [$db eval {SELECT term FROM temp.query_terms ORDER BY offset LIMIT 65}]
    if {![llength $terms] || [llength $terms] > 64} {error "search requires one to 64 terms"}
    return [join [lmap term $terms {format {"%s"*} [string map [list \" \"\"] $term]}] { AND }]
}

proc ::appcompiler::reference::query {archive action value args} {
    switch -- $action {
        search {
            if {[llength $args] > 1} {error "expected search QUERY ?LIMIT?"}
            set limit 50
            if {[llength $args]} {set limit [number [lindex $args 0] limit 1 200]}
            if {$archive eq "--runtime"} {
                set result [::machteld::docs search $value -limit $limit]
                return [join [lmap row [dict get $result items] {dict get $row id}] \n]
            }
            if {[string length $value] > 4096} {error "search query exceeds 4096 characters"}
        }
        get {
            if {[llength $args] > 2} {error "expected get ID ?OFFSET? ?LIMIT?"}
            set offset 0
            set limit 32768
            if {[llength $args] >= 1} {set offset [number [lindex $args 0] offset 0 2147483647]}
            if {[llength $args] == 2} {set limit [number [lindex $args 1] limit 1 1048576]}
            if {$archive eq "--runtime"} {
                return [dict get [::machteld::docs get $value -offset $offset -limit $limit] text]
            }
        }
        default {error "expected a docs operation of search or get"}
    }
    set bytes [readArchive $archive]
    set db [connection]
    try {
        if {$action eq "search"} {set expression [searchExpression $db $value]}
        $db deserialize -readonly 1 $bytes
        unset bytes
        $db eval {PRAGMA trusted_schema=OFF; PRAGMA query_only=ON}
        if {[$db onecolumn {PRAGMA application_id}] != 0x41505246 || [$db onecolumn {PRAGMA user_version}] != 1} {
            error "unrecognized application reference format"
        }
        if {$action eq "search"} {
            return [join [$db eval {SELECT id FROM search WHERE search MATCH $expression
                                     ORDER BY bm25(search,8,1), id LIMIT $limit}] \n]
        }
        # SQLite substr stops counting at a NUL. Those rare pages need Tcl's
        # character slicing. Ordinary reads transfer only the requested slice.
        set row [$db eval {SELECT has_nul, CASE WHEN has_nul THEN body ELSE substr(body,$offset+1,$limit) END
                           FROM page WHERE id=$value}]
        if {![llength $row]} {error "unknown application reference ID [list $value]"}
        lassign $row hasNul chunk
        if {$hasNul} {return [string range $chunk $offset [expr {$offset+$limit-1}]]}
        return $chunk
    } finally {$db close}
}
