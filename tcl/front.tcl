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
proc ::machteld::FrontBaseEnv {} {
    variable FRONT_ROOT ; variable FRONT_HOME ; variable FRONT_DIR
    FrontRoots
    # NATIVE SEPARATORS. These land in a child process's environment on Windows,
    # where `C:\dev` is the spelling everything else uses; Tcl's internal forward
    # slashes are an implementation detail that must not leak into what a child
    # sees. Caught by diffing against the front door being replaced.
    set e [dict create MT_ROOT [file nativename $FRONT_ROOT] \
                       MT_HOME [file nativename $FRONT_HOME]]
    set p [FrontProject]
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
            if {$exe eq ""} {
                Fail FRONT notfound "\"$name\" is catalogued but its executable is not installed"
            }

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

    Fail FRONT notfound "\"$name\" is not a builtin or a curated tool -- there is no PATH fallback"
}

proc ::machteld::front {args} {
    set subs {roots which env tools run}
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

    if {$sub eq "run"} {
        set inherit 0 ; set i 1
        if {[lindex $args 1] eq "-inherit"} { set inherit 1 ; set i 2 }
        if {[llength $args] <= $i} { Fail FRONT usage "usage: front run ?-inherit? name ?arg ...?" }
        return [FrontExec [FrontResolve [lindex $args $i]] $inherit [lrange $args [expr {$i + 1}] end]]
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
    if {$kind eq "builtin"} {
        return [uplevel #0 [list [dict get $r name] {*}$cargs]]
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

    if {$inherit} {
        return [run -inherit -dir [dict get $r cwd] -env [dict get $r env] -- {*}$argv]
    }
    return [run -dir [dict get $r cwd] -env [dict get $r env] -- {*}$argv]
}

# THE ARGV DISPATCHER. `Tcl_Main` calls AppInit -- which sources this prelude --
# before it looks at argv, so the front door can take a name over from here with
# no C at all.
#
# The rule is deliberately not "does this file exist": that would let a stray file
# in the working directory change what `mt rg` means, which is the same class of
# accident as a PATH fallback. A first argument is a SCRIPT if it looks like one
# (a path separator, or a .tcl extension) and a NAME otherwise.
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

    # No script argument at all: argv0 is this executable. That is the shell.
    if {[string equal -nocase [file normalize $name]                               [file normalize [info nameofexecutable]]]} return
    if {[string index $name 0] eq "-"} return         ;# Tcl_Main's options; `-` is stdin

    # A SCRIPT IF IT LOOKS LIKE ONE, deliberately not "if the file exists": that
    # would let a stray file in the working directory change what `mt rg` means,
    # which is the same accident as a PATH fallback wearing different clothes.
    if {[string match "*/*" $name] || [string match {*\*} $name]
        || [string tolower [file extension $name]] eq ".tcl"} return

    # No workspace, no front door: leave argv alone rather than failing an
    # invocation that never wanted one.
    if {[catch {FrontRoots}]} return

    if {[catch {FrontResolve $name} r]} {
        catch {puts stderr "mt: $r"}
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
