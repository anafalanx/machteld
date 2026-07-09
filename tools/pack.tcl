# tools/pack.tcl -- package a pure-Tcl/Tk tool into a standalone exe by appending
# its VFS (plus the Tcl/Tk script libraries, and optionally the machteld prelude)
# onto a prebuilt machteld basekit. ZERO compiler -- pure zipfs (the els/starpack
# overlay mechanism). This is the generalized form of package.tcl: package.tcl
# builds machteld itself; pack.tcl builds an arbitrary tool.
#
#   tclsh90s pack.tcl --tcltk <dir> --app <tooldir> --basekit <exe> --out <exe> [--prelude <machteld.tcl>]
#
# <tooldir> must contain main.tcl at its root -- TclZipfs_AppHook auto-runs a
# main.tcl in the appended archive, which is exactly the app entry point.
#
# Signing: wrap onto an UNSIGNED basekit and sign the RESULT (append-then-sign).
# The appended overlay is inside the Authenticode hash, so the tool's code is
# covered by the signature.

array set opt {--tcltk "" --app "" --basekit "" --out "" --prelude ""}
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {[info exists opt($a)]} { incr i; set opt($a) [lindex $argv $i] }
}
foreach k {--tcltk --app --basekit --out} {
    if {$opt($k) eq ""} { error "pack.tcl: missing $k" }
}
set TC   $opt(--tcltk)
set APP  $opt(--app)
set BASE $opt(--basekit)
set OUT  $opt(--out)
set PREL $opt(--prelude)
if {![file exists [file join $APP main.tcl]]} {
    error "pack.tcl: $APP has no main.tcl (the tool entry)"
}
if {![file exists $BASE]} { error "pack.tcl: basekit not found: $BASE" }

proc copy_tree {src dst} {
    file mkdir $dst
    foreach item [glob -nocomplain [file join $src *]] {
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
    foreach item [glob -nocomplain [file join $root $rel *]] {
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

set stage [file join [file dirname $OUT] _pack_stage]
file delete -force $stage
file mkdir $stage

# Tcl core script library.
set tclLib [file join $TC tcllib tcl_library]
if {![file isdirectory $tclLib]} { error "tcl_library not found: $tclLib" }
copy_tree $tclLib [file join $stage tcl_library]

# Tk core script library: prefer the copy inside the static wish; else tcllib.
set copiedTk 0
set wish [file join $TC tcl9s bin wish90s.exe]
if {[file exists $wish] && ![catch {zipfs mount $wish Wt}]} {
    if {[file isdirectory //zipfs:/Wt/tk_library]} {
        copy_tree //zipfs:/Wt/tk_library [file join $stage tk_library]
        set copiedTk 1
    }
    catch {zipfs unmount Wt}
}
if {!$copiedTk} {
    set tkLib [file join $TC tcllib tk_library]
    if {[file isdirectory $tkLib]} {
        copy_tree $tkLib [file join $stage tk_library]
        set copiedTk 1
    }
}
if {!$copiedTk} { error "tk_library not found in wish90s.exe or $TC/tcllib" }

# Optional machteld prelude, so the tool inherits the run/store/pty palette.
if {$PREL ne ""} {
    if {![file exists $PREL]} { error "pack.tcl: prelude not found: $PREL" }
    file copy -force $PREL [file join $stage machteld.tcl]
}

# The tool's own VFS at the archive root (main.tcl lands at root -> auto-run).
copy_tree $APP $stage

file delete -force $OUT
set entries [zip_entries $stage]
if {![llength $entries]} { error "pack.tcl: stage is empty" }
zipfs lmkimg $OUT $entries {} $BASE
file delete -force $stage
puts "packed [file nativename $OUT] ([file size $OUT] bytes) -- now sign it (append-then-sign)"
