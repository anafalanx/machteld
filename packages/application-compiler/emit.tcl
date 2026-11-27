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
    lappend definitions [list ::proc ${rt}::guard {type value path {checkExtras 0}} {
        lassign [typeParts $type] head first second
        if {$head eq "optional"} {
            if {[catch {llength $value} size]} {reject $path $type}
            set tag [lindex $value 0]
            if {$tag eq "none" && $size == 1} {return [list none]}
            if {$tag ne "some" || $size != 2} {reject $path $type}
            return [list some [guard $first [lindex $value 1] $path $checkExtras]]
        }
        switch -exact -- $head {
            callable {return [guardCallable $type $value $path]}
            ref {return [guardReference $first $value $path]}
            process_stream {return [guardStream $value $path]}
            task {return [guardTask $first $value $path]}
            range {
                if {$type ne "range<int>" || [catch {llength $value} size] || $size != 3} {reject $path $type}
                lassign $value start end closed
                if {$closed ni {0 1}} {reject $path.closed {0 or 1}}
                return [list [guard int $start $path.start] [guard int $end $path.end] $closed]
            }
            list {
                if {[catch {llength $value}]} {reject $path $type}
                set index 0
                set result {}
                foreach item $value {
                    lappend result [guard $first $item $path.$index $checkExtras]
                    incr index
                }
                return $result
            }
            map {
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
                if {[regexp {[^\u0000-\u00ff]} $value]} {reject $path bytes}
                return [binary format a* $value]
            }
            problem {
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
            int {
                if {![regexp {\A[+-]?[0-9]+\Z} $value]} {reject $path int}
                # Unlimited precision and decimal even with leading zeroes.
                scan $value %lld number
                return $number
            }
            decimal {
                if {[catch {decimal::canonical $value} normalized]} {reject $path decimal}
                return $normalized
            }
            binary64 {
                if {[catch {finiteBinary64 $value} number]} {reject $path {finite binary64}}
                if {$checkExtras eq "workerOutput"} {return [format %.17g $number]}
                return $number
            }
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
        if {$kind eq "record"} {
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
                dict set value $field [guard $fieldType [dict get $value $field] $path.$field $checkExtras]
            }
            return $value
        }
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
                    binary64 {set word [format {[::format %%.17g %s]} $word]}
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
            set left [emitExpression [dict get $node left] $context $bindings $depth]
            set right [emitExpression [dict get $node right] $context $bindings $depth]
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
                set comparison [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::equal] [emitTypeWord $type $context] $left $right]
                if {$op eq "!="} {return [format {[::tcl::mathop::! %s]} $comparison]}
                return $comparison
            }
            if {$op ni {+ - *}} {error "unsupported application operator: [list $op]"}
            if {[dict getdef [emitFacts $node $context] operandType {}] eq "decimal"} {
                return [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::decimal::calc] $op $left $right]
            }
            return [format {[::tcl::mathop::%s %s %s]} $op $left $right]
        }
        call - construct - builtin - sqlBegin - refCreate {
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
            set operand [emitExpression [dict get $node value] $context $bindings $depth]
            set where [expr {[dict get $context problemResult] ? [emitLocation $node] : {}}]
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
        construct {return [list ::list [list [dict get $node variant]]]}
        call {
            set name [dict get $node name]
            if {[dict exists $facts constructor]} {return [list ::list [list $name]]}
            set calleeModule [dict get $node qualifier]
            if {$calleeModule eq ""} {set calleeModule [dict get $context module]}
            if {[dict exists $node workerStart]} {
                return [list [list ${target}::@rt::workerStart] [dict get $node workerStart] [list $calleeModule.$name]]
            }
            set prefix [list [list ${target}::${calleeModule}::${name}]]
            if {[llength [dict getdef $facts typeArguments {}]]} {
                lappend prefix [emitTypeList [dict get $facts typeArguments] $context]
            }
            return $prefix
        }
        builtin {
            set name [dict get $node name]
            switch -exact -- $name {
                unit {return [list ::list]}
                map {return [list ::dict create]}
                bind {return [list [list ${target}::@rt::bindCallback]]}
                len {
                    switch -- [dict get $facts lengthKind] {
                        list {return [list ::llength]}
                        map {return [list ::dict size]}
                        text - bytes {return [list ::string length]}
                    }
                }
                ref_get - ref_set - ref_same {return [list [list ${target}::@rt::${name}]]}
                map_put {return [list ::dict replace]}
                require_key {return [list [list ${target}::@rt::require_key]]}
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
                sql_commit {return [list [list ${target}::@rt::sqlCommit]]}
                await - cancel - problem - read_stdin_bytes - decode_utf8 - decode_text - preview_text - write_stdout_utf8 -
                parse_instant - parse_local_datetime - resolve_offset - resolve_zone - capture_process -
                stream_process - close_process - cancel_process - find_executable {
                    return [list [list ${target}::@rt::${name}]]
                }
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

proc ::appcompiler::emitMatch {node context bindings depth} {
    set scrutinee [emitExpression [dict get $node value] $context $bindings $depth]
    # A nested arm must still be able to read its enclosing match's captures.
    # These names cannot coincide with the v_ prefix used for source locals.
    set slot m_$depth
    set arms [dict get $node arms]
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
        set result [emitExpression [dict get $arm body] $context $scope [expr {$depth + 1}]]
        set lastTag [dict get [lindex $alternatives end] variant]
        lappend actions [format {::set m_result %s} $result]
        lappend words [list $lastTag] [list [join $actions {; }]]
    }
    # An explicit final default also allows a user variant named "default".
    lappend words default [list {::return -code error -errorcode {APPCOMPILER VALUE CHOICE} {invalid choice tag}}]
    return [format {[%s]} [join $words { }]]
}

proc ::appcompiler::emitListMatch {scrutinee slot arms context bindings depth} {
    set branches {}
    set equalText [list [dict get $context target]::@rt::equal text]
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
        set action [format {::set m_result %s} $value]
        if {![llength $branches]} {
            # A match with just a fallback still evaluates its input once.
            return [format {[::set %s %s; %s]} $slot $scrutinee $action]
        }
        lappend branches [list $action]
    }
    return [format {[::set %s %s; %s]} $slot $scrutinee [join $branches { }]]
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
    # A checked update of the same variable can use Tcl's copy-on-write
    # dictionary instruction. Other holders keep the previous dictionary.
    if {$kind eq "assign" && [dict get $value kind] eq "builtin" && [dict get $value name] eq "map_put"} {
        lassign [dict get $value args] base key item
        if {[dict get $base kind] eq "var" && [dict get $base name] eq [dict get $node name]} {
            set keyWord [emitMapKeyWord $value $context [emitExpression $key $context]]
            return [format {::dict set %s %s %s} [emitLocalName [dict get $node name]] \
                $keyWord [emitExpression $item $context]]
        }
    }
    set word [emitExpression $value $context]
    switch -exact -- $kind {
        bind - assign {
            return [format {::set %s %s} [emitLocalName [dict get $node name]] $word]
        }
        return {
            if {[dict get $context problemResult]} {
                set command [dict get $context target]::@rt::atResult
                set word [format {[%s %s %s]} [list $command] $word [list [emitLocation $node]]]
            }
            return [format {::return %s} $word]
        }
        expr {return [format {::set m_discard %s} $word]}
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

proc ::appcompiler::emitLoop {node context bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    set location [emitLocation $node]
    set depth [dict getdef $context loopDepth 0]
    if {[dict get $node kind] eq "while"} {
        set test [emitExpression [dict get $node condition] $context]
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
        set closer [dict getdef $facts builtinCloser [expr {[dict get $node value kind] eq "refCreate" ? "endReference" : "sqlEnd"}]]
        emitLine [format {%c finally { %s $%s }} 125 [list ${target}::@rt::${closer}] $local] $location body locations
        return
    }

    # Catch in the owning frame. A return, break or labelled jump must travel
    # exactly as far as it did without the scope. Nested catches finish before
    # these generated scratch variables acquire the enclosing scope's values.
    emitLine [format {::set m_scopeCode [::catch %c} 123] $location body locations
    dict set context locateScope 1
    emitStatements [dict get $node body] $context body locations
    emitLine [format {%c m_scopeValue m_scopeOptions]} 125] $location body locations
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
                set test [emitExpression [dict get $statement condition] $context]
                emitLine [format {::if %s %c} $test 123] $location body locations
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

proc ::appcompiler::emitModules {modules targetNamespace facts resolved} {
    set definitions [emitRuntime $targetNamespace [dict get $resolved schemas]]
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
    foreach module [lsort -ascii [dict keys $modules]] {
        set context [dict create target $targetNamespace module $module facts $facts]
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
                    lappend body [format {::set %s [%s %s $%s %s]} $local \
                        [list ${targetNamespace}::@rt::guard] [emitTypeWord $type $context] $local \
                        [list [format {$%s} [dict get $param name]]]]
                    dict set locations [llength $body] [emitLocation $param]
                }
            }
            if {[dict get $function kind] eq "extern"} {
                emitExtern $function $context $formals body locations
            } else {
                set targets {}
                findOuterJumps [dict get $function body] {} {} targets
                dict set context outerJumps $targets
                emitStatements [dict get $function body] $context body locations
            }
            if {[llength $variables]} {set formals [linsert $formals 0 m_arguments]}
            lappend definitions [list ::proc $name $formals [join $body \n]]
            if {[dict get $function exported]} {
                lappend definitions [list ::namespace eval $moduleNamespace [list ::namespace export $functionName]]
            }
            dict set sourceMap $name $locations
        }
    }
    return [dict create script [join $definitions \n] sourceMap $sourceMap]
}
