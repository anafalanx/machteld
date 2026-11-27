namespace eval ::appcompiler::checker {}

proc ::appcompiler::checker::issue {reportsVar code node message} {
    upvar 1 $reportsVar reports
    # Parameter identities carry their scope internally. Diagnostics use
    # the spelling an author can find in the declaration at this location.
    regsub -all {@[A-Za-z_][A-Za-z_0-9]*:(?:fn|extern|record|choice):[A-Za-z_][A-Za-z_0-9]*:([A-Za-z_][A-Za-z_0-9]*)} \
        $message {.\1} message
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

proc ::appcompiler::checker::withTypeParams {world node reportsVar} {
    upvar 1 $reportsVar reports
    set bindings {}
    set prefix @[dict get $node module]:[dict getdef $node kind fn]:[dict get $node name]:
    foreach param [dict getdef $node typeParams {}] location [dict getdef $node typeParamLocations {}] {
        if {[dict exists $bindings .$param]} {
            if {$location eq ""} { set location $node }
            issue reports DUPLICATE_TYPE_PARAMETER $location "type parameter '.$param' is already declared"
        } else {
            dict set bindings .$param $prefix$param
        }
    }
    dict set world typeBindings $bindings
    return $world
}

proc ::appcompiler::checker::schemaKind {type world} {
    set head [lindex [::appcompiler::typeParts $type] 0]
    return [dict getdef $world schemas $head kind {}]
}

proc ::appcompiler::checker::schemaMembers {type world} {
    return [lindex [::appcompiler::specializeSchema $type [dict get $world runtimeSchemas]] 1]
}

proc ::appcompiler::checker::typeFits {length node reportsVar} {
    upvar 1 $reportsVar reports
    set limit 8192
    if {$length <= $limit} { return 1 }
    issue reports TYPE_EXPANSION_LIMIT $node "expanded type exceeds $limit characters"
    return 0
}

# Check the size before joining; several arguments can reuse a long alias.
proc ::appcompiler::checker::checkedType {head argsList node reportsVar} {
    upvar 1 $reportsVar reports
    set length [expr {$head eq "optional" ? 1 : [string length $head] + [llength $argsList] + 1}]
    foreach argument $argsList { incr length [string length $argument] }
    if {![typeFits $length $node reports]} { return "" }
    return [makeType $head $argsList]
}

# Nominal types include the defining module. A '*' is an internal inference
# variable for an absent payload. An empty type marks a prior diagnostic.
proc ::appcompiler::checker::declaredType {type node world reportsVar {allowTemplate 0}} {
    upvar 1 $reportsVar reports
    set parts [::appcompiler::typeParts $type]
    set head [lindex $parts 0]
    if {[dict exists $world typeBindings $head]} {
        if {[llength $parts] != 1} {
            issue reports TYPE_ARITY $node "type parameter '$head' takes no arguments"
            return ""
        }
        return [dict get $world typeBindings $head]
    }
    if {$head in {result list optional range map callable}} {
        if {$head eq "callable"} {
            set arity [expr {[llength $parts] - 1}]
            if {$arity == 0} {
                issue reports TYPE_ARITY $node {callable requires a result type after its parameter types}
                return ""
            }
        } else {
            set arity [expr {$head in {result map} ? 2 : 1}]
        }
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
        return [checkedType $head $args $node reports]
    }
    if {$type in {instant local_datetime}} {
        dict set reports usesTemporal 1
        return $type
    }
    if {$type in {int decimal text bool bytes problem unit process_output}} { return $type }
    if {![regexp {^\.(?:([a-zA-Z_][a-zA-Z_0-9]*)::)?([a-zA-Z_][a-zA-Z_0-9]*)$} $head -> target name]} {
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
    set arity [llength [dict getdef $schema typeParams {}]]
    if {$allowTemplate && $arity && [llength $parts] == 1} { return $key }
    if {[llength $parts] != $arity + 1} {
        issue reports TYPE_ARITY $node "type '$head' requires $arity type arguments"
        return ""
    }
    if {[dict get $schema kind] in {alias distinct}} {
        if {[dict exists $reports typeReferences]} {
            dict set reports typeReferences $key $node
            return ""
        }
        return [dict getdef $reports typeNames $key {}]
    }
    if {$arity} {
        set args {}
        set index 0
        foreach arg [lrange $parts 1 end] {
            set where [lindex [dict getdef $node typeLocations {}] $index]
            if {$where eq ""} { set where $node }
            lappend args [declaredType $arg $where $world reports]
            incr index
        }
        if {"" in $args} { return "" }
        return [checkedType $key $args $node reports]
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
                    if {$type ni {text int decimal bool bytes instant local_datetime}} {
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
    set world [withTypeParams $world $function reports]
    dict set function typeBindings [dict get $world typeBindings]
    dict set function typeVariables [dict values [dict get $world typeBindings]]
    if {[dict get $function exported] && [llength [dict get $function typeVariables]]} {
        # A Tcl caller can select instant at this boundary even when no X
        # declaration in the program spells a concrete temporal type.
        dict set reports usesTemporal 1
    }
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

# Register one closer for every instantiation of a locally declared nominal
# type. Its type variables may use different names or declaration order.
proc ::appcompiler::checker::resourceProtocols {world reportsVar} {
    upvar 1 $reportsVar reports
    set protocols {}
    dict for {module definition} [dict get $world modules] {
        foreach node [dict getdef $definition resources {}] {
            set type [format {.%s::%s} $module [dict get $node name]]
            set where [dict get $node typeLocation]
            if {[dict exists $protocols $type]} {
                issue reports RESOURCE_DUPLICATE $where "a cleanup function is already declared for $type"
                dict set protocols $type {}
                continue
            }
            dict set protocols $type {}
            if {[dict getdef $world schemas $type kind {}] ni {record choice distinct}} {
                issue reports RESOURCE_TYPE $where "a resource must name a record, choice or distinct type declared in this module"
                continue
            }
            set name [dict get $node closer]
            set where [dict get $node closerLocation]
            set function [dict getdef $world functions $module $name {}]
            if {$function eq ""} {
                issue reports RESOURCE_CLOSER $where "cleanup function '.$name' must be declared in module '$module'"
                continue
            }
            set params [dict get $function params]
            set variables [dict get $function typeVariables]
            set formal [lindex $params 0]
            set parts [::appcompiler::typeParts [dict getdef $formal type {}]]
            set arguments [lrange $parts 1 end]
            set result [dict get $function result]
            if {[llength $params] != 1 || [lindex $parts 0] ne $type ||
                    [lsort -ascii $arguments] ne [lsort -ascii $variables] ||
                    $result ni {unit result<unit,problem>}} {
                issue reports RESOURCE_CLOSER $where "'.$name' must accept one $type for every specialization and return unit or result<unit,problem>"
                continue
            }
            set order [lmap variable $variables {lsearch -exact $arguments $variable}]
            dict set protocols $type [dict create closer [list $module $name] order $order fallible [expr {$result ne "unit"}]]
        }
    }
    return $protocols
}

proc ::appcompiler::checker::scopeCleanup {node type world reportsVar} {
    upvar 1 $reportsVar reports
    if {$type in {{} @transaction}} {return}
    set parts [::appcompiler::typeParts $type]
    set head [lindex $parts 0]
    if {![dict exists $world resources $head]} {
        issue reports RESOURCE_REQUIRED [dict get $node value] "no scoped cleanup function is declared for $type"
        return
    }
    set protocol [dict get $world resources $head]
    if {$protocol eq ""} {return}
    set fallible [dict get $protocol fallible]
    set result [::appcompiler::typeParts [dict get $world returnType]]
    if {$fallible && ([lindex $result 0] ne "result" || [lindex $result 2] ne "problem")} {
        issue reports RESOURCE_PROPAGATION $node "fallible cleanup requires an enclosing function returning result<T,problem>"
        return
    }
    set arguments [lrange $parts 1 end]
    fact reports $node resourceCloser [dict get $protocol closer]
    fact reports $node resourceTypeArguments [lmap index [dict get $protocol order] {lindex $arguments $index}]
    fact reports $node resourceFallible $fallible
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

proc ::appcompiler::checker::argumentTypes {node scope imports world reportsVar {sqlTarget 0}} {
    upvar 1 $reportsVar reports
    set types {}
    foreach argument [dict get $node args] {
        if {$sqlTarget && [dict get $argument kind] eq "var"
                && [dict getdef $scope [dict get $argument name] type {}] eq "@transaction"} {
            lappend types @transaction
        } else {
            lappend types [expressionType $argument $scope $imports $world reports]
        }
        set sqlTarget 0
    }
    return $types
}

proc ::appcompiler::checker::checkArguments {node name actual expected reportsVar {parameters {}}} {
    upvar 1 $reportsVar reports
    set count [llength $expected]
    set valid [expr {$count == [llength $actual]}]
    if {!$valid} {
        issue reports CALL_ARITY $node "'$name' expects $count arguments, got [llength $actual]"
    }
    foreach have $actual want $expected arg [dict get $node args] parameter $parameters {
        if {$arg ne {} && ($parameter ne {} || $want ne {})} {
            set label [dict getdef $arg argumentLabel {}]
            set supplied [dict getdef $label name {}]
            set required [dict getdef $parameter label {}]
            if {$supplied ne $required} {
                if {$required eq {}} {
                    issue reports ARGUMENT_LABEL $label "'$name' expects an unlabeled argument here, got '$supplied:'"
                } elseif {$label eq {}} {
                    issue reports ARGUMENT_LABEL $arg "'$name' requires the label '$required:' here"
                } else {
                    issue reports ARGUMENT_LABEL $label "'$name' expects the label '$required:' here, got '$supplied:'"
                }
                set valid 0
            }
        }
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
    set choice [declaredType $spelling $where $world reports 1]
    if {$choice eq ""} { return "" }
    if {[schemaKind $choice $world] ne "choice"} {
        issue reports EXPECTED_CHOICE $where "expected a choice type, got $choice"
        return ""
    }
    set head [lindex [::appcompiler::typeParts $choice] 0]
    set variants [dict get $world schemas $head members]
    set alternate [string range $spelling 1 end]
    set function [dict getdef $world functions $alternate $name {}]
    if {$ambiguous && $alternate in $imports && $function ne "" && [dict get $function exported]
            && [dict exists $variants $name]} {
        issue reports AMBIGUOUS_CALL $node "'[format {%s::%s} $spelling $name]' names both an imported function and a local choice variant"
        return ""
    }
    if {![dict exists $variants $name]} {
        issue reports UNKNOWN_VARIANT [dict getdef $node variantLocation $node] "unknown variant '$name' on $choice"
        return ""
    }
    set variables [dict getdef $world schemas $head typeVariables {}]
    if {$choice eq $head && [llength $variables]} {
        set args [inferTypeArguments $node $variables [dict get $variants $name] $actual reports]
        if {![llength $args]} { return "" }
        set choice [checkedType $head $args $where reports]
        if {$choice eq ""} { return "" }
    }
    set payload [dict get [schemaMembers $choice $world] $name]
    if {![checkArguments $node $name $actual $payload reports]} { return "" }
    fact reports $node constructor $choice
    return $choice
}

proc ::appcompiler::checker::builtinType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set name [dict get $node name]
    set sqlTarget [expr {$name in {sql_one sql_optional sql_many sql_exec sql_commit}}]
    set actual [argumentTypes $node $scope $imports $world reports $sqlTarget]
    set generic [dict getdef $node typeArgs {}]
    set count [dict getdef {decode_json 1 make 1 map 2 sql_one 1 sql_optional 1 sql_many 1} $name 0]
    if {[llength $generic] != $count} {
        issue reports TYPE_ARITY $node "'$name' expects $count type arguments, got [llength $generic]"
        return ""
    }
    switch -exact -- $name {
        bind {return [callableOperation $node bind $actual reports]}
        ok - err - encode_json - underlying - len { set params [list *] }
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
        problem - decode_json - write_stdout_utf8 - parse_instant - parse_local_datetime { set params [list text] }
        instant_text { set params {instant} }
        local_datetime_text { set params {local_datetime} }
        resolve_offset { set params {local_datetime int} }
        resolve_zone { set params {local_datetime text} }
        capture_process { set params {text list<text> bytes int int} }
        decode_utf8 { set params [list bytes] }
        decode_text - preview_text { set params {bytes text} }
        read_stdin_bytes - map { set params {} }
        map_put - require_key - sorted_keys { return [mapCall $node $name $actual reports] }
        sql_one - sql_optional - sql_many - sql_exec - sql_commit {
            return [sqlCall $node $name $actual $world reports]
        }
        sql_begin {
            issue reports SQL_TRANSACTION_SCOPE $node {sql_begin requires a scoped 'using' binding}
            return ""
        }
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
        if {[schemaKind $schema $world] ne "record"} {
            issue reports EXPECTED_RECORD $location "decode_json requires a record schema, got $schema"
            return ""
        }
    }
    if {!$valid} { return "" }
    switch -exact -- $name {
        len {
            set type [lindex $actual 0]
            set head [lindex [::appcompiler::typeParts $type] 0]
            if {$head ni {list map bytes text}} {
                issue reports ARGUMENT_TYPE [lindex [dict get $node args] 0] "'len' requires list, map, bytes or text, got $type"
                return ""
            }
            fact reports $node lengthKind $head
            return int
        }
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
        capture_process {
            dict set reports usesProcess 1
            return result<process_output,problem>
        }
        decode_utf8 - decode_text - preview_text { return result<text,problem> }
        decode_json {
            fact reports $node schema $schema
            return [makeType result [list $schema problem]]
        }
        encode_json {
            set schema [lindex $actual 0]
            if {[schemaKind $schema $world] ne "record"} {
                issue reports EXPECTED_RECORD [lindex [dict get $node args] 0] "encode_json requires a record, got $schema"
                return ""
            }
            fact reports $node schema $schema
            return result<text,problem>
        }
        write_stdout_utf8 { return result<unit,problem> }
        instant_text - local_datetime_text { return text }
        parse_instant - resolve_offset {
            dict set reports usesTemporal 1
            return result<instant,problem>
        }
        resolve_zone {
            dict set reports usesTemporal 1
            dict set reports usesZone 1
            return result<list<instant>,problem>
        }
        parse_local_datetime {
            dict set reports usesTemporal 1
            return result<local_datetime,problem>
        }
        quotient { return result<int,problem> }
        divide_rounded { return result<decimal,problem> }
    }
}

proc ::appcompiler::checker::sqlScalar {type distinctBases} {
    if {[string index $type end] eq "?"} { set type [string range $type 0 end-1] }
    return [expr {[dict getdef $distinctBases $type $type] in {int decimal text bytes bool instant local_datetime}}]
}

proc ::appcompiler::checker::sqlCall {node name actual world reportsVar} {
    upvar 1 $reportsVar reports
    set valid 1
    set count [llength $actual]
    if {$name eq "sql_commit"} {
        if {$count != 1} {
            issue reports CALL_ARITY $node "'$name' expects 1 argument, got $count"
            set valid 0
        }
    } elseif {$count < 2} {
        issue reports CALL_ARITY $node "'$name' expects at least 2 arguments, got $count"
        set valid 0
    }
    set bases [dict get $reports distinctBases]
    set index 0
    foreach type $actual arg [dict get $node args] {
        if {$type eq ""} {
            set valid 0
        } elseif {$index == 0} {
            if {$name in {sql_exec sql_commit} && $type ne "@transaction"} {
                issue reports SQL_TRANSACTION_REQUIRED $arg "'$name' requires a scoped transaction binding"
                set valid 0
            } elseif {$type ni {text @transaction}} {
                issue reports ARGUMENT_TYPE $arg "'$name' expects a database path or scoped transaction, got $type"
                set valid 0
            }
        } elseif {$index == 1} {
            if {$type ne "text"} {
                issue reports ARGUMENT_TYPE $arg "'$name' expects SQL text, got $type"
                set valid 0
            }
        } elseif {$type ne "*?" && ![sqlScalar $type $bases]} {
            issue reports SQL_BIND_TYPE $arg "'$name' cannot bind $type as a SQLite value"
            set valid 0
        }
        incr index
    }
    if {$name in {sql_exec sql_commit}} {
        if {!$valid} { return "" }
        fact reports $node sqlBindings [lrange $actual 2 end]
        return result<unit,problem>
    }
    set location [lindex [dict get $node typeLocations] 0]
    set row [declaredType [lindex [dict get $node typeArgs] 0] $location $world reports]
    if {$row eq ""} { return "" }
    if {[schemaKind $row $world] ne "record"} {
        issue reports EXPECTED_RECORD $location "'$name' requires a record row type, got $row"
        return ""
    }
    dict for {field type} [schemaMembers $row $world] {
        if {$type eq ""} {
            set valid 0
        } elseif {![sqlScalar $type $bases]} {
            issue reports SQL_FIELD_TYPE $location "row field '$field' has type $type, which cannot hold a SQLite cell"
            set valid 0
        }
    }
    if {!$valid} { return "" }
    dict set reports usesSql 1
    fact reports $node schema $row
    fact reports $node transaction [expr {[lindex $actual 0] eq "@transaction"}]
    fact reports $node sqlBindings [lrange $actual 2 end]
    switch -exact -- $name {
        sql_optional { set row [makeType optional [list $row]] }
        sql_many { set row [makeType list [list $row]] }
    }
    return [makeType result [list $row problem]]
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
        set isChoice [expr {[schemaKind $localChoice $world] eq "choice"}]
        set choiceHead [lindex [::appcompiler::typeParts $localChoice] 0]
        if {($isChoice && [dict exists $world schemas $choiceHead members $name])
                || (($declaredKind in {alias distinct} || $isChoice) && $target ni $imports)} {
            if {![llength [dict getdef $node typeArgs {}]]} {
                return [constructType $node .$target $name 1 $scope $imports $world reports]
            }
            # Type arguments after a qualified member belong to the
            # function. A choice applies its arguments before the "::".
            if {$target ne $caller && $target ni $imports} {
                issue reports TYPE_ARITY [lindex [dict get $node typeLocations] 0] \
                    "place choice type arguments before '::$name' in a variant constructor"
                return ""
            }
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
    return [checkCall $node .$name $actual $function $world reports]
}

# Bind the declaration's parameters structurally. A missing payload (the
# internal "*") contributes no evidence; a later argument can fill it in.
proc ::appcompiler::checker::inferFromArgument {formal actual variables bindingsVar} {
    upvar 1 $bindingsVar bindings
    if {$actual eq "*"} {return 1}
    if {$formal in $variables} {
        set known [dict getdef $bindings $formal *]
        set combined [joinTypes $known $actual]
        if {$combined eq ""} {return 0}
        dict set bindings $formal $combined
        return 1
    }
    set pattern [::appcompiler::typeParts $formal]
    set supplied [::appcompiler::typeParts $actual]
    if {[lindex $pattern 0] ne [lindex $supplied 0] || [llength $pattern] != [llength $supplied]} {return 0}
    foreach child [lrange $pattern 1 end] value [lrange $supplied 1 end] {
        if {![inferFromArgument $child $value $variables bindings]} {return 0}
    }
    return 1
}

proc ::appcompiler::checker::inferTypeArguments {node variables expected actual reportsVar} {
    upvar 1 $reportsVar reports
    if {[llength $actual] != [llength $expected]} {
        issue reports CALL_ARITY $node "expected [llength $expected] arguments, got [llength $actual]"
        return {}
    }
    set bindings {}
    foreach formal $expected value $actual arg [dict get $node args] {
        if {$formal eq "" || $value eq ""} {return {}}
        if {![inferFromArgument $formal $value $variables bindings]} {
            issue reports ARGUMENT_TYPE $arg "argument of type $value is inconsistent with the generic signature or earlier arguments"
            return {}
        }
    }
    set arguments {}
    foreach variable $variables {
        set type [dict getdef $bindings $variable *]
        if {[string first * $type] >= 0} {
            set name [lindex [split $variable :] end]
            issue reports TYPE_INFERENCE $node "cannot infer type parameter '.$name'; supply explicit type arguments"
            return {}
        }
        lappend arguments $type
    }
    return $arguments
}

proc ::appcompiler::checker::checkCall {node name actual function world reportsVar} {
    upvar 1 $reportsVar reports
    set expected [lmap param [dict get $function params] {dict get $param type}]
    set variables [dict get $function typeVariables]
    set arguments [dict getdef $node typeArgs {}]
    if {[llength $arguments]} {
        if {[llength $arguments] != [llength $variables]} {
            issue reports TYPE_ARITY $node "'$name' expects [llength $variables] type arguments, got [llength $arguments]"
            return ""
        }
        set resolved {}
        foreach type $arguments location [dict get $node typeLocations] {
            lappend resolved [declaredType $type $location $world reports]
        }
        if {"" in $resolved} {return ""}
        set arguments $resolved
    } elseif {[llength $variables]} {
        if {[dict get $node kind] eq "functionValue"} {
            issue reports TYPE_INFERENCE $node "supply explicit type arguments when taking '$name' as a callable"
            return ""
        }
        set arguments [inferTypeArguments $node $variables $expected $actual reports]
        if {![llength $arguments]} {return ""}
    }
    set result [dict get $function result]
    if {[llength $variables]} {
        set bindings {}
        foreach variable $variables argument $arguments {dict set bindings $variable $argument}
        set expected [lmap formal $expected {::appcompiler::substituteType $formal $bindings}]
        set result [::appcompiler::substituteType $result $bindings]
        foreach type [list {*}$expected $result] {
            if {![typeFits [string length $type] $node reports]} {return ""}
        }
        fact reports $node typeArguments $arguments
    }
    if {[dict get $node kind] eq "functionValue"} {
        foreach param [dict get $function params] {
            if {[dict getdef $param label {}] ne ""} {
                issue reports CALLABLE_LABEL $node "'$name' requires argument labels; declare a positional adapter that supplies them"
                return ""
            }
        }
        if {"" in $expected || $result eq ""} {return ""}
        set key [list [dict get $function module] [dict get $function name]]
        dict set reports callbackTargets $key 1
        return [checkedType callable [list {*}$expected $result] $node reports]
    }
    if {![checkArguments $node $name $actual $expected reports [dict get $function params]]} { return "" }
    return $result
}

# Both operations consume the same positional signature. Binding consumes a
# nonempty leading slice and leaves the suffix as the new callable's type.
proc ::appcompiler::checker::callableOperation {node operation actual reportsVar} {
    upvar 1 $reportsVar reports
    if {$operation eq "bind" && [llength $actual] < 2} {
        issue reports CALL_ARITY $node {bind expects a callable followed by at least one captured argument}
        return ""
    }
    set type [lindex $actual 0]
    if {$type eq ""} {return ""}
    set parts [::appcompiler::typeParts $type]
    if {[lindex $parts 0] ne "callable"} {
        set operand [expr {$operation eq "bind" ? [lindex [dict get $node args] 0] : [dict get $node value]}]
        issue reports EXPECTED_CALLABLE $operand "expected a callable, got $type"
        return ""
    }
    set expected [lrange $parts 1 end-1]
    set supplied [lrange $actual 1 end]
    if {$operation eq "bind"} {
        dict set node args [lrange [dict get $node args] 1 end]
        set count [llength $supplied]
        if {$count > [llength $expected]} {
            issue reports CALL_ARITY $node "cannot capture $count arguments of a callable with [llength $expected] parameters"
            return ""
        }
        if {![checkArguments $node bind $supplied [lrange $expected 0 $count-1] reports]} {return ""}
        return [makeType callable [lrange $parts $count+1 end]]
    }
    if {![checkArguments $node $operation $supplied $expected reports]} {return ""}
    return [lindex $parts end]
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
    if {$valid && [schemaKind $record $world] ne "record"} {
        issue reports EXPECTED_RECORD $base "expected a record, got $record"
        set valid 0
    }
    set hasRecord $valid
    if {$hasRecord} { set fields [schemaMembers $record $world] }
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

proc ::appcompiler::checker::matchVariants {type world} {
    lassign [::appcompiler::typeParts $type] head first second
    switch -- $head {
        optional {return [dict create none {} some [list $first]]}
        result {return [dict create ok [list $first] err [list $second]]}
    }
    return [schemaMembers $type $world]
}

# Check the variant and its payload independently of any shared arm body.
proc ::appcompiler::checker::choicePattern {arm choice world seenVar coverageVar reportsVar} {
    upvar 1 $seenVar seen $coverageVar coverageKnown $reportsVar reports
    set valid 1
    set location [dict getdef $arm typeLocation $arm]
    set variantLocation [dict getdef $arm variantLocation $arm]
    set kind [dict get $arm kind]
    if {$kind in {optionalArm resultArm}} {
        set pattern $choice
        set expected [expr {$kind eq "resultArm" ? "result" : "optional"}]
        if {$choice ne "" && [lindex [::appcompiler::typeParts $choice] 0] ne $expected} {
            issue reports PATTERN_TYPE $arm "pattern '[dict get $arm variant]' expects $expected, got $choice"
            set pattern ""
        }
    } else {
        set pattern [declaredType [dict get $arm type] $location $world reports 1]
        if {$pattern ne "" && $pattern eq [lindex [::appcompiler::typeParts $choice] 0]} {
            # The matched value determines an omitted argument list in a pattern.
            set pattern $choice
        } elseif {[dict getdef $world schemas $pattern typeVariables {}] ne ""} {
            issue reports TYPE_INFERENCE $location "cannot infer the type arguments for pattern '$pattern' from '$choice'"
            set pattern ""
        }
        if {$pattern ne "" && [schemaKind $pattern $world] ne "choice"} {
            issue reports EXPECTED_CHOICE $location "expected a closed choice in the pattern, got $pattern"
            set pattern ""
        }
    }
    set name [dict get $arm variant]
    set payload {}
    set knownVariant 0
    set members [expr {$pattern eq "" ? {} : [matchVariants $pattern $world]}]
    if {$pattern eq ""} {
        set valid 0
        set coverageKnown 0
    } elseif {![dict exists $members $name]} {
        issue reports UNKNOWN_VARIANT $variantLocation "unknown variant '$name' on $pattern"
        set valid 0
        set coverageKnown 0
    } else {
        set knownVariant 1
        set payload [dict get $members $name]
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
    set head [lindex $parts 0]
    if {$head eq "list"} {
        return [listMatchType $node [lindex $parts 1] $scope $imports $world reports]
    }
    set arms [dict get $node arms]
    if {$head ni {optional result} && [llength $arms] && [dict get [lindex $arms 0] kind] in {listarm fallback}
            && [schemaKind $choice $world] ne "choice"} {
        if {$choice ne ""} {
            issue reports EXPECTED_LIST $value "expected a list for these patterns, got $choice"
        }
        return [listMatchType $node "" $scope $imports $world reports]
    }
    if {$choice ne "" && $head ni {optional result} && [schemaKind $choice $world] ne "choice"} {
        issue reports EXPECTED_CHOICE $value "expected a closed choice, optional or result, got $choice"
        set choice ""
    }
    set seen {}
    set result ""
    set valid [expr {$choice ne ""}]
    set coverageKnown $valid
    foreach arm [dict get $node arms] {
        if {[dict get $arm kind] in {arm optionalArm resultArm armGroup}} {
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
        foreach name [dict keys [matchVariants $choice $world]] {
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
# Equality requires every stored component to support equality. Represent that
# condition as the set of parameters that must support it, plus a marker for an
# invalid declaration or an intrinsically noncomparable component.
proc ::appcompiler::checker::equalityRequirements {type summaries} {
    if {$type eq ""} { return !invalid }
    if {$type in {int decimal text bool instant local_datetime}} { return {} }
    set parts [::appcompiler::typeParts $type]
    set head [lindex $parts 0]
    if {[string index $head 0] eq "@"} { return [list $head] }
    set args [lrange $parts 1 end]
    if {$head in {optional list map}} {
        set required {}
        foreach arg $args { lappend required {*}[equalityRequirements $arg $summaries] }
        return [lsort -unique $required]
    }
    if {![dict exists $summaries $head]} { return !unsupported }
    lassign [dict get $summaries $head] variables conditions
    set required {}
    foreach condition $conditions {
        set index [lsearch -exact $variables $condition]
        if {$index < 0} {
            lappend required $condition
        } else {
            lappend required {*}[equalityRequirements [lindex $args $index] $summaries]
        }
    }
    return [lsort -unique $required]
}

# Solve the finite requirements of recursive declarations once, on their
# templates. Expanding .tree<list<T>> recursively from .tree<T> would produce
# infinitely many concrete type spellings even when all its fields compare.
proc ::appcompiler::checker::equalitySummaries {schemas} {
    set summaries {}
    set fields {}
    set dependents {}
    set pending {}
    dict for {name entry} $schemas {
        lassign $entry kind members variables
        dict set summaries $name [list $variables {}]
        dict set pending $name 1
        switch -- $kind {
            distinct { set types [list $members] }
            record { set types [dict values $members] }
            choice { set types [concat {*}[dict values $members]] }
        }
        dict set fields $name $types
        foreach referenced [regexp -all -inline {\.[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*} $types] {
            dict set dependents $referenced $name 1
        }
    }
    while {[dict size $pending]} {
        set batch $pending
        set pending {}
        dict for {name unused} $batch {
            set requirements {}
            foreach type [dict get $fields $name] {
                lappend requirements {*}[equalityRequirements $type $summaries]
            }
            set requirements [lsort -unique $requirements]
            lassign [dict get $summaries $name] variables previous
            if {$requirements ne $previous} {
                dict set summaries $name [list $variables $requirements]
                set pending [dict merge $pending [dict getdef $dependents $name {}]]
            }
        }
    }
    return $summaries
}

proc ::appcompiler::checker::comparable {type world} {
    set required [equalityRequirements $type [dict get $world equalitySummaries]]
    if {$required eq ""} { return 1 }
    if {$required eq "!invalid"} { return -1 }
    return 0
}

proc ::appcompiler::checker::comparisonType {left right op where world reportsVar} {
    upvar 1 $reportsVar reports
    if {$left eq "" || $right eq ""} { return "" }
    if {$left in {int decimal} && $right in {int decimal}} {
        return [expr {$left eq "decimal" || $right eq "decimal" ? "decimal" : "int"}]
    }
    if {$op in {< <= > >=}} {
        if {$left ne $right} {
            issue reports OPERAND_TYPE $where "'$op' needs operands of the same ordered type, got $left and $right"
            return ""
        }
        set base [dict getdef $reports distinctBases $left $left]
        if {$base ni {int decimal text instant local_datetime}} {
            issue reports NOT_ORDERED $where "ordering is not defined for $left"
            return ""
        }
        return $base
    }
    set type [joinTypes $left $right]
    if {$type eq ""} {
        issue reports OPERAND_TYPE $where "'$op' needs operands of the same type, got $left and $right"
        return ""
    }
    set comparison [comparable $type $world]
    if {$comparison < 0} { return "" }
    if {!$comparison} {
        issue reports NOT_COMPARABLE $where "value equality is not defined for $type"
        return ""
    }
    return $type
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
    if {$op in {&& ||}} {
        foreach side {left right} type [list $left $right] {
            if {$type ni {{} bool}} {
                issue reports OPERAND_TYPE [dict get $node $side] "'$op' expects bool, got $type"
            }
        }
        if {$left eq "bool" && $right eq "bool"} {return bool}
        return ""
    }
    if {$op in {== != < <= > >=}} {
        set type [comparisonType $left $right $op $node $world reports]
        if {$type eq ""} { return "" }
        fact reports $node operandType $type
        return bool
    }
    if {$op ni {+ - * /}} {
        issue reports UNKNOWN_OPERATOR $node "unknown binary operator '$op'"
        return ""
    }
    if {$left ni {int decimal} || $right ni {int decimal}} {
        foreach side {left right} type [list $left $right] {
            if {$type ni {{} int decimal}} {
                issue reports OPERAND_TYPE [dict get $node $side] "'$op' expects an int or decimal operand, got $type"
            }
        }
        return ""
    }
    if {$op eq "/"} { return result<decimal,problem> }
    set common [expr {$left eq "decimal" || $right eq "decimal" ? "decimal" : "int"}]
    if {$common eq "decimal"} { fact reports $node operandType decimal }
    return $common
}

proc ::appcompiler::checker::expressionType {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    try {
        return [inferExpression $node $scope $imports $world reports]
    } trap {APPCOMPILER TYPE_EXPANSION_LIMIT} message {
        issue reports TYPE_EXPANSION_LIMIT $node $message
        return ""
    }
}

proc ::appcompiler::checker::inferExpression {node scope imports world reportsVar} {
    upvar 1 $reportsVar reports
    set kind [dict get $node kind]
    switch -exact -- $kind {
        int - decimal - text - bool - unit { return $kind }
        toolPath {
            dict set reports usesProcess 1
            return result<text,problem>
        }
        list {
            set element *
            set valid 1
            foreach item [dict get $node items] {
                set type [expressionType $item $scope $imports $world reports]
                if {$type eq ""} {
                    set valid 0
                    continue
                }
                set joined [joinTypes $element $type]
                if {$joined eq ""} {
                    issue reports LIST_ELEMENT_TYPE $item "list element expects $element, got $type"
                    set valid 0
                } else {
                    set element $joined
                }
            }
            if {!$valid} {return ""}
            return [checkedType list [list $element] $node reports]
        }
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
            set type [dict get $scope $name type]
            if {$type eq "@transaction"} {
                issue reports SQL_TRANSACTION_SCOPE $node "scoped transaction '$name' can only be the first argument of a SQL operation"
                return ""
            }
            return $type
        }
        sqlBegin {
            set actual [argumentTypes $node $scope $imports $world reports]
            if {![checkArguments $node sql_begin $actual {text} reports]} { return "" }
            dict set reports usesSql 1
            return result<@transaction,problem>
        }
        call - functionValue { return [callType $node $scope $imports $world reports] }
        invoke {
            set callee [dict get $node value]
            set type [expressionType $callee $scope $imports $world reports]
            set actual [argumentTypes $node $scope $imports $world reports]
            return [callableOperation $node "\$[dict get $callee name]" [list $type {*}$actual] reports]
        }
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
            if {[dict get $node op] eq "!"} {
                if {$type eq "bool"} {return bool}
                issue reports OPERAND_TYPE $operand "'!' expects bool, got $type"
                return ""
            }
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
                    } elseif {$head eq "list"} {
                        issue reports INCOMPLETE_TYPE $value "a list binding needs a concrete element type"
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
            using {
                set type [expressionType [dict get $statement value] $scope $imports $world reports]
                scopeCleanup $statement $type $world reports
                set innerScope $scope
                bindLocal innerScope [dict get $statement binding] $type 0 reports
                if {[checkBlock [dict get $statement body] $innerScope $imports $world reports]} {
                    set returns 1
                }
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
                } elseif {$actual in [dict values [dict getdef $world typeBindings {}]]} {
                    issue reports DISCARDED_RESULT $value "the value of this expression may be a result; bind it or return it"
                }
            }
            default { issue reports UNKNOWN_STATEMENT $statement "unknown statement kind '$kind'" }
        }
    }
    return $returns
}

proc ::appcompiler::checker::checkFunction {function imports world reportsVar} {
    upvar 1 $reportsVar reports
    dict set world typeBindings [dict get $function typeBindings]
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

proc ::appcompiler::checker::checkExample {example imports world reportsVar} {
    upvar 1 $reportsVar reports
    dict set world returnType unit
    set actual [dict get $example actual]
    set owner [dict get $example owner]
    set type ""
    if {$owner eq "" || $owner ne [dict get $actual name]} {
        issue reports EXAMPLE_OWNER $actual "an example must call the function declared immediately before it"
        argumentTypes $actual {} $imports $world reports
    } else {
        set type [expressionType $actual {} $imports $world reports]
        if {$type ne ""} { fact reports $example actualType $type }
    }
    lassign [::appcompiler::typeParts $type] head success failure
    if {[dict get $example expectation] eq "value"} {
        set expected [dict get $example expected]
        set want [expressionType $expected {} $imports $world reports]
        if {$head ne "result"} { set success $type }
        set comparison [comparisonType $success $want => $expected $world reports]
        if {$comparison ne ""} { fact reports $example operandType $comparison }
        return
    }
    if {$type ne "" && ($head ne "result" || $failure ne "problem")} {
        issue reports EXAMPLE_ERROR_TYPE [dict get $example code] "an error-code expectation requires result<T,problem>, got $type"
    }
    set seen [dict create code 1]
    foreach field [dict get $example fields] {
        set name [dict get $field name]
        set value [dict get $field value]
        set want [expressionType $value {} $imports $world reports]
        if {[dict exists $seen $name]} {
            issue reports EXAMPLE_DUPLICATE_FIELD $field "problem field '$name' is already selected"
            continue
        }
        dict set seen $name 1
        if {$want eq ""} { continue }
        set defined [dict getdef {message text byteOffset int} $name {}]
        if {$defined ne "" && $want ne $defined} {
            issue reports EXAMPLE_FIELD_TYPE $value "problem field '$name' expects $defined, got $want"
            continue
        }
        set comparison [comparisonType $want $want => $value $world reports]
        if {$comparison ne ""} { fact reports $field operandType $comparison }
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
                set memberWorld [checker::withTypeParams $world $schema reports]
                set variables [dict values [dict get $memberWorld typeBindings]]
                dict set world schemas $key typeVariables $variables
                set members [checker::readMembers $schema $memberWorld reports]
            }
            dict set world schemas $key members $members
            dict set runtimeSchemas $key [list [dict get $schema kind] $members]
            if {[dict getdef $world schemas $key typeVariables {}] ne ""} {
                dict lappend runtimeSchemas $key $variables
            }
        }
    }
    set outputFields {status text exit int stdout bytes stderr bytes stdout_retained int stderr_retained int
        stdout_truncated bool stderr_truncated bool}
    dict set world schemas process_output [dict create kind record members $outputFields]
    dict set runtimeSchemas process_output [list record $outputFields]
    dict set world runtimeSchemas $runtimeSchemas
    dict set world equalitySummaries [checker::equalitySummaries $runtimeSchemas]
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
    dict set world resources [checker::resourceProtocols $world reports]
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
        foreach example [dict getdef $definition examples {}] {
            checker::checkExample $example $imports $world reports
        }
    }
    if {$factsVar ne ""} {
        upvar 1 $factsVar facts
        set facts [dict get $reports facts]
    }
    if {$resolvedVar ne ""} {
        upvar 1 $resolvedVar resolved
        set resolved [dict create schemas $runtimeSchemas functions [dict get $world functions] \
            callbackTargets [dict keys [dict getdef $reports callbackTargets {}]] \
            usesSql [dict getdef $reports usesSql 0] usesTemporal [dict getdef $reports usesTemporal 0] \
            usesZone [dict getdef $reports usesZone 0] usesProcess [dict getdef $reports usesProcess 0]]
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
