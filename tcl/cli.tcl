# cli.tcl -- ::machteld::cli: declare a tool's arguments once.
#
#   cli parse $argv $spec      -> a dict of values
#   cli usage $spec ?name?     -> the help text, generated from the same spec
#
# machteld is a tool factory, so every program it stamps needs argument parsing,
# and until now every one wrote its own. `changes` and `tasks` each hand-rolled
# it; `tasks` got it wrong badly enough that `tasks --interval` with nothing after
# it set the interval to the empty string, `after ""` threw out of the refresh
# timer, and the tool died at startup. That is the class of bug this removes: not
# because two tools happened to duplicate code, but because argument parsing is
# in every standard library there is (`argparse`, `flag`, `cli`) and machteld had
# no answer at all.
#
# TWO DECISIONS WORTH KNOWING ABOUT.
#
# 1. THIS IS PURE. It prints nothing and never exits. An argparse-style "print
#    usage and exit" is invisible in the place it is most needed: a wrapped GUI
#    exe is started with no standard channels at all, so a tool that reported a
#    bad argument on stdout would report it to nowhere. `tasks` already learned
#    this the hard way. So `--help` comes back as a value in the dict and a bad
#    argument comes back as an error whose message already contains the usage
#    block; the tool decides whether that goes to stderr, a dialog, or a log.
#
# 2. THE SPEC IS A DICT, NOT A MINI-LANGUAGE. `{--interval int 2000..}` would
#    mean inventing syntax to parse, which is the thing rule 1 exists to stop.
#    Each option maps to a dict of attributes, so `min`, `choices` and whatever
#    comes later are ordinary keys rather than new punctuation -- and the spec is
#    itself a Tcl dict, readable with `dict get` like everything else here.
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
        if {$kind eq "positional" && $type eq "flag"} {
            Fail CLI badvalue "cli: \"$name\" is positional and cannot be a flag"
        }
        set key [expr {$kind eq "option" ? [string range $name 2 end] : $name}]
        if {$key eq ""} { Fail CLI badvalue "cli: \"--\" is not an option name" }
        # Still reachable even after the duplicate-key check above: `--dir` and a
        # positional `dir` are distinct dict keys that would land on one result key.
        if {[dict exists $seen $key]} {
            Fail CLI badvalue "cli: \"$name\" collides with another entry on the key \"$key\""
        }
        dict set seen $key 1
        dict set attrs _key $key
        dict set attrs _type $type
        lappend out [list $name $kind $attrs]
    }
    return $out
}

proc ::machteld::CliDefault {attrs} {
    if {[dict exists $attrs default]} { return [dict get $attrs default] }
    if {[dict get $attrs _type] eq "flag"} { return 0 }
    return ""
}

# Check one supplied value against its declared constraints. The message names
# the option and what was expected, because "invalid value" is not a diagnostic.
proc ::machteld::CliCheck {name attrs v} {
    switch -- [dict get $attrs _type] {
        int {
            if {![string is integer -strict $v]} {
                Fail CLI usage "$name needs a whole number, got \"$v\""
            }
            if {[dict exists $attrs min] && $v < [dict get $attrs min]} {
                Fail CLI usage "$name must be at least [dict get $attrs min], got $v"
            }
            if {[dict exists $attrs max] && $v > [dict get $attrs max]} {
                Fail CLI usage "$name must be at most [dict get $attrs max], got $v"
            }
        }
    }
    if {[dict exists $attrs choices]} {
        set ch [dict get $attrs choices]
        if {$v ni $ch} {
            Fail CLI usage "$name must be one of [join $ch {, }], got \"$v\""
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
    if {[llength $opts]} { append line " ?options?" }
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
    if {[llength $opts]} {
        append out "\n\noptions:"
        foreach entry $opts {
            lassign $entry n kind attrs
            set label $n
            if {[dict get $attrs _type] ne "flag"} { append label " <[dict get $attrs _type]>" }
            append out "\n  [format %-22s $label] [CliHelpText $attrs]"
        }
        append out "\n  [format %-22s --help] show this message"
    }
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
    if {[dict exists $attrs default] && [dict get $attrs default] ni {"" 0}} {
        lappend extra "default [dict get $attrs default]"
    }
    if {[llength $extra]} { append t " (" [join $extra {; }] ")" }
    return [string trimleft $t]
}

proc ::machteld::cli {args} {
    # Named here the way the C verbs name theirs, so the manifest can read the
    # subcommand table out of the body instead of anyone maintaining a copy.
    set subs {parse usage duration}
    # And declared empty on purpose. `cli` takes no options of its own -- the
    # `--help` and `--interval` literals below belong to the PROGRAM being parsed,
    # not to this verb, and a scanner cannot tell those two apart by looking. An
    # explicit table beats a guess: without this line the manifest claimed `cli`
    # accepted `--help`, which is precisely the kind of lie it exists to prevent.
    set opts {}
    if {[llength $args] < 1} {
        Fail CLI usage "usage: cli parse argv spec | cli usage spec ?name?"
    }
    set sub [lindex $args 0]
    if {$sub ni $subs} {
        Fail CLI usage "cli: unknown subcommand \"$sub\": must be [join $subs { or }]"
    }

    # THE CONVENTION, MADE AVAILABLE TO THE TOOLS THAT HAVE TO HONOUR IT. Every
    # machteld verb demands an explicit unit on a duration -- `-timeout 100` is
    # refused so it can never silently mean 100 seconds -- and until now nothing
    # exposed the parser that enforces it. So a stamped tool had two choices: a
    # second dialect (`--grace 20`, a bare number, exactly what the palette
    # rejects) or a hand-rolled regexp per tool. `life` and `lifelab` shipped
    # with the first. A toolkit that insists on a convention owes its tools the
    # means to keep it.
    #
    # Deliberately the SAME `_dur2ms` the verbs use, not a copy: two parsers for
    # one syntax is how the tools and the palette would drift apart, and the
    # drift would be silent because both would look right in isolation.
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

    set res {}
    set positional {}
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
            dict set res [dict get $attrs _key] 1
            continue
        }
        # The bug this whole verb exists to prevent: an option whose value is
        # simply absent must be refused here, loudly, and not handed on as an
        # empty string to be discovered three frames later by whatever consumes
        # it. `i+1 == llength` is that case, and so is a following `--option`.
        set nxt [lindex $argv [expr {$i + 1}]]
        if {$i + 1 >= [llength $argv] || ([string match --* $nxt] && $nxt ne "--")} {
            Fail CLI usage "$n needs a value"
        }
        incr i
        dict set res [dict get $attrs _key] [CliCheck $n $attrs $nxt]
    }

    # Positionals, in declaration order, then whatever is left over.
    set idx 0
    foreach entry $positional {
        lassign $entry n kind attrs
        if {$idx < [llength $rest]} {
            dict set res [dict get $attrs _key] [CliCheck $n $attrs [lindex $rest $idx]]
            incr idx
        } elseif {[dict exists $attrs required] && [dict get $attrs required]} {
            Fail CLI usage "missing required argument <$n>"
        }
    }
    if {$idx < [llength $rest]} {
        Fail CLI usage "unexpected argument \"[lindex $rest $idx]\""
    }

    # A required option with no value supplied and no default is missing, not
    # empty -- checked last so the message names the option rather than whatever
    # tripped over the empty string later.
    foreach entry $norm {
        lassign $entry n kind attrs
        if {$kind ne "option"} continue
        if {![dict exists $attrs required] || ![dict get $attrs required]} continue
        if {[dict get $res [dict get $attrs _key]] eq "" && ![dict exists $attrs default]} {
            Fail CLI usage "missing required option $n"
        }
    }
    return $res
}
