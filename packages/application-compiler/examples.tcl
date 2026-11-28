# Example operands use the regular emitter. Each compiled word runs in a
# fresh procedure frame, once, and only under an explicit test request.
proc ::appcompiler::exampleValue {node context} {
    dict set context nativeFloat [expr {[llength [info commands ::machteld::x::binary64v1::add]] &&
        "add" in [namespace eval ::machteld::x::binary64v1 {namespace export}]}]
    dict set context floatPairs [expr {[llength [info commands ::machteld::x::binary64v1::rightPair]] &&
        "rightPair" in [namespace eval ::machteld::x::binary64v1 {namespace export}]}]
    set word [emitExpression $node $context]
    return [apply [list {} "::return $word" [dict get $context target]]]
}

# An empty message means the expectation matched. Native Tcl faults escape
# to the per-example handler, independently of ordinary typed error results.
proc ::appcompiler::compareExample {example context} {
    set rt [dict get $context target]::@rt
    set facts [emitFacts $example $context]
    set result [exampleValue [dict get $example actual] $context]
    if {[dict get $example expectation] eq "value"} {
        set expected [exampleValue [dict get $example expected] $context]
        if {[lindex [typeParts [dict get $facts actualType]] 0] eq "result"} {
            lassign $result tag actual
            if {$tag ne "ok"} {return "expected success [list $expected], got [list $result]"}
        } else {
            set actual $result
        }
        if {![${rt}::equal [dict get $facts operandType] $actual $expected]} {
            return "expected [list $expected], got [list $actual]"
        }
        return {}
    }

    set code [dict get $example code value]
    set fields {}
    foreach field [dict get $example fields] {
        set type [dict get [emitFacts $field $context] operandType]
        lappend fields [list [dict get $field name] $type [exampleValue [dict get $field value] $context]]
    }
    lassign $result tag problem
    if {$tag ne "err"} {return "expected error [list $code], got [list $result]"}
    if {![dict exists $problem code]} {return "expected error code [list $code], got an error without code"}
    set actualCode [dict get $problem code]
    if {![${rt}::equal text $code $actualCode]} {
        return "expected error code [list $code], got [list $actualCode]"
    }
    foreach selection $fields {
        lassign $selection name type expected
        if {![dict exists $problem $name]} {return "expected $name = [list $expected], field is missing"}
        set raw [dict get $problem $name]
        if {[catch {${rt}::guard $type $raw $name 1} actual]} {
            return "expected $name = [list $expected] ($type), got [list $raw] ($actual)"
        }
        if {![${rt}::equal $type $actual $expected]} {
            return "expected $name = [list $expected], got [list $actual]"
        }
    }
    return {}
}

proc ::appcompiler::runExamples {analysis minApi packageDirs {toolRoot {}}} {
    variable exampleSerial
    set target ::appcompiler::exampleRun[incr exampleSerial]
    while {[namespace exists $target]} {set target ::appcompiler::exampleRun[incr exampleSerial]}
    set artifact [emitChecked $analysis $target $toolRoot]
    set total 0
    set failures {}
    set savedPath $::auto_path
    try {
        namespace eval :: [applicationPrelude $minApi $packageDirs]
        namespace eval :: [dict get $artifact script]
        foreach module [lsort -ascii [dict keys [dict get $analysis modules]]] {
            set context [dict create target $target module $module facts [dict get $analysis facts] problemResult 0]
            foreach example [dict get $analysis modules $module examples] {
                incr total
                try {
                    set message [compareExample $example $context]
                } on error {detail options} {
                    set where [${target}::@rt::errorLocation $options]
                    set at [expr {$where eq {} ? {} : " at [dict get $where module]:[dict get $where line]:[dict get $where column]"}]
                    set message "Tcl error${at}: $detail"
                }
                if {$message ne {}} {
                    lappend failures [diagnostic EXAMPLE_FAILED $example "example .[dict get $example owner]: $message"]
                }
            }
        }
    } finally {
        if {[namespace exists $target]} {namespace delete $target}
        set ::auto_path $savedPath
    }
    set failed [llength $failures]
    return [dict create total $total passed [expr {$total - $failed}] failed $failed failures $failures]
}
