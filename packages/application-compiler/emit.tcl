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

proc ::appcompiler::emitArgumentGuard {param local} {
    set type [dict get $param type]
    if {$type eq "text"} {return {}}
    set message [format {expected %s for parameter $%s} $type [dict get $param name]]
    set failure [list [list ::return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} $message]]
    switch -exact -- $type {
        int {
            # %lld reads an arbitrary-precision decimal. Validate the whole
            # word first because scan would otherwise accept a numeric prefix.
            return [format {::if {![::regexp {\A[+-]?[0-9]+\Z} $%1$s]} %2$s; ::scan $%1$s %%lld %1$s} $local $failure]
        }
        bool {
            return [format {::if {$%1$s ni {0 1 false true}} %2$s; ::set %1$s [::expr {$%1$s in {1 true}}]} $local $failure]
        }
        default {error "unsupported application argument type: [list $type]"}
    }
}

proc ::appcompiler::emitLocation {node} {
    return [dict create module [dict get $node module] line [dict get $node line] \
        column [dict get $node column]]
}

proc ::appcompiler::emitExpression {node targetNamespace module} {
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
            return [format {$%s} [emitLocalName [dict get $node name]]]
        }
        binary {
            set op [dict get $node op]
            if {$op ni {+ - *}} {error "unsupported application operator: [list $op]"}
            set left [emitExpression [dict get $node left] $targetNamespace $module]
            set right [emitExpression [dict get $node right] $targetNamespace $module]
            return [format {[::tcl::mathop::%s %s %s]} $op $left $right]
        }
        call {
            set calleeModule [dict get $node qualifier]
            if {$calleeModule eq ""} {set calleeModule $module}
            set command ${targetNamespace}::${calleeModule}::[dict get $node name]
            set words [list [list $command]]
            foreach argument [dict get $node args] {
                lappend words [emitExpression $argument $targetNamespace $module]
            }
            return [format {[%s]} [join $words { }]]
        }
        default {error "unsupported application expression: [list $kind]"}
    }
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
    set definitions {}
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
                if {[dict get $function exported]} {
                    set guard [emitArgumentGuard $param $local]
                    if {$guard ne ""} {
                        lappend body $guard
                        dict set locations [llength $body] [emitLocation $param]
                    }
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
