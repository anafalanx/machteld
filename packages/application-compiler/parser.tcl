namespace eval ::appcompiler {}

# Parse each module in its own cursor so recursive and concurrent callers do
# not share source locations. The compiler consumes syntax trees, never source
# text evaluated as Tcl.
oo::class create ::appcompiler::ModuleParser {
    variable module source offset line column token keywords localChoices stringModes consumed docLines

    constructor {moduleName sourceText} {
        set module $moduleName
        set source $sourceText
        set offset 0
        set line 1
        set column 1
        set keywords {fn extern export import return true false record choice alias distinct match with some none if else unit for in break continue while}
        set localChoices {}
        set stringModes {}
        set docLines {}
        # A Tcl caller can supply surrogate code points that strict UTF-8
        # source files cannot contain, even in comments or raw literals.
        if {[regexp -indices {[\uD800-\uDFFF]} $source invalid]} {
            set index [lindex $invalid 0]
            my consume [string range $source 0 $index-1]
            set where [dict create module $module line $line column $column endLine $line endColumn [expr {$column + 1}]]
            ::appcompiler::fail E_SOURCE_UNICODE $where {source contains a Unicode surrogate code point}
        }
        my advance
    }

    method consume {spelling} {
        set length [string length $spelling]
        incr offset $length
        set breaks [regexp -all -inline -indices {\r\n|[\r\n]} $spelling]
        if {[llength $breaks]} {
            incr line [llength $breaks]
            set column [expr {$length - [lindex $breaks end 1]}]
        } else {
            incr column $length
        }
    }

    method location {} { dict create module $module line $line column $column }

    method finishToken {start kind value} {
        return [dict merge $start [dict create endLine $line endColumn $column kind $kind value $value]]
    }

    # Leave the closing quote (or a physical interpolation marker) for the
    # caller. Decoded dollars never re-enter the lexer.
    method quotedChunk {opening interpolated} {
        set value {}
        set escapes [list \" \" \\ \\ n \n r \r t \t 0 \u0000 b \b f \f]
        set markers {["\\]}
        if {$interpolated} {
            dict set escapes {$} {$}
            set markers {["\\$]}
        }
        while {[regexp -start $offset -indices $markers $source marker]} {
            set at [lindex $marker 0]
            if {$at > $offset} {
                set chunk [string range $source $offset $at-1]
                append value $chunk
                my consume $chunk
            }
            set mark [string index $source $offset]
            if {$mark eq "\""} { return $value }
            if {$mark eq {$}} {
                set next [string index $source $offset+1]
                if {$next eq "\{" || [regexp {[A-Za-z_]} $next]} { return $value }
                append value {$}
                incr offset
                incr column
                continue
            }
            set where [dict create module $module line $line column $column endLine $line endColumn [expr {$column + 1}]]
            incr offset
            incr column

            set selector [string index $source $offset]
            if {[dict exists $escapes $selector]} {
                append value [dict get $escapes $selector]
                incr offset
                incr column
            } elseif {$selector eq "u"} {
                # A Unicode escape after its backslash occupies at most nine
                # ASCII characters. Inspect only that bounded window.
                set window [string range $source $offset $offset+8]
                if {![regexp {\Au\{([0-9a-fA-F]{1,6})\}} $window spelling digits]} {
                    ::appcompiler::fail E_PARSE_ESCAPE $where {expected one to six hex digits inside \u{...}}
                }
                scan $digits %x scalar
                if {$scalar > 0x10ffff || ($scalar >= 0xd800 && $scalar <= 0xdfff)} {
                    ::appcompiler::fail E_PARSE_ESCAPE $where {Unicode escape does not name a scalar value}
                }
                append value [format %c $scalar]
                incr offset [string length $spelling]
                incr column [string length $spelling]
            } elseif {$selector eq ""} {
                ::appcompiler::fail E_PARSE_ESCAPE $where {incomplete escape in double-quoted text}
            } else {
                ::appcompiler::fail E_PARSE_ESCAPE $where {unknown escape in double-quoted text}
            }
        }
        ::appcompiler::fail E_PARSE_STRING $opening {unterminated double-quoted text literal}
    }

    method interpolationToken {} {
        set start [my location]
        set mark [string index $source $offset]
        set next [string index $source $offset+1]
        if {$mark eq "\""} {
            my consume \"
            lpop stringModes
            return [my finishToken $start interpolateEnd {}]
        }
        if {$mark eq {$} && $next eq "\{"} {
            my consume "\$\{"
            set opening [my finishToken $start holeStart {}]
            lappend stringModes [list code $opening 0]
            return $opening
        }
        if {$mark eq {$} && [regexp {[A-Za-z_]} $next]} {
            regexp -start $offset -indices {[$][A-Za-z_][A-Za-z_0-9]*} $source bounds
            set word [string range $source {*}$bounds]
            my consume $word
            return [my finishToken $start holeName [string range $word 1 end]]
        }
        set chunk [my quotedChunk [lindex $stringModes end 1] 1]
        return [my finishToken $start interpolateText $chunk]
    }

    method advance {} {
        # The cursor normally sits beyond the lookahead token. Save the end
        # of the consumed token before skipping trivia or reading ahead.
        set consumed [list $offset $line $column]
        if {[lindex $stringModes end 0] eq "text"} {
            set token [my interpolationToken]
            return
        }
        # The final alternative consumes every remaining character. A search
        # beginning at offset therefore always matches at that exact offset.
        set pattern {[ \t]+|\r\n|[\r\n]|#[^\r\n]*|'[^']*'|[.$]?[A-Za-z_][A-Za-z_0-9]*|[0-9]+(?:\.[0-9]+)?|\.\.=?|::=|:=|::|->|=>|==|!=|.}
        while {$offset < [string length $source]} {
            regexp -start $offset -indices -- $pattern $source bounds
            lassign $bounds first last
            set word [string range $source $first $last]
            set location [my location]
            my consume $word
            dict set location endLine $line
            dict set location endColumn $column

            set initial [string index $word 0]
            switch -exact -- $initial {
                " " - "\t" { continue }
                "#" {
                    if {[string range $word 0 1] eq "##"} {
                        set startOfLine [expr {$first - [dict get $location column] + 1}]
                        if {[string trim [string range $source $startOfLine $first-1] " \t"] eq ""} {
                            set content [string range $word 2 end]
                            if {[string index $content 0] eq " "} { set content [string range $content 1 end] }
                            dict set docLines [dict get $location line] $content
                        }
                    }
                    continue
                }
                "\r" - "\n" { set kind newline }
                "'" {
                    if {[string length $word] == 1} {
                        ::appcompiler::fail E_PARSE_STRING $location {unterminated raw text literal}
                    }
                    set kind text
                    set word [string range $word 1 end-1]
                }
                \" {
                    set kind text
                    try {
                        set word [my quotedChunk $location 0]
                    } trap {APPCOMPILER DIAGNOSTIC E_PARSE_STRING} {message options} {
                        if {![llength $stringModes]} { return -options $options $message }
                        # In a hole the grammar distinguishes an unfinished
                        # string operand from an outer quote after a value.
                        set token [dict merge $location [dict create kind unterminatedText value {}]]
                        return
                    }
                    my consume \"
                    dict set location endLine $line
                    dict set location endColumn $column
                }
                {$} - {.} {
                    if {$word eq {$} && [string index $source $offset] eq "\""} {
                        my consume \"
                        set token [my finishToken $location interpolateStart {}]
                        lappend stringModes [list text $token]
                        return
                    } elseif {$word in {.. ..=}} {
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
                    } elseif {$word in {+ - * / ( ) \{ \} [ ] < > : , = ::= := :: -> => ? == != |}} {
                        set kind $word
                    } else {
                        ::appcompiler::fail E_PARSE_TOKEN $location "unexpected character '$word'"
                    }
                }
            }
            if {[llength $stringModes] && $kind in {\{ \}}} {
                set depth [lindex $stringModes end 2]
                if {$kind eq "\{"} {
                    lset stringModes end 2 [incr depth]
                } elseif {$depth} {
                    lset stringModes end 2 [incr depth -1]
                } else {
                    lpop stringModes
                    set kind holeEnd
                }
            }
            set token [dict merge $location [dict create kind $kind value $word]]
            return
        }
        if {[llength $stringModes]} { my unclosedHole }
        set token [my finishToken [my location] eof {}]
    }

    method unclosedHole {} {
        ::appcompiler::fail E_PARSE_INTERPOLATION [lindex $stringModes end 1] {unterminated interpolation expression}
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

    method cursor {} { list $offset $line $column $token $stringModes $consumed }

    method restore {cursor} { lassign $cursor offset line column token stringModes consumed }

    method collectChoiceNames {} {
        # .name::member(...) can denote an imported function or a locally
        # declared choice. Collect declaration heads before parsing any uses.
        # Skip complete interpolations using lexical tokens only. Their
        # expressions can use names of choices declared later in this module.
        set beginning [my cursor]
        set depth 0
        set declarationStart 1
        while {![my at eof]} {
            if {[my at interpolateStart]} {
                set nesting 1
                while {$nesting} {
                    my advance
                    if {[my at unterminatedText]} {
                        my restore $beginning
                        return
                    }
                    if {[my at interpolateStart]} { incr nesting }
                    if {[my at interpolateEnd]} { incr nesting -1 }
                }
                my advance
                set declarationStart 0
            } elseif {$declarationStart && [my at choice]} {
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
        set resources {}
        set examples {}
        set owner {}
        if {[string first :: $source] >= 0 && ([string first choice $source] >= 0 ||
                [string first alias $source] >= 0 || [string first distinct $source] >= 0)} {
            my collectChoiceNames
        }
        my skipLines
        while {![my at eof]} {
            if {[my at identifier] && [dict get $token value] eq "example"} {
                lappend examples [my example $owner]
            } elseif {[my at identifier] && [dict get $token value] eq "resource"} {
                set owner {}
                set start $token
                my advance
                set type [my take dotName {the local nominal type of the resource}]
                set using [my take identifier {'using' before the cleanup function}]
                if {[dict get $using value] ne "using"} {
                    ::appcompiler::fail E_PARSE_EXPECTED $using {expected 'using' before the cleanup function}
                }
                set closer [my take dotName {the local cleanup function}]
                lappend resources [my node $start resource name [dict get $type value] closer [dict get $closer value] \
                    typeLocation [my node $type type] closerLocation [my node $closer fn]]
            } elseif {[my at import]} {
                set owner {}
                my advance
                set imported [my take identifier {an imported module name}]
                set name [dict get $imported value]
                lappend imports $name
                dict set importLocations $name [my node $imported import name $name]
            } else {
                set start $token
                set exported [my at export]
                if {$exported} { my advance }
                set declaration [dict get $token kind]
                if {[my at identifier] && [dict get $token value] eq "tool"} {set declaration tool}
                switch -exact -- $declaration {
                    tool {
                        my advance
                        set function [my documented $start [my tool $exported]]
                        lappend functions $function
                        set owner [dict get $function name]
                    }
                    fn - extern {
                        set kind [dict get $token kind]
                        my advance
                        if {$kind eq "extern"} { my take fn "'fn' after 'extern'" }
                        set function [my documented $start [my function $exported $kind]]
                        lappend functions $function
                        set owner [dict get $function name]
                    }
                    record - choice - alias - distinct {
                        set owner {}
                        lappend types [my documented $start [my typeDeclaration $exported]]
                    }
                    default {
                        ::appcompiler::fail E_PARSE_EXPECTED $token {expected a function, external function, tool, record, choice, alias, distinct, resource or import declaration}
                    }
                }
            }
            if {![my at eof]} { my take newline {a line break between declarations} }
            my skipLines
        }
        return [dict create imports $imports importLocations $importLocations types $types functions $functions resources $resources examples $examples]
    }

    method documented {start declaration} {
        set lines {}
        set n [dict get $start line]
        while {[dict exists $docLines [incr n -1]]} { lappend lines [dict get $docLines $n] }
        if {[llength $lines]} { dict set declaration doc [join [lreverse $lines] \n] }
        return $declaration
    }

    method example {owner} {
        set start $token
        set first [expr {$offset - [string length [dict get $start value]]}]
        my advance
        set name [my take dotName {the dot-prefixed function called by the example}]
        set types [my callTypeArguments]
        set actual [my node $name call name [dict get $name value] qualifier {} {*}$types args [my parenthesized callArgument]]
        set actualLocation [my consumedSpan $name]
        my take => {'=>' before the example expectation}
        my skipLines
        set expectedStart $token
        if {[my at identifier] && [dict get $token value] eq "error"} {
            my advance
            set literal [my take text {a literal text error code}]
            set fields {}
            if {[my at \{]} { set fields [my braced exampleField {expected problem fields} 1] }
            set expectation [dict create expectation error code [my node $literal text value [dict get $literal value]] fields $fields]
        } else {
            set expectation [dict create expectation value expected [my expression]]
        }
        lassign $consumed last endLine endColumn
        return [my node $start example owner $owner source [string range $source $first $last-1] \
            endLine $endLine endColumn $endColumn actual $actual actualLocation $actualLocation \
            expectedLocation [my consumedSpan $expectedStart] {*}$expectation]
    }

    method consumedSpan {start} {
        return [dict replace [dict remove $start kind value] \
            endLine [lindex $consumed 1] endColumn [lindex $consumed 2]]
    }

    method exampleField {} {
        set field [my fieldAssignment]
        dict set field kind exampleField
        return $field
    }

    # All delimited lists return their elements in source order. Each item
    # parser consumes exactly one complete production, including nested lists.
    method commaItems {item closing {allowTrailing 0}} {
        set entries {}
        my skipLines
        if {![my at $closing]} {
            while {1} {
                lappend entries [my $item]
                my skipLines
                if {![my at ,]} break
                my advance
                my skipLines
                if {$allowTrailing && [my at $closing]} break
            }
        }
        return $entries
    }

    method parenthesized {item {endVar {}}} {
        my take ( {an opening parenthesis}
        set entries [my commaItems $item )]
        set end [my take ) {a closing parenthesis}]
        if {$endVar ne ""} {
            upvar 1 $endVar closing
            set closing $end
        }
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

    method function {exported kind} {
        set name [my take dotName {a dot-prefixed function name}]
        set generics [my typeParameters]
        set params [my parenthesized parameter]
        my take -> {'->' before the result type}
        set result [my typeAnnotation]
        my skipLines
        set node [my node $name $kind name [dict get $name value] exported $exported {*}$generics params $params \
                result [dict get $result name] resultLocation $result body {}]
        if {$kind eq "extern"} { return [dict merge $node [my externalBinding]] }
        if {[my at =>]} {
            my advance
            my skipLines
            set start $token
            dict set node body [list [my node $start return value [my expression]]]
        } else {
            dict set node body [my braced statement {function body}]
        }
        return $node
    }

    method tool {exported} {
        set name [my take dotName {a dot-prefixed tool name}]
        my take = {'=' before the relative executable path}
        set path [my take text {a literal executable path relative to the application}]
        if {[catch {::appcompiler::project::relativePath [dict get $path value]} relative] ||
                ![string equal -nocase [file extension $relative] .exe]} {
            ::appcompiler::fail TOOL_PATH $path {tool requires a portable relative .exe path}
        }
        set lookup [my node $path toolPath value $relative]
        set result [my node $name type name result<text,problem>]
        return [my node $name tool name [dict get $name value] exported $exported typeParams {} \
            typeParamLocations {} params {} result result<text,problem> resultLocation $result \
            path $relative body [list [my node $path return value $lookup]]]
    }

    method externalBinding {} {
        my take = {'=' before the external command prefix}
        my skipLines
        my take {[} {an opening bracket before the external command prefix}
        my skipLines
        if {[my at {]}]} {
            ::appcompiler::fail E_EXTERN_COMMAND $token {the external command prefix must contain a command name}
        }
        set first [my take text {a quoted absolute Tcl command name}]
        set command [dict get $first value]
        if {![string match ::* $command] || [string match *:: $command] ||
                [string first :::: $command] >= 0 || [string first \u0000 $command] >= 0} {
            ::appcompiler::fail E_EXTERN_COMMAND $first {expected an absolute Tcl command name with nonempty namespace components and no NUL}
        }
        set prefix [list $command]
        my skipLines
        while {[my at ,]} {
            my advance
            my skipLines
            lappend prefix [dict get [my take text {a quoted fixed command argument}] value]
            my skipLines
        }
        my take {]} {a closing bracket after the external command prefix}
        set binding [dict create prefix $prefix prefixLocation [my node $first command] package {}]
        set after [my cursor]
        my skipLines
        if {[my at identifier] && [dict get $token value] eq "from"} {
            my advance
            my skipLines
            set word [my take text {a quoted package name after 'from'}]
            set package [dict get $word value]
            if {$package eq "" || [string index $package 0] eq "-" || [string first \u0000 $package] >= 0} {
                ::appcompiler::fail E_EXTERN_PACKAGE $word {expected a nonempty package name without a NUL or leading hyphen}
            }
            dict set binding package $package
            dict set binding packageLocation [my node $word package]
        } else {
            my restore $after
        }
        return $binding
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
        set type [my appliedType $start $end $name]
        set name [dict get $type name]
        while {[my at ?]} {
            append name ?
            set optional [my typeLocation $start $token $name]
            dict set optional typeLocations [list $type]
            set type $optional
            my advance
        }
        return $type
    }

    method appliedType {start end name} {
        if {![my at <]} {return [my typeLocation $start $end $name]}
        set args [my typeArguments]
        append name < [join [dict get $args types] ,] >
        return [dict merge [my typeLocation $start [dict get $args end] $name] \
                [dict create typeLocations [dict get $args locations]]]
    }

    method typeParameters {} {
        set names {}
        set locations {}
        if {[my at <]} {
            my advance
            my skipLines
            while {1} {
                set param [my take dotName {a dot-prefixed type parameter}]
                set name [dict get $param value]
                lappend names $name
                lappend locations [my node $param typeParameter name $name]
                my skipLines
                if {![my at ,]} break
                my advance
                my skipLines
            }
            my take > {a closing angle bracket after the type parameters}
        }
        return [dict create typeParams $names typeParamLocations $locations]
    }

    method callTypeArguments {} {
        if {![my at <]} {return [dict create typeArgs {} typeLocations {}]}
        set args [my typeArguments]
        return [dict create typeArgs [dict get $args types] typeLocations [dict get $args locations]]
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
        set label {}
        if {![my at dataName]} {
            set label [my take identifier {an argument label or a parameter name beginning with '$'}]
        }
        set parameter [my typedName [my take dataName {a parameter name beginning with '$'}] param]
        if {$label ne {}} {dict set parameter label [dict get $label value]}
        return $parameter
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
        set generics {}
        if {$kind in {record choice}} {set generics [my typeParameters]}
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
        return [my node $name $kind name [dict get $name value] exported $exported {*}$generics {*}$members]
    }

    method node {where kind args} {
        return [dict merge [dict remove $where value] [dict create kind $kind {*}$args]]
    }

    method typeLocation {start end name} {
        return [my node $start type name $name endLine [dict get $end endLine] endColumn [dict get $end endColumn]]
    }

    method statement {} {
        set start $token
        if {[my at identifier] && [dict get $token value] eq "using"} {
            set beginning [my cursor]
            my advance
            if {[my at dataName]} {
                set binding $token
                my advance
                my take ::= {'::=' after the scoped binding}
                if {[my at identifier] && [dict get $token value] eq "ref"} {
                    set value [my primary]
                    dict set value kind refCreate
                } elseif {[my at identifier] && [dict get $token value] eq "sql_begin"} {
                    set resource $token
                    my advance
                    set begin [my node $resource sqlBegin args [my parenthesized expression]]
                    set question [my take ? {'?' to propagate failure when opening the transaction}]
                    set value [my node $question propagate value $begin]
                } else {
                    set value [my expression]
                    if {[dict get $value kind] ne "propagate"} {
                        ::appcompiler::fail E_PARSE_EXPECTED $token {expected '?' to propagate failure when acquiring the resource}
                    }
                    if {[dict get $value value kind] eq "builtin" && [dict get $value value name] eq "tk_open"} {
                        dict set value value kind tkOpen
                    }
                }
                my skipLines
                return [my node $start using binding [my node $binding binding name [dict get $binding value]] \
                    value $value body [my braced statement {resource body}]]
            }
            my restore $beginning
        }
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

    method interpolated {} {
        set opening $token
        set parts {}
        my advance
        while {![my at interpolateEnd]} {
            set start $token
            switch -exact -- [dict get $token kind] {
                interpolateText {
                    lappend parts [my node $start text value [dict get $start value]]
                    my advance
                }
                holeName {
                    set value [my node $start var name [dict get $start value]]
                    lappend parts [my node $start hole value $value]
                    my advance
                }
                holeStart {
                    my advance
                    my skipLines
                    if {[my at holeEnd]} {
                        ::appcompiler::fail E_PARSE_INTERPOLATION $token {expected an expression inside interpolation}
                    }
                    set value [my expression]
                    my skipLines
                    if {[my at unterminatedText]} { my unclosedHole }
                    if {![my at holeEnd]} {
                        ::appcompiler::fail E_PARSE_INTERPOLATION $token {expected the closing brace after the interpolation expression}
                    }
                    lappend parts [my node $start hole value $value endLine [dict get $token endLine] endColumn [dict get $token endColumn]]
                    my advance
                }
                default {
                    ::appcompiler::fail E_PARSE_INTERPOLATION $token {expected interpolated text, an expression or the closing quote}
                }
            }
        }
        set closing $token
        my advance
        return [my node $opening interpolate parts $parts endLine [dict get $closing endLine] endColumn [dict get $closing endColumn]]
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
            {[} {
                my advance
                set items [my commaItems expression {]} 1]
                set end [my take {]} {a closing bracket after the list elements}]
                return [my node $start list items $items endLine [dict get $end endLine] endColumn [dict get $end endColumn]]
            }
            unterminatedText {
                ::appcompiler::fail E_PARSE_STRING $token {unterminated double-quoted text literal}
            }
            interpolateStart { return [my interpolated] }
            dataName {
                my advance
                set binding [my node $start var name [dict get $start value]]
                if {[my at (]} {
                    return [my node $start invoke value $binding args [my parenthesized callArgument]]
                }
                return $binding
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

    method choicePayload {} {
        if {[my at identifier] && [dict get $token value] eq "_"} {
            set discard $token
            my advance
            return [my node $discard discard]
        }
        return [my patternBinding]
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
        set first [my choicePattern]
        set alternatives [list $first]
        while {1} {
            if {[my at newline]} {
                set afterPattern [my cursor]
                my skipLines
                if {![my at |]} { my restore $afterPattern }
            }
            if {![my at |]} break
            my advance
            my skipLines
            lappend alternatives [my choicePattern]
        }
        set body [my armBody]
        if {[llength $alternatives] == 1} {
            dict set first body $body
            return $first
        }
        set end [lindex $alternatives end]
        return [my node $start armGroup alternatives $alternatives body $body \
            endLine [dict get $end endLine] endColumn [dict get $end endColumn]]
    }

    method choicePattern {} {
        set start $token
        set name [dict get $start value]
        if {[my at none] || [my at some] || ([my at identifier] && $name in {ok err})} {
            set kind [expr {$name in {ok err} ? "resultArm" : "optionalArm"}]
            set annotation {}
            set variant $start
            my advance
        } else {
            # A local pattern has two components (.type::case); an imported
            # pattern has three (.module::type::case).
            my take dotName {a dot-prefixed choice type, none, some, ok or err in a match pattern}
            set kind arm
            set location [my appliedType $start $start ".[dict get $start value]"]
            my take :: {'::' before the choice variant}
            set variant [my take identifier {a choice variant name}]
            if {[my at ::] || [my at <]} {
                if {[dict exists $location typeLocations]} {
                    ::appcompiler::fail E_PARSE_EXPECTED $token {expected the choice pattern after the specialized type name}
                }
                set location [my appliedType $start $variant "[dict get $location name]::[dict get $variant value]"]
                my take :: {'::' before the choice variant}
                set variant [my take identifier {a choice variant name}]
            }
            set annotation [dict create type [dict get $location name] typeLocation $location]
        }
        set bindings {}
        set end $variant
        if {[my at (]} { set bindings [my parenthesized choicePayload end] }
        set name [dict get $variant value]
        return [my node $start $kind {*}$annotation \
                variant $name variantLocation [my node $variant variant name $name] bindings $bindings \
                endLine [dict get $end endLine] endColumn [dict get $end endColumn]]
    }

    method armBody {} {
        my take => {'=>' after the match pattern}
        my skipLines
        return [my expression]
    }

    method callArgument {} {
        if {[my at identifier] || [dict get $token kind] in $keywords} {
            set beginning [my cursor]
            set label $token
            my advance
            if {[my at :]} {
                my advance
                my skipLines
                set value [my expression]
                dict set value argumentLabel [my node $label label name [dict get $label value]]
                return $value
            }
            my restore $beginning
        }
        return [my expression]
    }

    method call {} {
        set start $token
        set name [dict get $token value]
        set qualifier {}
        set locations {}
        my advance
        set applied [my appliedType $start $start ".$name"]
        if {[my at ::]} {
            set qualifier $name
            my advance
            set member [my take identifier {a qualified member name}]
            set name [dict get $member value]
            set ambiguous 0
            set choice $applied
            if {![dict exists $applied typeLocations]} {
                set applied [my appliedType $start $member ".${qualifier}::$name"]
                if {[my at ::]} {
                    set choice $applied
                    my advance
                    set member [my take identifier {a choice variant name}]
                    set name [dict get $member value]
                } elseif {![dict exists $applied typeLocations] && [dict exists $localChoices $qualifier $name]} {
                    set ambiguous [my at (]
                } else {
                    if {[dict exists $localChoices $qualifier]} {
                        set locations [dict create typeLocation $choice variantLocation [my node $member variant name $name]]
                    }
                    set choice {}
                }
            }
            if {$choice ne {}} {
                set args {}
                if {[my at (]} { set args [my parenthesized callArgument] }
                return [my node $start construct type [dict get $choice name] typeLocation $choice \
                        variant $name variantLocation [my node $member variant name $name] ambiguous $ambiguous args $args]
            }
        }
        set typeLocations [dict getdef $applied typeLocations {}]
        set typeArgs [lmap location $typeLocations {dict get $location name}]
        set kind functionValue
        set args {}
        if {[my at (]} {
            set kind call
            set args [my parenthesized callArgument]
        }
        return [my node $start $kind name $name qualifier $qualifier args $args \
            typeArgs $typeArgs typeLocations $typeLocations {*}$locations]
    }
}

proc ::appcompiler::parseModule {module source} {
    set parser [::appcompiler::ModuleParser new $module $source]
    try { return [$parser parse] } finally { $parser destroy }
}
