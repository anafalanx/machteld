# tools/package.tcl -- append the machteld zipfs onto the wrapper exe.
#
# Runs under the STATIC tclsh90s (which has `zipfs lmkimg`). Stages the Tcl/Tk
# core script libraries + the machteld prelude (as machteld.tcl at the archive
# root), then appends the zip AFTER the wrapper's PE image (so any baked-in
# icon/manifest survives). The prelude is deliberately NOT named main.tcl: the C
# host sources it explicitly and leaves Tcl_Main's REPL/script handling intact.
#
#   tclsh90s package.tcl --tcltk <dir> --prelude <machteld.tcl> --wrapper <exe> --out <exe>

array set opt {--tcltk "" --prelude "" --wrapper "" --out ""}
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {[info exists opt($a)]} {
        incr i
        set opt($a) [lindex $argv $i]
    }
}
foreach k {--tcltk --prelude --wrapper --out} {
    if {$opt($k) eq ""} { error "package.tcl: missing $k" }
}
set TC   $opt(--tcltk)
set PREL $opt(--prelude)
set WRAP $opt(--wrapper)
set OUT  $opt(--out)

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

set stage [file join [file dirname $OUT] _pkg_stage]
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

# The machteld prelude at the archive root.
file copy -force $PREL [file join $stage machteld.tcl]

file delete -force $OUT
set entries [zip_entries $stage]
if {![llength $entries]} { error "package stage is empty: $stage" }
zipfs lmkimg $OUT $entries {} $WRAP
file delete -force $stage
puts "built [file nativename $OUT] ([file size $OUT] bytes)"
