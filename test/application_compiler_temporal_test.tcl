package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::temporalTest {
    variable checks 0
    variable source {distinct .moment = instant
record .reading {
    stamp: .moment
    local_time: local_datetime?
}
record .series { readings: list<.reading> }

export fn .parse($text: text) -> result<instant,problem> => parse_instant($text)
export fn .local($text: text) -> result<local_datetime,problem> => parse_local_datetime($text)
export fn .resolve($text: text, $minutes: int) -> result<instant,problem> =>
    resolve_offset(parse_local_datetime($text)?, $minutes)
export fn .instant_string($stamp: instant) -> text => instant_text($stamp)
export fn .local_string($stamp: local_datetime) -> text => local_datetime_text($stamp)
export extern fn .from_tcl($value: text) -> instant = ['::string', 'cat']
export fn .same($left: .series, $right: .series) -> bool => $left == $right
export fn .json($text: text) -> result<text,problem> =>
    encode_json(decode_json<.series>($text)?)

export fn .store($path: text, $stamp: text, $local: local_datetime?) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO readings VALUES (?1, ?2)', make<.moment>(parse_instant($stamp)?), $local)?
        sql_commit($tx)?
    }
    return ok(unit)
}
export fn .rows($path: text, $sql: text) -> result<list<.reading>,problem> =>
    sql_many<.reading>($path, $sql)
fn .ordered($path: text) -> result<unit,problem> {
    $rows ::= .rows($path, 'SELECT stamp, local_time FROM readings ORDER BY stamp COLLATE BINARY')?
    for $row in $rows {
        $stamp ::= instant_text(underlying($row.stamp))
        write_stdout_utf8($"$stamp\n")?
    }
    return ok(unit)
}
fn .main($args: list<text>) -> result<unit,problem> =>
    match $args {
        ['normalize', $value] => write_stdout_utf8(instant_text(parse_instant($value)?))
        ['ordered', $path] => .ordered($path)
        _ => err(problem('expected normalize VALUE or ordered DATABASE'))
    }}
}

proc ::temporalTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::temporalTest::problem {result code label} {
    lassign $result tag value
    equal $tag err "$label returns a typed error"
    equal [dict get $value code] $code "$label problem code"
}

proc ::temporalTest::static {} {
    foreach {source expected} {
        {fn .f($v: instant) -> local_datetime => $v} RETURN_TYPE
        {fn .f($v: text) -> instant => $v} RETURN_TYPE
        {fn .f($t: instant, $local: local_datetime) -> bool => $t == $local} OPERAND_TYPE
        {fn .f($local: local_datetime) -> text => instant_text($local)} ARGUMENT_TYPE
        {fn .f($local: local_datetime) -> result<instant,problem> => resolve_offset($local, '60')} ARGUMENT_TYPE
    } {
        set diagnostics [::appcompiler::check [dict create sample $source]]
        equal [lmap d $diagnostics {dict get $d code}] [list $expected] $source
    }
}

proc ::temporalTest::scalars {} {
    foreach {input expected} {
        0001-01-01T14:00:00+14:00 0001-01-01T00:00:00.000000000Z
        9999-12-31T09:59:59.999999999-14:00 9999-12-31T23:59:59.999999999Z
        0004-03-01T01:02:03+05:45 0004-02-29T19:17:03.000000000Z
        1600-03-01T00:00:09.12000+14:00 1600-02-29T10:00:09.120000000Z
        1900-02-28T23:59:59.000000001-00:01 1900-03-01T00:00:59.000000001Z
        1582-10-10T00:00:00Z 1582-10-10T00:00:00.000000000Z
        1199-12-31T23:40:00-00:45 1200-01-01T00:25:00.000000000Z
        2000-02-29T23:59:59.000000000+00:00 2000-02-29T23:59:59.000000000Z
        2009-09-09T08:09:08.010100+08:59 2009-09-08T23:10:08.010100000Z
    } {
        equal [::timeApp::events::parse $input] [list ok $expected] $input
        equal [::timeApp::events::instant_string $expected] $expected "Tcl to instant to text"
    }
    foreach input {
        0000-01-01T00:00:00Z 1900-02-29T00:00:00Z 2000-04-31T00:00:00Z
        2000-01-01T23:59:60Z 2000-01-01T24:00:00Z 2000-01-01T01:00:00.1234567890Z
        2000-01-01T01:00:00-00:00 2000-01-01T01:00:00+14:01 2000-01-01T01:00:00+01:60
        2000-01-01T01:00:00+01:00Z 2000-01-01T00:00:00
    } {problem [::timeApp::events::parse $input] INVALID_INSTANT $input}
    foreach input {0001-01-01T00:00:00+00:01 9999-12-31T23:59:59-00:01} {
        problem [::timeApp::events::parse $input] INSTANT_RANGE "UTC year overflow"
    }
    set wall 2026-10-25T02:30:00.000000001
    equal [::timeApp::events::local 2026-10-25T02:30:00.1200] {ok 2026-10-25T02:30:00.12} "canonical local precision"
    equal [::timeApp::events::local_string $wall] $wall "local time needs no zone"
    equal [::timeApp::events::resolve $wall 120] {ok 2026-10-25T00:30:00.000000001Z} "first repeated wall time"
    equal [::timeApp::events::resolve $wall 60] {ok 2026-10-25T01:30:00.000000001Z} "second repeated wall time"
    foreach value [list ${wall}Z ${wall}+01:00 "2026-01-01T00:00:00\x00" "2026-01-01T00:00:00\n"] {
        problem [::timeApp::events::local $value] INVALID_LOCAL_DATETIME "invalid local input"
    }
    foreach offset {-841 841} {problem [::timeApp::events::resolve $wall $offset] INVALID_OFFSET "offset range"}
    foreach {fn input code} {
        instant_string 2026-01-01T00:00:00Z {APPCOMPILER ARGUMENT TYPE}
        instant_string 2026-01-01T01:00:00.000000000+01:00 {APPCOMPILER ARGUMENT TYPE}
        local_string 2026-01-01T00:00:00.00 {APPCOMPILER ARGUMENT TYPE}
        from_tcl 2026-01-01T00:00:00.3Z {APPCOMPILER EXTERN RESULT}
    } {
        equal [catch {::timeApp::events::$fn $input} msg options] 1 "$fn rejects noncanonical boundary data"
        equal [dict get $options -errorcode] $code "$fn retains the Tcl boundary error code"
    }
}

proc ::temporalTest::wireAndDatabase {path} {
    set first 2000-03-01T00:00:00.000000000Z
    set next 2000-03-01T00:00:00.000000001Z
    set end 2000-03-01T00:00:01.000000000Z
    set wall 2000-02-29T23:59:59.008
    set json [format {{"readings":[{"stamp":"%s","local_time":"%s"},{"stamp":"%s"}]}} $first $wall $next]
    equal [::timeApp::events::json $json] [list ok $json] "nested JSON, distinct instant and omitted local"
    foreach substitute [list {"2000-03-01T00:00:00Z"} 0 null] {
        problem [::timeApp::events::json [string map [list "\"$first\"" $substitute] $json]] JSON_SCHEMA "JSON timestamp type and canonical form"
    }
    set row [dict create stamp $first local_time [list some $wall]]
    set rows [dict create readings [list $row]]
    equal [::timeApp::events::same $rows $rows] 1 "nested temporal record equality"
    equal [::timeApp::events::same $rows [dict create readings [list [dict replace $row stamp $next]]]] 0 "one nanosecond changes record equality"

    package require sqlite3
    sqlite3 [namespace current]::db $path
    try {
        db eval {CREATE TABLE readings(stamp TEXT NOT NULL, local_time TEXT) STRICT}
        foreach {input local} [list $end none $next [list some $wall] 2000-02-29T19:00:00-05:00 none] {
            equal [::timeApp::events::store $path $input $local] [list ok {}] "store temporal bound values"
        }
        equal [db eval {SELECT typeof(stamp), stamp FROM readings ORDER BY stamp COLLATE BINARY}] \
            [list text $first text $next text $end] "SQLite BINARY orders adjacent instants"
        set sql {SELECT stamp, local_time FROM readings ORDER BY stamp COLLATE BINARY}
        lassign [::timeApp::events::rows $path $sql] tag records
        equal $tag ok "typed SQL rows"
        equal [lmap r $records {dict get $r stamp}] [list $first $next $end] "typed SQL order"
        equal [dict get [lindex $records 0] local_time] none "SQL NULL is an absent local"
        equal [dict get [lindex $records 1] local_time] [list some $wall] "SQL local precision"
        foreach badSql {
            {SELECT '2000-03-01T00:00:00Z' AS stamp, NULL AS local_time}
            {SELECT 0 AS stamp, NULL AS local_time}
            {SELECT stamp, '2000-03-01T00:00:00Z' AS local_time FROM readings}
        } {problem [::timeApp::events::rows $path $badSql] SQL_TYPE "typed SQL refuses noncanonical stored data"}
    } finally {db close}
    return [list $first $next $end]
}

proc ::temporalTest::packed {work path expected} {
    variable source
    set author [file join $work author]
    set recipient [file join $work recipient]
    file mkdir $author $recipient
    set manifest [file join $author project.dict]
    ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {events main} modules {events events.src}}
    ::appcompiler::project::stageBytes [file join $author events.src] [encoding convertto -profile strict utf-8 $source]
    set archive [file join $recipient events.machteld]
    ::appcompiler::project::pack $manifest $archive
    file rename -- $author [file join $work retired]
    file rename -- $path [file join $recipient records.db]
    set exe [file join $recipient machteld.exe]
    file copy -- [info nameofexecutable] $exe
    foreach {args output} [list {ordered records.db} "[join $expected \n]\n" \
            {normalize 2000-03-01T00:00:00.000000001+00:15} 2000-02-29T23:45:00.000000001Z] {
        set run [::machteld::run -dir $recipient -timeout 30s -- $exe $archive {*}$args]
        equal [dict get $run truncated] {} "complete archive output"
        equal [dict get $run err] {} "archive stderr ($args)"
        equal [dict get $run exit] 0 "archive exit ($args)"
        equal [dict get $run out] $output "archive output ($args)"
    }
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set work [file normalize [file tempdir]]
try {
    ::temporalTest::static
    set artifact [::appcompiler::compile [dict create events $::temporalTest::source] ::timeApp]
    namespace eval :: [dict get $artifact script]
    ::temporalTest::scalars
    set path [file join $work records.db]
    set ordered [::temporalTest::wireAndDatabase $path]
    if {$argv eq "-pack"} {::temporalTest::packed $work $path $ordered}
} finally {
    if {[file dirname $work] ne $work && [file normalize $work] eq $work} {file delete -force -- $work}
}
puts "application compiler temporal: $::temporalTest::checks assertions passed"
