# cli.tcl -- ::machteld::cli: declare a tool's arguments once.
#
#   cli parse $argv $spec      -> a dict of values
#   cli usage $spec ?name?     -> the help text, generated from the same spec
#
# Parsing is pure: it prints nothing and never exits, which also works in a GUI
# host with no standard channels. `--help` is a returned flag and usage failures
# carry generated help text. The declaration is a Tcl dict, not a mini-language.
#
#   set spec {
#       --interval {type int    default 2000 min 100 help "refresh interval, ms"}
#       --format   {type string default text choices {text json} help "output format"}
#       --all      {type flag                help "show everything"}
#       dir        {type string default .    help "directory to watch"}
#   }
#
# A name starting with `--` is an option; anything else is a positional, taken in
# declaration order. Options use `--` because these are arguments to a PROGRAM;
# the palette's own verbs keep Tcl's `-option`, and that split is deliberate.

namespace eval ::machteld {}

# The attributes an entry may carry, and the types a value may have. Both are
# closed sets: a typo in a spec is the author's mistake and should fail loudly at
# the point of declaration rather than silently doing nothing.
set ::machteld::CLI_ATTRS {type default min max choices help required}
set ::machteld::CLI_TYPES {flag int string}

# Normalise and CHECK the spec, returning an ordered list of {name kind attrs}.
# Tcl dicts iterate in insertion order, which is what makes positional order fall
# out of the declaration without anyone numbering anything.
proc ::machteld::CliNorm {spec} {
    variable CLI_ATTRS
    variable CLI_TYPES
    if {[catch {dict size $spec}]} {
        Fail CLI badvalue "cli: the spec must be a dict of name -> attributes"
    }
    # A DICT SILENTLY KEEPS ONLY THE LAST OF A REPEATED KEY, so declaring
    # `--verbose` twice does not collide -- the first declaration simply vanishes,
    # taking its type and default with it, and nothing anywhere says so. Comparing
    # the raw list length against the dict size is the only place that duplication
    # is still visible, because by the time `dict for` runs it is gone.
    if {[llength $spec] != 2 * [dict size $spec]} {
        Fail CLI badvalue "cli: the spec names something twice (a dict keeps only the last)"
    }
    set out {}
    set seen {}
    dict for {name attrs} $spec {
        if {[catch {dict size $attrs}]} {
            Fail CLI badvalue "cli: attributes for \"$name\" must be a dict"
        }
        foreach k [dict keys $attrs] {
            if {$k ni $CLI_ATTRS} {
                Fail CLI badvalue "cli: unknown attribute \"$k\" for \"$name\" (known: $CLI_ATTRS)"
            }
        }
        set type [expr {[dict exists $attrs type] ? [dict get $attrs type] : "string"}]
        if {$type ni $CLI_TYPES} {
            Fail CLI badvalue "cli: unknown type \"$type\" for \"$name\" (known: $CLI_TYPES)"
        }
        set kind [expr {[string match --* $name] ? "option" : "positional"}]
        if {$name eq "--help"} {
            Fail CLI badvalue "cli: --help is provided by the parser and cannot be redeclared"
        }
        if {$kind eq "positional" && $type eq "flag"} {
            Fail CLI badvalue "cli: \"$name\" is positional and cannot be a flag"
        }
        set key [expr {$kind eq "option" ? [string range $name 2 end] : $name}]
        if {$key eq ""} { Fail CLI badvalue "cli: \"--\" is not an option name" }
        # The parser owns the `help` result key for both spellings.
        if {$key eq "help"} {
            Fail CLI badvalue "cli: \"$name\" collides with the parser's help key"
        }
        # Still reachable even after the duplicate-key check above: `--dir` and a
        # positional `dir` are distinct dict keys that would land on one result key.
        if {[dict exists $seen $key]} {
            Fail CLI badvalue "cli: \"$name\" collides with another entry on the key \"$key\""
        }
        dict set seen $key 1
        dict set attrs _key $key
        dict set attrs _type $type

        # Everything below describes the declaration, not command-line input.
        # Validate it now so a broken spec cannot lie dormant until help is
        # rendered or a particular option happens to be supplied.
        if {[dict exists $attrs required]
                && ![string is boolean -strict [dict get $attrs required]]} {
            Fail CLI badvalue "cli: required for \"$name\" must be a boolean"
        }

        set hasMin [dict exists $attrs min]
        set hasMax [dict exists $attrs max]
        if {$type ne "int" && ($hasMin || $hasMax)} {
            Fail CLI badvalue "cli: min and max for \"$name\" require type int"
        }
        foreach bound {min max} {
            if {[dict exists $attrs $bound]
                    && ![string is integer -strict [dict get $attrs $bound]]} {
                Fail CLI badvalue "cli: $bound for \"$name\" must be a whole number"
            }
        }
        if {$hasMin && $hasMax
                && [dict get $attrs min] > [dict get $attrs max]} {
            Fail CLI badvalue "cli: min for \"$name\" cannot exceed max"
        }

        if {[dict exists $attrs choices]} {
            set choices [dict get $attrs choices]
            if {[catch {llength $choices}]} {
                Fail CLI badvalue "cli: choices for \"$name\" must be a list"
            }
            if {$type eq "flag"} {
                Fail CLI badvalue "cli: \"$name\" is a flag and cannot declare choices"
            }
            # A choice that cannot itself pass the declared type/range is dead
            # data and almost certainly a typo in the spec.
            foreach choice $choices {
                CliCheck $name $attrs $choice badvalue
            }
        }
        if {[dict exists $attrs default]} {
            CliCheck $name $attrs [dict get $attrs default] badvalue
        }
        lappend out [list $name $kind $attrs]
    }
    return $out
}

proc ::machteld::CliDefault {attrs} {
    if {[dict exists $attrs default]} { return [dict get $attrs default] }
    if {[dict get $attrs _type] eq "flag"} { return 0 }
    return ""
}

# Check one value against its declared constraints. Command-line values use
# `usage`; CliNorm passes `badvalue` for author-supplied defaults and choices.
proc ::machteld::CliCheck {name attrs v {code usage}} {
    switch -- [dict get $attrs _type] {
        flag {
            if {![string is boolean -strict $v]} {
                Fail CLI $code "$name needs a boolean, got \"$v\""
            }
        }
        int {
            if {![string is integer -strict $v]} {
                Fail CLI $code "$name needs a whole number, got \"$v\""
            }
            if {[dict exists $attrs min] && $v < [dict get $attrs min]} {
                Fail CLI $code "$name must be at least [dict get $attrs min], got $v"
            }
            if {[dict exists $attrs max] && $v > [dict get $attrs max]} {
                Fail CLI $code "$name must be at most [dict get $attrs max], got $v"
            }
        }
    }
    if {[dict exists $attrs choices]} {
        set ch [dict get $attrs choices]
        if {$v ni $ch} {
            Fail CLI $code "$name must be one of [join $ch {, }], got \"$v\""
        }
    }
    return $v
}

proc ::machteld::CliUsage {norm name} {
    set opts {}
    set pos {}
    foreach entry $norm {
        lassign $entry n kind attrs
        if {$kind eq "option"} { lappend opts $entry } else { lappend pos $entry }
    }
    set line "usage: $name"
    append line " ?options?"
    foreach entry $pos {
        lassign $entry n kind attrs
        set req [expr {[dict exists $attrs required] && [dict get $attrs required]}]
        append line [expr {$req ? " <$n>" : " ?$n?"}]
    }
    set out $line
    if {[llength $pos]} {
        append out "\n\narguments:"
        foreach entry $pos {
            lassign $entry n kind attrs
            append out "\n  [format %-22s $n] [CliHelpText $attrs]"
        }
    }
    append out "\n\noptions:"
    foreach entry $opts {
        lassign $entry n kind attrs
        set label $n
        if {[dict get $attrs _type] ne "flag"} { append label " <[dict get $attrs _type]>" }
        append out "\n  [format %-22s $label] [CliHelpText $attrs]"
    }
    append out "\n  [format %-22s --help] show this message"
    return $out
}

# The help line for one entry: its text, then the facts the caller would
# otherwise have to discover by being refused -- default, range, choices.
proc ::machteld::CliHelpText {attrs} {
    set t [expr {[dict exists $attrs help] ? [dict get $attrs help] : ""}]
    set extra {}
    if {[dict exists $attrs choices]} { lappend extra "one of [join [dict get $attrs choices] {, }]" }
    if {[dict exists $attrs min] && [dict exists $attrs max]} {
        lappend extra "[dict get $attrs min]-[dict get $attrs max]"
    } elseif {[dict exists $attrs min]} {
        lappend extra "at least [dict get $attrs min]"
    } elseif {[dict exists $attrs max]} {
        lappend extra "at most [dict get $attrs max]"
    }
    # A flag's default 0 is noise; any other declared default is information.
    set isFlag [expr {[dict exists $attrs type] && [dict get $attrs type] eq "flag"}]
    if {[dict exists $attrs default] && [dict get $attrs default] ne "" && !$isFlag} {
        lappend extra "default [dict get $attrs default]"
    }
    if {[llength $extra]} { append t " (" [join $extra {; }] ")" }
    return [string trimleft $t]
}

proc ::machteld::cli {args} {
    set subs {parse usage duration}
    if {[llength $args] < 1} {
        Fail CLI usage "usage: cli parse argv spec | cli usage spec ?name? | cli duration value"
    }
    set sub [lindex $args 0]
    if {$sub ni $subs} {
        Fail CLI usage "cli: unknown subcommand \"$sub\": must be [join $subs { or }]"
    }

    # Programs use the same explicit-unit duration parser as runtime commands.
    if {$sub eq "duration"} {
        if {[llength $args] != 2} { Fail CLI usage "usage: cli duration value" }
        return [_dur2ms CLI [lindex $args 1]]
    }

    if {$sub eq "usage"} {
        if {[llength $args] < 2 || [llength $args] > 3} {
            Fail CLI usage "usage: cli usage spec ?name?"
        }
        set name [expr {[llength $args] == 3 ? [lindex $args 2]
                        : [file rootname [file tail [info nameofexecutable]]]}]
        return [CliUsage [CliNorm [lindex $args 1]] $name]
    }

    if {[llength $args] != 3} { Fail CLI usage "usage: cli parse argv spec" }
    lassign $args _ argv spec
    set norm [CliNorm $spec]

    set name [file rootname [file tail [info nameofexecutable]]]
    try {
        return [CliParse $argv $norm]
    } trap {MACHTELD CLI usage} {msg opts} {
        return -options $opts "$msg\n\n[CliUsage $norm $name]"
    }
}

proc ::machteld::CliParse {argv norm} {
    set res {}
    set positional {}
    set supplied {}
    foreach entry $norm {
        lassign $entry n kind attrs
        dict set res [dict get $attrs _key] [CliDefault $attrs]
        if {$kind eq "positional"} { lappend positional $entry }
    }
    # `help` is always present, so a tool can check it without declaring it. It is
    # a value rather than an action for the reason at the top of this file.
    dict set res help 0

    set rest {}
    set endopts 0
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {$endopts || ![string match --* $a]} { lappend rest $a ; continue }
        if {$a eq "--"} { set endopts 1 ; continue }
        if {$a eq "--help"} { dict set res help 1 ; continue }

        set found ""
        foreach entry $norm {
            lassign $entry n kind attrs
            if {$kind eq "option" && $n eq $a} { set found $entry ; break }
        }
        if {$found eq ""} {
            Fail CLI usage "unknown option \"$a\""
        }
        lassign $found n kind attrs
        if {[dict get $attrs _type] eq "flag"} {
            set key [dict get $attrs _key]
            dict set res $key 1
            lappend supplied $key
            continue
        }
        # Refuse a missing value here instead of passing an ambiguous empty one.
        set nxt [lindex $argv [expr {$i + 1}]]
        # `--` is the end-of-options marker everywhere, a value nowhere.
        if {$i + 1 >= [llength $argv] || [string match --* $nxt]} {
            Fail CLI usage "$n needs a value"
        }
        incr i
        set key [dict get $attrs _key]
        dict set res $key [CliCheck $n $attrs $nxt]
        lappend supplied $key
    }

    # Positionals, in declaration order, then whatever is left over. Help waives
    # only missing required values: positionals that were actually supplied are
    # still typed, and unexpected extras remain mistakes.
    set wantsHelp [dict get $res help]
    set idx 0
    foreach entry $positional {
        lassign $entry n kind attrs
        if {$idx < [llength $rest]} {
            dict set res [dict get $attrs _key] [CliCheck $n $attrs [lindex $rest $idx]]
            incr idx
        } elseif {!$wantsHelp && [dict exists $attrs required] &&
                  [dict get $attrs required]} {
            Fail CLI usage "missing required argument <$n>"
        }
    }
    if {$idx < [llength $rest]} {
        Fail CLI usage "unexpected argument \"[lindex $rest $idx]\""
    }
    if {$wantsHelp} {
        return $res
    }

    # A required option with no value supplied and no default is missing, not
    # empty -- checked last so the message names the option rather than whatever
    # tripped over the empty string later.
    foreach entry $norm {
        lassign $entry n kind attrs
        if {$kind ne "option"} continue
        if {![dict exists $attrs required] || ![dict get $attrs required]} continue
        if {[dict get $attrs _key] ni $supplied && ![dict exists $attrs default]} {
            Fail CLI usage "missing required option $n"
        }
    }
    return $res
}

::machteld::MetaDefine cli [dict create kind tcl args args domain CLI \
    codes {badvalue usage} doc machteld/command/cli subcommands [dict create \
        parse    [dict create options {} doc machteld/command/cli#parse] \
        usage    [dict create options {} doc machteld/command/cli#usage] \
        duration [dict create options {} doc machteld/command/cli#duration]]]
