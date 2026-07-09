# machteld.tcl -- the machteld prelude.
#
# Sourced by the C host (Machteld_AppInit) from the appended zipfs BEFORE
# Tcl_Main runs a user script or enters the REPL. M0 establishes only the
# namespace, version, and a branded prompt; the command palette
# (run / child / pty / wait / scope / detach and the domain ensembles) lands
# from M1 on.

namespace eval ::machteld {
    variable version 0.2.0
}

proc ::machteld::version {} {
    variable version
    return $version
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

# _dur2ms: parse a duration with an explicit unit (500ms, 30s, 5m, 2h) to
# milliseconds. Bare numbers are rejected -- the same rule the C option parser
# enforces, so a stray `-timeout 100` can never silently mean "100 seconds".
proc ::machteld::_dur2ms {d} {
    if {![regexp {^([0-9]+)(ms|s|m|h)$} $d -> n u]} {
        return -code error "bad duration \"$d\": use an explicit unit (500ms, 30s, 5m, 2h)"
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
                set timeout_ms [::machteld::_dur2ms [lindex $args 1]]
                set args [lrange $args 2 end]
            } else {
                return -code error "pty expect: unknown option \"$opt\""
            }
        }
        if {[llength $args] != 1} {
            return -code error "usage: pty expect tok ?-timeout dur? {pattern body ...}"
        }
        set pats {}
        set tbody {return -code error "pty expect: timed out"}
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

    namespace ensemble create -command ::machteld::pty -map {
        spawn  {::machteld::PtyCore spawn}
        send   {::machteld::PtyCore send}
        read   {::machteld::PtyCore read}
        close  {::machteld::PtyCore close}
        list   {::machteld::PtyCore list}
        expect ::machteld::PtyExpect
    }
}

# wrap: stamp a pure-Tcl/Tk tool into a standalone exe, fully self-contained --
# the Tcl/Tk script libraries, the prelude, and BOTH basekits (console + GUI) ride
# inside this machteld.exe, so no external toolchain or payload is needed. Zero
# compiler (pure zipfs, the els/starpack overlay). Named `wrap`, not `package`,
# because Tcl core owns the command `package`. Sign the result: append-then-sign.
#   wrap <tooldir> -o <out.exe> ?--gui|--console? ?--no-prelude?
# <tooldir> must contain main.tcl (the tool's entry, auto-run by AppHook).
proc ::machteld::_copy_tree {src dst} {
    file mkdir $dst
    foreach item [glob -nocomplain [file join $src *]] {
        set target [file join $dst [file tail $item]]
        if {[file isdirectory $item]} {
            ::machteld::_copy_tree $item $target
        } else {
            file copy -force $item $target
        }
    }
}
proc ::machteld::_zip_entries {root {rel ""}} {
    set out {}
    foreach item [glob -nocomplain [file join $root $rel *]] {
        set name [file tail $item]
        set zrel [expr {$rel eq "" ? $name : [file join $rel $name]}]
        if {[file isdirectory $item]} {
            lappend out {*}[::machteld::_zip_entries $root $zrel]
        } else {
            lappend out $item [string map {\\ /} $zrel]
        }
    }
    return $out
}
proc ::machteld::wrap {args} {
    set gui 0; set out ""; set with_prelude 1; set tool ""
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        switch -- $a {
            --gui        { set gui 1 }
            --console    { set gui 0 }
            --no-prelude { set with_prelude 0 }
            -o           { incr i; set out [lindex $args $i] }
            default {
                if {$tool eq ""} {
                    set tool $a
                } else {
                    return -code error "wrap: unexpected argument \"$a\""
                }
            }
        }
    }
    if {$tool eq "" || $out eq ""} {
        return -code error "usage: wrap <tooldir> -o <out.exe> ?--gui|--console? ?--no-prelude?"
    }
    if {![file exists [file join $tool main.tcl]]} {
        return -code error "wrap: \"$tool\" has no main.tcl (the tool's entry point)"
    }
    # Locate our own mounted payload (the Tcl/Tk libs + the embedded basekits).
    set root ""
    foreach _m [dict keys [zipfs mount]] {
        if {[file isdirectory $_m/tcl_library] && [file isdirectory $_m/basekit]} {
            set root $_m; break
        }
    }
    if {$root eq ""} {
        return -code error "wrap: this machteld carries no embedded payload (run the packaged machteld.exe)"
    }
    set bare [file join $root basekit [expr {$gui ? {gui.exe} : {console.exe}}]]
    if {![file exists $bare]} { return -code error "wrap: basekit not embedded: $bare" }

    set work [file tempdir]
    try {
        set stage [file join $work stage]
        file mkdir $stage
        ::machteld::_copy_tree [file join $root tcl_library] [file join $stage tcl_library]
        ::machteld::_copy_tree [file join $root tk_library]  [file join $stage tk_library]
        if {$with_prelude && [file exists [file join $root machteld.tcl]]} {
            file copy -force [file join $root machteld.tcl] [file join $stage machteld.tcl]
        }
        ::machteld::_copy_tree $tool $stage
        set tmpbare [file join $work bare.exe]
        file copy -force $bare $tmpbare
        file delete -force $out
        zipfs lmkimg $out [::machteld::_zip_entries $stage] {} $tmpbare
    } finally {
        catch {file delete -force $work}
    }
    return $out
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
package ifneeded Tk 9.0.3 {load {} Tk}

# One-line banner on the first interactive prompt, then a plain branded prompt.
# (tcl_prompt1 is never invoked in non-interactive/script mode, so scripts stay
# silent.)
set ::tcl_prompt1 {
    puts "machteld [::machteld::version] - a Windows machine-control shell (Tcl [info patchlevel])"
    set ::tcl_prompt1 {puts -nonewline "mt % "; flush stdout}
    puts -nonewline "mt % "
    flush stdout
}
