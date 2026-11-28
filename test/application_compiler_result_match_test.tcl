package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::resultMatchTest {
    variable checks 0
    variable sources [dict create catalog {export choice .failure {
    missing
    held(text)
}
export alias .lookup = result<text,.failure>
export fn .read($name: text) -> .lookup {
    if $name == '' { return err(.failure::missing()) }
    if $name == 'hold' { return err(.failure::held('review')) }
    return ok($name)
}
} client {import catalog
export fn .report($name: text) -> text => match .catalog::read($name) {
    err($reason) => match $reason {
        .catalog::failure::held($why) => $"pending: $why"
        .catalog::failure::missing => 'unavailable'
    }
    ok($value) => $value
}
example .report('') => 'unavailable'
example .report('hold') => 'pending: review'
example .report('007') => '007'
export fn .merged<.t>($r: result<.t,.t>) -> .t => match $r {
    ok($item) | err($item) => $item
}
export fn .nested($r: result<text?,int>) -> text => match $r {
    ok($item) => match $item { none => 'unset'
        some($value) => $value }
    err(_) => 'failed'
}
export fn .propagate($name: text) -> .catalog::lookup {
    $found ::= .catalog::read($name)?
    return ok($found)
}
fn .main($args: list<text>) -> result<unit,problem> => match $args {
    [$name] => write_stdout_utf8(.report($name))
    _ => err(problem('expected one name'))
}
}]
}

proc ::resultMatchTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::resultMatchTest::direct {} {
    variable sources
    equal [::appcompiler::check $sources] {} "typed local handling checks"
    set artifact [::appcompiler::compile $sources ::resultApp]
    set child [interp create]
    try {
        $child eval [dict get $artifact script]
        $child eval {
            set ::reads 0
            proc ::observed {args} {incr ::reads}
            trace add execution ::resultApp::catalog::read enter ::observed
        }
        foreach {name expected} {007 007 {} unavailable hold {pending: review}} {
            equal [$child eval [list ::resultApp::client::report $name]] $expected "cross-module lookup '$name'"
        }
        equal [$child eval {set ::reads}] 3 "evaluate each matched lookup once"
        foreach {type input expected} {
            text {ok 007} 007
            text {err 007} 007
            int {ok 007} 7
            list<text> {err {one 007}} {one 007}
        } {
            equal [$child eval [list ::resultApp::client::merged $type $input]] $expected "generic shared payload $input"
        }
        foreach {input expected} {
            {ok {some 007}} 007
            {ok none} unset
            {err 42} failed
        } {
            equal [$child eval [list ::resultApp::client::nested $input]] $expected "nested optional vs error"
        }
        equal [$child eval {::resultApp::client::propagate hold}] {err {held review}} "unhandled typed error still propagates"
        equal [$child eval {::resultApp::client::propagate 007}] {ok 007} "success after propagation"
        equal [$child eval {catch {::resultApp::client::nested {ok}}}] 1 "Tcl guard rejects malformed result"
    } finally {interp delete $child}
}

proc ::resultMatchTest::armValues {} {
    set source {extern fn .tap($v:text) -> text = ['::tap']
export fn .first($keys:list<text>, $values:list<text>) -> map<text,text> {
    $out := map<text,text>()
    $i := 0
    for $key in $keys {
        $out = match $out[.tap($key)] {
            some($saved) => $out
            none => map_put($out, .tap($key), match $values[$i] {
                some($v) => .tap($v)
                none => .tap('absent') })
        }
        $i = $i + 1
    }
    return $out
}
export fn .nested($select:result<text,text>,$xs:list<text>) -> list<text> {
    $value ::= match $select {
        ok($v) => match $xs { [$x] => .tap($x)
            _ => .tap($v) }
        err($v) => match $xs { _ => .tap($v) }
    }
    return [$value,.tap('after')]
}
export fn .blank($key:text?) -> list<text> => [match $key {
    none => ''
    some($v) => .tap($v) }, .tap('after')]
}
    set app [interp create]
    try {
        $app eval [dict get [::appcompiler::compile [dict create select $source] ::selection] script]
        $app eval {
            proc tap v {
                lappend ::events $v
                if {$v eq {fail}} {return -code error -errorcode {FIXTURE ARM} -detail evidence rejected}
                return $v
            }
            set ::events {}
        }
        set k "key\u0000\U0001F686"
        set v [::machteld::json decode -typed 17]
        set out [$app eval [list ::selection::select::first [list $k $k other missing] [list $v fail -code]]]
        equal [dict keys $out] [list $k other missing] {ordered first occurrence index}
        equal [dict values $out] [list $v -code absent] {first value and missing input payload}
        equal [::machteld::json type [dict get $out $k]] number {selected value retains its native type}
        equal [::machteld::json type $v] number {caller retains its native value}
        equal [$app eval {set ::events}] [list $k $k $v $k other other -code missing missing absent] {ordered lookup, selected arm and operand effects}
        foreach {choice items first} [list {ok fallback} [list $v] $v {ok fallback} {x y} fallback {err -level} {} -level] {
            $app eval {set ::events {}}
            set results [$app eval [list ::selection::select::nested $choice $items]]
            equal $results [list $first after] {an arm produces its value and later statements run}
            equal [$app eval {set ::events}] $results {only the selected nested arms run}
        }
        $app eval {set ::events {}}
        equal [$app eval {::selection::select::blank none}] [list {} after] {an empty arm supplies its result}
        equal [$app eval {set ::events}] after {later operand runs after the empty arm}
        set status [catch {$app eval [list ::selection::select::nested {ok safe} {fail}]} msg options]
        equal [list $status $msg [dict get $options -errorcode] [dict get $options -detail]] {1 rejected {FIXTURE ARM} evidence} {an arm propagates the original Tcl error}
        equal [dict get $options -appcompilerlocation] {module select line 1 column 36} {failing extern retains its source location}
        # The returned arm value may itself be a collection assigned back to
        # its base in a loop. An extra result local would keep the previous
        # dictionary shared and force a whole copy at every distinct key.
        equal [string match {*::set m_result *} [$app eval {info body ::selection::select::first}]] 0 {arm results are not retained in a scratch local}
    } finally {interp delete $app}
}

proc ::resultMatchTest::reject {signature arms code token} {
    set source [format {fn .bad($r: %s) -> text => match $r {
    %s
}} $signature $arms]
    set ds [::appcompiler::check [dict create bad $source]]
    equal [lmap d $ds {dict get $d code}] [list $code] "$code in $arms"
    set node [dict get [lindex $ds 0] node]
    set line [lindex [split $source \n] [expr {[dict get $node line]-1}]]
    equal [string range $line [expr {[dict get $node column]-1}] [expr {[dict get $node column]+[string length $token]-2}]] \
        $token "$code selects the source token"
}

proc ::resultMatchTest::diagnostics {} {
    foreach {arms code token} {
        {ok($v) => $v} MATCH_NONEXHAUSTIVE match
        {err(_) => 'error'} MATCH_NONEXHAUSTIVE match
        {ok($v) => $v
    ok(_) => 'duplicate'
    err(_) => 'error'} DUPLICATE_ARM ok
        {ok($v) => $v
    err() => 'error'} PATTERN_ARITY err
        {ok($v) => $v
    err($a,$b) => 'error'} PATTERN_ARITY err
        {ok($v) | err($v) => 'both'} PATTERN_BINDING_TYPE {$v}
        {ok($a) | err($b) => 'both'} PATTERN_BINDINGS {$b}
        {ok($v) => $v
    some(_) => 'wrong family'} PATTERN_TYPE some
        {_ => 'too broad'} PATTERN_TYPE _
    } {reject result<text,int> $arms $code $token}
    reject text? {ok(_) => 'invalid'
    none => 'none'} PATTERN_TYPE ok
    reject result<text,int> {ok($v) => $v
    err($e) => $e} MATCH_ARM_TYPE {$e}
}

proc ::resultMatchTest::packed {} {
    variable sources
    set tmp [file normalize [file tempdir]]
    try {
        set author [file join $tmp source]
        file mkdir $author
        set manifest [file join $author project.dict]
        ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {client main} modules {client client.src catalog catalog.src}}
        dict for {module source} $sources {
            ::appcompiler::project::stageBytes [file join $author $module.src] [encoding convertto utf-8 $source]
        }
        set relocated [file join $tmp delivery]
        file mkdir $relocated
        set host [file join $relocated machteld.exe]
        file copy -- [info nameofexecutable] $host
        set archive [file join $relocated catalog.machteld]
        ::appcompiler::project::pack $manifest $archive
        file rename -- $author [file join $tmp retired]
        foreach {name expected} {007 007 {} unavailable hold {pending: review}} {
            set run [::machteld::run -dir $relocated -timeout 30s -- $host $archive $name]
            equal [dict get $run exit] 0 "packed lookup '$name': [dict get $run err]"
            equal [dict get $run out] $expected "packed recovered result '$name'"
        }
    } finally {file delete -force -- $tmp}
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::resultMatchTest::direct
::resultMatchTest::diagnostics
::resultMatchTest::armValues
if {$argv eq "-pack"} {::resultMatchTest::packed}
puts "application compiler result matching: $::resultMatchTest::checks assertions passed"
