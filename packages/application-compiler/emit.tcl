# Each expression emits one Tcl word. Text stays on one physical line so a
# procedure body line can always be traced to its source statement.
proc ::appcompiler::emitTextWord {value} {
    set escapes [list \\ {\\} \" {\"} \$ {\$} \[ {\[} \] {\]} \
        \{ {\{} \} {\}} \n {\n} \r {\r} \t {\t} \
        \u0000 {\u0000} \u001a {\u001a}]
    return [format {"%s"} [string map $escapes $value]]
}

proc ::appcompiler::emitIntegerWord {value} {
    if {![regexp {\A([+-]?)([0-9]+)\Z} $value -> sign digits]} {
        error "invalid integer in checked application: [list $value]"
    }
    # Tcl accepts other integer bases. An application integer is decimal.
    set digits [string trimleft $digits 0]
    if {$digits eq ""} {return 0}
    if {$sign eq "-"} {return -$digits}
    return $digits
}

proc ::appcompiler::emitLocalName {name} {
    # In particular, the final Tcl formal named 'args' would be variadic.
    return v_[binary encode hex [encoding convertto utf-8 $name]]
}

# A generated program carries its own type descriptions and needs no compiler
# at run time. @rt cannot be an application module name. Its procedures keep
# no mutable state, so two applications may use different definitions.
proc ::appcompiler::emitRuntime {targetNamespace checkedSchemas} {
    set rt ${targetNamespace}::@rt
    # Schema serialization must be reproducible across source dictionary orders.
    set schemas {}
    foreach name [lsort -ascii [dict keys $checkedSchemas]] {
        dict set schemas $name [dict get $checkedSchemas $name]
    }
    set definitions [list [list ::namespace eval $rt {}]]
    lappend definitions [list ::proc ${rt}::schemas {} [list ::return $schemas]]
    foreach helper {typeParts substituteType specializeSchema} {
        lappend definitions [list ::proc ${rt}::$helper [info args ::appcompiler::$helper] \
            [info body ::appcompiler::$helper]]
    }
    lappend definitions [list ::proc ${rt}::reject {path expected} {
        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected $expected at $path"
    }]
    # Emit the same scalar conversion in both public boundary paths. The
    # list loop can report the exact index without a helper call per item.
    set integerAdmission {
        if {[scan $item %lld%n number consumed] != 2} {reject @path int}
        # Avoid formatting a bignum just to compare its decimal spelling.
        if {$consumed > 18 || ![string equal $item $number]} {
            # Work on a private object to preserve caller-owned native JSON
            # handles. scan skips initial whitespace and may stop at a raw NUL.
            append item {}
            if {![string match {[-+0-9]*} $item] || $consumed != [string length $item]} {
                reject @path int
            }
        }
        set number
    }
    lappend definitions [list ::if {[llength [::info commands ::machteld::x::guardInteger]] &&
                "guardInteger" in [::namespace eval ::machteld::x {namespace export}]} \
            [list ::namespace eval $rt {::namespace import -force ::machteld::x::guardInteger}] else \
            [list ::proc ${rt}::guardInteger {item path} [string map [list @path {$path}] $integerAdmission]]]
    set listItemAdmission [string map [list @path {$path.$index}] $integerAdmission]
    set integers [list ::proc ${rt}::guardIntegerList {value path} [string map [list @admit $listItemAdmission] {
        # Detach the root before llength can convert a caller's typed handle.
        # An ordinary Tcl list keeps its backing store and needs no text copy.
        append value {}
        if {[catch {llength $value}]} {reject $path list<int>}
        set index -1
        return [lmap item $value {
            incr index
            @admit
        }]
    }]]
    lappend definitions [list ::if {[llength [info commands ::machteld::GuardIntegerList]]} \
        [list ::proc ${rt}::guardIntegerList {value path} {::machteld::GuardIntegerList $value $path}] else $integers]
    lappend definitions [list ::proc ${rt}::guardBooleanList {value path} {
        # Parse the root through a local copy so the caller keeps typed handles.
        append value {}
        if {[catch {llength $value}]} {reject $path list<bool>}
        set i -1
        return [lmap item $value {
            incr i
            # Keep the scalar spelling check length-aware on older Tcl hosts.
            if {$item ni {0 1 false true}} {reject $path.$i bool}
            expr {$item in {1 true}}
        }]
    }]
    lappend definitions [list ::proc ${rt}::guardBinary64 {value path {checkExtras 0}} {
        if {[catch {finiteBinary64 $value} number]} {reject $path {finite binary64}}
        if {$checkExtras eq "workerOutput"} {return [binary64Text $number]}
        return $number
    }]
    # A generic boolean guard enters typeParts before it reads the field.
    # Reserve that frame here so a nearly exhausted interpreter reports the same error.
    lappend definitions [list ::proc ${rt}::guardBoolean {value path} {
        wireDepthAvailable 0
        if {$value ni {0 1 false true}} {reject $path bool}
        return [expr {$value in {1 true}}]
    }]
    lappend definitions [list ::proc ${rt}::guardOptional {type first value path checkExtras} {
        # Parse the local container without changing a caller's typed handle.
        append value {}
        if {[catch {llength $value} size]} {reject $path $type}
        set tag [lindex $value 0]
        if {$tag eq "none" && $size == 1} {return [list none]}
        if {$tag ne "some" || $size != 2} {reject $path $type}
        set payload [lindex $value 1]
        switch -- $first {
            int {set payload [guardInteger $payload $path]}
            binary64 {set payload [guardBinary64 $payload $path $checkExtras]}
            text {}
            default {set payload [guard $first $payload $path $checkExtras]}
        }
        return [list some $payload]
    }]
    # Keep the ordinary guard's typeParts frame before catching calendar errors.
    lappend definitions [list ::proc ${rt}::guardTemporalField {type value path} {
        wireDepthAvailable 0
        if {[catch {temporalCanonical $type $value}]} {reject $path "canonical $type"}
        return $value
    }]
    lappend definitions [list ::proc ${rt}::guardRecord {type members value path checkExtras} {
        # Reading a dict can replace a borrowed object's internal type.
        append value {}
        if {[catch {dict size $value}]} {reject $path $type}
        if {$checkExtras in {worker workerOutput} && [llength $value] != 2 * [dict size $value]} {reject $path {unique worker record fields}}
        # Unknown record fields from an extern must remain usable by
        # structural equality and by the JSON writer without type guessing.
        if {$checkExtras ne "0"} {
            dict for {name extra} $value {
                if {$checkExtras in {worker workerOutput} && ![dict exists $members $name]} {
                    reject "$path\[[list $name]\]" {a declared worker message field}
                }
                if {![dict exists $members $name] && [catch {::machteld::json type $extra}]} {
                    reject "$path\[[list $name]\]" {a retained typed JSON value}
                }
            }
        }
        dict for {field fieldType} $members {
            if {![dict exists $value $field]} {
                if {[string index $fieldType end] eq "?"} {continue}
                reject $path.$field $fieldType
            }
            set member [dict get $value $field]
            switch -- $fieldType {
                text {}
                int {set member [guardInteger $member $path.$field]}
                bool {set member [guardBoolean $member $path.$field]}
                instant - local_datetime {set member [guardTemporalField $fieldType $member $path.$field]}
                binary64 {set member [guardBinary64 $member $path.$field $checkExtras]}
                int? {set member [guardOptional int? int $member $path.$field $checkExtras]}
                text? {set member [guardOptional text? text $member $path.$field $checkExtras]}
                binary64? {set member [guardOptional binary64? binary64 $member $path.$field $checkExtras]}
                default {set member [guard $fieldType $member $path.$field $checkExtras]}
            }
            dict set value $field $member
        }
        return $value
    }]
    # The loop replaces the recursive guard frame for each row, so the
    # integer validator still runs at the same interpreter recursion depth.
    lappend definitions [list ::proc ${rt}::guardIntegerRows {rows path} {
        set result {}
        foreach row $rows {
            lappend result [guardIntegerList $row $path.[llength $result]]
        }
        return $result
    }]
    lappend definitions [list ::proc ${rt}::guard {type value path {checkExtras 0}} {
        # List, dict and byte conversions can consume a native Tcl object.
        # Detach the local value only in the branches that parse it.
        lassign [typeParts $type] head first second
        if {$head eq "optional"} {return [guardOptional $type $first $value $path $checkExtras]}
        switch -exact -- $head {
            callable {return [guardCallable $type $value $path]}
            ref {return [guardReference $first $value $path]}
            process_stream {return [guardStream $value $path]}
            task {return [guardTask $first $value $path]}
            tk_window - tk_label - tk_button - tk_canvas - tk_item {
                if {![llength [info commands [namespace current]::tkGuard]]} {reject $path "a live $head from this application"}
                return [tkGuard $head $value $path]
            }
            range {
                append value {}
                if {$type ne "range<int>" || [catch {llength $value} size] || $size != 3} {reject $path $type}
                lassign $value start end closed
                if {$closed ni {0 1}} {reject $path.closed {0 or 1}}
                return [list [guard int $start $path.start] [guard int $end $path.end] $closed]
            }
            list {
                if {$first eq "int"} {return [guardIntegerList $value $path]}
                if {$first eq "bool"} {return [guardBooleanList $value $path]}
                if {$first eq "text"} {
                    # A full slice returns the canonical list spelling while
                    # retaining its elements. Parse a private outer object.
                    append value {}
                    if {[catch {lrange $value 0 end} words]} {reject $path $type}
                    return $words
                }
                append value {}
                if {[catch {llength $value}]} {reject $path $type}
                set result {}
                # All rows in a monomorphic record list use the same schema.
                set entry [dict getdef [schemas] $first {}]
                if {[lindex $entry 0] eq "record" && [llength $entry] == 2} {
                    set members [lindex $entry 1]
                    foreach item $value {lappend result [guardRecord $first $members $item $path.[llength $result] $checkExtras]}
                    return $result
                }
                if {$first eq "list<int>"} {return [guardIntegerRows $value $path]}
                set index 0
                foreach item $value {
                    lappend result [guard $first $item $path.$index $checkExtras]
                    incr index
                }
                return $result
            }
            map {
                append value {}
                set keyType [scalarBase $first]
                if {$keyType ni {text int bool decimal} || [catch {dict size $value}]} {reject $path $type}
                if {$checkExtras in {worker workerOutput} && [llength $value] != 2 * [dict size $value]} {reject $path {unique worker map keys}}
                # Text map keys require one representation for equivalent Tcl strings.
                set keyGuard [expr {$keyType eq "text" ? "@textKey" : $keyType}]
                set result {}
                dict for {external item} $value {
                    set key [guard $keyGuard $external "$path key"]
                    if {[dict exists $result $key]} {
                        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} \
                            "map keys at $path normalize to the same $first key [list $key]"
                    }
                    dict set result $key [guard $second $item "$path\[[list $key]\]" $checkExtras]
                }
                return $result
            }
            result {
                append value {}
                if {[catch {llength $value} size] || $size != 2} {reject $path $type}
                lassign $value tag payload
                switch -exact -- $tag {
                    ok  {return [list ok  [guard $first $payload $path.ok $checkExtras]]}
                    err {return [list err [guard $second $payload $path.err $checkExtras]]}
                    default {reject $path $type}
                }
            }
            unit {
                if {$value ne ""} {reject $path unit}
                return {}
            }
            bytes {
                append value {}
                # Tcl 9 binary scan requires every character to fit in a byte.
                if {[catch {binary scan $value a* octets}]} {reject $path bytes}
                return $octets
            }
            problem {
                append value {}
                if {[catch {dict size $value}] || ![dict exists $value message]} {reject $path problem}
                if {[dict exists $value byteOffset]} {
                    set offset [guard int [dict get $value byteOffset] $path.byteOffset]
                    if {$offset < 0} {reject $path.byteOffset {a nonnegative byte offset}}
                    dict set value byteOffset $offset
                }
                if {[dict exists $value origin]} {
                    dict set value origin [guardLocation [dict get $value origin] $path.origin]
                }
                if {$checkExtras in {worker workerOutput}} {
                    set fields {}
                    foreach key {message code origin byteOffset} {
                        if {[dict exists $value $key]} {dict set fields $key [dict get $value $key]}
                    }
                    if {[dict exists $fields origin]} {
                        set where [dict get $fields origin]
                        dict set fields origin [dict create module [dict get $where module] \
                            line [dict get $where line] column [dict get $where column]]
                    }
                    return $fields
                }
                return $value
            }
            int {return [guardInteger $value $path]}
            decimal {
                if {[catch {decimal::canonical $value} normalized]} {reject $path decimal}
                return $normalized
            }
            binary64 {return [guardBinary64 $value $path $checkExtras]}
            instant - local_datetime {
                if {[catch {temporalCanonical $type $value}]} {reject $path "canonical $type"}
                return $value
            }
            bool {
                if {$value ni {0 1 false true}} {reject $path bool}
                return [expr {$value in {1 true}}]
            }
            @textKey {return [mapTextKey $value]}
            text {return $value}
        }
        lassign [specializeSchema $type [schemas]] kind members
        if {$kind eq "distinct"} {return [guard $members $value $path $checkExtras]}
        if {$kind eq "record"} {return [guardRecord $type $members $value $path $checkExtras]}
        append value {}
        if {[catch {llength $value} size] || $size < 1} {reject $path $type}
        set tag [lindex $value 0]
        if {![dict exists $members $tag]} {reject $path $type}
        set payload [dict get $members $tag]
        if {$size != 1 + [llength $payload]} {reject $path $type}
        set result [list $tag]
        set index 0
        foreach fieldType $payload {
            incr index
            lappend result [guard $fieldType [lindex $value $index] $path.$tag.$index $checkExtras]
        }
        return $result
    }]
    return $definitions
}

proc ::appcompiler::emitLocation {node} {
    return [dict create module [dict get $node module] line [dict get $node line] \
        column [dict get $node column]]
}

proc ::appcompiler::emitFacts {node context} {
    set key [list [dict get $node module] [dict get $node line] [dict get $node column] [dict get $node kind]]
    return [dict getdef $context facts $key {}]
}

# Closed types stay literal Tcl words. Types mentioning a parameter acquire
# the concrete caller's descriptor before a runtime boundary sees them.
proc ::appcompiler::emitTypeWord {type context} {
    if {[string first @ $type] < 0} {return [list $type]}
    return [format {[%s %s $m_types]} [list [dict get $context target]::@rt::substituteType] [list $type]]
}

proc ::appcompiler::emitTypeList {types context} {
    if {[string first @ $types] < 0} {return [list $types]}
    return [format {[::list %s]} [join [lmap type $types {emitTypeWord $type $context}] { }]]
}

proc ::appcompiler::emitMapKeyWord {node context word} {
    if {[dict get [emitFacts $node $context] keyType] ne "text"} {return $word}
    set command [dict get $context target]::@rt::mapTextKey
    return [format {[%s %s]} [list $command] $word]
}

proc ::appcompiler::propagatedFloat {node context} {
    if {[dict get $node kind] ne "propagate"} {return 0}
    set value [dict get $node value]
    return [expr {[dict get $value kind] eq "binary" && [dict get $value op] in {+ - *} &&
            [dict getdef [emitFacts $value $context] operandType {}] eq "binary64"}]
}

# Finite results that round to negative zero may flow directly into another
# +, - or *. The sign can affect only the sign of a later zero. Normalize
# once at the observable boundary. Keep each overflow check before the next
# operand is read to preserve failures, Tcl traces and callback order.
# Preserve every source leaf read in the original expression. In particular a
# failure of the left subtree still prevents any right-subtree evaluations.
proc ::appcompiler::emitFloatOperand {operand context bindings depth} {
    if {[propagatedFloat $operand $context]} {
        return [emitPropagatedFloat $operand $context $bindings $depth 0]
    }
    return [emitExpression $operand $context $bindings $depth]
}

proc ::appcompiler::emitFloatCheckParts {node context bindings depth} {
    set value [dict get $node value]
    set op [dict get $value op]
    set lhs [dict get $value left]
    set left [emitFloatOperand $lhs $context $bindings $depth]
    set rhs [dict get $value right]
    set where [expr {[dict get $context problemResult] ? [emitLocation $node] : {}}]
    set location [list $where]
    if {$op in {+ -} && [propagatedFloat $lhs $context] && [propagatedFloat $rhs $context]} {
        # The checked left operand is finite. For both + and -, an infinite right
        # result propagates to infinity. No source operands remain to read at
        # this point. Save the right result to attribute overflow exactly.
        set inner [dict get $rhs value]
        set a [emitFloatOperand [dict get $inner left] $context $bindings $depth]
        set b [emitFloatOperand [dict get $inner right] $context $bindings $depth]
        set right [format {[::set m_fp_rhs [::expr {%s %s %s}]]} $a [dict get $inner op] $b]
        if {[dict get $context problemResult]} {
            set location [format {[::expr {abs($m_fp_rhs) == Inf ? %s : %s}]} [list [emitLocation $rhs]] [list $where]]
        }
    } else {
        set right [emitFloatOperand $rhs $context $bindings $depth]
    }
    set number [format {[::set m_fp [::expr {%s %s %s}]]} $left $op $right]
    set rt [dict get $context target]::@rt
    set overflow [format {[%s [%s] %s]} [list ${rt}::propagate] [list ${rt}::binaryOverflow] $location]
    return [list $number $overflow]
}

proc ::appcompiler::emitPropagatedFloat {node context bindings depth canonical} {
    lassign [emitFloatCheckParts $node $context $bindings $depth] number overflow
    # Adding positive zero preserves each finite nonzero double exactly.
    set result [expr {$canonical ? {(0.0 + $m_fp)} : {$m_fp}}]
    # Direct comparisons compile to Tcl bytecode. The right test reads
    # only the computed double, after all source operands have been read.
    return [format {[::expr {(%s == Inf || $m_fp == -Inf) ? %s : %s}]} $number $overflow $result]
}

# Capability selection happens when an application is loaded. The same
# archive retains its original Tcl bytecode on a host without these operators.
proc ::appcompiler::nativeFloatOperand {node context bindings depth raw} {
    if {$raw && [propagatedFloat $node $context]} {
        # A non-double supplied by a Tcl read trace can retain a Tcl integer
        # intermediate between checked arithmetic operations.
        set inner [dict get $node value]
        return [nativeFloatWord [dict get $inner op] $inner $context $bindings $depth $node 1]
    }
    return [emitExpression $node $context $bindings $depth]
}
proc ::appcompiler::nativeFloatWord {operation node context bindings depth {propagation {}} {raw 0}} {
    set commands {+ add - subtract * multiply / divide neg negate < less <= lessEqual
        > greater >= greaterEqual == equal != notEqual}
    set command ::machteld::x::binary64v1::[dict get $commands $operation]
    if {$operation eq "neg"} {
        return [format {[%s %s]} $command [emitExpression [dict get $node value] $context $bindings $depth]]
    }
    set rawChildren [expr {($propagation ne {} && $operation in {+ - *}) ||
        ($operation in {< <= > >=} && [propagatedFloat [dict get $node left] $context] &&
        [propagatedFloat [dict get $node right] $context])}]
    set left [nativeFloatOperand [dict get $node left] $context $bindings $depth $rawChildren]
    set rhs [dict get $node right]
    if {[dict getdef $context floatPairs 0] && $operation in {+ - * < <= > >= == !=} &&
            [propagatedFloat $rhs $context]} {
        # Tcl has read the left operand and both inner operands by the time
        # this pair runs. The original inner and outer failures keep their
        # individual question-mark locations.
        set inner [dict get $rhs value]
        set middle [nativeFloatOperand [dict get $inner left] $context $bindings $depth 1]
        set right [nativeFloatOperand [dict get $inner right] $context $bindings $depth 1]
        set innerAt [expr {[dict get $context problemResult] ? [emitLocation $rhs] : {}}]
        set outerAt [expr {$propagation ne {} && [dict get $context problemResult] ? [emitLocation $propagation] : {}}]
        set flags [expr {$rawChildren | (($propagation ne {}) << 1) | ($raw << 2)}]
        return [format {[::machteld::x::binary64v1::rightPair %s %s %s %s %s %s %s %s %d]} \
            $left $middle $right [list [dict get $context target]::@rt::propagate] \
            [list $innerAt] [list $outerAt] [dict get $commands $operation] [dict get $commands [dict get $inner op]] $flags]
    }
    set right [nativeFloatOperand $rhs $context $bindings $depth $rawChildren]
    if {$propagation eq {}} {return [format {[%s %s %s]} $command $left $right]}
    set where [expr {[dict get $context problemResult] ? [emitLocation $propagation] : {}}]
    return [format {[%s %s %s %s %s%s]} $command $left $right \
        [list [dict get $context target]::@rt::propagate] [list $where] [expr {$raw ? " raw" : ""}]]
}

proc ::appcompiler::emitExpression {node context {bindings {}} {depth 0}} {
    set targetNamespace [dict get $context target]
    set module [dict get $context module]
    set kind [dict get $node kind]
    switch -exact -- $kind {
        toolPath {
            return [format {[%s %s]} [list [dict get $context target]::@rt::toolPath] [emitTextWord [dict get $node value]]]
        }
        int  {return [emitIntegerWord [dict get $node value]]}
        decimal {return [list [decimal::canonical [dict get $node value]]]}
        text {return [emitTextWord [dict get $node value]]}
        list {
            set words [list ::list]
            foreach item [dict get $node items] {
                lappend words [emitExpression $item $context $bindings $depth]
            }
            return [format {[%s]} [join $words { }]]
        }
        interpolate {
            # Each segment is one Tcl word. Command substitutions run from
            # left to right and a propagated error skips the remaining words.
            set words [list ::string cat]
            foreach part [dict get $node parts] {
                if {[dict get $part kind] eq "text"} {
                    lappend words [emitTextWord [dict get $part value]]
                    continue
                }
                set word [emitExpression [dict get $part value] $context $bindings $depth]
                switch -- [dict get [emitFacts $part $context] interpolationType] {
                    bool {set word [format {[::expr {%s ? "true" : "false"}]} $word]}
                    binary64 {set word [format {[%s %s]} [list ${targetNamespace}::@rt::binary64Text] $word]}
                }
                lappend words $word
            }
            return [format {[%s]} [join $words { }]]
        }
        unit {return {{}}}
        bool {
            switch -exact -- [dict get $node value] {
                true  - 1 {return 1}
                false - 0 {return 0}
                default {error "invalid boolean in checked application"}
            }
        }
        var {
            set name [dict get $node name]
            if {[dict exists $bindings $name]} {return [dict get $bindings $name]}
            return [format {$%s} [emitLocalName $name]]
        }
        functionValue {
            set facts [emitFacts $node $context]
            set name [dict get $node name]
            if {[dict exists $facts constructor]} {return [list $name]}
            set qualifier [dict get $node qualifier]
            if {$qualifier eq ""} {set qualifier $module}
            set types [emitTypeList [dict getdef $facts typeArguments {}] $context]
            return [format {[::list %s %s %s {}]} [list ${targetNamespace}::@rt::invokeCallback] \
                [list [list $qualifier $name]] $types]
        }
        invoke {
            set prefix [emitExpression [dict get $node value] $context $bindings $depth]
            set words [list "{*}$prefix"]
            foreach argument [dict get $node args] {
                lappend words [emitExpression $argument $context $bindings $depth]
            }
            return [format {[%s]} [join $words { }]]
        }
        unary {
            if {[dict getdef $context nativeFloat 0] &&
                    [dict getdef [emitFacts $node $context] operandType {}] eq "binary64"} {
                return [nativeFloatWord neg $node $context $bindings $depth]
            }
            set value [emitExpression [dict get $node value] $context $bindings $depth]
            if {[dict get $node op] eq "!"} {return [format {[::tcl::mathop::! %s]} $value]}
            if {[dict get [emitFacts $node $context] operandType] eq "decimal"} {
                return [format {[%s - 0 %s]} [list ${targetNamespace}::@rt::decimal::calc] $value]
            }
            if {[dict get [emitFacts $node $context] operandType] eq "binary64"} {
                return [format {[::tcl::mathop::- 0.0 %s]} $value]
            }
            return [format {[::tcl::mathop::- %s]} $value]
        }
        binary {
            set op [dict get $node op]
            if {[dict getdef $context nativeFloat 0] &&
                    [dict getdef [emitFacts $node $context] operandType {}] eq "binary64"} {
                return [nativeFloatWord $op $node $context $bindings $depth]
            }
            set lhs [dict get $node left]
            set rhs [dict get $node right]
            if {$op in {< <= > >=} && [propagatedFloat $lhs $context] && [propagatedFloat $rhs $context]} {
                # The left result is finite before the right operands run. Each
                # comparison outcome admits only one sign of right overflow.
                # Both operands are numbers here, so the sign of zero is immaterial.
                set left [emitFloatOperand $lhs $context $bindings $depth]
                lassign [emitFloatCheckParts $rhs $context $bindings $depth] right overflow
                lassign [expr {$op in {< <=} ? {Inf -Inf} : {-Inf Inf}}] trueInfinity falseInfinity
                return [format {[::expr {%s %s %s ? ($m_fp == %s ? %s : 1) : ($m_fp == %s ? %s : 0)}]} \
                    $left $op $right $trueInfinity $overflow $falseInfinity $overflow]
            }
            set left [emitExpression $lhs $context $bindings $depth]
            set right [emitExpression $rhs $context $bindings $depth]
            if {$op in {&& ||}} {
                # Keep both substitutions in a braced expression so Tcl
                # evaluates the right one only when the left demands it.
                return [format {[::expr {%s %s %s}]} $left $op $right]
            }
            if {$op in {< <= > >=}} {
                set type [dict get [emitFacts $node $context] operandType]
                switch -exact -- $type {
                    int - binary64 {return [format {[::tcl::mathop::%s %s %s]} $op $left $right]}
                    decimal {set compare [list ${targetNamespace}::@rt::compareNumericMapKeys]}
                    text {set compare [list ${targetNamespace}::@rt::compareText]}
                    instant - local_datetime {set compare {::string compare}}
                    default {error "unexpected ordered type: [list $type]"}
                }
                return [format {[::tcl::mathop::%s [%s %s %s] 0]} $op $compare $left $right]
            }
            if {$op in {.. ..=}} {
                return [format {[::list %s %s %d]} $left $right [expr {$op eq "..="}]]
            }
            if {$op in {+ - * /} && [dict getdef [emitFacts $node $context] operandType {}] eq "binary64"} {
                return [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::binaryArithmetic] $op $left $right]
            }
            if {$op eq "/"} {
                return [format {[%s %s %s]} [list ${targetNamespace}::@rt::decimal::divide] $left $right]
            }
            if {$op in {== !=}} {
                set type [dict get [emitFacts $node $context] operandType]
                switch -- $type {
                    int - bool - binary64 {return [format {[::expr {%s %s %s}]} $left $op $right]}
                    decimal - instant - local_datetime {set command {::string equal}}
                    text {set command [list ${targetNamespace}::@rt::equalText]}
                    default {
                        if {[dict exists $context recordComparators $type]} {
                            set command [list [dict get $context recordComparators $type]]
                        } else {
                            set command [format {%s %s} [list ${targetNamespace}::@rt::equal] [emitTypeWord $type $context]]
                        }
                    }
                }
                set comparison [format {[%s %s %s]} $command $left $right]
                if {$op eq "!="} {return [format {[::tcl::mathop::! %s]} $comparison]}
                return $comparison
            }
            if {$op ni {+ - *}} {error "unsupported application operator: [list $op]"}
            if {[dict getdef [emitFacts $node $context] operandType {}] eq "decimal"} {
                return [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::decimal::calc] $op $left $right]
            }
            return [format {[::tcl::mathop::%s %s %s]} $op $left $right]
        }
        call - construct - builtin - sqlBegin - refCreate - tkOpen {
            set facts [emitFacts $node $context]
            if {[dict exists $facts recordConstructor]} {
                set words [list ::dict create]
                foreach argument [dict get $node args] {
                    lappend words [list [dict get $argument argumentLabel name]] [emitExpression $argument $context $bindings $depth]
                }
                return [format {[%s]} [join $words { }]]
            }
            # These explicit conversions preserve the checked Tcl representation.
            if {$kind eq "builtin" && [dict get $node name] in {make underlying instant_text local_datetime_text}} {
                return [emitExpression [lindex [dict get $node args] 0] $context $bindings $depth]
            }
            set words [emitCallPrefix $node $context]
            set arguments [lmap argument [dict get $node args] {
                emitExpression $argument $context $bindings $depth
            }]
            if {$kind eq "builtin" && [dict get $node name] eq "list_append"} {
                set arguments [linsert $arguments 1 end]
            }
            if {$kind eq "builtin" && [dict get $node name] in {map_put require_key}} {
                lset arguments 1 [emitMapKeyWord $node $context [lindex $arguments 1]]
            }
            if {[dict exists $facts sqlBindings] && [dict get $node name] ne "sql_commit"} {
                set values [format {[::list %s]} [join [lrange $arguments 2 end] { }]]
                lappend words {*}[lrange $arguments 0 1] [emitTypeList [dict get $facts sqlBindings] $context] $values
            } else {
                lappend words {*}$arguments
            }
            if {$kind eq "sqlBegin" || [dict exists $facts sqlBindings]} {
                return [format {[%s [%s] %s]} [list ${targetNamespace}::@rt::atResult] \
                    [join $words { }] [list [emitLocation $node]]]
            }
            return [format {[%s]} [join $words { }]]
        }
        propagate {
            set value [dict get $node value]
            if {[dict getdef $context nativeFloat 0] && [dict get $value kind] eq "binary" &&
                    [dict get $value op] in {+ - * /} &&
                    [dict getdef [emitFacts $value $context] operandType {}] eq "binary64"} {
                return [nativeFloatWord [dict get $value op] $value $context $bindings $depth $node]
            }
            set where [expr {[dict get $context problemResult] ? [emitLocation $node] : {}}]
            if {[dict get $value kind] eq "builtin" && [dict get $value name] eq "require_index"} {
                lassign [dict get $value args] items index
                set base [emitExpression $items $context $bindings $depth]
                set key [emitExpression $index $context $bindings $depth]
                return [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::checkedIndex] $base $key [list $where]]
            }
            if {[propagatedFloat $node $context]} {
                return [emitPropagatedFloat $node $context $bindings $depth 1]
            }
            set operand [emitExpression $value $context $bindings $depth]
            return [format {[%s %s %s]} [list ${targetNamespace}::@rt::propagate] $operand [list $where]]
        }
        none {return none}
        some {
            set word [emitExpression [dict get $node value] $context $bindings $depth]
            return [format {[::list some %s]} $word]
        }
        field {
            # Exported record guards have already checked every required field.
            set base [emitExpression [dict get $node base] $context $bindings $depth]
            return [format {[::dict getdef %s %s none]} $base [list [dict get $node name]]]
        }
        index {
            set base [emitExpression [dict get $node base] $context $bindings $depth]
            set key [emitExpression [dict get $node key] $context $bindings $depth]
            if {[dict exists [emitFacts $node $context] listIndex]} {
                return [format {[%s %s %s]} [list ${targetNamespace}::@rt::listLookup] $base $key]
            }
            set key [emitMapKeyWord $node $context $key]
            return [format {[%s %s %s]} [list ${targetNamespace}::@rt::mapLookup] $base $key]
        }
        update {
            set base [emitExpression [dict get $node base] $context $bindings $depth]
            set words [list ::dict replace $base]
            foreach field [dict get $node fields] {
                lappend words [list [dict get $field name]] \
                    [emitExpression [dict get $field value] $context $bindings $depth]
            }
            return [format {[%s]} [join $words { }]]
        }
        match {
            return [emitMatch $node $context $bindings $depth]
        }
        default {error "unsupported application expression: [list $kind]"}
    }
}

proc ::appcompiler::emitCallPrefix {node context} {
    set facts [emitFacts $node $context]
    set target [dict get $context target]
    switch -exact -- [dict get $node kind] {
        sqlBegin {return [list [list ${target}::@rt::sqlBegin]]}
        refCreate {return [list [list ${target}::@rt::newReference] [emitTypeWord [dict get $facts elementType] $context]]}
        tkOpen {return [list [list ${target}::@rt::tk_open]]}
        construct {return [list ::list [list [dict get $node variant]]]}
        call {
            set name [dict get $node name]
            if {[dict exists $facts constructor]} {return [list ::list [list $name]]}
            set calleeModule [dict get $node qualifier]
            if {$calleeModule eq ""} {set calleeModule [dict get $context module]}
            if {[dict exists $node workerStart]} {
                return [list [list ${target}::@rt::workerStart] [dict get $node workerStart] [list $calleeModule.$name]]
            }
            set types [dict getdef $facts typeArguments {}]
            if {[dict exists $facts directEntry]} {
                set prefix [list [list ${target}::${calleeModule}::@${name}]]
                if {[llength $types]} {
                    set bindings {}
                    foreach variable [dict get $facts directEntry] type $types {
                        dict set bindings $variable $type
                    }
                    lappend prefix [list $bindings]
                }
            } else {
                set prefix [list [list ${target}::${calleeModule}::${name}]]
                if {[llength $types]} {lappend prefix [emitTypeList $types $context]}
            }
            return $prefix
        }
        builtin {
            set name [dict get $node name]
            if {[dict exists $facts tkOperation]} {
                set prefix [list [list ${target}::@rt::${name}]]
                if {$name in {tk_on_click tk_on_action}} {lappend prefix [list [emitLocation $node]]}
                return $prefix
            }
            switch -exact -- $name {
                unit - list {return [list ::list]}
                list_append {return [list ::linsert]}
                map {return [list ::dict create]}
                bind {return [list [list ${target}::@rt::bindCallback]]}
                len {
                    switch -- [dict get $facts lengthKind] {
                        list {return [list ::llength]}
                        map {return [list ::dict size]}
                        bytes {return [list ::string length]}
                        text {
                            set operand [lindex [dict get $node args] 0]
                            if {[dict get $operand kind] eq "text"} {return [list ::string length]}
                            return [list [list ${target}::@rt::textLength]]
                        }
                    }
                }
                ref_get - ref_set - ref_same {return [list [list ${target}::@rt::${name}]]}
                map_put {return [list ::dict replace]}
                require_key - require_index {return [list [list ${target}::@rt::${name}]]}
                sorted_keys {return [list [list ${target}::@rt::sorted_keys] [list [dict get $facts keyType]]]}
                ok - err {return [list ::list $name]}
                decode_json - encode_json {
                    return [list [list ${target}::@rt::${name}] [emitTypeWord [dict get $facts schema] $context]]
                }
                sql_one - sql_optional - sql_many {
                    set reader [expr {[dict get $facts transaction] ? "sqlTxRead" : "sqlRead"}]
                    return [list [list ${target}::@rt::${reader}] [string range $name 4 end] [emitTypeWord [dict get $facts schema] $context]]
                }
                sql_exec {return [list [list ${target}::@rt::sqlExec]]}
                sql_schema {return [list [list ${target}::@rt::sqlSchema]]}
                sql_returning_one - sql_returning_optional - sql_returning_many {
                    return [list [list ${target}::@rt::sqlReturning] [lindex [split $name _] end] [emitTypeWord [dict get $facts schema] $context]]
                }
                sql_commit {return [list [list ${target}::@rt::sqlCommit]]}
                await - cancel - problem - read_stdin_bytes - decode_utf8 - decode_text - preview_text - write_stdout_utf8 -
                parse_instant - parse_local_datetime - resolve_offset - resolve_zone - capture_process -
                close_process - cancel_process - find_executable {
                    return [list [list ${target}::@rt::${name}]]
                }
                stream_process {return [list [list ${target}::@rt::stream_process] [list [emitLocation $node]]]}
                quotient {return [list [list ${target}::@rt::decimal::quotient]]}
                to_binary64 - exact_decimal {return [list [list ${target}::@rt::${name}]]}
                divide_rounded {return [list [list ${target}::@rt::decimal::rounded]]}
                default {error "unsupported application builtin: [list $name]"}
            }
        }
    }
}

# A grouped arm can bind the same name from a different payload slot in
# each variant. Keep one copy of its body and select the slot by tag only
# for captures whose position varies.
proc ::appcompiler::choiceCaptures {alternatives slot bindings setupVar} {
    upvar 1 $setupVar setup
    set positions {}
    foreach alternative $alternatives {
        set tag [dict get $alternative variant]
        set index 0
        foreach capture [dict get $alternative bindings] {
            incr index
            if {[dict get $capture kind] eq "discard"} {continue}
            dict set positions [dict get $capture name] $tag $index
        }
    }
    dict for {name byTag} $positions {
        set indexes [dict values $byTag]
        set index [lindex $indexes 0]
        if {[lsearch -exact -not $indexes $index] >= 0} {
            set local ${slot}_[emitLocalName $name]
            lappend setup [format {::set %s [::lindex $%s [::dict get %s [::lindex $%s 0]]]} \
                    $local $slot [list $byTag] $slot]
            dict set bindings $name [format {$%s} $local]
        } else {
            dict set bindings $name [format {[::lindex $%s %d]} $slot $index]
        }
    }
    return $bindings
}

proc ::appcompiler::emitMatch {node context bindings depth {destination {}}} {
    # A nested arm must still be able to read its enclosing match's captures.
    # These names cannot coincide with the v_ prefix used for source locals.
    set slot m_$depth
    set arms [dict get $node arms]
    set input [dict get $node value]
    if {[dict get $input kind] eq "index" && [llength $arms] == 2} {
        return [emitIndexMatch $input $arms $slot $context $bindings [expr {$depth + 1}]]
    }
    set scrutinee [emitExpression $input $context $bindings $depth]
    if {[dict get [lindex $arms 0] kind] in {listarm fallback}} {
        return [emitListMatch $scrutinee $slot $arms $context $bindings $depth]
    }
    set selector [format {[::lindex [::set %s %s] 0]} $slot $scrutinee]
    set words [list ::switch -exact -- $selector]
    foreach arm $arms {
        set alternatives [dict getdef $arm alternatives [list $arm]]
        set actions {}
        set scope [choiceCaptures $alternatives $slot $bindings actions]
        foreach alternative [lrange $alternatives 0 end-1] {
            lappend words [list [dict get $alternative variant]] -
        }
        set lastTag [dict get [lindex $alternatives end] variant]
        if {$destination ne {}} {
            lappend actions [emitAssignment $destination [dict get $arm body] $context $scope [expr {$depth + 1}]]
        } else {
            set result [emitExpression [dict get $arm body] $context $scope [expr {$depth + 1}]]
            # A level-zero return produces the arm value with normal Tcl
            # completion. Keeping it in a local would leave another owner
            # when the caller next updates the chosen list or dictionary.
            lappend actions [format {::return -level 0 %s} $result]
        }
        lappend words [list $lastTag] [list [join $actions {; }]]
    }
    # An explicit final default also allows a user variant named "default".
    lappend words default [list {::return -code error -errorcode {APPCOMPILER VALUE CHOICE} {invalid choice tag}}]
    if {$destination ne {}} {
        # The arm has stored its result. Release the scrutinee so a later
        # mutation need not copy an otherwise unshared captured collection.
        return [format {%s; ::unset %s} [join $words { }] $slot]
    }
    return [format {[%s]} [join $words { }]]
}

# A lookup immediately consumed by some/none can branch on presence itself.
proc ::appcompiler::emitIndexMatch {input arms slot context bindings depth} {
    lassign $arms present absent
    if {[dict get $present variant] eq "none"} {lassign $arms absent present}
    set capture [lindex [dict get $present bindings] 0]
    set base [emitExpression [dict get $input base] $context $bindings $depth]
    set key [emitExpression [dict get $input key] $context $bindings $depth]
    set missing [emitExpression [dict get $absent body] $context $bindings $depth]
    set subscript ${slot}_key
    set listIndex [dict exists [emitFacts $input $context] listIndex]
    if {$listIndex} {
        # Keep listLookup's miss test: an unordered numeric index still reaches
        # lindex, which reports it as invalid rather than treating it as absent.
        set test [format {!($%s < 0 || $%s >= [::llength $%s])} $subscript $subscript $slot]
        set element [format {[::lindex $%s $%s]} $slot $subscript]
    } else {
        set key [emitMapKeyWord $input $context $key]
        set body [dict get $present body]
        # dict getdef evaluates its default eagerly. Only pass literal defaults.
        if {[dict get $capture kind] ne "discard" && [dict get $body kind] eq "var" &&
                [dict get $body name] eq [dict get $capture name] &&
                [dict get $absent body kind] in {int decimal bool text unit none}} {
            return [format {[::dict getdef %s %s %s]} $base $key $missing]
        }
        set test [format {[::dict exists $%s $%s]} $slot $subscript]
        set element [format {[::dict get $%s $%s]} $slot $subscript]
    }
    # Release the captured collection before the selected arm. Leaving its
    # value in a scratch local would force copies on later in-place updates.
    set clear [list ::unset $slot $subscript]
    if {[dict get $capture kind] eq "discard"} {
        set setup $clear
        if {$listIndex} {
            # A present abstract-list element can throw even when its value is discarded.
            set setup [format {::lindex $%s $%s; %s} $slot $subscript $clear]
        }
    } else {
        set setup [format {::set %s %s; ::unset %s} $slot $element $subscript]
        dict set bindings [dict get $capture name] [format {$%s} $slot]
    }
    set found [emitExpression [dict get $present body] $context $bindings $depth]
    set yes [list [format {%s; ::return -level 0 %s} $setup $found]]
    set no [list [format {%s; ::return -level 0 %s} $clear $missing]]
    return [format {[::set %s %s; ::set %s %s; ::if {%s} %s else %s]} \
        $slot $base $subscript $key $test $yes $no]
}

proc ::appcompiler::emitListMatch {scrutinee slot arms context bindings depth} {
    set branches {}
    set equalText [list [dict get $context target]::@rt::equalText]
    foreach arm $arms {
        set scope $bindings
        if {[dict get $arm kind] eq "fallback"} {
            if {[llength $branches]} {lappend branches else}
        } else {
            set elements [dict get $arm elements]
            set conditions [list [format {[::llength $%s] == %d} $slot [llength $elements]]]
            set index 0
            foreach pattern $elements {
                set item [format {[::lindex $%s %d]} $slot $index]
                if {[dict get $pattern kind] eq "patternText"} {
                    lappend conditions [format {[%s %s %s]} $equalText $item [emitTextWord [dict get $pattern value]]]
                } else {
                    dict set scope [dict get $pattern name] $item
                }
                incr index
            }
            lappend branches [expr {[llength $branches] ? "elseif" : "::if"}] [list [join $conditions { && }]]
        }
        set value [emitExpression [dict get $arm body] $context $scope [expr {$depth + 1}]]
        set action [format {::return -level 0 %s} $value]
        if {![llength $branches]} {
            # A match with just a fallback still evaluates its input once.
            return [format {[::set %s %s; %s]} $slot $scrutinee $action]
        }
        lappend branches [list $action]
    }
    return [format {[::set %s %s; %s]} $slot $scrutinee [join $branches { }]]
}

proc ::appcompiler::emitAssignment {name value context bindings depth} {
    set local [emitLocalName $name]
    # Read the base value before evaluating subsequent operands. A Tcl
    # callback may trace or replace the local before the final assignment.
    return [format {::set %s %s} $local [emitExpression $value $context $bindings $depth]]
}

proc ::appcompiler::emitStatement {node context} {
    set kind [dict get $node kind]
    if {$kind in {break continue}} {
        set label [dict get $node label]
        if {$label eq {} || $label eq [dict get $context nearestLoop]} {return ::$kind}
        set code [loopCode [dict get $context loopIndices $label] $kind]
        return [list ::return -level 0 -code $code]
    }
    set value [dict get $node value]
    if {$kind eq "assign"} {
        set name [dict get $node name]
        if {[dict get $value kind] eq "match" && [dict get $value value kind] ne "index"
                && [dict get [lindex [dict get $value arms] 0] kind] eq "optionalArm"} {
            return [emitMatch $value $context {} 0 $name]
        }
        return [emitAssignment $name $value $context {} 0]
    }
    if {$kind eq "bind" && [dict get $value kind] eq "propagate" &&
            [dict get $value value kind] eq "builtin" && [dict get $value value name] eq "require_index" &&
            ![dict getdef $context locateScope 0]} {
        # At a binding, the checked element can go straight into its destination.
        # Read the list first, read the index once, and release both snapshots
        # before the new binding can trigger Tcl variable traces.
        lassign [dict get $value value args] items index
        if {[dict get $items kind] eq "var" && [dict get $index kind] eq "var"} {
            set rt [dict get $context target]::@rt
            set where [expr {[dict get $context problemResult] ? [emitLocation $value] : {}}]
            set clear {::unset m_lookup_list m_lookup_index}
            set fault [format {[%s $m_lookup_list $m_lookup_index]} [list ${rt}::indexFailure]]
            set element {[::lindex $m_lookup_list $m_lookup_index]}
            # Select an already-evaluated word after releasing both snapshots.
            # The returned object has no extra local owner when the destination
            # write (or the propagation of an error) can run Tcl observers.
            set afterClear {[::lindex [::list %s [%s]] 0]}
            set missing [format {%s %s %s} [list ${rt}::propagate] [format $afterClear $fault $clear] [list $where]]
            set steps [list [format {::set m_lookup_list %s} [emitExpression $items $context]]]
            lappend steps [format {::if {[::set m_lookup_index %s] < 0 || $m_lookup_index >= [::llength $m_lookup_list]} {%s}} \
                [emitExpression $index $context] $missing]
            lappend steps [format {::set %s %s} [emitLocalName [dict get $node name]] [format $afterClear $element $clear]]
            return [join $steps {; }]
        }
    }
    set word [emitExpression $value $context]
    switch -exact -- $kind {
        bind {
            return [format {::set %s %s} [emitLocalName [dict get $node name]] $word]
        }
        return {
            if {[dict get $context problemResult]} {
                set command [dict get $context target]::@rt::atResult
                set word [format {[%s %s %s]} [list $command] $word [list [emitLocation $node]]]
            }
            return [format {::return %s} $word]
        }
        # Tcl evaluates the operand and completes normally. A scratch local
        # would keep a discarded collection alive across the next operation.
        expr {return [format {::return -level 0 %s} $word]}
        default {error "unsupported application statement: [list [dict get $node kind]]"}
    }
}

proc ::appcompiler::emitLine {line location bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    lappend body $line
    dict set locations [llength $body] $location
}

# Only a jump across another loop needs a handler. Resolve the lexical target
# once during compilation so ordinary loop bodies have no try overhead.
proc ::appcompiler::findOuterJumps {statements active nearest targetsVar} {
    upvar 1 $targetsVar targets
    foreach node $statements {
        switch -exact -- [dict get $node kind] {
            for - while {
                set label [dict get $node label]
                set scope $active
                if {$label ne {}} {dict set scope $label [emitLocation $node]}
                findOuterJumps [dict get $node body] $scope $label targets
            }
            if {
                findOuterJumps [dict get $node body] $active $nearest targets
                findOuterJumps [dict get $node otherwise] $active $nearest targets
            }
            using {findOuterJumps [dict get $node body] $active $nearest targets}
            break - continue {
                set label [dict get $node label]
                if {$label ne {} && $label ne $nearest} {
                    dict set targets [dict get $active $label] [dict get $node kind] 1
                }
            }
        }
    }
}

# Tcl loops propagate custom completion codes unchanged. Reserve two per
# nesting level, separate from Tcl's native return, break and continue.
proc ::appcompiler::loopCode {depth kind} {
    expr {256 + 2 * $depth + ($kind eq "continue")}
}

# A comparison directly inside a braced Tcl condition lets the VM branch
# on its result without first materializing a boolean for a nested command.
proc ::appcompiler::emitCondition {node context} {
    if {[dict get $node kind] eq "binary" && [dict get $node op] in {< <= > >= == !=} &&
            [dict getdef [emitFacts $node $context] operandType {}] eq "int"} {
        set left [emitExpression [dict get $node left] $context]
        set right [emitExpression [dict get $node right] $context]
        return [format {%s %s %s} $left [dict get $node op] $right]
    }
    return [emitExpression $node $context]
}

proc ::appcompiler::emitLoop {node context bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    set location [emitLocation $node]
    set depth [dict getdef $context loopDepth 0]
    if {[dict get $node kind] eq "while"} {
        set test [emitCondition [dict get $node condition] $context]
        if {[dict getdef $context locateScope 0]} {
            # The condition runs again after the loop body has moved the marker.
            set test [format {[::set m_scopeLine %d] && (%s)} [llength $body] $test]
        }
        # Bracing defers variable and command substitutions until each test.
        set header [format {::while {%s} %c} $test 123]
    } else {
        set iterable [emitExpression [dict get $node iterable] $context]
        set type [dict get [emitFacts $node $context] iterableType]
        set local [emitLocalName [dict get $node name]]
        if {$type eq "range<int>"} {
            set limit m_limit_$depth
            set closed m_closed_$depth
            emitLine [format {::lassign %s %s %s %s} $iterable $local $limit $closed] $location body locations
            emitLine [format {::incr %s $%s} $limit $closed] $location body locations
            set header [format {::for {} {$%s < $%s} {::incr %s} %c} $local $limit $local 123]
        } elseif {[lindex [typeParts $type] 0] eq "map"} {
            set header [format {::dict for {%s m_mapvalue_%d} %s %c} $local $depth $iterable 123]
        } else {
            set header [format {::foreach %s %s %c} $local $iterable 123]
        }
    }
    emitLine $header $location body locations
    set label [dict get $node label]
    dict set context loopDepth [expr {$depth + 1}]
    dict set context nearestLoop $label
    if {$label ne {}} {dict set context loopIndices $label $depth}
    set jumps [dict getdef $context outerJumps $location {}]
    if {[dict size $jumps]} {emitLine "::try \{" $location body locations}
    emitStatements [dict get $node body] $context body locations
    if {[dict size $jumps]} {
        set handlers \}
        foreach kind [dict keys $jumps] {
            append handlers [format { on %d {} {::%s}} [loopCode $depth $kind] $kind]
        }
        emitLine $handlers $location body locations
    }
    emitLine \} $location body locations
}

proc ::appcompiler::emitUsing {node context bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    set facts [emitFacts $node $context]
    set local [emitLocalName [dict get $node binding name]]
    set location [emitLocation $node]
    set target [dict get $context target]
    emitLine [format {::set %s %s} $local [emitExpression [dict get $node value] $context]] $location body locations
    if {![dict exists $facts resourceCloser]} {
        emitLine "::try \{" $location body locations
        emitStatements [dict get $node body] $context body locations
        # A normally completed statement block has no value for the closer.
        set closer [dict getdef $facts builtinCloser [expr {[dict get $node value kind] eq "refCreate" ? "endReference" : "sqlEnd"}]]
        emitLine [format {::return -level 0 {}; %c finally { %s $%s }} 125 [list ${target}::@rt::${closer}] $local] $location body locations
        return
    }

    # Catch in the owning frame. A return, break or labelled jump must travel
    # exactly as far as it did without the scope. Nested catches finish before
    # these generated scratch variables acquire the enclosing scope's values.
    emitLine [format {::set m_scopeCode [::catch %c} 123] $location body locations
    dict set context locateScope 1
    emitStatements [dict get $node body] $context body locations
    emitLine [format {::return -level 0 {}; %c m_scopeValue m_scopeOptions]} 125] $location body locations
    lassign [dict get $facts resourceCloser] module function
    set call [list [list ${target}::${module}::${function}]]
    set types [dict get $facts resourceTypeArguments]
    if {[llength $types]} {lappend call [emitTypeList $types $context]}
    lappend call [format {$%s} $local]
    emitLine [format {::set m_closeCode [::catch {%s} m_closeValue m_closeOptions]} [join $call { }]] $location body locations
    set closeLine [llength $body]
    # An error caught inside the compiled function can lack its generated
    # frame. Supply the last statement's line for the usual source-map lookup.
    emitLine [format {::if {$m_scopeCode == 1} {::dict append m_scopeOptions -errorinfo [::format "\n    (procedure \"%%s\" line %%d)" %s $m_scopeLine]}} \
        [list [dict get $context procedure]]] $location body locations
    emitLine [format {::if {$m_closeCode == 1} {::dict append m_closeOptions -errorinfo %s}} \
        [emitTextWord [format "\n    (procedure \"%s\" line %d)" [dict get $context procedure] $closeLine]]] $location body locations
    set failed {$m_closeCode != 0}
    if {[dict get $facts resourceFallible]} {append failed { || [::lindex $m_closeValue 0] eq "err"}}
    emitLine [format {::if {%s} %c} $failed 123] $location body locations
    emitLine [format {::lassign [%s $m_scopeCode $m_scopeValue $m_scopeOptions $m_closeCode $m_closeValue $m_closeOptions %s %s] m_scopeValue m_scopeOptions} \
        [list ${target}::@rt::failedClose] [emitTypeWord [dict get $context errorType] $context] [list $location]] $location body locations
    emitLine {::return -options $m_scopeOptions $m_scopeValue} $location body locations
    emitLine \} $location body locations
    emitLine {::if {$m_scopeCode != 0} {::return -options $m_scopeOptions $m_scopeValue}} $location body locations
}

proc ::appcompiler::emitStatements {statements context bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    foreach statement $statements {
        set location [emitLocation $statement]
        if {[dict getdef $context locateScope 0]} {
            emitLine [format {::set m_scopeLine %d} [expr {[llength $body] + 1}]] $location body locations
        }
        switch -exact -- [dict get $statement kind] {
            for - while {emitLoop $statement $context body locations}
            using {emitUsing $statement $context body locations}
            if {
                set test [emitCondition [dict get $statement condition] $context]
                emitLine [format {::if {%s} %c} $test 123] $location body locations
                emitStatements [dict get $statement body] $context body locations
                if {[llength [dict get $statement otherwise]]} {
                    emitLine [format {%c else %c} 125 123] $location body locations
                    emitStatements [dict get $statement otherwise] $context body locations
                }
                emitLine \} $location body locations
            }
            default {emitLine [emitStatement $statement $context] $location body locations}
        }
    }
}

proc ::appcompiler::emitExtern {function context formals bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    set rt [dict get $context target]::@rt
    set invoke [list ${rt}::externInvoke]
    set package [dict get $function package]
    if {$package ne {}} {
        set where [emitLocation [dict get $function packageLocation]]
        emitLine [format {%s %s {::package require} %s} $invoke [list $where] [emitTextWord $package]] \
            $where body locations
    }
    set where [emitLocation [dict get $function prefixLocation]]
    # Encode the whole prefix as one literal list on one generated source line.
    set call [list $invoke [list $where] [emitTextWord [dict get $function prefix]]]
    foreach formal $formals {lappend call [format {$%s} $formal]}
    set value [format {[%s %s %s [%s]]} [list ${rt}::externResult] [list $where] \
        [emitTypeWord [dict get $function result] $context] [join $call { }]]
    if {[dict get $context problemResult]} {
        set value [format {[%s %s %s]} [list ${rt}::atResult] $value [list $where]]
    }
    emitLine [format {::return %s} $value] $where body locations
}

# Compile the field names into dict bytecodes for public lists of small,
# concrete records. Internal calls operate on already checked values.
proc ::appcompiler::emitRecordListGuard {command members} {
    set body [list {append value {}} {if {[catch {llength $value}]} {reject $path list<$element>}}]
    lappend body {set i -1}
    set loop [list {incr i} {append row {}} {if {[catch {dict size $row}]} {reject $path.$i $element}}]
    dict for {name fieldType} $members {
        set field [list $name]
        set where [format {$path.$i.%s} $name]
        set original [format {[dict get $row %s]} $field]
        switch -- $fieldType {
            int {set checked [format {[guardInteger %s %s]} $original $where]}
            binary64 {set checked [format {[guardBinary64 %s %s]} $original $where]}
            instant - local_datetime {set checked [format {[guardTemporalField %s %s %s]} $fieldType $original $where]}
            text {set checked $original}
            int? - text? - binary64? {
                set checked [format {[guardOptional %s %s %s %s 0]} $fieldType [string range $fieldType 0 end-1] $original $where]
            }
            default {set checked [format {[guard %s %s %s]} [list $fieldType] $original $where]}
        }
        set save [format {dict set row %s %s} $field $checked]
        if {[string index $fieldType end] eq "?"} {
            lappend loop [format {if {[dict exists $row %s]} {%s}} $field $save]
        } else {
            lappend loop [format {if {![dict exists $row %s]} {reject %s %s}} $field $where [list $fieldType]] $save
        }
    }
    lappend loop {set row}
    lappend body [format {return [lmap row $value {%s}]} [join $loop \n]]
    set fallback [list ::proc $command {element value path} [join $body \n]]
    dict for {field type} $members {
        if {$type ni {int text int? text?}} {return $fallback}
    }
    set fast [format {::machteld::GuardRecordList %s $element $value $path} [list $members]]
    return [list ::if {[llength [info commands ::machteld::GuardRecordList]]} \
        [list ::proc $command {element value path} $fast] else $fallback]
}

proc ::appcompiler::emitPublicGuard {type context schemas guardsVar definitionsVar} {
    upvar 1 $guardsVar guards $definitionsVar definitions
    set rt [dict get $context target]::@rt
    if {$type eq "binary64"} {return [list ${rt}::guardBinary64]}
    if {$type eq "list<int>"} {return [list ${rt}::guardIntegerList]}
    if {$type eq "list<bool>"} {return [list ${rt}::guardBooleanList]}
    if {[string match {list<*>} $type]} {
        set element [string range $type 5 end-1]
        set schema [dict getdef $schemas $element {}]
        lassign $schema kind members
        # Unroll only small nongeneric records. Larger shapes keep one compact
        # field loop. Reuse each ordered layout across nominal types and modules.
        if {$kind eq "record" && [llength $schema] == 2 && [dict size $members] <= 16} {
            if {![dict exists $guards $members]} {
                set helper ${rt}::recordList[dict size $guards]
                lappend definitions [emitRecordListGuard $helper $members]
                dict set guards $members $helper
            }
            return [list [dict get $guards $members] $element]
        }
    }
    return [format {%s %s} [list ${rt}::guard] [emitTypeWord $type $context]]
}

# A single procedure reads the array in order. dict update keeps unknown
# typed children and gives each declared field a local Tcl variable.
proc ::appcompiler::emitJsonRowReader {command fields} {
    set update [list dict update out]
    set ops {}
    set body [list {set path "$outer\[[incr i]\]"} {set kind [::machteld::json type $node]} \
        {if {$kind ne "object"} {invalidWire "$path expects an object, got $kind"}} \
        {set out [::machteld::json children $node]}]
    set fieldIndex 0
    dict for {name fieldType} $fields {
        set slot f[incr fieldIndex]
        lappend update $name $slot
        set fallback [format {set %s [fromWire %s $%s $path.%s]} $slot [list $fieldType] $slot $name]
        if {[string index $fieldType end] eq "?"} {
            lappend ops [format {if {[info exists %s]} {%s}} $slot $fallback]
            continue
        }
        lappend ops [format {if {![info exists %s]} {invalidWire "$path is missing required field %s"}} $slot $name]
        switch -- $fieldType {
            text - bool {
                set kind [expr {$fieldType eq "text" ? "string" : "boolean"}]
                set wanted [expr {$fieldType eq "text" ? "text" : "a boolean"}]
                lappend ops [format {set kind [::machteld::json type $%s]} $slot] \
                    [format {if {$kind ne "%s"} {invalidWire "$path.%s expects %s, got $kind"}} $kind $name $wanted] \
                    [format {set %s [::machteld::json unwrap $%s]} $slot $slot]
            }
            default {lappend ops $fallback}
        }
    }
    if {[llength $ops]} {lappend body [list {*}$update [join $ops \n]]}
    lappend body {set out}
    set loop [format {return [lmap node $children {%s}]} [join $body \n]]
    set setup {}
    set eligible [expr {[dict size $fields] > 0}]
    foreach type [dict values $fields] {
        if {$type ni {text bool int}} {set eligible 0; break}
    }
    if {$eligible} {
        lappend setup {variable jsonRowProjection}
        lappend setup [format {if {$jsonRowProjection} {
            set layout %s
            # Prepare the compiler-owned dictionary without converting a caller's object.
            dict size $layout
            set rows [::machteld::x::projectRows $layout $node]
            switch [llength $rows] {
                1 {return [lindex $rows 0]}
                2 {
                    # Let the standard validator describe the first unsupported row.
                    lassign $rows index value
                    fromWire $element $value "$outer\[$index\]"
                }
            }
        }} [list $fields]]
    }
    lappend setup {set children [::machteld::json children $node]} {set i -1} $loop
    return [list ::proc $command {node outer element} [join $setup \n]]
}

proc ::appcompiler::emitJsonListReaders {rt schemas roots} {
    set definitions {}
    set readers {}
    set layouts {}
    set seen {}
    # Visit only concrete shapes reachable from decode_json. Share identical
    # ordered layouts so each validator preserves the first failing field.
    set queue [lsort -ascii $roots]
    for {set i 0} {$i < [llength $queue]} {incr i} {
        set type [lindex $queue $i]
        if {[dict exists $seen $type]} continue
        dict set seen $type 1
        set parts [typeParts $type]
        lassign $parts head left right
        if {$head eq "optional"} {lappend queue $left; continue}
        if {$head eq "map"} {lappend queue $right; continue}
        if {$head ne "list"} {
            set schema [dict getdef $schemas $type {}]
            if {[llength $schema] == 2 && [lindex $schema 0] eq "record"} {
                lappend queue {*}[dict values [lindex $schema 1]]
            }
            if {$left ne {} && [dict exists $schemas $head]} {
                # A generic envelope may contain a list of one of its parameters.
                # Follow concrete arguments alone so recursive types cannot grow.
                lassign [dict get $schemas $head] kind members parameters
                if {$kind eq "record"} {
                    set fieldTypes [dict values $members]
                    foreach parameter $parameters argument [lrange $parts 1 end] {
                        if {"list<$parameter>" in $fieldTypes} {lappend queue "list<$argument>"}
                    }
                }
            }
            continue
        }
        lappend queue $left
        set schema [dict getdef $schemas $left {}]
        lassign $schema kind fields
        # Bound generated code per layout and per application. The ordinary
        # decoder handles larger and generic records using their runtime schema.
        if {[llength $schema] != 2 || $kind ne "record" || [dict size $fields] > 16} continue
        if {![dict exists $layouts $fields]} {
            if {[dict size $layouts] >= 32} continue
            set command ${rt}::readJsonRows[dict size $layouts]
            dict set layouts $fields $command
            lappend definitions [emitJsonRowReader $command $fields]
        }
        dict set readers $left [dict get $layouts $fields]
    }
    lappend definitions [list ::proc ${rt}::jsonListReaders {} [list return $readers]]
    return $definitions
}

# Small, fixed scalar records have statically known field types. Compile each
# referenced layout once. Other records use the ordinary runtime comparator.
proc ::appcompiler::emitRecordComparators {rt schemas types definitionsVar} {
    upvar 1 $definitionsVar definitions
    set comparators {}
    set layouts {}
    foreach type [lsort -ascii $types] {
        set schema [dict getdef $schemas $type {}]
        lassign $schema kind members
        if {$kind ne "record" || [llength $schema] != 2 || [dict size $members] > 16} continue
        if {![dict exists $layouts $members]} {
            if {[dict size $layouts] >= 32} continue
            set body {}
            dict for {name field} $members {
                set a [format {[dict getdef $left %s none]} [list $name]]
                set b [format {[dict getdef $right %s none]} [list $name]]
                switch -exact -- $field {
                    text {lappend body [format {if {![equalText %s %s]} {return 0}} $a $b]}
                    int - bool {lappend body [format {if {%s != %s} {return 0}} $a $b]}
                    default {break}
                }
            }
            if {[llength $body] != [dict size $members]} continue
            set names [dict keys $members]
            lappend body [format {tailcall equalExtras [dict remove $left %s] [dict remove $right %s]} $names $names]
            set comparator ${rt}::recordEqual[dict size $layouts]
            dict set layouts $members $comparator
            lappend definitions [list ::proc $comparator {left right} [join $body \n]]
        }
        dict set comparators $type [dict get $layouts $members]
    }
    return $comparators
}

# Read fields in declaration order, even when a query projects its columns
# in another order. sqlCell retains the diagnostics and complex conversions.
proc ::appcompiler::emitSqlRowReader {command fields schemas} {
    set storageTags {int integer bool integer text text bytes blob}
    set body {}
    set result {::dict create}
    set index 0
    dict for {field declared} $fields {
        set optional [expr {[string index $declared end] eq "?"}]
        set type [expr {$optional ? [string range $declared 0 end-1] : $declared}]
        set base $type
        lassign [specializeSchema $type $schemas] kind underlying
        if {$kind eq "distinct"} {set base $underlying}
        set var field[incr index]
        lappend result [list $field] [format {$%s} $var]
        lappend body [format {::set cell [::dict get $cells %s]} [list $field]]
        set fallback [format {[sqlCell %s %s %d $cell %s]} [list $type] [list $base] $optional [list $field]]
        set storage [dict getdef $storageTags $base {}]
        if {$storage eq {}} {
            lappend body [format {::set %s %s} $var $fallback]
            continue
        }
        lappend body [format {::lassign $cell storage %s} $var]
        set valid [format {$storage eq "%s"} $storage]
        if {$base eq "bool"} {append valid [format { && $%s in {0 1}} $var]}
        if {$optional} {
            lappend body [format {if {$storage eq "null"} {
    ::set %s [::list none]
} elseif {%s} {
    ::set %s [::list some $%s]
} else {
    ::set %s %s
}} $var $valid $var $var $var $fallback]
        } else {
            lappend body [format {if {!(%s)} {::set %s %s}} $valid $var $fallback]
        }
    }
    lappend body [format {::return [%s]} [join $result { }]]
    return [list ::proc $command cells [join $body \n]]
}

proc ::appcompiler::emitSqlRowReaders {rt schemas types} {
    set definitions {}
    set readers {}
    set layouts {}
    set fieldsLeft 128
    foreach type [lsort -ascii -unique $types] {
        lassign [specializeSchema $type $schemas] kind fields
        if {$kind ne "record" || [string first @ $type] >= 0 || [dict size $fields] > 16} continue
        if {![dict exists $layouts $fields]} {
            set count [dict size $fields]
            if {[dict size $layouts] >= 32 || $count > $fieldsLeft} continue
            incr fieldsLeft -$count
            set reader ${rt}::readSqlRow[dict size $layouts]
            dict set layouts $fields $reader
            lappend definitions [emitSqlRowReader $reader $fields $schemas]
        }
        dict set readers $type [dict get $layouts $fields]
    }
    lappend definitions [list ::proc ${rt}::sqlReaders {} [list return $readers]]
    return $definitions
}

proc ::appcompiler::emitModules {modules targetNamespace facts resolved} {
    set definitions [emitRuntime $targetNamespace [dict get $resolved schemas]]
    if {[dict getdef $resolved usesSql 0]} {
        lappend definitions {*}[emitSqlRowReaders ${targetNamespace}::@rt [dict get $resolved schemas] \
            [dict getdef $resolved sqlRowTypes {}]]
    }
    lappend definitions {*}[emitJsonListReaders ${targetNamespace}::@rt [dict get $resolved schemas] \
        [dict getdef $resolved jsonDecodeRoots {}]]
    set targets {}
    foreach key [lsort -ascii [dict get $resolved callbackTargets]] {
        lassign $key module name
        set function [dict get $resolved functions $module $name]
        set parameters [lmap param [dict get $function params] {dict get $param type}]
        dict set targets $key [list ${targetNamespace}::${module}::${name} [dict get $function typeVariables] \
            $parameters [dict get $function result]]
    }
    lappend definitions [list ::proc ${targetNamespace}::@rt::callbackTargets {} [list ::return $targets]]
    set sourceMap [dict create]
    set recordListGuards {}
    set recordComparators [emitRecordComparators ${targetNamespace}::@rt [dict get $resolved schemas] \
        [dict getdef $resolved equalityTypes {}] definitions]
    foreach module [lsort -ascii [dict keys $modules]] {
        set context [dict create target $targetNamespace module $module facts $facts recordComparators $recordComparators]
        set moduleNamespace ${targetNamespace}::${module}
        lappend definitions [list ::namespace eval $moduleNamespace {}]
        dict for {functionName function} [dict get $resolved functions $module] {
            set resultParts [typeParts [dict get $function result]]
            dict set context problemResult [expr {[lindex $resultParts 0] eq "result"
                && [lindex $resultParts 2] eq "problem"}]
            set name ${moduleNamespace}::${functionName}
            dict set context procedure $name
            dict set context errorType [lindex $resultParts 2]
            set formals {}
            set body {}
            set locations [dict create]
            set variables [dict getdef $function typeVariables {}]
            if {[llength $variables]} {
                emitLine [format {::set m_types [%s %s $m_arguments]} \
                    [list ${targetNamespace}::@rt::bindTypes] [list $variables]] [emitLocation $function] body locations
            }
            foreach param [dict get $function params] {
                set local [emitLocalName [dict get $param name]]
                lappend formals $local
                set type [dict get $param type]
                if {[dict get $function exported] && $type ne "text"} {
                    set prefix [emitPublicGuard $type $context [dict get $resolved schemas] recordListGuards definitions]
                    lappend body [format {::set %s [%s $%s %s]} $local $prefix $local \
                        [list [format {$%s} [dict get $param name]]]]
                    dict set locations [llength $body] [emitLocation $param]
                }
            }
            set parameters $formals
            if {[llength $variables]} {set parameters [linsert $formals 0 m_arguments]}
            if {[dict exists $resolved directTargets [list $module $functionName]]} {
                # Keep the externally visible command and its source-mapped
                # guards. The private entry owns the single application body.
                set implementation ${moduleNamespace}::@${functionName}
                set forward [list ::tailcall [list $implementation]]
                if {[llength $variables]} {lappend forward {$m_types}}
                foreach local $formals {lappend forward [format {$%s} $local]}
                emitLine [join $forward { }] [emitLocation $function] body locations
                lappend definitions [list ::proc $name $parameters [join $body \n]]
                dict set sourceMap $name $locations
                set body {}
                set locations {}
                set name $implementation
                dict set context procedure $name
                if {[llength $variables]} {set parameters [linsert $formals 0 m_types]}
            }
            if {[dict get $function kind] eq "extern"} {
                emitExtern $function $context $formals body locations
            } else {
                set targets {}
                findOuterJumps [dict get $function body] {} {} targets
                dict set context outerJumps $targets
                set dual [dict exists $resolved binary64Functions [list $module $functionName]]
                set paired [dict exists $resolved binary64PairFunctions [list $module $functionName]]
                if {$dual} {
                    set nativeBody $body
                    set nativeLocations $locations
                    emitStatements [dict get $function body] [dict replace $context nativeFloat 1] \
                        nativeBody nativeLocations
                    if {$paired} {
                        set pairBody $body
                        set pairLocations $locations
                        emitStatements [dict get $function body] [dict replace $context nativeFloat 1 floatPairs 1] \
                            pairBody pairLocations
                    }
                }
                emitStatements [dict get $function body] $context body locations
            }
            set definition [list ::proc $name $parameters [join $body \n]]
            if {[dict get $function kind] ne "extern" && $dual} {
                set capability {[::llength [::info commands ::machteld::x::binary64v1::add]] &&
                    "add" in [::namespace eval ::machteld::x::binary64v1 {::namespace export}]}
                set native [list ::proc $name $parameters [join $nativeBody \n]]
                if {$paired} {
                    set pairCapability {[::llength [::info commands ::machteld::x::binary64v1::rightPair]] &&
                        "rightPair" in [::namespace eval ::machteld::x::binary64v1 {::namespace export}]}
                    set native [list ::if $pairCapability [list ::proc $name $parameters [join $pairBody \n]] else $native]
                }
                lappend definitions [list ::if $capability $native else $definition]
            } else {
                lappend definitions $definition
            }
            if {[dict get $function exported]} {
                lappend definitions [list ::namespace eval $moduleNamespace [list ::namespace export $functionName]]
            }
            dict set sourceMap $name $locations
        }
    }
    return [dict create script [join $definitions \n] sourceMap $sourceMap]
}
