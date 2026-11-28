package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::integerListTest {variable checks 0}
proc ::integerListTest::equal {got want label} {
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
    incr ::integerListTest::checks
}
proc ::integerListTest::failure {app command code message} {
    equal [catch {$app eval $command} got options] 1 "boundary rejected the input"
    equal [dict get $options -errorcode] $code "boundary error code"
    equal $got $message "first failing element"
}
proc ::integerListTest::rowDepth {app} {
    $app eval {
        proc ::intLists::@rt::genericRows {rows path} {
            set result {}
            foreach row $rows {
                lappend result [guard list<int> $row $path.[llength $result]]
            }
            return $result
        }
        proc nestedCall {depth call} {
            if {$depth == 0} {return [{*}$call]}
            return [nestedCall [expr {$depth - 1}] $call]
        }
    }
    set oldLimit [interp recursionlimit $app]
    try {
        interp recursionlimit $app 16
        foreach rows [list {{+009} {-1}} {{+009} {bad later}}] {
            for {set depth 0} {$depth <= 16} {incr depth} {
                set outcomes {}
                foreach prefix {{::intLists::@rt::genericRows} {::intLists::@rt::guard list<list<int>>}} {
                    set call [list {*}$prefix $rows input]
                    set status [catch {$app eval [list nestedCall $depth $call]} answer options]
                    lappend outcomes [list $status $answer [dict getdef $options -errorcode {}]]
                }
                equal {*}$outcomes "nested row validation at recursion depth $depth"
            }
        }
    } finally {interp recursionlimit $app $oldLimit}
}
proc ::integerListTest::exercise {script native} {
    set app [interp create]
    try {
        if {$native} {$app alias ::machteld::GuardIntegerList ::machteld::GuardIntegerList}
        $app alias json ::machteld::json
        $app eval {proc foreign {} {return $::value}}
        $app eval $script
        set borrowed [$app eval {
            set observed {}
            foreach token {17 17.5} {
                foreach shape {element argument} {
                    set document [json decode -typed "{\"amount\":$token}"]
                    set amount [json get $document amount]
                    set input $amount
                    if {$shape eq "element"} {set input [list $amount]}
                    set status [catch {::intLists::sample::echo $input} answer]
                    lappend observed $status $answer [json type $amount] [json encode -- [json get $document amount]]
                }
            }
            set observed
        }]
        set ok [list 0 17 number 17]
        set err [list 1 {expected int at $values.0} number 17.5]
        equal $borrowed [concat $ok $ok $err $err] "retained JSON root and members survive acceptance and failure"
        # Older hosts return a Tcl string containing a raw NUL from JSON.
        # Tcl's literal NUL and a bytearray also cross this same boundary.
        set rejected [$app eval {
            set observed {}
            set jsonString [json decode -typed {"17\u0000tail"}]
            foreach word [list $jsonString [json unwrap $jsonString] "17\u0000tail" [binary decode hex 31370078]] {
                foreach shape {argument element} {
                    set input $word
                    if {$shape eq "element"} {set input [list $word]}
                    set status [catch {::intLists::sample::echo $input} answer options]
                    lappend observed [list $status $answer [dict getdef $options -errorcode {}]]
                }
            }
            set observed
        }]
        equal $rejected [lrepeat 8 [list 1 {expected int at $values.0} {APPCOMPILER ARGUMENT TYPE}]] \
            "reject raw and literal NUL at element zero"
        set huge [string repeat 9 375]
        set input [list +0009 -010 -000000 +0 "00$huge" "-00$huge"]
        set clean [list 9 -10 0 0 $huge -$huge]
        equal [$app eval [list ::intLists::sample::echo $input]] $clean "base-ten integer spelling"
        equal [$app eval [list ::intLists::sample::echo "   {1}\t-2 \n"]] {1 -2} "canonical list spelling"
        equal [$app eval [list ::intLists::sample::nested [list {} $input]]] [list {} $clean] "nested lists"
        if {$native} {
            $app eval {
                set visits 0
                proc countVisit args {incr ::visits}
                trace add execution ::machteld::GuardIntegerList enter countVisit
            }
        }
        equal [$app eval [list ::intLists::sample::twice $input]] 12 "two typed calls"
        if {$native} {
            equal [$app eval {set visits}] 1 "check the public native boundary once before two typed calls"
            $app eval {trace remove execution ::machteld::GuardIntegerList enter countVisit}
        }
        $app eval [list set ::value $input]
        equal [$app eval ::intLists::sample::from_tcl] $clean "extern list output"
        set typeError {APPCOMPILER ARGUMENT TYPE}
        set shared [::machteld::json decode -typed 123456789012345678901234567890]
        set rows [list [list $shared +017] $shared {-00}]
        equal [$app eval [list ::intLists::sample::nested $rows]] \
            {{123456789012345678901234567890 17} 123456789012345678901234567890 0} "borrowed integer as both element and row"
        failure $app [list ::intLists::sample::nested [concat $rows [list \{]]] \
            $typeError {expected list<int> at $values.3}
        equal [::machteld::json type $shared] number "borrowed row and element survive a later malformed row"
        rowDepth $app
        set values {}
        set normalized {}
        for {set i 0} {$i < 130} {incr i} {
            if {$i % 7 == 0} {
                lappend values $shared
                lappend normalized 123456789012345678901234567890
            } else {
                lappend values [format +%05d $i]
                lappend normalized $i
            }
        }
        equal [$app eval [list ::intLists::sample::echo $values]] $normalized "all integers keep their order across batches"
        foreach at {63 64 65 127 128 129} {
            set invalid [lreplace $values $at $at bad another_error]
            failure $app [list ::intLists::sample::echo $invalid] $typeError [format {expected int at $values.%d} $at]
        }
        equal [::machteld::json type $shared] number "a shared bignum retains its JSON type after late errors"
        failure $app [list ::intLists::sample::echo \{] $typeError {expected list<int> at $values}
        foreach x [list {} + - 0x3 0b11 1e2 "1\u00002" "\u0661" " 7" "7\n" -1.0] {
            failure $app [list ::intLists::sample::echo [list 9 $x bad]] $typeError {expected int at $values.1}
        }
        set bad [concat [lrepeat 16383 +009] [list out_of_range another_error]]
        failure $app [list ::intLists::sample::nested [list {0} $bad]] $typeError {expected int at $values.1.16383}
        $app eval [list set ::value $bad]
        failure $app ::intLists::sample::from_tcl {APPCOMPILER EXTERN RESULT} {expected int at extern result.16383}
        # Successful calls after partial failures must return their own elements.
        equal [$app eval [list ::intLists::sample::echo [list "-000$huge"]]] [list -$huge] "new value after an error"
    } finally {interp delete $app}
}
namespace eval ::integerListTest {
    set source {export fn .echo($values: list<int>) -> list<int> { return $values }
export fn .nested($values: list<list<int>>) -> list<list<int>> { return $values }
fn .count($values: list<int>) -> int { return len($values) }
export fn .twice($values: list<int>) -> int { return .count($values) + .count($values) }
extern fn .foreign() -> list<int> = ['::foreign']
export fn .from_tcl() -> list<int> { return .foreign() }}
    set script [dict get [::appcompiler::compile [dict create sample $source] ::intLists] script]
    exercise $script 0
    if {[llength [info commands ::machteld::GuardIntegerList]]} {exercise $script 1}
    puts "application compiler integer lists: $checks assertions passed"
}
