# machteld.tcl -- the machteld prelude.
#
# Sourced by the C host (Machteld_AppInit) from the appended zipfs BEFORE
# Tcl_Main runs a user script or enters the REPL. M0 establishes only the
# namespace, version, and a branded prompt; the command palette
# (run / child / pty / wait / scope / detach and the domain ensembles) lands
# from M1 on.

namespace eval ::machteld {
    variable version 0.1.0-m1
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
