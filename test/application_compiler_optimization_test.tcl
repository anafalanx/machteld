package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

# Black-box results and observable effects. Keep these independent of which
# Tcl spelling or runtime helper the generator uses.
namespace eval ::optimizationTest {
    variable checks 0
    variable history {}
    variable source {alias .count = int
distinct .identifier = text
record .cell<.t> { values: list<.t?> }
choice .event { empty
    counted(.cell<int>) }
extern fn .mark($label: text, $n: int) -> int = ['::optimizationTest::mark']
extern fn .mark_text($label: text, $value: text) -> text = ['::optimizationTest::note']
export fn .marked_text($a: text, $b: text) -> bool => .mark_text('first', $a) != .mark_text('second', $b)

export fn .values($a: .count, $b: int) -> list<bool> => [
    $a == $b, $a != $b, !($a == $b),
    $a + 1 == $b + 1, ($a - $b) * ($b - $a) != 0]
export fn .control($a: int, $b: int) -> int {
    $score := 0
    if $a == $b { $score = $score + 1 }
    if $a != $b { $score = $score + 2 }
    while $score < 4 && $a != $b { $score = $score + 1 }
    return $score
}
export fn .indices($values: list<int>, $needle: int) -> list<int> {
    $matches := list<int>()
    $i := 0
    for $v in $values {
        if $v == $needle { $matches = list_append($matches, $i) }
        $i = $i + 1
    }
    return $matches
}
export fn .crossings($events: list<text>, $threshold: int) -> list<text> {
    $hits := list<text>()
    $counts := map<text,int>()
    for $key in $events {
        $prior ::= match $counts[$key] { some($n) => $n
            none => 0 }
        $next ::= $prior + 1
        $counts = map_put($counts, $key, $next)
        if $next == $threshold { $hits = list_append($hits, $key) }
    }
    return $hits
}
export fn .ordered($a: int, $b: int) -> bool =>
    .mark('first', $a) != .mark('second', $b) && .mark('third', $b) == $b
export fn .checked($left_divisor: int, $right_divisor: int) -> result<bool,problem> =>
    ok(quotient(12, .mark('left', $left_divisor))? == quotient(18, .mark('right', $right_divisor))?)
export fn .mixed($a: int, $b: decimal) -> list<bool> => [$a == $b, $a != $b]
}
}

proc ::optimizationTest::wordCounts {} {
    set events [list {} 007 7 "a\0b" a A 007 {} "a\0b" 7 a {} "a\0b" 007 007]
    foreach sequence [list {} $events [lreverse $events] [concat $events $events]] {
        foreach threshold {0 1 2 3 4 8 9} {
            set counts {}
            set expected {}
            foreach key $sequence {
                dict incr counts $key
                if {[dict get $counts $key] == $threshold} {lappend expected $key}
            }
            expect [::optApp::model::crossings $sequence $threshold] $expected \
                "ordered frequency crossings over [llength $sequence] keys at $threshold"
        }
    }
}

proc ::optimizationTest::expect {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::optimizationTest::discardEvidence {} {
    variable discardLog
    variable discardFault
    lappend discardLog fetch
    if {$discardFault} {return -code error -errorcode {TEST EVIDENCE} unavailable}
    variable witness [::machteld::json decode -typed {{"retained":[17]}}]
    return $witness
}

proc ::optimizationTest::observeEvidence {} {
    variable discardLog
    variable witness
    lappend discardLog observe
    if {![regexp {refcount of ([0-9]+)} [::tcl::unsupported::representation $witness] -> owners]} {
        error "unable to inspect retained evidence"
    }
    return $owners
}

proc ::optimizationTest::openEvidence {} {
    return {ok opened}
}

proc ::optimizationTest::closeEvidence {handle} {
    variable ownersAtClose [observeEvidence]
    return {}
}

proc ::optimizationTest::discardedValues {} {
    variable discardLog
    variable discardFault 0
    set script {distinct .handle = text
resource .handle using .close
extern fn .open() -> result<.handle,problem> = ['::optimizationTest::openEvidence']
extern fn .close($handle:.handle) -> unit = ['::optimizationTest::closeEvidence']
extern fn .fetch() -> text = ['::optimizationTest::discardEvidence']
extern fn .owners() -> int = ['::optimizationTest::observeEvidence']
export fn .observe() -> int => .owners()
export fn .discard() -> int {
    .fetch()
    return .owners()
}
export fn .scoped() -> result<int,problem> {
    using $handle ::= .open()? { .fetch() }
    return ok(.owners())
}}
    set app [::appcompiler::compile [dict create discard $script] ::optDiscard]
    namespace eval :: [dict get $app script]
    discardEvidence
    set withoutOperand [::optDiscard::discard::observe]
    set discardLog {}
    expect [::optDiscard::discard::discard] $withoutOperand {a discarded return value has no remaining compiler owner}
    expect $discardLog {fetch observe} {discarded operation runs exactly once before the observer}
    expect [::machteld::json type $::optimizationTest::witness] object {the caller still owns its typed evidence}
    set discardLog {}
    expect [::optDiscard::discard::scoped] [list ok $withoutOperand] {a scope releases its completed statement}
    expect $::optimizationTest::ownersAtClose $withoutOperand {the resource closer sees no discarded body value}
    expect $discardLog {fetch observe observe} {the closer runs once before the caller resumes}
    set discardFault 1
    set discardLog {}
    set code [catch {::optDiscard::discard::discard} message options]
    expect $code 1 {an error in a discarded expression propagates}
    expect [list $message [dict get $options -errorcode] $discardLog] {unavailable {TEST EVIDENCE} fetch} \
        {a failing discarded call keeps its diagnostic and prevents later effects}
    unset ::optimizationTest::witness
}

proc ::optimizationTest::mark {label n} {
    variable history
    lappend history $label
    return $n
}

proc ::optimizationTest::integerCases {} {
    # Expected identities use known decimal spellings. Tcl expr would treat
    # some of the deliberately noncanonical inputs as octal or reject them.
    set cases {0 0 -000 0 +000 0 1 1 -1 -1 007 7 7 7 +0008 8 8 8 -08 -8}
    foreach bits {31 53 63 64 128 257} {
        set limit [expr {1 << $bits}]
        foreach n [list [expr {$limit-1}] $limit [expr {$limit+1}] -$limit] {
            lappend cases $n $n
        }
    }
    foreach {left a} $cases {
        foreach {right b} $cases {
            set same [string equal $a $b]
            set different [expr {!$same}]
            expect [::optApp::model::values $left $right] \
                [list $same $different $different $same $different] "integer values ($left, $right)"
            expect [::optApp::model::control $left $right] [expr {$same ? 1 : 4}] "integer branches ($left, $right)"
        }
    }
    foreach bad [list {} 0x10 1e2 3.5 NaN false {1 + 1} {[error boom]}] {
        foreach pair [list [list $bad 0] [list 0 $bad]] {
            expect [catch {::optApp::model::values {*}$pair} message options] 1 "invalid integer $pair"
            expect [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "integer boundary $pair"
        }
    }
    set spellings {}
    set canonical {}
    foreach {wire value} $cases {lappend spellings $wire; lappend canonical $value}
    foreach sequence [list {} {0} {8 +0008 7 -08 +0008} $spellings] \
            oracle [list {} {0} {8 8 7 -8 8} $canonical] {
        foreach {wire value} $cases {
            expect [::optApp::model::indices $sequence $wire] [lsearch -all -exact $oracle $value] \
                "index collection over [llength $sequence] items for $wire"
        }
    }
}

proc ::optimizationTest::evaluation {} {
    variable history
    variable source
    foreach {left right expected calls} {7 007 0 {first second} -8 8 1 {first second third}} {
        set history {}
        expect [::optApp::model::ordered $left $right] $expected "short-circuit result ($left, $right)"
        expect $history $calls "short-circuit effects ($left, $right)"
    }
    set expression [lsearch -inline -glob [split $source \n] {*ok(quotient(12*}]
    set line [expr {1 + [lsearch -exact [split $source \n] $expression]}]
    foreach {left right outcome calls} {2 3 1 {left right} 3 3 0 {left right}
        0 3 left left 2 0 right {left right} 0 0 left left} {
        set history {}
        set result [::optApp::model::checked $left $right]
        expect $history $calls "operand order and multiplicity ($left, $right)"
        if {$outcome in {0 1}} {
            expect $result [list ok $outcome] "integer results inside equality ($left, $right)"
        } else {
            lassign $result tag problem
            expect [list $tag [dict get $problem code]] {err DIVIDE_BY_ZERO} "first failure ($left, $right)"
            set origin [dict get $problem origin]
            set question [expr {$outcome eq "left" ? [string first ? $expression] : [string last ? $expression]}]
            expect [list [dict get $origin module] [dict get $origin line] [dict get $origin column]] \
                [list model $line [expr {$question+1}]] "first failure source ($left, $right)"
        }
    }
}

proc ::optimizationTest::otherTypes {} {
    variable history
    foreach {a b same} {17 18 0 17 17 1 {{"a":true}} {[true]} 0 {"A"} {"a"} 0} {
        set left [::machteld::json decode -typed $a]
        set right [::machteld::json decode -typed $b]
        expect [::optApp::model::text $left $right] [list $same [expr {!$same}]] "compare borrowed text spellings"
        expect [::machteld::json encode -- $left] $a "text comparison retains the left handle"
        expect [::machteld::json encode -- $right] $b "text comparison retains the right handle"
    }
    set wire [::machteld::json unwrap [::machteld::json decode -typed {"snow\u0000\u96ea\ud83d\ude80\u0000"}]]
    set local "snow\0雪\U0001f680\0"
    foreach {left right wanted} [list $wire $local 1 $local $wire 1 $wire "$local!" 0 "snow" $wire 0 \
            "A" "a" 0 {} "\0" 0 "e\u0301" "é" 0 "\U00010fff" "\U00010ffe" 0] {
        set expected [list $wanted [expr {!$wanted}]]
        expect [::optApp::model::text $left $right] $expected "text equality preserves native and Tcl spellings"
        expect [::optApp::model::identifier $left $right] $expected "distinct text has the same equality semantics"
        expect [::optApp::model::optional [list some $left] [list some $right]] $expected "nested text has the same equality semantics"
    }
    set history {}
    expect [::optApp::model::marked_text $wire $local] 0 "text operands are compared once"
    expect $history {first second} "text operands retain their evaluation order"
    set counted [list counted [dict create values {{some +008} none}]]
    set sameCount [list counted [dict create values {{some 8} none}]]
    set reordered [list counted [dict create values {none {some 8}}]]
    foreach {name left right expected} [list \
        text 007 7 0 text "a\0b" "a\0b" 1 text "e\u0301" "\u00e9" 0 \
        identifier 007 7 0 identifier 007 007 1 bool false 0 1 bool 1 0 0 \
        decimal 1.0000000 1 1 decimal 9007199254740992.0001 9007199254740992 0 \
        mixed 9007199254740992 9007199254740992.0001 0 mixed 007 7.00 1 \
        binary64 -0.0 0 1 binary64 1 1.0000000000000002 0 \
        stamp 2000-01-01T00:00:00.000000000Z 2000-01-01T00:00:00.000000000Z 1 \
        wall 2000-01-01T00:00:00 2000-01-01T00:00:00.000000001 0 \
        optional none {some {}} 0 optional {some 007} {some 7} 0 \
        mapping {007 01 7 2} {7 2 007 1} 1 mapping {007 01 7 2} {7 1 007 2} 0 \
        event $counted $sameCount 1 event $counted $reordered 0 event empty $counted 0] {
        expect [::optApp::model::$name $left $right] [list $expected [expr {!$expected}]] "$name ($left, $right)"
    }
}

proc ::optimizationTest::note {tag value} {
    variable history
    lappend history $tag
    return $value
}

proc ::optimizationTest::updateHook {} {}
proc ::optimizationTest::updateValue {} {
    variable history
    lappend history extern
    return [lindex $history 0]
}
proc ::optimizationTest::installUpdateTraces {mode base key item cmd op} {
    if {$mode in {missing array linked}} {
        uplevel 1 [list unset $base]
        if {$mode eq "array"} {uplevel 1 [list array set $base {live yes}]}
        if {$mode eq "linked"} {uplevel 1 [list upvar #0 ::optimizationTest::cells(bound) $base]}
    }
    foreach local [list $base $key $item] label {base key item} {
        if {$local ne {} && $mode ni {missing array}} {
            uplevel 1 [list trace add variable $local read [list ::optimizationTest::updateRead $mode $label $base]]
        }
    }
    if {$mode eq "list"} {
        uplevel 1 [list trace add variable $base write [list apply {{name index op} {lappend ::optimizationTest::history write}}]]
    }
}
proc ::optimizationTest::updateRead {mode label base name index op} {
    variable history
    lappend history $label
    if {$mode eq "throw" && $label eq "base"} {error "first operand failed"}
    if {$label eq "key" && $mode in {replace unset changeType}} {
        upvar 1 $base dest
        switch $mode {
            replace {set dest {different yes}}
            unset {unset dest}
            changeType {unset dest; array set dest {live yes}}
        }
    }
}

proc ::optimizationTest::collectionUpdates {} {
    variable history
    variable cells
    set source {extern fn .hook() -> unit = ['::optimizationTest::updateHook']
extern fn .value() -> text = ['::optimizationTest::updateValue']
export fn .append($seed:list<text>) -> list<text> {
    $out := $seed
    .hook()
    $out = list_append($out, .value())
    return $out
}
export fn .put($seed:map<text,text>, $key:text, $item:text) -> map<text,text> {
    $out := $seed
    .hook()
    $out = map_put($out, $key, $item)
    return $out
}}
    set artifact [::appcompiler::compile [dict create edit $source] ::collectionUpdates]
    namespace eval :: [dict get $artifact script]
    set prefix ::collectionUpdates::edit
    set base [::appcompiler::emitLocalName out]
    set key [::appcompiler::emitLocalName key]
    set item [::appcompiler::emitLocalName item]
    set old [::machteld::json decode -typed {{"old":true}}]
    set new [::machteld::json decode -typed {[1]}]
    set nul "7\u0000key"
    set seed [dict create $nul $old other keep]
    foreach mode {list replace unset throw missing array changeType linked} {
        set history {}
        set cells(bound) $seed
        set fields [expr {$mode eq "list" ? [list {} {}] : [list $key $item]}]
        set hook [list ::optimizationTest::installUpdateTraces $mode $base {*}$fields]
        trace add execution ${prefix}::hook enter $hook
        try {
            if {$mode eq "list"} {
                expect [${prefix}::append old] {old base} "append reads its base before the extern"
                expect $history {base extern write base} "append observes the source and stores its result once"
            } elseif {$mode in {throw missing array changeType}} {
                set code [catch {${prefix}::put $seed $nul $new} message opts]
                expect $code 1 "map assignment fails when the destination is $mode"
                set access [expr {$mode eq "changeType" ? "WRITE" : "READ"}]
                expect [dict get $opts -errorcode] [list TCL $access VARNAME] "preserve the $mode variable error"
                set path [::collectionUpdates::@rt::mappedLocation $opts [::collectionUpdates::@rt::sourceMap]]
                expect $path {module edit line 12 column 5} "map assignment identifies the failing source statement"
                if {$mode eq "throw"} {expect $history base "a failing base read precedes the key and value"}
            } else {
                set out [${prefix}::put $seed $nul $new]
                expect [dict keys $out] [dict keys $seed] "map update preserves the captured keys under $mode"
                expect [::machteld::json type [dict get $out $nul]] array "new member remains typed"
                expect [::machteld::json type [dict get $seed $nul]] object "old member remains typed"
                if {$mode eq "replace"} {expect $history {base key item base} "map reads base, key, item in source order"}
                if {$mode eq "linked"} {
                    expect [::machteld::json type [dict get $cells(bound) $nul]] array "commit writes to the linked array element"
                }
            }
        } finally {trace remove execution ${prefix}::hook enter $hook}
    }
    unset cells(bound)
}


proc ::optimizationTest::matchedLookups {} {
    variable history
    set source {extern fn .items($v: list<text>) -> list<text> = ['::optimizationTest::note','items']
extern fn .index($i: int) -> int = ['::optimizationTest::note','index']
extern fn .miss() -> text = ['::optimizationTest::note','miss','absent']
extern fn .hit($v: text) -> text = ['::optimizationTest::note','hit']
export fn .item($v: list<text>, $i: int) -> text => match .items($v)[.index($i)] {
    none => .miss()
    some($x) => .hit($x)
}
export fn .nested($rows: list<list<text>>, $indices: list<int>, $i: int) -> text =>
    match $rows[match $indices[$i] {some($j) => $j
        none => -1}] {some($row) => match $row[0] {some($value) => $value
            none => .miss()}
        none => .miss()}
export fn .key($m: map<text,text>, $k: text) -> text =>
    match $m[$k] {some($x) => $x
        none => 'absent'}
export fn .key_lazy($m: map<text,text>, $k: text) -> text =>
    match $m[$k] {none => .miss()
        some($x) => .hit($x)}
export fn .has($m: map<int,text?>, $i: int) -> bool =>
    match $m[$i] {some(_) => true
        none => false}
export fn .propagated($v: list<text>, $n: int) -> result<text,problem> =>
    ok(match .items($v)[quotient(12, $n)?] {some($x) => .hit($x)
        none => .miss()})}
    set built [::appcompiler::compile [dict create lookups $source] ::optLookup]
    namespace eval :: [dict get $built script]
    foreach {i wanted calls} [list 0 {} {items index hit} 1 007 {items index hit} \
            2 absent {items index miss} -1 absent {items index miss} \
            [expr {1 << 200}] absent {items index miss} [expr {-(1 << 200)}] absent {items index miss}] {
        set history {}
        expect [::optLookup::lookups::item {{} 007} $i] $wanted "optional lookup at $i"
        expect $history $calls "base and index are reached once, in order; only the selected arm runs"
    }
    foreach {i wanted} {0 007 1 absent 2 absent 3 absent} {
        expect [::optLookup::lookups::nested {{first} {007} {}} {1 2 7} $i] $wanted "nested lookup slots at $i"
    }
    set raw [::machteld::json decode -typed {{"a\u0000b":0}}]
    set wireKey [lindex [dict keys [::machteld::json unwrap $raw]] 0]
    set local "a\0b"
    set map [dict create $local 007 a {}]
    foreach {key wanted effect} [list $wireKey 007 hit a {} hit missing absent miss] {
        set history {}
        expect [::optLookup::lookups::key $map $key] $wanted "constant lookup default"
        expect [::optLookup::lookups::key_lazy $map $key] $wanted "dynamic lookup default"
        expect $history $effect "map lookup selects exactly one effect"
    }
    expect [::optLookup::lookups::has {1 none} 1] 1 "present nested none with discarded capture"
    expect [::optLookup::lookups::has {1 none} 2] 0 "missing map entry"
    set history {}
    lassign [::optLookup::lookups::propagated {{}} 0] tag p
    expect $history items "key error skips both match arms"
    set lines [split $source \n]
    set line [lsearch -glob $lines {*ok(match .items*}]
    expect [list $tag [dict get $p code] [dict get $p origin]] \
        [list err DIVIDE_BY_ZERO [dict create module lookups line [expr {$line+1}] \
            column [expr {1+[string first ? [lindex $lines $line]]}]]] "key error at original question mark"
    foreach {fn helper} {item listLookup key mapLookup} {
        expect [string first ::@rt::$helper [info body ::optLookup::lookups::$fn]] -1 \
            "immediate match consumes $fn without a tagged lookup"
    }
}

namespace eval ::optimizationTest {
    foreach {name type} {
        text text identifier .identifier bool bool decimal decimal binary64 binary64
        optional text? mapping map<text,int> event .event stamp instant wall local_datetime
    } {
        append source [format {export fn .%s($a: %s, $b: %s) -> list<bool> => [$a == $b, $a != $b]} $name $type $type] "\n"
    }
    set artifact [::appcompiler::compile [dict create model $source] ::optApp]
    namespace eval :: [dict get $artifact script]
    integerCases
    wordCounts
    otherTypes
    evaluation
    matchedLookups
    collectionUpdates
    discardedValues
    puts "application compiler optimization corpus: $checks assertions passed"
}
