# machteld -- `mirror`: the workspace's recovery replica.
#
#   mt mirror --dry-run          ;# robocopy /L: compare, change nothing
#   mt mirror                    ;# the real thing (see THE DESTRUCTIVE HALF)
#
# WHAT THIS COMMAND ACTUALLY IS. It does not copy bytes: it drives
# `robocopy /MIR`, and the copying, the retrying and the deletion of destination
# extras are Windows'. What z does around that -- and what this file does -- is
# decide WHERE, prove the where is still true, record what was skipped so it can
# be restored, and publish an account of the run. That was measured before it was
# ported: [spike/mirrorlinks](../spike/mirrorlinks/RESULTS.md) found the per-entry
# work to be two tree walks, 374 of mirror's 4,527 lines, and the other 4,153 to
# be exactly the planning-and-recording glue Tcl is for.
#
# --- THE DESTRUCTIVE HALF IS REFUSED, DELIBERATELY --------------------------
#
# `/MIR` DELETES. A destination extra is a file robocopy removes, and a mirror
# pointed at the wrong place removes a tree. z guards that with an OWNERSHIP
# RECORD -- `.z-mirror-owner.json` beside the destination, written once by
# `--adopt-dest`, checked on every real run -- which is the mechanism that stops
# a destination somebody else's tool is managing from being adopted silently.
# That record is not ported yet.
#
# So `mt mirror` without `--dry-run` REFUSES, with `{MACHTELD MIRROR unsupported}`
# naming what is missing. That is not caution for its own sake: running /MIR
# without the check z runs would make machteld the tool that deleted the backup,
# and a front door that is 95% of the way to a destructive command is not 95%
# finished -- it is the most dangerous shape the command can be in. The refusal
# goes when the ownership record and its guard are ported and tested against a
# fixture, and not before.
#
# Everything ELSE is here and is exercised by `--dry-run`, which runs the same
# resolution, the same validation, the same link scan, the same robocopy (with
# /L), the same report and the same artefact publication. That is the whole
# command minus the one phase that writes.
#
# --- WHAT IS SHARED WITH z, AND WHY -----------------------------------------
#
# The REPORT and the LINK MANIFEST keep z's formats byte for byte. They are read
# by `z logs`, `z status` and a future restore, so they are file formats shared
# with the front door being replaced -- the same reasoning that keeps the
# ledger's `generatedBy` saying `z`. The CONSOLE heading is machteld's, for the
# same reason `ledger check` advises `mt ledger refresh`: it is a sentence
# addressed to a person.

namespace eval ::machteld {
    variable MIRROR_STATE ""      ;# where the liveness file lives, once resolved
}

proc ::machteld::MirrorFail {code msg} { Fail MIRROR $code $msg }

# --- option parsing ----------------------------------------------------------
#
# z's SPELLINGS, INCLUDING `--dest=path`. This command is typed where `z mirror`
# was, and a flag that needs re-learning is a flag that gets typed wrong at the
# moment it matters. `-n` is z's short form for --dry-run.
proc ::machteld::MirrorOpts {argl} {
    set o [dict create dryrun 0 quiet 0 skiplinkscan 0 nopreflight 0 forcedest 0 \
                       adoptdest 0 preserveacl 0 dest "" logdir "" help 0]
    for {set i 0} {$i < [llength $argl]} {incr i} {
        set a [lindex $argl $i]
        switch -- $a {
            -h - --help          { dict set o help 1 }
            -n - --dry-run       { dict set o dryrun 1 }
            --quiet              { dict set o quiet 1 }
            --skip-link-scan     { dict set o skiplinkscan 1 }
            --no-preflight       { dict set o nopreflight 1 }
            --force-dest         { dict set o forcedest 1 }
            --adopt-dest         { dict set o adoptdest 1 }
            --preserve-acl       { dict set o preserveacl 1 }
            --dest - --log-dir {
                set v [lindex $argl [expr {$i + 1}]]
                if {$i + 1 >= [llength $argl] || [string index $v 0] eq "-"} {
                    MirrorFail usage "$a requires a path"
                }
                incr i
                dict set o [expr {$a eq "--dest" ? "dest" : "logdir"}] $v
            }
            default {
                # `--dest=path`, the other spelling z accepts.
                if {[regexp {^(--dest|--log-dir)=(.+)$} $a -> k v]} {
                    dict set o [expr {$k eq "--dest" ? "dest" : "logdir"}] $v
                } else {
                    MirrorFail usage "unknown argument \"$a\""
                }
            }
        }
    }
    # z's two refusals, kept because both name a real contradiction rather than
    # a style preference.
    if {[dict get $o dryrun] && [dict get $o nopreflight]} {
        MirrorFail usage "--dry-run cannot be combined with --no-preflight;\
                          a dry run is the preflight comparison"
    }
    if {[dict get $o dryrun] && [dict get $o adoptdest]} {
        MirrorFail usage "--dry-run cannot be combined with --adopt-dest;\
                          adoption changes destination ownership metadata"
    }
    return $o
}

# --- where the replica goes --------------------------------------------------

# z's candidate order exactly: the two commercial variables before the profile
# fallbacks, first one that EXISTS wins. The name travels with the directory
# because the console line reports which candidate answered.
proc ::machteld::MirrorOneDrive {} {
    set home [file normalize ~]
    set cands {}
    foreach {name var} {OneDrive OneDrive OneDriveCommercial OneDriveCommercial \
                        OneDriveConsumer OneDriveConsumer} {
        if {[info exists ::env($var)] && $::env($var) ne ""} {
            lappend cands [list $name $::env($var)]
        }
    }
    if {[info exists ::env(USERPROFILE)] && $::env(USERPROFILE) ne ""} {
        lappend cands [list "USERPROFILE fallback" [file join $::env(USERPROFILE) OneDrive]]
    }
    lappend cands [list "home fallback" [file join $home OneDrive]]
    foreach c $cands {
        lassign $c name dir
        if {$dir ne "" && [file exists $dir]} {
            return [dict create name $name dir [file nativename [file normalize $dir]]]
        }
    }
    return {}
}

proc ::machteld::MirrorAbs {p} { return [file nativename [FrontClean [file join [pwd] $p]]] }

# --- resolution, and the identity that makes it provable ---------------------
#
# THE PHYSICAL PATH, NOT THE NAME YOU TYPED. A destination reached through a
# junction is a different object from the one whose name you gave, and every
# safety question below -- is the destination inside the source, is it the same
# directory, has it changed since we looked -- is a question about OBJECTS. So
# each side is resolved to the nearest EXISTING ancestor, canonicalised through
# the OS, and any missing suffix is projected beneath it. The directory is
# never created here.
#
# !!! THIS LAYER IS NOT SOUND. DO NOT LIFT THE DESTRUCTIVE REFUSAL. !!!
#
# The two paragraphs above describe what this code is FOR. What it actually
# does is weaker, in two measured ways, and both were found by adversarial
# review after the port was written and committed.
#
# 1. `file normalize` DOES NOT RESOLVE A REPARSE POINT THAT IS THE FINAL
#    COMPONENT. Measured on the winsdk junction: `file normalize
#    C:/dev/.z/r/winsdk/10.0.26100.0` returns the junction's own path, while
#    normalising one component deeper follows it. Go's
#    `mirrorCanonicalExistingDirectory` opens the directory WITHOUT
#    FILE_FLAG_OPEN_REPARSE_POINT and calls GetFinalPathNameByHandleW, so it
#    always gets the target. `MirrorResolveDir` walks up to the nearest EXISTING
#    component, which for `--dest <a junction>` is the junction itself -- so
#    `physical` is not physical, and every containment clause below is handed a
#    path that is nowhere near the source. Reproduced end to end: a destination
#    junction pointing into the source tree passed every check, and robocopy's
#    own /L verdict reported a file INSIDE THE SOURCE as a destination extra --
#    which is to say, a real /MIR would have deleted it.
#
# 2. `dev` IS NOT THE VOLUME SERIAL NUMBER. It is the drive-letter index --
#    every path on C: reports `dev=2`, where the volume serial is 0xEB960D30.
#    And `file stat` on a junction returns the JUNCTION's identity, not the
#    target's (measured: 2/26741 against 2/53249), so the identity layer -- which
#    exists precisely because "a junction can make two different names one
#    directory" -- is blind to junctions as well.
#
# The internal use of identity is still sound: two names for one file report the
# same `ino`, which is what the `links -hardlinks` fixture checks from the other
# side. What is NOT sound is (a) comparing a junction against its target and
# (b) any claim that these numbers match z's -- they do not, which is also why
# the state and artefact files land at a filename z never reads.
#
# THE FIX IS ONE C PRIMITIVE, not more Tcl: a verb returning the canonical path,
# volume serial and 64-bit file index from a followed handle
# (GetFinalPathNameByHandleW + GetFileInformationByHandle). Until that exists,
# the destructive refusal in MirrorRun is the only thing standing between this
# file and data loss, and it is load-bearing rather than merely tidy.
proc ::machteld::MirrorIdentity {path} {
    if {[catch {file stat $path st}]} { return "" }
    return [list [dict get [array get st] dev] [dict get [array get st] ino]]
}

proc ::machteld::MirrorResolveDir {path} {
    set requested [MirrorAbs $path]
    set current $requested
    set missing {}
    while {1} {
        if {[file exists $current]} {
            if {![file isdirectory $current]} {
                MirrorFail badvalue "path component is not a directory: $current"
            }
            # `file normalize` FOLLOWS links, which is wrong for containment
            # (see FrontClean) and exactly right here: this asks where the
            # directory physically IS.
            set physical [file nativename [file normalize $current]]
            set ancestors [MirrorAncestors $physical]
            set projected $physical
            foreach m [lreverse $missing] { set projected [file join $projected $m] }
            set d [dict create requested $requested \
                       physical [file nativename [FrontClean $projected]] \
                       ancestor $physical exists [expr {![llength $missing]}] \
                       identity "" ancestors $ancestors]
            if {[dict get $d exists]} { dict set d identity [MirrorIdentity $physical] }
            return $d
        }
        # A DANGLING JUNCTION IS NOT A MISSING DIRECTORY. It is an object whose
        # target cannot be resolved, and treating it as absent would project the
        # destination through the wrong parent. `file exists` is false for it and
        # `file type` still answers, which is how the two are told apart.
        if {![catch {file type $current}]} {
            MirrorFail badvalue "path entry exists but its target cannot be resolved: $current"
        }
        set parent [file dirname $current]
        if {[string equal -nocase [FrontClean $parent] [FrontClean $current]]} {
            MirrorFail badvalue "no existing directory ancestor for $requested"
        }
        lappend missing [file tail $current]
        set current $parent
    }
}

proc ::machteld::MirrorAncestors {path} {
    set out {} ; set seen {}
    set current $path
    while {1} {
        set physical [file nativename [file normalize $current]]
        set key [string tolower [FrontClean $physical]]
        if {[dict exists $seen $key]} {
            MirrorFail oserror "directory ancestry loop at $physical"
        }
        dict set seen $key 1
        set id [MirrorIdentity $physical]
        if {$id ne ""} { lappend out $id }
        set parent [file dirname $physical]
        if {[string equal -nocase [FrontClean $parent] [FrontClean $physical]]} { return $out }
        set current $parent
    }
}

proc ::machteld::MirrorSame {a b} {
    return [string equal -nocase [FrontClean $a] [FrontClean $b]]
}

# THE NAME CHECKS, before anything is resolved. Cheap, and they catch the
# spelling mistakes; the identity checks below catch the rest.
proc ::machteld::MirrorValidatePaths {source dest forcedest} {
    if {!$forcedest && ![string equal -nocase [file tail [FrontClean $dest]] "z-backup"]} {
        MirrorFail badvalue "destination must end in z-backup unless --force-dest is used: $dest"
    }
    if {[FrontWithin $source $dest]} {
        MirrorFail badvalue "destination is inside source; refusing to mirror into $dest"
    }
    if {[FrontWithin $dest $source]} {
        MirrorFail badvalue "source is inside destination; refusing to mirror into $dest"
    }
    if {[MirrorSame [file dirname [FrontClean $dest]] [FrontClean $dest]]} {
        MirrorFail badvalue "destination cannot be a filesystem or share root: $dest"
    }
}

# AND THEN THE SAME QUESTIONS ASKED OF THE OBJECTS. A junction can make two
# different names one directory, or put the destination inside the source
# without either name saying so; only identity sees that.
proc ::machteld::MirrorValidatePlan {plan forcedest} {
    set s [dict get $plan source] ; set d [dict get $plan dest]
    set sp [dict get $s physical] ; set dp [dict get $d physical]
    if {[dict get $s exists] && [dict get $d exists]
        && [dict get $s identity] ne "" && [dict get $s identity] eq [dict get $d identity]} {
        MirrorFail badvalue "physical source and destination are the same directory: $sp"
    }
    if {[dict get $s identity] ne "" && [dict get $s identity] in [dict get $d ancestors]} {
        MirrorFail badvalue "physical destination is inside source; refusing to mirror into $dp"
    }
    if {[dict get $d exists] && [dict get $d identity] ne ""
        && [dict get $d identity] in [dict get $s ancestors]} {
        MirrorFail badvalue "physical source is inside destination; refusing to mirror into $dp"
    }
    if {[MirrorSame $sp $dp]} {
        MirrorFail badvalue "physical source and destination are the same path: $sp"
    }
    if {[FrontWithin $sp $dp]} {
        MirrorFail badvalue "physical destination is inside source; refusing to mirror into $dp"
    }
    if {[FrontWithin $dp $sp]} {
        MirrorFail badvalue "physical source is inside destination; refusing to mirror into $dp"
    }
    if {[MirrorSame [file dirname [FrontClean $dp]] [FrontClean $dp]]} {
        MirrorFail badvalue "destination cannot be a filesystem or share root: $dp"
    }
    if {!$forcedest && ![string equal -nocase [file tail [FrontClean $dp]] "z-backup"]} {
        MirrorFail badvalue "physical destination must end in z-backup unless --force-dest is used: $dp"
    }
}

proc ::machteld::MirrorPlan {source dest forcedest} {
    set source [MirrorAbs $source] ; set dest [MirrorAbs $dest]
    MirrorValidatePaths $source $dest $forcedest
    set s [MirrorResolveDir $source]
    if {![dict get $s exists]} { MirrorFail notfound "source does not exist: $source" }
    set plan [dict create source $s dest [MirrorResolveDir $dest]]
    MirrorValidatePlan $plan $forcedest
    return $plan
}

# THE RECHECK, between every phase. z re-resolves and compares because the
# window between "we validated this" and "robocopy opened it" is a window
# somebody can rename through. Tcl cannot hold z's kernel-level path pin -- that
# needs a handle per component with delete sharing denied -- so what is here is
# the CHECK without the PIN, and that difference is named in the docs rather
# than glossed: it narrows the window, it does not close it.
proc ::machteld::MirrorRecheck {plan forcedest} {
    set now [MirrorPlan [dict get $plan source physical] [dict get $plan dest physical] $forcedest]
    foreach side {source dest} {
        set b [dict get $plan $side] ; set a [dict get $now $side]
        if {![MirrorSame [dict get $b physical] [dict get $a physical]]} {
            MirrorFail oserror "physical $side changed after safety validation: [dict get $b physical]"
        }
        if {[dict get $b exists] && [dict get $a exists]
            && [dict get $b identity] ne "" && [dict get $a identity] ne ""
            && [dict get $b identity] ne [dict get $a identity]} {
            MirrorFail oserror "physical $side changed after safety validation: [dict get $b physical]"
        }
    }
    return $now
}

# --- the reserved paths inside the trees -------------------------------------

proc ::machteld::MirrorShellCache {root} {
    return [file nativename [file join $root .z cache shell]]
}

# `<root>\.z\mirror-links.json`, NOT `<root>\.z-mirror-links.json`. The first
# version guessed the latter and the guess was live in the dry run twice over:
# `/XF` excluded a file that does not exist while failing to exclude z's real
# reserved manifest, so a source z had mirrored showed spurious drift; and the
# reserved-extra correction looked for the destination copy at the wrong path,
# never fired, and reported an extra file and a set `extras` bit that z
# suppresses -- which is the precise misreport the correction exists to prevent.
proc ::machteld::MirrorLinkManifestPath {root} {
    return [file nativename [file join $root .z mirror-links.json]]
}

# A SIBLING OF THE DESTINATION, NOT A FILE INSIDE IT, and the difference is the
# whole point of the record. z spells it `filepath.Clean(dest) + suffix` -- string
# concatenation with no separator -- so `...\z-backup` becomes
# `...\z-backup.z-mirror-owner.json`, one level up. `file join` put it INSIDE the
# destination, where it is a file with no source counterpart, which is to say a
# destination extra, which is to say the first thing `/MIR` deletes. The guard
# would have deleted its own authorisation record. This file's own header said
# "beside the destination" while the code said "inside".
proc ::machteld::MirrorOwnerPath {root} {
    return [file nativename "[FrontClean $root].z-mirror-owner.json"]
}

# --- robocopy ----------------------------------------------------------------

# TRUSTED BY PATH, NOT BY PATH LOOKUP. z resolves robocopy under the real system
# directory and refuses anything else, because a `robocopy.exe` earlier on PATH
# is an arbitrary program about to be handed /MIR and a destination.
proc ::machteld::MirrorRobocopy {} {
    set sysroot [expr {[info exists ::env(SystemRoot)] ? $::env(SystemRoot) : "C:/Windows"}]
    set exe [file join $sysroot System32 robocopy.exe]
    if {![file exists $exe]} {
        MirrorFail notfound "no robocopy at [file nativename $exe]"
    }
    return [file nativename $exe]
}

proc ::machteld::MirrorQuote {a} {
    if {[regexp {[ \t\r\n\"]} $a]} { return "\"[string map [list \" \\\"] $a]\"" }
    return $a
}
proc ::machteld::MirrorCommandLine {exe argl} {
    set parts [list [MirrorQuote $exe]]
    foreach a $argl { lappend parts [MirrorQuote $a] }
    return [join $parts " "]
}

# robocopy's exit code is a BITFIELD, and reading it as an ordinal is the
# classic way to call a successful mirror a failure: 1 is "copied files", 3 is
# "copied files and saw extras", and only >= 8 is a real failure.
proc ::machteld::MirrorExitMeaning {code} {
    if {$code == 0} { return "no changes; destination already matched source" }
    set f {}
    if {$code & 1}  { lappend f "copied files" }
    if {$code & 2}  { lappend f "destination extras noticed or removed" }
    if {$code & 4}  { lappend f "mismatches noticed" }
    if {$code & 8}  { lappend f "copy failures" }
    if {$code & 16} { lappend f "fatal robocopy error" }
    if {![llength $f]} { return "robocopy code $code" }
    return [join $f "; "]
}

# --- robocopy's summary block ------------------------------------------------

proc ::machteld::MirrorSummaryFields {} { return {total copied skipped mismatch failed extras} }

proc ::machteld::MirrorParseSummary {text} {
    set s [dict create dirs {} files {} bytes {} times {} ended ""]
    foreach raw [split [string map {\r\n \n} $text] \n] {
        if {[regexp -nocase {^\s*(Dirs|Files|Bytes)\s*:\s+(.+)$} $raw -> what rest]} {
            set values [regexp -all -inline {\S+} [string trim $rest]]
            set row {}
            set i 0
            foreach field [MirrorSummaryFields] {
                if {$i < [llength $values]} { dict set row $field [lindex $values $i] }
                incr i
            }
            dict set s [string tolower $what] $row
            continue
        }
        if {[regexp -nocase {^\s*Times\s*:\s+(.+)$} $raw -> rest]} {
            dict set s times [regexp -all -inline {\S+} [string trim $rest]]
            continue
        }
        if {[regexp -nocase {^\s*Ended\s*:\s+(.+)$} $raw -> rest]} {
            dict set s ended [string trim $rest]
        }
    }
    return $s
}

# ROBOCOPY'S LOG IS NOT UTF-8, and reading it as if it were cost the whole
# summary. The log carries file names in the system code page, so a single
# non-ASCII byte anywhere in 19 MB of listing makes a strict UTF-8 decode throw
# -- and the first version caught that, fell back to robocopy's stdout, which
# `/LOG:` had left EMPTY, and printed `(robocopy summary not found)` under a
# perfectly good log file. It reported no drift where there was drift, which is
# the one failure mode a preflight must not have.
#
# Read as BYTES and left undecoded: the summary block is pure ASCII (`Dirs :`,
# digits, `Ended :`), and this text is parsed rather than displayed, so a byte
# string is exactly the right thing to match against. `fallback` is robocopy's
# stdout, used only when there is no log at all.
proc ::machteld::MirrorReadLog {path fallback} {
    if {![file exists $path]} { return $fallback }
    if {[catch {open $path rb} fh]} { return $fallback }
    set d [read $fh]
    close $fh
    if {$d eq ""} { return $fallback }
    return $d
}

proc ::machteld::MirrorDash {v} { return [expr {$v eq "" ? "-" : $v}] }

proc ::machteld::MirrorSummaryLines {title s} {
    set out [list "$title:"]
    foreach name {dirs files bytes} {
        set row [dict get $s $name]
        if {![llength $row]} continue
        lappend out [format "  %-5s total=%s copied=%s skipped=%s failed=%s extras=%s" $name \
            [MirrorDash [FrontDictOr $row total ""]] [MirrorDash [FrontDictOr $row copied ""]] \
            [MirrorDash [FrontDictOr $row skipped ""]] [MirrorDash [FrontDictOr $row failed ""]] \
            [MirrorDash [FrontDictOr $row extras ""]]]
    }
    if {[dict get $s ended] ne ""} { lappend out "  ended [dict get $s ended]" }
    if {[llength $out] == 1} { lappend out "  (robocopy summary not found)" }
    return $out
}

# THE MANIFEST IS AN EXTRA ROBOCOPY WOULD DELETE, and that is the point of this
# correction rather than a quirk. The destination's `.z-mirror-links.json` has
# no source-side counterpart during the run (the source's is excluded with /XF),
# so /MIR counts it as an extra and the exit code gains bit 2 -- reporting drift
# that is entirely this command's own bookkeeping. One file is subtracted, and
# the code's `extras` bit is cleared ONLY when the corrected counts reach zero.
proc ::machteld::MirrorNormalizeReserved {code s manifest} {
    if {![file isfile $manifest]} { return [list $code $s] }
    return [MirrorNormalizeReservedSize $code $s [file size $manifest]]
}
proc ::machteld::MirrorNormalizeReservedSize {code s size} {
    if {![llength [dict get $s files]] || ![llength [dict get $s dirs]]} { return [list $code $s] }
    set fe [MirrorInt [FrontDictOr [dict get $s files] extras ""]]
    set de [MirrorInt [FrontDictOr [dict get $s dirs] extras ""]]
    if {$fe eq "" || $de eq "" || $fe < 1} { return [list $code $s] }
    incr fe -1
    dict set s files extras $fe
    if {[llength [dict get $s bytes]]} {
        set be [MirrorInt [FrontDictOr [dict get $s bytes] extras ""]]
        if {$be ne "" && $be >= $size} { dict set s bytes extras [expr {$be - $size}] }
    }
    if {$fe == 0 && $de == 0} { set code [expr {$code & ~2}] }
    return [list $code $s]
}
proc ::machteld::MirrorInt {v} {
    set v [string map {, ""} [string trim $v]]
    if {$v eq "" || $v eq "-"} { return "" }
    if {![string is entier -strict $v]} { return "" }
    return $v
}

# --- the run's own bookkeeping ----------------------------------------------

proc ::machteld::MirrorNow {{ms ""}} {
    if {$ms eq ""} { set ms [clock milliseconds] }
    return [clock format [expr {$ms / 1000}] -format "%Y-%m-%dT%H:%M:%S" -timezone :UTC]
}

# z's run id: an RFC3339-ish UTC stamp with nanoseconds, the pid, and 8 random
# bytes. The randomness is what makes two runs started in the same millisecond
# by the same pid still distinct.
proc ::machteld::MirrorRunID {{ms ""}} {
    if {$ms eq ""} { set ms [clock milliseconds] }
    set stamp [clock format [expr {$ms / 1000}] -format "%Y%m%dT%H%M%S" -timezone :UTC]
    set frac [format "%03d000000" [expr {$ms % 1000}]]
    # HEX, NOT THE RAW BYTES. `hash random` returns eight random BYTES, and the
    # first version put them straight into a FILENAME -- which produced
    # `...-p6948-<eight bytes of binary>-report.txt` on disk: a run id that is
    # unreadable, unquotable, and different every time it round-trips through an
    # encoding. z hex-encodes it; so does this.
    return "${stamp}.${frac}Z-p[pid]-[binary encode hex [hash random 8]]"
}

# OUTSIDE BOTH TREES, ALWAYS. The liveness file must not be inside the thing
# being mirrored (robocopy would copy a file that is changing under it) nor
# inside the destination (it would be deleted as an extra), so it is keyed on
# the workspace's IDENTITY and lives under the user cache or TEMP.
proc ::machteld::MirrorStatePath {} {
    variable MIRROR_STATE ; variable FRONT_ROOT
    if {$MIRROR_STATE ne ""} { return $MIRROR_STATE }
    FrontRoots
    set root [MirrorResolveDir $FRONT_ROOT]
    set key [string tolower [FrontClean [dict get $root physical]]]
    if {[dict get $root identity] ne ""} {
        lassign [dict get $root identity] vol fil
        set key [format "volume:%016x:file:%016x" $vol $fil]
    }
    set name "mirror-[string range [hash sum sha256 $key] 0 31].json"
    set cands {}
    if {[info exists ::env(LOCALAPPDATA)] && $::env(LOCALAPPDATA) ne ""} {
        lappend cands $::env(LOCALAPPDATA)
    }
    if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { lappend cands $::env(TEMP) }
    set rejected {}
    foreach c $cands {
        set dir [file join $c z mirror-state]
        if {[catch {MirrorResolveDir $dir} rd]} { lappend rejected "$dir: $rd" ; continue }
        if {[FrontWithin [dict get $root physical] [dict get $rd physical]]} {
            lappend rejected "$dir: inside mirror source" ; continue
        }
        set MIRROR_STATE [file nativename [file join [dict get $rd physical] $name]]
        return $MIRROR_STATE
    }
    MirrorFail oserror "no mirror-state location outside [dict get $root physical] ([join $rejected {; }])"
}

proc ::machteld::MirrorArtifactPath {statepath} {
    set base [file tail $statepath]
    if {![string match "mirror-*" $base] || ![string match "*.json" $base]} {
        MirrorFail oserror "unexpected mirror-state filename: $statepath"
    }
    return [file nativename [file join [file dirname $statepath] "artifacts-[string range $base 7 end]"]]
}

# ATOMIC, because a half-written state file is read by `status` and by the next
# run's staleness check. Written to a temp name beside the target and renamed
# over it; the retry loop is z's, for the window where a reader has the old file
# open and Windows refuses the replace.
proc ::machteld::MirrorWriteAtomic {path data} {
    file mkdir [file dirname $path]
    set tmp [file join [file dirname $path] ".[file tail $path].tmp-[pid]-[clock milliseconds]"]
    set fh [open $tmp wb]
    puts -nonewline $fh $data
    close $fh
    set deadline [expr {[clock milliseconds] + 500}]
    while {1} {
        if {![catch {file rename -force $tmp $path}]} { return }
        if {[clock milliseconds] > $deadline} {
            catch {file delete -force $tmp}
            MirrorFail oserror "cannot commit $path"
        }
        after 5
    }
}

proc ::machteld::MirrorWriteState {path base stage} {
    if {$path eq ""} return
    set now [clock milliseconds]
    set d [dict create stage $stage updatedAt [MirrorNow $now] \
               heartbeat [expr {$now / 1000}] pid [pid]]
    foreach {k v} $base { dict set d $k $v }
    MirrorWriteAtomic $path "[LedgerJson [list o [MirrorStateObj $d]]]\n"
}

# The state file's key order is z's struct order, for the same reason the
# ledger's is: `z status` reads this file.
proc ::machteld::MirrorStateObj {d} {
    set o {}
    foreach {k type} {stage s updatedAt s heartbeat i pid i runId s startedAt s
                      dryRun b source s dest s logDir s preflightLog s mirrorLog s
                      postflightLog s linkManifest s reportPath s} {
        if {![dict exists $d $k]} continue
        set v [dict get $d $k]
        switch -- $type {
            i { lappend o $k [list i $v] }
            b { lappend o $k [list b $v] }
            default { lappend o $k [list s $v] }
        }
    }
    return $o
}

# --- the link manifest -------------------------------------------------------
#
# WHAT A RESTORE NEEDS. robocopy /XJ refuses to copy a junction or a symlink, so
# the replica is missing them by design; this file is the record that lets them
# be put back. `skipped: true` (from --skip-link-scan) is what makes a replica
# refuse to be restored from -- an incomplete manifest is worse than none,
# because it looks complete.
proc ::machteld::MirrorLinkManifest {source runid scan skipped ms} {
    set links {}
    foreach e [dict get $scan links] {
        lappend links [list o [list path   [list s [dict get $e path]] \
                                    type   [list s [dict get $e type]] \
                                    target [list s [dict get $e target]]]]
    }
    set errs {}
    foreach e [dict get $scan errors] { lappend errs [list s $e] }
    set o [list schema {i 1} \
                generatedBy {s {z mirror}} \
                runId [list s $runid] \
                createdAt [list s [MirrorNow $ms]] \
                source [list s $source] \
                policy {s {robocopy /XJ skips these; they are recorded here for restoration}} \
                skipped [list b $skipped] \
                links [expr {[llength $links] ? [list a $links] : {n {}}}]]
    if {[llength $errs]} { lappend o errors [list a $errs] }
    return "[LedgerJson [list o $o]]\n"
}

# --- the source link scan ----------------------------------------------------
#
# THE C VERB, not a Tcl walk. `links` classifies every reparse point from the
# directory enumeration itself, so the scan costs 986 ms where z's per-path
# GetFileAttributes costs 14,081 -- and z runs it TWICE per mirror. The type
# names and the rendered form are z's because both go into the manifest and the
# report.
proc ::machteld::MirrorScan {source} {
    set d [links $source]
    set out {} ; set errs {}
    foreach e [dict get $d links] {
        lappend out [dict create path [file nativename [dict get $e path]] \
                         type [dict get $e type] target [dict get $e target]]
    }
    foreach e [dict get $d errors] {
        lappend errs "inspect link [file nativename [dict get $e path]]: win32 [dict get $e win32] ([dict get $e reason])"
    }
    return [dict create links $out errors $errs]
}

proc ::machteld::MirrorLinkText {e} {
    return "[dict get $e path] \[[dict get $e type] -> [dict get $e target]\]"
}

# --- the report --------------------------------------------------------------
#
# z's FORMAT, BYTE FOR BYTE, including the "z OneDrive mirror report" heading:
# `z logs`, `z status` and the cockpit parse these files, so this is a shared
# file format and not a rendering. The 256 KB link-detail budget is z's too --
# a tree with ten thousand junctions must not produce a report nobody can open.
proc ::machteld::MirrorReport {d} {
    set budget [expr {256 << 10}]
    set mode [expr {[dict get $d dryrun] ? "dry run" : "mirror"}]
    set out {}
    lappend out "z OneDrive mirror report"
    lappend out "created: [MirrorNow]"
    if {[dict get $d runid] ne ""} { lappend out "run id: [dict get $d runid]" }
    lappend out "mode: $mode"
    lappend out "source: [dict get $d source]"
    lappend out "destination: [dict get $d dest]"
    lappend out "robocopy: [dict get $d robocopy]"
    lappend out "link policy: /XJ - skip symbolic links and junctions"
    lappend out "recovery model: one synchronized recovery replica; source deletions propagate"
    if {[FrontDictOr $d metadata ""] ne ""} { lappend out "metadata policy: [dict get $d metadata]" }
    if {[FrontDictOr $d manifest ""] ne ""} { lappend out "link manifest: [dict get $d manifest]" }
    lappend out ""
    lappend out "preflight command: [MirrorOr [FrontDictOr $d preflightcmd ""] "(skipped)"]"
    lappend out "mirror command: [MirrorOr [FrontDictOr $d mirrorcmd ""] "(dry run only)"]"
    lappend out "postflight command: [MirrorOr [FrontDictOr $d postflightcmd ""] "(not run)"]"
    lappend out ""
    if {[dict get $d skiplinkscan]} {
        lappend out "link scan: skipped by --skip-link-scan"
    } else {
        set links [dict get $d links] ; set lerrs [dict get $d linkerrors]
        lappend out "link scan: [llength $links] link(s), [llength $lerrs] scan error(s)"
        set written 0
        foreach l $links {
            set line "  [MirrorLinkText $l]"
            if {[string length $line] + 1 > $budget} break
            lappend out $line
            incr budget [expr {-([string length $line] + 1)}]
            incr written
        }
        if {[llength $links] - $written != 0} {
            lappend out "  ... [expr {[llength $links] - $written}] additional link(s) are recorded in the manifest"
        }
        set ewritten 0
        foreach e $lerrs {
            set line "  scan error: $e"
            if {[string length $line] + 1 > $budget} break
            lappend out $line
            incr budget [expr {-([string length $line] + 1)}]
            incr ewritten
        }
        if {[llength $lerrs] - $ewritten != 0} {
            lappend out "  ... [expr {[llength $lerrs] - $ewritten}] additional scan error(s) are recorded in the manifest"
        }
    }
    lappend out ""
    if {[dict get $d havepreflight]} {
        lappend out {*}[MirrorSummaryLines "preflight summary" [dict get $d preflight]]
    }
    if {[FrontDictOr $d havefinal 0]} {
        lappend out ""
        lappend out {*}[MirrorSummaryLines "final summary" [dict get $d final]]
    }
    if {[FrontDictOr $d havepostflight 0]} {
        lappend out ""
        lappend out {*}[MirrorSummaryLines "postflight summary" [dict get $d postflight]]
        lappend out "postflight exit code: [dict get $d postflightcode]"
    }
    lappend out ""
    lappend out "robocopy exit code: [dict get $d code]"
    lappend out "meaning: [MirrorExitMeaning [dict get $d code]]"
    set result [FrontDictOr $d result ""]
    if {$result eq ""} { set result [expr {[dict get $d code] >= 8 ? "failed" : "ok"}] }
    lappend out "result: $result"
    if {[llength [FrontDictOr $d wrappererrors {}]]} {
        lappend out "wrapper errors:"
        foreach e [dict get $d wrappererrors] { lappend out "  $e" }
    }
    lappend out ""
    lappend out "logs:"
    foreach l [dict get $d logs] { lappend out "  $l" }
    return "[join $out \n]\n"
}
proc ::machteld::MirrorOr {v d} { return [expr {$v eq "" ? $d : $v}] }

# --- the artefact index ------------------------------------------------------
#
# DISCOVERY METADATA, NOT LIVENESS. Each artefact advances INDEPENDENTLY: a dry
# run publishes its new report and preflight log without forgetting the last
# completed robocopy log, which is why `z logs --robocopy` still finds something
# after a dry run. Missing files are pruned on read rather than trusted.
proc ::machteld::MirrorPublishArtifacts {path base code result} {
    set prev {}
    if {![catch {LedgerRead $path} raw]} {
        catch {set prev [json decode [encoding convertfrom utf-8 $raw]]}
    }
    set idx [dict create version 2]
    foreach k {preflightLog mirrorLog postflightLog linkManifest artifactProvenance} {
        if {[dict exists $prev $k]} { dict set idx $k [dict get $prev $k] }
    }
    # PRUNE WHAT IS GONE. An index naming a deleted log is a reader following a
    # path that is not there.
    foreach k {preflightLog mirrorLog postflightLog linkManifest} {
        if {[dict exists $idx $k] && ![file exists [dict get $idx $k]]} { dict unset idx $k }
    }
    set prov [dict create runId [dict get $base runId] \
                  logDir [dict get $base logDir] \
                  logDirKey [string tolower [FrontClean [dict get $base logDir]]]]
    set provall [expr {[dict exists $idx artifactProvenance] ? [dict get $idx artifactProvenance] : {}}]
    if {![file exists [dict get $base reportPath]]} {
        MirrorFail oserror "completed report does not exist: [dict get $base reportPath]"
    }
    dict set provall report $prov
    foreach {k field} {preflightLog preflight mirrorLog robocopy postflightLog postflight
                       linkManifest links} {
        if {[dict exists $base $k] && [file exists [dict get $base $k]]} {
            dict set idx $k [dict get $base $k]
            dict set provall $field $prov
        }
    }
    dict set idx artifactProvenance $provall
    set o [list version {i 2} runId [list s [dict get $base runId]] \
                updatedAt [list s [MirrorNow]] startedAt [list s [dict get $base startedAt]] \
                dryRun [list b [dict get $base dryRun]] \
                source [list s [dict get $base source]] dest [list s [dict get $base dest]] \
                logDir [list s [dict get $base logDir]] \
                reportPath [list s [dict get $base reportPath]]]
    foreach {k jk} {preflightLog preflightLog mirrorLog mirrorLog postflightLog postflightLog
                    linkManifest linkManifest} {
        if {[dict exists $idx $k]} { lappend o $jk [list s [dict get $idx $k]] }
    }
    set provo {}
    foreach kind {report preflight robocopy postflight links} {
        if {![dict exists $provall $kind]} continue
        set p [dict get $provall $kind]
        lappend provo $kind [list o [list runId [list s [dict get $p runId]] \
                                          logDir [list s [dict get $p logDir]] \
                                          logDirKey [list s [dict get $p logDirKey]]]]
    }
    if {[llength $provo]} { lappend o artifactProvenance [list o $provo] }
    lappend o code [list i $code] result [list s $result]
    MirrorWriteAtomic $path "[LedgerJson [list o $o]]\n"
}

# --- the command -------------------------------------------------------------

proc ::machteld::MirrorUsage {} {
    return "usage: mt mirror \[--dry-run\] \[--dest <path>\] \[--log-dir <path>\]\
            \[--skip-link-scan\] \[--no-preflight\] \[--quiet\] \[--force-dest\]\
            \[--adopt-dest\] \[--preserve-acl\]"
}

proc ::machteld::MirrorRun {argl} {
    variable FRONT_ROOT
    FrontRoots
    set o [MirrorOpts $argl]
    if {[dict get $o help]} { return [MirrorUsage] }

    set out {}
    set source [MirrorAbs $FRONT_ROOT]
    set od [MirrorOneDrive]
    if {[dict get $o dest] eq "" && ![dict size $od]} {
        MirrorFail notfound "could not find OneDrive; pass --dest <path>"
    }
    set dest [dict get $o dest]
    if {$dest eq ""} { set dest [file join [dict get $od dir] z-backup] }
    set dest [MirrorAbs $dest]
    set logdir [dict get $o logdir]
    if {$logdir eq ""} { set logdir [file join [file dirname $dest] z-backup-logs] }
    set logdir [MirrorAbs $logdir]

    set requestedsource $source ; set requesteddest $dest
    set plan [MirrorPlan $source $dest [dict get $o forcedest]]
    set source [dict get $plan source physical]
    set dest   [dict get $plan dest physical]

    # THE DESTRUCTIVE HALF, REFUSED. See the header: /MIR deletes, z gates it on
    # an ownership record this does not write yet, and a command that is almost
    # ready to delete is the most dangerous state it can be in.
    if {![dict get $o dryrun]} {
        MirrorFail unsupported "a real /MIR run needs the destination ownership record\
            ([MirrorOwnerPath $dest]) and its guard, which are not ported yet --\
            run `mt mirror --dry-run`, or `z mirror` for the destructive run"
    }

    set robocopy [MirrorRobocopy]
    set statepath [MirrorStatePath]
    set artifacts [MirrorArtifactPath $statepath]
    set started [clock milliseconds]
    set runid [MirrorRunID $started]
    file mkdir $logdir
    set preflightlog [file nativename [file join $logdir "$runid-preflight.log"]]
    set mirrorlog    [file nativename [file join $logdir "$runid-robocopy.log"]]
    set postflightlog [file nativename [file join $logdir "$runid-postflight.log"]]
    set manifestlog  [file nativename [file join $logdir "$runid-links.json"]]
    set reportpath   [file nativename [file join $logdir "$runid-report.txt"]]

    set base [dict create runId $runid startedAt [MirrorNow $started] \
                  dryRun [dict get $o dryrun] source $source dest $dest logDir $logdir \
                  preflightLog $preflightlog mirrorLog $mirrorlog \
                  postflightLog $postflightlog linkManifest $manifestlog \
                  reportPath $reportpath]
    catch {MirrorWriteState $statepath $base starting}

    # THE HEADING IS machteld's; every line under it is z's. Same split as
    # `ledger check`: a heading names the tool you typed, the content is the
    # answer and has to agree.
    lappend out "mt mirror"
    lappend out "  source:      $source"
    lappend out "  destination: $dest"
    if {![MirrorSame $requestedsource $source]} { lappend out "  source alias: $requestedsource" }
    if {![MirrorSame $requesteddest $dest]}     { lappend out "  dest alias:   $requesteddest" }
    lappend out "  logs:        $logdir"
    # BRACED, because the backslashes are the message. Written as a quoted
    # string, Tcl ate `\c` and `\s` as escapes and the line read
    # `exclude and regenerate .zcacheshell` -- a path that does not exist,
    # printed as reassurance that it was excluded.
    lappend out {  cache policy: exclude and regenerate .z\cache\shell}
    if {[dict get $o dest] eq "" && [dict size $od]} {
        lappend out "  OneDrive:    [dict get $od dir] ([dict get $od name])"
    }
    lappend out "  link policy: /XJ, skip symbolic links and junctions"
    lappend out ""

    set scan [dict create links {} errors {}]
    if {![dict get $o skiplinkscan]} {
        lappend out "Scanning for symbolic links/junctions without following them..."
        set scan [MirrorScan $source]
        set links [dict get $scan links]
        if {![llength $links]} {
            lappend out "  none found"
        } else {
            lappend out "  [llength $links] link(s) found; robocopy will skip them with /XJ"
            foreach l [lrange $links 0 19] { lappend out "  [MirrorLinkText $l]" }
            if {[llength $links] > 20} {
                lappend out "  ... [expr {[llength $links] - 20}] more in report"
            }
        }
        if {[llength [dict get $scan errors]]} {
            lappend out "  [llength [dict get $scan errors]] scan error(s); see report"
        }
        lappend out ""
    }
    MirrorWriteAtomic $manifestlog [encoding convertto utf-8 \
        [MirrorLinkManifest $source $runid $scan [dict get $o skiplinkscan] [clock milliseconds]]]

    set copypolicy "/COPY:DAT"
    set metadata "portable content (data, attributes, timestamps); ACL/owner/audit metadata is not preserved"
    if {[dict get $o preserveacl]} {
        set copypolicy "/COPY:DATS"
        set metadata "data, attributes, timestamps, and NTFS ACLs; owner/audit metadata is not preserved"
    }
    set common [list $source $dest /MIR /XJ /R:3 /W:5 $copypolicy /DCOPY:DAT \
                     /XD [MirrorShellCache $source] /XF [MirrorLinkManifestPath $source]]

    set preflight [dict create dirs {} files {} bytes {} times {} ended ""]
    set havepre 0 ; set precmd "" ; set precode 0
    if {![dict get $o nopreflight]} {
        set preargs [concat $common [list /L /BYTES /NP /NFL /NDL /NJH "/LOG:$preflightlog"]]
        set precmd [MirrorCommandLine $robocopy $preargs]
        catch {MirrorWriteState $statepath $base preflight}
        lappend out "Preflight scan (robocopy /L, no changes)..."
        # RE-RESOLVED IMMEDIATELY BEFORE THE SPAWN. Tcl cannot pin the path the
        # way z's handle guard does; this narrows the window rather than closing
        # it, which is stated in the docs rather than glossed.
        MirrorRecheck $plan [dict get $o forcedest]
        set r [run -timeout 3600s -dir $source -- $robocopy {*}$preargs]
        set precode [dict get $r exit]
        set text [MirrorReadLog $preflightlog [dict get $r out]]
        set preflight [MirrorParseSummary $text]
        lassign [MirrorNormalizeReserved $precode $preflight [MirrorLinkManifestPath $dest]] \
                precode preflight
        set havepre 1
        lappend out "  robocopy code $precode: [MirrorExitMeaning $precode]"
        lappend out {*}[MirrorSummaryLines "  would change" $preflight]
        lappend out ""
    }

    set result [expr {[llength [dict get $scan errors]] ? "failed" : "ok"}]
    set rep [dict create runid $runid dryrun 1 source $source dest $dest robocopy $robocopy \
                 preflightcmd $precmd links [dict get $scan links] \
                 linkerrors [dict get $scan errors] skiplinkscan [dict get $o skiplinkscan] \
                 havepreflight $havepre preflight $preflight code $precode result $result \
                 metadata $metadata manifest $manifestlog \
                 logs [MirrorExisting [list $preflightlog $manifestlog]]]
    MirrorWriteAtomic $reportpath [encoding convertto utf-8 [MirrorReport $rep]]
    MirrorPublishArtifacts $artifacts $base $precode $result
    catch {file delete -force $statepath}

    lappend out "Dry run complete. Report: $reportpath"
    if {$result ne "ok"} { FrontStatus 1 }
    return [join $out \n]
}

proc ::machteld::MirrorExisting {paths} {
    set out {}
    foreach p $paths { if {[file exists $p]} { lappend out $p } }
    return $out
}
