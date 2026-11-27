namespace eval ::appcompiler::checker {}

proc ::appcompiler::checker::issue {reportsVar code node message} {
    upvar 1 $reportsVar reports
    lappend reports [::appcompiler::diagnostic $code $node $message]
}

# Types compare by canonical spelling: .module::name for a nominal type.
# Inside an expression, ? represents none with an as-yet-unknown payload;
# an empty type instead means that an earlier diagnostic prevents inference.
proc ::appcompiler::checker::declaredType {type node world reportsVar} {
    upvar 1 $reportsVar reports
    set base [string trimright $type "?"]
    set suffix [string range $type [string length $base] end]
    if {$base in {int text bool}} {
        return $type
    }
    if {![regexp {^\.(?:([a-zA-Z_][a-zA-Z_0-9]*)::)?([a-zA-Z_][a-zA-Z_0-9]*)$} $base -> target name]} {
        issue reports UNKNOWN_TYPE $node "unknown type '$type'"
        return ""
    }
    set caller [dict get $node module]
    if {$target eq ""} { set target $caller }
    if {$target ne $caller && $target ni [dict get $world modules $caller imports]} {
        issue reports MISSING_IMPORT $node "module '$target' must be imported before use"
        return ""
    }
    if {![dict exists $world modules $target]} {
        return ""
    }
    set key [format {.%s::%s} $target $name]
    if {![dict exists $world schemas $key]} {
        issue reports UNKNOWN_TYPE $node "unknown type '$base' in module '$target'"
        return ""
    }
    set schema [dict get $world schemas $key]
    if {$schema eq ""} { return "" }
    if {$target ne $caller && ![dict get $schema exported]} {
        issue reports NOT_EXPORTED $node "type '.$name' is private to module '$target'"
        return ""
    }
    return $key$suffix
}

proc ::appcompiler::checker::compatible {actual expected} {
    if {$actual eq $expected} { return 1 }
    # A hole at optional depth N fits any type with at least N optional layers.
    if {[string index $actual 0] ne "?"} { return 0 }
    set depth [expr {[string length $expected] - [string length [string trimright $expected "?"]]}]
    return [expr {[string length $actual] <= $depth}]
}

proc ::appcompiler::checker::signature {function world reportsVar} {
    upvar 1 $reportsVar reports
    set params {}
    foreach param [dict get $function params] {
        set location [dict getdef $param typeLocation $param]
        dict set param type [declaredType [dict get $param type] $location $world reports]
        lappend params $param
    }
    dict set function params $params
    set location [dict getdef $function resultLocation $function]
    dict set function result [declaredType [dict get $function result] $location $world reports]
    return $function
}

proc ::appcompiler::checker::readMembers {schema world reportsVar} {
    upvar 1 $reportsVar reports
    set members {}
    set isRecord [expr {[dict get $schema kind] eq "record"}]
    set section [expr {$isRecord ? "fields" : "variants"}]
    foreach member [dict get $schema $section] {
        set name [dict get $member name]
        if {[dict exists $members $name]} {
            if {$isRecord} {
                issue reports DUPLICATE_FIELD $member "field '$name' is already declared"
            } else {
                issue reports DUPLICATE_VARIANT $member "variant '$name' is already declared"
            }
            continue
        }
        if {$isRecord} {
            set location [dict getdef $member typeLocation $member]
            dict set members $name [declaredType [dict get $member type] $location $world reports]
        } else {
            set payload {}
            set index 0
            foreach type [dict get $member payload] {
                set location [lindex [dict getdef $member payloadLocations {}] $index]
                if {$location eq ""} { set location $member }
                lappend payload [declaredType $type $location $world reports]
                incr index
            }
            dict set members $name $payload
        }
    }
    return $members
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

proc ::appcompiler::checker::callType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set arguments [dict get $node args]
    set types {}
    foreach argument $arguments {
        lappend types [expressionType $argument $scope $imports $world reports]
    }

    set caller [dict get $node module]
    set target [dict get $node qualifier]
    if {$target eq ""} {
        set target $caller
    } elseif {$target ne $caller && $target ni $imports} {
        issue reports MISSING_IMPORT $node "module '$target' must be imported before use"
        return ""
    }
    if {![dict exists $world functions $target]} {
        # The module's missing import has its own diagnostic.
        return ""
    }
    set name [dict get $node name]
    if {![dict exists $world functions $target $name]} {
        issue reports UNKNOWN_FUNCTION $node "unknown function '.$name' in module '$target'"
        return ""
    }
    set function [dict get $world functions $target $name]
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
        if {$actual eq "" || $expected eq ""} {
            set valid 0
        } elseif {![compatible $actual $expected]} {
            set valid 0
            set paramName [dict get $param name]
            issue reports ARGUMENT_TYPE [lindex $arguments $i] "parameter '$paramName' expects $expected, got $actual"
        }
    }
    set result [dict get $function result]
    if {$valid} {
        return $result
    }
    return ""
}

proc ::appcompiler::checker::lookupField {fields field record reportsVar} {
    upvar 1 $reportsVar reports
    set name [dict get $field name]
    if {[dict exists $fields $name]} { return [dict get $fields $name] }
    set alternatives [join [dict keys $fields] {, }]
    if {$alternatives eq ""} { set alternatives "(none)" }
    issue reports UNKNOWN_FIELD $field "unknown field '$name' on $record; declared fields: $alternatives"
    return ""
}

proc ::appcompiler::checker::recordExpression {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set base [dict get $node base]
    set record [expressionType $base $scope $imports $world reports]
    set valid [expr {$record ne ""}]
    if {$valid && [dict getdef $world schemas $record kind {}] ne "record"} {
        issue reports EXPECTED_RECORD $base "expected a record, got $record"
        set valid 0
    }
    set hasRecord $valid
    if {$hasRecord} { set fields [dict get $world schemas $record members] }
    if {[dict get $node kind] eq "field"} {
        if {!$hasRecord} { return "" }
        return [lookupField $fields $node $record reports]
    }
    set updated {}
    foreach field [dict get $node fields] {
        set name [dict get $field name]
        set value [dict get $field value]
        set actual [expressionType $value $scope $imports $world reports]
        if {[dict exists $updated $name]} {
            issue reports DUPLICATE_UPDATE $field "field '$name' is updated more than once"
            set valid 0
        }
        dict set updated $name 1
        if {!$hasRecord} { continue }
        set expected [lookupField $fields $field $record reports]
        if {$actual eq "" || $expected eq ""} {
            set valid 0
        } elseif {![compatible $actual $expected]} {
            issue reports FIELD_TYPE $value "field '$name' on $record expects $expected, got $actual"
            set valid 0
        }
    }
    if {$valid} { return $record }
    return ""
}

proc ::appcompiler::checker::matchType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set value [dict get $node value]
    set choice [expressionType $value $scope $imports $world reports]
    if {$choice ne "" && [dict getdef $world schemas $choice kind {}] ne "choice"} {
        issue reports EXPECTED_CHOICE $value "expected a closed choice, got $choice"
        set choice ""
    }
    set seen {}
    set result ""
    set valid [expr {$choice ne ""}]
    set coverageKnown $valid
    foreach arm [dict get $node arms] {
        set location [dict getdef $arm typeLocation $arm]
        set variantLocation [dict getdef $arm variantLocation $arm]
        set pattern [declaredType [dict get $arm type] $location $world reports]
        set name [dict get $arm variant]
        set payload {}
        set knownVariant 0
        if {$pattern eq ""} {
            set valid 0
            set coverageKnown 0
        } elseif {[dict getdef $world schemas $pattern kind {}] ne "choice"} {
            issue reports EXPECTED_CHOICE $location "expected a closed choice in the pattern, got $pattern"
            set valid 0
            set coverageKnown 0
        } elseif {![dict exists $world schemas $pattern members $name]} {
            issue reports UNKNOWN_VARIANT $variantLocation "unknown variant '$name' on $pattern"
            set valid 0
            set coverageKnown 0
        } else {
            set knownVariant 1
            set payload [dict get $world schemas $pattern members $name]
            if {$choice ne "" && $pattern ne $choice} {
                issue reports PATTERN_TYPE $arm "expected a variant of $choice, got $pattern"
                set valid 0
                set coverageKnown 0
            } elseif {$pattern eq $choice} {
                if {[dict exists $seen $name]} {
                    issue reports DUPLICATE_ARM $variantLocation "variant '$name' is matched more than once"
                    set valid 0
                }
                dict set seen $name 1
            }
        }
        set bindings [dict get $arm bindings]
        if {$knownVariant && [llength $bindings] != [llength $payload]} {
            issue reports PATTERN_ARITY $variantLocation "variant '$name' expects [llength $payload] payload bindings, got [llength $bindings]"
            set valid 0
        }
        set local {}
        set index 0
        foreach binding $bindings {
            bindLocal local $binding [lindex $payload $index] 0 reports
            incr index
        }
        set body [dict get $arm body]
        set armType [expressionType $body [dict merge $scope $local] $imports $world reports]
        if {$armType eq ""} {
            set valid 0
        } elseif {$result eq "" || [compatible $result $armType]} {
            set result $armType
        } elseif {![compatible $armType $result]} {
            issue reports MATCH_ARM_TYPE $body "match arms have incompatible types $result and $armType"
            set valid 0
        }
    }
    # An unresolved pattern might be precisely the missing case. Its own
    # diagnostic is sufficient until the intended variant is known.
    if {$coverageKnown} {
        set absent {}
        foreach name [dict keys [dict get $world schemas $choice members]] {
            if {![dict exists $seen $name]} { lappend absent $name }
        }
        if {[llength $absent]} {
            issue reports MATCH_NONEXHAUSTIVE $node "match on $choice is missing variants: [join $absent {, }]"
            set valid 0
        }
    }
    if {$valid} { return $result }
    return ""
}

proc ::appcompiler::checker::expressionType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set kind [dict get $node kind]
    switch -exact -- $kind {
        int - text - bool { return $kind }
        none { return "?" }
        some {
            set type [expressionType [dict get $node value] $scope $imports $world reports]
            if {$type eq ""} { return "" }
            return ${type}?
        }
        field - update { return [recordExpression $node $scope $imports $world reports] }
        match { return [matchType $node $scope $imports $world reports] }
        var {
            set name [dict get $node name]
            if {![dict exists $scope $name]} {
                issue reports UNKNOWN_BINDING $node "unknown binding '$name'"
                return ""
            }
            return [dict get $scope $name type]
        }
        call { return [callType $node $scope $imports $world reports] }
        binary {
            set op [dict get $node op]
            set supported [expr {$op in {+ - *}}]
            if {!$supported} {
                issue reports UNKNOWN_OPERATOR $node "unknown binary operator '$op'"
            }
            set valid $supported
            foreach side {left right} {
                set operand [dict get $node $side]
                set type [expressionType $operand $scope $imports $world reports]
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

proc ::appcompiler::checker::checkFunction {function imports world reportsVar} {
    upvar 1 $reportsVar reports
    set scope {}
    foreach param [dict get $function params] {
        bindLocal scope $param [dict get $param type] 0 reports
    }
    set result [dict get $function result]
    set sawReturn 0
    foreach statement [dict get $function body] {
        set kind [dict get $statement kind]
        switch -exact -- $kind {
            bind {
                set value [dict get $statement value]
                set type [expressionType $value $scope $imports $world reports]
                if {[string index $type 0] eq "?"} {
                    issue reports OPTIONAL_TYPE_REQUIRED $value "cannot infer an optional payload type from none"
                    set type ""
                }
                bindLocal scope $statement $type [dict get $statement mutable] reports
            }
            assign {
                set value [dict get $statement value]
                set actual [expressionType $value $scope $imports $world reports]
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
                } elseif {$actual ne "" && $expected ne "" && ![compatible $actual $expected]} {
                    issue reports ASSIGNMENT_TYPE $value "binding '$name' expects $expected, got $actual"
                }
            }
            return {
                set sawReturn 1
                set value [dict get $statement value]
                set actual [expressionType $value $scope $imports $world reports]
                if {$actual ne "" && $result ne "" && ![compatible $actual $result]} {
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
    set world [dict create modules $modules schemas {} functions {}]
    # Establish nominal identities before resolving any field or signature types.
    dict for {module definition} $modules {
        foreach schema [dict getdef $definition types {}] {
            set key [format {.%s::%s} $module [dict get $schema name]]
            if {[dict exists $world schemas $key]} {
                checker::issue reports DUPLICATE_TYPE $schema "type '$key' is already declared"
                dict set world schemas $key ""
            } else {
                dict set world schemas $key $schema
            }
        }
    }
    dict for {key schema} [dict get $world schemas] {
        if {$schema ne ""} {
            dict set world schemas $key members [checker::readMembers $schema $world reports]
        }
    }
    # Index normalized signatures before bodies to support forward and recursive calls.
    set bodies {}
    dict for {module definition} $modules {
        dict set world functions $module {}
        foreach function [dict get $definition functions] {
            set function [checker::signature $function $world reports]
            dict lappend bodies $module $function
            set name [dict get $function name]
            if {[dict exists $world functions $module $name]} {
                checker::issue reports DUPLICATE_FUNCTION $function "function '.$name' is already declared in module '$module'"
                dict set world functions $module $name ""
            } else {
                dict set world functions $module $name $function
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
        foreach function [dict getdef $bodies $module {}] {
            checker::checkFunction $function $imports $world reports
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
