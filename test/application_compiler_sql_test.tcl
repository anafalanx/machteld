package require machteld

namespace eval ::sqlTest {variable count 0}

proc ::sqlTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}

proc ::sqlTest::write {path text} {
    set channel [open $path wb]
    try {puts -nonewline $channel [encoding convertto -profile strict utf-8 $text]} finally {close $channel}
}

proc ::sqlTest::command {cwd exe expectedExit args} {
    set run [::machteld::run -dir $cwd -timeout 30s -- $exe {*}$args]
    set out [encoding convertfrom -profile strict utf-8 [dict get $run out]]
    set err [encoding convertfrom -profile strict utf-8 [dict get $run err]]
    if {[dict get $run exit] ne $expectedExit || [dict get $run truncated] ne {}} {
        error "[list {*}$args]: expected exit $expectedExit, got [dict get $run exit]; stdout=$out, stderr=$err"
    }
    return [list [string trimright $out "\r\n"] [string trimright $err "\r\n"]]
}

proc ::sqlTest::success {cwd exe args} {
    lassign [command $cwd $exe 0 {*}$args] out err
    equal $err {} "successful command writes no stderr"
    return $out
}

proc ::sqlTest::sources {dir} {
    file mkdir $dir
    write [file join $dir project.dict] {schema 1 edition 1 minApi 0.21 entry {app main}
modules {app main.src model model.src}}
    write [file join $dir model.src] {export distinct .key = text
export record .observation {
    id: .key
    note: text?
}
export alias .row = .observation
export record .number { n: int }
export record .flag { enabled: bool }
export record .price { price: decimal }
export record .chunk { data: bytes }
export record .string { value: text }
}
    set source {import model

fn .at($id: text, $instant: int) -> result<.model::row?,problem> {
    return sql_optional<.model::row>('records.db',
        'SELECT note, id FROM history WHERE starts <= ?2 AND ?2 < ends AND id = ?1',
        make<.model::key>($id), $instant)
}
example .at('007', 9) => none
example .at('007', 34) => error 'CARDINALITY'
example .at('7', 31) => none
example .at('007', 40) => none

fn .matches($instant: int, $json: text) -> result<bool,problem> {
    $found ::= .at('007', $instant)?
    $expected ::= decode_json<.model::row>($json)?
    return ok($found == some($expected))
}
example .matches(10, '{"id":"007"}') => true
example .matches(20, '{"id":"007","note":""}') => true
example .matches(31, '{"id":"007","note":"ready"}') => true

fn .state($instant: int) -> result<text,problem> {
    $found ::= .at('007', $instant)?
    return ok(match $found {
        none => 'no row'
        some($row) => match $row.note {
            none => 'no note'
            some($text) => $text
        }
    })
}
example .state(9) => 'no row'
example .state(10) => 'no note'
example .state(20) => ''
example .state(31) => 'ready'

fn .number($sql: text) -> result<int,problem> {
    $row ::= sql_one<.model::number>('records.db', $sql)?
    return ok($row.n)
}
example .number('SELECT 8 AS n; -- trailing comment') => 8
example .number('SELECT 8 AS n WHERE 0') => error 'CARDINALITY'
example .number('SELECT 8 AS n UNION ALL SELECT 9') => error 'CARDINALITY'
example .number('SELECT 1 AS wrong WHERE 0') => error 'SQL_COLUMNS'
example .number('SELECT 1 AS N WHERE 0') => error 'SQL_COLUMNS'
example .number('SELECT 1 AS n, 2 AS n WHERE 0') => error 'SQL_COLUMNS'
example .number('SELECT 1 AS n, 2 AS extra WHERE 0') => error 'SQL_COLUMNS'
example .number('SELECT NULL AS n') => error 'SQL_TYPE'
example .number('SELECT 2.0 AS n') => error 'SQL_TYPE'
example .number("SELECT '2' AS n") => error 'SQL_TYPE'
example .number('SELECT ?1 AS n') => error 'SQL_BIND'
example .number('SELECT $path AS n') => error 'SQL_BIND'
example .number('SELECT n FROM missing_table') => error 'SQL_QUERY'
example .number('SELECT FROM') => error 'SQL_QUERY'
example .number('SELECT 1 AS n; SELECT 2 AS n') => error 'SQL_QUERY'
example .number('DELETE FROM history RETURNING starts AS n') => error 'SQL_QUERY'
example .number('PRAGMA user_version=17') => error 'SQL_QUERY'
example .number("ATTACH DATABASE 'should-not-exist.db' AS extra") => error 'SQL_QUERY'
example .number("SELECT count(*) AS n FROM words WHERE words MATCH 'aurora'") => 1

fn .order($cutoff: int) -> result<int,problem> {
    $rows ::= sql_many<.model::number>('records.db',
        'WITH seq(n) AS (VALUES (1), (2), (3)) SELECT n FROM seq WHERE n < ?1 ORDER BY n DESC', $cutoff)?
    $n := 0
    for $row in $rows { $n = 10 * $n + $row.n }
    return ok($n)
}
example .order(4) => 321
example .order(1) => 0

fn .ints($sql: text, $x: int, $y: int) -> result<int,problem> {
    $row ::= sql_one<.model::number>('records.db', $sql, $x, $y)?
    return ok($row.n)
}
example .ints('SELECT ?2 + ?1 + ?2 AS n', 2, 30) => 62
example .ints('SELECT ?2 AS n', 1, 20) => 20
example .ints('SELECT ? + ? AS n', 12, 7) => 19
example .ints('SELECT ?1 AS n', 2, 30) => error 'SQL_BIND'
example .ints('SELECT ?1 + ?2 AS n', 9223372036854775808, 0) => error 'SQL_BIND'

fn .mark($n: int) -> int => $n
fn .evaluation_order($path: text) -> result<int,problem> {
    $row ::= sql_one<.model::number>($path, 'SELECT ?2*10 + ?1 AS n', .mark(1), .mark(2))?
    return ok($row.n)
}

fn .optional_param($input: text?) -> result<int,problem> {
    $row ::= sql_one<.model::number>('records.db', 'SELECT CASE WHEN ?1 IS NULL THEN 19 ELSE length(?1) END AS n', $input)?
    return ok($row.n)
}
example .optional_param(none) => 19
example .optional_param(some('')) => 0
example .optional_param(some('雪')) => 1
fn .literal_null() -> result<int,problem> {
    $row ::= sql_one<.model::number>('records.db', 'SELECT (?1 IS NULL) AS n', none)?
    return ok($row.n)
}
example .literal_null() => 1

fn .text_param($input: text) -> result<text,problem> {
    $row ::= sql_one<.model::string>('records.db', 'SELECT ?1 AS value', $input)?
    return ok($row.value)
}
example .text_param("007'); DROP TABLE history; -- $x [expr 1] 雪\0x") => "007'); DROP TABLE history; -- $x [expr 1] 雪\0x"

fn .invalid_utf8() -> result<.model::string,problem> {
    return sql_one<.model::string>('records.db', "SELECT CAST(X'FF' AS TEXT) AS value")
}
example .invalid_utf8() => error 'SQL_TYPE'

fn .flag($sql: text, $value: bool) -> result<bool,problem> {
    $row ::= sql_one<.model::flag>('records.db', $sql, $value)?
    return ok($row.enabled)
}
example .flag('SELECT ?1 AS enabled', true) => true
example .flag('SELECT ?1 AS enabled', false) => false
example .flag('SELECT ?1+2 AS enabled', false) => error 'SQL_TYPE'

fn .price($sql: text, $value: decimal) -> result<decimal,problem> {
    $row ::= sql_one<.model::price>('records.db', $sql, $value)?
    return ok($row.price)
}
example .price('SELECT ?1 AS price', 120000000000000000000.123) => 120000000000000000000.123
example .price('SELECT CAST(?1 AS REAL) AS price', 0.1) => error 'SQL_TYPE'

extern fn .unhex($s: text) -> bytes = ['::binary','decode','hex']
extern fn .hex($data: bytes) -> text = ['::binary','encode','hex']
fn .blob($s: text) -> result<text,problem> {
    $row ::= sql_one<.model::chunk>('records.db', 'SELECT ?1 AS data', .unhex($s))?
    return ok(.hex($row.data))
}
example .blob('00ff80') => '00ff80'
example .blob('') => ''

fn .line($path: text, $key: text) -> result<text,problem> {
    $row ::= sql_one<.model::row>($path, 'SELECT note, id FROM history WHERE starts=30 AND id=?1', $key)?
    return encode_json($row)
}
example .line('uncreated.db','007') => error 'SQL_OPEN'
fn .main($args: list<text>) -> result<unit,problem> {
    return match $args {
        [$path, $key] => write_stdout_utf8(.line($path, $key)?)
        _ => err(problem('expected database path and key'))
    }
}}
    write [file join $dir main.src] $source
    return $source
}

proc ::sqlTest::database {path} {
    package require sqlite3
    sqlite3 [namespace current]::writer $path
    try {
        writer eval {
            CREATE TABLE history(id TEXT, starts INTEGER, ends INTEGER, note TEXT);
            INSERT INTO history VALUES ('007',10,20,NULL), ('007',20,30,''),
                                       ('007',30,40,'ready'), ('007',33,35,'overlap');
            CREATE VIRTUAL TABLE words USING fts5(content);
            INSERT INTO words VALUES ('aurora');
        }
    } finally {writer close}
}

proc ::sqlTest::static {exe driver dir source} {
    set valid [success $dir $exe $driver check --json project.dict]
    equal [dict get [::machteld::json unwrap [::machteld::json decode -typed $valid]] ok] 1 "SQL reads check without a database"
    equal [file exists [file join $dir records.db]] 0 "check did not create the data file"
    set path [file join $dir main.src]
    set invalid {
        ARGUMENT_TYPE         {sql_one<.model::row>(23, 's')}
        ARGUMENT_TYPE         {sql_many<.model::row>('p', true)}
        SQL_BIND_TYPE         {sql_one<.model::row>('p', 's', map<text,int>())}
        SQL_FIELD_TYPE        {sql_optional<.nested>('p', 's')}
        SQL_FIELD_TYPE        {sql_one<.ambiguous>('p','s')}
        EXPECTED_RECORD       {sql_one<text>('p','s')}
        CALL_ARITY            {sql_optional<.model::row>('p')}
        TYPE_ARITY            {sql_many('p','s')}
        MATCH_NONEXHAUSTIVE   {match some(1) {some($value) => $value}}
        PATTERN_ARITY         {match some(1) {some => 0
            none => 1}}
        DUPLICATE_ARM         {match some(1) {none => 0
            none => 1
            some(_) => 2}}
    }
    foreach {code expr} $invalid {
        write $path "import model\nrecord .nested { bad: list<int> }\nrecord .ambiguous { bad: text?? }\nfn .main(\$args: list<text>) -> result<unit,problem> {\n    \$ignored ::= $expr\n    return ok(unit)\n}"
        lassign [command $dir $exe 1 $driver check --json project.dict] out err
        equal $err {} "structured compile failure uses stdout"
        set diagnostics [dict get [::machteld::json unwrap [::machteld::json decode -typed $out]] diagnostics]
        set matched 0
        foreach item $diagnostics {
            set line [dict get $item node line]
            if {[dict get $item code] eq $code && $line >= 5 && $line < 5 + [llength [split $expr \n]]
                    && [dict get $item node module] eq "app"} {set matched 1}
        }
        equal $matched 1 "located $code for $expr: $diagnostics"
    }
    write $path $source
}

proc ::sqlTest::recordArgument {command operation} {variable calls; lappend calls [lindex $command 1]}

proc ::sqlTest::connectionLifetime {dir dbPath} {
    variable calls {}
    set project [::appcompiler::project::load [file join $dir project.dict]]
    set compiled [::appcompiler::compile [dict get $project sources] ::sqlTest::loaded]
    namespace eval :: [dict get $compiled script]
    try {
        trace add execution ::sqlTest::loaded::app::mark enter ::sqlTest::recordArgument
        equal [loaded::app::evaluation_order $dbPath] {ok 21} "compiled call binds the values in their argument slots"
        equal $calls {1 2} "bound expressions evaluate once, left to right"
        foreach id {7 007 7} {
            lassign [loaded::app::line $dbPath $id] outcome payload
            if {$id eq "7"} {
                equal $outcome err "cardinality error is an ordinary typed result"
                equal [dict get $payload code] CARDINALITY "public runtime code survives propagation"
            } else {
                equal $outcome ok "a later read succeeds after a failed call"
            }
            equal [info commands ::sqlTest::loaded::@rt::sqlConnection*] {} "call released its SQLite connection"
        }
    } finally {namespace delete ::sqlTest::loaded}
}

proc ::sqlTest::exercise {exe driver work mode} {
    set author [file join $work author]
    set source [sources $author]
    static $exe $driver $author $source
    if {$mode eq "-check-only"} {return}
    set recipient [file join $work {recipient 雪}]
    set archive [file join $author draft.machteld]
    if {$mode eq "-pack"} {
        success $author $exe $driver pack project.dict $archive
        equal [file exists [file join $author records.db]] 0 "pack does not contact the database"
    }
    set dbPath [file join $author records.db]
    database $dbPath
    connectionLifetime $author $dbPath
    set hash [::machteld::hash file sha256 $dbPath]
    set total [regexp -all -line {^example } $source]
    set report [success $author $exe $driver test project.dict]
    equal $report "$total examples: $total passed, 0 failed" "historical reads and typed SQL errors"
    equal [success $author $exe $driver run project.dict records.db 007] {{"id":"007","note":"ready"}} "direct project entry"
    equal [::machteld::hash file sha256 $dbPath] $hash "read-only statements leave database bytes unchanged"
    foreach name {should-not-exist.db uncreated.db} {equal [file exists [file join $author $name]] 0 "no $name was created"}
    if {$mode ne "-pack"} {return}

    file mkdir $recipient
    set delivery [file join $recipient history.machteld]
    file rename -- $archive $delivery
    file rename -- $dbPath [file join $recipient records.db]
    file rename -- $author [file join $work put-away]
    file copy -- $exe [file join $recipient machteld.exe]
    set host [file join $recipient machteld.exe]
    equal [success $recipient $host $delivery records.db 007] {{"id":"007","note":"ready"}} "moved archive reads external SQLite data"
    lassign [command $recipient $host 1 $delivery records.db 7] out err
    equal $out {} "an unexpected row count produces no output"
    equal [regexp {app:[0-9]+:[0-9]+:} $err] 1 "packed lookup failure identifies its source"
    set mount [zipfs mount $delivery sql-test]
    try {
        ::machteld::ArchiveEntry $mount
        file copy -- [file join $mount compiler] [file join $recipient compiler]
        file copy -- [file join $mount project inputs] [file join $recipient inputs]
    } finally {zipfs unmount $mount}
    equal [success $recipient $host compiler/driver.tcl test inputs/application.dict] $report "recipient runs the same examples with the archived compiler"
    equal [::machteld::hash file sha256 [file join $recipient records.db]] $hash "relocated runs preserve database"
}

set mode [lindex $argv 0]
if {$argv ni {{} -pack -check-only}} {error "usage: [file tail [info script]] ?-pack|-check-only?"}
set driver [file normalize [file join [file dirname [info script]] .. tools application_project.tcl]]
source -encoding utf-8 [file join [file dirname $driver] .. packages application-compiler compiler.tcl]
set work [file normalize [file tempdir]]
try {
    ::sqlTest::exercise [info nameofexecutable] $driver $work $mode
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler SQL: $::sqlTest::count assertions passed"
