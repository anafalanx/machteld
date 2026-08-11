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

# --- cdirs: the first command that must NOT agree with z ----------------------
#
# EVERY OTHER ENTRY IN THIS FILE ASSERTS EQUALITY. This one asserts a SUPERSET
# WITH A NAMED CAUSE, and it is asserted on TWO subjects because either one alone
# is satisfiable by a defect:
#
#   C:/dev        -- no non-surrogate reparse point exists in it, so the two veto
#                    rules coincide and the lists must be EQUAL BOTH WAYS. This is
#                    the BOUND. A walker that descended junctions satisfies every
#                    superset clause below and fails only here.
#   %USERPROFILE% -- OneDrive at depth 1, tag 0x9000701a, surrogate bit clear. z
#                    stops; machteld descends. This is the divergence, and it is
#                    124,144 real local directories at full depth.
#
# WHY THE SUPERSET CLAUSE IS THE WEAKEST OF THE SIX, stated so nobody reads a
# green line here as more than it is: `z subset-of mt` survives over-listing,
# fabrication, a vanished divergence and a wrong attribution alike. The bound
# (equality on C:/dev), the non-emptiness clause, the identical-spelling clause
# and the external existence probe are what carry the claim.
#
# z's LIST IS READ FROM A FILE, NEVER FROM CAPTURED STDOUT. `z cdirs --stdout`
# through `run` is capped at 1 MiB (src/proc.c: `size_t cap = 1u << 20`) and
# truncates in SILENCE -- measured on this machine, --max-depth 6 printed 16,817
# lines and `run` returned 16,423, exit 0, `truncated` set to `out`. The 394 lost
# lines come back as 394 extras attributable to nothing, and TRUNCATION MAKES A
# SUPERSET GATE PASS HARDER, which is a gate strengthened by its own bug. The
# count is cross-checked against z's own stats line as well, so a short file is
# caught even coming off disk.
set CDIRS_DEEP [expr {[lsearch -exact $argv --deep] >= 0}]
set CDIRS_T0 [clock seconds]
set MTEXE [info nameofexecutable]
set CDTMP [string map {\\ /} $env(TEMP)]

proc cdirsZ {zexe root cap} {
    set out [file join $::CDTMP zcd_[pid]_[clock clicks].txt]
    set a [list cdirs --root [file nativename $root] --out [file nativename $out] --quiet]
    if {$cap ne ""} { lappend a --max-depth $cap }
    set r [run -timeout 900s -- $zexe {*}$a]
    if {[dict get $r exit] != 0} { error "z cdirs failed: [dict get $r err]" }
    set claimed -1
    regexp {cdirs:\s+(\d+)\s+directories} [dict get $r out] -> claimed
    set fh [open $out r] ; fconfigure $fh -encoding utf-8
    set text [read $fh] ; close $fh
    file delete -force $out $out.errors.txt
    set l {}
    foreach line [split [string map {\r\n \n} [string trimright $text]] \n] {
        if {$line ne ""} { lappend l [string map {\\ /} $line] }
    }
    return [list $l $claimed [dict get $r truncated]]
}

# machteld's list comes off disk too, for symmetry -- but its COUNT and its
# attribution rows come from the `-json` report, which is the command under test
# describing its own run. That is not circular: clause A below is what stops the
# report explaining away anything z found, since a report cannot conjure a
# directory into a list it is not in.
proc cdirsMt {mt root cap} {
    set out [file join $::CDTMP mtcd_[pid]_[clock clicks].txt]
    set a [list front cdirs $root -out $out -json]
    if {$cap ne ""} { lappend a -depth $cap }
    set r [run -timeout 900s -- $mt {*}$a]
    if {[dict get $r exit] != 0} { error "mt cdirs failed: [dict get $r err]" }
    set rep [json decode [dict get $r out]]
    set fh [open $out r] ; fconfigure $fh -encoding utf-8
    set text [read $fh] ; close $fh
    file delete -force $out [file rootname $out].json
    set l {}
    foreach line [split [string map {\r\n \n} [string trimright $text]] \n] {
        if {$line ne ""} { lappend l $line }
    }
    return [list $l $rep]
}

# PREFIX CONTAINMENT WITHOUT `string match`. This home tree contains
# `C:/Users/anafa/gdrive/[19] MASTER`, so a path used as a glob PATTERN is a bug
# that only fires on one machine's data -- and fires as a false pass, since the
# bracket expression simply fails to match.
proc cdirsUnder {prefix path} {
    return [string equal -nocase -length [string length $prefix] $prefix $path]
}

proc cdirsCompare {label zexe mt root cap expectEqual} {
    lassign [cdirsZ $zexe $root $cap] zl zclaim ztrunc
    lassign [cdirsMt $mt $root $cap] ml rep

    set bad 0
    # THE ORACLE IS CHECKED BEFORE IT IS BELIEVED.
    if {$ztrunc ne ""} { puts "  z's stats capture was TRUNCATED ($ztrunc)" ; incr bad }
    if {$zclaim >= 0 && $zclaim != [llength $zl]} {
        puts "  z wrote [llength $zl] lines but claims $zclaim -- short file" ; incr bad
    }
    if {[dict get $rep dirs] != [llength $ml]} {
        puts "  mt wrote [llength $ml] lines but reports [dict get $rep dirs] -- short file" ; incr bad
    }

    set zset {} ; foreach p $zl { dict set zset [string tolower $p] $p }
    set mset {} ; foreach p $ml { dict set mset [string tolower $p] $p }
    # E: MULTIPLICITY. A set difference cannot see a duplicate; `glob -- * .*`
    # once walked every dot-directory twice, overcounted by 77%, and terminated
    # normally.
    set zdup [expr {[llength $zl] - [dict size $zset]}]
    set mdup [expr {[llength $ml] - [dict size $mset]}]
    if {$zdup || $mdup} { puts "  duplicates: z $zdup, mt $mdup" ; incr bad }

    set onlyz {} ; set churn 0
    foreach k [dict keys $zset] {
        if {[dict exists $mset $k]} continue
        set p [dict get $zset $k]
        # CHURN IS NOT A MISS, and the discriminator is EXTERNAL. z walks first
        # and machteld second; a directory deleted in between is in z's list and
        # not in machteld's, and that is not a defect. Tcl's own stat answers,
        # not either walker -- and it is reported OUT LOUD, because a green run
        # that leaned on this exception is a run with a narrower claim.
        if {![file isdirectory $p]} { incr churn } else { lappend onlyz $p }
    }
    if {$churn} { puts "  $churn path(s) z saw are gone from disk (churn, not a miss)" }

    # A: THE SUPERSET.
    if {[llength $onlyz]} {
        puts "  MISSED [llength $onlyz] director[expr {[llength $onlyz]==1?{y}:{ies}}]\
z found: [lrange $onlyz 0 5]"
        incr bad
    }

    # D: THE SPELLING of everything both found. Case-insensitive membership is
    # the right identity on NTFS and it HIDES name mangling -- CP_ACP in place of
    # CP_UTF8 turns two distinct names into the same bytes -- so this is a
    # separate clause rather than part of the set comparison.
    set spell 0
    foreach k [dict keys $zset] {
        if {![dict exists $mset $k]} continue
        if {[dict get $zset $k] ne [dict get $mset $k]} {
            if {$spell < 3} { catch {puts "  spelling: z [dict get $zset $k] / mt [dict get $mset $k]"} }
            incr spell
        }
    }
    if {$spell} { puts "  $spell shared path(s) spelled differently" ; incr bad }

    set extra {}
    foreach k [dict keys $mset] { if {![dict exists $zset $k]} { lappend extra [dict get $mset $k] } }

    if {$expectEqual} {
        # F: THE BOUND. On a tree with no non-surrogate reparse point the two
        # rules coincide, so a superset here is over-listing and nothing else.
        #
        # CHURN IS EXEMPTED IN BOTH DIRECTIONS, which it was not. The `onlyz`
        # side above has a `file isdirectory` filter and the divergence branch
        # below has a `ctime` one, but the BOUND -- the clause this file calls
        # the one that carries the whole claim -- had neither. z walks first and
        # machteld second, so a directory CREATED in between is machteld-only and
        # is not over-listing; `C:/dev` is an active build tree and its count was
        # observed moving 21841 -> 21804 -> 21841 across three runs minutes
        # apart. Reported out loud, because a green run that leaned on this
        # exemption is a run with a narrower claim.
        set born 0 ; set over {}
        foreach p $extra {
            if {![catch {file stat $p st}] && $st(ctime) >= $::CDIRS_T0} { incr born ; continue }
            lappend over $p
        }
        if {$born} { puts "  $born path(s) created after z's walk began (churn, not over-listing)" }
        set extra $over
        if {[llength $extra]} {
            puts "  OVER-LISTED [llength $extra] on a tree where the two rules coincide:\
[lrange $extra 0 5]"
            incr bad
        }
        puts [format "%-17s: z %d, mt %d, equal both ways%s" $label \
                  [llength $zl] [llength $ml] [expr {$bad ? " -- $bad PROBLEM(S)" : ""}]]
        return [list $bad {}]
    }

    # B: THE DIVERGENCE MUST ACTUALLY BE UNDER TEST. A gate that goes quiet when
    # OneDrive is unmounted has emptied itself, which is the exact shape gate 8
    # in the suite was rewritten to avoid.
    if {![llength $extra]} {
        puts "  NO EXTRAS AT ALL under $root -- the divergence is not being exercised."
        puts "  (no non-surrogate reparse point in reach? say so and pick another subject;"
        puts "   a silent pass here is the gate emptying itself.)"
        incr bad
    }

    # C: EVERY EXTRA ATTRIBUTABLE TO A ROW MACHTELD ITSELF PUBLISHED. The
    # `entered` rows come from the same walk cdirs performed, so this is machteld
    # explaining itself -- and clause A is what stops that being circular, since
    # nothing it says can explain away a directory z found and machteld did not.
    #
    # BUT "MACHTELD EXPLAINING ITSELF" IS ONLY A CHECK IF THE EXPLANATION CAN BE
    # WRONG, and it could not be. Measured by breaking it: with the `entered`
    # rows changed to name `[file dirname $path]`, the report attributed all
    # 14,625 extras to `C:/Users/anafa` -- the walk root itself -- and this file
    # went FULLY GREEN, printing `all below 1 disclosed non-surrogate root(s)`.
    # A row naming an ancestor of everything makes the clause unconditionally
    # true, and the summary printed only the COUNT of gates, so a human reading
    # it could not tell. Two answers, both mechanical:
    #
    #   the gate must lie STRICTLY BELOW the walk root -- a row naming the root
    #   or an ancestor of it explains nothing; and
    #
    #   z must have listed NOTHING under it. That is what "z stopped here" MEANS,
    #   and it is the property the whole attribution rests on. Measured today: z
    #   lists `C:/Users/anafa/OneDrive` itself and zero paths below it.
    #
    # The paths are printed as well, so the line a human reads names the places
    # rather than counting them -- which is this command's own doctrine applied
    # to its gate.
    set gates {} ; set rootpre "[string trimright $root /]/"
    foreach e [dict get $rep entered] {
        if {[dict get $e surrogate] != 0} continue
        set gp [dict get $e path]
        if {![cdirsUnder $rootpre "$gp/"] || [string equal -nocase $gp [string trimright $root /]]} {
            puts "  DISCLOSED ROW IS NOT BELOW THE WALK ROOT: $gp -- it explains nothing"
            incr bad ; continue
        }
        set zunder 0
        foreach k [dict keys $zset] { if {[cdirsUnder "[string tolower $gp]/" $k]} { incr zunder } }
        if {$zunder} {
            puts "  z listed $zunder path(s) BELOW $gp -- it did not stop there,\
so it cannot account for machteld's extras"
            incr bad ; continue
        }
        lappend gates "$gp/"
    }
    set unattr {} ; set newborn 0
    foreach p $extra {
        set ok 0
        foreach g $gates { if {[cdirsUnder $g $p]} { set ok 1 ; break } }
        if {$ok} continue
        # A NEW directory is churn in the other direction: created after z's walk
        # began, so z never had a chance to list it.
        if {![catch {file stat $p st}] && $st(ctime) >= $::CDIRS_T0} { incr newborn ; continue }
        lappend unattr $p
    }
    if {$newborn} { puts "  $newborn extra(s) created after z's walk began (churn)" }
    if {[llength $unattr]} {
        puts "  [llength $unattr] extra(s) attributable to NOTHING: [lrange $unattr 0 5]"
        incr bad
    }
    puts [format "%-17s: z %d, mt %d, +%d extra, all below %d disclosed non-surrogate root(s)%s" \
              $label [llength $zl] [llength $ml] [llength $extra] [llength $gates] \
              [expr {$bad ? " -- $bad PROBLEM(S)" : ""}]]
    # NAMED, NOT COUNTED -- the doctrine this command is built on, applied to the
    # line that reports on it. `1 disclosed root` is exactly the sentence that
    # let an ancestor-of-everything through unnoticed.
    foreach g $gates {
        set n 0
        foreach p $extra { if {[cdirsUnder $g $p]} { incr n } }
        puts [format "                 : %s accounts for %d of them" [string trimright $g /] $n]
    }
    return [list $bad $extra]
}

set cbad 0
# THE BOUND FIRST: if this fails, nothing the divergence subject says means
# anything.
lassign [cdirsCompare "cdirs C:/dev" $zexe $MTEXE C:/dev "" 1] b _
incr cbad $b
set cdhome [string map {\\ /} $env(USERPROFILE)]
lassign [cdirsCompare "cdirs home" $zexe $MTEXE $cdhome \
             [expr {$CDIRS_DEEP ? "" : 6}] 0] b cdextras
incr cbad $b

# THE EXTRAS EXIST. Everything above is set arithmetic between two walkers, and
# would be equally satisfied by a walker that INVENTS paths -- a mis-joined
# component, a stale buffer, a lexical prefix applied to the wrong parent. The
# oracle here is Tcl's own stat: a third implementation, asked one path at a
# time. EXHAUSTIVE RATHER THAN SAMPLED, because a sample is the shape that misses
# the one bad name in two hundred thousand.
set cdt0 [clock milliseconds]
set cdphantom {}
foreach p $cdextras { if {![file isdirectory $p]} { lappend cdphantom $p } }
if {[llength $cdphantom]} {
    catch {puts "  [llength $cdphantom] extra(s) DO NOT EXIST: [lrange $cdphantom 0 5]"}
    incr cbad
}
puts [format "cdirs extras     : %d probed, %d phantom, %d ms%s" [llength $cdextras] \
          [llength $cdphantom] [expr {[clock milliseconds] - $cdt0}] \
          [expr {$CDIRS_DEEP ? "" : "  (--deep for the full walk)"}]]

if {[llength $differ] || [llength $mine_refused] || [llength $pbad] || $ptotal < 20 || $vbad || $sbad || $cbad} {
    puts "DISAGREEMENT"
    exit 1
}
puts "AGREED on all [llength $names] tools and all $ptotal project commands"
exit 0
