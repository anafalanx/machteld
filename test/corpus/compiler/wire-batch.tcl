package require machteld

# Time the actual colleague-import record types separately for exporting an
# existing batch and for a decode/encode round trip. Check the complete wire.
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set timings 0
set rows 480
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set option [lindex $argv $i]] {
        --timings {set timings 1}
        --embedded {
            if {[info exists compiler]} {error "select the candidate compiler once"}
            set compiler [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with - --rows {
            if {[incr i] >= [llength $argv]} {error "$option needs an argument"}
            set value [lindex $argv $i]
            switch -- $option {
                --compiler {
                    if {[info exists compiler]} {error "select the candidate compiler once"}
                    set compiler $value
                }
                --compare-with {set baseline $value; set timings 1}
                --rows {
                    if {![string is entier -strict $value] || $value < 0} {error "expected a nonnegative row count"}
                    set rows $value
                }
            }
        }
        default {error "usage: wire-batch.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--rows count? ?--timings?"}
    }
}
if {![info exists compiler]} {set compiler [file join $root packages application-compiler]}
set file [open [file join $root examples typed-import observations.src] r]
try {chan configure $file -encoding utf-8; set observations [read $file]} finally {close $file}
set probe {import observations
export fn .read($wire: text) -> result<.observations::batch,problem> =>
    decode_json<.observations::batch>($wire)
export fn .write($batch: .observations::batch) -> result<text,problem> =>
    encode_json($batch)
export fn .roundtrip($wire: text) -> result<text,problem> =>
    .write(.read($wire)?)
export fn .same($a: .observations::batch, $b: .observations::batch) -> bool => $a == $b
record .samples {
    ids: list<int>
    valid: list<bool>
    labels: list<text>
}
export fn .accepted($wire: text) -> result<list<int>,problem> {
    $data ::= decode_json<.samples>($wire)?
    if len($data.ids) != len($data.valid) || len($data.ids) != len($data.labels) {
        return err(problem('sample columns have different lengths'))
    }
    $index := 0
    $accepted := list<int>()
    for $id in $data.ids {
        $valid ::= match $data.valid[$index] { some($v) => $v
            none => false }
        if $valid { $accepted = list_append($accepted, $id) }
        $index = $index + 1
    }
    return ok($accepted)
}
}
set sources [dict create observations $observations wirebench $probe]
set compilers [dict create X $compiler]
if {[info exists baseline]} {dict set compilers baseline $baseline}
dict for {tag directory} $compilers {
    set c [interp create]
    try {
        $c eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set artifact [$c eval [list ::appcompiler::compile $sources ::codec_$tag]]
        namespace eval :: [dict get $artifact script]
    } finally {interp delete $c}
}
proc sampleColumns {n} {
    set ids {}; set flags {}; set labels {}; set expected {}
    for {set i 0} {$i < $n} {incr i} {
        set id [expr {$i % 11 == 3 ? 10**64+$i : -317*$i}]
        set valid [expr {$i % 7 != 0 && $i % 13 != 1}]
        lappend ids $id
        lappend flags [expr {$valid ? "true" : "false"}]
        lappend labels {"coil\u0000\ud83d\udd2c"}
        if {$valid} {lappend expected $id}
    }
    return [list [format {{"ids":[%s],"valid":[%s],"labels":[%s]}} \
        [join $ids ,] [join $flags ,] [join $labels ,]] $expected]
}
proc batch {n} {
    set claims {}
    for {set i 0} {$i < $n} {incr i} {
        # Trace is a future field with a noncanonical numeric literal, nested
        # types and an embedded NUL. It must survive as its original JSON.
        lappend claims [format {{"id":"%04d","entity":"007","field":"reading","starts":%d,"ends":%d,"value":"雪","trace":[true,1.00e+7,{"x\u0000y":null}]}} \
            $i $i [expr {$i+2}]]
    }
    return [format {{"source":"north","claims":[%s]}} [join $claims ,]]
}
dict for {tag directory} $compilers {
    set prefix ::codec_${tag}::wirebench
    foreach n {0 1 513} {
        lassign [sampleColumns $n] input expected
        if {[${prefix}::accepted $input] ne [list ok $expected]} {error "$tag changed selected sample identifiers"}
    }
    foreach {input message} {
        {{"ids":[1,2.5],"valid":[],"labels":[]}} {value.ids[1] expects an integer JSON literal}
        {{"ids":[],"valid":[true,1],"labels":[]}} {value.valid[1] expects a boolean, got number}
        {{"ids":[],"valid":[],"labels":["coil",null]}} {value.labels[1] expects text, got null}
    } {
        lassign [${prefix}::accepted $input] status problem
        if {$status ne "err" || [dict get $problem code] ne "JSON_SCHEMA" ||
                [dict get $problem message] ne $message} {error "$tag unexpected sample rejection: $problem"}
    }
    set capability ::codec_${tag}::@rt::jsonScalarProjection
    if {[info exists $capability] && [set $capability]} {
        lassign [sampleColumns 3] input expected
        set previous [interp recursionlimit {}]
        try {
            for {set limit 5} {$limit < 20} {incr limit} {
                interp recursionlimit {} $limit
                set outcomes {}
                foreach enabled {0 1} {
                    set $capability $enabled
                    set status [catch {${prefix}::accepted $input} answer opts]
                    lappend outcomes [list $status $answer [dict getdef $opts -errorcode {}]]
                }
                if {[lindex $outcomes 0] ne [lindex $outcomes 1]} {error "$tag changed sample decode at recursion limit $limit"}
            }
        } finally {interp recursionlimit {} $previous; set $capability 1}
    }
    foreach {left right expected} {
        {[]} {[]} 1
        {[[false],null]} {[[0],null]} 0
        {[[1,2],3]} {[[1,2],4]} 0
        {[[1,2],3]} {[[1,2]]} 0
        {[1.00e99,{"k\u0000y":true,"b":-0.00}]} {[10e98,{"b":0,"k\u0000y":true}]} 1
        {[9007199254740993]} {[9007199254740992]} 0
    } {
        set compared {}
        foreach fragment [list $left $right] {
            set wire [format {{"source":"north","claims":[],"evidence":%s}} $fragment]
            lassign [${prefix}::read $wire] status row
            if {$status ne "ok"} {error "$tag failed to read retained evidence: $row"}
            lappend compared $row
        }
        if {[${prefix}::same {*}$compared] != $expected} {error "$tag compared $left and $right incorrectly"}
    }
    # Both values carry the same evidence; one is decoded, one constructed.
    # A native comparison must also respect the caller's remaining Tcl stack.
    set inner [::machteld::json decode -typed "[string repeat \[ 10]true[string repeat \] 10]"]
    set constructed [::machteld::json value array [list [::machteld::json get $inner 0]]]
    set record [dict create source north claims {} evidence $inner]
    set built [dict replace $record evidence $constructed]
    set saved [interp recursionlimit {}]
    try {
        foreach limit {12 15 18 24 32} {
            interp recursionlimit {} $limit
            set outcomes {}
            foreach other [list $record $built] {
                set status [catch {${prefix}::same $record $other} answer options]
                lappend outcomes [list $status $answer [dict getdef $options -errorcode {}]]
            }
            if {[lindex $outcomes 0] ne [lindex $outcomes 1]} {error "$tag changed recursion-limit behavior at $limit: $outcomes"}
        }
    } finally {interp recursionlimit {} $saved}
}
foreach size [lsort -integer -unique [list 0 1 $rows]] {
    set wire [batch $size]
    set expected [::machteld::json encode -- [::machteld::json decode -typed $wire]]
    dict for {tag directory} $compilers {
        set prefix ::codec_${tag}::wirebench
        lassign [${prefix}::read $wire] status value
        if {$status ne "ok" || [llength [dict get $value claims]] != $size} {error "$tag lost rows in decode"}
        foreach {op arg} [list write $value roundtrip $wire] {
            set cmd [list ${prefix}::$op $arg]
            if {[{*}$cmd] ne [list ok $expected]} {error "$tag $op changed the $size-row JSON batch"}
            if {$size == $rows} {dict set commands $tag $op $cmd}
        }
    }
    if {$size == $rows} {set wanted $expected}
}
if {!$timings} {puts "compiler JSON export: empty and populated batches preserve known and future fields"; return}
puts "round\tcompiler\toperation\tmicroseconds"
set tags [dict keys $compilers]
for {set round 1} {$round <= 16} {incr round} {
    foreach op [expr {$round % 4 < 2 ? {write roundtrip} : {roundtrip write}}] {
        foreach tag [expr {$round % 2 ? $tags : [lreverse $tags]}] {
            set cmd [dict get $commands $tag $op]
            set start [clock microseconds]
            set result [{*}$cmd]
            set elapsed [expr {[clock microseconds]-$start}]
            if {$result ne [list ok $wanted]} {error "$tag $op changed the timed result"}
            puts [join [list $round $tag $op $elapsed] \t]
        }
    }
}
