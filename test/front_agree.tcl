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

# THE COMPARISON IS OVER THE CURATED INVENTORY, which is the only inventory the
# two front doors share. `front tools` also lists the tools that ride inside
# mt.exe, and z has never heard of those -- counting them as "z refused" would
# report five deliberate differences as five surprises, every run, and hide a
# real one among them.
set shipped {}
foreach n [front tools] {
    if {[dict get [front env $n] kind] eq "script"} { lappend shipped $n }
}
set names [lmap n [front tools] {expr {$n in $shipped ? [continue] : $n}}]
puts [format "shipped by mt    : %d (%s) -- not compared, z has no such names" \
          [llength $shipped] [join $shipped " "]]
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
if {[llength $differ] || [llength $mine_refused]} {
    puts "DISAGREEMENT"
    exit 1
}
puts "AGREED on all [llength $names]"
exit 0
