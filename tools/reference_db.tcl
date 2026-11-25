# Build-time only. The bootstrap pins the SQLite module and its FTS5 tokenizer.
# The only copy of each manual's Markdown lives in page.body. Section offsets
# and the external-content index refer back to that same text.
namespace eval ::refdb {}

proc ::refdb::readText {path} {
    set ch [open $path rb]
    try {
        return [encoding convertfrom -profile strict utf-8 [read $ch]]
    } finally {
        close $ch
    }
}

proc ::refdb::sourceNotices {source} {
    # Keep the exact bytes of every matching contiguous comment block as well
    # as its readable text. Roff comment leaders, indentation and EOLs matter
    # for an original attribution or permission grant.
    set blocks {}
    set lines {}
    set raw ""
    foreach line [concat [regexp -all -inline {[^\n]*\n|[^\n]+$} $source] [list {}]] {
        if {[regexp {^[.']?\\"(.*)$} [string trimright $line "\r\n"] -> content]} {
            lappend lines [string trimleft $content]
            append raw $line
        } elseif {[llength $lines]} {
            set text [string trim [join $lines \n]]
            if {[regexp -nocase {copyright|license|permission|redistribut|warrant|attribution|public domain|all rights reserved} $text]} {
                lappend blocks [list $text [encoding convertto -profile strict utf-8 $raw]]
            }
            set lines {}
            set raw ""
        }
    }
    return $blocks
}
proc ::refdb::build {module input root output} {
    load $module Sqlite3
    if {[file exists $output]} { error "reference database output already exists" }
    set catalog [readText $input]
    sqlite3 db $output
    try {
        db eval {
            PRAGMA page_size = 4096;
            PRAGMA application_id = 1296323122;
            PRAGMA user_version = 2;
            PRAGMA foreign_keys = ON;
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE product (name TEXT PRIMARY KEY, version TEXT NOT NULL,
                                  documents INTEGER NOT NULL, manual_pages INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE page (id TEXT NOT NULL UNIQUE, product TEXT NOT NULL REFERENCES product(name),
                               version TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                               names TEXT NOT NULL, summary TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
                               bytes INTEGER NOT NULL, characters INTEGER NOT NULL, sha256 TEXT NOT NULL,
                               body TEXT NOT NULL);
            CREATE TABLE section (id TEXT NOT NULL REFERENCES page(id), slug TEXT NOT NULL, heading TEXT NOT NULL,
                                  start INTEGER NOT NULL, end INTEGER NOT NULL CHECK(end >= start),
                                  PRIMARY KEY(id,slug)) WITHOUT ROWID;
            CREATE TABLE alias (name TEXT NOT NULL, id TEXT NOT NULL REFERENCES page(id),
                                PRIMARY KEY(name,id)) WITHOUT ROWID;
            CREATE TABLE fragment (name TEXT PRIMARY KEY, id TEXT NOT NULL, slug TEXT NOT NULL,
                                   FOREIGN KEY(id,slug) REFERENCES section(id,slug)) WITHOUT ROWID;
            CREATE TABLE notice (id TEXT PRIMARY KEY REFERENCES page(id), source TEXT NOT NULL,
                                 text TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE notice_block (id TEXT NOT NULL REFERENCES notice(id), ordinal INTEGER NOT NULL,
                                       body BLOB NOT NULL, PRIMARY KEY(id,ordinal)) WITHOUT ROWID;
            CREATE TABLE provenance (id TEXT PRIMARY KEY REFERENCES page(id), source_file TEXT NOT NULL,
                                     raw_path TEXT NOT NULL, source_sha256 TEXT NOT NULL) WITHOUT ROWID;
            CREATE VIRTUAL TABLE search USING fts5(id,title,names,summary,body,content='page',
                                                   tokenize='unicode61',prefix='2 3');
        }
        db transaction {
            foreach key {generator machteld_version} {
                set value [dict get $catalog $key]
                db eval {INSERT INTO metadata VALUES ($key,$value)}
            }
            foreach name [lsort [dict keys [dict get $catalog products]]] {
                dict with catalog products $name {
                    db eval {INSERT INTO product VALUES ($name,$version,$documents,$manual_pages)}
                }
            }
            foreach id [lsort [dict keys [dict get $catalog documents]]] {
                set rec [dict get $catalog documents $id]
                foreach field {product version title names summary} {set $field [dict get $rec $field]}
                set kind [dict get $rec type]
                set fmt [dict get $rec formats markdown]
                foreach field {path bytes characters sha256} {set $field [dict get $fmt $field]}
                set body [readText [file join $root $path]]
                if {[string length $body] != $characters} {error "Markdown length mismatch for $id"}
                db eval {INSERT INTO page VALUES ($id,$product,$version,$kind,$title,$names,$summary,
                                                  $path,$bytes,$characters,$sha256,$body)}
                foreach field {source_file raw_path source_sha256} {set $field [dict get $rec $field]}
                db eval {INSERT INTO provenance VALUES ($id,$source_file,$raw_path,$source_sha256)}
                dict for {slug offsets} [dict get $fmt sections] {
                    set heading [dict get $rec sections $slug]
                    set start [dict get $offsets start]
                    set end [dict get $offsets end]
                    if {$start < 0 || $end < $start || $end > $characters} {error "invalid section $id#$slug"}
                    db eval {INSERT INTO section VALUES ($id,$slug,$heading,$start,$end)}
                }
                if {$kind ne "license" && [dict exists $rec formats source]} {
                    set source [dict get $rec formats source path]
                    set blocks [sourceNotices [readText [file join $root $source]]]
                    if {[llength $blocks]} {
                        set text [join [lmap block $blocks {lindex $block 0}] \n\n]
                        db eval {INSERT INTO notice VALUES ($id,$source,$text)}
                        set ordinal 0
                        foreach block $blocks {
                            set raw [lindex $block 1]
                            db eval {INSERT INTO notice_block VALUES ($id,$ordinal,@raw)}
                            incr ordinal
                        }
                    }
                }
            }
            foreach name [lsort [dict keys [dict get $catalog aliases]]] {
                foreach id [lsort -unique [dict get $catalog aliases $name]] {
                    db eval {INSERT INTO alias VALUES ($name,$id)}
                }
            }
            foreach name [lsort [dict keys [dict get $catalog fragments]]] {
                set fragment [dict get $catalog fragments $name]
                set id [dict get $fragment id]
                set slug [dict get $fragment section]
                db eval {INSERT INTO fragment VALUES ($name,$id,$slug)}
            }
            db eval {INSERT INTO search(search) VALUES ('rebuild');
                     INSERT INTO search(search) VALUES ('optimize');
                     INSERT INTO search(search,rank) VALUES ('integrity-check',1)}
        }
        db eval {VACUUM}
        if {[db onecolumn {PRAGMA integrity_check}] ne "ok" || [db eval {PRAGMA foreign_key_check}] ne {}} {
            error "offline reference failed SQLite integrity checks"
        }
    } finally {
        db close
    }
}

if {[file normalize $argv0] eq [file normalize [info script]]} {
    if {[llength $argv] != 4} {error {usage: reference_db.tcl MODULE INPUT METADATA_ROOT OUTPUT}}
    ::refdb::build {*}$argv
}
