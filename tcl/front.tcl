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
proc ::machteld::FrontProjectCommands {root} {
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
        if {![llength $argv]} continue                    ;# `z verify` calls this a problem
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
            continue                                      ;# neither a tool nor a path: dropped
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

proc ::machteld::front {args} {
    set subs {roots which env tools run journal projects runtimes status in}
    # THE DECLARED TABLE IS THE MANIFEST'S ANSWER, so an option missing here is
    # an option the palette denies having. `-inherit` was missing: `front run
    # -inherit` worked, the manifest said `front` took only -json, and the docs
    # gate called the working example a typo.
    set opts {-inherit -json}
    if {![llength $args]} {
        Fail FRONT usage "usage: front roots | front which name | front env name ?-json?\
                          | front tools ?pattern? | front run ?-inherit? ?--? name ?arg ...?\
                          | front journal | front projects ?-json? | front runtimes ?-json?"
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
