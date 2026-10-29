# Explicit example build only: never part of the Machteld runtime build.
package require machteld
namespace eval ::extension_example {
    variable here [file dirname [file normalize [info script]]]
}

proc ::extension_example::compile {output msys prefix} {
    variable here
    set compiler [file join [file normalize $msys] ucrt64 bin gcc.exe]
    set include [file join [file normalize $prefix] include]
    set stubs [file join [file normalize $prefix] lib libtclstub.a]
    if {![file isfile $stubs]} { set stubs [file join [file normalize $prefix] lib libtclstub90.a] }
    foreach path [list $compiler [file join $include tcl.h] $stubs] {
        if {![file isfile $path]} { error "missing explicit example build input: $path" }
    }
    if {[file exists $output]} { error "refusing to overwrite example DLL: $output" }
    set savedPath [expr {[info exists ::env(PATH)] ? $::env(PATH) : {}}]
    set hadPath [info exists ::env(PATH)]
    try {
        # GCC helper programs/DLLs come from this toolchain, not a different
        # compiler earlier on the caller's PATH. Restore the caller afterwards.
        set ::env(PATH) "[file nativename [file dirname $compiler]];[file nativename [file join $::env(SystemRoot) System32]];$::env(SystemRoot)"
        exec $compiler -shared -static-libgcc -std=c17 -O2 -Wall -Wextra -Werror \
            -DUSE_TCL_STUBS -I$include [file join $here examplemath.c] $stubs -o $output 2>@1
    } finally {
        if {$hadPath} { set ::env(PATH) $savedPath } else { unset ::env(PATH) }
    }
}

proc ::extension_example::build {stage msys prefix {host --console}} {
    variable here
    if {$host ni {--console --gui}} { error "host must be --console or --gui" }
    set stage [file normalize $stage]
    if {[file exists $stage]} { error "example stage must not already exist: $stage" }
    set application [file join $stage app]
    set bundle [file join $stage bundle]
    file mkdir $application $bundle
    file copy [file join $here main.tcl] [file join $application main.tcl]
    compile [file join $bundle examplemath.dll] $msys $prefix
    file copy [file join $here .. .. LICENSE] [file join $bundle LICENSE-examplemath.txt]
    file copy [file join $here NOTICE.txt] [file join $bundle NOTICE-examplemath.txt]
    ::machteld::wrap $application -o [file join $bundle extension-example.exe] \
        --manifest [file join $here app.dict] $host
    # This is the complete deployment inventory, separate from the executable's
    # embedded app-info inventory. The inventory does not hash itself.
    set files {}
    foreach name {extension-example.exe examplemath.dll LICENSE-examplemath.txt NOTICE-examplemath.txt} {
        set path [file join $bundle $name]
        dict set files $name [dict create size [file size $path] sha256 [::machteld::hash file sha256 $path]]
    }
    set channel [open [file join $bundle ship.dict] {WRONLY CREAT EXCL}]
    try {
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel [dict create schema 1 files $files]
    } finally { close $channel }
    return $bundle
}

if {[file normalize [info script]] eq [file normalize $argv0]} {
    if {[llength $argv] ni {3 4}} {
        puts stderr "usage: build.tcl new-stage-directory msys2-root tcl-prefix ?--console|--gui?"
        exit 2
    }
    puts [::extension_example::build {*}$argv]
}
