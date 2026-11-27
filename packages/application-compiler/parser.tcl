namespace eval ::appcompiler {}

# Parse each module in its own cursor so recursive and concurrent callers do
# not share source locations. The compiler consumes syntax trees, never source
# text evaluated as Tcl.
oo::class create ::appcompiler::ModuleParser {
    variable module source offset line column token

    constructor {moduleName sourceText} {
        set module $moduleName
        set source $sourceText
        set offset 0
        set line 1
        set column 1
        my advance
    }

    method advance {} {
        # The final alternative consumes every remaining character. A search
        # beginning at offset therefore always matches at that exact offset.
        set pattern {[ \t]+|\r\n|[\r\n]|#[^\r\n]*|'[^']*'|[.$]?[A-Za-z_][A-Za-z_0-9]*|[0-9]+|::=|:=|::|->|.}
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
                    set kind [expr {$initial eq "." ? "functionName" : "dataName"}]
                    set word [string range $word 1 end]
                }
                default {
                    if {[string match {[0-9]} $initial]} {
                        set kind integer
                    } elseif {[regexp {^[a-zA-Z_]} $word]} {
                        set kind [expr {$word in {fn export import return true false} ? $word : "identifier"}]
                    } elseif {$word in {+ - * ( ) \{ \} : , = ::= := :: ->}} {
                        set kind $word
                    } else {
                        ::appcompiler::fail E_PARSE_TOKEN $location "unexpected character '$word'"
                    }
                }
            }
            set token [dict merge $location [dict create kind $kind value $word]]
            return
        }
        set token [dict create kind eof value {} module $module line $line column $column]
    }

    method at {kind} { expr {[dict get $token kind] eq $kind} }

    method take {kind description} {
        # In a name position the grammar supplies its context. For example,
        # .other::return() can call an exported function declared as .return.
        set wordAsName [expr {$kind eq "identifier" && [dict get $token kind] in {fn export import return true false}}]
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
                my take fn {a function declaration or an import}
                lappend functions [my function $exported]
            }
            if {![my at eof]} { my take newline {a line break between declarations} }
            my skipLines
        }
        return [dict create imports $imports importLocations $importLocations functions $functions]
    }

    method function {exported} {
        set name [my take functionName {a dot-prefixed function name}]
        my take ( {'(' after the function name}
        set params {}
        my skipLines
        if {![my at )]} {
            while {1} {
                set param [my take dataName {a parameter name beginning with '$'}]
                my take : {':' before the parameter type}
                set type [dict get [my take identifier {a type name}] value]
                lappend params [my node $param param name [dict get $param value] type $type]
                my skipLines
                if {![my at ,]} break
                my advance
                my skipLines
            }
        }
        my take ) {')' after the parameters}
        my take -> {'->' before the result type}
        set result [dict get [my take identifier {a function result type}] value]
        my skipLines
        my take \{ {a braced function body}
        set body {}
        my skipLines
        while {![my at \}]} {
            if {[my at eof]} { ::appcompiler::fail E_PARSE_EXPECTED $token {expected the end of the function body} }
            lappend body [my statement]
            if {![my at \}]} { my take newline {a line break between statements} }
            my skipLines
        }
        my advance
        return [my node $name fn name [dict get $name value] exported $exported params $params result $result body $body]
    }

    method node {where kind args} {
        return [dict merge [dict remove $where value] [dict create kind $kind {*}$args]]
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
            functionName { return [my call] }
            default { ::appcompiler::fail E_PARSE_EXPECTED $token {expected a value expression} }
        }
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
        my take ( {'(' after the function name}
        my skipLines
        set args {}
        if {![my at )]} {
            while {1} {
                lappend args [my expression]
                my skipLines
                if {![my at ,]} break
                my advance
                my skipLines
            }
        }
        my take ) {')' after the call arguments}
        return [my node $start call name $name qualifier $qualifier args $args]
    }
}

proc ::appcompiler::parseModule {module source} {
    set parser [::appcompiler::ModuleParser new $module $source]
    try { return [$parser parse] } finally { $parser destroy }
}
