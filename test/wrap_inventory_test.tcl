# Explicit wrapping selection and publication preservation. No GUI is opened.
package require machteld

set ROOT [file join $env(TEMP) machteld-wrap-inventory-[pid]-[binary encode hex [hash random 8]]]
file mkdir $ROOT
set rootKey [::machteld::_canon_key [canon $ROOT]]
set fails 0; set checks 0
proc check {name condition} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc write_bytes {path bytes} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    try { puts -nonewline $channel $bytes } finally { close $channel }
}
proc read_bytes {path} {
    set channel [open $path rb]
    try { return [read $channel] } finally { close $channel }
}
proc expect_code {label script expected} {
    set caught [catch {uplevel 1 $script} message options]
    set code [expr {$caught && [dict exists $options -errorcode] ? [dict get $options -errorcode] : {}}]
    check $label [expr {$caught && $code eq [list MACHTELD WRAP $expected]}]
    if {!$caught || $code ne [list MACHTELD WRAP $expected]} { puts "     observed: $code $message" }
}
proc no_work {} { expr {![llength [glob -nocomplain -directory $::ROOT .machteld-wrap-*]]} }
proc manifest {files {extra {}}} {
    write_bytes $::MANIFEST [encoding convertto utf-8 [dict merge [dict create schema 1 files $files] $extra]]
}
proc preserved {label} {
    check "$label preserves the existing destination" [expr {[read_bytes $::OUT] eq "EXISTING-DESTINATION"}]
    check "$label cleans invocation work" [no_work]
}
set junction ""; set rootAlias ""; set unselectedLink ""
try {
    set APP [file join $ROOT source-tree]
    set MANIFEST [file join $ROOT payload.dict]
    set OUT [file join $ROOT tool.exe]
    set main "package require machteld\nputs INVENTORY-ENTRY\n"
    write_bytes [file join $APP main.tcl] $main
    write_bytes [file join $APP assets .theme] HIDDEN-THEME
    write_bytes [file join $APP assets windows-hidden.bin] [binary format H* 0001ff80]
    file attributes [file join $APP assets windows-hidden.bin] -hidden 1
    write_bytes [file join $APP .keep] DOT-ASSET
    write_bytes [file join $APP .git config] REPOSITORY-SECRET
    write_bytes [file join $APP secret-fixture.env] PRIVATE-UNSELECTED
    set selected {main.tcl assets/.theme assets/windows-hidden.bin .keep}
    manifest $selected
    write_bytes $OUT EXISTING-DESTINATION

    set plan [wrap $APP --manifest $MANIFEST -o $OUT --plan]
    check "plan lists only explicit assets in deterministic order" [expr {
        [dict keys [dict get $plan files]] eq [lsort $selected]}]
    check "plan names selected entry, subsystem and docs policy" [expr {
        [dict get $plan schema] == 1 && [dict get $plan entry] eq "app/main.tcl" &&
        [dict get $plan host] eq "console" && ![dict get $plan with_docs]}]
    check "default plan separates runtime authorship from absent app metadata" [expr {
        [dict get $plan metadata] eq {} && [dict get $plan runtime] eq
        [dict create name Machteld version [version] author {Vincent Vercauteren}]}]
    dict for {name facts} [dict get $plan files] {
        check "plan has exact size/hash for $name" [expr {
            [dict get $facts bytes] == [file size [file join $APP {*}[split $name /]]] &&
            [dict get $facts sha256] eq [hash file sha256 [file join $APP {*}[split $name /]]]}]
    }
    preserved plan
    check "plan does not contain a build-machine path" [expr {![string match *$ROOT* $plan]}]
    check "input list order does not change plan" [expr {
        [manifest [lreverse $selected]; wrap $APP --manifest $MANIFEST -o $OUT --plan] eq $plan}]
    manifest $selected
    set bomBytes [binary format a*a* [binary format H* efbbbf] [read_bytes $MANIFEST]]
    write_bytes $MANIFEST $bomBytes
    check "UTF-8 BOM manifest produces the same selected plan" [expr {
        [wrap $APP --manifest $MANIFEST -o $OUT --plan] eq $plan}]
    check "UTF-8 BOM remains covered by the raw manifest snapshot hash" [expr {
        [dict get [::machteld::_wrap_manifest $MANIFEST] snapshot sha256] eq [hash sum sha256 $bomBytes]}]
    manifest $selected
    set before [read_bytes $OUT]
    expect_code "plan still requires an output identity" {wrap $APP --manifest $MANIFEST --plan} usage
    expect_code "manifest is directory-only" {wrap [file join $APP main.tcl] --manifest $MANIFEST -o $OUT --plan} usage
    expect_code "missing manifest is rejected" {wrap $APP --manifest [file join $ROOT missing.dict] -o $OUT --plan} notfound
    set manifestHash [hash file sha256 $MANIFEST]
    expect_code "output cannot overwrite the manifest itself" {wrap $APP --manifest $MANIFEST -o $MANIFEST --plan} badvalue
    set manifestAlias [file join $ROOT manifest-hardlink.exe]
    if {![catch {exec cmd /c mklink /H [file nativename $manifestAlias] [file nativename $MANIFEST]}]} {
        expect_code "output cannot alias the manifest through a hardlink" {wrap $APP --manifest $MANIFEST -o $manifestAlias --plan} badvalue
        file delete $manifestAlias
    } else { puts "SKIP manifest hardlink fixture (creation unavailable)" }
    check "manifest output-identity refusals preserve configuration bytes" [expr {[hash file sha256 $MANIFEST] eq $manifestHash}]

    foreach {label data} [list \
            "unknown schema" {schema 2 files main.tcl} \
            "unknown key" {schema 1 files main.tcl surprise yes} \
            "duplicate key" {schema 1 schema 1 files main.tcl} \
            "missing files" {schema 1} \
            "empty files" {schema 1 files {}} \
            "invalid files list" "schema 1 files \{" \
            "unknown metadata key" {schema 1 files main.tcl metadata {name Demo version 1 surprise yes}} \
            "duplicate metadata key" {schema 1 files main.tcl metadata {name Demo name Again version 1}} \
            "missing metadata name" {schema 1 files main.tcl metadata {version 1}} \
            "missing metadata version" {schema 1 files main.tcl metadata {name Demo}}] {
        write_bytes $MANIFEST $data
        expect_code "manifest rejects $label" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    }
    write_bytes $MANIFEST [binary format H* ff]
    expect_code "manifest rejects malformed UTF-8" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    write_bytes $MANIFEST [string repeat x 1048577]
    expect_code "manifest size is bounded" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    manifest [lrepeat 10001 main.tcl]
    expect_code "manifest selected-file count is bounded" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    set ::manifestExecuted 0
    write_bytes $MANIFEST {schema 1 files {[set ::manifestExecuted 1]}}
    catch {wrap $APP --manifest $MANIFEST -o $OUT --plan}
    check "manifest is parsed as inert data, never executed" [expr {!$::manifestExecuted}]
    unset ::manifestExecuted

    foreach name {../secret-fixture.env assets/../main.tcl /main.tcl C:main.tcl {assets//.theme} {./main.tcl} {main.tcl:stream} {main.tcl.} {main.tcl } {assets/*} NUL.txt} {
        manifest [list main.tcl $name]
        expect_code "selection rejects unsafe path $name" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    }
    manifest {main.tcl missing.bin}
    expect_code "selection rejects a missing asset" {wrap $APP --manifest $MANIFEST -o $OUT --plan} notfound
    manifest {main.tcl assets}
    expect_code "selection requires regular files, not directory expansion" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    foreach names {{main.tcl main.tcl} {main.tcl MAIN.TCL} {assets/.theme}} {
        manifest $names
        expect_code "selection rejects duplicates/case aliases or omitted entry: $names" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
    }
    manifest {MAIN.TCL assets/.theme}
    set actualCase [wrap $APP --manifest $MANIFEST -o $OUT --entry MAIN.TCL --plan]
    check "caller case aliases resolve to exact on-disk archive spelling" [expr {
        [dict get $actualCase entry] eq "app/main.tcl" && [dict exists $actualCase files main.tcl]}]
    check "single-file input resolves exact on-disk spelling too" [expr {
        [dict get [wrap [file join $APP MAIN.TCL] -o $OUT --plan] entry] eq "app/main.tcl"}]
    manifest $selected
    preserved "invalid selections"

    # Junctions require no elevation on local NTFS. They are unselected first,
    # then selected, and finally used as a lexical ancestor of the input root.
    set target [file join $ROOT outside]
    write_bytes [file join $target main.tcl] $main
    set junction [file join $APP redirect]
    if {![catch {exec cmd /c mklink /J [file nativename $junction] [file nativename $target]}]} {
        check "unselected junction does not expand an explicit payload" [expr {
            [dict get [wrap $APP --manifest $MANIFEST -o $OUT --plan] files] eq [dict get $plan files]}]
        manifest {main.tcl redirect/main.tcl}
        expect_code "selection rejects a junction ancestor" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
        expect_code "whole-tree fallback rejects a junction" {wrap $APP -o $OUT --plan} badvalue
        expect_code "single-file input rejects a lexical junction ancestor" {wrap [file join $junction main.tcl] -o $OUT --plan} badvalue
        file delete $junction
        set junction ""
    } else { puts "SKIP junction fixture (creation unavailable)"; set junction "" }
    manifest $selected
    set rootAlias [file join $ROOT root-alias]
    if {![catch {exec cmd /c mklink /J [file nativename $rootAlias] [file nativename $ROOT]}]} {
        expect_code "input root rejects a lexical parent junction" {wrap [file join $rootAlias source-tree] --manifest $MANIFEST -o $OUT --plan} badvalue
        file delete $rootAlias
        set rootAlias ""
    } else { puts "SKIP parent junction fixture (creation unavailable)"; set rootAlias "" }
    set unselectedLink [file join $APP assets private-link.txt]
    if {![catch {exec cmd /c mklink [file nativename $unselectedLink] [file nativename [file join $target main.tcl]]}]} {
        check "an unselected sibling symlink is neither followed nor packaged" [expr {
            [dict get [wrap $APP --manifest $MANIFEST -o $OUT --plan] files] eq [dict get $plan files]}]
        manifest [concat $selected assets/private-link.txt]
        expect_code "an explicitly selected file symlink is refused" {wrap $APP --manifest $MANIFEST -o $OUT --plan} badvalue
        file delete $unselectedLink
        set unselectedLink ""
        manifest $selected
    } else { puts "SKIP file symlink fixture (creation unavailable)"; set unselectedLink "" }

    set bulk [file join $ROOT bulk]
    set bulkNames {}
    for {set i 0} {$i < 128} {incr i} {
        set name [format asset-%03d.bin $i]
        write_bytes [file join $bulk $name] x
        lappend bulkNames $name
    }
    set ::childScans 0; set ::linkScans 0
    rename ::machteld::_children ::machteld::_children_live
    rename ::machteld::links ::machteld::links_live
    proc ::machteld::_children {directory} { incr ::childScans; _children_live $directory }
    proc ::machteld::links {args} { incr ::linkScans; links_live {*}$args }
    try {
        set bulkInventory [::machteld::_wrap_inventory $bulk $bulkNames [dict get [canon $bulk] path]]
        check "same-directory selection enumerates filenames only once" [expr {$::childScans == 1 && [dict size $bulkInventory] == 128}]
        check "same-directory selection does not rescan links per file" [expr {$::linkScans < 16}]
        set beforeScans $::linkScans
        set bulkAgain [::machteld::_wrap_inventory $bulk $bulkNames [dict get [canon $bulk] path]]
        check "next inventory pass performs fresh directory/link inspections" [expr {
            $::childScans == 2 && $::linkScans == 2 * $beforeScans && $bulkAgain eq $bulkInventory}]
    } finally {
        rename ::machteld::_children {}
        rename ::machteld::_children_live ::machteld::_children
        rename ::machteld::links {}
        rename ::machteld::links_live ::machteld::links
        unset ::childScans ::linkScans
    }
    set sourceFacts [canon $APP]
    set sourceInventory [::machteld::_wrap_inventory $APP $selected [dict get $sourceFacts path]]
    write_bytes [file join $APP secret-fixture.env] UNSELECTED-CHANGED
    check "explicit selection ignores changes to unrelated files" [expr {![catch {
        ::machteld::_wrap_verify_inputs $APP [::machteld::_canon_key $sourceFacts] $selected $sourceInventory 0 {} {}
    }]}]
    set iconProbe [file join $ROOT icon-input.bin]
    write_bytes $iconProbe ORIGINAL-ICON-BYTES
    set iconSnapshot [::machteld::_wrap_snapshot $iconProbe]
    write_bytes $iconProbe MODIFIED-ICON-BYTES
    expect_code "final input validation detects changed external icon bytes" {
        ::machteld::_wrap_verify_inputs $APP [::machteld::_canon_key $sourceFacts] $selected $sourceInventory 0 {} $iconSnapshot
    } badvalue
    preserved "icon input mutation refusal"

    # Four images exercise explicit selection across both subsystems and docs
    # policies. Inspect GUI archives only; do not start a GUI process.
    set good ""
    foreach mode {console gui} {
        foreach withDocs {0 1} {
            set image [file join $ROOT selected-$mode-$withDocs.exe]
            set flags [list --$mode]
            if {$withDocs} { lappend flags --with-docs }
            set expected [wrap $APP --manifest $MANIFEST -o $image {*}$flags --plan]
            wrap $APP --manifest $MANIFEST -o $image {*}$flags
            set mount inventory-[pid]-$mode-$withDocs
            zipfs mount $image $mount
            try {
                set payload //zipfs:/$mount
                set embedded [string trimright [encoding convertfrom utf-8 [read_bytes [file join $payload app-info.dict]]] \n]
                check "$mode docs=$withDocs embeds exactly its preview record" [expr {$embedded eq $expected}]
                set paths [dict keys [::machteld::_wrap_archive_inventory [file join $payload app]]]
                check "$mode docs=$withDocs excludes unrelated repository and secret files" [expr {[lsort $paths] eq [lsort $selected]}]
                check "$mode docs=$withDocs retains selected hidden assets" [expr {
                    [read_bytes [file join $payload app assets .theme]] eq "HIDDEN-THEME" &&
                    [read_bytes [file join $payload app assets windows-hidden.bin]] eq [binary format H* 0001ff80]}]
                check "$mode docs=$withDocs has exactly the requested reference policy" [expr {
                    [file isdirectory [file join $payload reference]] == $withDocs}]
            } finally { zipfs unmount $mount }
            if {$mode eq "console" && !$withDocs} { set good $image }
        }
    }
    set launched [run -timeout 5s -- $good]
    check "explicitly selected console image starts correctly" [expr {
        [dict get $launched status] eq "ok" && [string trim [dict get $launched out]] eq "INVENTORY-ENTRY"}]
    check "whole-tree fallback still preserves all regular assets" [expr {
        [dict exists [wrap $APP -o $OUT --plan] files .git/config] &&
        [dict exists [wrap $APP -o $OUT --plan] files secret-fixture.env]}]

    rename ::machteld::_wrap_copy_assets ::machteld::_wrap_copy_assets_live
    proc ::machteld::_wrap_copy_assets {records destination} {
        _wrap_copy_assets_live $records $destination
        write_bytes [file join $::APP assets .theme] MUTATED-SOURCE
    }
    try {
        expect_code "changed selected bytes abort publication" {wrap $APP --manifest $MANIFEST -o $OUT} badvalue
        preserved "selected input mutation"
    } finally {
        rename ::machteld::_wrap_copy_assets {}
        rename ::machteld::_wrap_copy_assets_live ::machteld::_wrap_copy_assets
        write_bytes [file join $APP assets .theme] HIDDEN-THEME
    }
    rename ::machteld::_wrap_copy_assets ::machteld::_wrap_copy_assets_live
    proc ::machteld::_wrap_copy_assets {records destination} {
        _wrap_copy_assets_live $records $destination
        write_bytes [file join $destination assets .theme] CORRUPTED-STAGING
    }
    try {
        expect_code "changed staged asset bytes abort publication" {wrap $APP --manifest $MANIFEST -o $OUT} badvalue
        preserved "staged asset mutation"
    } finally {
        rename ::machteld::_wrap_copy_assets {}
        rename ::machteld::_wrap_copy_assets_live ::machteld::_wrap_copy_assets
    }
    rename ::machteld::_wrap_copy_assets ::machteld::_wrap_copy_assets_live
    proc ::machteld::_wrap_copy_assets {records destination} {
        _wrap_copy_assets_live $records $destination
        set old [file join $::APP assets .theme]
        file rename $old $old.saved
        write_bytes $old HIDDEN-THEME
    }
    try {
        expect_code "same-byte input replacement still changes identity" {wrap $APP --manifest $MANIFEST -o $OUT} badvalue
        preserved "selected input replacement"
    } finally {
        rename ::machteld::_wrap_copy_assets {}
        rename ::machteld::_wrap_copy_assets_live ::machteld::_wrap_copy_assets
        file delete [file join $APP assets .theme]
        file rename [file join $APP assets .theme.saved] [file join $APP assets .theme]
    }
    rename ::machteld::_write_launcher ::machteld::_write_launcher_live
    proc ::machteld::_write_launcher {path entry} {
        _write_launcher_live $path $entry
        write_bytes $::MANIFEST {schema 1 files main.tcl}
    }
    try {
        expect_code "changed manifest bytes abort publication" {wrap $APP --manifest $MANIFEST -o $OUT} badvalue
        preserved "manifest mutation"
    } finally {
        rename ::machteld::_write_launcher {}
        rename ::machteld::_write_launcher_live ::machteld::_write_launcher
        manifest $selected
    }
    rename ::machteld::_wrap_copy_assets ::machteld::_wrap_copy_assets_live
    proc ::machteld::_wrap_copy_assets {records destination} {
        _wrap_copy_assets_live $records $destination
        write_bytes [file join $::APP appeared.bin] NEW-ASSET
    }
    try {
        expect_code "whole-tree additions abort publication" {wrap $APP -o $OUT} badvalue
        preserved "whole-tree addition"
    } finally {
        rename ::machteld::_wrap_copy_assets {}
        rename ::machteld::_wrap_copy_assets_live ::machteld::_wrap_copy_assets
        file delete [file join $APP appeared.bin]
    }
    rename ::machteld::_write_launcher ::machteld::_write_launcher_live
    proc ::machteld::_write_launcher {path entry} { error "test: interrupted packaging" }
    try {
        expect_code "interrupted packaging aborts publication" {wrap $APP --manifest $MANIFEST -o $OUT} oserror
        preserved "interrupted packaging"
    } finally {
        rename ::machteld::_write_launcher {}
        rename ::machteld::_write_launcher_live ::machteld::_write_launcher
    }

    # Terminating the process cannot run Tcl finally. A completed staging
    # directory may remain, but the preexisting destination must be untouched.
    set interruptedScript [file join $ROOT terminate-wrap.tcl]
    write_bytes $interruptedScript {
package require machteld
lassign $argv input manifest output marker
rename ::machteld::_write_launcher ::machteld::_write_launcher_live
proc ::machteld::_write_launcher {path entry} {
    set channel [open $::marker w]
    puts $channel [file dirname [file dirname $path]]
    close $channel
    vwait ::never_continue_packaging
}
wrap $input --manifest $manifest -o $output
}
    set marker [file join $ROOT termination-ready.txt]
    set command [list [info nameofexecutable]]
    # Source overlays are an explicit development-only caller choice. Ordinary
    # packaged runs exercise the tested executable's own embedded wrapper.
    if {[info exists ::wrapInventoryOverlay]} { lappend command $::wrapInventoryOverlay }
    lappend command $interruptedScript $APP $MANIFEST $OUT $marker
    set wrapping [child start -- {*}$command]
    try {
        set deadline [expr {[clock milliseconds] + 90000}]
        while {![file exists $marker] && [clock milliseconds] < $deadline} { after 20 }
        check "external interruption fixture reaches pre-publication staging" [file exists $marker]
        if {![file exists $marker]} { error "external interruption fixture failed to reach its marker" }
        set orphan [string trim [read_bytes $marker]]
        set orphanFacts [canon $orphan]
        child close $wrapping
        set wrapping ""
        check "external process termination preserves the existing output" [expr {[read_bytes $OUT] eq "EXISTING-DESTINATION"}]
        check "external process termination leaves only uncommitted staging" [expr {
            [file isdirectory $orphan] && ![file exists [file join $orphan candidate.exe]]}]
        if {[file dirname [file normalize $orphan]] ne [file normalize $ROOT] ||
                ![regexp {^\.machteld-wrap-[0-9a-f]{32}$} [file tail $orphan]] ||
                [::machteld::_canon_key [canon $orphan]] ne [::machteld::_canon_key $orphanFacts]} {
            error "refusing unexpected interrupted-test cleanup path"
        }
        file delete -force $orphan
        check "interrupted-test orphan cleanup is bounded to its own work directory" [no_work]
    } finally { if {$wrapping ne ""} { child close $wrapping } }

    # Replace the completed image with a valid but differently selected archive.
    # The candidate validator must inspect bytes, not just ZIP readability.
    rename ::zipfs ::zipfs_live
    proc ::zipfs {subcommand args} {
        set result [::zipfs_live $subcommand {*}$args]
        if {$subcommand eq "lmkimg"} { file copy -force $::good [lindex $args 0] }
        return $result
    }
    manifest {main.tcl}
    try {
        expect_code "valid but altered candidate archive is rejected" {wrap $APP --manifest $MANIFEST -o $OUT} badvalue
        preserved "candidate corruption"
    } finally {
        rename ::zipfs {}
        rename ::zipfs_live ::zipfs
        manifest $selected
    }

    # A held channel normally denies DELETE sharing on Windows. The native
    # publication gate must preserve the old destination when replacement fails.
    set held [open $OUT rb]
    try {
        expect_code "destination contention aborts atomic replacement" {wrap $APP --manifest $MANIFEST -o $OUT} oserror
        preserved "destination contention"
    } finally { close $held }
    check "all packaging attempts leave no work directories" [no_work]
} finally {
    if {$unselectedLink ne ""} { catch {file delete $unselectedLink} }
    if {$rootAlias ne ""} { catch {file delete $rootAlias} }
    if {$junction ne ""} { catch {file delete $junction} }
    if {![catch {canon $ROOT} facts] && [::machteld::_canon_key $facts] eq $rootKey &&
            [string match machteld-wrap-inventory-* [file tail $ROOT]]} { file delete -force $ROOT }
}
if {$fails} { puts stderr "$fails of $checks wrap inventory checks failed"; exit 1 }
puts "ALL $checks WRAP INVENTORY CHECKS PASSED"
