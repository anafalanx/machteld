package require machteld

# With a desktop_catalog.dll argument the gate runs a real Tk application
# on its private, never-switched desktop.
set here [file dirname [file normalize [info script]]]
source -encoding utf-8 [file join $here pe_resources.tcl]

proc verify {label predicate {detail ""}} {
    if {![uplevel 1 [list expr $predicate]]} {error "failed: $label ($predicate) $detail"}
    puts "ok   $label"
}
proc writeBytes {path data} {
    file mkdir [file dirname $path]
    set f [open $path wb]
    try {puts -nonewline $f $data} finally {close $f}
}
proc writeText {path data} {writeBytes $path [encoding convertto utf-8 $data]}
proc readText {path} {encoding convertfrom -profile strict utf-8 [::pe::bytes $path]}
proc stdoutOf {result} {
    if {[dict get $result status] ne "ok"} {error "process failed: $result"}
    return [string trimright [encoding convertfrom -profile strict utf-8 [dict get $result out]] "\r\n"]
}
proc pngChunk {kind bytes} {
    return "[binary format I [string length $bytes]]$kind$bytes[binary format I [zlib crc32 "$kind$bytes"]]"
}
proc sampleIcon {} {
    # Independent DIB (1x1) and PNG (2x2) images exercise both resource forms.
    set dib [binary decode hex 280000000100000002000000010020000000000004000000000000000000000000000000000000000000ffff00000000]
    set png [binary decode hex 89504e470d0a1a0a]
    append png [pngChunk IHDR [binary format IIccccc 2 2 8 6 0 0 0]]
    set scanline [binary decode hex 00ff0000ff0000ffff]
    append png [pngChunk IDAT [zlib compress "$scanline$scanline"]] [pngChunk IEND ""]
    set first "[binary decode hex 0101000001002000][binary format ii [string length $dib] 38]"
    set second "[binary decode hex 0202000001002000][binary format ii [string length $png] [expr {38 + [string length $dib]}]]"
    return "[binary decode hex 000001000200]$first$second$dib$png"
}
proc inspectPe {path host metadata icon template} {
    set data [::pe::bytes $path]
    set optional [expr {[::pe::u32 $data 0x3c] + 24}]
    set directories [expr {$optional + ([::pe::u16 $data $optional] == 0x20b ? 112 : 96)}]
    verify "$host Windows subsystem" {[::pe::u16 $data [expr {$optional + 68}]] == ($host eq "gui" ? 2 : 3)}
    verify "$host unsigned image" {[::pe::u32 $data [expr {$directories + 32}]] == 0 &&
        [::pe::u32 $data [expr {$directories + 36}]] == 0}
    set manifest [::pe::resource $template 24 1]
    verify "$host retains the application manifest" {$manifest ne "" && [::pe::resource $data 24 1] eq $manifest}
    set ver [::pe::parse [::pe::resource $data 16 1 0x409]]
    foreach {field key} {
        ProductName name FileDescription description CompanyName publisher Author author
        LegalCopyright copyright FileVersion version ProductVersion version
    } {
        verify "$host $field" {[::pe::field $ver $field] eq [dict get $metadata $key]}
    }
    verify "$host fixed file and product versions" {[::pe::numbers $ver] eq {7 8 0 42 7 8 0 42}}
    verify "$host internal and original filenames" {[::pe::field $ver InternalName] eq [file rootname [file tail $path]] &&
        [::pe::field $ver OriginalFilename] eq [file tail $path]}
    verify "$host runtime attribution" {[::pe::field $ver MachteldRuntimeVersion] eq [package present machteld] &&
        [::pe::field $ver MachteldRuntimeAuthor] eq "Vincent Vercauteren"}
    set groups [::pe::names $data 14]
    set group [::pe::resource $data 14 [lindex $groups 0] 0x409]
    verify "$host icon group" {[llength $groups] == 1 && [string equal -nocase [lindex $groups 0] tk] &&
        [::pe::names $data 3] eq {1 2} &&
        [string length $group] == 34 && [::pe::u16 $group 4] == 2}
    foreach i {0 1} {
        set icoAt [expr {6 + 16 * $i}]
        set groupAt [expr {6 + 14 * $i}]
        set size [::pe::u32 $icon [expr {$icoAt + 8}]]
        set offset [::pe::u32 $icon [expr {$icoAt + 12}]]
        set id [::pe::u16 $group [expr {$groupAt + 12}]]
        verify "$host icon $i dimensions, size and image bytes" {
            [string range $group $groupAt [expr {$groupAt + 11}]] eq [string range $icon $icoAt [expr {$icoAt + 11}]] &&
            [::pe::resource $data 3 $id 0x409] eq [string range $icon $offset [expr {$offset + $size - 1}]]}
    }
}
proc inspectPayload {image plan} {
    zipfs mount $image wrappedCheck
    set root //zipfs:/wrappedCheck
    try {
        set record [readText [file join $root app-info.dict]]
        foreach key {schema entry host with_docs metadata files runtime} {
            verify "app-info $key agrees with preflight" {[dict get $record $key] eq [dict get $plan $key]}
        }
        verify "standalone runtime contents" {[lsort [glob -directory $root -tails *]] eq
            [lsort {app app-info.dict licenses machteld.tcl tcl9 tcl_library tk_library}]}
        verify "retains embedded license notices" {[lsort [glob -directory $root/licenses -tails *]] eq
            [lsort [glob -directory [file join [::machteld::PayloadRoot] licenses] -tails *]]}
        set index [readText [file join $root app machteld-inventory.dict]]
        verify "uses the shared archive inventory" {[dict get $index schema] == 1 &&
            [dict get $index entry] eq "ui/start.tcl" && [dict get $index files] eq [dict get $plan files]}
        foreach {name desc} [dict get $index files] {
            set path [file join $root app $name]
            verify "selected $name payload bytes" {[file size $path] == [dict get $desc bytes] &&
                [hash file sha256 $path] eq [dict get $desc sha256]}
        }
        verify "omits build-only icon and unselected project reference" {![file exists $root/app/icon.ico] &&
            ![file exists $root/app/reference] && ![file exists $root/app/app.dict]}
    } finally {zipfs unmount wrappedCheck}
}
proc solidIcon {bgra} {
    set header [binary format iiissiiiiii 40 32 64 1 32 0 4096 0 0 0 0]
    set dib "$header[string repeat [binary decode hex $bgra] 1024][binary format a128 {}]"
    return "[binary decode hex 0000010001002020000001002000][binary format ii [string length $dib] 22]$dib"
}
proc sameSwatch {observed expected} {
    # The shell's DPI scaling can round a rendered channel more than once.
    foreach offset {1 3 5} {
        scan [string range $observed $offset [expr {$offset + 1}]] %x a
        scan [string range $expected $offset [expr {$offset + 1}]] %x b
        if {abs($a - $b) > 5} {return 0}
    }
    return 1
}
proc checkTk {work fixture catalog} {
    if {![info exists ::env(MACHTELD_TEST_EXPECT_DESKTOP)] ||
        ![string match MachteldDesktopTest-* $::env(MACHTELD_TEST_EXPECT_DESKTOP)]} {
        error "run the wrapped window tests through desktop_runner.exe"
    }
    set source [file join $work src]
    file mkdir $source
    file copy $fixture [file join $source main.tcl]
    writeBytes [file join $source app.ico] [solidIcon 37a3e9ff]
    set control [file join $work original.ico]
    file copy [file join $source app.ico] $control
    set spec [file join $source app.dict]
    writeText $spec [dict create schema 1 entry main.tcl files {main.tcl} \
        metadata [dict create name "Window icon test" version 1 icon app.ico]]
    set override [file join $work override.ico]
    writeBytes $override [solidIcon b9b441ff]
    set dir [file join $work relocated]
    file mkdir $dir
    foreach mode {gui console} {
        set target [file join $work window.exe]
        wrap $spec -o $target --$mode
        file rename $target [file join $dir $mode.exe]
    }
    file delete -force -- $source
    foreach mode {gui console} {
        set report [file join $work $mode.dict]
        stdoutOf [run -dir $dir -timeout 30s -- [file join $dir $mode.exe] $mode $catalog $report $override $control]
        set state [readText $report]
        if {[dict exists $state error]} {error [dict get $state error]}
        verify "$mode initializes Tk at the requested time and packs a widget" {
            [dict get $state startedWithTk] == ($mode eq "gui") && [dict get $state manager] eq "pack"}
        verify "$mode Windows Shell, real root, and new toplevel display the executable icon" {
            [sameSwatch [dict get $state control] "#e9a337"] && [sameSwatch [dict get $state shell] [dict get $state control]] &&
            [sameSwatch [dict get $state root] [dict get $state control]] &&
            [dict get $state inherited] eq [dict get $state root]} $state
        verify "$mode window accepts both Tcl icon overrides independently of the root" {
            [dict get $state photo] eq "#00eb63" && [dict get $state bitmap] eq "#41b4b9" &&
            [dict get $state unchanged] eq [dict get $state root]} $state
    }
}
# Rebuild a fixture with a changed asset and the original inventory. Both
# packaging and startup must catch accidental corruption before app dispatch.
proc damageAsset {source output name replacement {template ""}} {
    zipfs mount $source damageFixture
    try {
        set entries [::machteld::_zip_entries //zipfs:/damageFixture]
        set sourceIndex [expr {[lsearch -exact $entries $name] - 1}]
        if {$sourceIndex < 0} {error "fixture lacks $name"}
        lset entries $sourceIndex $replacement
        if {$template eq ""} {
            zipfs lmkzip $output $entries
        } else {
            zipfs lmkimg $output $entries {} $template
        }
    } finally {zipfs unmount damageFixture}
}
proc checkWrap {work fixture} {
    set runtime [info nameofexecutable]
    set runtimeHash [hash file sha256 $runtime]
    set source [file join $work {source tree}]
    set caller [file join $work caller]
    file mkdir $caller
    set entry [file join $source ui start.tcl]
    writeText $entry [string map [list "\r\n" "\n"] [readText $fixture]]
    set payload [binary decode hex 007fff5c0081]
    writeBytes [file join $source ui payload.bin] $payload
    writeText [file join $source docs help.md] "Application-specific help\n"
    writeText [file join $source reference reference.db] "unselected fixture"
    set icon [sampleIcon]
    writeBytes [file join $source icon.ico] $icon
    set metadata [dict create name "Planner \u03a9 \U0001f680" version 7.8.0.42 description "Editor \u5de5\u5177" \
        author "Zo\u00eb" publisher "M\u00fcller & Co" copyright "\u00a9 2026" icon icon.ico]
    set spec [file join $source app.dict]
    set files {docs/help.md ui/payload.bin ui/start.tcl}
    set project [dict create schema 1 entry ui/start.tcl files $files metadata $metadata]
    writeText $spec $project
    set template [::pe::bytes [file join [::machteld::PayloadRoot] basekit app.exe]]
    foreach host {console gui} {
        set dir [file join $work $host]
        file mkdir $dir
        set path [file join $dir "Planner \u03a9.exe"]
        set plan [::machteld::wrap $spec -o $path --$host --plan]
        verify "$host preview has no filesystem side effects" {![file exists $path] &&
            [dict get $plan schema] == 1 && [dict get $plan host] eq $host && [dict get $plan with_docs] == 0 &&
            [dict get $plan entry] eq "app/ui/start.tcl" && [lsort [dict keys [dict get $plan files]]] eq $files}
        set iconInfo [dict get $plan metadata icon]
        verify "$host records icon digest and distinct runtime provenance" {
            [dict get $iconInfo sha256] eq [hash file sha256 [file join $source icon.ico]] &&
            [dict get $iconInfo bytes] == [string length $icon] && [dict get $plan runtime name] eq "Machteld" &&
            [dict get $plan runtime version] eq [package present machteld] && [string first $source $plan] < 0}
        if {$host eq "console"} {
            set console $path
            wrap $spec -o $path --console
        } else {
            stdoutOf [run -timeout 5m -env [list PATH [file nativename $caller]] -- $runtime wrap $spec -o $path --gui]
        }
        inspectPe $path $host $metadata $icon $template
        inspectPayload $path $plan
        set label [expr {$host eq "gui" ? "GUI" : $host}]
        puts "wrapped $label SHA-256 [hash file sha256 $path]"
    }
    set prior [hash file sha256 $console]
    set ordinary [file join $work plain]
    writeText [file join $ordinary main.tcl] "package require machteld\nputs OK\n"
    writeText [file join $ordinary notes.txt] "Application notes\n"
    set plainOut [file join $work plain.exe]
    set scriptPlan [wrap [file join $ordinary main.tcl] -o $plainOut --plan]
    set dirPlan [wrap $ordinary -o $plainOut --plan]
    verify "single-script and directory forms retain their different file selections" {
        [dict get $scriptPlan entry] eq "app/main.tcl" && [dict keys [dict get $scriptPlan files]] eq "main.tcl" &&
        [dict get $dirPlan entry] eq "app/main.tcl" && [lsort [dict keys [dict get $dirPlan files]]] eq {main.tcl notes.txt} &&
        [dict get $dirPlan host] eq "console" && ![file exists $plainOut]}
    set legacySpec [file join $source selection.dict]
    writeText $legacySpec [dict remove $project entry]
    set oldPlan [wrap $source --entry ui/start.tcl --manifest $legacySpec -o $console --plan]
    verify "old selection manifest preserves output during preview" {[dict get $oldPlan entry] eq "app/ui/start.tcl" &&
        [dict get $oldPlan files] eq [dict get $plan files] && [hash file sha256 $console] eq $prior}
    foreach options {{--with-docs} {--sign} {--unknown}} {
        verify "refuses $options and preserves output" {[catch {wrap $spec -o $console {*}$options}] &&
            [hash file sha256 $console] eq $prior}
    }
    foreach invalid [list [dict replace $metadata version 1.2.65536] [dict replace $metadata icon missing.ico]] {
        writeText $spec [dict replace $project metadata $invalid]
        verify "invalid branding preserves output" {[catch {wrap $spec -o $console}] && [hash file sha256 $console] eq $prior}
    }
    writeText $spec $project
    set archive [file join $work app.machteld]
    stdoutOf [run -timeout 2m -- $runtime pack $spec -o $archive]
    set external [file join $work branding app.dict]
    writeText $external $project
    writeBytes [file join [file dirname $external] icon.ico] $icon
    file delete -force -- $source
    set bitrot [file join $work corrupt.bin]
    writeBytes $bitrot [string replace $payload 1 1 X]
    set broken [file join $work damaged.machteld]
    damageAsset $archive $broken ui/payload.bin $bitrot
    verify "changed archive asset rejected before publication" {[catch {wrap $broken -o $console}] &&
        [hash file sha256 $console] eq $prior}
    set fromArchive [file join $work from-archive.exe]
    wrap $archive -o $fromArchive
    set rebranded [file join [file dirname $external] [file tail $console]]
    wrap $archive --manifest $external -o $rebranded
    verify "branding an existing verified archive recreates the source-project image" {
        [hash file sha256 $rebranded] eq $prior}
    foreach mismatch [list [dict replace $project files {ui/start.tcl}] [dict replace $project entry ui/payload.bin]] {
        writeText $external $mismatch
        verify "mismatched branding manifest preserves the application" {
            [catch {wrap $archive --manifest $external -o $rebranded}] && [hash file sha256 $rebranded] eq $prior}
    }
    file delete $archive
    set unbranded [::pe::bytes $fromArchive]
    set details [::pe::parse [::pe::resource $unbranded 16]]
    verify "unspecified branding uses the filename, generic icon and blank ownership" {
        [::pe::field $details ProductName] eq "from-archive" && [::pe::field $details FileDescription] eq "from-archive" &&
        [::pe::numbers $details] eq {0 0 0 0 0 0 0 0} && [::pe::field $details FileVersion] eq "0.0.0.0" &&
        [::pe::field $details CompanyName] eq "" && [::pe::field $details Author] eq "" &&
        [::pe::field $details LegalCopyright] eq "" && [::pe::names $unbranded 14] eq {} && [::pe::names $unbranded 3] eq {}}
    set dir [file join $work {relocated app}]
    file mkdir $dir
    set moved [file join $dir "Renamed \u03a9.exe"]
    file rename $console $moved
    set probe [stdoutOf [run -timeout 60s -dir $caller -- $moved --probe]]
    set launch [dict get $probe launch]
    set fileId [::machteld::_canon_key [canon $moved]]
    set contents [glob -tails -directory $dir *]
    verify "single relocated executable runs its application and relaunches a worker" {
        [llength $contents] == 1 && [lindex $contents 0] eq [file tail $moved] &&
        [dict get $probe asset] eq [binary encode hex $payload] && [dict get $probe matches] == 1 &&
        [dict get $probe reply] eq "a reply with spaces" && [dict get $probe doc_code] eq {MACHTELD DOCS unsupported} &&
        [::machteld::_canon_key [canon [dict get $probe argv0]]] eq $fileId &&
        [string match */app/ui/start.tcl [dict get $probe script]]} [list $moved $contents $fileId $probe]
    verify "launch pins the running generation" {[::machteld::_canon_key [canon [lindex $launch 0]]] eq $fileId &&
        [lrange $launch 1 end] eq [list --machteld-wrapped-generation $prior]}
    set sidecar [file rootname $moved].tcl
    writeText $sidecar {error {wrong companion entry}}
    set words [list --help --docs --manifest --check wrap $sidecar {} {two words} {a"b} "x\\" "\u4e16\u754c"]
    set echo [stdoutOf [run -timeout 30s -dir $caller -- $moved {*}$words]]
    verify "every ordinary argument reaches the wrapped app even beside a companion" {
        [lindex $echo 0] == [llength $words] && [lindex $echo 1] eq $words}
    set result [run -timeout 30s -dir $caller -- {*}$launch --exit]
    verify "generation relaunch preserves the application exit code" {[dict get $result exit] == 37}
    set damagedExe [file join $work damaged.exe]
    damageAsset $moved $damagedExe app/ui/payload.bin $bitrot [file join [::machteld::PayloadRoot] basekit app.exe]
    set result [run -timeout 30s -dir $caller -- $damagedExe --exit]
    verify "changed wrapped asset rejected before running any application code" {
        [dict get $result status] eq "error" && [dict get $result exit] ni {0 37} &&
        [string match -nocase *inventory* [dict get $result err]]}
    set converted [stdoutOf [run -timeout 60s -dir $caller -- $fromArchive --probe]]
    verify "verified archive wraps after project and then archive removal" {[dict get $converted asset] eq [dict get $probe asset] &&
        [dict get $converted reply] eq [dict get $probe reply] && [dict get $converted doc_code] eq {MACHTELD DOCS unsupported}}
    foreach wrong [list [list $moved --machteld-wrapped-generation [string repeat 0 64]] \
            [list $fromArchive {*}[lrange $launch 1 end]] [list $runtime {*}[lrange $launch 1 end]]] {
        set result [run -timeout 20s -dir $caller -- {*}$wrong --exit]
        verify "a mismatched generation cannot dispatch the application" {
            [dict get $result status] eq "error" && [dict get $result exit] ni {0 37}}
    }
    verify "full runtime remains byte identical" {[hash file sha256 $runtime] eq $runtimeHash}
}

set work [file tempdir]
try {
    if {$argv eq {}} {
        checkWrap $work [file join $here fixtures wrap_app.tcl]
    } elseif {[llength $argv] == 1 && [file isfile [lindex $argv 0]]} {
        checkTk $work [file join $here fixtures wrap_tk.tcl] [file normalize [lindex $argv 0]]
    } else {error "usage: wrap_test.tcl ?desktop_catalog.dll?"}
} finally {file delete -force -- $work}
puts "Standalone wrapped application checks passed."
