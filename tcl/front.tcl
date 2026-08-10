# front.tcl -- ::machteld::front: machteld as the front door to a workspace.
#
#   front roots                ;# where the workspace is, and how it was found
#   front which rg             ;# the executable a name resolves to
#   front env rg               ;# exe, args, env, cwd -- everything, as a dict
#   front env rg -json         ;# the same, on the wire
#   front tools ?pattern?      ;# what the workspace curates
#
# THE FRONT DOOR'S ONE JOB is to turn a name into something runnable under a
# controlled environment: an executable, its arguments, the variables it should
# see, and the directory it should start in. Everything else a workspace director
# does is built on that, and it is precisely what `run` and `child` were written
# for -- which is why this is a page of Tcl rather than a program.
#
# RESOLUTION IS THE MANIFEST'S, NOT THIS FILE'S. `.z/manifest.json` already
# describes 273 curated tools, each with a `exeFromRoot`, the directories it needs
# on PATH, and its own environment overlay. That file is maintained by the
# workspace, so this reads it rather than keeping a second inventory: while both
# front doors exist they must not be able to disagree, and the cheapest way to
# guarantee that is to have one source.
#
# NO SYSTEM-PATH FALLBACK, EVER. A name that the workspace does not curate does
# not resolve. That is the property that makes the workspace portable -- what runs
# is what was vendored, not what happens to be installed on the machine -- and it
# is the one rule here worth breaking a caller over.
#
# Read-only, deliberately. Nothing in this file spawns anything; that is the next
# step. Resolution can therefore be checked against the live `z` for agreement
# before anything depends on it.

namespace eval ::machteld {
    variable FRONT_ROOT ""      ;# MT_ROOT -- the workspace, where the exe lives
    variable FRONT_HOME ""      ;# MT_HOME -- its private system directory
    variable FRONT_DIR  ""      ;# which one was found: .mt, or .z during the change
    variable FRONT_MAN  ""      ;# the parsed manifest, read once

    # The workspace's private directory is `.mt`. `.z` is the one the Go front
    # door still owns, and it is searched second so this can read the LIVE
    # workspace and be checked against `z` for agreement before anything depends
    # on it. When `.mt` exists it wins, and the day `.z` is gone this list loses
    # its second entry rather than growing a flag.
    variable FRONT_DIRS {.mt .z}
}

# WHERE THE WORKSPACE IS. Found from the EXECUTABLE, not the working directory: a
# front door is wherever it was installed, and `cd` must not be able to move the
# workspace out from under a running command. An inherited Z_ROOT/Z_HOME wins, so
# a tool that re-enters the front door lands in the same workspace rather than
# rediscovering one.
proc ::machteld::FrontRoots {} {
    variable FRONT_ROOT ; variable FRONT_HOME
    if {$FRONT_ROOT ne ""} { return }
    variable FRONT_DIR ; variable FRONT_DIRS
    foreach {rv hv} {MT_ROOT MT_HOME Z_ROOT Z_HOME} {
        if {[info exists ::env($rv)] && [info exists ::env($hv)]
            && [file isdirectory $::env($hv)]} {
            set FRONT_ROOT [file normalize $::env($rv)]
            set FRONT_HOME [file normalize $::env($hv)]
            set FRONT_DIR  [file tail $FRONT_HOME]
            return
        }
    }
    set d [file dirname [file normalize [info nameofexecutable]]]
    while {1} {
        foreach cand $FRONT_DIRS {
            if {[file isdirectory [file join $d $cand]]} {
                set FRONT_ROOT $d
                set FRONT_HOME [file join $d $cand]
                set FRONT_DIR  $cand
                return
            }
        }
        set up [file dirname $d]
        if {$up eq $d} { break }
        set d $up
    }
    Fail FRONT noroot "no workspace: no [join $FRONT_DIRS { or }] directory at or above [file dirname [info nameofexecutable]]"
}

proc ::machteld::FrontManifest {} {
    variable FRONT_MAN ; variable FRONT_HOME
    if {$FRONT_MAN ne ""} { return $FRONT_MAN }
    FrontRoots
    set p [file join $FRONT_HOME manifest.json]
    if {![file exists $p]} { Fail FRONT manifest "no manifest at $p" }
    set fh [open $p r]
    fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    if {[catch {json decode $text} m]} { Fail FRONT manifest "manifest is not valid JSON: $m" }
    set FRONT_MAN $m
    return $m
}

# Z_ROOT and Z_HOME appear literally in manifest values; expand them the same way
# wherever they occur rather than only where this file happens to look.
proc ::machteld::FrontExpand {s} {
    variable FRONT_ROOT ; variable FRONT_HOME
    return [string map [list MT_ROOT $FRONT_ROOT MT_HOME $FRONT_HOME \
                            {${MT_ROOT}} $FRONT_ROOT {${MT_HOME}} $FRONT_HOME \
                            Z_ROOT $FRONT_ROOT Z_HOME $FRONT_HOME \
                            {${Z_ROOT}} $FRONT_ROOT {${Z_HOME}} $FRONT_HOME] $s]
}

# WHICH PROJECT WE ARE STANDING IN, if any. A project is a directory directly
# under the workspace root; being anywhere inside one makes it active. Decided
# from the working directory on purpose -- the project is where you are, while the
# workspace is where the front door is.
proc ::machteld::FrontProject {{dir ""}} {
    variable FRONT_ROOT
    FrontRoots
    if {$dir eq ""} { set dir [pwd] }
    set dir [file normalize $dir]
    set root $FRONT_ROOT
    if {![string equal -nocase -length [string length $root] $dir $root]} { return {} }
    set rest [string trimleft [string range $dir [string length $root] end] "/"]
    if {$rest eq ""} { return {} }
    set name [lindex [file split $rest] 0]
    return [dict create name $name root [file join $root $name]]
}

# The environment every spawned command receives. Z_ROOT and Z_HOME always; the
# project pair only when one is active, because an absent variable and an empty
# one are different answers and a script can tell them apart.
proc ::machteld::FrontBaseEnv {} {
    variable FRONT_ROOT ; variable FRONT_HOME ; variable FRONT_DIR
    FrontRoots
    set e [dict create MT_ROOT $FRONT_ROOT MT_HOME $FRONT_HOME]
    set p [FrontProject]
    if {[dict size $p]} {
        dict set e MT_PROJECT_NAME [dict get $p name]
        dict set e MT_PROJECT_ROOT [dict get $p root]
    }
    # BOTH SPELLINGS WHILE BOTH FRONT DOORS EXIST. Every project script in the
    # workspace was written against Z_*, and they have to keep working the day
    # this starts spawning things. Transitional on purpose, and with a removal
    # CONDITION rather than a vague intention: once the workspace's private
    # directory is `.mt`, the Z_ names are not emitted at all.
    if {$FRONT_DIR eq ".z"} {
        foreach {mt z} {MT_ROOT Z_ROOT MT_HOME Z_HOME
                        MT_PROJECT_NAME Z_PROJECT_NAME MT_PROJECT_ROOT Z_PROJECT_ROOT} {
            if {[dict exists $e $mt]} { dict set e $z [dict get $e $mt] }
        }
    }
    return $e
}

# NAME -> SOMETHING RUNNABLE. Resolution order is the workspace's: a builtin
# first, then a curated tool. `z:name` restricts to the front door's own, the way
# `z` qualifies a collision.
proc ::machteld::FrontResolve {name} {
    variable FRONT_HOME
    FrontRoots
    set only ""
    if {[regexp {^([a-z]+):(.+)$} $name -> scope rest]} {
        if {$scope ni {z project}} { Fail FRONT usage "unknown qualifier \"$scope:\": use z: or project:" }
        set only $scope
        set name $rest
    }

    if {$only in {"" z}} {
        # A builtin is a verb this exe already has: no process, no path.
        if {[dict exists [manifest] $name]} {
            return [dict create kind builtin name $name exe [info nameofexecutable] \
                        args [list $name] env [FrontBaseEnv] cwd [pwd]]
        }
    }

    if {$only eq ""} {
        set m [FrontManifest]
        if {[dict exists $m tools $name]} {
            set t [dict get $m tools $name]
            # KEYS THIS DOES NOT IMPLEMENT YET ARE AN ERROR, NOT A SHRUG. 35 of
            # the 273 entries carry an `envFromRoot`, 13 a `preFromRoot`, and one
            # an `arg0`; resolving those entries while ignoring the key would
            # produce a confident answer that differs from what `z` runs. Since
            # the whole point of this step is to be COMPARED against z, a wrong
            # answer is worse than a refusal -- and the refusal enumerates the
            # remaining work by name instead of hiding it.
            set known {version license source note exeFromRoot exe path env}
            foreach k [dict keys $t] {
                if {$k ni $known} {
                    Fail FRONT manifest "tool \"$name\" uses \"$k\", which the front door does not implement yet"
                }
            }
            # An absolute `exe`, else the Z_HOME-relative override, else the
            # convention the workspace uses for a plain tool: t/<name>/<name>.exe.
            if {[dict exists $t exe]} {
                set exe [FrontExpand [dict get $t exe]]
            } elseif {[dict exists $t exeFromRoot]} {
                set exe [file join $FRONT_HOME [FrontExpand [dict get $t exeFromRoot]]]
            } else {
                set exe [file join $FRONT_HOME t $name $name.exe]
            }
            set env [FrontBaseEnv]
            # The tool's own overlay, then the directories it needs ahead of the
            # inherited PATH -- prepended, so a vendored tool wins over anything
            # the machine happens to have.
            if {[dict exists $t env]} {
                dict for {k v} [dict get $t env] { dict set env $k [FrontExpand $v] }
            }
            if {[dict exists $t path]} {
                set dirs {}
                foreach d [dict get $t path] { lappend dirs [file nativename [file join $FRONT_HOME [FrontExpand $d]]] }
                set inherited [expr {[info exists ::env(PATH)] ? $::env(PATH) : ""}]
                dict set env PATH [join [concat $dirs [list $inherited]] ";"]
            }
            return [dict create kind tool name $name exe $exe args {} env $env cwd [pwd]]
        }
    }

    Fail FRONT notfound "\"$name\" is not a builtin or a curated tool -- there is no PATH fallback"
}

proc ::machteld::front {args} {
    set subs {roots which env tools}
    set opts {-json}
    if {![llength $args]} {
        Fail FRONT usage "usage: front roots | front which name | front env name ?-json? | front tools ?pattern?"
    }
    set sub [lindex $args 0]
    if {$sub ni $subs} {
        Fail FRONT usage "front: unknown subcommand \"$sub\": must be [join $subs {, }]"
    }

    if {$sub eq "roots"} {
        if {[llength $args] != 1} { Fail FRONT usage "usage: front roots" }
        variable FRONT_ROOT ; variable FRONT_HOME ; variable FRONT_DIR
        FrontRoots
        set d [dict create root $FRONT_ROOT home $FRONT_HOME dir $FRONT_DIR]
        set p [FrontProject]
        if {[dict size $p]} { dict set d project [dict get $p name] ; dict set d projectroot [dict get $p root] }
        return $d
    }

    if {$sub eq "tools"} {
        if {[llength $args] > 2} { Fail FRONT usage "usage: front tools ?pattern?" }
        set pat [expr {[llength $args] == 2 ? [lindex $args 1] : "*"}]
        set m [FrontManifest]
        if {![dict exists $m tools]} { return {} }
        return [lsort [lsearch -all -inline -glob [dict keys [dict get $m tools]] $pat]]
    }

    if {[llength $args] < 2} { Fail FRONT usage "usage: front $sub name" }
    set r [FrontResolve [lindex $args 1]]
    if {$sub eq "which"} {
        if {[llength $args] != 2} { Fail FRONT usage "usage: front which name" }
        return [dict get $r exe]
    }
    # env
    set asjson 0
    foreach a [lrange $args 2 end] {
        if {$a eq "-json"} { set asjson 1 ; continue }
        Fail FRONT usage "front env: unknown option \"$a\""
    }
    if {$asjson} { return [json encode $r] }
    return $r
}
