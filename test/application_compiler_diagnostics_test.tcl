package require machteld

namespace eval ::diagnosticTest {
    variable count 0
    namespace path ::machteld
}

proc ::diagnosticTest::expect {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}

proc ::diagnosticTest::writeUtf8 {path text} {
    set ch [open $path wb]
    try {puts -nonewline $ch [encoding convertto utf-8 $text]} finally {close $ch}
}

proc ::diagnosticTest::invoke {root driver args} {
    set child [::machteld::run -dir $root -timeout 15s -- [info nameofexecutable] $driver check {*}$args]
    if {[dict get $child exit] eq "" || [dict get $child truncated] ne ""} {
        error "incomplete project check: [dict get $child status]"
    }
    set streams {}
    foreach key {out err} {
        dict set streams $key [encoding convertfrom -profile strict utf-8 [dict get $child $key]]
    }
    return [dict merge $streams [dict create exit [dict get $child exit]]]
}

proc ::diagnosticTest::objectKeys {node keys label} {
    expect [json type $node] object "$label JSON type"
    expect [lsort [dict keys [json unwrap $node]]] [lsort $keys] "$label JSON members"
}

proc ::diagnosticTest::report {root driver manifest ok count} {
    set r [invoke $root $driver --json $manifest]
    expect [dict get $r exit] [expr {!$ok}] "JSON check exit status"
    expect [dict get $r err] {} "JSON check stderr"
    # The typed decoder also rejects any non-whitespace after the document.
    set doc [json decode -typed [dict get $r out]]
    objectKeys $doc {schema ok diagnostics} report
    foreach {key type value} [list schema number 1 ok boolean $ok] {
        set item [json get $doc $key]
        expect [json type $item] $type "$key JSON type"
        expect [json unwrap $item] $value "$key value"
    }
    set items [json get $doc diagnostics]
    expect [json type $items] array "diagnostics JSON type"
    expect [llength [json unwrap $items]] $count "number of diagnostics"
    set result {}
    for {set i 0} {$i < $count} {incr i} {
        set d [json get $items $i]
        objectKeys $d {code message node} diagnostic
        foreach key {code message} {
            expect [json type [json get $d $key]] string "$key JSON type"
        }
        set code [json unwrap [json get $d code]]
        if {[dict exists $result $code]} {error "unexpected duplicate fixture diagnostic $code"}
        dict set result $code $d
    }
    return $result
}

proc ::diagnosticTest::located {items code span} {
    set d [dict get $items $code]
    set node [json get $d node]
    set keys {module line column endLine endColumn}
    objectKeys $node $keys "$code span"
    set actual {}
    foreach key $keys {
        set value [json get $node $key]
        expect [json type $value] [expr {$key eq "module" ? "string" : "number"}] "$code $key type"
        lappend actual [json unwrap $value]
    }
    expect $actual $span "$code half-open source range"
    lassign $span module line column endLine endColumn
    return [format {%s:%s:%s..%s:%s [%s] %s} $module $line $column $endLine $endColumn $code \
        [json unwrap [json get $d message]]]
}

proc ::diagnosticTest::plain {root driver manifest expectedLines} {
    set r [invoke $root $driver $manifest]
    expect [dict get $r exit] [expr {[llength $expectedLines] > 0}] "plain check exit status"
    expect [dict get $r out] {} "plain check stdout"
    set text [string map [list \r\n \n] [dict get $r err]]
    expect [lsort [split [string trimright $text \n] \n]] [lsort $expectedLines] "plain check stderr"
}

proc ::diagnosticTest::syntaxRecovery {root driver manifest} {
    # These failures leave balanced declaration boundaries. A nested string
    # contains a line that would look like another declaration to a text scan.
    set first {fn .a() -> int { return [1,,2] }
fn .message() -> text => 'verbatim
fn .inside_string() -> int { return [3,,4] }
end'
# fn .inside_comment() -> int { return [5,,6] }
fn .b() -> int { return [7,,8] }
fn .ok() -> int => 9}
    writeUtf8 [file join $root a.src] [string map [list \n \r\n] $first]
    writeUtf8 [file join $root b.src] {import first
fn .independent() -> int => $missing
fn .dependent() -> int => .first::a()}
    set r [invoke $root $driver --json $manifest]
    expect [dict get $r exit] 1 "damaged module fails project check"
    set items [json get [json decode -typed [dict get $r out]] diagnostics]
    set locations {}
    set messages {}
    for {set i 0} {$i < [llength [json unwrap $items]]} {incr i} {
        set item [json get $items $i]
        set code [json unwrap [json get $item code]]
        set where [json get $item node]
        set span {}
        foreach key {module line column endLine endColumn} {lappend span [json unwrap [json get $where $key]]}
        lappend locations [list $code {*}$span]
        lappend messages [located [dict create $code $item] $code $span]
    }
    expect $locations {{E_PARSE_EXPECTED first 1 28 1 29} {E_PARSE_EXPECTED first 6 28 6 29} {UNKNOWN_BINDING second 2 29 2 37}} \
        "independent syntax errors keep spans and the importer suppresses speculative missing exports"
    plain $root $driver $manifest $messages

    writeUtf8 [file join $root b.src] {}
    writeUtf8 [file join $root a.src] "fn .a() -> int \{ return \[1,,2\]\nfn .nested() -> int \{ return \[3,,4\] \}"
    set report [report $root $driver $manifest 0 1]
    located $report E_PARSE_EXPECTED {first 1 28 1 29}

    writeUtf8 [file join $root a.src] {fn .a() -> int => 1 % 2
fn .b() -> int { return [7,,8] }
}
    set items [report $root $driver $manifest 0 2]
    located $items E_PARSE_TOKEN {first 1 21 1 22}
    located $items E_PARSE_EXPECTED {first 2 28 2 29}

    # Pre-scanning a broken choice must not hide a preceding bad character.
    writeUtf8 [file join $root a.src] {fn .a() -> int => 1 % 2
choice .thing { 5 }
# local .thing::case
}
    set items [report $root $driver $manifest 0 2]
    located $items E_PARSE_TOKEN {first 1 21 1 22}
    located $items E_PARSE_EXPECTED {first 2 17 2 18}

    # A failed lookahead can be the head of the next declaration. A complete
    # quoted string with a bad escape has a safe boundary after its close.
    set broken {fn .b() -> int => [7,,8]}
    foreach {prefix expected} [list \
            {% invalid} {{E_PARSE_TOKEN 1 1 1 2} {E_PARSE_EXPECTED 2 22 2 23}} \
            {fn .a() -> int =>} {{E_PARSE_EXPECTED 2 1 2 3} {E_PARSE_EXPECTED 2 22 2 23}} \
            {fn .a() -> text => "bad\q"} {{E_PARSE_ESCAPE 1 24 1 25} {E_PARSE_EXPECTED 2 22 2 23}} \
            {fn .a() -> text => $"bad\q
fn .inside() -> int => [3,,4]"} {{E_PARSE_ESCAPE 1 25 1 26} {E_PARSE_EXPECTED 3 22 3 23}} \
            {fn .a() -> text => "bad\q} {{E_PARSE_ESCAPE 1 24 1 25}}] {
        writeUtf8 [file join $root a.src] "$prefix\n$broken"
        set r [invoke $root $driver --json $manifest]
        set diagnostics [json unwrap [json get [json decode -typed [dict get $r out]] diagnostics]]
        set spans {}
        foreach item $diagnostics {
            set n [dict get $item node]
            lappend spans [list [dict get $item code] {*}[lmap key {line column endLine endColumn} {dict get $n $key}]]
        }
        expect $spans $expected "recover from $prefix"
    }
}

proc ::diagnosticTest::declarationBoundaries {root driver manifest} {
    set intact {export fn .take($s: int) -> int => $s
fn .one() -> int => $missing
fn .two() -> int => 'bad'}
    writeUtf8 [file join $root b.src] {import first
fn .wrong() -> int => .first::take('bad')
fn .typo() -> int => .first::unknown()}
    foreach {bad col} [list "fn .broken() -> int => 1 )\]\}" 26 ")\} \]" 1] {
        writeUtf8 [file join $root a.src] "$bad\n$intact"
        set items [report $root $driver $manifest 0 5]
        located $items E_PARSE_EXPECTED [list first 1 $col 1 [expr {$col + 1}]]
        located $items UNKNOWN_BINDING {first 3 21 3 29}
        located $items RETURN_TYPE {first 4 21 4 26}
        located $items ARGUMENT_TYPE {second 2 36 2 41}
        located $items UNKNOWN_FUNCTION {second 3 22 3 28}
    }

    # A mismatch inside a nested list still leaves the following text uncertain.
    writeUtf8 [file join $root a.src] {fn .broken() -> int { return [1,,2) }
fn .uncertain() -> int => $hidden}
    writeUtf8 [file join $root b.src] {import first
fn .maybe() -> int => .first::uncertain()
fn .known_bad() -> int => 'bad'}
    set items [report $root $driver $manifest 0 2]
    located $items E_PARSE_EXPECTED {first 1 33 1 34}
    located $items RETURN_TYPE {second 3 27 3 32}

    writeUtf8 [file join $root a.src] {export alias .lost =
record .private { x: int }
export alias .normal =
    list<int>
export fn .take($v: .normal) -> int => 7}
    writeUtf8 [file join $root b.src] {import first
fn .priv($v: .first::private) -> int => $v.x
fn .arg() -> int => .first::take('bad')
fn .absent($v: .first::typo) -> int => 0}
    set items [report $root $driver $manifest 0 4]
    located $items E_PARSE_EXPECTED {first 2 1 2 7}
    located $items NOT_EXPORTED {second 2 14 2 29}
    located $items ARGUMENT_TYPE {second 3 34 3 39}
    located $items UNKNOWN_TYPE {second 4 16 4 28}

    writeUtf8 [file join $root a.src] {export fn .take($s: int) -> int => $s}
    writeUtf8 [file join $root b.src] {distinct .lost =
import first
fn .bad() -> int => .first::take('bad')
fn .good() -> int => .first::take(2)}
    set items [report $root $driver $manifest 0 2]
    located $items E_PARSE_EXPECTED {second 2 1 2 7}
    located $items ARGUMENT_TYPE {second 3 34 3 39}

    # "tool" and "example" are ordinary words in expression positions.
    # Their dotted declaration names distinguish these from a continuation.
    writeUtf8 [file join $root a.src] {fn .missing() -> int =>
tool .helper = 'helper.exe'
fn .use() -> result<text,problem> => .helper()}
    writeUtf8 [file join $root b.src] {}
    set items [report $root $driver $manifest 0 1]
    located $items E_PARSE_EXPECTED {first 2 1 2 5}
    writeUtf8 [file join $root a.src] {fn .missing() -> int =>
example .missing() => $typo}
    set items [report $root $driver $manifest 0 2]
    located $items E_PARSE_EXPECTED {first 2 1 2 8}
    located $items UNKNOWN_BINDING {first 2 23 2 28}

    writeUtf8 [file join $root a.src] {}
    writeUtf8 [file join $root b.src] {alias .sample =
    list<text>
distinct .length =
    int
fn .checked($v: .sample, $l: .length) -> int =>
    underlying($l)
fn .two() -> int => 2
example .two() =>
    2}
    report $root $driver $manifest 1 0
}

proc ::diagnosticTest::partialModules {root driver manifest} {
    set first {export fn .before() -> int => $missing_before
export fn .broken() -> int => [1,,2]
example .broken() => 7
export fn .usable($n: int) -> int => $n
fn .local() -> int => .broken()
fn .after() -> int => 'wrong'
export record .damaged { value: }
fn .depends($r: .damaged) -> int => $r.field
fn .private() -> int => 0
fn .misspelled() -> int => .unknown()
fn .unknown_type($v: .wrong) -> int => 7
record .letter { payload: .damaged }
worker .deliver($m: .letter) -> result<.damaged,problem> => err(problem('unavailable'))
resource .damaged using .broken}
    set second {import first
fn .depends() -> int => .first::broken()
fn .takes($r: .first::damaged) -> int => $r.field
fn .argument() -> int => .first::usable('wrong')
fn .access() -> int => .first::private()
fn .healthy() -> int => .first::usable(7)}
    foreach module {first second} file {a.src b.src} {
        writeUtf8 [file join $root $file] [string map [list \n \r\n] [set $module]]
    }
    set r [invoke $root $driver --json $manifest]
    expect [list [dict get $r exit] [dict get $r err]] {1 {}} "partial module structured failure"
    set diagnostics [json unwrap [json get [json decode -typed [dict get $r out]] diagnostics]]
    set positions {}
    set messages {}
    foreach item $diagnostics {
        set code [dict get $item code]
        set where [dict get $item node]
        lassign [lmap key {module line column endLine endColumn} {dict get $where $key}] mod line col endLine endCol
        set row [lindex [split [set $mod] \n] [expr {$line - 1}]]
        lappend positions [list $code $mod $line [string range $row [expr {$col - 1}] [expr {$endCol - 2}]]]
        lappend messages [format {%s:%s:%s..%s:%s [%s] %s} $mod $line $col $endLine $endCol $code [dict get $item message]]
    }
    set expected [list [list E_PARSE_EXPECTED first 2 ,] [list E_PARSE_EXPECTED first 7 \}] \
        [list UNKNOWN_BINDING first 1 {$missing_before}] [list RETURN_TYPE first 6 {'wrong'}] \
        [list UNKNOWN_FUNCTION first 10 .unknown] [list UNKNOWN_TYPE first 11 .wrong] \
        [list ARGUMENT_TYPE second 4 {'wrong'}] [list NOT_EXPORTED second 5 .first]]
    expect [lsort $positions] [lsort $expected] "independent syntax, binding, type, argument and visibility checks with their source spans"
    plain $root $driver $manifest $messages
    set archive [file join $root failed.machteld]
    set packed [::machteld::run -dir $root -timeout 15s -- [info nameofexecutable] $driver pack $manifest $archive]
    expect [list [dict get $packed exit] [file exists $archive]] {1 0} "incomplete declarations produce no archive"
    set ran [::machteld::run -dir $root -timeout 15s -- [info nameofexecutable] $driver run $manifest]
    expect [list [dict get $ran exit] [file exists [file join $root entry-ran]]] {1 0} "partial program cannot run"
    writeUtf8 [file join $root b.src] {}
    writeUtf8 [file join $root a.src] "fn .before() -> int => \$missing\nfn .broken() -> int \{"
    set diagnostics [report $root $driver $manifest 0 2]
    located $diagnostics UNKNOWN_BINDING {first 1 24 1 32}
    writeUtf8 [file join $root b.src] {import first
fn .maybe_in_tail() -> int => .first::possible()
fn .independent($i: int) -> text => $i}
    # An unclosed block hides the remainder of this source. A declaration
    # there could explain a missing symbol, but cannot explain a bad return.
    set diagnostics [report $root $driver $manifest 0 3]
    located $diagnostics RETURN_TYPE {second 3 37 3 39}
    writeUtf8 [file join $root a.src] {fn .edit($n: int) -> int => $n
export fn .edit($s: text) -> text => [1,,2]
fn .local() -> text => .edit('x')}
    writeUtf8 [file join $root b.src] {import first
fn .caller() -> text => .first::edit('x')}
    set diagnostics [report $root $driver $manifest 0 1]
    located $diagnostics E_PARSE_EXPECTED {first 2 41 2 42}
}

proc ::diagnosticTest::run {root driver} {
    set manifest [file join $root project.dict]
    set base [dict create schema 1 edition 1 minApi 0.21 entry {main start} \
        modules {main entry.src first a.src second b.src} assets {extensions/pkgIndex.tcl} packageDirs extensions]
    writeUtf8 $manifest $base
    file mkdir [file join $root extensions]
    writeUtf8 [file join $root extensions pkgIndex.tcl] {
        file mkdir [file join $dir .. index-ran]
        package ifneeded Q57CheckOnly 1.0 {
            namespace eval ::q57 {proc deferred {} {}}
            package provide Q57CheckOnly 1.0
        }
    }
    writeUtf8 [file join $root entry.src] {import first
import second
extern fn .mark() -> unit = ['::file','mkdir','entry-ran']
extern fn .deferred() -> unit = ['::q57::deferred'] from 'Q57CheckOnly'
fn .start($args: list<text>) -> result<unit,problem> {
    .mark()
    return ok(.deferred())
}}
    foreach name {a.src b.src} {writeUtf8 [file join $root $name] {}}
    report $root $driver $manifest 1 0
    plain $root $driver $manifest {}
    foreach marker {entry-ran index-ran} {
        expect [file exists [file join $root $marker]] 0 "check never evaluates $marker"
    }

    # A synthetic entry diagnostic has no token to underline.
    writeUtf8 $manifest [dict replace $base entry {main absent}]
    set diagnostics [report $root $driver $manifest 0 1]
    plain $root $driver $manifest [list [located $diagnostics ENTRY_NAME {main 1 1 1 1}]]
    writeUtf8 $manifest $base

    # Raw CRLF, a supplementary code point and a multiline token distinguish
    # character positions from UTF-8 offsets and Windows UTF-16 code units.
    set first {fn .take($n: int) -> int { return $n }
fn .bad() -> int {
    return .take("雪🚀
fin")
}}
    set second {fn .take($v: text, $n: int) -> int { return $n }
fn .bad() -> int { return .take("雪🚀", $lost) }}
    foreach name {a.src b.src} source [list $first $second] {
        writeUtf8 [file join $root $name] [string map [list \n \r\n] $source]
    }
    set diagnostics [report $root $driver $manifest 0 2]
    set firstLine [located $diagnostics ARGUMENT_TYPE {first 3 18 4 5}]
    set secondLine [located $diagnostics UNKNOWN_BINDING {second 2 39 2 44}]
    plain $root $driver $manifest [list $firstLine $secondLine]
    syntaxRecovery $root $driver $manifest
    partialModules $root $driver $manifest
    declarationBoundaries $root $driver $manifest

    # Project errors have no application source range. Use a dictionary key so
    # even characters that Windows forbids in filenames can reach the reporter.
    set oddKey "unknown\"\\雪🚀\n\t\u0000tail"
    writeUtf8 $manifest [dict replace $base $oddKey 1]
    set diagnostics [report $root $driver $manifest 0 1]
    set invalid [dict get $diagnostics PROJECT_INVALID]
    expect [json type [json get $invalid node]] null "manifest validation location"
    set message [json unwrap [json get $invalid message]]
    set expected "project: unknown manifest key [list $oddKey]"
    expect [encoding convertto utf-8 $message] [encoding convertto utf-8 $expected] \
        "quotes, backslash, Unicode, line breaks, tab and NUL round-trip through JSON"

    set missing [file join $root missing-project.dict]
    set diagnostics [report $root $driver $missing 0 1]
    set io [dict get $diagnostics PROJECT_IO]
    expect [json type [json get $io node]] null "I/O location"
    expect [string match {*missing-project.dict*} [json unwrap [json get $io message]]] 1 "I/O error names its input"
}

set driver [file normalize [file join [file dirname [info script]] .. tools application_project.tcl]]
set root [file normalize [file tempdir]]
try {
    ::diagnosticTest::run $root $driver
} finally {
    foreach relative {project.dict a.src b.src entry.src extensions/pkgIndex.tcl extensions entry-ran index-ran} {
        file delete -- [file join $root $relative]
    }
    file delete -- $root
}
puts "application compiler diagnostics: $::diagnosticTest::count assertions passed"
