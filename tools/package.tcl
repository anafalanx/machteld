# tools/package.tcl -- append the machteld zipfs onto the wrapper exe.
#
# Runs under the STATIC tclsh90s (which has `zipfs lmkimg`). Stages the Tcl/Tk
# core script libraries + the machteld prelude (as machteld.tcl at the archive
# root), then appends the zip AFTER the wrapper's PE image (so any baked-in
# icon/manifest survives). The prelude is deliberately NOT named main.tcl: the C
# host sources it explicitly and leaves Tcl_Main's REPL/script handling intact.
#
#   tclsh90s package.tcl --prefix <dir> --prelude <machteld.tcl> --wrapper <exe> \
#           --licenses <dir> --apache-license <file> --reference <dir> --out <exe> \
#           ?--embed-console <exe>? ?--embed-gui <exe>?

array set opt {--prefix "" --prelude "" --wrapper "" --licenses "" --apache-license "" --reference "" --out "" --embed-console "" --embed-gui ""}
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {![info exists opt($a)]} { error "package.tcl: unknown option $a" }
    if {$i + 1 >= [llength $argv]} { error "package.tcl: $a needs a value" }
    incr i
    set opt($a) [lindex $argv $i]
}
foreach k {--prefix --prelude --wrapper --licenses --apache-license --reference --out} {
    if {$opt($k) eq ""} { error "package.tcl: missing $k" }
}
set TC   $opt(--prefix)
set PREL $opt(--prelude)
set WRAP $opt(--wrapper)
set OUT  [file normalize $opt(--out)]

# package.tcl is deliberately not a release-file replacer. Its caller gives it
# an absent, invocation-owned candidate path; tools/build.ps1 performs the one
# native Windows operation that publishes that candidate as the requested
# release name. Tcl's `file rename -force` replacement path is multi-step on
# Windows and cannot provide this prior-output guarantee.
if {![regexp {^\.machteld-build-[0-9a-f]{32}\.exe$} [file tail $OUT]]} {
    error "package output is not an invocation-owned build candidate: $OUT"
}
if {![catch {file lstat $OUT ignored}]} {
    error "package output already exists (an absent candidate is required): $OUT"
}

proc children {directory} {
    set seen {}
    foreach item [concat \
            [glob -nocomplain -directory $directory *] \
            [glob -nocomplain -types hidden -directory $directory *]] {
        set tail [file tail $item]
        if {$tail in {. ..}} continue
        dict set seen $item 1
    }
    return [lsort [dict keys $seen]]
}

proc copy_tree {src dst} {
    file mkdir $dst
    foreach item [children $src] {
        set target [file join $dst [file tail $item]]
        if {[file isdirectory $item]} {
            copy_tree $item $target
        } else {
            file copy -force $item $target
        }
    }
}

proc zip_entries {root {rel ""}} {
    set out {}
    set directory [expr {$rel eq "" ? $root : [file join $root $rel]}]
    foreach item [children $directory] {
        set name [file tail $item]
        set zrel [expr {$rel eq "" ? $name : [file join $rel $name]}]
        if {[file isdirectory $item]} {
            lappend out {*}[zip_entries $root $zrel]
        } else {
            lappend out $item [string map {\\ /} $zrel]
        }
    }
    return $out
}

set outputDir [file dirname [file normalize $OUT]]
file mkdir $outputDir
# Claim a unique namespace beside the destination. The live marker keeps
# ownership of the derived staging-directory and candidate names. The candidate
# is opened exclusively rather than with `file tempfile`: on Windows, tempfile
# sets FILE_ATTRIBUTE_TEMPORARY and that attribute survives publication. We
# delete only these exact names and publish only after lmkimg has completed.
set stageClaim ""
set stageMarker ""
set stage ""
set outputCandidate ""
set candidateChannel ""
try {
    set stageMarker [file tempfile stageClaim [file join $outputDir .machteld-package-stage-]]
    set stage "${stageClaim}.d"
    if {[file exists $stage]} { error "package staging namespace already exists: $stage" }
    file mkdir $stage
    set outputCandidate "${stageClaim}.candidate"
    set candidateChannel [open $outputCandidate {WRONLY CREAT EXCL}]
    close $candidateChannel
    set candidateChannel ""

# Tcl core script library.
set tclLib ""
foreach candidate [list [file join $TC lib tcl9.0] [file join $TC tcl_library]] {
    if {[file isdirectory $candidate]} { set tclLib $candidate; break }
}
if {$tclLib eq ""} { error "tcl_library not found under dependency prefix: $TC" }
copy_tree $tclLib [file join $stage tcl_library]

# Tcl 9 installs script modules separately from the core script library. Core
# services such as clock require msgcat from this sibling tree; keeping its
# canonical `tcl9/9.0/*.tm` layout also lets tm.tcl discover the modules from
# [file dirname [info library]] after the archive is mounted.
set tclModules ""
foreach candidate [list [file join $TC lib tcl9] [file join $TC tcl9]] {
    if {[file isdirectory $candidate]} { set tclModules $candidate; break }
}
if {$tclModules eq ""} { error "Tcl module tree not found under dependency prefix: $TC" }
if {![file exists [file join $tclModules 9.0 msgcat-1.7.1.tm]]} {
    error "Tcl module tree has no msgcat 1.7.1: $tclModules"
}
copy_tree $tclModules [file join $stage tcl9]

# Tk core script library: prefer the copy inside the static wish; else tcllib.
set copiedTk 0
set wish [file join $TC bin wish90s.exe]
if {[file exists $wish] && ![catch {zipfs mount $wish Wt}]} {
    if {[file isdirectory //zipfs:/Wt/tk_library]} {
        copy_tree //zipfs:/Wt/tk_library [file join $stage tk_library]
        set copiedTk 1
    }
    catch {zipfs unmount Wt}
}
if {!$copiedTk} {
    foreach tkLib [list [file join $TC lib tk9.0] [file join $TC tk_library]] {
        if {[file isdirectory $tkLib]} {
            copy_tree $tkLib [file join $stage tk_library]
            set copiedTk 1
            break
        }
    }
}
if {!$copiedTk} { error "tk_library not found under dependency prefix: $TC" }

# The machteld prelude at the archive root.
file copy -force $PREL [file join $stage machteld.tcl]

# Tcl, Tk, and yyjson require their notices in every distribution. They are
# runtime payload, not distribution-only documentation, because standalone
# tools are distributions too.
if {![file isdirectory $opt(--licenses)]} {
    error "license notice directory not found: $opt(--licenses)"
}
foreach notice {Tcl-9.0.4.txt Tk-9.0.4.txt yyjson-0.12.0.txt} {
    if {![file isfile [file join $opt(--licenses) $notice]]} {
        error "required license notice not found: $notice"
    }
}
copy_tree $opt(--licenses) [file join $stage licenses]
if {![file isfile $opt(--apache-license)]} {
    error "Apache 2.0 license not found: $opt(--apache-license)"
}
file copy -force $opt(--apache-license) [file join $stage licenses Apache-2.0.txt]

# Reference is a required runtime payload.  The generator publishes it only
# after validating inventories, indexes and hashes; packaging still checks the
# discovery/inert-index boundary instead of silently accepting an empty tree.
if {![file isdirectory $opt(--reference)]} {
    error "reference pack directory not found: $opt(--reference)"
}
foreach relative {catalog.dict catalog.json search.dict manifest.sha256 schema.json START-HERE.md AGENTS.md} {
    if {![file isfile [file join $opt(--reference) $relative]]} {
        error "reference pack is incomplete: $relative"
    }
}
copy_tree $opt(--reference) [file join $stage reference]

# The basekits are console and GUI copies of the bare host, so `wrap` can make a
# standalone exe with no toolchain, no `sdx` and no Tcl install anywhere. It
# extracts the one matching the chosen subsystem and appends onto it.
#
# A wrapped tool does not carry these basekits recursively, so only the full
# machteld.exe can perform another wrap.
if {$opt(--embed-console) ne "" || $opt(--embed-gui) ne ""} {
    file mkdir [file join $stage basekit]
    if {$opt(--embed-console) ne ""} {
        file copy -force $opt(--embed-console) [file join $stage basekit console.exe]
    }
    if {$opt(--embed-gui) ne ""} {
        file copy -force $opt(--embed-gui) [file join $stage basekit gui.exe]
    }
}

    set entries [zip_entries $stage]
    if {![llength $entries]} { error "package stage is empty: $stage" }
    zipfs lmkimg $outputCandidate $entries {} $WRAP
    # Both paths are in outputDir. The destination was absent at entry and this
    # non-replacing rename also refuses a path that appears during packaging.
    file rename $outputCandidate $OUT
} finally {
    if {$candidateChannel ne ""} { catch {close $candidateChannel} }
    if {$outputCandidate ne ""} { catch {file delete -force $outputCandidate} }
    if {$stage ne ""} { catch {file delete -force $stage} }
    if {$stageMarker ne ""} { catch {close $stageMarker} }
    if {$stageClaim ne ""} { catch {file delete -force $stageClaim} }
}
puts "built [file nativename $OUT] ([file size $OUT] bytes)"
