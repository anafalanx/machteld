# front.tcl -- ::machteld::front: machteld as the front door to a workspace.
#
#   front roots                ;# where the workspace is, and how it was found
#   front which rg             ;# the executable a name resolves to
#   front env rg               ;# exe, args, env, cwd -- everything, as a dict
#   front env rg -json         ;# the same, on the wire
#   front tools ?pattern?      ;# what the workspace curates
#   front run ?-inherit? rg -n TODO .     ;# resolve, then actually run it
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
# Resolution is checked against the live `z` for agreement on every curated tool
# (`test/front_agree.tcl`) -- 273 of 273 -- so what this runs is what the
# workspace would have run.
#
# LOADED LAST in the prelude, after the derived manifest: a builtin is "a verb the
# manifest knows", so the dispatcher at the foot of this file cannot resolve
# anything until that exists.

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

    # A directory is a PROJECT if it carries one of these. Same transition
    # order: machteld's own file wins, the Go front door's is still honoured.
    variable FRONT_PROJFILES {mt.json z.json}

    variable FRONT_JOURNAL ""   ;# "" untried, "on" open, "off" unavailable
    variable FRONT_SESSION ""   ;# this front door invocation
}

# THE JOURNAL IS A SERVICE, NOT A PRECONDITION. It is opened lazily, once, and
# every failure to do so is final and silent: no workspace, an unwritable
# directory, a database from a newer build -- none of those are reasons a tool
# should refuse to run. Same bargain `log` makes, for the same reason. A command
# must never fail because bookkeeping did.
proc ::machteld::FrontJournal {} {
    variable FRONT_JOURNAL ; variable FRONT_HOME ; variable FRONT_SESSION
    if {$FRONT_JOURNAL ne ""} { return [expr {$FRONT_JOURNAL eq "on"}] }
    set FRONT_JOURNAL off
    if {[catch {FrontRoots}]} { return 0 }
    if {[catch {journal open [file join $FRONT_HOME mt.db]}]} { return 0 }
    # One id per front-door invocation, so the rows of one command can be told
    # from another's even though every `mt <name>` is a separate process.
    set FRONT_SESSION "[pid]-[clock milliseconds]"
    set FRONT_JOURNAL on
    return 1
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

# THE THREE BRACKETED FORMS, AND ONLY THOSE. `${Z_ROOT}`, `$(Z_ROOT)` and
# `%Z_ROOT%`, likewise for Z_HOME -- which is exactly what the workspace's own
# resolver expands. The first version of this also mapped the BARE words
# `Z_ROOT` and `Z_HOME`, which is not expansion but corruption: any argument
# that merely contains those letters would have had a path spliced into the
# middle of it. Written from the workspace resolver rather than from the names,
# because a token syntax is not guessable.
proc ::machteld::FrontExpand {s} {
    variable FRONT_ROOT ; variable FRONT_HOME
    set root [file nativename $FRONT_ROOT]
    set home [file nativename $FRONT_HOME]
    set out [string map [list {${MT_ROOT}} $root {$(MT_ROOT)} $root %MT_ROOT% $root \
                              {${MT_HOME}} $home {$(MT_HOME)} $home %MT_HOME% $home \
                              {${Z_ROOT}}  $root {$(Z_ROOT)}  $root %Z_ROOT%  $root \
                              {${Z_HOME}}  $home {$(Z_HOME)}  $home %Z_HOME%  $home] $s]
    # AND IF IT EXPANDED TO A PATH INSIDE THE WORKSPACE, NORMALISE THE WHOLE
    # THING. Substituting the root leaves the tail spelled however the manifest
    # wrote it, so `${Z_HOME}/cache/glow/config.yml` came out half native and
    # half not -- `C:\dev\.z/cache/glow/config.yml`. The workspace's resolver
    # cleans the result whenever expansion put it under root or home, and that
    # single tool was the only one of 273 that noticed.
    if {$out ne $s && ([string equal -nocase -length [string length $root] $out $root]
                       || [string equal -nocase -length [string length $home] $out $home])} {
        return [file nativename [file normalize $out]]
    }
    return $out
}

# Case-insensitive dedup that keeps the first spelling, for PATH: Windows does
# not distinguish the case, and a directory listed twice is a longer PATH for no
# reason.
proc ::machteld::FrontDedup {items} {
    set out {} ; set seen {}
    foreach i $items {
        set k [string tolower $i]
        if {$k in $seen} continue
        lappend seen $k
        lappend out $i
    }
    return $out
}

# WHICH PROJECT WE ARE STANDING IN, if any. A project is a directory directly
# under the workspace root; being anywhere inside one makes it active. Decided
# from the working directory on purpose -- the project is where you are, while the
# workspace is where the front door is.
proc ::machteld::FrontProject {{dir ""}} {
    variable FRONT_PROJFILES
    FrontRoots
    if {$dir eq ""} { set dir [pwd] }
    set dir [file normalize $dir]
    while {1} {
        foreach f $FRONT_PROJFILES {
            if {[file exists [file join $dir $f]]} {
                set name [file tail $dir]
                if {[string index $name 0] eq "_" && [string length $name] > 1} {
                    set name [string range $name 1 end]
                }
                return [dict create name $name root $dir]
            }
        }
        set up [file dirname $dir]
        if {$up eq $dir} { return {} }
        set dir $up
    }
}

# The environment every spawned command receives. Z_ROOT and Z_HOME always; the
# project pair only when one is active, because an absent variable and an empty
# one are different answers and a script can tell them apart.
# `projdir` names the project explicitly, for `front in <project> ...`, where
# the project is an argument rather than wherever the caller happens to stand.
proc ::machteld::FrontBaseEnv {{projdir ""}} {
    variable FRONT_ROOT ; variable FRONT_HOME ; variable FRONT_DIR
    FrontRoots
    # NATIVE SEPARATORS. These land in a child process's environment on Windows,
    # where `C:\dev` is the spelling everything else uses; Tcl's internal forward
    # slashes are an implementation detail that must not leak into what a child
    # sees. Caught by diffing against the front door being replaced.
    set e [dict create MT_ROOT [file nativename $FRONT_ROOT] \
                       MT_HOME [file nativename $FRONT_HOME]]
    set p [FrontProject $projdir]
    if {[dict size $p]} {
        dict set e MT_PROJECT_NAME [dict get $p name]
        dict set e MT_PROJECT_ROOT [file nativename [dict get $p root]]
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
#
# THERE WAS BRIEFLY A THIRD TIER between those two, for tools riding inside this
# exe's own zipfs (`mt sums .`), and it lasted a day. Five programs shipped that
# way and all five were removed on 2026-08-10: a front door resolves names, and
# hosting the applications as well made it two things at once. Every name the
# front door resolves is now a key in a dict somebody else wrote -- which is
# also why nothing here joins a caller's string onto a path.
proc ::machteld::FrontResolve {name {projdir ""}} {
    variable FRONT_HOME
    FrontRoots
    set only ""
    if {[regexp {^([a-z]+):(.+)$} $name -> scope rest]} {
        if {$scope ni {z project}} { Fail FRONT usage "unknown qualifier \"$scope:\": use z: or project:" }
        set only $scope
        set name $rest
    }

    # THE QUALIFIERS WERE BACKWARDS. `z:name` means "the KIT's name" -- a curated
    # tool or a kit script -- and explicitly NOT a builtin, because a builtin is
    # unambiguous already and there is nothing to qualify it against. machteld
    # had it the other way round until 2026-08-10: `z:` reached builtins and
    # skipped tools, so `z:rg` did not resolve and `z:run` resolved to the
    # palette. Never caught, because the agreement test only ever asked bare
    # names.
    if {$only eq "z"} {
        if {[FrontSafeName $name]} {
            if {![catch {FrontCurated $name} r]} { return $r }
        }
        Fail FRONT notfound "the kit has no tool or script named \"$name\""
    }
    if {$only eq "project"} {
        set p [FrontProject]
        if {[dict size $p]} {
            set cmds [FrontProjectCommands [dict get $p root]]
            if {[dict exists $cmds $name]} { return [dict get $cmds $name] }
        }
        Fail FRONT notfound "the project declares no command named \"$name\""
    }

    # THE ORDER, AND WHAT IS RESERVED. z's rule is that its BUILT-INS and its
    # curated tools are reserved -- a project may not shadow either, so a bare
    # core name always means the kit. machteld's equivalent of z's built-ins is
    # the front-door command set, NOT the whole Tcl palette: `which` and `status`
    # are the front door's own commands, while `run`, `json` and `hash` are
    # scripting verbs that merely happen to be reachable from a command line.
    #
    # THE PALETTE USED TO COME FIRST, and it cost every project its `run`. Ten of
    # the twelve projects here declare a `run` command; `run` is also a palette
    # verb; so `mt run` inside a project was the palette's `run` in every one of
    # them, and z's was the project's. Reserving the whole palette reserves a
    # namespace far larger than the front door has any claim to.
    if {$only eq ""} {
        # 1. THE FRONT DOOR'S OWN COMMANDS -- `mt which rg`, not `mt front which
        #    rg`, because these exist to be typed where `z which rg` was, and a
        #    front door that needs a prefix does not replace one that does not.
        #    Reserved: all 21 of z's built-in names were checked against the 275
        #    the workspace curates and not one collides, and the suite re-checks
        #    it because the workspace gains tools without asking anybody.
        if {$name in [FrontCommands]} {
            return [dict create kind command name $name exe [info nameofexecutable] \
                        args [list front $name] env [FrontBaseEnv] cwd [pwd]]
        }
        # 2. A CURATED TOOL. Also reserved.
        if {[FrontSafeName $name] && ![catch {FrontCurated $name} r]} { return $r }
        # 3. THE PROJECT'S OWN COMMANDS, which may not shadow either of the two
        #    above. `_els` declares eighteen; `mt build` standing inside it runs
        #    the project's build, which machteld could not do at all until
        #    2026-08-10, having stopped at curated tools.
        set p [FrontProject $projdir]
        if {[dict size $p]} {
            set cmds [FrontProjectCommands [dict get $p root]]
            if {[dict exists $cmds $name]} { return [dict get $cmds $name] }
        }
        # 4. AND LAST, A PALETTE VERB, as a convenience rather than a claim:
        #    `mt version`, `mt manifest`, `mt help`. Nothing else wants those
        #    names -- no palette verb shadows a curated tool, checked -- and
        #    anything that does want one gets it first.
        #
        #    Asked with `PaletteVerb` rather than `dict exists [manifest] $name`,
        #    which is the same question and derives the entire self-description
        #    to answer it: 316 ms, on every single invocation.
        if {[PaletteVerb $name]} {
            return [dict create kind builtin name $name exe [info nameofexecutable] \
                        args [list $name] env [FrontBaseEnv] cwd [pwd]]
        }
    }

    Fail FRONT notfound "\"$name\" is not a builtin, a curated tool or a project command\
                         -- there is no PATH fallback"
}

# THE CURATED TOOLS, as their own proc so the bare name and the `z:`
# qualifier resolve through one implementation rather than two.
proc ::machteld::FrontCurated {name} {
    variable FRONT_HOME
    FrontRoots
        set m [FrontManifest]
        # THE `t/` DIRECTORY IS A SOURCE, NOT AN OVERRIDE. This was gated on
        # `dict exists $m tools $name` until 2026-08-10, which made the manifest
        # the whole inventory -- and it is not. A `t/<name>/` directory holding
        # `<name>.exe` IS a curated tool whether or not the manifest has ever
        # heard of it, which is how `EditPadPro8`, `RegexBuddy5`, `CSCSE5` and
        # `FNSE3` are z tools and were, until now, names machteld refused.
        #
        # Step 1 reported 273 of 273 resolutions agreeing and could not have
        # caught this: it iterated `front tools`, machteld's OWN list, so a tool
        # machteld did not know about was never asked for. A verification that
        # enumerates from the side under test can only find disagreements about
        # things both sides already name.
        if {[FrontSafeName $name]} {
            set t [expr {[dict exists $m tools $name] ? [dict get $m tools $name] : {}}]
            # THE EXE, CHOSEN THE WAY THE WORKSPACE CHOOSES IT -- and the order
            # is the opposite of the obvious one. The `t/` directory scan comes
            # FIRST, and there `exe` is a FILENAME INSIDE t/<name>/, not a path;
            # `exeFromRoot` is the fallback, joined at MT_HOME. Both are taken
            # only if the file is really there, so a tool that is catalogued but
            # not installed does not resolve at all rather than resolving to a
            # path that is not on disk. Every one of those four facts was read
            # out of the workspace's resolver; three of them are the opposite of
            # what the key names suggest.
            set exe ""
            set tdir [file join $FRONT_HOME t $name]
            if {[file isdirectory $tdir]} {
                set rel [expr {[dict exists $t exe] ? [dict get $t exe] : "$name.exe"}]
                set cand [file join $tdir $rel]
                if {[file exists $cand] && ![file isdirectory $cand]} { set exe $cand }
            }
            if {$exe eq "" && [dict exists $t exeFromRoot]} {
                set cand [file join $FRONT_HOME [dict get $t exeFromRoot]]
                if {[file exists $cand] && ![file isdirectory $cand]} { set exe $cand }
            }
            # Catalogued but not installed is its own answer; never heard of is
            # the generic one at the foot of this proc.
            if {$exe eq "" && [dict exists $m tools $name]} {
                Fail FRONT notfound "\"$name\" is catalogued but its executable is not installed"
            }
            if {$exe ne ""} {

            # Arguments prepended before the caller's: the MT_HOME-relative ones
            # first, then the literal ones with their tokens expanded. An
            # interpreter that runs a script, most often.
            set pre {}
            if {[dict exists $t preFromRoot]} {
                foreach rel [dict get $t preFromRoot] {
                    if {$rel ne ""} { lappend pre [file nativename [file join $FRONT_HOME $rel]] }
                }
            }
            if {[dict exists $t pre]} {
                foreach a [dict get $t pre] { lappend pre [FrontExpand $a] }
            }

            set env [FrontBaseEnv]
            # `envFromRoot` values are MT_HOME-relative PATHS; `env` values are
            # literal and are NOT token-expanded -- the workspace expands tokens
            # in `pre` only, and matching that matters more than being uniform.
            if {[dict exists $t envFromRoot]} {
                dict for {k v} [dict get $t envFromRoot] {
                    if {$k ne ""} { dict set env $k [file nativename [file join $FRONT_HOME $v]] }
                }
            }
            if {[dict exists $t env]} {
                dict for {k v} [dict get $t env] { if {$k ne ""} { dict set env $k $v } }
            }
            # PATH: only directories that EXIST, deduped, ahead of the inherited
            # one so a vendored tool wins over whatever the machine has.
            if {[dict exists $t path]} {
                set dirs {}
                foreach rel [dict get $t path] {
                    if {$rel eq ""} continue
                    set p [file join $FRONT_HOME $rel]
                    if {[file isdirectory $p]} { lappend dirs [file nativename $p] }
                }
                set dirs [FrontDedup $dirs]
                if {[llength $dirs]} {
                    set inherited [expr {[info exists ::env(PATH)] ? $::env(PATH) : ""}]
                    dict set env PATH [join [concat $dirs [list $inherited]] ";"]
                }
            }

            set r [dict create kind tool name $name exe [file nativename $exe] \
                       pre $pre args {} env $env cwd [file nativename [pwd]]]
            if {[dict exists $t arg0]} { dict set r arg0 [dict get $t arg0] }
            return $r
            }
        }
    Fail FRONT notfound "\"$name\" is not a curated tool"
}

# A NAME THAT MAY BE JOINED ONTO A PATH. `t/<name>/<name>.exe` puts a caller's
# string into a filename, so `mt ../../x` must not become a directory lookup.
# The curated names include `c++`, `go1.25` and `EditPadPro8`, so this cannot be
# the tight `[a-z][a-z0-9]*` a shipped tool's name had to be -- it refuses the
# separators and the dot-only forms, which is exactly what traversal needs.
# EVERY NAME THE WORKSPACE CURATES, from BOTH sources and in z's order: the
# `t/` directory scan first, then the manifest's `exeFromRoot` entries that are
# actually installed. Listing only the manifest is what hid four real tools.
proc ::machteld::FrontToolNames {} {
    variable FRONT_HOME
    FrontRoots
    set m [FrontManifest]
    set names {}
    foreach d [glob -nocomplain -types d -directory [file join $FRONT_HOME t] *] {
        set n [file tail $d]
        set rel "$n.exe"
        if {[dict exists $m tools $n exe]} { set rel [dict get $m tools $n exe] }
        set cand [file join $d $rel]
        if {[file exists $cand] && ![file isdirectory $cand]} { dict set names $n 1 }
    }
    if {[dict exists $m tools]} {
        dict for {n spec} [dict get $m tools] {
            if {[dict exists $names $n] || ![dict exists $spec exeFromRoot]} continue
            set cand [file join $FRONT_HOME [dict get $spec exeFromRoot]]
            if {[file exists $cand] && ![file isdirectory $cand]} { dict set names $n 1 }
        }
    }
    return [lsort [dict keys $names]]
}

proc ::machteld::FrontSafeName {name} {
    if {$name eq "" || $name eq "." || $name eq ".."} { return 0 }
    if {[string first "/" $name] >= 0 || [string first "\\" $name] >= 0} { return 0 }
    return 1
}

# WHAT `front` CAN BE ASKED, read out of `front`'s own table rather than listed
# again here. Two copies of a command set is how `mt projects` starts working
# and `front projects` stops, or the reverse; `MtclFacts` reads the same `set
# subs {...}` line for the manifest, so this is the third reader of one truth
# rather than a second copy of it. Cached: one regexp, once per process.
# NOT EVERY SUBCOMMAND IS PROMOTED, and `run` is why the exception exists.
# `front run` is the plumbing that executes a resolved name -- `mt run rg` is
# just `mt rg` with extra words -- so promoting it buys nothing, and it costs
# the bare name `run`, which TEN of the twelve projects here declare as a
# command of their own. z has no `run` built-in for exactly that reason.
# It stays reachable in full as `front run`.
proc ::machteld::FrontCommands {} {
    variable FRONT_CMDS
    if {![info exists FRONT_CMDS]} {
        set subs {}
        regexp -line -- {^\s+set subs \{([^\}]*)\}} [info body ::machteld::front] -> subs
        set FRONT_CMDS [lmap s $subs {expr {$s in [FrontUnpromoted] ? [continue] : $s}}]
    }
    return $FRONT_CMDS
}
proc ::machteld::FrontUnpromoted {} { return {run} }

# --- the workspace's own inventory -------------------------------------------
#
# THESE RULES WERE READ OUT OF z's SOURCE, not inferred from the output, for the
# same reason resolution was in step 1: they are not guessable. `runtimes` looks
# like "a directory scan of .z/r", and the thing that decides whether a payload
# has versions under it is a HARDCODED LIST of six names in
# `runtimes_builtin.go`. No amount of staring at `.z/r/` produces that -- `zig`
# and `winsdk` have a single version-shaped subdirectory each and are still
# reported unversioned.

# A HOSTED PROJECT is a `_`-prefixed directory carrying the project file. Not
# "a directory under the root", and not every `_` directory either: 23 of them
# exist here and 11 are projects. The name drops the underscore.
proc ::machteld::FrontProjects {} {
    variable FRONT_ROOT ; variable FRONT_PROJFILES
    FrontRoots
    set out {}
    foreach d [lsort [glob -nocomplain -types d -directory $FRONT_ROOT *]] {
        set dir [file tail $d]
        if {[string index $dir 0] ne "_" || [string length $dir] == 1} continue
        set found 0
        foreach pf $FRONT_PROJFILES { if {[file exists [file join $d $pf]]} { set found 1 ; break } }
        if {!$found} continue
        lappend out [dict create name [string range $dir 1 end] dir $dir \
                         path [file nativename [file join $FRONT_ROOT $dir]]]
    }
    return [lsort -index 1 $out]
}

# --- project commands: the tier machteld did not have ------------------------
#
# A project's `z.json` declares `commands`, each one an argv list. `_els` alone
# has eighteen. Standing inside a project, `z build` runs that project's build --
# and until now `mt build` said the workspace curates no such tool, because
# machteld resolved builtins and curated tools and then stopped.
#
# argv[0] IS RESOLVED, NOT EXECUTED. A name that is a curated tool CLONES that
# tool's whole target -- its env overlay, its PATH shaping, its prepended
# arguments -- and the command's remaining words are appended to those. So
# `["tclsh90", "tools/tasks.tcl", "build"]` runs the workspace's tclsh, with the
# workspace's Tcl environment, on a project-relative script. Otherwise argv[0]
# must be a PATH: absolute, or containing a separator and taken relative to the
# project root. A bare word that is neither is dropped rather than looked up on
# the system PATH -- the no-fallback rule reaches in here too.
#
# The working directory is the project root, which is what makes the rest of the
# argv able to be project-relative.
proc ::machteld::FrontProjectCommands {root {probVar ""}} {
    if {$probVar ne ""} { upvar 1 $probVar probs }
    set probs {}
    variable FRONT_PROJFILES
    set spec {}
    foreach f $FRONT_PROJFILES {
        set p [file join $root $f]
        if {![file exists $p]} continue
        set fh [open $p r] ; fconfigure $fh -encoding utf-8
        set text [read $fh] ; close $fh
        if {[catch {json decode $text} m]} {
            Fail FRONT manifest "[file nativename $p] is not valid JSON: $m"
        }
        if {[dict exists $m commands]} { set spec [dict get $m commands] }
        break
    }
    set out {}
    foreach name [lsort [dict keys $spec]] {
        set argv [dict get $spec $name]
        if {![llength $argv]} {
            lappend probs "project command \"$name\" has an empty command line"
            continue
        }
        set a0 [lindex $argv 0]
        set t ""
        if {![catch {FrontResolve "z:$a0"} r] && [dict get $r kind] eq "tool"} {
            set t $r
        } elseif {[file pathtype $a0] eq "absolute"} {
            set t [dict create kind project exe [file nativename [FrontClean $a0]] \
                       pre {} env [FrontBaseEnv $root]]
        } elseif {[string first "/" $a0] >= 0 || [string first "\\" $a0] >= 0} {
            # CLEANED, because `filepath.Join` cleans and `file join` does not.
            # `["./drang.exe", ...]` came out as `_drang\.\drang.exe` and
            # `["../_drang/drang.exe"]` as `_exp\..\_drang\drang.exe` -- both
            # run, both are the wrong string, and both differed from z on
            # nothing but punctuation. Six commands across two projects.
            set t [dict create kind project \
                       exe [file nativename [FrontClean [file join $root $a0]]] \
                       pre {} env [FrontBaseEnv $root]]
        } else {
            lappend probs "project command \"$name\": \"$a0\" is neither a z tool nor a path"
            continue                                      ;# dropped -- never a PATH lookup
        }
        set pre [expr {[dict exists $t pre] ? [dict get $t pre] : {}}]
        lappend pre {*}[lrange $argv 1 end]
        dict set t kind project
        dict set t name $name
        dict set t pre  $pre
        dict set t args {}
        dict set t env  [FrontBaseEnv $root]
        dict set t cwd  [file nativename $root]
        dict set out $name $t
    }
    return $out
}

# SCOUT LOOKS AT EVERY UNDERSCORE DIRECTORY, not at every hosted project -- and
# the difference is the point of the command. `projects` lists the eleven or
# twelve that carry a project file; scout lists all twenty-three and reports
# which ones do not, which is how a directory that was meant to become a project
# and never did gets noticed.
#
# Note it does NOT apply the length check `projects` does: a directory named
# exactly `_` is scouted and is not a project. Faithfully copied, because the
# two commands really are asking different questions.
proc ::machteld::FrontUnderscoreDirs {} {
    variable FRONT_ROOT
    FrontRoots
    set dirs {}
    foreach d [glob -nocomplain -types d -directory $FRONT_ROOT *] {
        if {[string index [file tail $d] 0] eq "_"} { lappend dirs $d }
    }
    # Sorted by lowercased basename, which is z's order and not Tcl's default.
    return [lmap p [lsort -index 0 [lmap d $dirs {list [string tolower [file tail $d]] $d}]] \
                {lindex $p 1}]
}

proc ::machteld::FrontScoutStatic {dir} {
    variable FRONT_PROJFILES
    set name [file tail $dir]
    if {[string index $name 0] eq "_"} { set name [string range $name 1 end] }
    set hasz 0
    foreach f $FRONT_PROJFILES {
        if {[file exists [file join $dir $f]]} { set hasz 1 ; break }
    }
    set row [dict create name $name zjson $hasz \
                 readme [file exists [file join $dir README.md]] \
                 git no-git branch - commands {}]
    if {$hasz} { dict set row commands [lsort [dict keys [FrontProjectCommands $dir]]] }
    return $row
}

# THE GIT PROBES RUN CONCURRENTLY, and it is worth 2.7x -- measured on a warm
# cache, after a cold-cache reading of the same comparison said the opposite by
# a factor of ten. Two `git` invocations per directory over twenty-three
# directories: serial 1.12 s, concurrent 0.41 s. z is concurrent by default for
# the same reason, and `--serial` exists on both to turn it off.
#
# Every probe is a SUPERVISED CHILD -- born in the job object, tree-killable,
# dying with this process, and carrying its own deadline -- so a `git` that
# wedges on one repository cannot hang the front door or leak a process. That is
# the argument for the palette existing, applied to the front door's own work.
proc ::machteld::FrontScoutProbe {dirs git serial} {
    set out {}
    foreach d $dirs { dict set out $d [dict create git no-git branch -] }
    set probing {}
    foreach d $dirs {
        if {[file exists [file join $d .git]]} { lappend probing $d }
    }
    if {$git eq ""} {
        foreach d $probing { dict set out $d git git? }
        return $out
    }
    set base [list [dict get $git exe]]
    if {[dict exists $git pre]} { lappend base {*}[dict get $git pre] }
    set genv [dict get $git env]
    foreach probe {status branch} {
        set argl [expr {$probe eq "status" ? {status --short} : {branch --show-current}}]
        set kids {}
        foreach d $probing {
            if {$serial} {
                set text [FrontGitRun $git $d $argl code]
                dict set kids $d [list done $text $code]
                continue
            }
            if {[catch {child start -timeout 120s -dir $d -env $genv -- {*}$base {*}$argl} c]} {
                dict set kids $d [list done "" 1]
            } else {
                dict set kids $d [list child $c]
            }
        }
        dict for {d k} $kids {
            lassign $k how a b
            if {$how eq "done"} {
                set text $a ; set code $b
            } else {
                set r [child wait $a]
                catch {child close $a}
                set text [dict get $r out] ; set code [dict get $r exit]
            }
            if {$probe eq "status"} {
                dict set out $d git [expr {$code != 0 ? "git?" :
                    ([string trim $text] eq "" ? "clean" : "dirty")}]
            } elseif {$code == 0 && [string trim $text] ne ""} {
                dict set out $d branch [string trim $text]
            }
        }
    }
    return $out
}

# WHAT THE WORKSPACE ROOT MAY CONTAIN: the front door itself, its private
# directory, and hosted projects. Anything else is reported -- this is a
# workspace whose root is meant to be almost empty, and drift there is the kind
# that goes unnoticed for years.
#
# BOTH FRONT DOORS ARE ACCEPTED while both exist. z flags anything it does not
# recognise, which will include `mt.exe` the day it lands beside `z.exe` -- so
# for a while `z verify` will report a problem that `mt verify` does not, and
# that difference is the transition rather than a defect in either.
proc ::machteld::FrontLayoutProblems {} {
    variable FRONT_ROOT ; variable FRONT_HOME ; variable FRONT_DIRS
    FrontRoots
    set probs {}
    if {![file isdirectory $FRONT_HOME]} {
        lappend probs "missing z home directory [file nativename $FRONT_HOME]"
    }
    if {[catch {glob -nocomplain -directory $FRONT_ROOT * .*} entries]} {
        return [list "cannot read workspace root [file nativename $FRONT_ROOT]"]
    }
    foreach e $entries {
        set n [file tail $e]
        if {$n eq "." || $n eq ".."} continue
        if {[string equal -nocase $n z.exe] || [string equal -nocase $n mt.exe]} continue
        if {$n in $FRONT_DIRS} continue
        if {[file isdirectory $e] && [string index $n 0] eq "_" && [string length $n] > 1} continue
        lappend probs "unexpected workspace-root entry [file nativename [file join $FRONT_ROOT $n]]"
    }
    return [lsort $probs]
}

# GIT, AS THE COCKPIT COUNTS IT. Two commands per directory -- the branch and
# the short status -- and a tally whose rules are exact and slightly surprising:
# `??` is untracked and is tested FIRST, so an untracked file is never counted
# as anything else; then a `D` anywhere in the two-character prefix is a
# deletion, then an `M` is a modification, and everything else is `other`. A
# line like `MD` counts as deleted, not modified, because D is tested first.
#
# An empty branch means a detached HEAD, and z says so in those words.
proc ::machteld::FrontGit {dir} {
    set g [FrontResolve git]
    set branch [string trim [FrontGitRun $g $dir {branch --show-current}]]
    set st [FrontGitRun $g $dir {status --short} code err]
    if {$code != 0} {
        set detail [string trim $err]
        if {$detail eq ""} { set detail [string trim $st] }
        return [dict create ok 0 branch $branch lines {} detail $detail]
    }
    set lines {}
    foreach line [split [string map {\r\n \n \r \n} $st] \n] {
        if {$line ne ""} { lappend lines $line }
    }
    set c [dict create modified 0 deleted 0 untracked 0 other 0]
    foreach line $lines {
        set pre [string range $line 0 1]
        if {[string range $line 0 1] eq "??"} {
            dict incr c untracked
        } elseif {[string first "D" $pre] >= 0} {
            dict incr c deleted
        } elseif {[string first "M" $pre] >= 0} {
            dict incr c modified
        } else {
            dict incr c other
        }
    }
    if {$branch eq ""} { set branch "(detached)" }
    return [dict create ok 1 branch $branch lines $lines counts $c]
}

# One line of prose from a git summary, for the human rendering only -- the
# -json form carries the dict and lets whoever reads it do its own counting.
proc ::machteld::FrontGitLine {g} {
    if {![dict get $g ok]} { return "unavailable ([dict get $g detail])" }
    set c [dict get $g counts]
    set bits {}
    foreach k {modified deleted untracked other} {
        if {[dict get $c $k]} { lappend bits "[dict get $c $k] $k" }
    }
    if {![llength $bits]} { return "clean on [dict get $g branch]" }
    return "dirty on [dict get $g branch]: [join $bits {, }]"
}

proc ::machteld::FrontGitRun {g dir argl {codeVar ""} {errVar ""}} {
    if {$codeVar ne ""} { upvar 1 $codeVar code }
    if {$errVar ne ""} { upvar 1 $errVar err }
    set argv [list [dict get $g exe]]
    if {[dict exists $g pre]} { lappend argv {*}[dict get $g pre] }
    lappend argv {*}$argl
    set code 1 ; set err ""
    if {[catch {run -timeout 60s -dir $dir -env [dict get $g env] -- {*}$argv} r]} { return "" }
    set code [dict get $r exit]
    set err  [dict get $r err]
    return [dict get $r out]
}

# WHICH PAYLOADS KEEP THEIR VERSIONS IN SUBDIRECTORIES. Copied from z rather
# than derived, because in z it is a literal `switch` and there is nothing to
# derive it from. When `.mt` becomes the workspace's own directory this belongs
# in the manifest, where it can be read instead of restated.
proc ::machteld::FrontVersioned {} { return {go node python sqlite tcltk twapi} }

proc ::machteld::FrontRuntimes {} {
    variable FRONT_HOME
    FrontRoots
    set root [file join $FRONT_HOME r]
    if {![file isdirectory $root]} { return {} }
    # Every tool resolved once, because an alias is "a curated tool whose
    # executable, prepended argument or environment value lives under this
    # payload" -- which is a fact about the RESOLVED target, not about the
    # manifest text.
    set targets {}
    foreach n [FrontToolNames] {
        if {[catch {FrontResolve $n} t]} continue
        lappend targets [list $n $t]
    }
    set out {}
    foreach d [lsort [glob -nocomplain -types d -directory $root *]] {
        set name [file tail $d]
        set vers {}
        if {$name in [FrontVersioned]} {
            foreach v [lsort [glob -nocomplain -types d -directory $d *]] {
                if {[string index [file tail $v] 0] eq "."} continue
                lappend vers [file tail $v]
            }
        }
        if {![llength $vers]} {
            lappend out [FrontRuntimeRow $name "" $d $targets]
            continue
        }
        foreach v $vers { lappend out [FrontRuntimeRow $name $v [file join $d $v] $targets] }
    }
    return $out
}

# `aliases` and `version` are OMITTED when empty rather than emitted as an empty
# list -- z's struct tags say `omitempty`, and the JSON has to agree key for key
# and not merely carry the same information.
proc ::machteld::FrontRuntimeRow {name version path targets} {
    set row [dict create name $name]
    if {$version ne ""} { dict set row version $version }
    dict set row path [file nativename $path]
    set a [FrontAliasesUnder $path $targets]
    if {[llength $a]} { dict set row aliases $a }
    return $row
}

proc ::machteld::FrontAliasesUnder {base targets} {
    set out {}
    foreach pair $targets {
        lassign $pair n t
        set cands {}
        if {[dict exists $t exe]} { lappend cands [dict get $t exe] }
        if {[dict exists $t pre]} { lappend cands {*}[dict get $t pre] }
        if {[dict exists $t env]} { dict for {_ v} [dict get $t env] { lappend cands $v } }
        foreach c $cands {
            if {[FrontWithin $base $c]} { lappend out $n ; break }
        }
    }
    return [lsort $out]
}

# `base` contains `candidate`, or is it. Case-insensitively, because Windows
# paths are, and z compares them that way.
proc ::machteld::FrontDictOr {d key default} {
    if {[dict exists $d $key] && [dict get $d $key] ne ""} { return [dict get $d $key] }
    return $default
}

# CLEANED LEXICALLY, NOT NORMALISED. `file normalize` FOLLOWS LINKS, and
# `.z/r/winsdk` is a junction into Program Files -- so normalising the payload
# directory and the tool's executable produced two paths in different trees and
# `signtool` stopped counting as a winsdk alias. z uses `filepath.Clean`, which
# is purely textual, and the question here is "is this path WRITTEN underneath
# that one", which is a question about the names rather than about the disk.
#
# One row of fourteen differed, because exactly one payload is a junction.
# Nothing about the shape of the code says which of the two is wrong.
proc ::machteld::FrontClean {p} {
    set segs [split [string map {\\ /} $p] /]
    set lead ""
    if {[llength $segs] > 2 && [lindex $segs 0] eq "" && [lindex $segs 1] eq ""} {
        set lead "//" ; set segs [lrange $segs 2 end]        ;# a UNC share
    } elseif {[lindex $segs 0] eq ""} {
        set lead "/"  ; set segs [lrange $segs 1 end]
    }
    set out {}
    foreach s $segs {
        if {$s eq "" || $s eq "."} continue
        if {$s eq ".." && [llength $out]} { set out [lrange $out 0 end-1] ; continue }
        lappend out $s
    }
    return $lead[join $out /]
}

proc ::machteld::FrontWithin {base candidate} {
    if {$base eq "" || $candidate eq ""} { return 0 }
    set b [FrontClean $base]
    set c [FrontClean $candidate]
    if {[string equal -nocase $b $c]} { return 1 }
    if {[string index $b end] ne "/"} { append b "/" }
    return [string equal -nocase -length [string length $b] $c $b]
}

# --- `cdirs`: the directory index, and the consequence z counts but never says -
#
# THE VERB WALKS; THIS DECIDES WHAT THE WALK MEANS. `dirs` is C because
# enumeration, reparse classification, the `\\?\` prefix and the emission order
# are the four things Tcl genuinely cannot reach, and [the register](direction.md)
# records it stopping there deliberately: `-out` was cut because it "is three
# lines of `open`/`puts`" and would have left the principal result key silently
# empty whenever it was used, and `elapsed` because "`clock milliseconds` on
# either side of the call is the same number" and "makes the verb never twice
# the same". Both objections are arguments FOR putting them one layer up. A
# command's product IS a file, so there is no result key to empty; and this is
# the caller with the two `clock milliseconds` calls, reporting a RUN rather than
# returning a value that ought to be reproducible. That is [rule 4] read from the
# other end, and it is why `-out` is wrong in the verb and right here.
#
# WHAT THIS COMMAND IS FOR, in one measurement taken on this machine. Under
# `C:/Users/anafa` the walk finds 236,162 directories and `z cdirs` finds
# 112,018. The entire difference is 124,144 directories under ONE reparse point
# -- `C:/Users/anafa/OneDrive`, tag `0x9000701a`, surrogate bit clear -- which z
# refuses to descend because it refuses every reparse point, and which `dirs`
# descends because it refuses only NAME SURROGATES. z is not silent about the
# decision. It is silent about the CONSEQUENCE: its stats line says "12 links
# skipped" and names none of the twelve, so eleven junctions that really are a
# second name for somewhere else and one placeholder root hiding more than half
# the home tree arrive as the same integer. Counted, consequence invisible.
#
# So the rule the report below is built on, and each clause is doing work:
#
#   A refusal the WALKER made is NAMED. A refusal the CALLER asked for is
#   COUNTED. The completeness verdict sits on the first line, beside the count,
#   so the count cannot be read alone.
#
# NAMED, for the walker's decisions, because the size of what lies behind a
# place the walk did not enter is not knowable WITHOUT entering it -- that is
# what not entering means, not a gap in the implementation. The number can
# therefore never be reported, and a report offering one instead invites the
# reader to take it for the magnitude of the loss. The one honest disclosure
# available is the PLACE: a reader who sees `C:/Users/anafa/OneDrive` knows the
# scale instantly, and a reader who sees `12` knows nothing. It is affordable
# exactly where it matters -- eleven such places in the whole home tree, two in
# the workspace.
#
# COUNTED, for `-prune` and `-depth`, because the caller already knows the
# criterion and restating it carries what naming each path would; it is also the
# only choice the verb permits, `pruned` and `depthlimited` being integers
# rather than path lists. The wording must not overclaim, and [the
# palette](palette.md) says why: those count REFUSALS, not elisions, and a leaf
# with nothing under it is counted too.
#
# VERDICT FIRST, because z's stats line is lowercase prose that reads as
# reassurance and needs arithmetic before it admits anything is missing.
# `[PARTIAL]` sits in the headline, in the same breath as the count.

namespace eval ::machteld {
    # HOW MANY PATHS A NAMED GROUP PRINTS before it says "and N more". The cap
    # exists so a tree carrying five thousand symlinks does not print five
    # thousand lines; it is set ABOVE the largest real case measured here -- the
    # home tree's eleven junctions -- so that the case this command was built
    # for prints in full rather than being the first thing the cap hides. The
    # count on the header line is always exact, and the sidecar and `-json` form
    # always carry every row.
    variable FRONT_DIRS_CAP 20
}

# THE DOMAIN IS THE VERB YOU CALLED, so a failure that started in `dirs` comes
# back as FRONT. [The contract](contract.md) states the rule and `FrontManifest`
# already sets the precedent, catching a `json decode` failure and re-raising it
# as `{MACHTELD FRONT manifest}`. The inner MESSAGE is preserved verbatim --
# `dirs` says which spelling of a bad root works, and that sentence is the useful
# part -- and only the domain is corrected.
#
# FOUR LITERAL ARMS, NOT `Fail FRONT $code $msg`, and this is not style. The
# manifest reads a Tcl verb's codes out of its own body with
# `{Fail\s+([A-Z]+)\s+([a-z]+)\s}`; a variable in the code position matches
# nothing, so the one-line version would leave `manifest front codes` denying
# two codes the command really raises while every test still passed. That is not
# hypothetical: the identical shape happened in the C, where folding
# free-and-raise into one helper moved the code literal out of the argument
# position `genmanifest.tcl` reads and the build reported `dirs codes=1` against
# a truth of four.
# AN EMPTY LIST THAT `json encode` WILL RENDER AS `[]` EVERY TIME.
#
# The encoder reads a value's own representation -- a dict is an object, a list
# is an array, anything else is a scalar -- and that rule is right; the failure
# is that an EMPTY list barely has a representation, and Tcl's empty string is a
# single shared object per interpreter. Whatever any line anywhere in the process
# last did to that literal is what the encoder sees. Measured here, all three
# outcomes from the same `[list]` in the same build: `[]`, `{}` and `""`.
# `json decode {[]}`, which looks like the obvious answer, gives `""`.
#
# `lrange` over a one-element list is the form that works, because it returns a
# FRESH list object rather than the shared literal. It reads oddly and it is
# honest: the alternative is a report whose `refused` key is an object on exactly
# the runs where nothing was refused.
proc ::machteld::FrontEmptyList {} { return [lrange [list x] 1 1] }

proc ::machteld::FrontDirsReraise {o msg} {
    set code ""
    if {[dict exists $o -errorcode]} {
        set ec [dict get $o -errorcode]
        if {[lindex $ec 0] eq "MACHTELD"} { set code [lindex $ec 2] }
    }
    switch -- $code {
        badvalue { Fail FRONT badvalue $msg }
        notfound { Fail FRONT notfound $msg }
        oserror  { Fail FRONT oserror  $msg }
        default  { Fail FRONT usage    $msg }
    }
}

# THE FILENAME IS DERIVED FROM THE ROOT, because z's is not and it lies. z writes
# every walk to the fixed name `c-drive-dirs.txt`, so `z cdirs --root C:\dev`
# puts 21,804 workspace directories in a file whose name says "c-drive" -- and
# overwrites the drive index doing it. Deriving the name means re-running the
# same root replaces the same file and two different roots cannot collide.
#
# The NORMALISED root is the key, never the string the caller typed, so `c:\dev\`,
# `C:/dev` and `\\?\C:\dev` all name one artefact instead of three.
#
# BUT THE SQUASH IS LOSSY, AND THAT CLAIM SHIPPED FALSE. `regsub -all
# {[^a-z0-9]+} -> "-"` maps `C:/dev/_x`, `C:/dev-x`, `C:/dev.x` and `C:/dev x`
# onto one name, and the hash tail fired only above 64 characters -- i.e.
# everywhere EXCEPT where the short, ordinary roots that collide live. Measured
# against the real indices on this machine, two genuine pairs already collided:
# `C:/Users/anafa/.codex/.tmp` against `.../.codex/tmp`, and
# `OneDrive/_LIVE` against `OneDrive/live` -- the second run silently replacing
# the first's index with no warning from either. Sharper still, a root whose last
# component is entirely non-ASCII squashed to its PARENT, so
# `C:/Users/anafa/\u00c4` wrote itself over `c-users-anafa`, the flagship
# artefact. That is z's `c-drive-dirs.txt` defect in a new spelling, in the one
# proc whose comment promised it could not happen.
#
# THE TEST FOR "SAFE" IS AN INVERSE, NOT A RULE OF THUMB. `FrontDirsUnslug`
# reconstructs the root that a lossless slug must have come from; if it does not
# reproduce the lowercased root exactly, the squash threw something away and the
# hash decides instead. Two things fall out. The ordinary roots keep their
# readable names -- `C:/dev` -> `c-dev`, `C:/Users/anafa` -> `c-users-anafa`,
# `//srv/share/x` -> `srv-share-x` -- because those really are recoverable. And
# the tail is joined with `--`, a sequence the lossless branch can never produce
# (it would need an empty path component), so a hashed slug can never collide
# with an unhashed one either.
proc ::machteld::FrontDirsUnslug {s} {
    set parts [split $s -]
    # A ONE-CHARACTER FIRST COMPONENT IS A DRIVE LETTER, which is also why
    # `//a/b` and `A:/b` -- both `a-b` under the old rule, and a real collision
    # between a UNC share and a drive -- now differ: only one of them survives
    # this reconstruction.
    if {[string length [lindex $parts 0]] == 1} {
        return "[lindex $parts 0]:/[join [lrange $parts 1 end] /]"
    }
    return "//[join $parts /]"
}

proc ::machteld::FrontDirsSlug {root} {
    set low [string tolower $root]
    set s $low
    regsub -all -- {[^a-z0-9]+} $s "-" s
    set s [string trim $s -]
    # A root of pure punctuation cannot happen through `dirs`, which refuses an
    # empty root -- but an empty filename is a silent disaster rather than a
    # visible one, so it is answered rather than assumed away.
    if {$s eq ""} { set s root }
    # DEEP ROOTS REACH THE LENGTH ARM ON THIS MACHINE: anything under
    # AppData/Local/Packages/<package>/LocalCache/... is past 64 characters once
    # squashed, and an unbounded slug pushes the cache path toward its own length
    # limit. The tail is hashed over the FULL lowercased root, so two roots
    # sharing a 55-character prefix still key different files -- and hashing the
    # LOWERCASED root rather than the string as typed is what keeps `c:\dev\_X`
    # and `C:/dev/_x` one artefact instead of two.
    if {[string length $s] > 64 || [FrontDirsUnslug $s] ne $low} {
        set s "[string range $s 0 53]--[string range [hash sum sha256 $low] 0 7]"
    }
    return $s
}

# NAMING A TAG IS POLICY, SO IT IS TCL. `dirs` reports `0x9000701a` and the front
# door says `cloud`, which is [rule 4] again in its smallest form.
#
# THE TABLE NAMES ONLY WHAT `dirs.c` ITSELF NAMES, plus the cloud family, and it
# stops there on purpose. A table of half-remembered reparse constants would be
# the front door asserting knowledge the C's own veto rule does not have, and the
# two would drift apart with nothing to notice. The cloud MASK is reasoned from
# the documented meaning of the `IO_REPARSE_TAG_CLOUD_1`..`_F` family; only
# `0x9000701a` has ever been observed here, which is said out loud for the same
# reason `dirs.c` says it about its DFS pair.
#
# `0x00000000` is a real answer and not "no tag": `dirs.c` records that a cloud
# root reads its tag from the directory scan and reads 0 through a HANDLE,
# because the filter consumes its own reparse point. Such a row says `reparse`
# rather than being mistaken for an ordinary directory.
proc ::machteld::FrontDirsTag {tag} {
    switch -- [format 0x%08x $tag] {
        0xa0000003 { return junction }
        0xa000000c { return symlink }
        0x8000000a { return dfs }
        0x80000012 { return dfsr }
        0x00000000 { return reparse }
    }
    if {($tag & 0xffff0fff) == 0x9000001a} { return cloud }
    return [format 0x%08x $tag]
}

# The verb's dict becomes the report's dict here, and NOTHING ELSE in this
# command touches the filesystem to do it. That split is what makes the whole
# report testable: a fixture hands this proc a synthesised `dirs` result and
# asserts the verdict and the rows without a disk anywhere. It matters more here
# than usual -- the review of `dirs` itself found FIVE gates that could not fail,
# every one of them pointed at a subject that could not exhibit the defect.
proc ::machteld::FrontDirsReport {d ms depth prune} {
    # THE JOIN, and it is the easiest thing in this file to get wrong. A `links`
    # row whose action is `failed` ALWAYS has an `errors` row beside it -- the
    # descent was attempted and the open failed -- so concatenating the two lists
    # reports one place twice and makes the headline disagree with the rows under
    # it. Keyed on the path, so such a place appears ONCE carrying both its tag
    # and its Win32 code.
    set order [list]
    set rows [dict create]
    foreach e [dict get $d errors] {
        set p [dict get $e path]
        if {![dict exists $rows $p]} { lappend order $p }
        dict set rows $p [dict create path $p why unreadable \
                              win32 [dict get $e win32] reason [dict get $e reason]]
    }
    foreach l [dict get $d links] {
        set act [dict get $l action]
        # `pruned` and `depthlimited` link rows are deliberately NOT added here.
        # `dirs.c` has already counted those in the two integers below, and
        # counting them again would break the arithmetic the palette guarantees:
        # every absent directory attributable to EXACTLY ONE cause.
        if {$act ni {nofollow failed}} continue
        set p [dict get $l path]
        set r [expr {[dict exists $rows $p] ? [dict get $rows $p] : [dict create path $p]}]
        if {![dict exists $rows $p]} { lappend order $p }
        dict set r why       [FrontDirsTag [dict get $l tag]]
        dict set r tag       [format 0x%08x [dict get $l tag]]
        dict set r surrogate [dict get $l surrogate]
        dict set rows $p $r
    }
    set refused [list]
    foreach p $order { lappend refused [dict get $rows $p] }

    # THE REVERSE SILENCE IS ALSO POSSIBLE, and this block is the answer to it. A
    # reader expecting z's semantics gets 236,162 lines where z gave 112,018 and
    # has no way to learn why; the reparse directories that WERE entered are
    # disclosed too, so the difference is stated rather than discovered by
    # diffing two files.
    #
    # AND DISCLOSING THE PLACE IS NOT ENOUGH, which is the half of this that
    # shipped missing. The indictment of z is "counted, consequence invisible":
    # `12 links skipped` names none of the twelve. A report that names the place
    # and gives no number is the same failure with the terms swapped -- NAMED,
    # MAGNITUDE INVISIBLE -- and a reader who does not already know z gets no
    # signal that 124,144 of 236,162 lines, 52.6% of the whole answer, came from
    # one row. The doc's reason for refusing a number is exact about `refused`
    # ("not knowable without entering it") and FALSE here: the walk DID enter,
    # the paths are in hand, and a prefix count over them is sub-second against a
    # twenty-second walk. So `below` is counted for every entered row.
    #
    # Only the non-surrogates are counted by prefix; a descended SURROGATE can
    # only be the root you named, where the answer is the whole list by
    # construction and a second pass would be arithmetic dressed as measurement.
    set entered [list]
    foreach l [dict get $d links] {
        if {[dict get $l action] ne "descended"} continue
        set p [dict get $l path]
        set row [dict create path $p \
                     why       [FrontDirsTag [dict get $l tag]] \
                     tag       [format 0x%08x [dict get $l tag]] \
                     surrogate [dict get $l surrogate]]
        if {[dict get $l surrogate]} {
            dict set row below [expr {[dict get $d dirs] - 1}]
        } else {
            set pre "$p/" ; set n [string length $pre] ; set c 0
            foreach q [dict get $d paths] {
                if {[string equal -nocase -length $n $pre $q]} { incr c }
            }
            dict set row below $c
        }
        lappend entered $row
    }

    # THE VERDICT IS CONSERVATIVE ON PURPOSE. `PARTIAL` means "the walk declined
    # to enter somewhere", not "something is definitely missing" -- a
    # depth-limited walk whose cut points are all leaves is PARTIAL although
    # nothing was lost. For a cache index, erring toward "you may not have
    # everything" is the safe direction, and the blocks below say which reading
    # applies in each case.
    set complete [expr {![llength $refused] && [dict get $d pruned] == 0
                        && [dict get $d depthlimited] == 0}]
    # AN EMPTY LIST HAS TO BE MADE TO ENCODE AS ONE, and this cost a shipped
    # defect to learn. `json encode` decides array-versus-object from a value's
    # own internal representation -- which is the right rule and the one [the
    # contract](contract.md) documents -- but an empty list has no representation
    # worth the name, and Tcl's empty string is ONE SHARED OBJECT for the whole
    # interpreter. So the answer depends on what some unrelated line did to that
    # literal earlier in the process. Measured in one binary, on one afternoon:
    # `mt cdirs C:/dev` wrote a sidecar saying `"entered":{}` and `"prune":{}`
    # while `front cdirs` on the fixture, same build, wrote `[]` for both. The
    # contract's own escape hatch -- "say -dict or -list" -- reaches only the TOP
    # level of a document, and these are nested.
    #
    # `FrontEmptyList` is the one form that is stable, and a consumer looping
    # over `report.refused` is exactly the reader who breaks on `{}` -- on the
    # runs where nothing was refused, which is the common case.
    if {![llength $refused]} { set refused [FrontEmptyList] }
    if {![llength $entered]} { set entered [FrontEmptyList] }
    set prune [lrange $prune 0 end]
    if {![llength $prune]} { set prune [FrontEmptyList] }
    set rep [dict create \
                 root         [dict get $d root] \
                 dirs         [dict get $d dirs] \
                 maxdepth     [dict get $d maxdepth] \
                 elapsed      $ms \
                 when         [clock seconds] \
                 complete     [expr {$complete ? 1 : 0}] \
                 refused      $refused \
                 entered      $entered \
                 pruned       [dict get $d pruned] \
                 prune        $prune \
                 depthlimited [dict get $d depthlimited]]
    # `depth` IS ABSENT WHEN NO LIMIT WAS ASKED FOR, rather than present and
    # empty -- the rule `status` already follows for the keys it cannot fill. It
    # is not merely tidier here, it is the only unambiguous encoding available:
    # `-depth 0` is a real and very different request from "no -depth at all",
    # and an empty string is exactly the value `json` maps `null` to, so a
    # present-but-empty `depth` would be indistinguishable from a caller who
    # passed nothing. Present means a limit was requested; absent means the walk
    # was unbounded, in which case `depthlimited` is necessarily 0.
    if {$depth ne ""} { dict set rep depth $depth }
    return $rep
}

# WRITE, THEN PUBLISH, and the ordering buys a real invariant on a command that
# runs for twenty seconds and can be interrupted: a present sidecar means the
# list beside it is whole. Both temporaries are complete before either is
# renamed, and the OLD sidecar is deleted BEFORE the new list lands -- so the
# window in which the two disagree shows an ABSENT report rather than a stale
# one describing a list it was never a report of. A walk that raises writes
# nothing at all, because a failed run must not destroy a good cache.
#
# z's sidecar cannot make this claim: it is created unconditionally and only
# sometimes mentioned, so its presence says nothing and its absence has two
# meanings -- clean run, or the run died.
proc ::machteld::FrontDirsWrite {d rep out} {
    set report "[file rootname $out].json"
    # `-out index.json` would otherwise make the report overwrite the list it is
    # a report OF. One character of typo, one artefact destroyed, nothing said.
    if {[string equal -nocase $report $out]} { set report "$out.report.json" }
    # NEITHER DESTINATION MAY BE A DIRECTORY, and both are refused BEFORE a byte
    # is written, because both used to be silent disasters.
    #
    # `file rename` moves a file INTO a directory target. So `-out <a directory>`
    # reported `[COMPLETE]`, exit 0, named the directory as the `list` and wrote
    # a sidecar saying `"bytes":96` about it -- while the list itself sat
    # orphaned inside as `<dir>/<dir>.tmp`. That is this proc's own invariant --
    # a present sidecar means the list beside it is whole -- broken in the one
    # direction nothing else could catch, plus a stray `.tmp`.
    #
    # And the sidecar's publish step used to delete whatever stood in its way, so
    # `-out notes.txt` beside a DIRECTORY named `notes.json` removed it and
    # everything under it, silently, before writing anything. Overwriting a FILE
    # there is documented and intended; `rm -rf` of a tree is not.
    if {[file isdirectory $out]} {
        Fail FRONT oserror "cdirs: -out $out is a directory, not a file"
    }
    if {[file isdirectory $report]} {
        Fail FRONT oserror "cdirs: the report would go to $report, which is a directory"
    }
    set dir [file dirname $out]
    if {[catch {file mkdir $dir} e]} {
        Fail FRONT oserror "cdirs: cannot create $dir: $e"
    }
    # utf-8 AND lf, neither of which is Tcl's default on Windows, and both of
    # which matter. `auto` translation emits CRLF, and paths here genuinely carry
    # non-ASCII -- `dirs.c`'s notes about CP_UTF8 and U+E000 exist because of the
    # names on this disk. Written a line at a time rather than as one `join`,
    # because the join materialises a second 23 MB string to no purpose.
    set fh ""
    if {[catch {
        set fh [open $out.tmp w]
        fconfigure $fh -encoding utf-8 -translation lf
        foreach p [dict get $d paths] { puts $fh $p }
        close $fh
        set fh ""
    } e]} {
        if {$fh ne ""} { catch {close $fh} }
        catch {file delete -force $out.tmp}
        Fail FRONT oserror "cdirs: cannot write $out: $e"
    }
    dict set rep list   $out
    dict set rep report $report
    dict set rep bytes  [file size $out.tmp]
    if {[catch {
        set fh [open $report.tmp w]
        fconfigure $fh -encoding utf-8 -translation lf
        puts $fh [json encode $rep]
        close $fh
        set fh ""
    } e]} {
        if {$fh ne ""} { catch {close $fh} }
        catch {file delete -force $out.tmp $report.tmp}
        Fail FRONT oserror "cdirs: cannot write $report: $e"
    }
    # PUBLISH IS ORDERED AND REVERSIBLE, and the second half of that is the fix
    # for the one path in this proc that could destroy something. What stood here
    # DELETED the old sidecar first and then renamed; when the rename failed --
    # the list file held open by a reader is enough -- the command raised
    # `oserror`, cleaned its temporaries, and left the previous run's list with no
    # report at all. "A failed run must not destroy a good cache" was written four
    # lines above the only line that could break it, and CD11 gated the `file
    # mkdir` failure, which aborts before ever reaching it.
    #
    # Moving it aside instead answers both directions. If the LIST cannot be
    # replaced, nothing has happened yet: the sidecar goes back and the previous
    # run survives whole. If the list lands and the REPORT cannot, the sidecar is
    # ABSENT rather than restored -- because a report describing a list it was
    # never a report of is precisely the state this ordering exists to make
    # impossible, and absence is the honest reading of "the run died here".
    set saved ""
    if {[file exists $report]} { set saved "$report.prev" }
    set moved 0
    if {[catch {
        if {$saved ne ""} { file rename -force $report $saved }
        file rename -force $out.tmp $out
        set moved 1
        file rename -force $report.tmp $report
    } e]} {
        if {$saved ne "" && !$moved} { catch {file rename -force $saved $report} }
        catch {file delete -force $out.tmp $report.tmp}
        if {$saved ne ""} { catch {file delete -force $saved} }
        Fail FRONT oserror "cdirs: cannot publish $out: $e"
    }
    if {$saved ne ""} { catch {file delete -force $saved} }
    return $rep
}

# THOUSANDS SEPARATORS, in the one command whose whole subject is large numbers
# whose magnitude is the point. `236162` and `236,162` are the same fact and not
# the same sentence; the rest of the front door's plainer output does without
# this, and here it earns its six lines.
proc ::machteld::FrontThousands {n} {
    set s [string trimleft $n -]
    set out ""
    while {[string length $s] > 3} {
        set out ",[string range $s end-2 end]$out"
        set s [string range $s 0 end-3]
    }
    if {$n < 0} { return "-$s$out" }
    return "$s$out"
}

proc ::machteld::FrontDirsBytes {n} {
    if {$n < 1024}       { return "$n B" }
    if {$n < 1048576}    { return [format "%.1f KB" [expr {$n / 1024.0}]] }
    if {$n < 1073741824} { return [format "%.1f MB" [expr {$n / 1048576.0}]] }
    return [format "%.1f GB" [expr {$n / 1073741824.0}]]
}

# The report dict becomes text here, and this proc reads NOTHING but the dict it
# is handed. Pairing a pure dict->dict builder with a pure dict->string renderer
# is what makes "the human text and the JSON are the same numbers" true by
# construction instead of by discipline -- there is no second set of counters to
# drift, which is the way a stats line usually starts lying.
proc ::machteld::FrontDirsText {rep} {
    variable FRONT_DIRS_CAP
    set L 16
    set out [list]
    lappend out [format "cdirs \[%s\]  %s director%s under %s in %.1fs" \
        [expr {[dict get $rep complete] ? "COMPLETE" : "PARTIAL"}] \
        [FrontThousands [dict get $rep dirs]] \
        [expr {[dict get $rep dirs] == 1 ? "y" : "ies"}] \
        [dict get $rep root] [expr {[dict get $rep elapsed] / 1000.0}]]
    # Absent under `-stdout`, where there are no files to name -- and absent
    # rather than named-as-empty, the same rule `status` follows for the keys it
    # cannot fill.
    if {[dict exists $rep list]} {
        lappend out [format "%-*s %s  (%s)" $L list [dict get $rep list] \
                         [FrontDirsBytes [dict get $rep bytes]]]
        lappend out [format "%-*s %s" $L report [dict get $rep report]]
    }

    set refused [dict get $rep refused]
    if {[llength $refused]} {
        lappend out ""
        lappend out [format "%-*s %s place%s. The walk stopped %s; what is inside is not in" \
            $L refused [FrontThousands [llength $refused]] \
            [expr {[llength $refused] == 1 ? "" : "s"}] \
            [expr {[llength $refused] == 1 ? "there" : "at each"}]]
        lappend out [format "%-*s %s" $L "" \
            "the list, and how much is there cannot be known from here."]
        set groups [dict create]
        foreach r $refused { dict lappend groups [dict get $r why] $r }
        # `unreadable` leads, because a directory you may not open is a different
        # kind of news from a link the walk declined by policy; the rest follow in
        # the order the walk met them, which is tree order and reads that way.
        set kinds [dict keys $groups]
        if {"unreadable" in $kinds} {
            set kinds [linsert [lsearch -all -inline -not -exact $kinds unreadable] 0 unreadable]
        }
        foreach why $kinds {
            set rows [dict get $groups $why]
            set n 0
            foreach r $rows {
                incr n
                if {$n > $FRONT_DIRS_CAP} continue
                set note ""
                if {[dict exists $r win32]} { set note "win32 [dict get $r win32]" }
                lappend out [format "  %-*s %s%s" [expr {$L - 2}] $why [dict get $r path] \
                                 [expr {$note eq "" ? "" : "   ($note)"}]]
            }
            if {[llength $rows] > $FRONT_DIRS_CAP} {
                lappend out [format "  %-*s ... and %s more (all of them in %s)" \
                    [expr {$L - 2}] "" [FrontThousands [expr {[llength $rows] - $FRONT_DIRS_CAP}]] \
                    [expr {[dict exists $rep report] ? [dict get $rep report] : "the -json form"}]]
            }
        }
    }

    set pruned [dict get $rep pruned]
    set dlim   [dict get $rep depthlimited]
    if {$pruned || $dlim} {
        lappend out ""
        set label "by request"
        # SINGULARISED, in the one command whose subject is the wording of a
        # count. `1 directories` in a report that says `1 directory`, `1 place`
        # and `1 reparse directory` three lines apart is small, and it is the
        # same class of thing as the rest of this file: the sentence and the
        # number disagreeing where only the number was checked.
        if {$dlim} {
            lappend out [format "%-*s %s director%s at the -depth %s limit" \
                $L $label [FrontThousands $dlim] [expr {$dlim == 1 ? "y" : "ies"}] \
                [expr {[dict exists $rep depth] ? [dict get $rep depth] : "?"}]]
            set label ""
        }
        if {$pruned} {
            lappend out [format "%-*s %s director%s matching -prune {%s}" \
                $L $label [FrontThousands $pruned] [expr {$pruned == 1 ? "y" : "ies"}] \
                [dict get $rep prune]]
        }
        lappend out [format "%-*s %s" $L "" \
            "These are counted refusals, not missing subtrees: a directory"]
        lappend out [format "%-*s %s" $L "" \
            "with nothing under it is counted here too."]
    }

    set entered [dict get $rep entered]
    set content [lmap r $entered {expr {[dict get $r surrogate] ? [continue] : $r}}]
    set named   [lmap r $entered {expr {[dict get $r surrogate] ? $r : [continue]}}]
    if {[llength $content]} {
        # THE COMPLETENESS SENTENCE IS CONDITIONAL, because the unconditional one
        # was FALSE exactly where being wrong costs the most. `Everything under it
        # IS in the count above` was printed on every run that had an entered row,
        # including `mt cdirs C:/Users/anafa -depth 3`, where ~124,000 directories
        # under that very row are NOT in the count. That is the report telling a
        # reader the list is complete below a place where it is not -- the one
        # direction this whole command exists to prevent, in its own output, with
        # no gate reading the string.
        #
        # Conservative in the same direction as the verdict: any `-prune`, any
        # `-depth` cut, or any refusal lying below an entered row drops the strong
        # claim, even when the cut was somewhere else entirely.
        set whole [expr {[dict get $rep pruned] == 0 && [dict get $rep depthlimited] == 0}]
        if {$whole} {
            foreach rr $refused {
                if {![dict exists $rr path]} continue
                foreach c $content {
                    if {[FrontWithin [dict get $c path] [dict get $rr path]]} { set whole 0 }
                }
            }
        }
        set one [expr {[llength $content] == 1}]
        lappend out ""
        lappend out [format "%-*s %s reparse director%s that %s content, not a second name for" \
            $L entered [FrontThousands [llength $content]] \
            [expr {$one ? "y" : "ies"}] [expr {$one ? "is" : "are"}]]
        if {$whole} {
            lappend out [format "%-*s somewhere else, and everything under %s IS in the count above." \
                $L "" [expr {$one ? "it" : "them"}]]
        } else {
            lappend out [format "%-*s somewhere else. This run also stopped early -- see above -- so" \
                $L ""]
            lappend out [format "%-*s what is under %s is only PARTLY in the count above." \
                $L "" [expr {$one ? "it" : "them"}]]
        }
        # AND THE MAGNITUDE, per row, because the place alone is the same silence
        # z is indicted for with the terms swapped. `entered  1 reparse directory
        # ... C:/Users/anafa/OneDrive` says a true thing and hides that HALF THE
        # ANSWER came from that one line.
        foreach r $content {
            lappend out [format "  %-*s %-50s tag %s" [expr {$L - 2}] [dict get $r why] \
                             [dict get $r path] [dict get $r tag]]
            set b [FrontDictOr $r below 0]
            lappend out [format "%-*s %s of the %s director%s above -- %.1f%% of this answer -- %s under it" \
                $L "" [FrontThousands $b] [FrontThousands [dict get $rep dirs]] \
                [expr {[dict get $rep dirs] == 1 ? "y" : "ies"}] \
                [expr {100.0 * $b / [dict get $rep dirs]}] \
                [expr {$b == 1 ? "is" : "are"}]]
        }
    }
    # A SURROGATE THAT WAS DESCENDED CAN ONLY BE THE ROOT YOU NAMED, and it is
    # the one disclosure the verb's review found missing entirely: a junction
    # root used to produce no `links` row at all, so nothing anywhere in the
    # answer said that every path returned is a second name for a tree living
    # somewhere else. 576 checks passed over that. Saying it here as well means
    # the front door does not re-introduce the silence one layer up.
    if {[llength $named]} {
        lappend out ""
        lappend out [format "%-*s %s reparse director%s the walk entered because you NAMED it." \
            $L named [FrontThousands [llength $named]] \
            [expr {[llength $named] == 1 ? "y" : "ies"}]]
        lappend out [format "%-*s %s" $L "" \
            "Every path in this list is a second name for a tree living elsewhere."]
        foreach r $named {
            lappend out [format "  %-*s %-50s tag %s" [expr {$L - 2}] [dict get $r why] \
                             [dict get $r path] [dict get $r tag]]
        }
    }
    return [join $out \n]
}

proc ::machteld::front {args} {
    set subs {roots which env tools run journal projects runtimes status in verify scout cdirs}
    # THE DECLARED TABLE IS THE MANIFEST'S ANSWER, so an option missing here is
    # an option the palette denies having. `-inherit` was missing: `front run
    # -inherit` worked, the manifest said `front` took only -json, and the docs
    # gate called the working example a typo.
    #
    # `cdirs` ADDS FOUR AND NOT A FIFTH, and the one it does not add is the
    # reason this comment grew. Its root is a POSITIONAL, spelled the way `dirs`
    # spells its own subject, because a command built over a verb must not
    # respell the verb's grammar -- [rule 1] read at the command layer. A
    # `--root` alias would have to be either declared here, making the manifest
    # assert an option that duplicates a positional, or left undeclared, making
    # the running binary accept something the manifest denies. Both break [rule
    # 6]. The `-json`/`--json` concession is safe because those are two
    # spellings of ONE option; a positional against an option is a different
    # grammar, not a different spelling.
    set opts {-depth -inherit -json -out -prune -stdout}
    if {![llength $args]} {
        Fail FRONT usage "usage: front roots | front which name | front env name ?-json?\
                          | front tools ?pattern? | front run ?-inherit? ?--? name ?arg ...?\
                          | front journal | front projects ?-json? | front runtimes ?-json?\
                          | front cdirs ?root? ?-depth n? ?-prune patterns? ?-out file? ?-stdout? ?-json?"
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

    # `tools` PRINTS WHAT z PRINTS -- `name<TAB>exe`, one per line -- because the
    # point of promoting it to `mt tools` is that it can be typed where `z tools`
    # was. `-json` is the shape a script wants and the shape z never had; that is
    # where the dict contract lives now.
    if {$sub eq "tools"} {
        set asjson 0 ; set pat "*"
        foreach a [lrange $args 1 end] {
            if {$a in {-json --json}} { set asjson 1 ; continue }
            if {$pat ne "*"} { Fail FRONT usage "usage: front tools ?pattern? ?-json?" }
            set pat $a
        }
        set rows {}
        foreach n [lsearch -all -inline -glob [FrontToolNames] $pat] {
            set exe ""
            if {![catch {FrontResolve $n} t] && [dict exists $t exe]} { set exe [dict get $t exe] }
            lappend rows [dict create name $n exe $exe]
        }
        if {$asjson} { return [json encode $rows -list] }
        set out {}
        foreach r $rows { lappend out "[dict get $r name]\t[dict get $r exe]" }
        return [join $out \n]
    }

    # `-json` AND `--json` BOTH, and that is not sloppiness. The palette's
    # convention is one dash; z's is two, and these commands exist to be typed
    # where `z projects --json` was typed. Accepting both is what a strangler
    # costs at the seam -- one of the two spellings can go when z does.
    # `status` IS A COCKPIT, and that is why it is only half here. z's status
    # reports the workspace's git state AND the latest mirror report, the mirror
    # run state, and -- under `--deep` -- the results of `verify` and `ledger
    # check`. Three of those four are the commands [the plan](front-door.md)
    # defers to last, so a faithful `status` cannot precede them. The plan put
    # it in the first batch; the code says otherwise.
    #
    # What is here is exact: root, the `.z` directory's git state, and every
    # hosted project's. What is not here is ABSENT rather than guessed -- no
    # `mirror: null` pretending there is no report when there is one.
    # `in <project> <name> ?args?` -- resolve and run a name IN a project's
    # context rather than in the caller's. The project is found by name with the
    # leading underscore optional and the comparison case-insensitive, which is
    # z's rule; the command runs with the project root as its working directory,
    # and with MT_PROJECT_ROOT / MT_PROJECT_NAME set to that project rather than
    # to wherever the caller happens to be standing.
    if {$sub eq "in"} {
        if {[llength $args] < 3} {
            Fail FRONT usage "usage: front in <project> <name> ?arg ...?"
        }
        set want [string trimleft [lindex $args 1] _]
        set proj ""
        foreach p [FrontProjects] {
            if {[string equal -nocase [dict get $p name] $want]} { set proj $p ; break }
        }
        if {$proj eq ""} { Fail FRONT notfound "no hosted project named \"$want\"" }
        set r [FrontResolve [lindex $args 2] [dict get $proj path]]
        # The project root is the working directory unless the target named one
        # of its own, which a project command does.
        if {![dict exists $r cwd] || [dict get $r cwd] eq [file nativename [pwd]]} {
            dict set r cwd [dict get $proj path]
        }
        return [FrontExec $r 1 [lrange $args 3 end]]
    }

    if {$sub eq "scout"} {
        set asjson 0 ; set showcmds 0 ; set serial 0
        foreach a [lrange $args 1 end] {
            switch -- $a {
                -json - --json         { set asjson 1 }
                -c - --commands        { set showcmds 1 }
                --serial - -serial     { set serial 1 }
                default { Fail FRONT usage "usage: front scout ?-commands? ?--serial? ?-json?" }
            }
        }
        set git ""
        catch {set git [FrontResolve z:git]}
        set dirs [FrontUnderscoreDirs]
        set probed [FrontScoutProbe $dirs $git $serial]
        set rows {}
        foreach d $dirs {
            set row [FrontScoutStatic $d]
            dict set row git    [dict get $probed $d git]
            dict set row branch [dict get $probed $d branch]
            lappend rows $row
        }
        if {$asjson} { return [json encode $rows -list] }
        variable FRONT_ROOT
        set out [list "mt scout" "root: [file nativename $FRONT_ROOT]" ""]
        lappend out [format "%-12s%-8s%-8s%-8s%-18s%s" project z.json readme git branch commands]
        lappend out [string repeat - 72]
        set hosted 0 ; set dirty 0
        foreach r $rows {
            if {[dict get $r zjson]} { incr hosted }
            if {[dict get $r git] eq "dirty"} { incr dirty }
            lappend out [format "%-12s%-8s%-8s%-8s%-18s%s" [dict get $r name] \
                [expr {[dict get $r zjson] ? "yes" : "no"}] \
                [expr {[dict get $r readme] ? "yes" : "no"}] \
                [dict get $r git] [dict get $r branch] [llength [dict get $r commands]]]
            if {$showcmds && [llength [dict get $r commands]]} {
                lappend out "  [join [dict get $r commands] {, }]"
            }
        }
        lappend out ""
        lappend out "summary: [llength $rows] underscore dirs, $hosted hosted projects,\
                     [expr {[llength $rows] - $hosted}] missing z.json, $dirty dirty git repos"
        return [join $out \n]
    }

    # `cdirs ?root? ?-depth n? ?-prune patterns? ?-out file? ?-stdout? ?-json?`
    #
    # ONE POSITIONAL AND FOUR OPTIONS, where z has twelve. Every removal is
    # argued rather than trimmed to taste, and the arguments are worth having
    # here because a surface is easier to grow than to shrink:
    #
    #   `--slash`        -- there is one spelling. The palette fixes forward
    #                       slashes and `dirs` returns them, so machteld's list
    #                       says `C:/Users/...` where z's says `C:\Users\...`.
    #                       ANYTHING READING z's CACHE BYTE-WISE WILL NOT READ
    #                       THIS ONE, which is half of why the default output
    #                       path below must not be z's.
    #   `--tree`         -- two output grammars in one command, one of which
    #                       cannot be grepped, cannot be diffed against
    #                       yesterday's run, and -- decisively -- has nowhere to
    #                       hang the disposition markers that are this command's
    #                       whole reason for existing. A tree of indented
    #                       basenames cannot say "the walk stopped here". A tree
    #                       renderer over `paths` is four lines in the caller.
    #   `--safe`         -- z documents it as "retained for compatibility and is
    #                       now the default policy", i.e. a no-op. A no-op option
    #                       is a lie in the manifest and a shape kept for a
    #                       caller who no longer exists.
    #   `--follow-links` -- UNAVAILABLE, which is stronger than absent. The verb
    #                       has no descent-policy lever (`-links list|follow|skip`
    #                       was refused as "four more dispositions and a `seen`
    #                       set with no receiver asking for it"), and doing it in
    #                       Tcl means rebuilding canonicalisation, containment
    #                       and volume+file-id identity in the prelude. Note that
    #                       a friendly `-follow` arm raising "not supported" would
    #                       be WORSE than nothing: the manifest derives options
    #                       from the table above and from switch arms, so either
    #                       route makes `manifest front options` claim it exists.
    #   `--flush N`      -- z's buffered-writer tuning. `dirs` returns a complete
    #                       list before a byte is written; there is no
    #                       incremental flush to tune.
    #   `--progress N`   -- the verb has no progress to report (`-onprogress` was
    #                       refused as "a spinner, fixed at an interval no
    #                       testable fixture reaches"), so this command cannot
    #                       observe what it is not given. THE HONEST CONSEQUENCE,
    #                       printed here rather than hidden: `mt cdirs
    #                       C:/Users/anafa` prints nothing for ~22 seconds and
    #                       then prints everything at once. That is a real cost,
    #                       and a second argument for the workspace default.
    #   `--quiet`        -- suppresses progress in z; with no progress there is
    #                       nothing to suppress. The only other available meaning
    #                       is "suppress the report", which is a flag for turning
    #                       off the one thing this command was designed around.
    #   `--gc MODE`      -- Go runtime tuning. No analogue, no caller.
    #   `max stack`      -- a fact about z's explicit stack, not about the tree.
    #                       `maxdepth` is the fact about the tree.
    #   `outside root`   -- only ever counts something under `--follow-links`.
    #
    # AND NO `-cloud` / `-nocloud`, which is the option somebody will ask for.
    # Three reasons, strongest last. It would be a switch whose only purpose is
    # to reproduce a behaviour this project has MEASURED to be wrong. The
    # legitimate want underneath "skip OneDrive" is almost never "skip cloud
    # storage as a class" but "don't index that subtree", which is a want about a
    # PLACE, and `-prune` addresses places. And decisively: skipping is a veto
    # INSIDE the walk, the verb exposes no veto hook, so a Tcl-side `-cloud`
    # could only post-filter a list it had already paid the full 22 seconds to
    # build -- delivering a shorter answer at full cost while looking like a
    # skip. That is exactly the class of silent misreport this command exists to
    # end. `-prune OneDrive` works properly in the sense that matters: the veto is
    # in the verb and the time is genuinely saved -- 8.2 s against 22.4 s, and the
    # report gives the COUNT and the PATTERNS, which is all the verb offers.
    #
    # ITS LIMITS RUN BOTH WAYS, and the over-match is the one that fires here.
    # Measured on this machine, `-prune OneDrive` hits FOUR places, not one: the
    # cloud root, `AppData/Local/OneDrive`, `AppData/Local/Microsoft/OneDrive` and
    # an Office asset folder called `onedrive`. The answer is 111,899 against z's
    # 112,015 and it is not a subset of z either -- it DROPS 126 directories z
    # lists, 124 of them the unrelated `AppData/Local/Microsoft/OneDrive` subtree.
    # It matches a NAME and not a tag in both directions: `OneDrive - Contoso`
    # needs `-prune {OneDrive*}` and is missed without it, and anything else on
    # the disk called `onedrive` is taken with it. A way to skip a PLACE cheaply,
    # not a way to reproduce z.
    #
    # AND THE `entered` DISCLOSURE GOES WITH IT: a pruned reparse directory is a
    # refusal the CALLER asked for, so it is counted and not named, and
    # `"entered":[]` is then correct rather than a loss. Naming it would put the
    # same place in two accounts and break the arithmetic the palette guarantees.
    # The caller who typed the word already knows.
    #
    # THE DEFAULT ROOT IS THE WORKSPACE, NOT `C:/`, and that is a deliberate
    # divergence from z rather than an oversight. Three reasons.
    #
    #   The front door's subject is the workspace. `tools`, `projects`,
    #   `runtimes`, `scout`, `verify` and `status` all answer about MT_ROOT
    #   without being told; a bare `mt cdirs` walking `C:\` would be the only
    #   front-door command silently widening its scope past the workspace, at the
    #   highest cost in the whole command set.
    #
    #   The default should be the root where the answer is CHECKABLE, and this
    #   is the argument that actually decides. Under the workspace root machteld
    #   and z agree exactly -- 21,804 against 21,804 on C:/dev, measured, zero
    #   only-in-z and zero only-in-mt. Under `C:/` they disagree BY DESIGN.
    #   Defaulting to the disagreeing root would make the zero-argument form the
    #   one form that can never be validated against the incumbent. Making the
    #   wide, disagreeing walk something you opt into BY NAMING IT puts the
    #   disagreement where it belongs: in a request somebody typed.
    #
    #   Cost. Workspace: ~1.5 s warm, 21,804 directories, a 1.2 MB file. `C:/`:
    #   tens of seconds and 7 MB+, with no output at all until it finishes.
    #
    # `mt cdirs C:/` is one word longer than z's default, and that is the right
    # price for the most expensive thing this command can do.
    if {$sub eq "cdirs"} {
        set root "" ; set out "" ; set tostdout 0 ; set asjson 0
        set depth "" ; set prune {} ; set sawout 0 ; set sawroot 0 ; set sawdepth 0
        set rest [lrange $args 1 end]
        for {set i 0} {$i < [llength $rest]} {incr i} {
            set a [lindex $rest $i]
            switch -- $a {
                -json - --json { set asjson 1 }
                -stdout        { set tostdout 1 }
                -out - -depth - -prune {
                    incr i
                    if {$i >= [llength $rest]} { Fail FRONT usage "front cdirs: $a needs a value" }
                    set v [lindex $rest $i]
                    switch -- $a {
                        -out   { set out $v ; set sawout 1 }
                        -depth { set depth $v ; set sawdepth 1 }
                        -prune { set prune $v }
                    }
                }
                default {
                    if {[string index $a 0] eq "-"} {
                        Fail FRONT usage "front cdirs: unknown option \"$a\":\
                            usage: front cdirs ?root? ?-depth n? ?-prune patterns?\
                            ?-out file? ?-stdout? ?-json?"
                    }
                    if {$sawroot} { Fail FRONT usage "front cdirs takes one root, not two" }
                    set root $a ; set sawroot 1
                }
            }
        }
        # REFUSED RATHER THAN RESOLVED BY PRECEDENCE. `-out` and `-stdout` are
        # two different dispositions named at once -- write the list here, write
        # no files -- and silently letting one win would be the command ignoring
        # something the caller wrote, which is the failure mode the whole report
        # below is aimed at.
        if {$sawout && $tostdout} {
            Fail FRONT usage "front cdirs: -out and -stdout name two different\
                              dispositions; -stdout writes no files at all"
        }
        # AN EMPTY VALUE IS A VALUE, NOT AN ABSENCE -- the same failure the
        # refusal above is aimed at, one register quieter, and it shipped on all
        # three surfaces. `mt cdirs $root -depth $limit` with an empty `$limit` is
        # the ordinary shape of an optional limit; it became a FULL walk, with no
        # `depth` key in the report to record that a limit had been asked for at
        # all, while `dirs $root -depth {}` refuses the identical value with
        # `badvalue`. `mt cdirs "$SOMEUNSETVAR"` walked the workspace where
        # `dirs {}` says "the root must not be empty". And `-out {}` quietly
        # became the default cache path -- a caller who NAMED a disposition and
        # got a different one.
        #
        # The two guards even disagreed with each other: `sawout` was already set
        # by `-out {}`, so `-out {} -stdout` was refused as two dispositions while
        # `-out {}` alone counted as no `-out` at all. `sawout`, `sawroot` and
        # `sawdepth` now mean what their names say everywhere.
        if {$sawout && $out eq ""} {
            Fail FRONT badvalue "front cdirs: -out takes a filename, not an empty string"
        }
        variable FRONT_ROOT ; variable FRONT_HOME
        FrontRoots
        if {!$sawroot} { set root $FRONT_ROOT }

        set wargs {}
        if {$sawdepth} { lappend wargs -depth $depth }
        # `$prune ne ""` and not `[llength $prune]`, because a malformed list --
        # `-prune \{` -- makes `llength` THROW an uncoded Tcl error before the
        # verb ever sees it, turning a clean `{MACHTELD FRONT badvalue}` into
        # something no caller can trap.
        if {$prune ne ""} { lappend wargs -prune $prune }
        set t0 [clock milliseconds]
        if {[catch {dirs $root {*}$wargs} d o]} { FrontDirsReraise $o $d }
        set ms [expr {[clock milliseconds] - $t0}]
        set rep [FrontDirsReport $d $ms $depth $prune]

        # `-stdout` AND `-json` ARE ORTHOGONAL, so there is no conflict rule to
        # write: `-stdout` chooses where the LIST goes, `-json` chooses the
        # FORMAT of the REPORT. All four combinations mean something, and the
        # fourth falling out rather than needing a refusal is what [creed] 6's
        # word "orthogonal" is asking for.
        if {$tostdout} {
            puts stderr [expr {$asjson ? [json encode $rep] : [FrontDirsText $rep]}]
            return [join [dict get $d paths] \n]
        }
        if {$out eq ""} {
            # `cache/mt/` INSIDE WHICHEVER HOME WAS FOUND, and never z's own
            # `cache/cdirs/c-drive-dirs.txt`. During the transition MT_HOME IS
            # `.z`, so writing there would have machteld overwrite the live cache
            # of the front door still in daily use -- with a list that is
            # forward-slashed and, at the new default, scoped to the workspace
            # rather than the drive. Two silent incompatibilities in one file.
            # This is the same discipline `FRONT_DIRS {.mt .z}` already encodes:
            # read the live workspace, write your own corner of it.
            set out [file join $FRONT_HOME cache mt dirs \
                         "[FrontDirsSlug [dict get $d root]].txt"]
        }
        # ABSOLUTE AND LEXICALLY CLEAN, so the `list` key in the report names a
        # file a later script can open. A relative `-out` recorded verbatim is a
        # path that means something different from every directory but the one
        # the command happened to be run from. `FrontClean` and not `file
        # normalize`, for the reason step 4 already paid for once: `file
        # normalize` FOLLOWS LINKS, and `.z/r/winsdk` is a junction into Program
        # Files -- normalising put a tool and its payload in different trees and
        # cost `signtool` its alias. Where a file is WRITTEN is a question about
        # names, not about the disk.
        set outasked $out
        if {[file pathtype $out] eq "relative"} { set out [file join [pwd] $out] }
        set out [FrontClean $out]
        # AND STILL ABSOLUTE AFTERWARDS, which the block above claimed and did not
        # check. `FrontClean` pops `..` lexically and will pop PAST the drive
        # letter -- `C:/dev/_machteld/../../../../x.txt` comes back as `x.txt` --
        # so the `list` key named a file only the original working directory could
        # open, in the report whose whole job is to name a file a later script can
        # open. Refused here rather than fixed inside `FrontClean`: that proc
        # answers "is this path WRITTEN underneath that one" for 275 tool
        # resolutions, and a filename is not the question it was written for.
        if {[file pathtype $out] eq "relative"} {
            Fail FRONT badvalue "front cdirs: -out \"$outasked\" climbs above the root\
                                 of the drive and names no file"
        }
        set rep [FrontDirsWrite $d $rep $out]
        return [expr {$asjson ? [json encode $rep] : [FrontDirsText $rep]}]
    }

    # `verify` -- the structural problems, which must agree with z's exactly.
    # The COUNTS line does not and cannot: z counts its 21 built-ins, machteld
    # counts its own front-door commands, and those are different sets on
    # purpose. The problems are the substance; the tally is a footer.
    if {$sub eq "verify"} {
        set asjson 0
        foreach a [lrange $args 1 end] {
            if {$a in {-json --json}} { set asjson 1 ; continue }
            Fail FRONT usage "usage: front verify ?-json?"
        }
        set problems [FrontLayoutProblems]
        set p [FrontProject]
        set pcmds {}
        if {[dict size $p]} {
            set pcmds [FrontProjectCommands [dict get $p root] pprobs]
            lappend problems {*}$pprobs
            # A PROJECT MAY NOT SHADOW THE KIT. Reported rather than silently
            # resolved one way, because a name that means two things is a bug in
            # the workspace and not a precedence puzzle for the front door.
            foreach n [lsort [dict keys $pcmds]] {
                if {$n in [FrontCommands] || $n in [FrontToolNames]} {
                    lappend problems "project defines reserved name \"$n\" (a z tool or built-in)"
                }
            }
        }
        # The kit defining one name twice: a front-door command that is also a
        # curated tool. Gated in the suite as well, because the workspace gains
        # tools without asking anybody.
        foreach n [FrontCommands] {
            if {$n in [FrontToolNames]} {
                lappend problems "kit defines \"$n\" in multiple places: builtin, tool"
            }
        }
        set problems [lsort -unique $problems]
        set d [dict create problems $problems ambiguous {} \
                   counts [dict create builtins [llength [FrontCommands]] \
                               tools [llength [FrontToolNames]] scripts 0 \
                               project [dict size $pcmds]]]
        if {$asjson} { return [json encode $d] }
        set out {}
        if {[llength $problems]} {
            lappend out "problems:"
            foreach x $problems { lappend out "  - $x" }
        } else {
            set c [dict get $d counts]
            lappend out "ok: [dict get $c builtins] commands, [dict get $c tools] tools,\
                         [dict get $c project] project commands; no collisions"
        }
        return [join $out \n]
    }

    if {$sub eq "status"} {
        set deep 0 ; set asjson 0
        foreach a [lrange $args 1 end] {
            switch -- $a {
                -json - --json { set asjson 1 }
                -deep - --deep { set deep 1 }
                default { Fail FRONT usage "usage: front status ?-deep? ?-json?" }
            }
        }
        if {$deep} {
            Fail FRONT unsupported "front status: -deep runs `verify` and `ledger check`,\
                                    and neither is built yet"
        }
        variable FRONT_ROOT ; variable FRONT_HOME
        FrontRoots
        set d [dict create root [file nativename $FRONT_ROOT] zGit [FrontGit $FRONT_HOME]]
        set rows {}
        foreach p [FrontProjects] {
            dict set p git [FrontGit [dict get $p path]]
            lappend rows $p
        }
        dict set d projects $rows
        if {$asjson} { return [json encode $d] }
        set out {}
        lappend out "mt status"
        lappend out "  root: [dict get $d root]"
        lappend out "  workspace git: [FrontGitLine [dict get $d zGit]]"
        lappend out ""
        lappend out "projects"
        foreach p $rows {
            lappend out [format "  %-12s %s" [dict get $p name] [dict get $p path]]
            lappend out "       git: [FrontGitLine [dict get $p git]]"
        }
        lappend out ""
        lappend out "not yet: mirror state, latest report, and --deep (verify + ledger check)"
        return [join $out \n]
    }

    if {$sub in {projects runtimes}} {
        set asjson 0
        foreach a [lrange $args 1 end] {
            if {$a in {-json --json}} { set asjson 1 ; continue }
            Fail FRONT usage "usage: front $sub ?-json?"
        }
        set rows [expr {$sub eq "projects" ? [FrontProjects] : [FrontRuntimes]}]
        if {$asjson} { return [json encode $rows -list] }
        if {![llength $rows]} { return "" }
        set out {}
        if {$sub eq "projects"} {
            foreach r $rows { lappend out "[dict get $r name]\t[dict get $r path]" }
            return [join $out \n]
        }
        # The human rendering is machteld's, not z's: aligned to the widest
        # value rather than to a fixed column, and the aliases counted rather
        # than truncated at eight with a "...(+204)". The -json form is the one
        # that has to agree, and it does.
        set w1 5 ; set w2 7
        foreach r $rows {
            set w1 [expr {max($w1, [string length [dict get $r name]])}]
            set w2 [expr {max($w2, [string length [FrontDictOr $r version -]])}]
        }
        lappend out [format "%-*s  %-*s  %7s  %s" $w1 runtime $w2 version aliases path]
        foreach r $rows {
            set a [dict get $r aliases]
            lappend out [format "%-*s  %-*s  %7s  %s" \
                $w1 [dict get $r name] $w2 [FrontDictOr $r version -] \
                [expr {[llength $a] ? [llength $a] : "-"}] [dict get $r path]]
        }
        return [join $out \n]
    }

    # ONE PLACE KNOWS THE FILENAME. `front run` opens the journal lazily and a
    # reader could not: it would have to spell `[file join ... mt.db]` itself,
    # which is a second authority on where the record lives and the first thing
    # that goes stale. This opens the same file the recorder writes and hands
    # back the path -- and, unlike the recorder, it does NOT swallow failure: a
    # script asking for the journal wants to be told there isn't one.
    if {$sub eq "journal"} {
        if {[llength $args] != 1} { Fail FRONT usage "usage: front journal" }
        variable FRONT_HOME ; variable FRONT_SESSION ; variable FRONT_JOURNAL
        FrontRoots
        set db [file join $FRONT_HOME mt.db]
        journal open $db
        if {$FRONT_SESSION eq ""} { set FRONT_SESSION "[pid]-[clock milliseconds]" }
        set FRONT_JOURNAL on
        return $db
    }

    if {$sub eq "run"} {
        # `--` ENDS FRONT'S OPTIONS -- the same guard `run`, `child start`,
        # `pty spawn` and `detach` all take. The parser never needed it (only
        # the word right after `run` is read as an option), but a reader does:
        # in `front run rg -n TODO .` nothing on the line says whose flag `-n`
        # is. It stays optional, because the everyday path is `mt rg -n TODO .`,
        # where the tool name is argv0 and there is nothing to disambiguate.
        set inherit 0 ; set i 1
        if {[lindex $args $i] eq "-inherit"} { set inherit 1 ; incr i }
        if {[lindex $args $i] eq "--"} { incr i }
        if {[llength $args] <= $i} { Fail FRONT usage "usage: front run ?-inherit? ?--? name ?arg ...?" }
        return [FrontExec [FrontResolve [lindex $args $i]] $inherit [lrange $args [expr {$i + 1}] end]]
    }

    if {[llength $args] < 2} { Fail FRONT usage "usage: front $sub name" }
    set r [FrontResolve [lindex $args 1]]
    # `which` PRINTS WHAT z PRINTS: `name<TAB>kind<TAB>exe`, and the exe field
    # is dropped when there is none -- which is what a builtin verb resolves to.
    # It used to return the bare executable, which reads better in a script and
    # is the wrong thing for a command whose whole purpose is being typed where
    # `z which` was. A script wants `dict get [front env $n] exe` anyway: `env`
    # is the dict, `which` is the line.
    if {$sub eq "which"} {
        if {[llength $args] != 2} { Fail FRONT usage "usage: front which name" }
        set exe [expr {[dict exists $r exe] ? [dict get $r exe] : ""}]
        if {[dict get $r kind] eq "builtin" || [dict get $r kind] eq "command"} { set exe "" }
        if {$exe eq ""} { return "[dict get $r name]\t[dict get $r kind]" }
        return "[dict get $r name]\t[dict get $r kind]\t$exe"
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

# --- running what was resolved ------------------------------------------------

# ONE RESOLUTION, TWO WAYS TO RUN IT, because the front door has two audiences.
#
# A person at a prompt wants the terminal handed over: `rg` in colour, a pager
# that pages, Ctrl-C reaching the right process. An AGENT writing a Tcl script
# wants the output back as data to parse. Those are opposite requirements, so
# `-inherit` selects between them rather than one of them being wrong: capture is
# the default because a script is the case that needs a value returned, and the
# argv dispatcher passes -inherit because a terminal is the case that needs the
# terminal.
#
# Either way the child is supervised: born in the job object, tree-killable, and
# dying with this process. That is the whole reason the front door spawns through
# the palette instead of exec'ing.
proc ::machteld::FrontExec {r inherit cargs} {
    set kind [dict get $r kind]

    # A builtin runs HERE. Re-spawning ourselves to reach a verb this exe already
    # has would pay 44 ms of process start to call a command that is already
    # loaded, and would hand the answer back through a pipe as text.
    if {$kind in {builtin command}} {
        # `args` rather than `name`, because the two kinds differ only in what
        # they expand to: a builtin verb is itself, a front-door command is
        # `front <name>`. Both run HERE, in this process.
        return [uplevel #0 [list {*}[dict get $r args] {*}$cargs]]
    }

    if {[dict exists $r arg0]} {
        # The one tool in the workspace that asks for it (`make`). Refused rather
        # than run without it: the program would see a different argv[0] than the
        # workspace intends, which is a silent difference, and this file's whole
        # standard is that a wrong answer is worse than a refusal.
        Fail FRONT unsupported "\"[dict get $r name]\" needs arg0, which the front door cannot set yet"
    }

    set argv [list [dict get $r exe]]
    if {[dict exists $r pre]} { lappend argv {*}[dict get $r pre] }
    lappend argv {*}$cargs

    # Recorded around the run, and every journal call is caught: see FrontJournal.
    variable FRONT_SESSION
    set jid ""
    if {[FrontJournal]} {
        catch {
            set jid [journal add [dict create                 session $FRONT_SESSION parent "" pid ""                 name [dict get $r name] kind [dict get $r kind]                 exe [dict get $r exe] argv [json encode $argv -list]                 cwd [dict get $r cwd]                 project [expr {[dict exists $r env MT_PROJECT_NAME]
                               ? [dict get $r env MT_PROJECT_NAME] : ""}]]]
        }
    }

    if {$inherit} {
        set res [run -inherit -dir [dict get $r cwd] -env [dict get $r env] -- {*}$argv]
    } else {
        set res [run -dir [dict get $r cwd] -env [dict get $r env] -- {*}$argv]
    }
    if {$jid ne ""} {
        catch {journal done $jid [dict get $res status] [dict get $res exit]}
    }
    return $res
}

# BECOME A SCRIPT. The process stops being a front door and starts being that
# program: its `argv0`, its `argv`, its event loop, its exit code.
#
# IT TAKES OVER TWO JOBS Tcl_Main WOULD HAVE DONE for a script named on the
# command line, and it has to, because Tcl_Main is no longer going to do them:
#
# 1. HANDING THE SCRIPT BACK TO Tcl_Main WOULD BE NEATER, AND DOES NOT WORK.
#    Tcl_Main reads its startup script into a local before it calls AppInit --
#    which is what sources this prelude -- so by the time the prelude has a
#    script to name, the decision about what to evaluate has been taken. Setting
#    `argv0` afterwards changes the variable and nothing else: the process still
#    tries to read a file called "app.tcl", and says so.
#
# 2. THE EVENT LOOP MUST BE REPLACED, NOT SKIPPED. Under `tclsh`, `package
#    require Tk` hands Tk_MainLoop to Tcl_SetMainLoop and Tcl_Main runs it AFTER
#    the script returns -- which is why a Tk program that never calls `vwait`
#    works there. Source one from here with nothing after it and it builds its
#    window, returns, and the process ends before a single event is dispatched.
#    `tkwait window .` is that loop for a program with one main window, which is
#    what a Tk program written this way has. Found by running the Life windows
#    that used to ship here, back when there were tools inside the exe to find
#    it with.
#
# The error path prints `-errorinfo`, because that is what Tcl_Main prints and a
# script that fails should not become harder to debug for being named rather
# than passed as a path.
proc ::machteld::FrontBecome {script cargs {label ""}} {
    global argv argv0
    set argv0 $script
    set argv $cargs
    if {[catch {uplevel #0 [list source $script]} e opts]} {
        set who [expr {$label eq "" ? "mt" : "mt: $label"}]
        catch {puts stderr "$who: $e"}
        catch {puts stderr [dict get $opts -errorinfo]}
        exit 1
    }
    if {[info exists ::tk_version] && [llength [info commands ::winfo]]
        && [winfo exists .]} {
        catch {uplevel #0 {tkwait window .}}
    }
    exit 0
}

# tcl: run a Tcl script as this process's program.
#
#   tcl <script.tcl> ?arg ...?
#
# THIS EXE IS A FRONT DOOR, NOT AN INTERPRETER YOU POINT AT A FILE. Until
# 2026-08-10 `mt app.tcl` ran app.tcl, because the dispatcher let through
# anything that LOOKED like a path -- a separator, or a `.tcl` extension -- and
# handed it to Tcl_Main. That worked, and it was a shape test: a heuristic
# deciding what kind of thing you meant. `argv0` is a NAME now, always, with no
# test of any kind, and this verb is how a script is named instead.
#
# This is also what a project's helper scripts are run with, which was the
# reason the front door had to be a script host at all: `mt tcl tools/build.tcl`.
#
# IT DOES NOT RETURN, and that is the point rather than a limitation: the process
# BECOMES the script. To *include* a file in the program you are already
# running, that is Tcl's own `source`, and always was.
proc ::machteld::tcl {args} {
    if {![llength $args]} { Fail TCL usage "usage: tcl <script.tcl> ?arg ...?" }
    set script [lindex $args 0]
    if {![file exists $script]} { Fail TCL notfound "tcl: no such script \"$script\"" }
    FrontBecome $script [lrange $args 1 end]
}

# THE ARGV DISPATCHER. `Tcl_Main` calls AppInit -- which sources this prelude --
# before it looks at argv, so the front door can take a name over from here with
# no C at all.
#
# THE RULE IS ONE LINE LONG: the first argument is a NAME. Not a name unless it
# looks like a path; not a name unless a file of that name exists; a name.
#
# It used to be two lines. Until 2026-08-10 anything carrying a path separator or
# a `.tcl` extension was handed back to Tcl_Main as a script, so `mt app.tcl`
# ran app.tcl the way `tclsh app.tcl` does. That was never "does this file
# exist" -- which would have let a stray file change what `mt rg` means, the
# same accident as a PATH fallback -- but it was still a SHAPE TEST, a heuristic
# guessing which of two kinds of thing you meant from how the word was spelled.
# `mt rg` beside a file called `rg` is the case it could not answer, and there
# are 273 curated names for such a file to be named after.
#
# A script is named now: `mt tcl app.tcl`. That cost a word at every call site
# -- 71 of them in this repo -- and bought a dispatcher with no heuristic in it
# at all, which is [the creed](creed.md)'s "determinism over cleverness" applied
# to the one place the front door was still guessing.
proc ::machteld::FrontDispatch {} {
    global argv argv0
    if {![info exists argv0]} return

    # THE NAME IS IN argv0, NOT argv[0]. By the time AppInit runs, `Tcl_Main` has
    # already taken the first argument as the script to run and left the rest in
    # `argv` -- so for `mt rg --version` the candidate is argv0="rg" with
    # argv={--version}. Reading argv[0] instead made the front door resolve the
    # first ARGUMENT of every command: `mt script.tcl a b` went looking for a
    # tool called "a". Only running it showed that.
    set name $argv0

    # A STAMPED TOOL IS NOT A FRONT DOOR, and this is where it says so.
    #
    # `wrap` puts the tool's main.tcl at the ROOT of the appended archive, which
    # is exactly what TclZipfs_AppHook turns into the startup script -- so a
    # wrapped program reaches this line with argv0 pointing into its own zipfs,
    # and without this check the front door would try to resolve that path as a
    # tool name and exit 127 before the program ran at all. It did not need the
    # check while the dispatcher had a shape test, because a zipfs path contains
    # separators and was handed straight back; removing the heuristic removed
    # that accident with it.
    #
    # The test is a fact, not a guess: `tools/package.tcl` FAILS THE BUILD if a
    # root main.tcl ever lands in mt.exe's own archive, so a root main.tcl means
    # a stamped tool and nothing else. The two halves assert the same thing from
    # opposite sides.
    foreach _m [dict keys [zipfs mount]] {
        if {[file exists [file join $_m main.tcl]]} return
    }

    # No script argument at all: argv0 is this executable. That is the shell.
    if {[string equal -nocase [file normalize $name]                               [file normalize [info nameofexecutable]]]} return
    if {[string index $name 0] eq "-"} return         ;# Tcl_Main's options; `-` is stdin

    # No workspace, no front door: leave argv alone rather than failing an
    # invocation that never wanted one.
    if {[catch {FrontRoots}]} return

    if {[catch {FrontResolve $name} r]} {
        catch {puts stderr "mt: $r"}
        # THE OLD SPELLING, ANSWERED RATHER THAN MERELY REFUSED. `mt app.tcl`
        # ran a script until 2026-08-10 and now names a tool nobody curates,
        # which is an unhelpful thing to be told when you plainly typed a
        # filename. `file exists` appears HERE and only here -- in the message,
        # never in the decision -- so what `mt` runs still cannot depend on what
        # happens to be in the working directory.
        if {[string match "*/*" $name] || [string match {*\\*} $name]
            || [string tolower [file extension $name]] eq ".tcl"
            || [file exists $name]} {
            catch {puts stderr "mt: that looks like a script -- name it: mt tcl $name ..."}
        }
        exit 127                                      ;# the shell's "no such command"
    }


    if {[catch {FrontExec $r 1 $argv} res]} {
        catch {puts stderr "mt: $res"}
        exit 126                                      ;# found, could not run
    }
    if {[dict exists $res exit]} { exit [dict get $res exit] }
    if {$res ne ""} { catch {puts $res} }
    exit 0
}

# The front door takes over argv here, at the very foot of the prelude.
::machteld::FrontDispatch
