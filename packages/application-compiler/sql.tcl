# Installed in the generated application's @rt namespace. A read owns its
# connection and one database snapshot, including statement inspection.
proc sqlFail {code message} {
    return -code error -errorcode [list APPCOMPILER SQL $code] $message
}

proc sqlAuthorizeRead {action first second database context} {
    switch -- $action {
        SQLITE_SELECT - SQLITE_READ - SQLITE_RECURSIVE {return SQLITE_OK}
        SQLITE_FUNCTION {
            if {[string tolower $second] ni {load_extension sqlite_log}} {return SQLITE_OK}
        }
        SQLITE_PRAGMA {
            # FTS5 consults this read-only counter when it opens an index.
            if {$first eq "data_version" && $second eq ""} {return SQLITE_OK}
            if {$first in {table_info table_xinfo table_list index_list index_info index_xinfo foreign_key_list}} {
                return SQLITE_OK
            }
        }
    }
    return SQLITE_DENY
}

proc sqlBinding {type value slot} {
    if {[string index $type end] eq "?"} {
        if {[lindex $value 0] eq "none"} {return [list null]}
        set value [lindex $value 1]
        set type [string range $type 0 end-1]
    }
    switch -- [scalarBase $type] {
        int {
            if {$value < -9223372036854775808 || $value > 9223372036854775807} {
                sqlFail SQL_BIND "parameter $slot is outside the SQLite signed 64-bit integer range"
            }
            return [list integer $value]
        }
        bool {return [list integer [expr {$value ? 1 : 0}]]}
        text - decimal {return [list text $value]}
        bytes {return [list blob $value]}
    }
    sqlFail SQL_BIND "parameter $slot has unsupported type $type"
}

proc sqlCell {type cell column} {
    lassign $cell storage value
    set optional [expr {[string index $type end] eq "?"}]
    if {$optional} {
        if {$storage eq "null"} {return [list none]}
        set type [string range $type 0 end-1]
    }
    switch -- [scalarBase $type] {
        int {set valid [expr {$storage eq "integer"}]}
        bool {set valid [expr {$storage eq "integer" && $value in {0 1}}]}
        text {set valid [expr {$storage eq "text"}]}
        bytes {set valid [expr {$storage eq "blob"}]}
        decimal {
            set valid [expr {$storage in {text integer} && ![catch {decimal::canonical $value} value]}]
        }
        default {set valid 0}
    }
    if {!$valid} {sqlFail SQL_TYPE "column [list $column] requires $type, got SQLite $storage"}
    if {$optional} {return [list some $value]}
    return $value
}

proc sqlReadRows {db cardinality rowType sql bindTypes bindValues} {
    set statement [$db inspect $sql]
    if {![dict get $statement statement] || ![dict get $statement readonly]} {
        sqlFail SQL_QUERY "expected one read-only SQLite statement"
    }
    set tail [dict get $statement tail]
    if {$tail ne "" && [dict get [$db inspect $tail] statement]} {
        sqlFail SQL_QUERY "expected one read-only SQLite statement"
    }
    set parameters [dict get $statement parameters]
    if {[llength $parameters] != [llength $bindValues]} {
        sqlFail SQL_BIND "statement has [llength $parameters] parameter slots, got [llength $bindValues] values"
    }
    set bindings {}
    set slot 0
    foreach name $parameters type $bindTypes value $bindValues {
        incr slot
        if {$name ne "" && [string index $name 0] ne "?"} {
            sqlFail SQL_BIND "expected a positional parameter at slot $slot, got [list $name]"
        }
        dict set bindings $slot [sqlBinding $type $value $slot]
    }
    set fields [lindex [dict get [schemas] $rowType] 1]
    set columns [dict get $statement columns]
    if {![llength $columns]} {sqlFail SQL_QUERY "the read statement must return columns"}
    if {[lsort -ascii $columns] ne [lsort -ascii [dict keys $fields]]} {
        sqlFail SQL_COLUMNS "expected columns [list [dict keys $fields]] for $rowType, got [list $columns]"
    }

    set rows {}
    $db eval -typed -asdict -parameters $bindings $sql cells {
        if {$cardinality ne "many" && [llength $rows]} {
            sqlFail CARDINALITY "expected at most one row, got at least two"
        }
        set row {}
        dict for {field type} $fields {
            dict set row $field [sqlCell $type [dict get $cells $field] $field]
        }
        lappend rows $row
    }
    switch -- $cardinality {
        many {return $rows}
        optional {
            if {![llength $rows]} {return [list none]}
            return [list some [lindex $rows 0]]
        }
        one {
            if {![llength $rows]} {sqlFail CARDINALITY "expected exactly one row, got zero"}
            return [lindex $rows 0]
        }
        default {error "unknown SQL cardinality $cardinality"}
    }
}

proc sqlRead {cardinality rowType path sql bindTypes bindValues} {
    if {[catch {package require sqlite3}]} {
        return [list err [dict create code SQL_UNAVAILABLE message "this host does not provide SQLite"]]
    }
    variable sqlReadSerial
    set db [namespace current]::sqlConnection[incr sqlReadSerial]
    while {[llength [info commands $db]]} {set db [namespace current]::sqlConnection[incr sqlReadSerial]}
    set opened 0
    set stage SQL_OPEN
    try {
        if {$path eq "" || [string first \u0000 $path] >= 0 || ![file isfile $path]
            || [lindex [file system $path] 0] ne "native"} {
            sqlFail SQL_OPEN "expected an existing database file, got [list $path]"
        }
        ::sqlite3 $db [file normalize $path] -readonly 1 -create 0
        set opened 1
        if {[catch {$db inspect {}}] || [catch {$db config defensive 1} defensive] || !$defensive} {
            sqlFail SQL_UNAVAILABLE "this host lacks the SQLite APIs required for typed SQL reads"
        }
        set stage SQL_QUERY
        # Pin the read snapshot before inspecting columns and stepping the
        # statement so concurrent schema changes cannot alter its result shape.
        $db eval {PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN; SELECT rootpage FROM main.sqlite_schema LIMIT 1}
        $db authorizer [namespace current]::sqlAuthorizeRead
        set value [sqlReadRows $db $cardinality $rowType $sql $bindTypes $bindValues]
        return [list ok $value]
    } trap {APPCOMPILER SQL} {message options} {
        return [list err [dict create code [lindex [dict get $options -errorcode] 2] message $message]]
    } trap {MACHTELD SQLITE parameter} {message options} {
        return [list err [dict create code SQL_BIND message $message]]
    } trap {MACHTELD SQLITE text} {message options} {
        return [list err [dict create code SQL_TYPE message $message]]
    } on error {message options} {
        return [list err [dict create code $stage message $message]]
    } finally {
        if {$opened} {$db close}
    }
}
