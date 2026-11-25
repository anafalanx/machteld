package require machteld

# Exercise the same archive builder used by the CLI. Hook its final checks
# to make filesystem changes deterministic between capture and publication.
set work [file tempdir]
set project [file join $work app]
file mkdir $project
set spec [file join $project project.dict]
set destination [file join $work release.machteld]
proc bytes {path contents} {
    set f [open $path wb]
    try {puts -nonewline $f $contents} finally {close $f}
}
proc readBytes {path} {
    set f [open $path rb]
    try {return [read $f]} finally {close $f}
}
proc check {label test} {
    if {!$test} {error "FAIL archive inventory: $label"}
    puts "ok   $label"
}
proc manifest {files} {
    bytes $::spec [encoding convertto utf-8 [dict create schema 1 entry main.tcl files $files]]
}
proc build {} {::machteld::PackArchive $::spec -o $::destination}
proc preserved {label script} {
    set before [readBytes $::destination]
    check "$label refuses publication" [catch {uplevel 1 $script}]
    check "$label preserves prior output" [expr {[readBytes $::destination] eq $before}]
    check "$label removes temporary work" [expr {![llength [glob -nocomplain -directory $::work .machteld-pack-*]]}]
}
proc mutateDuringBuild {label change script} {
    set ::mutation $change
    rename ::machteld::_pack_verify_candidate ::machteld::_verifyInventoryNormally
    proc ::machteld::_pack_verify_candidate {args} {
        uplevel #0 $::mutation
        _verifyInventoryNormally {*}$args
    }
    try {preserved $label $script} finally {
        rename ::machteld::_pack_verify_candidate {}
        rename ::machteld::_verifyInventoryNormally ::machteld::_pack_verify_candidate
        unset ::mutation
    }
}
try {
    set entry [file join $project main.tcl]
    set asset [file join $project .theme]
    set selected {main.tcl .theme}
    bytes $entry "package require machteld\nputs OK\n"
    bytes $asset data
    bytes [file join $project secret.txt] private
    manifest $selected
    build
    zipfs mount $destination packed
    try {
        set root //zipfs:/packed
        set inv [encoding convertfrom utf-8 [readBytes [file join $root machteld-inventory.dict]]]
        check "only selected files and the generated inventory are packaged" [expr {
            [lsort [dict keys [dict get $inv files]]] eq [lsort $selected] && ![file exists [file join $root secret.txt]]}]
        check "hidden bytes and exact SHA-256 are recorded" [expr {
            [dict get $inv files .theme sha256] eq [hash file sha256 $asset] && [readBytes [file join $root .theme]] eq "data"}]
    } finally {zipfs unmount packed}
    foreach {label files} {
        duplicate {main.tcl main.tcl} case-collision {main.tcl MAIN.TCL} traversal {main.tcl ../secret.txt}
        absent {main.tcl missing} missing-entry {.theme}
    } {
        manifest $files
        preserved $label build
    }
    bytes $spec {schema 1 entry main.tcl files {main.tcl} files {main.tcl}}
    preserved {duplicate manifest keys} build
    manifest $selected
    mutateDuringBuild {mutated asset} {bytes $::asset changed} build
    bytes $asset data
    mutateDuringBuild {replacement with identical bytes} {
        file rename $::asset $::asset.previous
        bytes $::asset data
    } build
    file delete $asset.previous
    mutateDuringBuild {modified manifest} {manifest {main.tcl}} build
    manifest $selected
    mutateDuringBuild {whole-directory additions} {bytes [file join $::project appeared] new} \
        {::machteld::PackArchive $::project -o $::destination}

    set target [file join $work outside]
    file mkdir $target
    bytes [file join $target outside.txt] unrelated
    set junction [file join $project linked]
    if {![catch {exec cmd /d /c mklink /J [file nativename $junction] [file nativename $target]}]} {
        try {
            build
            manifest {main.tcl linked/outside.txt}
            preserved {selected junction} build
        } finally {file delete $junction}
    }
    manifest $selected
    set held [open $destination rb]
    try {preserved {locked destination} build} finally {close $held}

    # Reuse the original package inventory's directory-scan regression.
    set bulk [file join $work bulk]
    file mkdir $bulk
    set names {}
    for {set i 0} {$i < 128} {incr i} {
        set name [format asset-%03d.bin $i]
        bytes [file join $bulk $name] x
        lappend names $name
    }
    set scans 0
    rename ::machteld::_children ::machteld::_scanChildren
    proc ::machteld::_children {path} {incr ::scans; _scanChildren $path}
    try {
        set first [::machteld::_pack_inventory $bulk $names [dict get [canon $bulk] path]]
        set next [::machteld::_pack_inventory $bulk $names [dict get [canon $bulk] path]]
        check "each 128-file inventory enumerates its shared directory once" [expr {
            $scans == 2 && [dict size $first] == 128 && $next eq $first}]
    } finally {rename ::machteld::_children {}; rename ::machteld::_scanChildren ::machteld::_children}
} finally {file delete -force -- $work}
