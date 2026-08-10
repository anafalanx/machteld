# machteld.tcl -- the machteld prelude.
#
# Sourced by the C host (Machteld_AppInit) from the appended zipfs BEFORE
# Tcl_Main runs a user script or enters the REPL. M0 establishes only the
# namespace, version, and a branded prompt; the command palette
# (run / child / pty / wait / scope / detach and the domain ensembles) lands
# from M1 on.

namespace eval ::machteld {
    variable version 0.3.0
    # MANIFEST is appended to this prelude at build time by tools/genmanifest.tcl,
    # which derives it from src/*.c. Declared empty here so the verb answers
    # something honest in a build where generation was skipped.
    variable MANIFEST {}
}

proc ::machteld::version {} {
    variable version
    return $version
}

# manifest: the palette describing itself ([creed] 4). One dict, no arguments,
# no subcommand vocabulary -- navigate it with `dict get`, which is Tcl the
# reader already knows and which reserves no words this surface would then be
# frozen around.
#
#   dict keys [manifest]                     -> the C verbs
#   dict get [manifest] run options          -> {-cpu -dir -env -mem ...}
#   dict get [manifest] pty subcommands read options   -> -timeout
#   dict get [manifest] child codes          -> what `child` can throw
#
# Every field is DERIVED from the C at build time, so it cannot drift from the
# code it describes -- which is the difference between self-description and a
# second copy of the truth. Prose belongs to `help`, deliberately: a summary is
# authored, and mixing authored text into a generated file is how a generated
# file starts being hand-edited.
# The two halves are derived by two different means, for one reason: C cannot be
# asked about itself at runtime and Tcl can. So the C facts are extracted from
# the source at build time, and the Tcl facts are read out of the live
# interpreter here -- `namespace ensemble configure -map` for a verb the prelude
# extends (pty gains `expect`), `info args` for a plain proc. Neither half is
# hand-maintained, which is the whole point: a hand-kept list is a second copy
# of the truth, and second copies drift.
#
# Internal helpers are excluded by the naming convention this prelude already
# follows: a leading underscore or capital (_dur2ms, PtyCore) means "not
# palette".
proc ::machteld::manifest {} {
    variable MANIFEST
    set m $MANIFEST
    foreach cmd [lsort [info commands ::machteld::*]] {
        set v [namespace tail $cmd]
        if {[string match {[A-Z_]*} $v]} continue
        if {[dict exists $m $v]} {
            # A C verb the prelude re-presents as an ensemble: take the union,
            # so a subcommand added in Tcl is as visible as one written in C.
            if {[namespace ensemble exists $cmd]} {
                set subs [dict get $m $v subcommands]
                set vcodes [dict get $m $v codes]
                foreach {s target} [namespace ensemble configure $cmd -map] {
                    if {![dict exists $subs $s]} { dict set subs $s [dict create options {}] }
                    # A subcommand implemented in Tcl behind a C verb -- `pty
                    # expect` is the case -- carries codes and options of its own.
                    # Reading only the C left the manifest silent about
                    # {MACHTELD PTY timeout}, which `pty expect` genuinely raises:
                    # a subcommand written in the prelude was less visible than
                    # one written in C, in the dict that exists to describe them
                    # both.
                    set t [lindex $target 0]
                    if {![llength [info procs $t]]} continue
                    set f [MtclFacts $t]
                    if {[dict exists $f codes]} { lappend vcodes {*}[dict get $f codes] }
                    if {[dict exists $f options]} {
                        dict set subs $s options [lsort -unique [concat \
                            [dict get $subs $s options] [dict get $f options]]]
                    }
                }
                dict set m $v subcommands $subs
                dict set m $v codes [lsort -unique $vcodes]
            }
            continue
        }
        # KIND IS READ, NOT ASSUMED. A command with no entry used to be called
        # `kind tcl` outright, which made a C verb the build-time generator
        # never saw indistinguishable from a prelude verb -- and that is exactly
        # what happened to `journal`: a C command with six options, described as
        # a Tcl verb with none. If it is not a proc it is C, and a C entry
        # carrying no domain is the generator having missed a file, which the
        # suite fails on rather than publishing.
        set entry [dict create kind [expr {[llength [info procs $cmd]] ? "tcl" : "c"}]]
        if {[llength [info procs $cmd]]} {
            dict set entry args [info args $cmd]
            set entry [dict merge $entry [MtclFacts $cmd]]
        }
        dict set m $v $entry
    }
    return $m
}

# What a Tcl verb declares about itself, read out of its own body.
#
# The C half of the manifest is derived from src/*.c at build time; this is the
# same trick applied to the prelude, and until Phase 0 it did not exist -- a Tcl
# verb reported `kind tcl` plus `info args` and nothing else, so the two verbs
# written in Tcl at the time (`help`, and `wrap`, since retired) had no domain,
# no codes and no options in the very dict whose purpose is describing the
# palette. Tolerable for two verbs; not tolerable for the standard library
# ([stdlib](stdlib.md)), which lands here and would have left creed 4 covering
# barely half the palette.
#
# `info body` is the source rather than a table, so this cannot drift: it reads
# the body of the actual command in the actual interpreter -- including one
# sourced out of the exe's own zipfs, which is how every shipped tool runs.
proc ::machteld::MtclFacts {cmd} {
    set body [info body $cmd]
    set domain ""
    set codes {}

    # The ordinary raiser.
    foreach {_ d c} [regexp -all -inline -- {Fail\s+([A-Z]+)\s+([a-z]+)\s} $body] {
        set domain $d ; lappend codes $c
    }
    # A script literal carrying its own errorcode, evaluated later by uplevel:
    # `pty expect`'s timeout body is built as text and run in the caller's frame,
    # so it cannot call Fail and states its code inline instead. `--` before the
    # pattern because it begins with a dash, and regexp would read it as a switch.
    foreach {_ d c} [regexp -all -inline -- \
            {-errorcode\s+\{MACHTELD\s+([A-Z]+)\s+([a-z]+)\}} $body] {
        set domain $d ; lappend codes $c
    }
    # Internal helpers that raise on the verb's behalf, followed TRANSITIVELY.
    # `cli` delegates spec checking to CliNorm, so a scan of `cli`'s own body
    # declared `usage` and nothing else while the verb could plainly raise
    # `badvalue`. One level fixed that case and was still not enough: `pool` names
    # PoolCreate, which names PoolSpawn, which is where `launch` is raised -- two
    # hops away and therefore invisible, so the manifest under-declared a code the
    # verb really throws. Depth is not a property anyone should have to guess, so
    # this walks to closure with a visited set rather than to a fixed number.
    set helpers {}
    foreach hcmd [info procs ::machteld::*] {
        if {[string match {[A-Z_]*} [namespace tail $hcmd]]} { lappend helpers $hcmd }
    }
    set seen {}
    set frontier [list $body]
    while {[llength $frontier]} {
        set text [lindex $frontier 0]
        set frontier [lrange $frontier 1 end]
        foreach hcmd $helpers {
            set hname [namespace tail $hcmd]
            if {[dict exists $seen $hname]} continue
            # `\\y` doubled on purpose: inside a quoted "\y$hname\y" Tcl collapses
            # the unknown escape to a bare y before the regex engine sees it, so
            # the pattern silently becomes yCliNormy and matches nothing at all.
            if {![regexp \\y$hname\\y $text]} continue
            dict set seen $hname 1
            set hbody [info body $hcmd]
            lappend frontier $hbody
            foreach {_ hd hc} [regexp -all -inline -- {Fail\s+([A-Z]+)\s+([a-z]+)\s} $hbody] {
                if {$domain eq ""} { set domain $hd }
                if {$hd eq $domain} { lappend codes $hc }
            }
        }
    }

    # A shared helper told which domain to raise in: `_dur2ms PTY $v` fails with
    # badvalue, but that literal lives in _dur2ms, not here. The C generator has
    # the same problem with parse_opts and solves it the same way -- follow the
    # call, and attribute what it raises to the verb that made it.
    foreach {_ helper d} [regexp -all -inline -- \
            {(?:::machteld::)?(_[a-z]\w*)\s+([A-Z]+)[\s\]]} $body] {
        set h ::machteld::$helper
        if {![llength [info procs $h]]} continue
        if {$domain eq ""} { set domain $d }
        foreach {_ c} [regexp -all -inline -- {Fail\s+\$\w+\s+([a-z]+)\s} [info body $h]] {
            lappend codes $c
        }
    }

    # Options. A verb may DECLARE its table -- `set opts {...}` -- and that wins
    # outright, including when it is empty. Guessing is only a fallback, because
    # guessing cannot distinguish a verb's own options from option literals it
    # handles on someone else's behalf: `cli` compares against "--help" while
    # parsing a *tool's* argv, and the scanner read that as an option of `cli`.
    set options {}
    if {[regexp -line -- {^\s+set opts \{([^\}]*)\}} $body -> declared]} {
        set options $declared
    } else {
        # The two idioms the prelude uses where nothing is declared: a switch arm,
        # and an equality against a literal. Matching only one is exactly how the
        # C side once under-reported `watch`'s options as none.
        foreach {_ o} [regexp -all -inline -line -- {^\s+(--?[a-z][-a-z0-9]*)\s+\{} $body] {
            lappend options $o
        }
        foreach {_ o} [regexp -all -inline -- {eq\s+"(--?[a-z][-a-z0-9]*)"} $body] {
            lappend options $o
        }
    }

    # Subcommands, declared the way the C declares them. A C verb names its
    # table in `static const char *const subs[]`; a Tcl verb writes
    # `set subs {parse usage}` for exactly the same reason -- so the manifest can
    # read the table rather than anyone keeping a second copy of it in a doc.
    set subcommands {}
    if {[regexp -line -- {^\s+set subs \{([^\}]*)\}} $body -> raw]} {
        foreach sname $raw { dict set subcommands $sname [dict create options {}] }
    }

    set out [dict create]
    if {[dict size $subcommands]} { dict set out subcommands $subcommands }
    if {$domain ne ""}      { dict set out domain $domain }
    if {[llength $codes]}   { dict set out codes [lsort -unique $codes] }
    if {[llength $options]} { dict set out options [lsort -unique $options] }
    return $out
}

# scope { body }: run body, then close (tree-kill) any children started within
# it that are still alive at the closing brace -- bounded lifetime by lexical
# structure. Pure Tcl over the child registry; nests naturally (each scope
# touches only the children born inside it). Runs the cleanup even if body
# throws, and re-raises the body's result/error unchanged.
proc ::machteld::scope {body} {
    set before [::machteld::child list]
    set code [catch {uplevel 1 $body} result options]
    foreach c [::machteld::child list] {
        if {$c ni $before} {
            catch {::machteld::child close $c}
        }
    }
    return -options $options $result
}

# vtstrip: remove ANSI/VT escape sequences from text, so output captured from a
# pseudo-console (pty read) can be matched or displayed as clean text. Strips CSI
# (ESC [ ...), OSC (ESC ] ... BEL/ST), and the common two/one-char ESC sequences
# (charset select, keypad, cursor save/restore). Printable text, newlines, tabs,
# and carriage returns are preserved. ESC/BEL/backslash are built with [format
# %c] and literal brackets are matched with bracket-classes ([[] is a literal
# '['), so the source carries no control characters and no escape ambiguity.
proc ::machteld::vtstrip {s} {
    set E  [format %c 27]  ;# ESC
    set B  [format %c 7]   ;# BEL
    set BS [string repeat [format %c 92] 2]  ;# "\\" -- a regex-literal backslash (ESC-\ ST)
    regsub -all [string cat $E {[[][0-9;?<>=]*[ -/]*[@-~]}] $s {} s
    regsub -all [string cat $E {[]].*?(?:} $B {|} $E $BS {)}] $s {} s
    regsub -all [string cat $E {[()#][0-9A-Za-z]}] $s {} s
    regsub -all [string cat $E {[=>78McDEHM]}] $s {} s
    return $s
}

# Fail: the prelude's raiser, mirroring src/proc.c's mt_error(interp, DOMAIN,
# code, msg). Every Tcl verb fails through it, so `{MACHTELD <DOMAIN> <code>}`
# means the same thing whether the verb was written in C or here.
#
# The prelude used to raise eleven bare `return -code error` with no code at all,
# which put its two verbs of the time (`help`, and `wrap`, since retired) outside
# the error registry entirely -- nothing to document, and nothing a scan could
# find. That was survivable while the prelude held two verbs. It stops being survivable as the standard library lands here,
# which is why this is Phase 0 of [the standard library](stdlib.md) rather than
# a cleanup to get to later.
#
# An error raised inside Fail propagates out through its caller unchanged, so no
# -level games are needed; the only cost is Fail appearing in a stack trace.
proc ::machteld::Fail {domain code msg} {
    return -code error -errorcode [list MACHTELD $domain $code] $msg
}

# _dur2ms: parse a duration with an explicit unit (500ms, 30s, 5m, 2h) to
# milliseconds. Bare numbers are rejected -- the same rule the C option parser
# enforces, so a stray `-timeout 100` can never silently mean "100 seconds".
# Takes the caller's domain, the same way the C option parser does: the domain
# is the verb you invoked, never the helper that happened to fail.
proc ::machteld::_dur2ms {dom d} {
    if {![regexp {^([0-9]+)(ms|s|m|h)$} $d -> n u]} {
        Fail $dom badvalue "bad duration \"$d\": use an explicit unit (500ms, 30s, 5m, 2h)"
    }
    return [expr {$n * [dict get {ms 1 s 1000 m 60000 h 3600000} $u]}]
}

# pty: extend the C core (spawn/send/read/close/list) with a Tcl-level `expect`,
# an interaction loop layered over `pty read`. The C command is renamed aside and
# a namespace ensemble re-presents it as `pty` with the extra subcommand.
if {[info commands ::machteld::pty] ne ""} {
    rename ::machteld::pty ::machteld::PtyCore

    # pty expect $tok ?-timeout dur? {pattern {body} ... ?timeout {body}?}
    # Read from the pseudo-console until the (VT-stripped) accumulated output
    # glob-matches one of the patterns, then run that body in the caller's scope
    # and return its result. If nothing matches before the deadline, run the
    # `timeout` body (default: raise an error). Default deadline 10s.
    proc ::machteld::PtyExpect {tok args} {
        set timeout_ms 10000
        while {[llength $args] > 1 && [string index [lindex $args 0] 0] eq "-"} {
            set opt [lindex $args 0]
            if {$opt eq "-timeout"} {
                set timeout_ms [::machteld::_dur2ms PTY [lindex $args 1]]
                set args [lrange $args 2 end]
            } else {
                Fail PTY usage "pty expect: unknown option \"$opt\""
            }
        }
        if {[llength $args] != 1} {
            Fail PTY usage "usage: pty expect tok ?-timeout dur? {pattern body ...}"
        }
        set pats {}
        set tbody {return -code error -errorcode {MACHTELD PTY timeout} "pty expect: timed out"}
        foreach {pat body} [lindex $args 0] {
            if {$pat eq "timeout"} { set tbody $body } else { lappend pats $pat $body }
        }
        set buf ""
        set deadline [expr {[clock milliseconds] + $timeout_ms}]
        while {1} {
            append buf [::machteld::PtyCore read $tok -timeout 100ms]
            if {$buf ne ""} {
                set clean [::machteld::vtstrip $buf]
                foreach {pat body} $pats {
                    if {[string match $pat $clean]} { return [uplevel 1 $body] }
                }
            }
            if {[clock milliseconds] >= $deadline} { return [uplevel 1 $tbody] }
        }
    }

    # HAND-MAINTAINED, AND THEREFORE A DRIFT HAZARD: a subcommand added to the C
    # is invisible until it is named here too. `pty info` landed in proc.c and
    # this map still had five entries, so the verb existed in the binary and
    # could not be called. The count stayed at six either way -- five core plus
    # `expect` -- so only a set comparison catches it, which is what the manifest
    # test in run_test.tcl does.
    namespace ensemble create -command ::machteld::pty -map {
        spawn  {::machteld::PtyCore spawn}
        send   {::machteld::PtyCore send}
        read   {::machteld::PtyCore read}
        close  {::machteld::PtyCore close}
        list   {::machteld::PtyCore list}
        info   {::machteld::PtyCore info}
        expect ::machteld::PtyExpect
    }
}


# help: machteld ships its own docs -- the OKF bundle rides in the appended zipfs
# at //zipfs:/docs/, so the tool serves its own spec (no external lookup, and an
# agent can load the palette straight from the binary). `help` lists topics,
# `help <topic>` returns that concept file, `help all` returns the whole bundle.
# Returns the text (the REPL prints it; a script can capture it).
proc ::machteld::help {{topic ""}} {
    set docs ""
    foreach _m [dict keys [zipfs mount]] {
        if {[file isdirectory $_m/docs]} { set docs $_m/docs; break }
    }
    if {$docs eq ""} { Fail HELP unsupported "help: this build carries no embedded docs" }
    set files [lsort [glob -nocomplain -tails -directory $docs *.md]]
    if {$topic eq ""} {
        set out "machteld [::machteld::version] -- help <topic>:\n"
        foreach f $files { append out "  [file rootname $f]\n" }
        append out "  all   (the whole bundle)\n"
        return $out
    }
    if {$topic eq "all"} {
        set out ""
        foreach f $files {
            set ch [open [file join $docs $f] r]
            append out [read $ch] "\n\n---\n\n"
            close $ch
        }
        return $out
    }
    set f [file join $docs $topic.md]
    if {![file exists $f]} { Fail HELP notfound "help: no topic \"$topic\" (try: help)" }
    set ch [open $f r]
    set text [read $ch]
    close $ch
    return $text
}

# Expose the palette as bare verbs: unqualified run / child / pty / wait / scope
# / detach / store resolve to ::machteld::* -- so the REPL and scripts read like
# a shell script, the ergonomic point of the design. This uses the global
# namespace's command-resolution path, so Tcl's own commands (found first) are
# never shadowed and nothing is copied.
namespace eval :: { namespace path [concat [namespace path] ::machteld] }

# Tk on demand: a static build ships no Tk DLL, so wire `package require Tk`
# straight to the in-process, statically-linked Tk_Init via `load {} Tk`. Tk is
# not initialized -- and no window is created -- until a script actually asks.
# (The version label tracks the pinned Tcl/Tk payload; `load {} Tk` itself is
# version-agnostic and always loads whatever Tk is linked in.)
package ifneeded Tk 9.0.4 {load {} Tk}

# One-line banner on the first interactive prompt, then a plain branded prompt.
# (tcl_prompt1 is never invoked in non-interactive/script mode, so scripts stay
# silent.)
set ::tcl_prompt1 {
    puts "machteld [::machteld::version] - a Windows machine-control shell (Tcl [info patchlevel])"
    set ::tcl_prompt1 {puts -nonewline "mt % "; flush stdout}
    puts -nonewline "mt % "
    flush stdout
}
