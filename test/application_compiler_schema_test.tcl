package require machteld
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

namespace eval ::schemaTest {
    variable count 0
    variable source {record .number { n: int }
fn .schema($path: text, $sql: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_schema($tx, $sql)?
        return sql_commit($tx)
    }
}
fn .migrate($path: text, $value: text) -> result<int,problem> {
    using $tx ::= sql_begin($path)? {
        sql_schema($tx, 'CREATE TABLE IF NOT EXISTS item(id INTEGER PRIMARY KEY, label TEXT UNIQUE) STRICT')?
        sql_schema($tx, 'CREATE INDEX IF NOT EXISTS by_label ON item(label)')?
        sql_schema($tx, 'CREATE TABLE IF NOT EXISTS log(n INTEGER NOT NULL)')?
        sql_schema($tx, 'CREATE TRIGGER IF NOT EXISTS audit AFTER INSERT ON item BEGIN INSERT INTO log(n) VALUES (NEW.id); END')?
        sql_schema($tx, 'CREATE VIEW IF NOT EXISTS labels AS SELECT label FROM item')?
        sql_schema($tx, 'CREATE TEMP TABLE input AS SELECT ?1 AS label', $value)?
        $r ::= sql_returning_one<.number>($tx, 'WITH pending AS (SELECT label FROM input) INSERT INTO item(label) SELECT label FROM pending RETURNING id AS n')?
        sql_commit($tx)?
        return ok($r.n)
    }
}
fn .maybe($path: text, $id: int) -> result<.number?,problem> {
    using $tx ::= sql_begin($path)? {
        $r ::= sql_returning_optional<.number>($tx,'UPDATE item SET label = label WHERE id=?1 RETURNING id AS n',$id)?
        sql_commit($tx)?
        return ok($r)
    }
}
fn .many($path: text, $sql: text) -> result<list<.number>,problem> {
    using $tx ::= sql_begin($path)? {
        $r ::= sql_returning_many<.number>($tx,$sql)?
        sql_commit($tx)?
        return ok($r)
    }
}
fn .failure($path: text, $sql: text, $recover: bool) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx,"INSERT INTO item(label) VALUES ('uncommitted marker')")?
        if $recover {
            $ignored ::= sql_returning_one<.number>($tx,$sql)
            return sql_commit($tx)
        }
        $r ::= sql_returning_one<.number>($tx,$sql)?
        return sql_commit($tx)
    }
}
fn .schema_failure($path: text, $sql: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_schema($tx,'CREATE TABLE rolled_back(n INTEGER)')?
        $ignored ::= sql_schema($tx,$sql)
        return sql_commit($tx)
    }
}
fn .main($args: list<text>) -> result<unit,problem> {
    return match $args {
        [$path, $label] => write_stdout_utf8($"${.migrate($path,$label)?}")
        _ => err(problem('expected database path and label'))
    }
}}
}

proc ::schemaTest::equal {got expected label} {
    variable count
    if {$got ne $expected} {error "$label: expected [list $expected], got [list $got]"}
    incr count
}
proc ::schemaTest::problem {result expected} {
    lassign $result tag detail
    equal $tag err "expected failure for $expected"
    equal [dict get $detail code] $expected "typed failure: $detail"
    equal [dict get $detail origin module] app "source site for $expected"
}

proc ::schemaTest::check {} {
    variable source
    equal [::appcompiler::check [dict create app $source]] {} "all statement forms check without opening SQLite"
    foreach {type body expected} {
        unit {sql_schema('x','s')} SQL_TRANSACTION_REQUIRED
        .r {sql_returning_one<.r>('x','s')} SQL_TRANSACTION_REQUIRED
        .r? {sql_returning_optional<.r>('x','s')} SQL_TRANSACTION_REQUIRED
        list<.r> {sql_returning_many<.r>('x','s')} SQL_TRANSACTION_REQUIRED
    } {
        set diagnostics [::appcompiler::check [dict create app "record .r { n: int }\nfn .bad() -> result<$type,problem> => $body"]]
        equal [lmap d $diagnostics {dict get $d code}] [list $expected] "scope required for $body"
    }
}

proc ::schemaTest::exercise {path} {
    variable source
    namespace eval :: [dict get [::appcompiler::compile [dict create app $source] ::schemaApp] script]
    set value "007; \[hello\] \u96ea\u0000last"
    equal [::schemaApp::app::migrate $path $value] {ok 1} "CTE write returns generated key"
    equal [db onecolumn {SELECT hex(label) FROM labels}] [string toupper [binary encode hex [encoding convertto utf-8 $value]]] "bound text reaches CTAS, view and main table intact"
    equal [::schemaApp::app::migrate $path second] {ok 2} "idempotent DDL with SQLite no-op index and trigger"
    equal [db eval {SELECT n FROM log ORDER BY n}] {1 2} "trigger writes commit with the returned rows"
    equal [::schemaApp::app::maybe $path 77] {ok none} "zero returned rows"
    equal [::schemaApp::app::maybe $path 2] {ok {some {n 2}}} "one optional row"
    equal [::schemaApp::app::many $path {DELETE FROM item WHERE 0 RETURNING id AS n}] [list ok {}] "zero of many"
    lassign [::schemaApp::app::many $path {WITH c(i) AS (SELECT id FROM item) UPDATE item SET label=label WHERE id IN c RETURNING id AS n}] tag rows
    equal [list $tag [lsort -integer [lmap row $rows {dict get $row n}]]] {ok {1 2}} "all returned rows without assuming SQLite output order"
    foreach sql {
        {ALTER TABLE log ADD COLUMN note TEXT} {CREATE UNIQUE INDEX by_log ON log(n)}
        {REINDEX by_log} {ANALYZE log} {DROP INDEX by_log} {DROP INDEX IF EXISTS by_log}
        {CREATE VIRTUAL TABLE words USING fts5(content)} {DROP TABLE words}
        {CREATE TRIGGER require_label BEFORE INSERT ON item WHEN NEW.label='' BEGIN SELECT RAISE(ABORT,'label required'); END}
    } {equal [::schemaApp::app::schema $path $sql] [list ok {}] "schema operation $sql"}
    foreach {sql code} {
        {DELETE FROM item WHERE id=-1 RETURNING id AS n} CARDINALITY
        {INSERT INTO item(label) VALUES ('a'),('b') RETURNING id AS n} CARDINALITY
        {INSERT INTO item(label) VALUES ('a'),('b') RETURNING CASE WHEN label='b' THEN 'bad' ELSE id END AS n} CARDINALITY
        {INSERT INTO item(label) VALUES ('a') RETURNING label AS n} SQL_TYPE
        {INSERT INTO item(label) VALUES ('a') RETURNING CAST(X'FF' AS TEXT) AS n} SQL_TYPE
        {UPDATE item SET label=label RETURNING id AS other} SQL_COLUMNS
        {UPDATE item SET label=label WHERE id=?1 RETURNING id AS n} SQL_BIND
        {INSERT OR FAIL INTO item(label) VALUES ('prefix'),('second') RETURNING id AS n} SQL_QUERY
        {INSERT INTO item(label) VALUES ('' ) RETURNING id AS n} SQL_QUERY
        {WITH input(n) AS (VALUES(1)) SELECT n FROM input} SQL_QUERY
        {EXPLAIN INSERT INTO item(label) VALUES ('x') RETURNING id AS n} SQL_QUERY
        {INSERT INTO item(label) VALUES ('missing returning')} SQL_QUERY
        {DELETE FROM item RETURNING id AS n; COMMIT} SQL_QUERY
    } {
        problem [::schemaApp::app::failure $path $sql false] $code
        problem [::schemaApp::app::failure $path $sql true] SQL_TX_CLOSED
        equal [db eval {SELECT id FROM item ORDER BY id}] {1 2} "failed mutation and earlier writes rolled back"
        equal [db eval {SELECT n FROM log ORDER BY n}] {1 2} "failed mutation rolled back all trigger effects"
    }
    # A later row can fail typed decoding even when the cardinality permits all rows.
    problem [::schemaApp::app::many $path {INSERT INTO item(label) VALUES ('a'),('b') RETURNING CASE WHEN label='b' THEN 'bad' ELSE id END AS n}] SQL_TYPE
    equal [db onecolumn {SELECT count(*) FROM log}] 2 "late decode rolled back both trigger firings"
    foreach sql {
        {SELECT 1} {WITH c(x) AS (VALUES(1)) INSERT INTO log(n) SELECT x FROM c}
        {COMMIT} {BEGIN} {SAVEPOINT x} {PRAGMA user_version=1} {VACUUM}
        {ATTACH ':memory:' AS extra} {CREATE TABLE x(n); DROP TABLE item}
    } {
        problem [::schemaApp::app::schema $path $sql] SQL_QUERY
        problem [::schemaApp::app::schema_failure $path $sql] SQL_TX_CLOSED
        equal [db onecolumn {SELECT count(*) FROM sqlite_schema WHERE name='rolled_back'}] 0 "failed schema change closes and rolls back earlier DDL"
    }
    set target [file join [file dirname $path] copy.db]
    problem [::schemaApp::app::schema $path "VACUUM INTO '[string map {' ''} $target]'"] SQL_QUERY
    equal [file exists $target] 0 "maintenance does not create a file inside a typed transaction"
}

proc ::schemaTest::packed {dir path} {
    variable source
    set author [file join $dir author]
    set recipient [file join $dir receiver]
    file mkdir $author $recipient
    set manifest [file join $author project.dict]
    ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {app main} modules {app app.src}}
    ::appcompiler::project::stageBytes [file join $author app.src] [encoding convertto -profile strict utf-8 $source]
    set archive [file join $recipient authored.machteld]
    ::appcompiler::project::pack $manifest $archive
    file rename -- $author [file join $dir retired]
    set rebuilt [file join $recipient rebuilt.machteld]
    ::appcompiler::project::rebuild $archive $rebuilt
    foreach delivery [list $archive $rebuilt] id {3 4} {
        set result [::machteld::run -dir $recipient -timeout 30s -- [info nameofexecutable] $delivery $path "item $id"]
        equal [list [dict get $result exit] [dict get $result err] [dict get $result out]] [list 0 {} $id] "relocated authored and rebuilt entries"
        equal [db onecolumn {SELECT max(n) FROM log}] $id "packed trigger state"
    }
}

if {$argv ni {{} -pack -check-only}} {error "usage: [file tail [info script]] ?-pack|-check-only?"}
::schemaTest::check
if {$argv ne "-check-only"} {
    package require sqlite3
    set work [file normalize [file tempdir]]
    try {
        set path [file join $work {research 雪.db}]
        sqlite3 ::schemaTest::db $path
        ::schemaTest::exercise $path
        if {$argv eq "-pack"} {::schemaTest::packed $work $path}
    } finally {
        if {[info commands ::schemaTest::db] ne {}} {::schemaTest::db close}
        file delete -force -- $work
    }
}
puts "application compiler schema and RETURNING: $::schemaTest::count assertions passed"
