# Handwritten Tcl reference for the colleague-import corpus.
namespace eval ::replay_Tcl::bench {namespace path ::machteld}

if {![catch {::machteld::json children [::machteld::json decode -typed {[]}]}]} {
    interp alias {} ::replay_Tcl::bench::children {} ::machteld::json children
} else {
    # Older runtimes expose individual typed children through get.
    proc ::replay_Tcl::bench::children {node} {
        set result {}
        if {[json type $node] eq "array"} {
            set length [llength [json unwrap $node]]
            for {set index 0} {$index < $length} {incr index} {
                lappend result [json get $node $index]
            }
        } else {
            foreach key [dict keys [json unwrap $node]] {
                dict set result $key [json get $node $key]
            }
        }
        return $result
    }
}

# Compare numbers as decimal digits and a power of ten. Binary64 would lose
# distinctions in large integer sensor readings.
proc ::replay_Tcl::bench::numberKey {spelling} {
    if {![regexp {\A(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\Z} \
            $spelling -> sign whole fraction exponent]} {error "invalid JSON number"}
    set digits [string trimleft $whole$fraction 0]
    if {$digits eq ""} {return {0 0}}
    set power 0
    if {$exponent ne ""} {scan $exponent %lld power}
    set mantissa [string trimright $digits 0]
    return [list $sign$mantissa [expr {$power - [string length $fraction] +
        [string length $digits] - [string length $mantissa]}]]
}

proc ::replay_Tcl::bench::sameEvidence {left right} {
    set type [json type $left]
    if {$type ne [json type $right]} {return 0}
    switch $type {
        object {
            set leftFields [children $left]
            set rightFields [children $right]
            if {[dict size $leftFields] != [dict size $rightFields]} {return 0}
            dict for {key value} $leftFields {
                if {![dict exists $rightFields $key] ||
                        ![sameEvidence $value [dict get $rightFields $key]]} {return 0}
            }
            return 1
        }
        array {
            set leftItems [children $left]
            set rightItems [children $right]
            if {[llength $leftItems] != [llength $rightItems]} {return 0}
            foreach a $leftItems b $rightItems {
                if {![sameEvidence $a $b]} {return 0}
            }
            return 1
        }
        number {expr {[numberKey [json unwrap $left]] eq [numberKey [json unwrap $right]]}}
        null {return 1}
        default {string equal [json unwrap $left] [json unwrap $right]}
    }
}

proc ::replay_Tcl::bench::scalar {members key type} {
    set node [dict get $members $key]
    if {[json type $node] ne $type} {error "invalid $key"}
    set value [json unwrap $node]
    if {$type eq "number"} {
        if {![regexp {\A-?[0-9]+\Z} $value]} {error "invalid integer $key"}
        scan $value %lld value
        if {$value < -0x8000000000000000 || $value > 0x7fffffffffffffff} {error "out-of-range $key"}
    }
    return $value
}

proc ::replay_Tcl::bench::batch {wire} {
    set batch [children [json decode -typed $wire]]
    set source [scalar $batch source string]
    set claims [dict get $batch claims]
    if {[json type $claims] ne "array"} {error "expected claims"}
    set rows {}
    foreach claim [children $claims] {
        set fields [children $claim]
        lappend rows [list [scalar $fields id string] [scalar $fields entity string] \
            [scalar $fields field string] [scalar $fields starts number] \
            [scalar $fields ends number] [scalar $fields value string] $claim]
    }
    return [list $source $rows]
}

proc ::replay_Tcl::bench::count {wire} {
    return [list ok [llength [lindex [batch $wire] 1]]]
}

proc ::replay_Tcl::bench::merge_wire {path wire} {
    try {
        lassign [batch $wire] source rows
        if {$source eq ""} {error "missing source identifier"}
        sqlite3 importDb $path -create 0
        try {
            set added 0
            importDb transaction immediate {
                foreach row $rows {
                    lassign $row id entity field starts ends value claim
                    if {$id eq "" || $entity eq "" || $field eq ""} {error "empty claim field"}
                    set matches [importDb eval {SELECT payload FROM claims WHERE source=$source AND id=$id}]
                    if {[llength $matches]} {
                        set saved [json decode -typed [lindex $matches 0]]
                        if {![sameEvidence $saved $claim]} {
                            error "source '$source' reused claim id '$id' with different content"
                        }
                    } else {
                        set payload [json encode -- $claim]
                        importDb eval {INSERT INTO claims(source,id,entity,field,starts,ends,value,payload)
                            VALUES ($source,$id,$entity,$field,$starts,$ends,$value,$payload)}
                        incr added
                    }
                }
            }
            return [list ok $added]
        } finally {importDb close}
    } on error {message options} {return [list err [dict create message $message]]}
}

proc ::replay_Tcl::bench::query_wire {path at} {
    sqlite3 queryDb $path -create 0 -readonly 1
    try {
        set lines [queryDb eval {WITH active AS (
            SELECT * FROM claims WHERE entity='E7' AND starts<=CAST($at AS INTEGER) AND CAST($at AS INTEGER)<ends)
            SELECT json_object('source',a.source,'id',a.id,'entity',a.entity,'field',a.field,'starts',a.starts,
                'ends',a.ends,'value',a.value,'disputed',json(CASE WHEN EXISTS (
                    SELECT 1 FROM active b WHERE b.field=a.field AND b.source<>a.source AND b.value<>a.value
                ) THEN 'true' ELSE 'false' END)) FROM active a ORDER BY a.field,a.source,a.id}]
        return [list ok $lines]
    } finally {queryDb close}
}

namespace eval ::replayChecks {}

proc ::replayChecks::merge {command database claims expected} {
    set wire [format {{"source":"north","claims":[%s]}} [join $claims ,]]
    lassign [$command $database $wire] tag value
    if {$tag eq "err"} {set value [dict get $value message]}
    if {[list $tag $value] ne $expected} {
        error "[namespace qualifiers $command]: expected $expected, got [list $tag $value]"
    }
}

# Exercise both importers against a real schema. A reader on another
# connection verifies that a rejected batch left every persisted field intact.
proc ::replayChecks::verify {label template directory} {
    set command ::replay_${label}::bench::merge_wire
    set database [file join $directory "evidence-$label.db"]
    file copy -- $template $database
    set original {{"id":"a","entity":"E7","field":"reading","starts":2,"ends":9,"value":"north","samples":[{"tick":2,"values":[9007199254740993,1.000e+2],"unit":"mm"}]}}
    set equivalent {{"samples":[{"unit":"mm","values":[9007199254740993.0,100],"tick":2}],"value":"north","ends":9,"starts":2,"field":"reading","entity":"E7","id":"a"}}
    set changed [string map {9007199254740993 9007199254740992} $original]
    set fresh [string map [list {"id":"a"} {"id":"b"}] $original]
    set invalid [string map [list {"id":"a"} {"id":"late"} {"ends":9} {"ends":2}] $original]
    set conflict [list err "source 'north' reused claim id 'a' with different content"]
    set readback {SELECT source,id,entity,field,starts,ends,value,payload FROM claims ORDER BY source,id}
    sqlite3 witness $database -create 0
    try {
        merge $command $database [list $original] {ok 1}
        set inserted [list north a E7 reading 2 9 north $original]
        if {[witness eval $readback] ne $inserted} {error "$label changed the inserted payload"}
        merge $command $database [list $equivalent] {ok 0}
        if {[witness eval $readback] ne $inserted} {error "$label rewrote equivalent evidence"}

        witness eval {UPDATE claims SET payload=$equivalent WHERE source='north' AND id='a'}
        set retained [lreplace $inserted end end $equivalent]
        merge $command $database [list $original] {ok 0}
        merge $command $database [list $fresh $changed] $conflict
        if {[witness eval $readback] ne $retained} {error "$label committed part of a conflicting replay"}
        merge $command $database [list $fresh $invalid] [list err "CHECK constraint failed: starts_must_precede_ends"]
        if {[witness eval $readback] ne $retained} {error "$label committed part of an invalid insert"}

        foreach broken [list {} [format %c 123]] {
            witness eval {UPDATE claims SET payload=$broken WHERE source='north' AND id='a'}
            if {![catch {::machteld::json decode -typed $broken} message]} {error "invalid fixture"}
            merge $command $database [list $fresh $original] [list err $message]
            if {[witness eval $readback] ne [lreplace $inserted end end $broken]} {
                error "$label modified an existing malformed payload or kept the earlier insert"
            }
        }
    } finally {witness close}
}
