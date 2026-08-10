# front_agree.tcl -- the front door must agree with the one it is replacing.
#
#   machteld test/front_agree.tcl ?--verbose?
#
# Resolution is the only part of a front door that has a right answer available
# for checking: `z env --json <name>` already says what z would run, for all 273
# curated tools. So rather than assert that this implementation looks correct,
# ask both and diff.
#
# This is a SEPARATE file from the suite on purpose. It needs a live workspace
# with a working `z.exe` beside it, which the suite must not require -- machteld
# has to build and pass on a machine where no such workspace exists. Driven from
# the suite when the workspace IS there, skipped cleanly when it is not.
#
# What is compared, and why not more: `exe` and the environment OVERLAY. Not the
# inherited PATH tail (it is whatever the caller had), and not `finalArgv` beyond
# the prepended arguments (the caller's own args are not resolution).

set VERBOSE [expr {[lsearch -exact $argv --verbose] >= 0}]

set root [dict get [front roots] root]
set zexe [file join $root z.exe]
if {![file exists $zexe]} {
    puts "SKIP: no z.exe at $zexe -- nothing to agree with"
    exit 0
}

# `z env --json` yields env as a list of K=V strings; machteld yields a dict.
# Compared as mappings, because an environment is a mapping -- the order z emits
# them in is an artefact of how it builds the list, not a fact about the child.
proc envlist_to_dict {l} {
    set d [dict create]
    foreach kv $l {
        set i [string first "=" $kv]
        if {$i < 0} continue
        dict set d [string range $kv 0 [expr {$i - 1}]] [string range $kv [expr {$i + 1}] end]
    }
    return $d
}

# PATH is compared by its HEAD -- the directories the tool actually adds. The
# tail is the caller's inherited PATH, which differs between the two processes
# for reasons that have nothing to do with resolution.
proc path_head {p inherited} {
    if {$p eq ""} { return {} }
    set dirs [split $p ";"]
    set tail [split $inherited ";"]
    set n [llength $tail]
    if {$n > 0 && [llength $dirs] >= $n} {
        set dirs [lrange $dirs 0 end-$n]
    }
    return [lmap d $dirs {string tolower $d}]
}

# THE NAMES COME FROM z, NOT FROM machteld, and that is the whole difference
# between a test and a mirror. This read `front tools` until 2026-08-10 and
# reported 273 of 273 agreeing -- while z had 275 tools and machteld refused
# four of them outright (`EditPadPro8`, `RegexBuddy5`, `CSCSE5`, `FNSE3`, all
# `.z/t/` directories the manifest never mentions). A verification that
# enumerates from the side under test can only find disagreements about things
# both sides already name; it is structurally blind to anything missing.
#
# Taking the list from z means machteld's inventory is checked too: a name z
# has and machteld cannot resolve now fails here, which is exactly how those
# four were found.
set names {}
foreach line [split [string map {\r\n \n} [dict get [run -timeout 60s -- $zexe tools] out]] \n] {
    set n [lindex [split $line \t] 0]
    if {$n ne ""} { lappend names $n }
}
if {[llength $names] < 100} { error "front_agree: z listed only [llength $names] tools" }
set mine [front tools -json]
set mineNames [lmap r [json decode $mine] {dict get $r name}]
set onlyZ [lmap n $names {expr {$n in $mineNames ? [continue] : $n}}]
set onlyM [lmap n $mineNames {expr {$n in $names ? [continue] : $n}}]
puts [format "inventory        : z %d, machteld %d" [llength $names] [llength $mineNames]]
if {[llength $onlyZ] || [llength $onlyM]} {
    puts "  only z has  : $onlyZ"
    puts "  only mt has : $onlyM"
}
set agree 0 ; set differ {} ; set mine_refused {} ; set theirs_refused {}
set inherited [expr {[info exists ::env(PATH)] ? $::env(PATH) : ""}]

foreach n $names {
    set zr [run -timeout 20s -- $zexe env --json $n]
    set zok [expr {[dict get $zr exit] == 0}]
    set mok [expr {![catch {front env $n} me]}]

    if {!$zok && !$mok} { incr agree ; continue }
    if {!$zok} { lappend theirs_refused $n ; continue }
    if {!$mok} { lappend mine_refused [list $n $me] ; continue }

    set them [json decode [dict get $zr out]]
    set problems {}

    if {[string tolower [dict get $me exe]] ne [string tolower [dict get $them exe]]} {
        lappend problems "exe: mine [dict get $me exe] / theirs [dict get $them exe]"
    }

    set tenv [envlist_to_dict [dict get $them env]]
    set menv [dict get $me env]
    # The Z_/MT_ pair is this front door's own contribution; z knows only Z_.
    foreach k {MT_ROOT MT_HOME MT_PROJECT_ROOT MT_PROJECT_NAME} { dict unset menv $k }
    foreach k [lsort -unique [concat [dict keys $tenv] [dict keys $menv]]] {
        set hasm [dict exists $menv $k] ; set hast [dict exists $tenv $k]
        if {$hasm != $hast} {
            lappend problems "env $k: [expr {$hasm ? {only mine} : {only theirs}}]"
            continue
        }
        set mv [dict get $menv $k] ; set tv [dict get $tenv $k]
        if {$k eq "PATH"} {
            set mh [path_head $mv $inherited] ; set th [path_head $tv $inherited]
            if {$mh ne $th} { lappend problems "env PATH head: mine $mh / theirs $th" }
            continue
        }
        if {[string tolower $mv] ne [string tolower $tv]} {
            lappend problems "env $k: mine \"$mv\" / theirs \"$tv\""
        }
    }

    # The prepended arguments, which z reports as finalArgv after the exe.
    set tpre [lrange [dict get $them finalArgv] 1 end]
    set mpre [expr {[dict exists $me pre] ? [dict get $me pre] : {}}]
    if {[lmap x $mpre {string tolower $x}] ne [lmap x $tpre {string tolower $x}]} {
        lappend problems "pre: mine $mpre / theirs $tpre"
    }

    if {[llength $problems]} {
        lappend differ [list $n $problems]
    } else {
        incr agree
    }
}

puts [format "agree            : %d / %d" $agree [llength $names]]
puts [format "differ           : %d" [llength $differ]]
puts [format "machteld refused : %d" [llength $mine_refused]]
puts [format "z refused        : %d" [llength $theirs_refused]]
if {[llength $theirs_refused]} { puts "  z refused: [lrange $theirs_refused 0 8]" }
foreach d [lrange $mine_refused 0 [expr {$VERBOSE ? "end" : 5}]] {
    puts "  machteld refused [lindex $d 0]: [lindex $d 1]"
}
foreach d [lrange $differ 0 [expr {$VERBOSE ? "end" : 9}]] {
    puts "  [lindex $d 0]:"
    foreach p [lindex $d 1] { puts "      $p" }
}
# --- and every PROJECT COMMAND, resolved from inside its project -------------
# The kit's inventory is only half the front door's job. Each project's z.json
# declares commands whose argv[0] resolves to a curated tool and CLONES that
# tool's whole target -- env overlay, PATH shaping, prepended arguments -- with
# the rest of the argv appended and the project root as the working directory.
# Three defects hid in that one paragraph until it was diffed:
#
#   - the palette was consulted before project commands, so `run` -- a palette
#     verb AND a command in ten of the twelve projects -- resolved to the wrong
#     one every time;
#   - `filepath.Join` cleans and `file join` does not, so `./drang.exe` came out
#     as `_drang\.\drang.exe`;
#   - `z:` reached builtins and not tools, exactly backwards.
set here [pwd]
set ptotal 0 ; set pagree 0 ; set pbad {}
foreach p [json decode [front projects -json]] {
    set root [dict get $p path]
    set cmds [::machteld::FrontProjectCommands $root]
    if {![dict size $cmds]} continue
    cd $root
    foreach n [lsort [dict keys $cmds]] {
        incr ptotal
        set zr [run -timeout 60s -dir $root -- $zexe env --json $n]
        if {[dict get $zr exit] != 0} { lappend pbad "[dict get $p name]/$n: z refused" ; continue }
        set z [json decode [dict get $zr out]]
        if {[catch {front env $n} m]} { lappend pbad "[dict get $p name]/$n: machteld refused" ; continue }
        set probs {}
        if {[dict get $z exe] ne [dict get $m exe]} {
            lappend probs "exe z=[dict get $z exe] machteld=[dict get $m exe]"
        }
        set zp [expr {[dict exists $z pre] ? [dict get $z pre] : {}}]
        set mp [expr {[dict exists $m pre] ? [dict get $m pre] : {}}]
        if {$zp ne $mp} { lappend probs "pre z={$zp} machteld={$mp}" }
        if {[dict exists $z cwd] && [dict get $z cwd] ne [dict get $m cwd]} {
            lappend probs "cwd z=[dict get $z cwd] machteld=[dict get $m cwd]"
        }
        if {[llength $probs]} {
            lappend pbad "[dict get $p name]/$n: [join $probs {; }]"
        } else { incr pagree }
    }
}
cd $here
puts [format "project commands : %d / %d" $pagree $ptotal]
foreach b [lrange $pbad 0 [expr {$VERBOSE ? "end" : 9}]] { puts "  $b" }
if {$ptotal < 20} { puts "  (suspiciously few -- is FrontProjectCommands reading anything?)" }

# --- and the structural problems `verify` reports ----------------------------
# The problem LIST must agree exactly; the counts footer must not and cannot,
# since z counts its 21 built-ins and machteld counts its own front-door
# commands, which are different sets on purpose.
proc verifyProblems {text} {
    set out {}
    foreach line [split [string map {\r\n \n} $text] \n] {
        if {[string range [string trim $line] 0 1] eq "- "} {
            lappend out [string trim [string range [string trim $line] 2 end]]
        }
    }
    return [lsort $out]
}
set zv [verifyProblems [dict get [run -timeout 60s -- $zexe verify] out]]
set mv [lsort [dict get [json decode [front verify -json]] problems]]
puts [format "verify problems  : z %d, machteld %d" [llength $zv] [llength $mv]]
set vbad 0
if {$zv ne $mv} {
    set vbad 1
    puts "  only z      : [lmap x $zv {expr {$x in $mv ? [continue] : $x}}]"
    puts "  only machteld: [lmap x $mv {expr {$x in $zv ? [continue] : $x}}]"
}

# --- and the scout table, line for line --------------------------------------
# Each side's own first line differs (it names which front door produced it) and
# z prints a trailing hint of its own; everything between must be identical.
proc scoutBody {text} {
    set out {}
    foreach l [lrange [split [string map {\r\n \n} [string trimright $text]] \n] 1 end] {
        set l [string trimright $l]
        if {[string match "hint:*" $l]} continue
        lappend out $l
    }
    return $out
}
set zs [scoutBody [dict get [run -timeout 300s -- $zexe scout] out]]
set ms [scoutBody [dict get [run -timeout 300s -- [info nameofexecutable] scout] out]]
set sbad 0
foreach a $zs b $ms { if {$a ne $b} { incr sbad ; if {$sbad < 4} { puts "  z : '$a'" ; puts "  mt: '$b'" } } }
if {[llength $zs] != [llength $ms]} { incr sbad }
puts [format "scout table      : %d lines, %s" [llength $zs] [expr {$sbad ? "$sbad DIFFER" : "identical"}]]

if {[llength $differ] || [llength $mine_refused] || [llength $pbad] || $ptotal < 20 || $vbad || $sbad} {
    puts "DISAGREEMENT"
    exit 1
}
puts "AGREED on all [llength $names] tools and all $ptotal project commands"
exit 0
