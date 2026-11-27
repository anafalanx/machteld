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

proc ::appcompiler::emitTypeName {module type} {
    lassign [typeParts $type] head first second
    switch -exact -- $head {
        optional {return [emitTypeName $module $first]?}
        list {return list<[emitTypeName $module $first]>}
        result {return result<[emitTypeName $module $first],[emitTypeName $module $second]>}
    }
    if {[string index $type 0] eq "." && [string first :: $type] < 0} {
        return .${module}::[string range $type 1 end]
    }
    return $type
}

# A generated program carries its own type descriptions and needs no compiler
# at run time. @rt cannot be an application module name. Its procedures keep
# no mutable state, so two applications may use different definitions.
proc ::appcompiler::emitRuntime {targetNamespace modules} {
    set rt ${targetNamespace}::@rt
    set schemas {}
    foreach module [lsort -ascii [dict keys $modules]] {
        foreach type [dict getdef $modules $module types {}] {
            set members {}
            set kind [dict get $type kind]
            if {$kind eq "record"} {
                foreach field [dict get $type fields] {
                    dict set members [dict get $field name] [emitTypeName $module [dict get $field type]]
                }
            } else {
                foreach variant [dict get $type variants] {
                    set payload [lmap t [dict get $variant payload] {emitTypeName $module $t}]
                    dict set members [dict get $variant name] $payload
                }
            }
            dict set schemas .${module}::[dict get $type name] [list $kind $members]
        }
    }
    set definitions [list [list ::namespace eval $rt {}]]
    lappend definitions [list ::proc ${rt}::schemas {} [list ::return $schemas]]
    lappend definitions [list ::proc ${rt}::typeParts [info args ::appcompiler::typeParts] \
        [info body ::appcompiler::typeParts]]
    lappend definitions [list ::proc ${rt}::reject {path expected} {
        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected $expected at $path"
    }]
    lappend definitions [list ::proc ${rt}::guard {type value path} {
        lassign [typeParts $type] head first second
        if {$head eq "optional"} {
            if {[catch {llength $value} size]} {reject $path $type}
            set tag [lindex $value 0]
            if {$tag eq "none" && $size == 1} {return [list none]}
            if {$tag ne "some" || $size != 2} {reject $path $type}
            return [list some [guard $first [lindex $value 1] $path]]
        }
        switch -exact -- $head {
            list {
                if {[catch {llength $value}]} {reject $path $type}
                set index 0
                set result {}
                foreach item $value {
                    lappend result [guard $first $item $path.$index]
                    incr index
                }
                return $result
            }
            result {
                if {[catch {llength $value} size] || $size != 2} {reject $path $type}
                lassign $value tag payload
                switch -exact -- $tag {
                    ok  {return [list ok  [guard $first $payload $path.ok]]}
                    err {return [list err [guard $second $payload $path.err]]}
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
                    set origin [dict get $value origin]
                    if {[catch {dict size $origin}] || ![dict exists $origin module]} {reject $path.origin {a source location}}
                    foreach field {line column} {
                        if {![dict exists $origin $field]} {reject $path.origin.$field int}
                        dict set origin $field [guard int [dict get $origin $field] $path.origin.$field]
                    }
                    dict set value origin $origin
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
            bool {
                if {$value ni {0 1 false true}} {reject $path bool}
                return [expr {$value in {1 true}}]
            }
            text {return $value}
        }
        lassign [dict get [schemas] $type] kind members
        if {$kind eq "record"} {
            if {[catch {dict size $value}]} {reject $path $type}
            dict for {field fieldType} $members {
                if {![dict exists $value $field]} {
                    if {[string index $fieldType end] eq "?"} {continue}
                    reject $path.$field $fieldType
                }
                dict set value $field [guard $fieldType [dict get $value $field] $path.$field]
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
            lappend result [guard $fieldType [lindex $value $index] $path.$tag.$index]
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

proc ::appcompiler::emitExpression {node context {bindings {}} {depth 0}} {
    set targetNamespace [dict get $context target]
    set module [dict get $context module]
    set kind [dict get $node kind]
    switch -exact -- $kind {
        int  {return [emitIntegerWord [dict get $node value]]}
        decimal {return [list [decimal::canonical [dict get $node value]]]}
        text {return [emitTextWord [dict get $node value]]}
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
        unary {
            set value [emitExpression [dict get $node value] $context $bindings $depth]
            if {[dict get [emitFacts $node $context] operandType] eq "decimal"} {
                return [format {[%s - 0 %s]} [list ${targetNamespace}::@rt::decimal::calc] $value]
            }
            return [format {[::tcl::mathop::- %s]} $value]
        }
        binary {
            set op [dict get $node op]
            set left [emitExpression [dict get $node left] $context $bindings $depth]
            set right [emitExpression [dict get $node right] $context $bindings $depth]
            if {$op eq "/"} {
                return [format {[%s %s %s]} [list ${targetNamespace}::@rt::decimal::divide] $left $right]
            }
            if {$op in {== !=}} {
                set type [dict get [emitFacts $node $context] operandType]
                set comparison [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::equal] [list $type] $left $right]
                if {$op eq "!="} {return [format {[::tcl::mathop::! %s]} $comparison]}
                return $comparison
            }
            if {$op ni {+ - *}} {error "unsupported application operator: [list $op]"}
            if {[dict getdef [emitFacts $node $context] operandType {}] eq "decimal"} {
                return [format {[%s %s %s %s]} [list ${targetNamespace}::@rt::decimal::calc] $op $left $right]
            }
            return [format {[::tcl::mathop::%s %s %s]} $op $left $right]
        }
        call - construct - builtin {
            set words [emitCallPrefix $node $context]
            foreach argument [dict get $node args] {
                lappend words [emitExpression $argument $context $bindings $depth]
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
        construct {return [list ::list [list [dict get $node variant]]]}
        call {
            set name [dict get $node name]
            if {[dict exists $facts constructor]} {return [list ::list [list $name]]}
            set calleeModule [dict get $node qualifier]
            if {$calleeModule eq ""} {set calleeModule [dict get $context module]}
            return [list [list ${target}::${calleeModule}::${name}]]
        }
        builtin {
            set name [dict get $node name]
            switch -exact -- $name {
                unit {return [list ::list]}
                ok - err {return [list ::list $name]}
                decode_json - encode_json {
                    return [list [list ${target}::@rt::${name}] [list [dict get $facts schema]]]
                }
                problem - read_stdin_bytes - decode_utf8 - write_stdout_utf8 {
                    return [list [list ${target}::@rt::${name}]]
                }
                quotient {return [list [list ${target}::@rt::decimal::quotient]]}
                divide_rounded {return [list [list ${target}::@rt::decimal::rounded]]}
                default {error "unsupported application builtin: [list $name]"}
            }
        }
    }
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
        set scope $bindings
        set index 0
        foreach capture [dict get $arm bindings] {
            dict set scope [dict get $capture name] [format {[::lindex $%s %d]} $slot [incr index]]
        }
        set result [emitExpression [dict get $arm body] $context $scope [expr {$depth + 1}]]
        lappend words [list [dict get $arm variant]] [list [format {::set m_result %s} $result]]
    }
    # An explicit final default also allows a user variant named "default".
    lappend words default [list {::return -code error -errorcode {APPCOMPILER VALUE CHOICE} {invalid choice tag}}]
    return [format {[%s]} [join $words { }]]
}

proc ::appcompiler::emitListMatch {scrutinee slot arms context bindings depth} {
    set branches {}
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
                    lappend conditions [format {[::string equal %s %s]} $item [emitTextWord [dict get $pattern value]]]
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
    set word [emitExpression [dict get $node value] $context]
    switch -exact -- [dict get $node kind] {
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

proc ::appcompiler::emitStatements {statements context bodyVar locationsVar} {
    upvar 1 $bodyVar body $locationsVar locations
    foreach statement $statements {
        set location [emitLocation $statement]
        dict set locations [expr {[llength $body] + 1}] $location
        if {[dict get $statement kind] ne "if"} {
            lappend body [emitStatement $statement $context]
            continue
        }
        set test [emitExpression [dict get $statement condition] $context]
        lappend body [format {::if %s %c} $test 123]
        emitStatements [dict get $statement body] $context body locations
        if {[llength [dict get $statement otherwise]]} {
            lappend body [format {%c else %c} 125 123]
            dict set locations [llength $body] $location
            emitStatements [dict get $statement otherwise] $context body locations
        }
        lappend body \}
        dict set locations [llength $body] $location
    }
}

proc ::appcompiler::emitModules {modules targetNamespace {facts {}}} {
    set definitions [emitRuntime $targetNamespace $modules]
    set sourceMap [dict create]
    foreach module [lsort -ascii [dict keys $modules]] {
        set context [dict create target $targetNamespace module $module facts $facts]
        set moduleNamespace ${targetNamespace}::${module}
        lappend definitions [list ::namespace eval $moduleNamespace {}]
        foreach function [dict get $modules $module functions] {
            set resultParts [typeParts [dict get $function result]]
            dict set context problemResult [expr {[lindex $resultParts 0] eq "result"
                && [lindex $resultParts 2] eq "problem"}]
            set name ${moduleNamespace}::[dict get $function name]
            set formals {}
            set body {}
            set locations [dict create]
            foreach param [dict get $function params] {
                set local [emitLocalName [dict get $param name]]
                lappend formals $local
                set type [emitTypeName $module [dict get $param type]]
                if {[dict get $function exported] && $type ne "text"} {
                    lappend body [format {::set %s [%s %s $%s %s]} $local \
                        [list ${targetNamespace}::@rt::guard] [list $type] $local \
                        [list [format {$%s} [dict get $param name]]]]
                    dict set locations [llength $body] [emitLocation $param]
                }
            }
            emitStatements [dict get $function body] $context body locations
            lappend definitions [list ::proc $name $formals [join $body \n]]
            dict set sourceMap $name $locations
        }
    }
    return [dict create script [join $definitions \n] sourceMap $sourceMap]
}
