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

# WHICH C FUNCTION IMPLEMENTS WHICH VERB IS DERIVED TOO -- see the scan below
# `functions`. It was a hand-kept table here until 2026-08-10, sitting beside a
# hand-kept list of source files, under a comment claiming it was the one
# mapping the scanner could not derive. It was derivable all along:
# Tcl_CreateObjCommand names the command and the function on the SAME LINE, and
# the block that followed already read the verb names out of exactly that call
# -- and then threw them away, unused.
#
# `journal` is what the two lists cost. journal.c compiled, linked and ran, and
# neither list named it, so the manifest never saw the verb: `manifest` fell
# through to `kind tcl` with no domain, no codes, and none of its six options.
# That is the same under-reporting the unattributed-option check at the bottom
# of this file exists to prevent, reached by a road no check watched -- and it
# surfaced only because a doc happened to mention an option, three steps away.

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

# ---- the sources, and the verbs they register ------------------------------
# EVERY .c IN THE DIRECTORY, not a list. A file that registers no
# ::machteld:: command contributes no verb and costs nothing to read, so
# `glob` cannot under-report the way a list can.
set FILETEXT {}   ;# path -> its text
set FILEFNS  {}   ;# path -> {function body ...}, indexed per file
set VERBSOF  {}   ;# path -> the verbs that file registers
set REG      {}   ;# verb -> the file that registers it
set IMPL     {}   ;# C function -> verb
foreach path [lsort [glob -directory $SRC *.c]] {
    set text [slurp $path]
    dict set FILETEXT $path $text
    dict set FILEFNS  $path [functions $text]
    foreach {_ v fn} [regexp -all -inline \
            {Tcl_CreateObjCommand\(interp,\s*"::machteld::(\w+)",\s*(\w+)} $text] {
        dict set REG $v $path
        dict lappend VERBSOF $path $v
        dict set IMPL $fn $v
    }
}
if {![dict size $IMPL]} { error "genmanifest: no ::machteld:: commands found under $SRC" }

proc srcfile {name} {
    global FILETEXT
    foreach p [dict keys $FILETEXT] { if {[file tail $p] eq $name} { return $p } }
    error "genmanifest: there is no $name under the source directory"
}

# FUNCTIONS ARE INDEXED PER FILE, not merged into one flat namespace: store.c
# and journal.c both define a static `fail_code`, and one index would let either
# file's helper answer for the other file's verb. Attribution follows the
# compiler's own rule -- a static function belongs to its translation unit.
#
# A file that registers EXACTLY ONE verb is that verb's body in full, because
# a whole-file body is the only way to see what the dispatcher does not hold:
# `notopen` is raised in store.c's needDb and journal.c's need_db, neither of
# which is the dispatcher. Its individual functions are indexed as well, so
# attribution can still follow a helper called from one branch -- `hash`'s
# -binary lives in `want_binary`, defined above the dispatcher and therefore
# outside every `idx ==` region.
proc verb_body {verb} {
    global REG FILETEXT FILEFNS VERBSOF IMPL
    set path [dict get $REG $verb]
    if {[llength [dict get $VERBSOF $path]] == 1} { return [dict get $FILETEXT $path] }
    set fns [dict get $FILEFNS $path]
    foreach {fn v} $IMPL {
        if {$v eq $verb && [dict exists $fns $fn]} { return [dict get $fns $fn] }
    }
    error "genmanifest: $verb is registered in [file tail $path] but its\
           implementation was not found -- see `functions`"
}
proc verb_fns {verb} {
    global REG FILEFNS
    return [dict get $FILEFNS [dict get $REG $verb]]
}

# proc.c by name, and only here: the shared option parser and the codes that
# travel in a variable are facts about THAT file, not about the palette.
set proc_c [dict get $FILETEXT [srcfile proc.c]]
set fns    [dict get $FILEFNS  [srcfile proc.c]]

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
    set body [verb_body $verb]
    set vfns [verb_fns $verb]

    # domain: whatever this body passes to mt_error / fail_code / fail
    set domain ""
    if {[regexp {mt_error\(interp,\s*"([A-Z]+)"} $body -> d]} { set domain $d }
    # The raw form, for a file with no error helper of its own -- and the form
    # every single-domain file ends at, since its raiser spells the domain once.
    # There used to be a third rule here: "a body calling fail_code is STORE".
    # It was dead the day it was written (store.c spells STORE in the line
    # above) and it was a trap for the next file, which was journal.c -- whose
    # raiser is also called fail_code and whose domain is not STORE.
    if {$domain eq "" &&
        [regexp {Tcl_SetErrorCode\(interp,\s*"MACHTELD",\s*"([A-Z]+)"} $body -> d]} { set domain $d }

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
    dict set entry options [opts_in $body $shared_opts $vfns]
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
    if {![dict exists $manifest $verb]} {
        error "genmanifest: $verb is registered in C but no entry was derived for it"
    }
    set entry [dict get $manifest $verb]
    set declared {}
    if {[dict exists $entry options]} { set declared [dict get $entry options] }
    if {[dict exists $entry subcommands]} {
        dict for {_ sm} [dict get $entry subcommands] {
            if {[dict exists $sm options]} { set declared [concat $declared [dict get $sm options]] }
        }
    }
    set found [opts_in [verb_body $verb] $shared_opts [verb_fns $verb]]
    foreach o $found {
        if {$o ni $declared} {
            error "genmanifest: $verb accepts $o but the manifest does not declare it"
        }
    }
    if {[dict get $entry domain] eq ""} {
        error "genmanifest: $verb declares no domain -- every palette verb raises in one"
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

# A SINGLE-VERB FILE NAMES ITS RESULT BUILDER AFTER ITS VERB: `dirs` answers with
# the dict built by `dirs_dict`. That is a naming CONVENTION, stated here because
# here is where it is read -- rename the function and this derivation stops
# seeing it. It is not free-floating taste: the closure walk below is the same
# one `child_dict` gets, and without it a data verb whose dict the manifest
# cannot describe is creed 4 decaying by one verb per verb.
#
# TWO RULES FOR THE NEXT SINGLE-VERB FILE, both of which the derivation depends
# on and neither of which the compiler enforces:
#   - build the result dict with LITERAL Tcl_NewStringObj("key", -1) calls
#     inside <verb>_dict; routing them through a dict_put_str(d, k, v) helper
#     (ps.c:61) hides the literal and derives an empty shape;
#   - do not call the row builders FROM <verb>_dict. The closure follows callees,
#     so a row builder's own keys -- `path`, `tag`, `reason` -- would be published
#     as phantom keys of the top-level result.
# The `error` below is the same one the child_dict block ends with, for the same
# reason it gives: a derivation that reports nothing when the code moves is worse
# than one that reports nothing at all, because it looks like an answer.
foreach {fn verb} $IMPL {
    if {[dict exists $manifest $verb returns]} continue
    set vfns [verb_fns $verb]
    if {![dict exists $vfns ${verb}_dict]} continue
    set keys {} ; set todo [list ${verb}_dict] ; set seen {}
    while {[llength $todo]} {
        set f [lindex $todo 0] ; set todo [lrange $todo 1 end]
        if {$f in $seen || ![dict exists $vfns $f]} continue
        lappend seen $f
        set b [dict get $vfns $f]
        foreach {_ k} [regexp -all -inline {Tcl_NewStringObj\("(\w+)", *-1\)} $b] { lappend keys $k }
        foreach {_ callee} [regexp -all -inline {(\w+)\s*\(} $b] {
            if {[dict exists $vfns $callee]} { lappend todo $callee }
        }
    }
    if {![llength $keys]} {
        error "genmanifest: derived an empty result shape from ${verb}_dict"
    }
    dict set manifest $verb returns [lsort -unique $keys]
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
