# Installed in the generated application's @rt namespace. A path read owns
# one snapshot. A write scope owns one connection until commit or cleanup.
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

proc sqlAuthorizeWrite {action first second database context} {
    if {$action in {SQLITE_INSERT SQLITE_UPDATE SQLITE_DELETE}} {return SQLITE_OK}
    return [sqlAuthorizeRead $action $first $second $database $context]
}

# SQLite reports operations during prepare, including calls from trigger
# bodies, foreign keys and virtual table modules. Record what the outer
# statement requests. Keep the restrictions in effect through sqlite3_step.
proc sqlAuthorizeChange {db mode action first second database context} {
    variable sqlKinds
    if {$mode eq "schema"} {
        switch -- $action {
            SQLITE_INSERT {
                # An existing virtual table can make IF NOT EXISTS report
                # only this catalog check, with no CREATE_VTABLE callback.
                # The connection uses SQLite's defensive mode.
                if {$context eq "" && $first in {sqlite_master sqlite_temp_master}} {return SQLITE_OK}
            }
            SQLITE_ALTER_TABLE {
                dict set sqlKinds($db) schema 1
                dict set sqlKinds($db) alter [list $first $second]
                return SQLITE_OK
            }
            SQLITE_PRAGMA {
                # When adding a constrained column SQLite checks existing
                # rows by running quick_check on this table during step.
                if {$first eq "quick_check" && [dict exists $sqlKinds($db) alter] &&
                    [dict get $sqlKinds($db) alter] eq [list $database $second]} {
                    return SQLITE_OK
                }
            }
            SQLITE_CREATE_VTABLE - SQLITE_DROP_VTABLE {
                if {![string equal -nocase $second fts5]} {return SQLITE_DENY}
                dict set sqlKinds($db) schema 1
                return SQLITE_OK
            }
            SQLITE_CREATE_TABLE - SQLITE_CREATE_INDEX - SQLITE_CREATE_VIEW - SQLITE_CREATE_TRIGGER -
            SQLITE_CREATE_TEMP_TABLE - SQLITE_CREATE_TEMP_INDEX - SQLITE_CREATE_TEMP_VIEW - SQLITE_CREATE_TEMP_TRIGGER -
            SQLITE_DROP_TABLE - SQLITE_DROP_INDEX - SQLITE_DROP_VIEW - SQLITE_DROP_TRIGGER -
            SQLITE_DROP_TEMP_TABLE - SQLITE_DROP_TEMP_INDEX - SQLITE_DROP_TEMP_VIEW - SQLITE_DROP_TEMP_TRIGGER -
            SQLITE_REINDEX - SQLITE_ANALYZE {
                dict set sqlKinds($db) schema 1
                return SQLITE_OK
            }
        }
    }
    if {$context eq "" && $action in {SQLITE_INSERT SQLITE_UPDATE SQLITE_DELETE}} {
        dict set sqlKinds($db) dml 1
    } elseif {$mode eq "schema"} {
        dict set sqlKinds($db) other 1
    }
    return [sqlAuthorizeWrite $action $first $second $database $context]
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
        binary64 {return [list real $value]}
        text - decimal - instant - local_datetime {return [list text $value]}
        bytes {return [list blob $value]}
    }
    sqlFail SQL_BIND "parameter $slot has unsupported type $type"
}

proc sqlCell {type base optional cell column} {
    lassign $cell storage value
    if {$optional && $storage eq "null"} {return [list none]}
    switch -- $base {
        int {set valid [expr {$storage eq "integer"}]}
        bool {set valid [expr {$storage eq "integer" && $value in {0 1}}]}
        text {set valid [expr {$storage eq "text"}]}
        bytes {set valid [expr {$storage eq "blob"}]}
        binary64 {
            set valid [expr {$storage eq "real"}]
            if {$valid} {
                # Typed SQLite REAL cells carry a Tcl_NewDoubleObj. Inspect the
                # binary value so a floating-point mode cannot flush a subnormal.
                binary scan [binary format Q $value] W bits
                set magnitude [expr {$bits & 0x7fffffffffffffff}]
                if {$magnitude >= 0x7ff0000000000000} {
                    sqlFail SQL_TYPE "column [list $column] requires a finite REAL"
                }
                if {$magnitude == 0} {set value 0.0}
            }
        }
        decimal {
            set valid [expr {$storage in {text integer} && ![catch {decimal::canonical $value} value]}]
        }
        instant - local_datetime {
            set valid [expr {$storage eq "text"}]
            if {$valid && [catch {temporalCanonical $base $value}]} {
                sqlFail SQL_TYPE "column [list $column] requires canonical $base text"
            }
        }
        default {set valid 0}
    }
    if {!$valid} {sqlFail SQL_TYPE "column [list $column] requires $type, got SQLite $storage"}
    if {$optional} {return [list some $value]}
    return $value
}

proc sqlStatement {db sql} {
    set statement [$db inspect $sql]
    set tail [dict get $statement tail]
    if {![dict get $statement statement] || ($tail ne "" && [dict get [$db inspect $tail] statement])} {
        sqlFail SQL_QUERY "expected one SQLite statement"
    }
    return $statement
}

proc sqlBindings {statement bindTypes bindValues} {
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
    return $bindings
}

proc sqlReadRows {db cardinality rowType sql bindTypes bindValues} {
    set statement [sqlStatement $db $sql]
    if {![dict get $statement readonly]} {sqlFail SQL_QUERY "expected one read-only SQLite statement"}
    return [sqlRows $db $cardinality $rowType $sql $statement $bindTypes $bindValues]
}

# Keep the per-field loop in a procedure. SQLite evaluates its row callback
# as a script, while this procedure can use compiled local variable slots.
proc sqlDecodeRow {decoders cells} {
    set row {}
    foreach {field type base optional} $decoders {
        dict set row $field [sqlCell $type $base $optional [dict get $cells $field] $field]
    }
    return $row
}

proc sqlRows {db cardinality rowType sql statement bindTypes bindValues} {
    set bindings [sqlBindings $statement $bindTypes $bindValues]
    set fields [lindex [specializeSchema $rowType [schemas]] 1]
    set columns [dict get $statement columns]
    if {![llength $columns]} {sqlFail SQL_QUERY "the statement must return columns"}
    if {[lsort -ascii $columns] ne [lsort -ascii [dict keys $fields]]} {
        sqlFail SQL_COLUMNS "expected columns [list [dict keys $fields]] for $rowType, got [list $columns]"
    }

    set decoder [dict getdef [sqlReaders] $rowType {}]
    if {$decoder eq {}} {
        # The general reader resolves field types once per statement.
        set decoders {}
        dict for {field type} $fields {
            set optional [expr {[string index $type end] eq "?"}]
            if {$optional} {set type [string range $type 0 end-1]}
            lappend decoders $field $type [scalarBase $type] $optional
        }
        set decoder [list sqlDecodeRow $decoders]
    }
    set rows {}
    $db eval -typed -asdict -parameters $bindings $sql cells {
        if {$cardinality ne "many" && [llength $rows]} {
            sqlFail CARDINALITY "expected at most one row, got at least two"
        }
        lappend rows [{*}$decoder $cells]
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

proc sqlOpen {path readonly} {
    if {[catch {package require sqlite3}]} {
        sqlFail SQL_UNAVAILABLE "this host does not provide SQLite"
    }
    variable sqlReadSerial
    set db [namespace current]::sqlConnection[incr sqlReadSerial]
    while {[llength [info commands $db]]} {set db [namespace current]::sqlConnection[incr sqlReadSerial]}
    # Unicode and filesystem operations can replace an opaque Tcl representation.
    # Keep the caller's object available after both a successful and a failed open.
    append path {}
    if {$path eq "" || [string first \u0000 $path] >= 0 || ![file isfile $path]
        || [lindex [file system $path] 0] ne "native"} {
        sqlFail SQL_OPEN "expected an existing database file, got [list $path]"
    }
    if {[catch {::sqlite3 $db [file normalize $path] -readonly $readonly -create 0} message]} {
        sqlFail SQL_OPEN $message
    }
    try {
        if {[catch {$db inspect {}}] || [catch {$db config defensive 1} defensive] || !$defensive} {
            sqlFail SQL_UNAVAILABLE "this host lacks the SQLite APIs required for typed SQL"
        }
        if {!$readonly} {
            if {[$db readonly]} {sqlFail SQL_OPEN "database opened read-only"}
            if {![$db config enable_fkey 1]} {sqlFail SQL_UNAVAILABLE "SQLite foreign key enforcement is required"}
        }
    } on error {message options} {
        $db close
        return -options $options $message
    }
    return $db
}

proc sqlErrorResult {fallback message options} {
    set errorCode [dict get $options -errorcode]
    if {[lrange $errorCode 0 1] eq {APPCOMPILER SQL}} {
        set fallback [lindex $errorCode 2]
    } elseif {[lrange $errorCode 0 2] eq {MACHTELD SQLITE parameter}} {
        set fallback SQL_BIND
    } elseif {[lrange $errorCode 0 2] eq {MACHTELD SQLITE text}} {
        set fallback SQL_TYPE
    }
    return [list err [dict create code $fallback message $message]]
}

proc sqlRead {cardinality rowType path sql bindTypes bindValues} {
    try {
        set db [sqlOpen $path 1]
        # Pin the read snapshot before inspecting columns and stepping the
        # statement so concurrent schema changes cannot alter its result shape.
        $db eval {PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN; SELECT rootpage FROM main.sqlite_schema LIMIT 1}
        $db authorizer [namespace current]::sqlAuthorizeRead
        set value [sqlReadRows $db $cardinality $rowType $sql $bindTypes $bindValues]
        return [list ok $value]
    } on error {message options} {
        return [sqlErrorResult SQL_QUERY $message $options]
    } finally {
        if {[info exists db]} {$db close}
    }
}

proc sqlBegin {path} {
    variable sqlTransactions
    try {
        set db [sqlOpen $path 0]
        $db eval {PRAGMA trusted_schema=OFF; BEGIN IMMEDIATE}
        # SQLite can roll back a whole transaction itself, for example on I/O
        # errors. Never let a later operation on that handle run in autocommit.
        $db rollback_hook [list ::set [namespace current]::sqlTransactions($db) 0]
        set sqlTransactions($db) 1
        return [list ok $db]
    } on error {message options} {
        if {[info exists db]} {$db close}
        return [sqlErrorResult SQL_BEGIN $message $options]
    }
}

proc sqlRequireTransaction {db authorizer} {
    variable sqlTransactions
    if {![info exists sqlTransactions($db)] || !$sqlTransactions($db)} {
        sqlFail SQL_TX_CLOSED "the SQLite transaction is closed"
    }
    # Reinstalling the same callback expires SQLite's cached statements.
    if {[$db authorizer] ne $authorizer} {$db authorizer $authorizer}
}

proc sqlEnd {db} {
    variable sqlTransactions
    if {[info exists sqlTransactions($db)]} {
        # Closing a SQLite connection rolls back any uncommitted transaction.
        # Cleanup also runs after a successful commit and must be idempotent.
        catch {$db close}
        unset sqlTransactions($db)
    }
}

proc sqlCommit {db} {
    try {
        sqlRequireTransaction $db {}
        $db eval COMMIT
        return [list ok {}]
    } on error {message options} {
        return [sqlErrorResult SQL_COMMIT $message $options]
    } finally {
        sqlEnd $db
    }
}

proc sqlExec {db sql bindTypes bindValues} {
    try {
        sqlRequireTransaction $db [namespace current]::sqlAuthorizeWrite
        set statement [sqlStatement $db $sql]
        if {[dict get $statement readonly] || [llength [dict get $statement columns]]} {
            sqlFail SQL_QUERY "expected one INSERT, UPDATE or DELETE without returned columns"
        }
        set bindings [sqlBindings $statement $bindTypes $bindValues]
        $db eval -parameters $bindings $sql
        return [list ok {}]
    } on error {message options} {
        # OR FAIL can leave earlier rows of this statement changed. Closing
        # here prevents an explicitly handled error from committing a prefix.
        sqlEnd $db
        return [sqlErrorResult SQL_QUERY $message $options]
    }
}

proc sqlTxRead {cardinality rowType db sql bindTypes bindValues} {
    try {
        sqlRequireTransaction $db [namespace current]::sqlAuthorizeRead
        return [list ok [sqlReadRows $db $cardinality $rowType $sql $bindTypes $bindValues]]
    } on error {message options} {
        return [sqlErrorResult SQL_QUERY $message $options]
    }
}

proc sqlSchema {db sql bindTypes bindValues} {
    variable sqlKinds
    try {
        sqlRequireTransaction $db [list [namespace current]::sqlAuthorizeChange $db schema]
        set sqlKinds($db) {}
        set statement [sqlStatement $db $sql]
        # IF [NOT] EXISTS can authorize nothing, and SQLite reports a no-op
        # DROP TRIGGER as read-only. Keep the authorizer active when stepping:
        # VACUUM also defers work and cannot run in our transaction.
        # ALTER ADD COLUMN can expose SQLite's internal constraint-check
        # expression as column metadata. The schema operation owns that work.
        set kinds $sqlKinds($db)
        if {[dict get $statement explain] ||
            ([llength [dict get $statement columns]] && ![dict exists $kinds alter]) ||
            ([dict size $kinds] && ![dict exists $kinds schema])} {
            sqlFail SQL_QUERY "expected one transactional SQLite schema statement"
        }
        $db eval -parameters [sqlBindings $statement $bindTypes $bindValues] $sql
        return [list ok {}]
    } on error {message options} {
        sqlEnd $db
        return [sqlErrorResult SQL_QUERY $message $options]
    } finally {
        unset -nocomplain sqlKinds($db)
    }
}

proc sqlReturning {cardinality rowType db sql bindTypes bindValues} {
    variable sqlKinds
    try {
        sqlRequireTransaction $db [list [namespace current]::sqlAuthorizeChange $db returning]
        set sqlKinds($db) {}
        set statement [sqlStatement $db $sql]
        if {[dict get $statement readonly] || [dict get $statement explain] || ![dict exists $sqlKinds($db) dml]} {
            sqlFail SQL_QUERY "expected one INSERT, UPDATE or DELETE with RETURNING"
        }
        return [list ok [sqlRows $db $cardinality $rowType $sql $statement $bindTypes $bindValues]]
    } on error {message options} {
        # SQLite performs all RETURNING writes before delivering the first row.
        # A row decode or cardinality error must roll back their trigger effects too.
        sqlEnd $db
        return [sqlErrorResult SQL_QUERY $message $options]
    } finally {
        unset -nocomplain sqlKinds($db)
    }
}
