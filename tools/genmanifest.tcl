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
    WatchCmd  watch
    StoreCmd  store
    JsonCmd   json
    PsCmd     ps
    HashCmd   hash
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
set json_c  [slurp [file join $SRC json.c]]
set ps_c    [slurp [file join $SRC ps.c]]
set hash_c  [slurp [file join $SRC hash.c]]
set fns     [functions $proc_c]
# store.c and json.c implement exactly one verb each, so the whole file is that
# verb's body -- otherwise `notopen`, raised in the needDb helper rather than in
# StoreCmd, would be invisible to a per-function scan.
#
# Their individual functions are ALSO indexed, because a whole-file body has no
# structure to follow: `hash`'s -binary lives in the helper `want_binary`, which
# is defined ABOVE the dispatcher and therefore sits outside every `idx ==`
# region. Indexed as a function, it can be followed from the branch that calls
# it; left as anonymous file text, it is invisible to attribution and the option
# is lost. Merged UNDER the whole-file entries so those still win for the verb.
set fns [dict merge [functions $store_c] [functions $json_c] \
                    [functions $ps_c] [functions $hash_c] $fns]
dict set fns StoreCmd $store_c
dict set fns JsonCmd  $json_c
dict set fns PsCmd    $ps_c
dict set fns HashCmd  $hash_c

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
proc opts_in {region shared {fns {}}} {
    set out {}
    if {[regexp {parse_opts\(interp,} $region]} { set out $shared }
    # FOLLOW THE HELPERS, to closure. An option is wherever the code happens to
    # test for it, and that is not always the verb's own body: `hash`'s -binary
    # lives in `want_binary()`, a helper called from three subcommands, and a
    # scan of the dispatcher alone reported hash as taking no options at all --
    # while the palette documented -binary and the binary accepted it. Same
    # shape as the result-shape scanner following `child_dict` to
    # `child_dict_ex`: derivation must go where the code went.
    set todo {} ; set seen {}
    foreach {_ callee} [regexp -all -inline {(\w+)\s*\(} $region] {
        if {[dict exists $fns $callee]} { lappend todo $callee }
    }
    while {[llength $todo]} {
        set f [lindex $todo 0] ; set todo [lrange $todo 1 end]
        if {$f in $seen} continue
        lappend seen $f
        set body [dict get $fns $f]
        append region "\n" $body
        foreach {_ callee} [regexp -all -inline {(\w+)\s*\(} $body] {
            if {[dict exists $fns $callee] && $callee ni $seen} { lappend todo $callee }
        }
    }
    # Any strcmp against a "-something" literal is an option check, whichever
    # way the argument got there: some sites compare Tcl_GetString(objv[i])
    # directly, others hoist it into a local first. Matching only the first
    # idiom made the manifest under-report watch's options as none -- a
    # manifest that omits a real option is the exact lie it exists to prevent,
    # so the match is on the literal, not on how the argument is spelled.
    foreach {_ o} [regexp -all -inline {strcmp\([^,]+,\s*"(-\w+)"\)} $region] {
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
    # The raw form, for a file with no error helper of its own.
    if {$domain eq "" &&
        [regexp {Tcl_SetErrorCode\(interp,\s*"MACHTELD",\s*"([A-Z]+)"} $body -> d]} { set domain $d }
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
    foreach {_ c} [regexp -all -inline \
        {Tcl_SetErrorCode\(interp,\s*"MACHTELD",\s*"[A-Z]+",\s*"(\w+)"} $body] { lappend codes $c }
    # A file with a single domain spells that domain once, inside its own
    # raiser, and passes only the code: ps_error(interp, "denied", msg). A
    # multi-domain file's raiser takes the domain first: mt_error(interp, "RUN",
    # "notfound", msg). Case tells the two apart -- a domain is uppercase, a code
    # never is -- so both idioms are read without naming either helper here.
    # Without this, ps declared zero codes while raising five, and the registry
    # closure test in run_test.tcl had nothing to check those five against.
    foreach {_ c} [regexp -all -inline {\w+_error\(interp,\s*"([a-z]\w*)"} $body] { lappend codes $c }
    if {[regexp {\Wfail\(interp,} $body]} { lappend codes sqlite }
    if {[regexp {mt_error\(interp,\s*"[A-Z]+",\s*code,} $body]} { lappend codes {*}$var_codes }
    if {$domain ne "" && $domain in $shared_domains} {
        foreach {_ c} [regexp -all -inline {mt_error\(interp,\s*dom,\s*"(\w+)"} [dict get $fns parse_opts]] {
            lappend codes $c
        }
    }

    set entry [dict create kind c domain $domain codes [lsort -unique $codes]]

    # THE VERB-LEVEL SET IS THE ONE THAT IS GUARANTEED: every option this verb
    # accepts anywhere, helpers included. It is always published, even for verbs
    # with subcommands, because it is the only claim the derivation can actually
    # stand behind.
    dict set entry options [opts_in $body $shared_opts $fns]
    if {[llength $subs] != 0} {
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
        # MARKERS THAT SHARE A GUARD SHARE ITS BLOCK. `if (idx == SUM || idx ==
        # FILE_ || idx == HMAC || idx == START)` is four markers on one line, and
        # "each marker's region runs to the next marker" gave the first three a
        # region of zero characters. So the block those four subcommands share
        # was attributed to the last of them alone -- and `hash`'s -binary, which
        # is reached through a helper called inside it, landed nowhere at all.
        # Markers glued by `||` with no brace between them are one guard.
        set groups {}
        set i 0
        while {$i < [llength $positions]} {
            set startpos [lindex [lindex $positions $i] 0]
            set names [list [lindex [lindex $positions $i] 1]]
            while {$i + 1 < [llength $positions]} {
                set glue [string range $body [lindex [lindex $positions $i] 0] \
                              [expr {[lindex [lindex $positions [expr {$i + 1}]] 0] - 1}]]
                if {![string match {*||*} $glue] || [string first "\{" $glue] >= 0} break
                incr i
                lappend names [lindex [lindex $positions $i] 1]
            }
            lappend groups [list $startpos $names]
            incr i
        }
        set submap {}
        for {set g 0} {$g < [llength $groups]} {incr g} {
            lassign [lindex $groups $g] pos names
            set end [expr {$g + 1 < [llength $groups]
                           ? [lindex [lindex $groups [expr {$g + 1}]] 0] - 1 : "end"}]
            # NO HELPER FOLLOWING HERE, deliberately. An option tested inside
            # the branch belongs to that branch; one reached through a helper
            # called from a block several subcommands share cannot be pinned to
            # any of them by reading the text. Following helpers here produced a
            # precise-looking manifest that said `hash update` takes -binary
            # (it does not) and `hash file` does not (it does). Where attribution
            # is not derivable the union above is the honest answer, and a
            # confident wrong answer is the failure this file exists to prevent.
            set o [opts_in [string range $body $pos $end] $shared_opts {}]
            if {$o eq ""} continue
            foreach name $names {
                set idx [lsearch -exact $enums $name]
                if {$idx < 0 || $idx >= [llength $subs]} { continue }
                set sub [lindex $subs $idx]
                dict set submap $sub [lsort -unique [concat \
                    [expr {[dict exists $submap $sub] ? [dict get $submap $sub] : {}}] $o]]
            }
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

# ---- nothing may go unattributed -------------------------------------------
# Every `-option` literal a verb's code tests for must end up declared SOMEWHERE
# in that verb's entry -- at verb level or under a subcommand. Under-reporting is
# the one failure this generator exists to prevent, and it has now happened
# twice quietly: `hash -binary` lived in a helper nobody followed, and json's
# `-dict`/`-list` were attributed to the wrong subcommand because the encode
# branch had no marker. Both produced a manifest that looked plausible and was
# wrong. A generator that cannot see something must SAY so, not omit it.
foreach {fn verb} $IMPL {
    if {![dict exists $fns $fn] || ![dict exists $manifest $verb]} { continue }
    set entry [dict get $manifest $verb]
    set declared {}
    if {[dict exists $entry options]} { set declared [dict get $entry options] }
    if {[dict exists $entry subcommands]} {
        dict for {_ sm} [dict get $entry subcommands] {
            if {[dict exists $sm options]} { set declared [concat $declared [dict get $sm options]] }
        }
    }
    set found [opts_in [dict get $fns $fn] $shared_opts $fns]
    foreach o $found {
        if {$o ni $declared} {
            error "genmanifest: $verb accepts $o but the manifest does not declare it"
        }
    }
}

# ---- result shapes ---------------------------------------------------------
# One shared builder produces the dict `run` and `child wait` both answer with.
if {[dict exists $fns child_dict]} {
    # FOLLOW THE DELEGATION, to closure. The keys live in whichever function
    # actually calls Tcl_DictObjPut, and that moved: `child_dict` became a
    # one-line wrapper over `child_dict_ex` the moment `child wait` gained a
    # "still running" answer. Matching one hardcoded name, this scanner derived
    # an EMPTY result shape and the manifest quietly claimed `run` returns
    # nothing -- caught only because a separate test compares the manifest to a
    # real call. A derivation that reports nothing when the code moves is worse
    # than one that reports nothing at all, because it looks like an answer.
    set keys {} ; set todo [list child_dict] ; set seen {}
    while {[llength $todo]} {
        set f [lindex $todo 0] ; set todo [lrange $todo 1 end]
        if {$f in $seen || ![dict exists $fns $f]} continue
        lappend seen $f
        set body [dict get $fns $f]
        foreach {_ k} [regexp -all -inline {Tcl_NewStringObj\("(\w+)", *-1\)} $body] {
            lappend keys $k
        }
        # Anything it calls that is also defined in this source tree.
        foreach {_ callee} [regexp -all -inline {(\w+)\s*\(} $body] {
            if {[dict exists $fns $callee]} { lappend todo $callee }
        }
    }
    set keys [lsort -unique $keys]
    if {![llength $keys]} { error "genmanifest: derived an empty result shape from child_dict" }
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
