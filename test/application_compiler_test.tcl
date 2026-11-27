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
    equal [dict get $compiled sourceMap ::compiled::units::seconds 3 line] 3 "source map return line"
    equal [dict get $compiled sourceMap ::compiled::units::seconds 3 module] units "source map module"

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
    puts "application compiler: $count assertions passed"
}
