namespace eval ::appcompiler {}

# Parse each module in its own cursor so recursive and concurrent callers do
# not share source locations. The compiler consumes syntax trees, never source
# text evaluated as Tcl.
oo::class create ::appcompiler::ModuleParser {
    variable module source offset line column token keywords localChoices

    constructor {moduleName sourceText} {
        set module $moduleName
        set source $sourceText
        set offset 0
        set line 1
        set column 1
        set keywords {fn export import return true false record choice alias distinct match with some none if else unit for in break continue while}
        set localChoices {}
        my advance
    }

    method advance {} {
        # The final alternative consumes every remaining character. A search
        # beginning at offset therefore always matches at that exact offset.
        set pattern {[ \t]+|\r\n|[\r\n]|#[^\r\n]*|'[^']*'|[.$]?[A-Za-z_][A-Za-z_0-9]*|[0-9]+(?:\.[0-9]+)?|\.\.=?|::=|:=|::|->|=>|==|!=|.}
        while {$offset < [string length $source]} {
            regexp -start $offset -indices -- $pattern $source bounds
            lassign $bounds first last
            set word [string range $source $first $last]
            set location [dict create module $module line $line column $column]
            set offset [expr {$last + 1}]
            set breaks [regexp -all -inline -indices {\r\n|[\r\n]} $word]
            if {[llength $breaks]} {
                incr line [llength $breaks]
                set column [expr {[string length $word] - [lindex $breaks end 1]}]
            } else {
                incr column [string length $word]
            }
            dict set location endLine $line
            dict set location endColumn $column

            set initial [string index $word 0]
            switch -exact -- $initial {
                " " - "\t" - "#" { continue }
                "\r" - "\n" { set kind newline }
                "'" {
                    if {[string length $word] == 1} {
                        ::appcompiler::fail E_PARSE_STRING $location {unterminated raw text literal}
                    }
                    set kind text
                    set word [string range $word 1 end-1]
                }
                {$} - {.} {
                    if {$word in {.. ..=}} {
                        set kind $word
                    } elseif {[string length $word] == 1} {
                        ::appcompiler::fail E_PARSE_NAME $location "expected an identifier after '$word'"
                    } else {
                        set kind [expr {$initial eq "." ? "dotName" : "dataName"}]
                        set word [string range $word 1 end]
                    }
                }
                default {
                    if {[string match {[0-9]} $initial]} {
                        set kind [expr {[string first . $word] < 0 ? "integer" : "decimal"}]
                    } elseif {[regexp {^[a-zA-Z_]} $word]} {
                        set kind [expr {$word in $keywords ? $word : "identifier"}]
                    } elseif {$word in {+ - * / ( ) \{ \} [ ] < > : , = ::= := :: -> => ? == !=}} {
                        set kind $word
                    } else {
                        ::appcompiler::fail E_PARSE_TOKEN $location "unexpected character '$word'"
                    }
                }
            }
            set token [dict merge $location [dict create kind $kind value $word]]
            return
        }
        set token [dict create kind eof value {} module $module line $line column $column endLine $line endColumn $column]
    }

    method at {kind} { expr {[dict get $token kind] eq $kind} }

    method take {kind description} {
        # In a name position the grammar supplies its context. For example,
        # .other::return() can call an exported function declared as .return.
        set wordAsName [expr {$kind eq "identifier" && [dict get $token kind] in $keywords}]
        if {![my at $kind] && !$wordAsName} {
            ::appcompiler::fail E_PARSE_EXPECTED $token "expected $description"
        }
        set previous $token
        my advance
        return $previous
    }

    method skipLines {} {
        while {[my at newline]} { my advance }
    }

    method cursor {} { list $offset $line $column $token }

    method restore {cursor} { lassign $cursor offset line column token }

    method collectChoiceNames {} {
        # .name::member(...) can denote an imported function or a locally
        # declared choice. Collect declaration heads before parsing any uses.
        # The lexer skips comments and keeps entire raw strings in one token.
        set beginning [my cursor]
        set depth 0
        set declarationStart 1
        while {![my at eof]} {
            if {$declarationStart && [my at choice]} {
                set choice [my typeDeclaration 0]
                set members {}
                foreach variant [dict get $choice variants] { dict set members [dict get $variant name] 1 }
                dict set localChoices [dict get $choice name] $members
                set declarationStart 0
            } elseif {$declarationStart && ([my at alias] || [my at distinct])} {
                my advance
                set name [my take dotName {a dot-prefixed type name}]
                # Aliased variants are resolved during type checking. Keeping
                # the name here lets a payload-free variant omit parentheses.
                dict set localChoices [dict get $name value] {}
                set declarationStart 0
            } else {
                if {[my at \{]} { incr depth }
                if {[my at \}]} { incr depth -1 }
                if {!($declarationStart && [my at export])} {
                    set declarationStart [expr {$depth == 0 && [my at newline]}]
                }
                my advance
            }
        }
        my restore $beginning
    }

    method parse {} {
        set imports {}
        set importLocations {}
        set functions {}
        set types {}
        if {[string first :: $source] >= 0 && ([string first choice $source] >= 0 ||
                [string first alias $source] >= 0 || [string first distinct $source] >= 0)} {
            my collectChoiceNames
        }
        my skipLines
        while {![my at eof]} {
            if {[my at import]} {
                my advance
                set imported [my take identifier {an imported module name}]
                set name [dict get $imported value]
                lappend imports $name
                dict set importLocations $name [my node $imported import name $name]
            } else {
                set exported [my at export]
                if {$exported} { my advance }
                switch -exact -- [dict get $token kind] {
                    fn {
                        my advance
                        lappend functions [my function $exported]
                    }
                    record - choice - alias - distinct {
                        lappend types [my typeDeclaration $exported]
                    }
                    default {
                        ::appcompiler::fail E_PARSE_EXPECTED $token {expected a function, record, choice, alias, distinct or import declaration}
                    }
                }
            }
            if {![my at eof]} { my take newline {a line break between declarations} }
            my skipLines
        }
        return [dict create imports $imports importLocations $importLocations types $types functions $functions]
    }

    # All delimited lists return their elements in source order. Each item
    # parser consumes exactly one complete production, including nested lists.
    method parenthesized {item} {
        my take ( {an opening parenthesis}
        set entries {}
        my skipLines
        if {![my at )]} {
            while {1} {
                lappend entries [my $item]
                my skipLines
                if {![my at ,]} break
                my advance
                my skipLines
            }
        }
        my take ) {a closing parenthesis}
        return $entries
    }

    method braced {item description {allowComma 0}} {
        my take \{ "an opening brace before the $description"
        set entries {}
        my skipLines
        while {![my at \}]} {
            if {[my at eof]} { ::appcompiler::fail E_PARSE_EXPECTED $token "expected the closing brace for the $description" }
            lappend entries [my $item]
            if {$allowComma && [my at ,]} {
                my advance
            } elseif {![my at \}]} {
                my take newline "a line break or the closing brace for the $description"
            }
            my skipLines
        }
        my advance
        return $entries
    }

    method function {exported} {
        set name [my take dotName {a dot-prefixed function name}]
        set params [my parenthesized parameter]
        my take -> {'->' before the result type}
        set result [my typeAnnotation]
        my skipLines
        set body [my braced statement {function body}]
        return [my node $name fn name [dict get $name value] exported $exported params $params \
                result [dict get $result name] resultLocation $result body $body]
    }

    method typeAnnotation {} {
        set start $token
        set end $start
        if {[my at dotName]} {
            set name ".[dict get $token value]"
            my advance
            if {[my at ::]} {
                my advance
                set end [my take identifier {a type name in the imported module}]
                append name :: [dict get $end value]
            }
        } else {
            set name [dict get [my take identifier {a type name}] value]
        }
        if {[my at <]} {
            set args [my typeArguments]
            append name < [join [dict get $args types] ,] >
            set end [dict get $args end]
            set type [my typeLocation $start $end $name]
            dict set type typeLocations [dict get $args locations]
        } else {
            set type [my typeLocation $start $end $name]
        }
        while {[my at ?]} {
            append name ?
            set optional [my typeLocation $start $token $name]
            dict set optional typeLocations [list $type]
            set type $optional
            my advance
        }
        return $type
    }

    method typeArguments {} {
        my take < {an opening angle bracket}
        set locations {}
        my skipLines
        while {1} {
            lappend locations [my typeAnnotation]
            my skipLines
            if {![my at ,]} break
            my advance
            my skipLines
        }
        set end [my take > {a closing angle bracket after the type arguments}]
        return [dict create types [lmap location $locations {dict get $location name}] locations $locations end $end]
    }

    method typedName {name kind} {
        my take : "':' before the $kind type"
        set type [my typeAnnotation]
        return [my node $name $kind name [dict get $name value] type [dict get $type name] typeLocation $type]
    }

    method parameter {} {
        return [my typedName [my take dataName {a parameter name beginning with '$'}] param]
    }

    method fieldDeclaration {} {
        return [my typedName [my take identifier {a record field name}] field]
    }

    method variantDeclaration {} {
        set name [my take identifier {a choice variant name}]
        set locations {}
        if {[my at (]} { set locations [my parenthesized typeAnnotation] }
        set types [lmap location $locations {dict get $location name}]
        return [my node $name variant name [dict get $name value] payload $types payloadLocations $locations]
    }

    method typeDeclaration {exported} {
        set kind [dict get $token kind]
        my advance
        set name [my take dotName "a dot-prefixed $kind name"]
        my skipLines
        if {$kind in {alias distinct}} {
            my take = "'=' before the $kind target"
            my skipLines
            set target [my typeAnnotation]
            set members [dict create target [dict get $target name] targetLocation $target]
        } elseif {$kind eq "record"} {
            set members [dict create fields [my braced fieldDeclaration {record fields}]]
        } else {
            set members [dict create variants [my braced variantDeclaration {choice variants}]]
        }
        return [my node $name $kind name [dict get $name value] exported $exported {*}$members]
    }

    method node {where kind args} {
        return [dict merge [dict remove $where value] [dict create kind $kind {*}$args]]
    }

    method typeLocation {start end name} {
        return [my node $start type name $name endLine [dict get $end endLine] endColumn [dict get $end endColumn]]
    }

    method statement {} {
        set start $token
        if {[my at return]} {
            my advance
            return [my node $start return value [my expression]]
        }
        set kind [dict get $start kind]
        if {$kind in {for while break continue}} {
            my advance
            set node [my node $start $kind label {}]
            if {[my at dotName]} {
                set beginning [my cursor]
                set candidate $token
                my advance
                # A while condition can itself start with a dotted function.
                if {$kind eq "while" && ![my at :]} {
                    my restore $beginning
                } else {
                    dict set node label [dict get $candidate value]
                    dict set node labelLocation [my node $candidate label]
                    if {$kind in {for while} && [my at :]} { my advance }
                }
            }
            if {$kind eq "for"} {
                set binding [my take dataName {a loop binding beginning with '$'}]
                set name [dict get $binding value]
                dict set node name $name
                dict set node binding [my node $binding binding name $name]
                my take in {'in' before the iterable}
                dict set node iterable [my expression]
            } elseif {$kind eq "while"} {
                dict set node condition [my expression]
            }
            if {$kind in {for while}} {
                my skipLines
                dict set node body [my braced statement {loop body}]
            }
            return $node
        }
        if {[my at if]} {
            my advance
            set condition [my expression]
            my skipLines
            set body [my braced statement {if body}]
            set afterBody [my cursor]
            my skipLines
            set otherwise {}
            if {[my at else]} {
                my advance
                my skipLines
                set otherwise [my braced statement {else body}]
            } else {
                # The enclosing statement list still needs this line break.
                my restore $afterBody
            }
            return [my node $start if condition $condition body $body otherwise $otherwise]
        }
        if {[my at dataName]} {
            set beginning [my cursor]
            my advance
            set op [dict get $token kind]
            if {$op in {:= ::= =}} {
                my advance
                set name [dict get $start value]
                set value [my expression]
                if {$op eq "="} { return [my node $start assign name $name value $value] }
                return [my node $start bind name $name mutable [expr {$op eq ":="}] value $value]
            }
            my restore $beginning
        }
        return [my node $start expr value [my expression]]
    }

    method expression {{minimum 0}} {
        set left [my primary]
        while {[my at dotName] || [my at with] || [my at ?] || [my at {[}]} {
            set where $token
            if {[my at dotName]} {
                my advance
                set left [my node $where field base $left name [dict get $where value]]
            } elseif {[my at ?]} {
                my advance
                set left [my node $where propagate value $left]
            } elseif {[my at {[}]} {
                my advance
                my skipLines
                set key [my expression]
                my skipLines
                my take {]} {a closing bracket after the map key}
                set left [my node $where index base $left key $key]
            } else {
                my advance
                my skipLines
                set fields [my braced fieldAssignment {record update} 1]
                set left [my node $where update base $left fields $fields]
            }
        }
        set precedences {== 1 != 1 .. 2 ..= 2 + 3 - 3 * 4 / 4}
        while {[dict exists $precedences [dict get $token kind]]} {
            set op [dict get $token kind]
            set precedence [dict get $precedences $op]
            if {$precedence < $minimum} break
            set where $token
            my advance
            my skipLines
            set right [my expression [expr {$precedence + 1}]]
            set left [my node $where binary op $op left $left right $right]
        }
        return $left
    }

    method primary {} {
        set start $token
        switch -exact -- [dict get $token kind] {
            - {
                my advance
                return [my node $start unary op - value [my expression 5]]
            }
            decimal {
                my advance
                return [my node $start decimal value [dict get $start value]]
            }
            integer {
                my advance
                set digits [dict get $start value]
                # Always decimal, even for a value such as 008. No native-word
                # conversion is needed to represent a literal of any length.
                set digits [string trimleft $digits 0]
                if {$digits eq {}} { set digits 0 }
                return [my node $start int value $digits]
            }
            true - false {
                my advance
                return [my node $start bool value [expr {[dict get $start kind] eq "true"}]]
            }
            text {
                my advance
                return [my node $start text value [dict get $start value]]
            }
            dataName {
                my advance
                return [my node $start var name [dict get $start value]]
            }
            ( {
                my advance
                my skipLines
                set value [my expression]
                my skipLines
                my take ) {')' after the expression}
                return $value
            }
            none {
                my advance
                return [my node $start none]
            }
            unit {
                my advance
                return [my node $start unit]
            }
            some {
                my advance
                my take ( {'(' after some}
                my skipLines
                set value [my expression]
                my skipLines
                my take ) {')' after the optional value}
                return [my node $start some value $value]
            }
            match {
                my advance
                set value [my expression]
                my skipLines
                return [my node $start match value $value arms [my braced matchArm {match arms}]]
            }
            dotName { return [my call] }
            identifier {
                my advance
                set types {}
                set locations {}
                if {[my at <]} {
                    set args [my typeArguments]
                    set types [dict get $args types]
                    set locations [dict get $args locations]
                }
                set args [my parenthesized expression]
                return [my node $start builtin name [dict get $start value] typeArgs $types typeLocations $locations args $args]
            }
            default { ::appcompiler::fail E_PARSE_EXPECTED $token {expected a value expression} }
        }
    }

    method fieldAssignment {} {
        set name [my take identifier {a field name in the record update}]
        my take = {'=' after the field name}
        my skipLines
        return [my node $name setfield name [dict get $name value] value [my expression]]
    }

    method patternBinding {} {
        set binding [my take dataName {a pattern binding beginning with '$'}]
        return [my node $binding pattern name [dict get $binding value]]
    }

    method matchArm {} {
        set start $token
        if {[my at {[}]} {
            my advance
            my skipLines
            set elements {}
            if {![my at {]}]} {
                while {1} {
                    if {[my at text]} {
                        set literal $token
                        my advance
                        lappend elements [my node $literal patternText value [dict get $literal value]]
                    } else {
                        lappend elements [my patternBinding]
                    }
                    my skipLines
                    if {![my at ,]} break
                    my advance
                    my skipLines
                }
            }
            my take {]} {a closing bracket after the list pattern}
            return [my node $start listarm elements $elements body [my armBody]]
        }
        if {[my at identifier] && [dict get $token value] eq "_"} {
            my advance
            return [my node $start fallback body [my armBody]]
        }
        # A local pattern has two components (.type::case); an imported
        # pattern has three (.module::type::case).
        set start [my take dotName {a dot-prefixed choice type in the match pattern}]
        set type ".[dict get $start value]"
        set typeEnd $start
        my take :: {'::' before the choice variant}
        set variant [my take identifier {a choice variant name}]
        if {[my at ::]} {
            append type :: [dict get $variant value]
            set typeEnd $variant
            my advance
            set variant [my take identifier {a choice variant name}]
        }
        set bindings {}
        if {[my at (]} { set bindings [my parenthesized patternBinding] }
        set body [my armBody]
        set name [dict get $variant value]
        return [my node $start arm type $type typeLocation [my typeLocation $start $typeEnd $type] \
                variant $name variantLocation [my node $variant variant name $name] bindings $bindings body $body]
    }

    method armBody {} {
        my take => {'=>' after the match pattern}
        my skipLines
        return [my expression]
    }

    method call {} {
        set start $token
        set name [dict get $token value]
        set qualifier {}
        set locations {}
        my advance
        if {[my at ::]} {
            set qualifier $name
            my advance
            set member [my take identifier {a qualified member name}]
            set name [dict get $member value]
            set type ".$qualifier"
            set typeEnd $start
            set ambiguous 0
            if {[my at ::]} {
                append type :: $name
                set typeEnd $member
                my advance
                set member [my take identifier {a choice variant name}]
                set name [dict get $member value]
            } elseif {[dict exists $localChoices $qualifier $name] ||
                    (![my at (] && [dict exists $localChoices $qualifier])} {
                set ambiguous [my at (]
            } else {
                if {[dict exists $localChoices $qualifier]} {
                    set locations [dict create typeLocation [my typeLocation $start $typeEnd $type] \
                        variantLocation [my node $member variant name $name]]
                }
                set type {}
            }
            if {$type ne {}} {
                set args {}
                if {[my at (]} { set args [my parenthesized expression] }
                return [my node $start construct type $type typeLocation [my typeLocation $start $typeEnd $type] \
                        variant $name variantLocation [my node $member variant name $name] ambiguous $ambiguous args $args]
            }
        }
        set args [my parenthesized expression]
        return [my node $start call name $name qualifier $qualifier args $args {*}$locations]
    }
}

proc ::appcompiler::parseModule {module source} {
    set parser [::appcompiler::ModuleParser new $module $source]
    try { return [$parser parse] } finally { $parser destroy }
}
