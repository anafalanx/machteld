# genmanifest.tcl -- derive the palette manifest FROM THE C SOURCE.
#
#   tclsh90s tools/genmanifest.tcl <srcdir> <out.tcl>
#
# Creed 4 says the palette describes itself and that docs are generated *from*
# the truth, not maintained beside it. The truth about the C verbs is the C:
# which subcommands Tcl_GetIndexFromObj will accept, which options the parser
# compares against, which error codes reach Tcl_SetErrorCode. So this reads them
# out of src/*.c and writes a Tcl dict -- nobody hand-maintains a second copy,
# and drift is impossible rather than merely detectable.
#
# Deliberately NOT here: prose. A summary or an example is authored, not
# derived, and mixing the two in one generated file is how a generated file
# starts being hand-edited. Prose lives in the docs bundle (`help`); this
# carries only what the compiler would agree with.

if {[llength $argv] != 2} {
    puts stderr "usage: genmanifest.tcl <srcdir> <out.tcl>"
    exit 2
}
lassign $argv SRC OUT

proc slurp {path} {
    set f [open $path r]
    fconfigure $f -translation lf
    set t [read $f]
    close $f
    return $t
}

# Which C function implements which palette verb. This is the one mapping the
# scanner cannot derive (a function name is not a command name); everything else
# below is read out of the source. Tcl_CreateObjCommand tells us the verb names,
# and this says which body to attribute facts to.
set IMPL {
    RunCmd    run
    ChildCmd  child
    WaitCmd   wait
    DetachCmd detach
    PtyCmd    pty
    StoreCmd  store
}

# NOTE ON TCL REGEXPS HERE: Tcl's ARE takes its greediness for the WHOLE
# expression from the FIRST quantifier, so a leading `\s*` makes a later `.*?`
# behave greedily -- which silently swallowed each subs[] array's closing brace
# and pulled in every quoted string that followed. Every span match below is
# therefore written with a negated character class, which cannot over-reach.

# Split a C file into {function body} pairs, so every fact can be attributed to
# the verb whose body holds it. Bodies are delimited by a top-level closing
# brace in column 0, which is this codebase's own layout.
proc functions {text} {
    set out {}
    set cur ""
    set buf {}
    foreach line [split $text \n] {
        if {[regexp {^static\s+(?:\w+)\s*\*?\s*(\w+)\s*\(} $line -> name]} {
            if {$cur ne ""} { dict set out $cur [join $buf \n] }
            set cur $name
            set buf {}
        }
        lappend buf $line
        if {$line eq "\}" && $cur ne ""} {
            dict set out $cur [join $buf \n]
            set cur ""
            set buf {}
        }
    }
    if {$cur ne ""} { dict set out $cur [join $buf \n] }
    return $out
}

set proc_c  [slurp [file join $SRC proc.c]]
set store_c [slurp [file join $SRC store.c]]
set fns     [functions $proc_c]
# store.c implements exactly one verb, so the whole file is that verb's body --
# otherwise `notopen`, which is raised in the needDb helper rather than in
# StoreCmd, would be invisible to a per-function scan.
dict set fns StoreCmd $store_c

# ---- verbs the C actually registers ---------------------------------------
set verbs {}
foreach t [list $proc_c $store_c] {
    foreach {_ v} [regexp -all -inline {Tcl_CreateObjCommand\(interp,\s*"::machteld::(\w+)"} $t] {
        lappend verbs $v
    }
}

# ---- the shared option parser, and which verbs reach it --------------------
# parse_opts serves four verbs; each passes its own domain, so the call sites
# say which verbs own these options without anyone asserting it.
set shared_opts {}
if {[dict exists $fns parse_opts]} {
    foreach {_ o} [regexp -all -inline {strcmp\(a, "(-\w+)"\)} [dict get $fns parse_opts]] {
        lappend shared_opts $o
    }
}
set shared_domains {}
foreach {_ d} [regexp -all -inline {parse_opts\(interp,\s*"([A-Z]+)"} $proc_c] {
    lappend shared_domains $d
}

# ---- per-verb facts --------------------------------------------------------
# Codes that travel in a VARIABLE rather than a literal: child_launch and
# pty_spawn report which failure they had through *code, seeded by the caller.
# A literal-only scan would miss `launch` and `notfound` at three call sites.
set var_codes {}
foreach {_ c} [regexp -all -inline {code = "(\w+)"} $proc_c] { lappend var_codes $c }
set var_codes [lsort -unique $var_codes]

# Options a region of C accepts: the shared parser's set if it calls parse_opts,
# plus any comparison it makes itself (wait's -any, pty read's -timeout).
proc opts_in {region shared} {
    set out {}
    if {[regexp {parse_opts\(interp,} $region]} { set out $shared }
    foreach {_ o} [regexp -all -inline {strcmp\(Tcl_GetString\(objv\[[^\]]*\]\),\s*"(-\w+)"\)} $region] {
        lappend out $o
    }
    return [lsort -unique $out]
}

set manifest {}
foreach {fn verb} $IMPL {
    if {![dict exists $fns $fn]} { continue }
    set body [dict get $fns $fn]

    # domain: whatever this body passes to mt_error / fail_code / fail
    set domain ""
    if {[regexp {mt_error\(interp,\s*"([A-Z]+)"} $body -> d]} { set domain $d }
    if {$domain eq "" && [regexp {fail(_code)?\(interp,} $body]} { set domain STORE }

    # subcommands: the Tcl_GetIndexFromObj table. A negated class, not `.*?` --
    # see the greediness note above.
    set subs {}
    set enums {}
    if {[regexp {static const char \*const subs\[\]\s*=\s*\{([^\}]*)\}} $body -> raw]} {
        foreach {_ s} [regexp -all -inline {"(\w+)"} $raw] { lappend subs $s }
    }
    # The parallel enum names the branches, so an option found in a branch can be
    # attributed to the right SUBCOMMAND rather than smeared across the verb --
    # `pty send` does not take -mem, and saying so would be a lie.
    if {[regexp {enum\s*\{([^\}]*)\}} $body -> raw]} {
        foreach e [split $raw ,] {
            set e [string trim $e]
            if {$e ne ""} { lappend enums $e }
        }
    }

    set codes {}
    foreach {_ c} [regexp -all -inline {mt_error\(interp,\s*"[A-Z]+",\s*"(\w+)"} $body] { lappend codes $c }
    foreach {_ c} [regexp -all -inline {fail_code\(interp,\s*"(\w+)"} $body] { lappend codes $c }
    if {[regexp {\Wfail\(interp,} $body]} { lappend codes sqlite }
    if {[regexp {mt_error\(interp,\s*"[A-Z]+",\s*code,} $body]} { lappend codes {*}$var_codes }
    if {$domain ne "" && $domain in $shared_domains} {
        foreach {_ c} [regexp -all -inline {mt_error\(interp,\s*dom,\s*"(\w+)"} [dict get $fns parse_opts]] {
            lappend codes $c
        }
    }

    set entry [dict create kind c domain $domain codes [lsort -unique $codes]]

    if {[llength $subs] == 0} {
        dict set entry options [opts_in $body $shared_opts]
    } else {
        # Split the body at each branch marker (`idx == NAME` or `case NAME:`)
        # and attribute what follows to that subcommand.
        set marks {}
        foreach {_ nm} [regexp -all -inline -indices {idx == (\w+)} $body] { }
        set positions {}
        foreach pat {{idx == (\w+)} {case (\w+):}} {
            set start 0
            while {[regexp -start $start -indices $pat $body whole name]} {
                lappend positions [list [lindex $whole 0] [string range $body {*}$name]]
                set start [expr {[lindex $whole 1] + 1}]
            }
        }
        set positions [lsort -integer -index 0 $positions]
        set submap {}
        for {set i 0} {$i < [llength $positions]} {incr i} {
            lassign [lindex $positions $i] pos name
            set end [expr {$i + 1 < [llength $positions]
                           ? [lindex [lindex $positions [expr {$i+1}]] 0] - 1 : "end"}]
            set region [string range $body $pos $end]
            set idx [lsearch -exact $enums $name]
            if {$idx < 0 || $idx >= [llength $subs]} { continue }
            set sub [lindex $subs $idx]
            set o [opts_in $region $shared_opts]
            if {$o ne ""} { dict set submap $sub [lsort -unique [concat [expr {[dict exists $submap $sub] ? [dict get $submap $sub] : {}}] $o]] }
        }
        set subdict {}
        foreach s $subs {
            dict set subdict $s [dict create options \
                [expr {[dict exists $submap $s] ? [dict get $submap $s] : {}}]]
        }
        dict set entry subcommands $subdict
    }
    dict set manifest $verb $entry
}

# ---- result shapes ---------------------------------------------------------
# One shared builder produces the dict `run` and `child wait` both answer with.
if {[dict exists $fns child_dict]} {
    set keys {}
    foreach {_ k} [regexp -all -inline {Tcl_NewStringObj\("(\w+)", *-1\)} [dict get $fns child_dict]] {
        lappend keys $k
    }
    set keys [lsort -unique $keys]
    foreach v {run child} {
        if {[dict exists $manifest $v]} { dict set manifest $v returns $keys }
    }
}

# ---- emit ------------------------------------------------------------------
set f [open $OUT w]
fconfigure $f -translation lf
puts $f "# GENERATED by tools/genmanifest.tcl from src/*.c -- do not edit."
puts $f "# Creed 4: the palette describes itself, and the description is derived,"
puts $f "# so it cannot disagree with the code it describes."
puts $f "set ::machteld::MANIFEST \{"
foreach v [lsort [dict keys $manifest]] {
    puts $f "    [list $v] [list [dict get $manifest $v]]"
}
puts $f "\}"
close $f

puts "genmanifest: [dict size $manifest] verbs -> [file nativename $OUT]"
foreach v [lsort [dict keys $manifest]] {
    set d [dict get $manifest $v]
    set nsub [expr {[dict exists $d subcommands] ? [dict size [dict get $d subcommands]] : 0}]
    set nopt [expr {[dict exists $d options] ? [llength [dict get $d options]] : 0}]
    puts [format "  %-8s domain=%-7s subs=%-2d opts=%-2d codes=%d" \
        $v [dict get $d domain] $nsub $nopt [llength [dict get $d codes]]]
}
