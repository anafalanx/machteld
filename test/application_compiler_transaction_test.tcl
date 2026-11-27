package require machteld
lappend auto_path [file join [file dirname [info script]] .. packages application-compiler]
package require application-compiler 0.1

namespace eval ::txTest {
    variable count 0
    variable source {record .number { n: int }
extern fn .stop($message: text) -> unit = ['::error']
fn .save($path: text, $id: text) -> result<int,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO items VALUES (?1)', $id)?
        $one ::= sql_one<.number>($tx, 'SELECT count(*) AS n FROM items')?
        $outside ::= sql_one<.number>($path, 'SELECT count(*) AS n FROM items')?
        $maybe ::= sql_optional<.number>($tx, 'SELECT 1 AS n FROM items WHERE id=?1', $id)?
        $extra ::= match $maybe { none => 0
            some($r) => $r.n }
        $many ::= sql_many<.number>($tx, 'SELECT 2 AS n FROM items WHERE id=?1', $id)?
        $n := 0
        for $r in $many { $n = $n + $r.n }
        sql_commit($tx)?
        return ok(1000 * $one.n + 100 * $outside.n + 10 * $extra + $n)
    }
}
fn .leave($path: text, $mode: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'temporary')?
        if $mode == 'early' { return ok(unit) }
        if $mode == 'typed' { return err(problem('rejected item')) }
        if $mode == 'fault' { .stop('unexpected fault') }
        if $mode == 'commit-fail' {
            sql_exec($tx, 'INSERT INTO child VALUES (42)')?
            sql_commit($tx)?
        }
    }
    return ok(unit)
}
fn .loop($path: text) -> result<unit,problem> {
    for .batch $index in 0..3 {
        using $tx ::= sql_begin($path)? {
            sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'temporary')?
            if $index == 0 { continue .batch }
            break .batch
        }
    }
    return ok(unit)
}
fn .statement($path: text, $sql: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'temporary')?
        sql_exec($tx, $sql)?
        return sql_commit($tx)
    }
}
fn .fail_write($path: text, $sql: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'temporary')?
        $failure ::= sql_exec($tx, $sql)
        sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'must never autocommit')?
        return sql_commit($tx)
    }
}
fn .fail_commit($path: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO child VALUES (42)')?
        $failure ::= sql_commit($tx)
        return sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'must never autocommit')
    }
}
fn .after_commit($path: text, $operation: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_commit($tx)?
        if $operation == 'commit' { return sql_commit($tx) }
        if $operation == 'read' {
            $r ::= sql_one<.number>($tx, 'SELECT 1 AS n')?
            return ok(unit)
        }
        return sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'must never autocommit')
    }
}
fn .read_control($path: text, $sql: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO items VALUES (?1)', 'temporary')?
        $r ::= sql_one<.number>($tx, $sql)?
        return sql_commit($tx)
    }
}
fn .main($args: list<text>) -> result<unit,problem> {
    return match $args {
        [$path, 'save', $id] => write_stdout_utf8($"${.save($path, $id)?}")
        [$path, $mode] => .leave($path, $mode)
        _ => err(problem('expected database and operation'))
    }
}}
}

proc ::txTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}

proc ::txTest::static {} {
    variable source
    equal [::appcompiler::check [dict create app $source]] {} "transaction fixture checks without a database"
    set module {export record .row { using: int }
export fn .using($row: .row) -> int => $row.using}
    set client {import using
fn .value($path: text) -> result<int,problem> {
    using $tx ::= sql_begin($path)? {
        $row ::= sql_one<.using::row>($tx, 'SELECT 19 AS "using"')?
        return ok(.using::using($row))
    }
}}
    equal [::appcompiler::check [dict create app $client using $module]] {} \
        "the resource statement preserves a module, function and field named using"
    foreach {code snippet} {
        UNKNOWN_FUNCTION         {using()}
        SQL_TRANSACTION_SCOPE    {using $tx ::= sql_begin($path)? { $copy ::= $tx }}
        SQL_TRANSACTION_SCOPE    {using $tx ::= sql_begin($path)? { $same ::= $tx == $tx }}
        SQL_TRANSACTION_SCOPE    {$copy ::= sql_begin($path)?}
        SQL_TRANSACTION_REQUIRED {sql_commit($path)?}
        SQL_TRANSACTION_REQUIRED {sql_exec($path, 'DELETE FROM items')?}
        UNKNOWN_BINDING          {using $tx ::= sql_begin($path)? {}
sql_commit($tx)?}
        ARGUMENT_TYPE            {using $tx ::= sql_begin(123)? {}}
        ARGUMENT_TYPE            {using $tx ::= sql_begin($path)? { sql_exec($tx, 23)? }}
        SQL_BIND_TYPE            {using $tx ::= sql_begin($path)? { sql_exec($tx, 's', map<text,int>())? }}
        DISCARDED_RESULT         {using $tx ::= sql_begin($path)? { sql_commit($tx) }}
    } {
        set program [format {fn .invalid($path: text) -> result<unit,problem> {
%s
return ok(unit)
}} $snippet]
        set items [::appcompiler::check [dict create app $program]]
        set located 0
        foreach item $items {
            set node [dict get $item node]
            if {[dict get $item code] eq $code && [dict get $node module] eq "app" &&
                    [dict get $node line] >= 2 && [dict get $node line] <= 1 + [llength [split $snippet \n]]} {
                set located 1
            }
        }
        equal $located 1 "$code for $snippet: $items"
    }
    set plain {fn .invalid($path: text) -> unit {
        using $tx ::= sql_begin($path)? {}
        return unit
    }}
    equal [lmap d [::appcompiler::check [dict create app $plain]] {dict get $d code}] PROPAGATION_TYPE \
        "opening a transaction requires a compatible fallible function"
}

proc ::txTest::expectProblem {result code sourceLine} {
    variable source
    lassign $result tag problem
    equal $tag err "$code is a typed failure"
    equal [dict get $problem code] $code "$code is preserved"
    set origin [dict get $problem origin]
    set line [dict get $origin line]
    equal [list [dict get $origin module] [string match $sourceLine [string trim [lindex [split $source \n] [expr {$line-1}]]]]] \
        {app 1} "located $code ($origin, expected $sourceLine)"
}

proc ::txTest::fixture {path} {
    package require sqlite3
    sqlite3 [namespace current]::observer $path
    observer eval {
        CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL) STRICT;
        CREATE TABLE parent(id INTEGER PRIMARY KEY) STRICT;
        CREATE TABLE child(parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED) STRICT;
    }
}

proc ::txTest::exercise {path} {
    variable source
    set compiled [::appcompiler::compile [dict create app $source] ::txApp]
    namespace eval :: [dict get $compiled script]
    set id "007'); DROP TABLE items; --\n\u96ea\u0000end"
    set idHex [string toupper [binary encode hex [encoding convertto -profile strict utf-8 $id]]]
    equal [::txApp::app::save $path $id] {ok 1012} "the handle sees its own changes, a separate reader sees the prior snapshot"
    equal [observer onecolumn {SELECT hex(id) FROM items}] $idHex "a second connection sees the exact committed bytes"
    foreach mode {early normal typed fault commit-fail} {
        set status [catch {::txApp::app::leave $path $mode} result options]
        if {$mode eq "fault"} {
            equal [list $status $result] {1 {unexpected fault}} "the original Tcl exception survives cleanup"
            set origin [dict get $options -appcompilerlocation]
            equal [list [dict get $origin module] [dict get $origin line]] {app 2} "fault retains its extern origin"
        } else {
            equal $status 0 "$mode is a normal return"
            switch -- $mode {
                typed {equal [dict get [lindex $result 1] message] {rejected item} "the application rejection survives cleanup"}
                commit-fail {expectProblem $result SQL_COMMIT {sql_commit*}}
                default {equal $result [list ok {}] "$mode successful return"}
            }
        }
        equal [observer eval {SELECT hex(id) FROM items}] [list $idHex] "$mode rolls back all new data"
        equal [observer eval {SELECT parent_id FROM child}] {} "$mode leaves no invalid foreign key"
    }
    equal [::txApp::app::loop $path] [list ok {}] "break and continue through a scope both release the writer"
    equal [observer eval {SELECT hex(id) FROM items}] [list $idHex] "loop control rolled back both writes"

    set missing [file join [file dirname $path] missing.db]
    expectProblem [::txApp::app::save $missing test] SQL_OPEN {using*sql_begin*}
    equal [file exists $missing] 0 "a mistaken path never creates a database"
    observer eval {BEGIN IMMEDIATE}
    try {
        expectProblem [::txApp::app::save $path locked] SQL_BEGIN {using*sql_begin*}
    } finally {observer eval {ROLLBACK}}
    foreach sql {
        {COMMIT} {END} {ROLLBACK} {SAVEPOINT s} {PRAGMA foreign_keys=OFF}
        {DELETE FROM items; COMMIT} {SELECT 1}
        {INSERT INTO items VALUES ('returned') RETURNING id}
    } {
        expectProblem [::txApp::app::statement $path $sql] SQL_QUERY {sql_exec($tx, $sql)*}
        equal [observer eval {SELECT hex(id) FROM items}] [list $idHex] "blocked statement leaves no writes: $sql"
    }
    expectProblem [::txApp::app::statement $path {INSERT INTO items VALUES (?1)}] SQL_BIND {sql_exec($tx, $sql)*}
    foreach sql {{COMMIT} {ROLLBACK} {DELETE FROM items RETURNING 1 AS n}} {
        expectProblem [::txApp::app::read_control $path $sql] SQL_QUERY {*sql_one*}
        equal [observer eval {SELECT hex(id) FROM items}] [list $idHex] "a read cannot commit or write: $sql"
    }
    foreach policy {FAIL ROLLBACK ABORT} {
        set sql "INSERT OR $policy INTO items VALUES ('partial'), ('temporary')"
        expectProblem [::txApp::app::fail_write $path $sql] SQL_TX_CLOSED {sql_exec*must never autocommit*}
        equal [observer eval {SELECT hex(id) FROM items}] [list $idHex] "OR $policy cannot commit a partial statement or later write"
    }
    expectProblem [::txApp::app::fail_commit $path] SQL_TX_CLOSED {*sql_exec*must never autocommit*}
    equal [observer eval {SELECT parent_id FROM child}] {} "failed commit closes and rolls back immediately"
    foreach {operation location} {commit {*return sql_commit*} read {*sql_one*} write {*sql_exec*must never autocommit*}} {
        expectProblem [::txApp::app::after_commit $path $operation] SQL_TX_CLOSED $location
    }
    equal [observer eval {SELECT hex(id) FROM items}] [list $idHex] "attempts after failed and successful commits leave disk unchanged"
    equal [::txApp::app::save $path next] {ok 2112} "a fresh transaction can write after every failure"
}

proc ::txTest::packed {work path} {
    variable source
    set author [file join $work author]
    set recipient [file join $work recipient]
    file mkdir $author $recipient
    set manifest [file join $author project.dict]
    ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {app main} modules {app app.src}}
    ::appcompiler::project::stageBytes [file join $author app.src] [encoding convertto -profile strict utf-8 $source]
    set archive [file join $recipient transaction.machteld]
    ::appcompiler::project::pack $manifest $archive
    file rename -- $author [file join $work retired]
    set exe [file join $recipient machteld.exe]
    file copy -- [info nameofexecutable] $exe
    foreach {args status output errorPattern} {
        {save packed} 0 3212 {}
        {early} 0 {} {}
        {typed} 1 {} {app:*: rejected item}
        {commit-fail} 1 {} {app:*:*}
    } {
        set r [::machteld::run -dir $recipient -timeout 30s -- $exe $archive $path {*}$args]
        set err [string trimright [encoding convertfrom -profile strict utf-8 [dict get $r err]] "\r\n"]
        equal [dict get $r exit] $status "[list {*}$args] exit, stderr=$err"
        equal [dict get $r truncated] {} "[list {*}$args] complete streams"
        equal [encoding convertfrom -profile strict utf-8 [dict get $r out]] $output "[list {*}$args] stdout"
        equal [string match $errorPattern $err] 1 "[list {*}$args] stderr: $err"
        equal [observer onecolumn {SELECT count(*) FROM items}] 3 "[list {*}$args] packed database state"
    }
}

if {$argv ni {{} -check-only -pack}} {error "usage: [file tail [info script]] ?-check-only|-pack?"}
::txTest::static
if {$argv ne "-check-only"} {
    set work [file normalize [file tempdir]]
    set path [file join $work records.db]
    try {
        ::txTest::fixture $path
        ::txTest::exercise $path
        if {$argv eq "-pack"} {::txTest::packed $work $path}
    } finally {
        if {[llength [info commands ::txTest::observer]]} {::txTest::observer close}
        if {[file dirname $work] ne $work && [file normalize $work] eq $work} {file delete -force -- $work}
    }
}
puts "application compiler transactions: $::txTest::count assertions passed"
