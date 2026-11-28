package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::recordAdmission {
    variable tests 0
    variable code {
export record .row { id: int
    label: text
    amount: int?
    caption: text? }
export record .empty {}
export record .labels { left: text
    right: text }
export record .flag { bit: bool }
export record .box<.t> { item: .t }
export fn .rows($rows: list<.row>) -> list<.row> { return $rows }
export fn .empty_rows($rows: list<.empty>) -> list<.empty> { return $rows }
export fn .label_rows($rows: list<.labels>) -> list<.labels> { return $rows }
export fn .flags($rows: list<.flag>) -> list<.flag> { return $rows }
export fn .boxed($rows: list<.box<int>>) -> list<.box<int>> { return $rows }
export fn .one($row: .row) -> .row { return $row }
export fn .one_empty($row: .empty) -> .empty { return $row }
}
}
proc ::recordAdmission::eq {got want} {
    variable tests
    incr tests
    if {$got ne $want} {error "expected [list $want], got [list $got]"}
}
proc ::recordAdmission::rejects {command want} {
    eq [catch $command message options] 1
    eq $message $want
    eq [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE}
}
proc ::recordAdmission::suite {scope} {
    set rows ${scope}::probe::rows
    set empty ${scope}::probe::empty_rows
    set good [dict create label a id 7]
    eq [$rows {}] {}
    eq [$empty [list {} {untouched deep}]] [list {} {untouched deep}]
    eq [$empty [list "  duplicate  first duplicate second "]] [list "  duplicate  first duplicate second "]
    set labelRows ${scope}::probe::label_rows
    set spelling "  right {two words} left first extra 17 left final  "
    set labels [$labelRows [list $spelling]]
    eq $labels [list [dict create right {two words} left final extra 17]]
    eq $spelling "  right {two words} left first extra 17 left final  "
    set evidence [::machteld::json decode -typed {{"nested":[true]}}]
    set labels [$labelRows [list [dict create right $evidence left $evidence]]]
    eq [::machteld::json type [dict get [lindex $labels 0] right]] object
    eq [::machteld::json type $evidence] object
    set huge [string repeat 9 401]
    set octal 010
    expr {$octal + 0}
    foreach {spelling numeric} [list $octal 10 +00017 17 -000 0 -0008 -8 +000$huge $huge -000$huge -$huge] {
        set row [dict create id $spelling extra unknown label a amount [list some $spelling] caption {some {}}]
        set want [dict replace $row id $numeric amount [list some $numeric]]
        eq [$rows [list $row]] [list $want]
    }
    eq [$rows [list {label original id +04 label last amount none}]] [list {label last id 4 amount none}]
    set nested [::machteld::json decode -typed {{"nested":[{"a":[1,null]}]}}]
    set numeric [::machteld::json decode -typed 17]
    set retained [::machteld::json decode -typed {"hi"}]
    set row [dict create id $numeric label $retained amount [list some $numeric] caption [list some $retained] extra $nested]
    set out [lindex [$rows [list $row]] 0]
    eq [dict keys $out] [dict keys $row]
    eq [dict get $out id] 17
    eq [dict get $out amount] {some 17}
    eq [::machteld::json type [dict get $out label]] string
    eq [::machteld::json type [lindex [dict get $out caption] 1]] string
    eq [::machteld::json type [dict get $out extra]] object
    eq [::machteld::json type [::machteld::json get [dict get $out extra] nested]] array
    eq [::machteld::json type $numeric] number
    set raw [::machteld::json unwrap [::machteld::json decode -typed {"17\u0000tail"}]]
    foreach bad [list "" 1e3 0x31 "7\u0661" "17\0tail" $raw [binary decode hex 31370078] -+4 +] {
        rejects [list $rows [list $good [dict replace $good id $bad]]] {expected int at $rows.1.id}
        rejects [list $rows [list [dict replace $good amount [list some $bad]]]] {expected int at $rows.0.amount}
    }
    rejects [list $rows "\{"] {expected list<.probe::row> at $rows}
    rejects [list $rows [list $good broken]] {expected .probe::row at $rows.1}
    foreach row [list {} [dict create amount {bad tag}]] {
        rejects [list $rows [list $row]] {expected int at $rows.0.id}
    }
    rejects [list $rows [list [dict create id 2 amount bad]]] {expected text at $rows.0.label}
    foreach bad [list "some" {none extra} "some\0bad 1" [list {some } 5] "\{"] {
        rejects [list $rows [list [dict replace $good amount $bad caption bad]]] {expected int? at $rows.0.amount}
    }
    set many [lrepeat 1024 $good]
    lset many 1019 [dict replace $good caption oops]
    lset many 1020 {}
    rejects [list $rows $many] {expected text? at $rows.1019.caption}
    set requiredExtra [dict replace $good extra $nested]
    rejects [list ${scope}::@rt::guard list<.probe::row> [list $requiredExtra] p worker] {expected a declared worker message field at p.0[extra]}
    rejects [list ${scope}::@rt::guard list<.probe::row> [list [dict replace $good extra raw]] p 1] {expected a retained typed JSON value at p.0[extra]}
    eq [${scope}::probe::flags [list {bit true}]] [list {bit 1}]
    set flagGuard ${scope}::@rt::guard
    set raw [::machteld::json unwrap [::machteld::json decode -typed {"1\u0000tail"}]]
    foreach mode {0 1 worker workerOutput} {
        eq [$flagGuard .probe::flag {bit false} p $mode] {bit 0}
        rejects [list $flagGuard .probe::flag [dict create bit $raw] p $mode] {expected bool at p.bit}
    }
    eq [${scope}::probe::boxed [list {item +0004}]] [list {item 4}]

    # Each node remains usable through its original handle on both outcomes.
    foreach part {root row optional} {
        set node [::machteld::json decode -typed 17]
        switch $part {
            root {set value $node; set expected {expected .probe::row at $rows.0}}
            row {set value [list $node]; set expected {expected .probe::row at $rows.0}}
            optional {set value [list [dict replace $good amount $node]]; set expected {expected int? at $rows.0.amount}}
        }
        rejects [list $rows $value] $expected
        eq [::machteld::json type $node] number
        eq [::machteld::json unwrap $node] 17
    }
    set root [::machteld::json decode -typed {"id 3 label a"}]
    eq [$rows $root] {{id 3 label a}}
    eq [::machteld::json type $root] string
    set doc [::machteld::json decode -typed {{"opt":"some 3","row":"id 3 label a"}}]
    set option [::machteld::json get $doc opt]
    set sourceRow [::machteld::json get $doc row]
    rejects [list $rows [list [dict replace $good amount $option]]] {expected int? at $rows.0.amount}
    eq [$rows $sourceRow] {{id 3 label a}}
    rejects [list $rows [list $sourceRow]] {expected .probe::row at $rows.0}
    eq [::machteld::json type $option] string
    eq [::machteld::json type $sourceRow] string
    eq [::machteld::json type $doc] object
    set opaqueRow [::machteld::json decode -typed {"row with spaces"}]
    rejects [list $rows [list $opaqueRow]] {expected .probe::row at $rows.0}
    eq [::machteld::json type $opaqueRow] string
    # An empty layout accepts this valid dictionary without touching its
    # caller-owned keys or canonicalizing its original string spelling.
    set opaqueRow [::machteld::json decode -typed {["a b"]}]
    eq [$empty [list $opaqueRow]] [list {["a b"]}]
    eq [::machteld::json type $opaqueRow] array
    eq [${scope}::probe::one_empty $opaqueRow] {["a b"]}
    eq [::machteld::json type $opaqueRow] array
    rejects [list ${scope}::probe::one $opaqueRow] {expected int at $row.id}
    eq [::machteld::json type $opaqueRow] array
    foreach {json expectedCode want} {
        {"item +007"} 0 {{item 7}}
        {"item oops"} 1 {expected int at $rows.0.item}
    } {
        set outer [::machteld::json decode -typed $json]
        set call [list ${scope}::probe::boxed $outer]
        if {$expectedCode} {rejects $call $want} else {eq [{*}$call] $want}
        eq [::machteld::json type $outer] string
    }
    foreach boundary {worker workerOutput 1} {
        set outer [::machteld::json decode -typed {"id +003 label a"}]
        eq [${scope}::@rt::guard list<.probe::row> $outer p $boundary] {{id 3 label a}}
        eq [::machteld::json type $outer] string
        set wanted [expr {$boundary eq "1" ? "a retained typed JSON value" : "a declared worker message field"}]
        set extra [lindex {["a b"]} 0]
        rejects [list ${scope}::@rt::guard .probe::empty $opaqueRow p $boundary] \
            [format {expected %s at p[%s]} $wanted [list $extra]]
        eq [::machteld::json type $opaqueRow] array
        rejects [list ${scope}::@rt::guard .probe::row "\{" p $boundary] {expected .probe::row at p}
        rejects [list ${scope}::@rt::guard list<.probe::row> "\{" p $boundary] {expected list<.probe::row> at p}
        set duplicate [list id 4 label duplicate id +003]
        if {$boundary eq "1"} {
            eq [${scope}::@rt::guard .probe::row $duplicate p $boundary] {id 3 label duplicate}
        } else {
            rejects [list ${scope}::@rt::guard .probe::row $duplicate p $boundary] {expected unique worker record fields at p}
        }
    }
}

proc ::recordAdmission::direct {} {
    set guard ::machteld::GuardRecordList
    set row [dict create a +007]
    set max {}
    for {set i 0} {$i < 16} {incr i} {lappend max f$i int?}
    eq [$guard $max rec [list {}] root] [list {}]
    eq [$guard {} empty [list $row] root] [list $row]
    set invalid [list "\{" a {a int a bool} {a int a int} {a integer} {a {}} \
        [list a "int\0junk"] [concat $max {overflow int?}]]
    foreach layout $invalid {
        eq [catch {$guard $layout rec noSuchRow p} why] 1
        eq $why {invalid compiler record layout}
    }
    eq [catch {$guard {a int}} why] 1
    eq $why {wrong # args: should be "::machteld::GuardRecordList layout element value path"}
    set borrowed [::machteld::json decode -typed 17]
    eq [catch {$guard [list a $borrowed] rec {} p} why] 1
    eq [::machteld::json type $borrowed] number
    eq [$guard [list $borrowed int] rec [list [dict create 17 $borrowed]] $borrowed] {{17 17}}
    eq [::machteld::json type $borrowed] number
    set alias [list {a int}]
    # All four command arguments may refer to a single Tcl value.
    eq [catch {$guard $alias $alias $alias $alias} why] 1
    eq $alias [list {a int}]
    set bad [dict create a [::machteld::json decode -typed 4.5]]
    set nearly [concat [lrepeat 60 $row] [list $bad]]
    for {set i 0} {$i < 50} {incr i} {
        rejects [list $guard {a int} rec $nearly input] {expected int at input.60.a}
        eq [$guard {a int} rec [list $row $row] input] {{a 7} {a 7}}
    }
    eq [::machteld::json type [dict get $bad a]] number
}

# Compare the specialized record path with its generic field read at the point
# where the application can still enter the extern but has almost no stack.
proc ::recordAdmission::fieldDepth {type valid invalid} {
    set source [string map [list @field@ $type] {record .flag { bit: @field@ }
        extern fn .read() -> .flag = ['::readFlag']
        export fn .rows($rows: list<.flag>) -> list<.flag> => $rows
        export fn .walk($n: int) -> @field@ {
            if $n == 0 { return .read().bit }
            return .walk($n - 1)
        }}]
    set script [dict get [::appcompiler::compile [dict create probe $source] ::app] script]
    set ref [interp create]
    set checked [interp create]
    try {
        foreach ip [list $ref $checked] {
            $ip eval $script
            $ip eval {proc ::readFlag {} {return $::row}}
        }
        $ref eval [list set ::fieldType $type]
        $ref eval {proc ::app::@rt::guardRecord {type members value path checkExtras} {
            dict set value bit [guard $::fieldType [dict get $value bit] $path.bit $checkExtras]
            return $value
        }}
        set row [dict create bit $valid]
        set normalized [$checked eval [list ::app::@rt::guard $type $valid value]]
        eq [$checked eval [list ::app::probe::rows [list $row]]] [list [dict create bit $normalized]]
        set want [expr {$type eq "bool" ? "bool" : "canonical $type"}]
        set badRows [list $row [dict create bit $invalid]]
        rejects [list $checked eval [list ::app::probe::rows $badRows]] [format {expected %s at $rows.1.bit} $want]
        foreach spelling [list $valid $invalid] {
            foreach ip [list $ref $checked] {$ip eval [list set ::row [dict create bit $spelling]]}
            foreach limit {12 13} {
                foreach ip [list $ref $checked] {interp recursionlimit $ip $limit}
                for {set depth 0} {$depth <= $limit} {incr depth} {
                    set results {}
                    foreach ip [list $ref $checked] {
                        set status [catch {$ip eval [list ::app::probe::walk $depth]} msg options]
                        lappend results [list $status $msg [dict getdef $options -errorcode {}] [dict getdef $options -appcompilerlocation {}]]
                    }
                    eq [lindex $results 0] [lindex $results 1]
                }
            }
        }
    } finally {
        interp delete $checked
        interp delete $ref
    }
}

proc ::recordAdmission::run {} {
    variable code
    variable tests
    # Generate the same artifact twice with capability selected at startup.
    set native [llength [info commands ::machteld::GuardRecordList]]
    if {$native} {rename ::machteld::GuardRecordList ::recordAdmission::savedGuard}
    try {
        namespace eval :: [dict get [::appcompiler::compile [dict create probe $code] ::recordOld] script]
    } finally {
        if {$native} {rename ::recordAdmission::savedGuard ::machteld::GuardRecordList}
    }
    suite ::recordOld
    fieldDepth bool true bad
    fieldDepth instant 2000-02-29T12:00:00.000000000Z 1900-02-29T12:00:00.000000000Z
    fieldDepth local_datetime 2000-02-29T12:00:00.1 2000-02-29T12:00:00.10
    if {$native} {
        namespace eval :: [dict get [::appcompiler::compile [dict create probe $code] ::recordNew] script]
        suite ::recordNew
        direct
        set ::recordAdmission::calls 0
        trace add execution ::machteld::GuardRecordList enter ::recordAdmission::count
        try {
            ::recordNew::probe::flags [list {bit true}]
            ::recordNew::probe::boxed [list {item +5}]
            ::recordNew::@rt::guard list<.probe::row> [list {id 7 label A}] p worker
            ::recordNew::@rt::guard list<.probe::row> [list {id 7 label A}] p 1
            eq $::recordAdmission::calls 0
            ::recordNew::probe::rows [list {id 7 label A}]
            eq $::recordAdmission::calls 1
        } finally {trace remove execution ::machteld::GuardRecordList enter ::recordAdmission::count}
    }
    puts "record admission passed $tests checks (native capability $native)"
}
proc ::recordAdmission::count args {incr ::recordAdmission::calls}
::recordAdmission::run
