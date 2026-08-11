# machteld -- the payload ledger.
#
# WHAT THIS IS FOR. The workspace tracks its own code, docs and manifests in git
# and deliberately does NOT track the payloads: `t/`, `r/`, `go/`, `deno/` and
# `cache/` are fetched, not committed, and together they are gigabytes. The
# ledger is what stands in for them -- a content-addressed inventory of every
# payload, its entrypoints, their SHA-256s and sizes, and where each came from,
# so a clone can tell what it is missing and prove that what it has is what was
# there. `refresh` writes it; `check` says whether the tree still matches.
#
# WHY IT IS A SEPARATE FILE. `front.tcl` is already the longest thing here, and
# [rule 3] is "one page, or it is out". This is one command with one job and no
# entanglement with resolution beyond four helpers it calls.
#
# --- THE ONE DECISION WORTH ARGUING ------------------------------------------
#
# THE FILE STAYS BYTE-IDENTICAL TO z's, INCLUDING `"generatedBy": "z ledger
# refresh"`. That looks wrong -- machteld generated it, and machteld should say
# so -- and it is the only defensible answer while both tools exist. The ledger
# is a SHARED ARTEFACT in a SHARED workspace: one file, one git history, two
# programs that can write it. If machteld stamped its own name, `z ledger check`
# would call the file stale the moment machteld touched it, `mt ledger check`
# would call it stale the moment z did, and the workspace would carry a file that
# is permanently wrong according to whichever tool did not write it last. The
# field names the FORMAT's generator -- the `ledger refresh` command of the z
# workspace kit -- and machteld is a second implementation of that command, not a
# second format. The same reasoning keeps z's wording inside `restore.method`.
#
# What is NOT z's is the advice line `check` prints when something is stale. That
# is a sentence addressed to a person, not a byte in a shared file, and telling
# someone typing `mt` to go run `z` is the one thing a front door replacing z
# must not do. It is the only line in this command that differs, and the
# agreement test asserts both halves: every other line identical, that one line
# different in exactly this way.
#
# --- AND THE ONE THING TO KNOW BEFORE READING THE JSON CODE ------------------
#
# The output has to match `json.MarshalIndent` byte for byte, which means
# reproducing four Go behaviours that are not what a JSON writer would choose:
# struct DECLARATION order (not alphabetical), HTML escaping of `<`, `>` and `&`
# even in a file no browser will read, `omitempty` semantics per field, and the
# fact that `omitempty` ON A STRUCT DOES NOTHING -- which is why every payload
# carries a `"restore": {}` it does not need. See LedgerJson below.

namespace eval ::machteld {
    variable LEDGER_PAYLOAD_REL "book/payloads.lock.json"
    variable LEDGER_MSYS2_REL   "book/msys2-packages.lock.txt"
}

# --- the JSON writer, shaped to Go -------------------------------------------
#
# A VALUE IS `{type payload}`: `s` string, `i` integer, `o` ordered object, `a`
# array, `n` null. Ordered, because the key order in the output is the order the
# fields are DECLARED in `ledger_builtin.go` -- a Tcl dict would give whatever
# order it liked and a sorted emitter would give alphabetical. Neither matches,
# and the file has to match exactly or the two tools fight over it forever.
proc ::machteld::LedgerJson {v {ind ""}} {
    lassign $v type payload
    switch -- $type {
        i { return $payload }
        n { return "null" }
        s { return [LedgerJsonStr $payload] }
        b {
            # A BOOLEAN TYPE RATHER THAN A RAW-TEXT ONE. `mirror`'s state and
            # artefact files carry `dryRun` and `skipped`, and the obvious way to
            # get them out is a passthrough that emits whatever string it is
            # handed -- which is an unescaped hole in a writer whose entire job
            # is escaping. This takes a Tcl truth value and emits one of two
            # literals; nothing else can reach the output.
            return [expr {$payload ? "true" : "false"}]
        }
        o {
            # Go's indenter writes an empty object as `{}` on one line, and this
            # is not a corner case: EVERY payload ends in `"restore": {}`.
            if {![llength $payload]} { return "\{\}" }
            set inner "$ind  "
            set parts {}
            foreach {k val} $payload {
                lappend parts "$inner[LedgerJsonStr $k]: [LedgerJson $val $inner]"
            }
            return "\{\n[join $parts ",\n"]\n$ind\}"
        }
        a {
            if {![llength $payload]} { return "\[\]" }
            set inner "$ind  "
            set parts {}
            foreach val $payload { lappend parts "$inner[LedgerJson $val $inner]" }
            return "\[\n[join $parts ",\n"]\n$ind\]"
        }
        default { Fail FRONT badvalue "ledger: unknown json value type \"$type\"" }
    }
}

# GO ESCAPES `<`, `>` AND `&`, and that is the trap. `json.Marshal` HTML-escapes
# by default -- only an `Encoder` with `SetEscapeHTML(false)` does not -- so a
# source URL with a query string comes out spelling its ampersand as a six-
# character escape, where every other JSON writer in the world writes it plainly.
# z calls `json.MarshalIndent`, so escaping is ON, and a straightforward writer
# would differ on the first payload whose metadata carried one of the three.
#
# The rest is Go's `encodeState.string`: five short escapes, `\u00xx` in
# LOWERCASE hex for every other C0 control -- Go uses neither `\b` nor `\f` --
# and U+2028/U+2029 spelled out, those two being legal in JSON and fatal in
# JavaScript. Go also substitutes U+FFFD for invalid UTF-8; that cannot arise
# here, because every string in this document came through `json decode` or off
# the filesystem as a name, and `json decode` would have refused it first.
proc ::machteld::LedgerJsonStr {s} {
    set out [string map [list \\ {\\} \" {\"} \n {\n} \r {\r} \t {\t} \
                              < {\u003c} > {\u003e} & {\u0026}] $s]
    if {[regexp {[\u0000-\u001f\u2028\u2029]} $out]} {
        set fixed ""
        foreach ch [split $out ""] {
            set n [scan $ch %c]
            if {$n < 0x20 || $n == 0x2028 || $n == 0x2029} {
                append fixed [format {\u%04x} $n]
            } else {
                append fixed $ch
            }
        }
        set out $fixed
    }
    return "\"$out\""
}

# --- small helpers that mirror named Go functions ----------------------------

# `relSlash`: the path as written under the workspace, forward-slashed. Compared
# case-insensitively where Go's `filepath.Rel` is not, which can only matter if
# the two programs ever spell the same directory with different case -- and if
# they did, Go would emit a `../..` climb here and the agreement test would say
# so rather than the difference passing silently.
proc ::machteld::LedgerRelSlash {root path} {
    set r [FrontClean $root]
    set p [FrontClean $path]
    if {[string equal -nocase $r $p]} { return "." }
    if {[string index $r end] ne "/"} { append r "/" }
    if {[string equal -nocase -length [string length $r] $p $r]} {
        return [string range $p [string length $r] end]
    }
    return $p
}

# `compactToken`: lowercase, letters and digits only. Used to match a cached
# download whose filename spells a version without its dots -- `sqlite-tools-
# win-x64-3530200.zip` against `3.53.2`.
proc ::machteld::LedgerCompact {s} {
    return [regsub -all {[^a-z0-9]} [string tolower $s] ""]
}

# `looksVersion` / `semanticVersion`: the first dash-separated part that is
# digits and dots. `cpython-3.12.13-windows-x86_64-none` -> `3.12.13`.
proc ::machteld::LedgerLooksVersion {s} {
    if {$s eq ""} { return 0 }
    if {![regexp {^[0-9.]+$} $s]} { return 0 }
    return [regexp {[0-9]} $s]
}
proc ::machteld::LedgerSemantic {s} {
    foreach part [split $s -] {
        if {[LedgerLooksVersion $part]} { return $part }
    }
    if {[LedgerLooksVersion $s]} { return $s }
    return ""
}

proc ::machteld::LedgerDedupSorted {items} {
    set out {}
    foreach s $items { if {$s ne ""} { lappend out $s } }
    return [lsort -ascii -unique $out]
}

# --- matching a cached download to a payload ---------------------------------
#
# A DOWNLOAD IS CLAIMED BY NAME OR BY VERSION, and the version rule is the
# fiddly one: `containsVersionToken` requires DIGIT BOUNDARIES on both sides, so
# `3.12` does not match `3.12.13` and `1.4` does not match `21.4`. Without that,
# every payload sharing a version prefix would claim the same archive.
proc ::machteld::LedgerMatcher {name version includename} {
    set nameToks {} ; set verToks {} ; set compactToks {}
    if {$version ne ""} {
        set lower [string tolower $version]
        lappend verToks $lower
        set compact [LedgerCompact $version]
        # "Useful" means: it exists, it is not just the version again, and it is
        # long enough not to match half the cache. Go's threshold is 4.
        if {$compact ne "" && $compact ne $lower && [string length $compact] >= 4} {
            lappend compactToks $compact
        }
    }
    if {$includename && $name ne ""} {
        lappend nameToks [string tolower $name] [LedgerCompact $name]
    }
    return [list [LedgerDedupSorted $nameToks] [LedgerDedupSorted $verToks] \
                 [LedgerDedupSorted $compactToks]]
}

proc ::machteld::LedgerMatcherEmpty {m} {
    lassign $m n v c
    return [expr {![llength $n] && ![llength $v] && ![llength $c]}]
}

proc ::machteld::LedgerMatches {m base} {
    lassign $m nameToks verToks compactToks
    set compactBase [LedgerCompact $base]
    foreach tok $nameToks {
        if {[string first $tok $base] >= 0 || [string first $tok $compactBase] >= 0} { return 1 }
    }
    foreach tok $verToks {
        if {[LedgerContainsVersion $base $tok]} { return 1 }
    }
    foreach tok $compactToks {
        if {[string first $tok $compactBase] >= 0} { return 1 }
    }
    return 0
}

# The token must appear with no digit before it, and after it neither a digit nor
# a dot-then-digit. `3.51.0` matches `sqlite-3.51.0.zip` and not `3.51.02`.
proc ::machteld::LedgerContainsVersion {base token} {
    if {$token eq ""} { return 0 }
    set len [string length $token]
    set start 0
    while {1} {
        set i [string first $token $base $start]
        if {$i < 0} { return 0 }
        set okStart [expr {$i <= 0 || ![string is digit -strict [string index $base [expr {$i - 1}]]]}]
        set end [expr {$i + $len}]
        set okEnd 1
        if {$end < [string length $base]} {
            set next [string index $base $end]
            if {[string is digit -strict $next]} {
                set okEnd 0
            } elseif {$next eq "." && $end + 1 < [string length $base]} {
                set okEnd [expr {![string is digit -strict [string index $base [expr {$end + 1}]]]}]
            }
        }
        if {$okStart && $okEnd} { return 1 }
        incr start
    }
}

# EVERY FILE UNDER cache/downloads, INCLUDING HIDDEN ONES. `glob -types f` does
# not return files carrying the hidden ATTRIBUTE -- not dot-names, the Windows
# attribute -- which is the same blind spot that hid 786 directories from the
# first version of `cdirs`. Two globs and a dedup is the whole fix, and a walk
# that silently skipped a cached archive would under-report the ledger.
proc ::machteld::LedgerWalkFiles {dir} {
    set out {}
    set seen {}
    foreach types {f {f hidden}} {
        foreach f [glob -nocomplain -directory $dir -types $types -- *] {
            set k [string tolower $f]
            if {[dict exists $seen $k]} continue
            dict set seen $k 1
            lappend out $f
        }
    }
    foreach types {d {d hidden}} {
        foreach d [glob -nocomplain -directory $dir -types $types -- *] {
            set k [string tolower $d]
            if {[dict exists $seen $k]} continue
            dict set seen $k 1
            lappend out {*}[LedgerWalkFiles $d]
        }
    }
    return $out
}

proc ::machteld::LedgerCachedDownloads {home name version includename} {
    set dir [file join $home cache downloads]
    if {![file exists $dir]} { return {} }
    set m [LedgerMatcher $name $version $includename]
    if {[LedgerMatcherEmpty $m]} { return {} }
    set files {}
    foreach f [LedgerWalkFiles $dir] {
        if {![LedgerMatches $m [string tolower [file tail $f]]]} continue
        # A file that cannot be hashed is DROPPED, not listed without a hash --
        # which is the opposite of what an entrypoint does. Go makes the same
        # distinction and it is the right one: an entrypoint is a fact about the
        # payload's shape, a cached download is a claim about a file's contents.
        if {[catch {hash file sha256 $f} sum]} continue
        lappend files [list [LedgerRelSlash $home $f] $sum [file size $f]]
    }
    return [lsort -ascii -index 0 $files]
}

# --- the pieces of a payload -------------------------------------------------

# The manifest entry that describes this payload, found through its ALIASES
# rather than by its own name: `winsdk` is a directory nobody names, and the only
# metadata about it in the workspace hangs off `signtool`. `preferVersion` picks
# the alias whose version matches when a payload has several -- two Go
# installations, two node, two tcltk.
proc ::machteld::LedgerSpecFor {m aliases {preferVersion ""}} {
    set first ""
    foreach alias $aliases {
        if {![dict exists $m tools $alias]} continue
        set spec [dict get $m tools $alias]
        if {$first eq ""} { set first $spec }
        if {$preferVersion ne "" && [FrontDictOr $spec version ""] eq $preferVersion} {
            return $spec
        }
    }
    return $first
}

# Metadata fills only what is still empty, so a value the payload already knows
# (a runtime's directory version) beats the manifest's.
proc ::machteld::LedgerApplySpec {pVar spec} {
    upvar 1 $pVar p
    if {$spec eq ""} return
    foreach k {version source license note} {
        if {[FrontDictOr $p $k ""] eq ""} {
            set v [FrontDictOr $spec $k ""]
            if {$v ne ""} { dict set p $k $v }
        }
    }
}

proc ::machteld::LedgerRestoreFor {spec} {
    if {$spec eq "" || [FrontDictOr $spec source ""] eq ""} { return {} }
    return [dict create method "manual download or package-manager install, then run z ledger refresh" \
                        source [dict get $spec source]]
}

# THE FILES THIS PAYLOAD IS ENTERED THROUGH: every alias's executable, plus any
# ABSOLUTE prepended argument -- an interpreter's script -- that lives under it.
# Relative `pre` entries are skipped, because they are arguments rather than
# files. One entry per PATH, carrying every alias that reaches it, so the two
# dozen names pointing at one `busybox`-style binary produce one row and not two
# dozen.
proc ::machteld::LedgerEntrypoints {home base targets} {
    set byPath {}
    foreach pair $targets {
        lassign $pair n t
        set cands {}
        if {[dict exists $t exe] && [FrontWithin $base [dict get $t exe]]} {
            lappend cands [dict get $t exe]
        }
        if {[dict exists $t pre]} {
            foreach pre [dict get $t pre] {
                if {[LedgerAbsolute $pre] && [FrontWithin $base $pre]} { lappend cands $pre }
            }
        }
        foreach c $cands { dict lappend byPath $c $n }
    }
    set out {}
    foreach p [lsort -ascii [dict keys $byPath]] {
        set item [dict create path [LedgerRelSlash $home $p] \
                              aliases [LedgerDedupSorted [dict get $byPath $p]]]
        # UNHASHABLE IS STILL AN ENTRYPOINT. The path is a fact about the
        # payload's shape and stays; only the claim about its contents is
        # dropped. `bytes` goes with `sha256` because Go takes both from the same
        # read -- reporting a size for a file it could not read would be a
        # different program's answer.
        if {![catch {hash file sha256 $p} sum]} {
            dict set item sha256 $sum
            dict set item bytes [file size $p]
        }
        lappend out $item
    }
    return $out
}

# Go's `filepath.IsAbs`: a drive-qualified path or a UNC share. A ROOTED path
# like `\tools\x.exe` is NOT absolute on Windows -- it names a place on whatever
# drive is current -- and Go says so.
proc ::machteld::LedgerAbsolute {p} {
    if {[regexp {^[A-Za-z]:[\\/]} $p]} { return 1 }
    if {[regexp {^[\\/][\\/]} $p]} { return 1 }
    return 0
}

# --- the three sources of payloads -------------------------------------------

proc ::machteld::LedgerToolPayloads {home m targets} {
    set root [file join $home t]
    if {![file isdirectory $root]} { return {} }
    set out {}
    foreach name [LedgerChildDirs $root] {
        set path [file join $root $name]
        set aliases [FrontAliasesUnder $path $targets]
        set spec [LedgerSpecFor $m $aliases]
        # A `t/<name>/` directory nobody aliases still gets its metadata if the
        # manifest happens to describe it under its own name.
        if {$spec eq "" && [dict exists $m tools $name]} { set spec [dict get $m tools $name] }
        set p [dict create id "tool:$name" kind tool name $name \
                           path [LedgerRelSlash $home $path] aliases $aliases \
                           entrypoints [LedgerEntrypoints $home $path $targets] \
                           cached [LedgerCachedDownloads $home $name [FrontDictOr $spec version ""] 1] \
                           restore [LedgerRestoreFor $spec]]
        LedgerApplySpec p $spec
        lappend out $p
    }
    return $out
}

proc ::machteld::LedgerRuntimePayloads {home m targets packages} {
    variable LEDGER_MSYS2_REL
    set out {}
    foreach info [FrontRuntimes $targets] {
        set name [dict get $info name]
        set version [FrontDictOr $info version ""]
        set aliases [FrontDictOr $info aliases {}]
        set spec [LedgerSpecFor $m $aliases [LedgerSemantic $version]]
        # THE DIRECTORY NAME IS NOT THE VERSION, and three payloads prove it.
        # `winsdk` and `zig` have no version in their path at all and take one
        # from an alias's manifest entry; `python` has
        # `cpython-3.12.13-windows-x86_64-none` and reports `3.12.13`; `msys2`
        # takes its version from an installed PACKAGE, below.
        if {$spec ne "" && [FrontDictOr $spec version ""] ne ""} {
            set version [dict get $spec version]
        } elseif {[set v [LedgerSemantic $version]] ne ""} {
            set version $v
        }
        if {$name eq "msys2"} {
            set v [LedgerPackageVersion $packages msys2-runtime]
            if {$v ne ""} { set version $v }
        }
        set id "runtime:$name"
        if {$version ne ""} { append id ":$version" }
        set p [dict create id $id kind runtime name $name version $version \
                           path [LedgerRelSlash $home [dict get $info path]] \
                           aliases $aliases \
                           cached [LedgerCachedDownloads $home $name $version 0] \
                           restore [LedgerRestoreFor $spec]]
        LedgerApplySpec p $spec
        if {$name eq "msys2"} {
            # MSYS2 IS COUNTED, NOT ENUMERATED. Two hundred aliases and a
            # thousand binaries would swamp the file and tell nobody anything;
            # what actually pins an MSYS2 install is the package list, which
            # lives in its own lock file and is named here instead.
            dict set p source "https://www.msys2.org/"
            dict set p license "Mixed; see MSYS2 package licenses and $LEDGER_MSYS2_REL"
            dict set p note "MSYS2/UCRT64 shell and native build payload; exact installed packages are locked separately"
            dict set p packagelock $LEDGER_MSYS2_REL
            dict set p aliascount [llength $aliases]
            dict set p entrypoints {}
            dict set p cached {}
        } else {
            dict set p entrypoints [LedgerEntrypoints $home [dict get $info path] $targets]
        }
        lappend out $p
    }
    return $out
}

# THE KERNEL'S OWN RUNTIMES: what z is BUILT with, as opposed to what the
# workspace offers. Nothing resolves them by name -- they are not on the tool
# surface at all -- and the ledger tracks them anyway, because a clone that
# cannot rebuild the kernel is missing something a clone that cannot run `rg` is
# not.
proc ::machteld::LedgerKernelPayloads {home} {
    set entryRel [dict create go {bin/go.exe bin/gofmt.exe} deno {deno.exe}]
    set out {}
    foreach name [dict keys $entryRel] {
        set base [file join $home $name]
        if {![file isdirectory $base]} continue
        foreach v [LedgerChildDirs $base] {
            if {[string index $v 0] eq "."} continue
            set dir [file join $base $v]
            set eps {}
            foreach rel [dict get $entryRel $name] {
                set exe [file join $dir $rel]
                if {![file exists $exe] || [file isdirectory $exe]} continue
                set item [dict create path [LedgerRelSlash $home $exe]]
                if {![catch {hash file sha256 $exe} sum]} {
                    dict set item sha256 $sum
                    dict set item bytes [file size $exe]
                }
                lappend eps $item
            }
            lappend out [dict create id "kernel:$name:$v" kind kernel name $name \
                             version $v path [LedgerRelSlash $home $dir] \
                             note "private z kernel runtime under .z; not on the public tool surface" \
                             entrypoints $eps restore {}]
        }
    }
    return $out
}

# CHILD DIRECTORIES, THE WAY Go's `ReadDir` + `IsDir()` SEES THEM: hidden ones
# included, dot-names included, and name-surrogate reparse points EXCLUDED --
# Go reports a junction or symlink as a link rather than a directory, so it never
# descends one here either. Two globs because `-types d` omits the hidden
# attribute; `.*` because `*` does not match a leading dot.
proc ::machteld::LedgerChildDirs {dir} {
    set seen {}
    foreach types {d {d hidden}} {
        foreach pat {* .*} {
            foreach d [glob -nocomplain -directory $dir -types $types -- $pat] {
                set n [file tail $d]
                if {$n eq "." || $n eq ".."} continue
                if {[file type $d] ne "directory"} continue
                dict set seen $n 1
            }
        }
    }
    return [lsort -ascii [dict keys $seen]]
}

# --- the msys2 package lock --------------------------------------------------
#
# The one part of the ledger that RUNS something. `pacman -Q` is the only
# authority on what is installed in an MSYS2 tree, and the guard is z's: the
# `pacman` we resolve must live under `r/msys2`, so a `pacman` from somewhere
# else on the machine cannot be asked about this workspace's payload.
proc ::machteld::LedgerMsys2Packages {home} {
    if {[catch {FrontResolve pacman} t]} { return {} }
    if {![dict exists $t exe]} { return {} }
    if {![FrontWithin [file join $home r msys2] [dict get $t exe]]} { return {} }
    set argv [list [dict get $t exe]]
    if {[dict exists $t pre]} { lappend argv {*}[dict get $t pre] }
    lappend argv -Q
    set opts {}
    if {[dict exists $t arg0]} { lappend opts -arg0 [dict get $t arg0] }
    set r [run -dir [dict get $t cwd] -env [dict get $t env] {*}$opts -- {*}$argv]
    if {[dict get $r exit] != 0} {
        Fail FRONT oserror "pacman exited [dict get $r exit]: [string trim [dict get $r err]]"
    }
    set text [string map [list \r\n \n \r \n] [dict get $r out]]
    set clean {}
    foreach line [split $text \n] {
        set line [string trim $line]
        if {$line ne ""} { lappend clean $line }
    }
    return [list 1 "[join [lsort -ascii $clean] \n]\n"]
}

proc ::machteld::LedgerPackageVersion {packages name} {
    if {![llength $packages]} { return "" }
    foreach line [split [lindex $packages 1] \n] {
        set f [split [string trim $line]]
        set f [lsearch -all -inline -not -exact $f ""]
        if {[llength $f] >= 2 && [lindex $f 0] eq $name} { return [lindex $f 1] }
    }
    return ""
}

# --- assembling the document -------------------------------------------------

proc ::machteld::LedgerBuild {home m targets packages} {
    variable LEDGER_PAYLOAD_REL ; variable LEDGER_MSYS2_REL
    set payloads {}
    lappend payloads {*}[LedgerRuntimePayloads $home $m $targets $packages]
    lappend payloads {*}[LedgerToolPayloads $home $m $targets]
    lappend payloads {*}[LedgerKernelPayloads $home]
    set keyed {}
    foreach p $payloads { lappend keyed [list [dict get $p id] $p] }
    set sorted {}
    foreach pair [lsort -ascii -index 0 $keyed] { lappend sorted [lindex $pair 1] }

    set doc {}
    lappend doc schema      {i 1}
    lappend doc generatedBy {s {z ledger refresh}}
    lappend doc policy [list s "git tracks z code/docs/manifests/bookkeeping under Z_HOME;\
 fetchable payload roots under t/, r/, go/, deno/, and cache/ are ignored"]
    lappend doc files [list o [list resolver {s manifest.json} \
                                   payloadLock [list s $LEDGER_PAYLOAD_REL] \
                                   msys2PackageLock [list s $LEDGER_MSYS2_REL]]]
    # `payloads` has no `omitempty`, so an empty workspace emits `null` rather
    # than `[]` -- a nil slice in Go, and the difference is visible in the file.
    if {![llength $sorted]} {
        lappend doc payloads {n {}}
    } else {
        set items {}
        foreach p $sorted { lappend items [list o [LedgerPayloadObj $p]] }
        lappend doc payloads [list a $items]
    }
    return [LedgerJson [list o $doc]]\n
}

# THE FIELD ORDER AND THE `omitempty` RULES ARE THE SPEC, so they are written out
# one line each rather than looped over a table: this proc IS `type ledgerPayload
# struct` transcribed, and a reader should be able to hold the two side by side.
proc ::machteld::LedgerPayloadObj {p} {
    set o {}
    lappend o id   [list s [dict get $p id]]
    lappend o kind [list s [dict get $p kind]]
    lappend o name [list s [dict get $p name]]
    if {[FrontDictOr $p version ""] ne ""} { lappend o version [list s [dict get $p version]] }
    lappend o path [list s [dict get $p path]]
    foreach k {source license note} {
        if {[FrontDictOr $p $k ""] ne ""} { lappend o $k [list s [dict get $p $k]] }
    }
    set aliases [FrontDictOr $p aliases {}]
    if {[llength $aliases]} {
        lappend o aliases [list a [lmap a $aliases {list s $a}]]
    }
    if {[FrontDictOr $p aliascount 0] != 0} {
        lappend o aliasCount [list i [dict get $p aliascount]]
    }
    set eps [FrontDictOr $p entrypoints {}]
    if {[llength $eps]} {
        set items {}
        foreach e $eps {
            set eo [list path [list s [dict get $e path]]]
            set ea [FrontDictOr $e aliases {}]
            if {[llength $ea]} { lappend eo aliases [list a [lmap a $ea {list s $a}]] }
            if {[FrontDictOr $e sha256 ""] ne ""} { lappend eo sha256 [list s [dict get $e sha256]] }
            if {[FrontDictOr $e bytes 0] != 0} { lappend eo bytes [list i [dict get $e bytes]] }
            lappend items [list o $eo]
        }
        lappend o entrypoints [list a $items]
    }
    set cached [FrontDictOr $p cached {}]
    if {[llength $cached]} {
        set items {}
        foreach c $cached {
            lassign $c path sum bytes
            # `ledgerFile` has NO omitempty on any field: a zero-byte cached
            # download still emits `"bytes": 0`.
            lappend items [list o [list path [list s $path] sha256 [list s $sum] \
                                        bytes [list i $bytes]]]
        }
        lappend o cachedDownloads [list a $items]
    }
    if {[FrontDictOr $p packagelock ""] ne ""} {
        lappend o packageLock [list s [dict get $p packagelock]]
    }
    # AND ALWAYS `restore`, EMPTY OR NOT. Its Go tag says `omitempty`, and
    # `omitempty` does nothing to a struct -- a struct is never "empty" to
    # `encoding/json`. So every payload without a source carries `"restore": {}`.
    # This is the single most visible Go-ism in the file and the easiest thing in
    # the world to leave out.
    set restore [FrontDictOr $p restore {}]
    set ro {}
    foreach k {method source note} {
        if {[dict exists $restore $k] && [dict get $restore $k] ne ""} {
            lappend ro $k [list s [dict get $restore $k]]
        }
    }
    lappend o restore [list o $ro]
    return $o
}

# The whole product: relative path -> the exact bytes that belong there.
proc ::machteld::LedgerFiles {} {
    variable FRONT_HOME ; variable LEDGER_PAYLOAD_REL ; variable LEDGER_MSYS2_REL
    FrontRoots
    set m [FrontManifest]
    set targets {}
    foreach n [FrontToolNames] {
        if {[catch {FrontResolve $n} t]} continue
        lappend targets [list $n $t]
    }
    set packages [LedgerMsys2Packages $FRONT_HOME]
    set files [dict create $LEDGER_PAYLOAD_REL \
                   [encoding convertto utf-8 [LedgerBuild $FRONT_HOME $m $targets $packages]]]
    # Absent pacman means no lock file at all, rather than an empty one: z writes
    # the key only when it has something to write, and `check` then never asks
    # about a file that was never meant to exist.
    if {[llength $packages]} {
        dict set files $LEDGER_MSYS2_REL [encoding convertto utf-8 [lindex $packages 1]]
    }
    return $files
}

proc ::machteld::LedgerRead {path} {
    set fh [open $path rb]
    set data [read $fh]
    close $fh
    return $data
}

# --- the command -------------------------------------------------------------

proc ::machteld::LedgerRun {sub} {
    variable FRONT_HOME
    if {$sub ni {refresh check}} {
        Fail FRONT usage "usage: front ledger refresh|check"
    }
    set files [LedgerFiles]
    set out {}
    if {$sub eq "refresh"} {
        foreach rel [lsort -ascii [dict keys $files]] {
            set path [file join $FRONT_HOME $rel]
            file mkdir [file dirname $path]
            set fh [open $path wb]
            puts -nonewline $fh [dict get $files $rel]
            close $fh
            lappend out "updated $rel"
        }
        return [join $out \n]
    }
    set ok 1
    foreach rel [lsort -ascii [dict keys $files]] {
        set path [file join $FRONT_HOME $rel]
        if {[catch {LedgerRead $path} got]} {
            set ok 0
            lappend out "missing $rel"
            continue
        }
        if {$got ne [dict get $files $rel]} {
            set ok 0
            lappend out "stale $rel"
        }
    }
    if {!$ok} {
        # THE ONE LINE THAT IS NOT z's -- see the header. A front door replacing
        # z does not tell you to go and run z.
        lappend out "run: mt ledger refresh"
        FrontStatus 1
        return [join $out \n]
    }
    return "ok: payload ledgers are current"
}
