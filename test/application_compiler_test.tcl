package require machteld

lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::compilerTest {variable count 0}
proc ::compilerTest::equal {actual expected name} {
    variable count
    if {$actual ne $expected} {
        error "$name: expected [list $expected], got [list $actual]"
    }
    incr count
}
proc ::compilerTest::codes {sources} {
    lmap item [::appcompiler::check $sources] {dict get $item code}
}
namespace eval ::compilerTest {
    set example {export fn .seconds($minutes: int) -> int {
    $factor ::= 60
    return $minutes * $factor
}}
    set sources [dict create units $example main {
import units
fn .compute() -> int {
    $n := 0001
    $N ::= 3
    $n = $n + $N - 2
    return .units::seconds($n)
}
}]
    equal [codes $sources] {} "valid program"
    set compiled [::appcompiler::compile $sources ::compiled]
    equal [namespace exists ::compiled] 0 "checking and compiling do not load the application"
    namespace eval :: [dict get $compiled script]
    equal [::compiled::units::seconds 2] 120 "approved function"
    equal [::compiled::units::seconds 008] 480 "decimal Tcl boundary value"
    foreach invalid {abc 2.5 0x10} {
        equal [catch {::compiled::units::seconds $invalid} message options] 1 "invalid int $invalid"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "boundary type error"
    }
    equal [::compiled::main::compute] 120 "two modules, case-distinct locals, fixed and mutable bindings"
    equal [dict get $compiled sourceMap ::compiled::units::seconds 1 line] 1 "source map argument validation"
    equal [dict get $compiled sourceMap ::compiled::units::@seconds 2 line] 3 "source map return line"
    equal [dict get $compiled sourceMap ::compiled::units::@seconds 2 module] units "source map module"

    set mixed "export fn .label() -> text \{\r\n\treturn '🚆\r雪'\n\}"
    set analyzed [::appcompiler::analyze [dict create mixed $mixed]]
    equal [dict get $analyzed diagnostics] {} "mixed physical line endings"
    set function [lindex [dict get $analyzed modules mixed functions] 0]
    set literal [dict get [lindex [dict get $function body] 0] value]
    equal $literal [dict create module mixed line 2 column 9 endLine 3 endColumn 3 \
        kind text value "🚆\r雪"] "multiline raw literal span and spelling"
    set artifact [::appcompiler::emitChecked $analyzed ::position]
    equal [dict get $artifact sourceMap ::position::mixed::label 1] \
        {module mixed line 2 column 2} "source map after CRLF and a tab"
    set bad [string map [list {雪'} {雪'  @}] $mixed]
    set diagnostic [lindex [::appcompiler::check [dict create mixed $bad]] 0]
    equal [dict get $diagnostic code] E_PARSE_TOKEN "unexpected character after raw text"
    equal [dict get $diagnostic node] {module mixed line 3 column 5 endLine 3 endColumn 6} \
        "invalid token span after a multiline literal and horizontal space"

    set calls [dict create library {
export fn .countdown($n: int) -> int {
    if $n == 0 { return 0 }
    return .countdown($n - 1)
}
export fn .id<.t>($v: .t) -> .t => $v
export record .holder { items: list<ref<int>> }
export fn .ignore($x: .holder) -> int => 9
export fn .sum($n: int) -> int => $n
export fn .callback() -> callable<int,int> => .sum
extern fn .host_value() -> int = ['::compilerTest::hostValue']
export fn .from_host() -> int => .sum(.host_value())
} client {
import library
export fn .start($n: int) -> int => .library::countdown(.library::id($n))
fn .stale() -> ref<int> {
    using $r ::= ref(1) {return $r}
}
export fn .expired() -> int => .library::ignore(make<.library::holder>(items: [.stale()]))
export fn .generic_expired() -> ref<int> => .library::id(.stale())
}]
    set callsArtifact [::appcompiler::compile $calls ::calls]
    namespace eval :: [dict get $callsArtifact script]
    set guards {}
    proc recordGuard {command operation} {lappend ::compilerTest::guards [lindex $command 3]}
    trace add execution ::calls::@rt::guard enter ::compilerTest::recordGuard
    try {
        equal [::calls::client::start 0008] 0 "recursive exported calls and concrete generic cross-module calls"
        equal $guards {{$n}} "normalize once at the Tcl entry and never again during direct recursion"
        equal [::calls::library::id int 008] 8 "generic Tcl entry normalizes its supplied value"
        equal [catch {::calls::library::id invalid 0} msg options] 1 "generic Tcl entry checks descriptors"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "invalid generic descriptor code"
        foreach caller {expired generic_expired} {
            equal [catch {::calls::client::$caller} msg options] 1 "$caller rejects a reference that expired earlier"
            equal [dict get $options -errorcode] {APPCOMPILER REFERENCE EXPIRED} "$caller retains the boundary error"
        }
        set callback [::calls::library::callback]
        equal [catch {{*}$callback bad} msg options] 1 "Tcl callback argument checks survive direct calls to the same target"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "callback argument error code"
        proc hostValue {} {return bad}
        equal [catch {::calls::library::from_host} msg options] 1 "extern result checked before direct call"
        equal [dict get $options -errorcode] {APPCOMPILER EXTERN RESULT} "extern result error code"
    } finally {
        trace remove execution ::calls::@rt::guard enter ::compilerTest::recordGuard
    }

    set fixed [string map [list {return $minutes} "\$factor = 30\n    return \$minutes"] $example]
    set reports [::appcompiler::check [dict create scale $fixed]]
    equal [llength $reports] 1 "one independent error"
    set item [lindex $reports 0]
    equal [dict get $item code] FIXED_ASSIGNMENT "fixed assignment is rejected"
    equal [dict get $item node line] 3 "fixed assignment line"
    equal [dict get $item node column] 5 "fixed assignment column"
    equal [dict get $item node module] scale "logical source name"
    set broken [string map [list {return $minutes * $factor} {return '120'}] $example]
    equal [codes [dict create units $broken]] RETURN_TYPE "text cannot satisfy an integer result"
    equal [codes [dict create units [string map [list {$minutes *} {$Minutes *}] $example]]] \
        UNKNOWN_BINDING "accidental capitalization"
    equal [catch {::appcompiler::compile [dict create units $fixed] ::broken} message options] \
        1 "compile refuses an invalid program"
    equal [dict get $options -errorcode] {APPCOMPILER CHECK} "structured compiler error"
    equal [dict get [lindex [dict get $options -diagnostics] 0] code] FIXED_ASSIGNMENT \
        "compile and check return the same diagnostic"
    equal [namespace exists ::broken] 0 "failed compile has no application side effects"

    set both [dict create scale $fixed bad $broken]
    equal [lsort [codes $both]] {FIXED_ASSIGNMENT RETURN_TYPE} "independent semantic diagnostics"
    equal [codes [dict create math {} Math {}]] MODULE_CASE_COLLISION "module case collision"
    equal [codes [dict create math {} use "import Math"]] UNKNOWN_MODULE "exact import spelling"
    equal [codes [dict create math {} café {}]] MODULE_NAME "ASCII module name"
    equal [codes [dict create units $example other {fn .go() -> int {return .units::seconds(1)}}]] \
        MISSING_IMPORT "qualified calls require an import"
    set private [string map [list {export fn} fn] $example]
    equal [codes [dict replace $sources units $private]] NOT_EXPORTED "private declaration"
    equal [codes [dict create m {fn .a() -> int {return .b(1)}
fn .b() -> int {return 1}}]] CALL_ARITY "forward declaration and arity"
    equal [codes [dict create m {fn .x() -> bool {}}]] MISSING_RETURN "missing return"
    equal [expr {[llength [codes [dict create m {fn .é() -> int {return 1}}]]] > 0}] \
        1 "reject Unicode identifier"
    set malformed [dict create a {fn .a() -> int { return [clock] }} b {fn}]
    equal [llength [codes $malformed]] 2 "independent parse errors"
    set mixed [dict create broken {fn} use {import broken
fn .bad() -> int {return 'bad'}
fn .waiting() -> int {return .broken::unknown()}}]
    equal [lsort [codes $mixed]] {E_PARSE_EXPECTED RETURN_TYPE} \
        "a broken imported module suppresses only its dependent diagnostics"

    # Data that resembles Tcl source must survive code generation and loading.
    set payload [format {007 $hidden [error boom]; \%c%s%s} 125 \n \u263a]
    set quoting [dict create data [format {export fn .get() -> text {return '%s'}} $payload]]
    set code [dict get [::appcompiler::compile $quoting ::literal] script]
    namespace eval :: $code
    equal [::literal::data::get] $payload "literal text stays inert and preserves spelling"
    set numbers {fn .n() -> int {return (009 + 1) * 99999999999999999999999999999}}
    namespace eval :: [dict get [::appcompiler::compile [dict create n $numbers] ::exact] script]
    equal [::exact::n::n] 999999999999999999999999999990 "exact decimal integer arithmetic"

    set model {export record .item {
    id: text
    note: text?
}
export choice .edit {
    keep
    clear
    set(text)
}
export fn .apply($item: .item, $edit: .edit) -> .item {
    return match $edit {
        .edit::keep       => $item
        .edit::clear      => $item with { note = none }
        .edit::set($text) => $item with { note = some($text) }
    }
}}
    set client {import model
export fn .change($item: .model::item, $edit: .model::edit) -> .model::item {
    return .model::apply($item, $edit)
}
export fn .read_note($item: .model::item) -> text? {return $item.note}}
    set project [dict create entry $client model $model]
    equal [codes $project] {} "two-module record and closed choice"
    set emitted [::appcompiler::compile $project ::typed]
    namespace eval :: [dict get $emitted script]
    set input [dict create id 007 note [list some old] future [dict create extraKey "mémo"]]
    equal [::typed::entry::change $input keep] $input "keep every field"
    set cleared [::typed::entry::change $input clear]
    equal [dict get $cleared note] none "clear the optional"
    set setEmpty [::typed::entry::change $input [list set {}]]
    equal [dict get $setEmpty note] [list some {}] "present empty differs from absent"
    equal [dict get $setEmpty id] 007 "text identifier preserves leading zeros"
    equal [dict get $setEmpty future] [dict get $input future] "unknown nested data survives"
    equal [dict get $input note] {some old} "record updates have value semantics"
    set missing [dict remove $input note]
    equal [::typed::entry::change $missing keep] $missing "keep an omitted optional field"
    equal [::typed::entry::read_note $missing] none "absent optional read"
    equal [::typed::entry::read_note $setEmpty] [list some {}] "present empty optional read"
    equal [catch {::typed::entry::change $input {set}}] 1 "ill-shaped external choice"
    equal [catch {::typed::entry::change [dict create note none] keep}] 1 "missing required field"
    equal [catch {::typed::entry::change [dict replace $input note unexpected] keep}] 1 \
        "strict optional at Tcl boundary"

    set typo [string map [list {note = some} {notes = some}] $model]
    set mistakes [::appcompiler::check [dict replace $project model $typo]]
    set mistake [lindex $mistakes 0]
    equal [dict get $mistake code] UNKNOWN_FIELD "misspelled record field"
    equal [dict get $mistake node line] 14 "field diagnostic in original module"
    equal [dict get $mistake node module] model "field diagnostic source identity"
    equal [expr {[string first "notes" [dict get $mistake message]] >= 0
        && [string match {*declared fields:*note*} [dict get $mistake message]]}] \
        1 "field diagnostic lists the declared alternatives"
    equal [expr {[dict get $mistake node endColumn] - [dict get $mistake node column]}] \
        5 "field diagnostic underlines only the invalid name"
    set dropped [regsub -line {^ *\.edit::clear[^\n]*\n} $model {}]
    equal [codes [dict replace $project model $dropped]] MATCH_NONEXHAUSTIVE "missing choice variant"
    set unrelated {record .first { id: text }
record .second { id: text }
fn .mix($one: .first) -> .second { return $one }}
    equal [codes [dict create types $unrelated]] RETURN_TYPE "same-shaped records are nominal"
    puts "application compiler: $count assertions passed"
}
