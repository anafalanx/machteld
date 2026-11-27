namespace eval ::appcompiler::checker {}

proc ::appcompiler::checker::issue {reportsVar code node message} {
    upvar 1 $reportsVar reports
    dict lappend reports diagnostics [::appcompiler::diagnostic $code $node $message]
}

proc ::appcompiler::checker::fact {reportsVar node name value} {
    upvar 1 $reportsVar reports
    set key [list [dict get $node module] [dict get $node line] [dict get $node column] [dict get $node kind]]
    dict set reports facts $key $name $value
}

proc ::appcompiler::checker::makeType {head arguments} {
    if {$head eq "optional"} { return [lindex $arguments 0]? }
    return [format {%s<%s>} $head [join $arguments ,]]
}

proc ::appcompiler::checker::typeFits {length node reportsVar} {
    upvar 1 $reportsVar reports
    set limit 8192
    if {$length <= $limit} { return 1 }
    issue reports TYPE_EXPANSION_LIMIT $node "expanded type exceeds $limit characters"
    return 0
}

# Nominal types include the defining module. A '*' is an internal inference
# variable for an absent payload. An empty type marks a prior diagnostic.
proc ::appcompiler::checker::declaredType {type node world reportsVar} {
    upvar 1 $reportsVar reports
    set parts [::appcompiler::typeParts $type]
    set head [lindex $parts 0]
    if {$head in {result list optional range map}} {
        set arity [expr {$head in {result map} ? 2 : 1}]
        if {[llength $parts] != $arity + 1} {
            issue reports TYPE_ARITY $node "type '$head' requires $arity type arguments"
            return ""
        }
        set args {}
        set locations [dict getdef $node typeLocations {}]
        foreach child [lrange $parts 1 end] location $locations {
            if {$location eq ""} { set location $node }
            lappend args [declaredType $child $location $world reports]
        }
        if {[dict exists $reports typeReferences]} { return "" }
        set key [lindex $args 0]
        if {$head eq "map" && [dict getdef $reports distinctBases $key $key] ni {{} text int bool decimal}} {
            set location [lindex $locations 0]
            if {$location eq ""} { set location $node }
            issue reports MAP_KEY_TYPE $location "map keys require text, int, bool or decimal storage, got $key"
            return ""
        }
        if {"" in $args} { return "" }
        if {$head eq "range" && [lindex $args 0] ne "int"} {
            issue reports RANGE_ELEMENT_TYPE $node "only ranges of int are supported"
            return ""
        }
        # Count punctuation and canonical children before joining. Repeated
        # aliases in a generic can otherwise double its spelling at each step.
        set length [expr {$head eq "optional" ? 1 : [string length $head] + $arity + 1}]
        foreach argument $args { incr length [string length $argument] }
        if {![typeFits $length $node reports]} { return "" }
        return [makeType $head $args]
    }
    if {$type in {int decimal text bool bytes problem unit}} { return $type }
    if {![regexp {^\.(?:([a-zA-Z_][a-zA-Z_0-9]*)::)?([a-zA-Z_][a-zA-Z_0-9]*)$} $type -> target name]} {
        issue reports UNKNOWN_TYPE $node "unknown type '$type'"
        return ""
    }
    set caller [dict get $node module]
    if {$target eq ""} { set target $caller }
    if {$target ne $caller && $target ni [dict get $world modules $caller imports]} {
        issue reports MISSING_IMPORT $node "module '$target' must be imported before use"
        return ""
    }
    if {![dict exists $world modules $target]} { return "" }
    set key [format {.%s::%s} $target $name]
    if {![dict exists $world schemas $key]} {
        issue reports UNKNOWN_TYPE $node "unknown type '$type' in module '$target'"
        return ""
    }
    set schema [dict get $world schemas $key]
    if {$schema eq ""} { return "" }
    if {$target ne $caller && ![dict get $schema exported]} {
        issue reports NOT_EXPORTED $node "type '.$name' is private to module '$target'"
        return ""
    }
    if {[dict get $schema kind] in {alias distinct}} {
        if {[dict exists $reports typeReferences]} {
            dict set reports typeReferences $key $node
            return ""
        }
        return [dict getdef $reports typeNames $key {}]
    }
    if {![typeFits [string length $key] $node reports]} { return "" }
    return $key
}

# Resolve aliases and distinct backing types after dependencies. References to
# records and choices terminate at their identity, allowing recursive members.
# An explicit worklist permits long chains without Tcl call-stack growth.
proc ::appcompiler::checker::resolveTypeNames {world reportsVar} {
    upvar 1 $reportsVar reports
    set dependencies {}
    dict for {key schema} [dict get $world schemas] {
        if {$schema eq "" || [dict get $schema kind] ni {alias distinct}} { continue }
        set scan [dict create typeReferences {} diagnostics {}]
        declaredType [dict get $schema target] [dict get $schema targetLocation] $world scan
        dict set dependencies $key [dict get $scan typeReferences]
    }
    set active {}
    set path {}
    foreach root [dict keys $dependencies] {
        set stack [list [list enter $root {}]]
        while {[llength $stack]} {
            lassign [lpop stack] step key location
            if {$step eq "resolve"} {
                set schema [dict get $world schemas $key]
                set where [dict get $schema targetLocation]
                set type [declaredType [dict get $schema target] $where $world reports]
                if {[dict get $schema kind] eq "distinct" && $type ne ""} {
                    if {$type ni {text int decimal bool bytes}} {
                        issue reports DISTINCT_BASE_TYPE $where "a distinct type requires a primitive scalar base, got $type"
                        set type ""
                    } elseif {![typeFits [string length $key] $schema reports]} {
                        set type ""
                    } else {
                        dict set reports distinctBases $key $type
                        set type $key
                    }
                }
                dict set reports typeNames $key $type
                dict unset active $key
                lpop path
            } elseif {![dict exists $reports typeNames $key]} {
                if {[dict exists $active $key]} {
                    set code ALIAS_CYCLE
                    foreach member [lrange $path [dict get $active $key] end] {
                        if {[dict get $world schemas $member kind] eq "distinct"} { set code DISTINCT_CYCLE; break }
                    }
                    issue reports $code $location "type definition '$key' refers back to itself"
                    dict set reports typeNames $key ""
                    continue
                }
                dict set active $key [llength $path]
                lappend path $key
                lappend stack [list resolve $key {}]
                set references [dict get $dependencies $key]
                foreach dependency [lreverse [dict keys $references]] {
                    lappend stack [list enter $dependency [dict get $references $dependency]]
                }
            }
        }
    }
}

# Keep concrete information from both operands; e.g. result<int,*> joined
# with result<*,problem> yields result<int,problem> for an exhaustive match.
proc ::appcompiler::checker::joinTypes {left right} {
    if {$left eq "" || $right eq ""} { return "" }
    if {$left eq "*" || $left eq $right} { return $right }
    if {$right eq "*"} { return $left }
    set a [::appcompiler::typeParts $left]
    set b [::appcompiler::typeParts $right]
    set head [lindex $a 0]
    if {$head ne [lindex $b 0] || [llength $a] != [llength $b] || [llength $a] < 2} { return "" }
    set args {}
    foreach x [lrange $a 1 end] y [lrange $b 1 end] {
        set joined [joinTypes $x $y]
        if {$joined eq ""} { return "" }
        lappend args $joined
    }
    return [makeType $head $args]
}

proc ::appcompiler::checker::compatible {actual expected} {
    return [expr {[joinTypes $actual $expected] ne ""}]
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

proc ::appcompiler::checker::argumentTypes {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set types {}
    foreach argument [dict get $node args] {
        lappend types [expressionType $argument $scope $imports $world reports]
    }
    return $types
}

proc ::appcompiler::checker::checkArguments {node name actual expected reportsVar} {
    upvar 1 $reportsVar reports
    set count [llength $expected]
    set valid [expr {$count == [llength $actual]}]
    if {!$valid} {
        issue reports CALL_ARITY $node "'$name' expects $count arguments, got [llength $actual]"
    }
    foreach have $actual want $expected arg [dict get $node args] {
        if {$have eq "" || $want eq ""} {
            set valid 0
        } elseif {$want eq "numeric" ? $have ni {int decimal} : ![compatible $have $want]} {
            issue reports ARGUMENT_TYPE $arg "'$name' expects $want, got $have"
            set valid 0
        }
    }
    return $valid
}

proc ::appcompiler::checker::constructType {node spelling name ambiguous scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set actual [argumentTypes $node $scope $imports $world reports]
    set where [dict getdef $node typeLocation $node]
    set choice [declaredType $spelling $where $world reports]
    if {$choice eq ""} { return "" }
    if {[dict getdef $world schemas $choice kind {}] ne "choice"} {
        issue reports EXPECTED_CHOICE $where "expected a choice type, got $choice"
        return ""
    }
    set alternate [string range $spelling 1 end]
    set function [dict getdef $world functions $alternate $name {}]
    if {$ambiguous && $alternate in $imports && $function ne "" && [dict get $function exported]
            && [dict exists $world schemas $choice members $name]} {
        issue reports AMBIGUOUS_CALL $node "'[format {%s::%s} $spelling $name]' names both an imported function and a local choice variant"
        return ""
    }
    if {![dict exists $world schemas $choice members $name]} {
        issue reports UNKNOWN_VARIANT [dict getdef $node variantLocation $node] "unknown variant '$name' on $choice"
        return ""
    }
    set payload [dict get $world schemas $choice members $name]
    if {![checkArguments $node $name $actual $payload reports]} { return "" }
    fact reports $node constructor $choice
    return $choice
}

proc ::appcompiler::checker::builtinType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set name [dict get $node name]
    set actual [argumentTypes $node $scope $imports $world reports]
    set generic [dict getdef $node typeArgs {}]
    set count [dict getdef {decode_json 1 make 1 map 2} $name 0]
    if {[llength $generic] != $count} {
        issue reports TYPE_ARITY $node "'$name' expects $count type arguments, got [llength $generic]"
        return ""
    }
    switch -exact -- $name {
        ok - err - encode_json - underlying { set params [list *] }
        make {
            set location [lindex [dict getdef $node typeLocations {}] 0]
            if {$location eq ""} { set location $node }
            set nominal [declaredType [lindex $generic 0] $location $world reports]
            set base [dict getdef $reports distinctBases $nominal {}]
            if {$nominal ne "" && $base eq ""} {
                issue reports EXPECTED_DISTINCT $location "make requires a distinct scalar type, got $nominal"
            }
            set params [list $base]
        }
        problem - decode_json - write_stdout_utf8 { set params [list text] }
        decode_utf8 { set params [list bytes] }
        decode_text - preview_text { set params {bytes text} }
        read_stdin_bytes - map { set params {} }
        map_put - require_key - sorted_keys { return [mapCall $node $name $actual reports] }
        quotient { set params {int int} }
        divide_rounded { set params {numeric numeric int text} }
        default {
            issue reports UNKNOWN_FUNCTION $node "unknown standard function '$name'"
            return ""
        }
    }
    set valid [checkArguments $node $name $actual $params reports]
    if {$name eq "map"} {
        set type [declaredType [makeType map $generic] $node $world reports]
        if {!$valid} { return "" }
        return $type
    }
    if {$name eq "decode_json"} {
        set location [lindex [dict getdef $node typeLocations {}] 0]
        if {$location eq ""} { set location $node }
        set schema [declaredType [lindex $generic 0] $location $world reports]
        if {$schema eq ""} { return "" }
        if {[dict getdef $world schemas $schema kind {}] ne "record"} {
            issue reports EXPECTED_RECORD $location "decode_json requires a record schema, got $schema"
            return ""
        }
    }
    if {!$valid} { return "" }
    switch -exact -- $name {
        make { return $nominal }
        underlying {
            set type [lindex $actual 0]
            if {![dict exists $reports distinctBases $type]} {
                issue reports EXPECTED_DISTINCT [lindex [dict get $node args] 0] "underlying requires a distinct scalar, got $type"
                return ""
            }
            return [dict get $reports distinctBases $type]
        }
        ok { return [makeType result [list [lindex $actual 0] *]] }
        err { return [makeType result [list * [lindex $actual 0]]] }
        problem { return problem }
        read_stdin_bytes { return result<bytes,problem> }
        decode_utf8 - decode_text - preview_text { return result<text,problem> }
        decode_json {
            fact reports $node schema $schema
            return [makeType result [list $schema problem]]
        }
        encode_json {
            set schema [lindex $actual 0]
            if {[dict getdef $world schemas $schema kind {}] ne "record"} {
                issue reports EXPECTED_RECORD [lindex [dict get $node args] 0] "encode_json requires a record, got $schema"
                return ""
            }
            fact reports $node schema $schema
            return result<text,problem>
        }
        write_stdout_utf8 { return result<unit,problem> }
        quotient { return result<int,problem> }
        divide_rounded { return result<decimal,problem> }
    }
}

proc ::appcompiler::checker::mapParts {type base reportsVar} {
    upvar 1 $reportsVar reports
    if {$type eq ""} { return {} }
    set parts [::appcompiler::typeParts $type]
    if {[lindex $parts 0] eq "map"} { return $parts }
    issue reports EXPECTED_MAP $base "expected a map, got $type"
    return {}
}

proc ::appcompiler::checker::mapKeyMatches {actual expected key reportsVar} {
    upvar 1 $reportsVar reports
    if {$actual eq ""} { return 0 }
    if {$actual eq $expected} { return 1 }
    issue reports MAP_KEY_TYPE $key "map expects a $expected key, got $actual"
    return 0
}

proc ::appcompiler::checker::mapCall {node name actual reportsVar} {
    upvar 1 $reportsVar reports
    set params [dict get {map_put {* * *} require_key {* *} sorted_keys {*}} $name]
    set valid [checkArguments $node $name $actual $params reports]
    set args [dict get $node args]
    set mapType [lindex $actual 0]
    set parts [mapParts $mapType [lindex $args 0] reports]
    if {![llength $parts]} { return "" }
    lassign $parts head keyType valueType
    if {$name ne "sorted_keys" && ![mapKeyMatches [lindex $actual 1] $keyType [lindex $args 1] reports]} {
        set valid 0
    }
    if {$name eq "map_put"} {
        set value [lindex $actual 2]
        if {$value ne "" && ![compatible $value $valueType]} {
            issue reports ARGUMENT_TYPE [lindex $args 2] "'map_put' expects $valueType, got $value"
            set valid 0
        }
    }
    if {!$valid} { return "" }
    fact reports $node keyType [dict getdef $reports distinctBases $keyType $keyType]
    switch -exact -- $name {
        map_put { return $mapType }
        require_key { return [makeType result [list $valueType problem]] }
        sorted_keys { return [makeType list [list $keyType]] }
    }
}

proc ::appcompiler::checker::callType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set caller [dict get $node module]
    set target [dict get $node qualifier]
    set name [dict get $node name]
    set localChoice [format {.%s::%s} $caller $target]
    if {$target ne ""} {
        set declaredKind [dict getdef $world schemas $localChoice kind {}]
        if {$declaredKind eq "alias"} { set localChoice [dict get $reports typeNames $localChoice] }
        set isChoice [expr {[dict getdef $world schemas $localChoice kind {}] eq "choice"}]
        if {($isChoice && [dict exists $world schemas $localChoice members $name])
                || (($declaredKind in {alias distinct} || $isChoice) && $target ni $imports)} {
            return [constructType $node .$target $name 1 $scope $imports $world reports]
        }
    }
    set actual [argumentTypes $node $scope $imports $world reports]
    if {$target eq ""} {
        set target $caller
    } elseif {$target ne $caller && $target ni $imports} {
        issue reports MISSING_IMPORT $node "module '$target' must be imported before use"
        return ""
    }
    if {![dict exists $world functions $target]} { return "" }
    if {![dict exists $world functions $target $name]} {
        issue reports UNKNOWN_FUNCTION $node "unknown function '.$name' in module '$target'"
        return ""
    }
    set function [dict get $world functions $target $name]
    if {$function eq ""} { return "" }
    if {$caller ne $target && ![dict get $function exported]} {
        issue reports NOT_EXPORTED $node "function '.$name' is private to module '$target'"
        return ""
    }
    return [checkCall $node .$name $actual $function reports]
}

proc ::appcompiler::checker::checkCall {node name actual function reportsVar} {
    upvar 1 $reportsVar reports
    set expected [lmap param [dict get $function params] {dict get $param type}]
    if {![checkArguments $node $name $actual $expected reports]} { return "" }
    return [dict get $function result]
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

proc ::appcompiler::checker::joinArm {body armType resultVar validVar reportsVar} {
    upvar 1 $resultVar result $validVar valid $reportsVar reports
    if {$armType eq ""} {
        set valid 0
    } elseif {$result eq ""} {
        set result $armType
    } else {
        set joined [joinTypes $result $armType]
        if {$joined eq ""} {
            issue reports MATCH_ARM_TYPE $body "match arms have incompatible types $result and $armType"
            set valid 0
        } else {
            set result $joined
        }
    }
}

proc ::appcompiler::checker::listMatchType {node element scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set seenFallback 0
    set coverageKnown 1
    set valid [expr {$element ne ""}]
    set result ""
    foreach arm [dict get $node arms] {
        set local {}
        if {$seenFallback} {
            issue reports UNREACHABLE_ARM $arm "an earlier wildcard already matches every list"
            set valid 0
        }
        switch -exact -- [dict get $arm kind] {
            fallback { set seenFallback 1 }
            listarm {
                foreach pattern [dict get $arm elements] {
                    if {[dict get $pattern kind] eq "patternText"} {
                        if {$element ne "" && $element ne "text"} {
                            issue reports PATTERN_TYPE $pattern "a text pattern cannot match a list element of type $element"
                            set valid 0
                        }
                    } else {
                        bindLocal local $pattern $element 0 reports
                    }
                }
            }
            default {
                issue reports PATTERN_TYPE $arm "a list match requires a list pattern or a wildcard"
                set valid 0
                set coverageKnown 0
                set seen {}
                set alternatives [dict getdef $arm alternatives [list $arm]]
                set local [choiceArmScope $alternatives {} $world seen coverageKnown valid reports]
            }
        }
        set body [dict get $arm body]
        set armType [expressionType $body [dict merge $scope $local] $imports $world reports]
        joinArm $body $armType result valid reports
    }
    if {!$seenFallback && $element ne "" && $coverageKnown} {
        issue reports MATCH_NONEXHAUSTIVE $node "a list match requires a wildcard to cover other contents and lengths"
        set valid 0
    }
    if {$valid} { return $result }
    return ""
}

# Check the variant and its payload independently of any shared arm body.
proc ::appcompiler::checker::choicePattern {arm choice world seenVar coverageVar reportsVar} {
    upvar 1 $seenVar seen $coverageVar coverageKnown $reportsVar reports
    set valid 1
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
        if {[dict get $binding kind] ne "discard"} {
            set capture [dict get $binding name]
            set type [lindex $payload $index]
            if {$type eq "" || [dict exists $local $capture]} { set valid 0 }
            bindLocal local $binding $type 0 reports
            dict set local $capture location $binding
        }
        incr index
    }
    return [list $valid $local]
}

proc ::appcompiler::checker::choiceArmScope {alternatives choice world seenVar coverageVar validVar reportsVar} {
    upvar 1 $seenVar seen $coverageVar coverageKnown $validVar valid $reportsVar reports
    set recovery {}
    set common {}
    foreach alternative $alternatives {
        lassign [choicePattern $alternative $choice $world seen coverageKnown reports] ok local
        if {[llength $alternatives] == 1} {
            if {!$ok} { set valid 0 }
            return $local
        }
        # Mentioned but disputed names have unknown types during recovery.
        # Uses of unrelated names still receive their ordinary diagnostics.
        foreach name [dict keys $local] {
            dict set recovery $name [dict create type {} mutable 0]
        }
        if {!$ok} { set valid 0; continue }
        if {![info exists reference]} {
            set reference $local
            set common $local
            continue
        }
        set sameNames [expr {[dict size $local] == [dict size $reference]}]
        set where [dict get $alternative variantLocation]
        dict for {name binding} $local {
            if {![dict exists $reference $name]} {
                set sameNames 0
                set where [dict get $binding location]
                break
            }
        }
        if {!$sameNames} {
            issue reports PATTERN_BINDINGS $where "alternatives must bind the same names, expected [list [dict keys $reference]], got [list [dict keys $local]]"
            set valid 0
        }
        dict for {name binding} $reference {
            if {![dict exists $local $name]} {
                dict unset common $name
                continue
            }
            set expected [dict get $binding type]
            set type [dict get $local $name type]
            if {$expected ne $type} {
                dict unset common $name
                if {$type ne "" && $expected ne ""} {
                    issue reports PATTERN_BINDING_TYPE [dict get $local $name location] "alternatives bind '$name' as both $expected and $type"
                    set valid 0
                }
            }
        }
    }
    return [dict merge $recovery $common]
}

proc ::appcompiler::checker::matchType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set value [dict get $node value]
    set choice [expressionType $value $scope $imports $world reports]
    set parts [::appcompiler::typeParts $choice]
    if {[lindex $parts 0] eq "list"} {
        return [listMatchType $node [lindex $parts 1] $scope $imports $world reports]
    }
    set arms [dict get $node arms]
    if {[llength $arms] && [dict get [lindex $arms 0] kind] in {listarm fallback}
            && [dict getdef $world schemas $choice kind {}] ne "choice"} {
        if {$choice ne ""} {
            issue reports EXPECTED_LIST $value "expected a list for these patterns, got $choice"
        }
        return [listMatchType $node "" $scope $imports $world reports]
    }
    if {$choice ne "" && [dict getdef $world schemas $choice kind {}] ne "choice"} {
        issue reports EXPECTED_CHOICE $value "expected a closed choice, got $choice"
        set choice ""
    }
    set seen {}
    set result ""
    set valid [expr {$choice ne ""}]
    set coverageKnown $valid
    foreach arm [dict get $node arms] {
        if {[dict get $arm kind] in {arm armGroup}} {
            set alternatives [dict getdef $arm alternatives [list $arm]]
            set local [choiceArmScope $alternatives $choice $world seen coverageKnown valid reports]
        } else {
            if {$choice ne ""} {
                issue reports PATTERN_TYPE $arm "a closed choice match must explicitly name its variants"
            }
            set valid 0
            set coverageKnown 0
            set local {}
            foreach pattern [dict getdef $arm elements {}] {
                if {[dict get $pattern kind] eq "pattern"} { bindLocal local $pattern {} 0 reports }
            }
        }
        set body [dict get $arm body]
        set armType [expressionType $body [dict merge $scope $local] $imports $world reports]
        joinArm $body $armType result valid reports
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

# Equality visits each reachable type once, even for cyclic declarations.
# A failed member declaration already has a diagnostic. Its unknown type
# cannot establish either comparability or a second, independent error.
proc ::appcompiler::checker::comparable {type world} {
    set pending [list $type]
    set seen {}
    set known 1
    for {set i 0} {$i < [llength $pending]} {incr i} {
        set member [lindex $pending $i]
        if {[dict exists $seen $member]} { continue }
        dict set seen $member 1
        if {$member eq ""} { set known -1; continue }
        if {$member in {int decimal text bool}} { continue }
        set parts [::appcompiler::typeParts $member]
        if {[lindex $parts 0] eq "range"} { return 0 }
        if {[lindex $parts 0] in {optional list map}} {
            lappend pending {*}[lrange $parts 1 end]
            continue
        }
        if {![dict exists $world schemas $member]} { return 0 }
        set schema [dict get $world schemas $member]
        if {[dict get $schema kind] eq "distinct"} {
            lappend pending [dict get $schema members]
        } elseif {[dict get $schema kind] eq "choice"} {
            foreach payload [dict values [dict get $schema members]] { lappend pending {*}$payload }
        } else {
            lappend pending {*}[dict values [dict get $schema members]]
        }
    }
    return $known
}

proc ::appcompiler::checker::binaryType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set op [dict get $node op]
    set left [expressionType [dict get $node left] $scope $imports $world reports]
    set right [expressionType [dict get $node right] $scope $imports $world reports]
    if {$op in {.. ..=}} {
        foreach side {left right} type [list $left $right] {
            if {$type ni {{} int}} {
                issue reports OPERAND_TYPE [dict get $node $side] "range endpoint must be int, got $type"
            }
        }
        if {$left eq "int" && $right eq "int"} { return range<int> }
        return ""
    }
    set numeric [expr {$left in {int decimal} && $right in {int decimal}}]
    set common [expr {$left eq "decimal" || $right eq "decimal" ? "decimal" : "int"}]
    if {$op in {== !=}} {
        if {$left eq "" || $right eq ""} { return "" }
        set type [expr {$numeric ? $common : [joinTypes $left $right]}]
        if {$type eq ""} {
            issue reports OPERAND_TYPE $node "'$op' needs operands of the same type, got $left and $right"
            return ""
        }
        set comparison [comparable $type $world]
        if {$comparison < 0} { return "" }
        if {!$comparison} {
            issue reports NOT_COMPARABLE $node "value equality is not defined for $type"
            return ""
        }
        fact reports $node operandType $type
        return bool
    }
    if {$op ni {+ - * /}} {
        issue reports UNKNOWN_OPERATOR $node "unknown binary operator '$op'"
        return ""
    }
    if {!$numeric} {
        foreach side {left right} type [list $left $right] {
            if {$type ni {{} int decimal}} {
                issue reports OPERAND_TYPE [dict get $node $side] "'$op' expects an int or decimal operand, got $type"
            }
        }
        return ""
    }
    if {$op eq "/"} { return result<decimal,problem> }
    if {$common eq "decimal"} { fact reports $node operandType decimal }
    return $common
}

proc ::appcompiler::checker::expressionType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set kind [dict get $node kind]
    switch -exact -- $kind {
        int - decimal - text - bool - unit { return $kind }
        interpolate {
            set valid 1
            foreach part [dict get $node parts] {
                if {[dict get $part kind] eq "text"} { continue }
                set value [dict get $part value]
                set type [expressionType $value $scope $imports $world reports]
                if {$type eq ""} {
                    set valid 0
                } elseif {$type ni {text int decimal bool}} {
                    issue reports INTERPOLATION_TYPE $value "interpolation needs text, int, decimal or bool, got $type"
                    set valid 0
                } else {
                    fact reports $part interpolationType $type
                }
            }
            if {$valid} { return text }
            return ""
        }
        none { return {*?} }
        some {
            set type [expressionType [dict get $node value] $scope $imports $world reports]
            if {$type eq ""} { return "" }
            return [makeType optional [list $type]]
        }
        field - update { return [recordExpression $node $scope $imports $world reports] }
        index {
            set base [dict get $node base]
            set key [dict get $node key]
            set mapType [expressionType $base $scope $imports $world reports]
            set keyType [expressionType $key $scope $imports $world reports]
            set parts [mapParts $mapType $base reports]
            if {![llength $parts] || ![mapKeyMatches $keyType [lindex $parts 1] $key reports]} { return "" }
            fact reports $node keyType [dict getdef $reports distinctBases $keyType $keyType]
            return [makeType optional [list [lindex $parts 2]]]
        }
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
        builtin { return [builtinType $node $scope $imports $world reports] }
        construct {
            return [constructType $node [dict get $node type] [dict get $node variant] \
                [dict getdef $node ambiguous 0] $scope $imports $world reports]
        }
        binary { return [binaryType $node $scope $imports $world reports] }
        unary {
            set operand [dict get $node value]
            set type [expressionType $operand $scope $imports $world reports]
            if {$type eq ""} { return "" }
            if {$type ni {int decimal}} {
                issue reports OPERAND_TYPE $operand "unary '-' expects an int or decimal operand, got $type"
                return ""
            }
            fact reports $node operandType $type
            return $type
        }
        propagate {
            set raw [expressionType [dict get $node value] $scope $imports $world reports]
            if {$raw eq ""} { return "" }
            set parts [::appcompiler::typeParts $raw]
            set result [dict get $world returnType]
            set target [::appcompiler::typeParts $result]
            if {[lindex $parts 0] ne "result"} {
                issue reports EXPECTED_RESULT $node "postfix '?' needs a result, got $raw"
                return ""
            }
            if {$result eq ""} { return "" }
            if {[lindex $target 0] ne "result" || ![compatible [lindex $parts 2] [lindex $target 2]]} {
                issue reports PROPAGATION_TYPE $node "cannot propagate $raw from a function returning $result"
                return ""
            }
            return [lindex $parts 1]
        }
        default {
            issue reports UNKNOWN_EXPRESSION $node "unknown expression kind '$kind'"
            return ""
        }
    }
}

proc ::appcompiler::checker::checkCondition {statement scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set condition [dict get $statement condition]
    set actual [expressionType $condition $scope $imports $world reports]
    if {$actual ne "" && $actual ne "bool"} {
        issue reports CONDITION_TYPE $condition "[dict get $statement kind] requires bool, got $actual"
    }
}

proc ::appcompiler::checker::iteratedElement {statement scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set iterable [dict get $statement iterable]
    set type [expressionType $iterable $scope $imports $world reports]
    set parts [::appcompiler::typeParts $type]
    if {[lindex $parts 0] in {list map} || $type eq "range<int>"} {
        fact reports $statement iterableType $type
        return [lindex $parts 1]
    }
    if {$type ne ""} {
        issue reports ITERABLE_TYPE $iterable "for requires a list, a map or an integer range, got $type"
    }
    return ""
}

proc ::appcompiler::checker::checkBlock {statements scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set result [dict get $world returnType]
    set returns 0
    foreach statement $statements {
        set kind [dict get $statement kind]
        switch -exact -- $kind {
            bind {
                set value [dict get $statement value]
                set type [expressionType $value $scope $imports $world reports]
                set mutable [dict get $statement mutable]
                if {[string first * $type] >= 0} {
                    set head [lindex [::appcompiler::typeParts $type] 0]
                    if {$head eq "optional"} {
                        issue reports OPTIONAL_TYPE_REQUIRED $value "cannot infer an optional payload type from this expression"
                        set type ""
                    } elseif {$mutable} {
                        issue reports INCOMPLETE_TYPE $value "a changeable binding needs a concrete type"
                        set type ""
                    }
                }
                bindLocal scope $statement $type $mutable reports
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
                if {$mutable eq ""} { continue }
                if {!$mutable} {
                    issue reports FIXED_ASSIGNMENT $statement "cannot reassign fixed binding '$name'"
                } elseif {$actual ne "" && $expected ne "" && ![compatible $actual $expected]} {
                    issue reports ASSIGNMENT_TYPE $value "binding '$name' expects $expected, got $actual"
                }
            }
            return {
                set returns 1
                set value [dict get $statement value]
                set actual [expressionType $value $scope $imports $world reports]
                if {$actual ne "" && $result ne "" && ![compatible $actual $result]} {
                    issue reports RETURN_TYPE $value "expected return type $result, got $actual"
                }
            }
            if {
                checkCondition $statement $scope $imports $world reports
                set thenReturns [checkBlock [dict get $statement body] $scope $imports $world reports]
                set elseReturns [checkBlock [dict get $statement otherwise] $scope $imports $world reports]
                if {$thenReturns && $elseReturns} { set returns 1 }
            }
            for - while {
                set innerScope $scope
                if {$kind eq "while"} {
                    checkCondition $statement $scope $imports $world reports
                } else {
                    set element [iteratedElement $statement $scope $imports $world reports]
                    bindLocal innerScope [dict get $statement binding] $element 0 reports
                }
                set label [dict get $statement label]
                if {$label ne "" && $label in [dict getdef $world loops {}]} {
                    issue reports DUPLICATE_LOOP_LABEL [dict get $statement labelLocation] "loop label '.$label' is already active"
                }
                set nested $world
                dict lappend nested loops $label
                checkBlock [dict get $statement body] $innerScope $imports $nested reports
            }
            break - continue {
                set loops [dict getdef $world loops {}]
                set label [dict get $statement label]
                if {$label ne "" && $label ni $loops} {
                    issue reports UNKNOWN_LOOP_LABEL [dict get $statement labelLocation] "unknown loop label '.$label'"
                } elseif {$label eq "" && ![llength $loops]} {
                    issue reports LOOP_CONTROL $statement "'$kind' requires an enclosing loop"
                }
            }
            expr {
                set value [dict get $statement value]
                set actual [expressionType $value $scope $imports $world reports]
                if {[lindex [::appcompiler::typeParts $actual] 0] eq "result"} {
                    issue reports DISCARDED_RESULT $value "handle, propagate or return the result of this expression"
                }
            }
            default { issue reports UNKNOWN_STATEMENT $statement "unknown statement kind '$kind'" }
        }
    }
    return $returns
}

proc ::appcompiler::checker::checkFunction {function imports world reportsVar} {
    upvar 1 $reportsVar reports
    set scope {}
    foreach param [dict get $function params] {
        bindLocal scope $param [dict get $param type] 0 reports
    }
    if {[dict getdef $function kind fn] eq "extern"} { return }
    dict set world returnType [dict get $function result]
    if {![checkBlock [dict get $function body] $scope $imports $world reports]} {
        set name [dict get $function name]
        issue reports MISSING_RETURN $function "function '.$name' must return a value on every reachable path"
    }
}

proc ::appcompiler::checkDiagnostics {modules {unavailable {}} {factsVar {}} {resolvedVar {}}} {
    set reports [dict create diagnostics {} facts {} typeNames {} distinctBases {}]
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
    checker::resolveTypeNames $world reports
    set runtimeSchemas {}
    dict for {key schema} [dict get $world schemas] {
        if {$schema ne "" && [dict get $schema kind] ne "alias"} {
            if {[dict get $schema kind] eq "distinct"} {
                set members [dict getdef $reports distinctBases $key {}]
            } else {
                set members [checker::readMembers $schema $world reports]
            }
            dict set world schemas $key members $members
            dict set runtimeSchemas $key [list [dict get $schema kind] $members]
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
    if {$factsVar ne ""} {
        upvar 1 $factsVar facts
        set facts [dict get $reports facts]
    }
    if {$resolvedVar ne ""} {
        upvar 1 $resolvedVar resolved
        set resolved [dict create schemas $runtimeSchemas functions [dict get $world functions]]
    }
    return [dict get $reports diagnostics]
}

proc ::appcompiler::checkModules {modules} {
    set reports [checkDiagnostics $modules]
    if {[llength $reports]} {
        set first [lindex $reports 0]
        fail [dict get $first code] [dict get $first node] [dict get $first message]
    }
    return
}
