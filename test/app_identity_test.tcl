package require machteld 0.21

# test/app_identity_test.tcl -- a wrapped application's own Windows identity:
# its RT_VERSION strings and numbers, RT_MANIFEST kept from the basekit, its
# RT_GROUP_ICON and RT_ICON images byte for byte, app-info.dict agreeing with
# what Windows shows, the runtime's build-info kept apart from it, a wrap with
# nothing on PATH, refusals that leave every file byte-identical, and the
# runtime under test never changed. GUI hosts are read as data only: no GUI
# executable is started and no window opens.
#
#     machteld.exe test/app_identity_test.tcl RUNTIME
#
# Runs on the build runtime; RUNTIME wraps and is the host under test, and it
# also runs test/identity_native_test.tcl, the private identity commands'
# own regressions. The Tcl port of test/app_identity_test.ps1 (machteld
# 8bcc1ec), which read the resources with C# through Windows' resource and
# version APIs; here they are read from the PE bytes (test/pe_resources.tcl).

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] pe_resources.tcl]

namespace eval ::ai {
    namespace path {::machteld ::pe}
    variable here [file dirname [file normalize [info script]]]
    variable checks 0
    variable failures 0
    variable runtime ""
}

proc ::ai::check {name condition {detail ""}} {
    variable checks
    variable failures
    incr checks
    if {$condition} {
        puts "ok   $name"
    } else {
        incr failures
        puts "FAIL $name $detail"
    }
}

proc ::ai::writeText {path text} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel [encoding convertto utf-8 $text]
    close $channel
}

proc ::ai::writeBytes {path data} {
    set channel [open $path wb]
    puts -nonewline $channel $data
    close $channel
}

# Runs the runtime under test (or -exe) with args; returns exit, status,
# out (strict UTF-8, or "" when it is not) and text (err then out).
proc ::ai::host {args} {
    variable runtime
    set exe $runtime
    set options {}
    while {[lindex $args 0] in {-exe -env}} {
        set args [lassign $args option value]
        if {$option eq "-exe"} {
            set exe $value
        } else {
            lappend options $option $value
        }
    }
    set result [run -timeout 5m {*}$options -- $exe {*}$args]
    if {[catch {encoding convertfrom -profile strict utf-8 [dict get $result out]} out]} {
        set out ""
    }
    set err [encoding convertfrom -profile replace utf-8 [dict get $result err]]
    dict create exit [dict get $result exit] status [dict get $result status] out $out \
        text "$err[encoding convertfrom -profile replace utf-8 [dict get $result out]]"
}

proc ::ai::versionInfo {path} {
    if {[catch {parse [versionBlock $path]} info]} {
        return [dict create strings {} fileMS 0 fileLS 0 productMS 0 productLS 0]
    }
    return $info
}

proc ::ai::refused {label manifest protected args} {
    variable app
    set before [hash file sha256 $protected]
    set result [host wrap $app --manifest $manifest {*}$args]
    check "$label refuses invalid wrapping" [expr {[dict get $result exit] != 0}] [dict get $result text]
    check "$label preserves the existing file byte-for-byte" [expr {[hash file sha256 $protected] eq $before}]
}

# The probe runs on the runtime under test: `extract DIR` copies the packaged
# basekits out and reports the runtime's build-info and version; `inspect EXE`
# reads a wrapped application's app-info.dict from its ZIP. Both print one
# Tcl dict.
set ::ai::probe {package require machteld
fconfigure stdout -encoding utf-8
proc read_bytes {path} {
    set ch [open $path rb]
    try { return [read $ch] } finally { close $ch }
}
proc optional_file {root name} {
    set path [file join $root $name]
    if {![file isfile $path]} { return "" }
    return [binary encode base64 -maxlen 0 [read_bytes $path]]
}
if {[lindex $argv 0] eq "extract"} {
    set root [::machteld::PayloadRoot]
    set destination [lindex $argv 1]
    file mkdir $destination
    foreach kind {console gui} { file copy [file join $root basekit $kind.exe] [file join $destination $kind.exe] }
    puts [list build_info [optional_file $root build-info.dict] runtime_version [version]]
} else {
    zipfs mount [lindex $argv 1] identity_inspect
    set root //zipfs:/identity_inspect
    try {
        set info [encoding convertfrom utf-8 [read_bytes [file join $root app-info.dict]]]
        set metadata [dict get $info metadata]
        set result [dict create build_info [optional_file $root build-info.dict] \
            schema [dict get $info schema] entry [dict get $info entry] host [dict get $info host] \
            runtime_name [dict get $info runtime name] runtime_version [dict get $info runtime version] \
            runtime_author [dict get $info runtime author] \
            files [dict keys [dict get $info files]] app_main [hash file sha256 [file join $root app main.tcl]] \
            payload_icon [file exists [file join $root app icon.ico]] \
            has_reference [file exists [file join $root reference]]]
        foreach field {name description version author publisher copyright internal_name original_filename} {
            dict set result $field [dict get $metadata $field]
        }
        if {[dict get $metadata icon] ne ""} {
            dict set result icon_hash [dict get $metadata icon sha256]
            dict set result icon_bytes [dict get $metadata icon bytes]
        }
        puts $result
    } finally { zipfs unmount identity_inspect }
}
}

proc ::ai::main {argv} {
    variable runtime
    variable here
    variable failures
    variable checks
    variable app
    variable probe
    if {[llength $argv] != 1} {
        puts stderr "usage: app_identity_test.tcl RUNTIME"
        exit 2
    }
    set runtime [file normalize [lindex $argv 0]]
    set hostHash [hash file sha256 $runtime]
    set temp [file normalize $::env(TEMP)]
    set leaf machteld-app-identity-[pid]-[binary encode hex [hash random 16]]
    set work [file join $temp $leaf]
    if {[file exists $work]} {
        error "the work folder exists already: [file nativename $work]"
    }
    file mkdir $work
    try {
        set probePath [file join $work inspect.tcl]
        writeText $probePath $probe
        set bare [file join $work bare]
        set extracted [host $probePath extract $bare]
        if {[dict get $extracted exit] != 0} {
            error "cannot extract the embedded basekits: [dict get $extracted text]"
        }
        set runtimeInfo [string trim [dict get $extracted out]]
        set nativeWork [file join $work native]
        set native [host [file join $here identity_native_test.tcl] \
            [file join $bare console.exe] [file join $bare gui.exe] $nativeWork]
        puts [string trimright [dict get $native text]]
        check {private native validation suite passes against packaged executable} \
            [expr {[dict get $native exit] == 0}] [dict get $native text]
        if {[dict get $native exit] != 0} {
            error "the private identity suite failed"
        }

        # Spelled as escapes, so a mis-decoded test file cannot give the
        # manifest and the expectations the same mojibake.
        set omega \u03a9
        set rocket \U0001f680
        foreach kind {console gui} {
            set bareData [bytes [file join $bare $kind.exe]]
            set nativeData [bytes [file join $nativeWork "$kind-$omega.exe"]]
            check "$kind native stamping preserves unrelated Windows manifest bytes" \
                [expr {[resource $nativeData 24 1] eq [resource $bareData 24 1] && [resource $bareData 24 1] ne ""}]
            check "$kind repeated icon replacement removes stale image IDs" \
                [expr {[resource $nativeData 3 1 0x409] ne "" && [names $nativeData 3] eq {1}}] [names $nativeData 3]
        }

        set app [file join $work app]
        set entry [file join $app main.tcl]
        writeText $entry "package require machteld\nputs APP-IDENTITY-OK\n"
        set manifest [file join $work payload.dict]
        set icon [file join $work icon.ico]
        file copy [file join $nativeWork valid-multiple.ico] $icon
        set appName "Project desk $omega $rocket"
        set description "Administration $omega $rocket"
        set author "App Author $omega"
        set publisher "App Publisher $omega"
        set copyright "Copyright 2026 App Author $omega"
        set custom "name {$appName} version 7.8 description {$description} author {$author} publisher {$publisher} copyright {$copyright} icon icon.ico"
        writeText $manifest "schema 1 files {main.tcl} metadata {$custom}\n"
        set iconFile [bytes $icon]
        foreach kind {console gui} {
            set target [file join $work "custom-$kind-$omega.exe"]
            set arguments [list wrap $app --manifest $manifest -o $target --$kind]
            set planned [host {*}$arguments --plan]
            check "$kind identity plan validates without creating output" \
                [expr {[dict get $planned exit] == 0 && ![file exists $target]}] [dict get $planned text]
            set result [host {*}$arguments]
            check "$kind custom identity wraps successfully" \
                [expr {[dict get $result exit] == 0 && [file isfile $target]}] [dict get $result text]
            if {[dict get $result exit] != 0} {
                continue
            }
            set info [versionInfo $target]
            set data [bytes $target]
            check "$kind Windows properties preserve Unicode name and description" \
                [expr {[field $info ProductName] eq $appName && [field $info FileDescription] eq $description}]
            check "$kind application versions are independent from runtime version" \
                [expr {[field $info FileVersion] eq "7.8" && [field $info ProductVersion] eq "7.8" &&
                    [lrange [numbers $info] 0 3] eq {7 8 0 0}}] [numbers $info]
            check "$kind explicit authorship appears exactly in Windows properties" \
                [expr {[field $info CompanyName] eq $publisher && [field $info LegalCopyright] eq $copyright &&
                    [field $info Author] eq $author}]
            check "$kind application filenames describe the output, not Machteld" \
                [expr {[field $info InternalName] eq [file rootname [file tail $target]] &&
                    [field $info OriginalFilename] eq [file tail $target]}]
            check "$kind Windows properties label runtime identity separately" \
                [expr {[field $info MachteldRuntimeVersion] eq [dict get $runtimeInfo runtime_version] &&
                    [field $info MachteldRuntimeAuthor] eq "Vincent Vercauteren"}]
            check "$kind wrapped identity preserves the Windows manifest resource" \
                [expr {[resource $data 24 1] eq [resource [bytes [file join $bare $kind.exe]] 24 1]}]
            set group [resource $data 14 1 0x409]
            check "$kind custom multi-image icon has the expected resource group" \
                [expr {[string length $group] == 34 && [u16 $group 4] == 2}]
            for {set index 0} {$index < 2} {incr index} {
                set size [u32 $iconFile [expr {6 + 16 * $index + 8}]]
                set offset [u32 $iconFile [expr {6 + 16 * $index + 12}]]
                set expected [string range $iconFile $offset [expr {$offset + $size - 1}]]
                check "$kind icon image $index retains exact PNG/DIB bytes" \
                    [expr {[resource $data 3 [expr {$index + 1}] 0x409] eq $expected}]
            }
            set inspected [host $probePath inspect $target]
            check "$kind stamped executable retains a readable application ZIP" \
                [expr {[dict get $inspected exit] == 0}] [dict get $inspected text]
            if {[dict get $inspected exit] == 0} {
                set payload [string trim [dict get $inspected out]]
                check "$kind application identity record matches Windows identity" \
                    [expr {[dict get $payload name] eq $appName && [dict get $payload description] eq $description &&
                        [dict get $payload version] eq "7.8" && [dict get $payload author] eq $author &&
                        [dict get $payload publisher] eq $publisher && [dict get $payload copyright] eq $copyright}]
                check "$kind runtime provenance remains separate and byte-identical" \
                    [expr {[dict get $payload runtime_name] eq "Machteld" &&
                        [dict get $payload runtime_version] eq [dict get $runtimeInfo runtime_version] &&
                        [dict get $payload runtime_author] eq "Vincent Vercauteren" &&
                        [dict get $payload build_info] eq [dict get $runtimeInfo build_info]}]
                check "$kind exact selected payload and icon provenance survive stamping" \
                    [expr {[dict get $payload schema] == 1 && [dict get $payload entry] eq "app/main.tcl" &&
                        [dict get $payload host] eq $kind && [dict get $payload files] eq "main.tcl" &&
                        [dict get $payload app_main] eq [hash file sha256 $entry] &&
                        ![dict get $payload payload_icon] && ![dict get $payload has_reference] &&
                        [dict get $payload icon_hash] eq [hash file sha256 $icon] &&
                        [dict get $payload icon_bytes] == [string length $iconFile]}]
            }
            if {$kind eq "console"} {
                set ran [host -exe $target]
                check {custom console application still executes its own entry} \
                    [expr {[dict get $ran exit] == 0 && [string trim [dict get $ran out]] eq "APP-IDENTITY-OK"}] [dict get $ran text]
            }
        }

        set minimal [file join $work minimal.exe]
        writeText $manifest "schema 1 files {main.tcl} metadata {name {Unattributed app} version 1.2.3.4}\n"
        set result [host wrap $app --manifest $manifest -o $minimal]
        check {minimal explicit metadata wraps without inventing ownership} \
            [expr {[dict get $result exit] == 0}] [dict get $result text]
        if {[dict get $result exit] == 0} {
            set info [versionInfo $minimal]
            check {omitted description defaults to app name and all ownership remains blank} \
                [expr {[field $info FileDescription] eq "Unattributed app" && [field $info CompanyName] eq "" &&
                    [field $info LegalCopyright] eq "" && [dict exists $info strings Author] &&
                    [field $info Author] eq ""}]
            check {four-part application version is exact in text and numeric tuple} \
                [expr {[field $info FileVersion] eq "1.2.3.4" && [lrange [numbers $info] 0 3] eq {1 2 3 4}}]
        }
        set nested [file join $work manifests]
        file mkdir $nested
        foreach iconPath [list ../icon.ico [file normalize $icon]] {
            set nestedManifest [file join $nested payload.dict]
            writeText $nestedManifest "schema 1 files {main.tcl} metadata {name {Icon path app} version 1 icon {$iconPath}}\n"
            set pathOutput [file join $work icon-path.exe]
            set result [host wrap $app --manifest $nestedManifest -o $pathOutput]
            check {explicit parent-relative or absolute icon path resolves from manifest} \
                [expr {[dict get $result exit] == 0 && [resource [bytes $pathOutput] 14 1 0x409] ne ""}] [dict get $result text]
        }
        writeText $manifest "schema 1 files {main.tcl} metadata {$custom}\n"
        set emptyPath [file join $work empty-tool-path]
        file mkdir $emptyPath
        set compilerFree [file join $work compiler-free.exe]
        set result [host -env [list PATH [file nativename $emptyPath]] wrap $app --manifest $manifest -o $compilerFree]
        check {custom identity and icon wrap with no compiler or helper on PATH} \
            [expr {[dict get $result exit] == 0 && [file isfile $compilerFree] &&
                [field [versionInfo $compilerFree] ProductName] eq $appName &&
                [resource [bytes $compilerFree] 14 1 0x409] ne ""}] [dict get $result text]

        set protected [file join $work protected.exe]
        writeBytes $protected [binary decode hex 00112233445566778899aabbccddeeff]
        foreach invalid [list {name Demo} {version 1} {name Demo version 65536} {name Demo version 1.2.3.4.5} \
                "name Demo version 1 description {\u0085}" "name {[string repeat x 1025]} version 1" \
                {name Demo version 1 unknown nope}] {
            writeText $manifest "schema 1 files {main.tcl} metadata {$invalid}\n"
            refused "invalid metadata" $manifest $protected -o $protected
        }
        writeText $manifest "schema 1 files {main.tcl} metadata {name Demo version 1 icon broken.ico}\n"
        writeBytes [file join $work broken.ico] [binary decode hex 000001000100]
        refused "malformed icon" $manifest $protected -o $protected
        refused "malformed icon plan" $manifest $protected -o $protected --plan
        writeText $manifest "schema 1 files {main.tcl} metadata {$custom}\n"
        refused "output equal to icon" $manifest $icon -o $icon
        set iconAlias [file join $work icon-hardlink.exe]
        file link -hard $iconAlias $icon
        refused "output hardlinked to icon" $manifest $icon -o $iconAlias
        check {identity tests never mutate the tested Machteld executable} [expr {[hash file sha256 $runtime] eq $hostHash}]
    } finally {
        if {[file tail $work] eq $leaf && [file dirname $work] eq $temp && [file isdirectory $work]} {
            file delete -force $work
        }
    }
    if {$failures} {
        puts stderr "$failures of $checks app identity checks failed"
        exit 1
    }
    puts "ALL $checks APP IDENTITY CHECKS PASSED"
}

::ai::main $argv
