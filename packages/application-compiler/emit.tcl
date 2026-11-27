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
    lappend definitions [list ::proc ${rt}::reject {path expected} {
        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected $expected at $path"
    }]
    lappend definitions [list ::proc ${rt}::guard {type value path} {
        if {[string index $type end] eq "?"} {
            if {[catch {llength $value} size]} {reject $path $type}
            set tag [lindex $value 0]
            if {$tag eq "none" && $size == 1} {return [list none]}
            if {$tag ne "some" || $size != 2} {reject $path $type}
            return [list some [guard [string range $type 0 end-1] [lindex $value 1] $path]]
        }
        switch -exact -- $type {
            int {
                if {![regexp {\A[+-]?[0-9]+\Z} $value]} {reject $path int}
                # Unlimited precision and decimal even with leading zeroes.
                scan $value %lld number
                return $number
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

proc ::appcompiler::emitExpression {node targetNamespace module {bindings {}} {depth 0}} {
    set kind [dict get $node kind]
    switch -exact -- $kind {
        int  {return [emitIntegerWord [dict get $node value]]}
        text {return [emitTextWord [dict get $node value]]}
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
        binary {
            set op [dict get $node op]
            if {$op ni {+ - *}} {error "unsupported application operator: [list $op]"}
            set left [emitExpression [dict get $node left] $targetNamespace $module $bindings $depth]
            set right [emitExpression [dict get $node right] $targetNamespace $module $bindings $depth]
            return [format {[::tcl::mathop::%s %s %s]} $op $left $right]
        }
        call {
            set calleeModule [dict get $node qualifier]
            if {$calleeModule eq ""} {set calleeModule $module}
            set command ${targetNamespace}::${calleeModule}::[dict get $node name]
            set words [list [list $command]]
            foreach argument [dict get $node args] {
                lappend words [emitExpression $argument $targetNamespace $module $bindings $depth]
            }
            return [format {[%s]} [join $words { }]]
        }
        none {return none}
        some {
            set word [emitExpression [dict get $node value] $targetNamespace $module $bindings $depth]
            return [format {[::list some %s]} $word]
        }
        field {
            # Exported record guards have already checked every required field.
            set base [emitExpression [dict get $node base] $targetNamespace $module $bindings $depth]
            return [format {[::dict getdef %s %s none]} $base [list [dict get $node name]]]
        }
        update {
            set base [emitExpression [dict get $node base] $targetNamespace $module $bindings $depth]
            set words [list ::dict replace $base]
            foreach field [dict get $node fields] {
                lappend words [list [dict get $field name]] \
                    [emitExpression [dict get $field value] $targetNamespace $module $bindings $depth]
            }
            return [format {[%s]} [join $words { }]]
        }
        match {
            return [emitMatch $node $targetNamespace $module $bindings $depth]
        }
        default {error "unsupported application expression: [list $kind]"}
    }
}

proc ::appcompiler::emitMatch {node targetNamespace module bindings depth} {
    set scrutinee [emitExpression [dict get $node value] $targetNamespace $module $bindings $depth]
    # A nested arm must still be able to read its enclosing match's captures.
    # These names cannot coincide with the v_ prefix used for source locals.
    set slot m_$depth
    set selector [format {[::lindex [::set %s %s] 0]} $slot $scrutinee]
    set words [list ::switch -exact -- $selector]
    foreach arm [dict get $node arms] {
        set scope $bindings
        set index 0
        foreach capture [dict get $arm bindings] {
            dict set scope [dict get $capture name] [format {[::lindex $%s %d]} $slot [incr index]]
        }
        set result [emitExpression [dict get $arm body] $targetNamespace $module $scope [expr {$depth + 1}]]
        lappend words [list [dict get $arm variant]] [list [format {::set m_result %s} $result]]
    }
    # An explicit final default also allows a user variant named "default".
    lappend words default [list {::return -code error -errorcode {APPCOMPILER VALUE CHOICE} {invalid choice tag}}]
    return [format {[%s]} [join $words { }]]
}

proc ::appcompiler::emitStatement {node targetNamespace module} {
    set word [emitExpression [dict get $node value] $targetNamespace $module]
    switch -exact -- [dict get $node kind] {
        bind - assign {
            return [format {::set %s %s} [emitLocalName [dict get $node name]] $word]
        }
        return {return [format {::return %s} $word]}
        default {error "unsupported application statement: [list [dict get $node kind]]"}
    }
}

proc ::appcompiler::emitModules {modules targetNamespace} {
    set definitions [emitRuntime $targetNamespace $modules]
    set sourceMap [dict create]
    foreach module [lsort -ascii [dict keys $modules]] {
        set moduleNamespace ${targetNamespace}::${module}
        lappend definitions [list ::namespace eval $moduleNamespace {}]
        foreach function [dict get $modules $module functions] {
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
            foreach statement [dict get $function body] {
                lappend body [emitStatement $statement $targetNamespace $module]
                dict set locations [llength $body] [emitLocation $statement]
            }
            lappend definitions [list ::proc $name $formals [join $body \n]]
            dict set sourceMap $name $locations
        }
    }
    return [dict create script [join $definitions \n] sourceMap $sourceMap]
}
