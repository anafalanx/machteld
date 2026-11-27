namespace eval ::appcompiler::checker {}

proc ::appcompiler::checker::issue {reportsVar code node message} {
    upvar 1 $reportsVar reports
    lappend reports [::appcompiler::diagnostic $code $node $message]
}

proc ::appcompiler::checker::knownType {type} {
    return [expr {$type in {int text bool}}]
}

proc ::appcompiler::checker::declaredType {type node reportsVar} {
    upvar 1 $reportsVar reports
    if {![knownType $type]} {
        issue reports UNKNOWN_TYPE $node "unknown type '$type'"
        return ""
    }
    return $type
}

proc ::appcompiler::checker::bindLocal {scopeVar node type mutable reportsVar} {
    upvar 1 $scopeVar scope $reportsVar reports
    set name [dict get $node name]
    if {[dict exists $scope $name]} {
        issue reports DUPLICATE_BINDING $node "binding '$name' is already declared"
        # Neither declaration can supply unambiguous information to later uses.
        dict set scope $name [dict create type "" mutable ""]
        return
    }
    dict set scope $name [dict create type $type mutable $mutable]
}

proc ::appcompiler::checker::callType {node scope imports functions reportsVar} {
    upvar 1 $reportsVar reports
    set arguments [dict get $node args]
    set types {}
    foreach argument $arguments {
        lappend types [expressionType $argument $scope $imports $functions reports]
    }

    set caller [dict get $node module]
    set target [dict get $node qualifier]
    if {$target eq ""} {
        set target $caller
    } elseif {$target ne $caller && $target ni $imports} {
        issue reports MISSING_IMPORT $node "module '$target' must be imported before use"
        return ""
    }
    if {![dict exists $functions $target]} {
        # The module's missing import has its own diagnostic.
        return ""
    }
    set name [dict get $node name]
    if {![dict exists $functions $target $name]} {
        issue reports UNKNOWN_FUNCTION $node "unknown function '.$name' in module '$target'"
        return ""
    }
    set function [dict get $functions $target $name]
    if {$function eq ""} {
        return ""
    }
    if {$caller ne $target && ![dict get $function exported]} {
        issue reports NOT_EXPORTED $node "function '.$name' is private to module '$target'"
        return ""
    }

    set params [dict get $function params]
    set expectedCount [llength $params]
    set actualCount [llength $arguments]
    set valid [expr {$actualCount == $expectedCount}]
    if {!$valid} {
        issue reports CALL_ARITY $node "'.$name' expects $expectedCount arguments, got $actualCount"
    }
    for {set i 0} {$i < min($actualCount, $expectedCount)} {incr i} {
        set param [lindex $params $i]
        set expected [dict get $param type]
        set actual [lindex $types $i]
        if {$actual eq "" || ![knownType $expected]} {
            set valid 0
        } elseif {$actual ne $expected} {
            set valid 0
            set paramName [dict get $param name]
            issue reports ARGUMENT_TYPE [lindex $arguments $i] "parameter '$paramName' expects $expected, got $actual"
        }
    }
    set result [dict get $function result]
    if {$valid && [knownType $result]} {
        return $result
    }
    return ""
}

proc ::appcompiler::checker::expressionType {node scope imports functions reportsVar} {
    upvar 1 $reportsVar reports
    set kind [dict get $node kind]
    switch -exact -- $kind {
        int - text - bool { return $kind }
        var {
            set name [dict get $node name]
            if {![dict exists $scope $name]} {
                issue reports UNKNOWN_BINDING $node "unknown binding '$name'"
                return ""
            }
            return [dict get $scope $name type]
        }
        call { return [callType $node $scope $imports $functions reports] }
        binary {
            set op [dict get $node op]
            set supported [expr {$op in {+ - *}}]
            if {!$supported} {
                issue reports UNKNOWN_OPERATOR $node "unknown binary operator '$op'"
            }
            set valid $supported
            foreach side {left right} {
                set operand [dict get $node $side]
                set type [expressionType $operand $scope $imports $functions reports]
                if {$type eq ""} {
                    set valid 0
                } elseif {$supported && $type ne "int"} {
                    set valid 0
                    issue reports OPERAND_TYPE $operand "'$op' expects an int operand, got $type"
                }
            }
            if {$valid} {
                return int
            }
            return ""
        }
        default {
            issue reports UNKNOWN_EXPRESSION $node "unknown expression kind '$kind'"
            return ""
        }
    }
}

proc ::appcompiler::checker::checkFunction {function imports functions reportsVar} {
    upvar 1 $reportsVar reports
    set scope {}
    foreach param [dict get $function params] {
        set type [declaredType [dict get $param type] $param reports]
        bindLocal scope $param $type 0 reports
    }
    set result [declaredType [dict get $function result] $function reports]
    set sawReturn 0
    foreach statement [dict get $function body] {
        set kind [dict get $statement kind]
        switch -exact -- $kind {
            bind {
                set type [expressionType [dict get $statement value] $scope $imports $functions reports]
                bindLocal scope $statement $type [dict get $statement mutable] reports
            }
            assign {
                set value [dict get $statement value]
                set actual [expressionType $value $scope $imports $functions reports]
                set name [dict get $statement name]
                if {![dict exists $scope $name]} {
                    issue reports UNKNOWN_BINDING $statement "unknown binding '$name'"
                    continue
                }
                set mutable [dict get $scope $name mutable]
                set expected [dict get $scope $name type]
                if {$mutable eq ""} {
                    continue
                }
                if {!$mutable} {
                    issue reports FIXED_ASSIGNMENT $statement "cannot reassign fixed binding '$name'"
                } elseif {$actual ne "" && $expected ne "" && $actual ne $expected} {
                    issue reports ASSIGNMENT_TYPE $value "binding '$name' expects $expected, got $actual"
                }
            }
            return {
                set sawReturn 1
                set value [dict get $statement value]
                set actual [expressionType $value $scope $imports $functions reports]
                if {$actual ne "" && $result ne "" && $actual ne $result} {
                    issue reports RETURN_TYPE $value "expected return type $result, got $actual"
                }
            }
            default {
                issue reports UNKNOWN_STATEMENT $statement "unknown statement kind '$kind'"
            }
        }
    }
    if {!$sawReturn} {
        set name [dict get $function name]
        issue reports MISSING_RETURN $function "function '.$name' must return a value"
    }
}

proc ::appcompiler::checkDiagnostics {modules {unavailable {}}} {
    set reports {}
    set functions {}
    # Index signatures first so forward calls and cross-module recursion can resolve.
    dict for {module definition} $modules {
        dict set functions $module {}
        foreach function [dict get $definition functions] {
            set name [dict get $function name]
            if {[dict exists $functions $module $name]} {
                checker::issue reports DUPLICATE_FUNCTION $function "function '.$name' is already declared in module '$module'"
                dict set functions $module $name ""
            } else {
                dict set functions $module $name $function
            }
        }
    }
    dict for {module definition} $modules {
        set imports [dict get $definition imports]
        foreach imported $imports {
            if {![dict exists $modules $imported] && ![dict exists $unavailable $imported]} {
                if {[dict exists $definition importLocations $imported]} {
                    set node [dict get $definition importLocations $imported]
                } else {
                    set node [dict create module $module line 1 column 1]
                }
                checker::issue reports UNKNOWN_MODULE $node "imported module '$imported' was not supplied"
            }
        }
        foreach function [dict get $definition functions] {
            checker::checkFunction $function $imports $functions reports
        }
    }
    return $reports
}

proc ::appcompiler::checkModules {modules} {
    set reports [checkDiagnostics $modules]
    if {[llength $reports]} {
        set first [lindex $reports 0]
        fail [dict get $first code] [dict get $first node] [dict get $first message]
    }
    return
}
