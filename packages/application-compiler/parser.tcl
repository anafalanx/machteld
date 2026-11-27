namespace eval ::appcompiler {}

# Parse each module in its own cursor so recursive and concurrent callers do
# not share source locations. The compiler consumes syntax trees, never source
# text evaluated as Tcl.
oo::class create ::appcompiler::ModuleParser {
    variable module source offset line column token keywords

    constructor {moduleName sourceText} {
        set module $moduleName
        set source $sourceText
        set offset 0
        set line 1
        set column 1
        set keywords {fn export import return true false record choice match with some none}
        my advance
    }

    method advance {} {
        # The final alternative consumes every remaining character. A search
        # beginning at offset therefore always matches at that exact offset.
        set pattern {[ \t]+|\r\n|[\r\n]|#[^\r\n]*|'[^']*'|[.$]?[A-Za-z_][A-Za-z_0-9]*|[0-9]+|::=|:=|::|->|=>|.}
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
                    if {[string length $word] == 1} {
                        ::appcompiler::fail E_PARSE_NAME $location "expected an identifier after '$word'"
                    }
                    set kind [expr {$initial eq "." ? "dotName" : "dataName"}]
                    set word [string range $word 1 end]
                }
                default {
                    if {[string match {[0-9]} $initial]} {
                        set kind integer
                    } elseif {[regexp {^[a-zA-Z_]} $word]} {
                        set kind [expr {$word in $keywords ? $word : "identifier"}]
                    } elseif {$word in {+ - * ( ) \{ \} : , = ::= := :: -> => ?}} {
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

    method parse {} {
        set imports {}
        set importLocations {}
        set functions {}
        set types {}
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
                    record - choice {
                        lappend types [my typeDeclaration $exported]
                    }
                    default {
                        ::appcompiler::fail E_PARSE_EXPECTED $token {expected a function, record or choice declaration, or an import}
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
        if {[my at ?]} {
            append name ?
            set end $token
            my advance
        }
        return [my typeLocation $start $end $name]
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
        if {$kind eq "record"} {
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
        if {[my at return]} {
            set start $token
            my advance
            return [my node $start return value [my expression]]
        }
        set variable [my take dataName {a binding, assignment, or return}]
        set name [dict get $variable value]
        set op [dict get $token kind]
        if {$op ni {:= ::= =}} {
            ::appcompiler::fail E_PARSE_EXPECTED $token {expected ':=', '::=', or '=' after the binding name}
        }
        my advance
        set value [my expression]
        if {$op eq "="} { return [my node $variable assign name $name value $value] }
        return [my node $variable bind name $name mutable [expr {$op eq ":="}] value $value]
    }

    method expression {{minimum 0}} {
        set left [my primary]
        while {[my at dotName] || [my at with]} {
            set where $token
            if {[my at dotName]} {
                my advance
                set left [my node $where field base $left name [dict get $where value]]
            } else {
                my advance
                my skipLines
                set fields [my braced fieldAssignment {record update} 1]
                set left [my node $where update base $left fields $fields]
            }
        }
        set precedences {+ 1 - 1 * 2}
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
            integer - - {
                set negative [my at -]
                if {$negative} { my advance }
                set digits [dict get [my take integer {a decimal integer}] value]
                # Always decimal, even for a value such as 008. No native-word
                # conversion is needed to represent a literal of any length.
                set digits [string trimleft $digits 0]
                if {$digits eq {}} { set digits 0 }
                if {$negative && $digits ne "0"} { set digits -$digits }
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
        my take => {'=>' after the match pattern}
        my skipLines
        set body [my expression]
        set name [dict get $variant value]
        return [my node $start arm type $type typeLocation [my typeLocation $start $typeEnd $type] \
                variant $name variantLocation [my node $variant variant name $name] bindings $bindings body $body]
    }

    method call {} {
        set start $token
        set name [dict get $token value]
        set qualifier {}
        my advance
        if {[my at ::]} {
            set qualifier $name
            my advance
            set name [dict get [my take identifier {a function name in the imported module}] value]
        }
        set args [my parenthesized expression]
        return [my node $start call name $name qualifier $qualifier args $args]
    }
}

proc ::appcompiler::parseModule {module source} {
    set parser [::appcompiler::ModuleParser new $module $source]
    try { return [$parser parse] } finally { $parser destroy }
}
