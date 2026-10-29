# Headless acceptance of actual examples, including GUI-subsystem wrappers.
# No normal Inspector UI role is launched; worker/headless roles destroy the
# GUI host's precreated root before event processing.
package require machteld
if {[llength $argv] != 2} { error "usage: examples_package_test.tcl msys2-root tcl-prefix" }
lassign $argv MSYS PREFIX
set MSYS [file normalize $MSYS]
set PREFIX [file normalize $PREFIX]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
set INSPECTOR [file join $ROOT examples project-inspector]
set EXTENSION [file join $ROOT examples external-extension]
source [file join $EXTENSION build.tcl]
set TEMP_ROOT [file normalize $env(TEMP)]
set WORK [file normalize [file join $TEMP_ROOT machteld-examples-[pid]-[clock clicks]]]
if {[file dirname $WORK] ne $TEMP_ROOT || [file exists $WORK]} { error "unsafe example test workspace" }
file mkdir $WORK
set checks 0; set fails 0
proc check {name condition} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc read_text {path} {
    set channel [open $path r]
    try { fconfigure $channel -encoding utf-8; return [read $channel] } finally { close $channel }
}
proc write_text {path text} {
    set channel [open $path {WRONLY CREAT EXCL}]
    try { fconfigure $channel -encoding utf-8; puts -nonewline $channel $text } finally { close $channel }
}
proc run_utf8 {args} {
    # run captures bytes, not decoded text. These example roles explicitly emit
    # UTF-8; decode at their protocol boundary before interpreting JSON/paths.
    set result [::machteld::run {*}$args]
    foreach stream {out err} {
        dict set result $stream [encoding convertfrom -profile strict utf-8 [dict get $result $stream]]
    }
    return $result
}
proc payload_files {root {relative {}}} {
    set result {}
    foreach path [glob -nocomplain -directory [file join $root $relative] * .*] {
        if {[file tail $path] in {. ..}} { continue }
        set name [file join $relative [file tail $path]]
        if {[file isdirectory $path]} { lappend result {*}[payload_files $root $name]
        } else { lappend result [string map {\\ /} $name] }
    }
    return [lsort $result]
}
proc inspect_image {image expected} {
    set mount "example-[pid]-[clock clicks]"
    zipfs mount $image $mount
    try {
        set root //zipfs:/$mount
        set info [string trim [read_text [file join $root app-info.dict]]]
        check "[file tail $image]: exact application inventory" [expr {
            [payload_files [file join $root app]] eq [lsort $expected] &&
            [lsort [dict keys [dict get $info files]]] eq [lsort $expected]}]
        set valid 1
        dict for {name record} [dict get $info files] {
            set path [file join $root app $name]
            if {[file size $path] != [dict get $record bytes] ||
                    [hash file sha256 $path] ne [dict get $record sha256]} { set valid 0 }
        }
        check "[file tail $image]: embedded size and SHA-256 match payload" $valid
        check "[file tail $image]: reference pack is opt-in" [expr {![file exists [file join $root reference]]}]
        return $info
    } finally { zipfs unmount $mount }
}
proc inspect_runs {label prefix directory} {
    set result [run_utf8 -timeout 15s -- {*}$prefix --headless $directory]
    check "$label: normal controller/worker route exits successfully" [expr {
        [dict get $result status] eq "ok" && [dict get $result exit] == 0}]
    set state [json decode [dict get $result out]]
    set paths [lmap row [dict get $state rows] { dict get $row path }]
    check "$label: Unicode and spaces survive worker round-trip" [expr {
        [dict get $state phase] eq "done" && [file join $directory {café 雪.txt}] in $paths}]
    set numeric [lindex [dict get $state rows] 0]
    check "$label: numeric-looking filename stays a JSON string" [expr {
        [dict get $numeric name] eq "123" && [string match {*"name":"123"*} [dict get $result out]]}]
    set result [run_utf8 -timeout 15s -- {*}$prefix --headless $directory noisy]
    set state [json decode [dict get $result out]]
    check "$label: sustained stdout/stderr completes with bounded diagnostics" [expr {
        [dict get $result status] eq "ok" && [dict get $state phase] eq "done" &&
        [string length [dict get $state log]] == 8192}]
    set result [run_utf8 -timeout 15s -- {*}$prefix --headless $directory fail]
    set state [json decode [dict get $result out]]
    check "$label: deliberate worker failure remains a copyable error" [expr {
        [dict get $result exit] == 1 && [dict get $state phase] eq "error" &&
        [string match {*Deliberate demonstration failure*} [dict get $state error]]}]
    set result [run_utf8 -timeout 15s -- {*}$prefix --worker $directory inspect]
    set records [split [string trim [dict get $result out]] \n]
    check "$label: direct worker role is not recursive GUI startup" [expr {
        [dict get $result status] eq "ok" &&
        [dict get [json decode [lindex $records end]] type] eq "complete"}]
    set result [run_utf8 -timeout 5s -- {*}$prefix --headless]
    check "$label: invalid role arguments fail without entering Tk" [expr {
        [dict get $result exit] == 2 && [string match {*usage:*} [dict get $result err]]}]
}
set originalDirectory [pwd]
set originalChildren [child list]
try {
    set directory [file join $WORK {data space 雪}]
    set unrelated [file join $WORK unrelated]
    file mkdir $directory $unrelated
    write_text [file join $directory {café 雪.txt}] "read-only fixture"
    write_text [file join $directory 123] "numeric name"
    set originalHash [hash file sha256 [file join $directory {café 雪.txt}]]
    set stage [file join $WORK inspector-stage]
    file mkdir $stage
    set manifest [file join $INSPECTOR app.dict]
    set assets [dict get [read_text $manifest] files]
    foreach name $assets { file copy [file join $INSPECTOR $name] [file join $stage $name] }
    write_text [file join $stage private-note.txt] "Not an application asset."
    set images {}
    foreach host {console gui} {
        set image [file join $WORK "Inspector $host 雪.exe"]
        set plan [wrap $stage -o $image --manifest $manifest --$host --plan]
        check "$host: package plan does not publish output" [expr {![file exists $image]}]
        wrap $stage -o $image --manifest $manifest --$host
        set info [inspect_image $image $assets]
        check "$host: committed inventory matches package plan" [expr {$info eq $plan}]
        check "$host: app identity and runtime identity stay separate" [expr {
            [dict get $info metadata name] eq "Project Inspector" &&
            [dict get $info metadata version] eq "1.0" &&
            [dict get $info runtime name] eq "Machteld"}]
        dict set images $host $image
    }
    # Remove the original staging pathname as an available dependency; the
    # application must source siblings from its archive and launch its own role.
    file rename $stage [file join $WORK retired-inspector-stage]
    cd $unrelated
    inspect_runs source [list [info nameofexecutable] [file join $INSPECTOR main.tcl]] $directory
    dict for {host image} $images { inspect_runs $host [list $image] $directory }
    foreach host {console gui} {
        set bundle [::extension_example::build [file join $WORK extension-$host] $MSYS $PREFIX --$host]
        set headers [exec [file join $MSYS ucrt64 bin objdump.exe] -p [file join $bundle examplemath.dll]]
        set imports [regexp -all -inline -line {DLL Name: ([^\r\n]+)} $headers]
        set onlyPlatform [expr {[llength $imports] > 0}]
        foreach {match library} $imports {
            set library [string tolower [string trim $library]]
            if {$library ni {kernel32.dll ucrtbase.dll} &&
                    ![string match api-ms-win-crt-*.dll $library]} { set onlyPlatform 0 }
        }
        check "$host extension: imports only Windows/UCRT, not Tcl/compiler DLLs" $onlyPlatform
        set deployed [file join $WORK "deployed $host 雪"]
        file rename $bundle $deployed
        set image [file join $deployed extension-example.exe]
        inspect_image $image {main.tcl}
        set shipping [read_text [file join $deployed ship.dict]]
        set expected {LICENSE-examplemath.txt NOTICE-examplemath.txt examplemath.dll extension-example.exe}
        check "$host extension: exact external deployment inventory" [expr {
            [lsort [dict keys [dict get $shipping files]]] eq [lsort $expected] &&
            [payload_files $deployed] eq [lsort [concat $expected ship.dict]]}]
        set valid 1
        dict for {name record} [dict get $shipping files] {
            set path [file join $deployed $name]
            if {[file size $path] != [dict get $record size] ||
                    [hash file sha256 $path] ne [dict get $record sha256]} { set valid 0 }
        }
        check "$host extension: deployment sizes and hashes match" $valid
        check "$host extension: full license and attribution travel beside DLL" [expr {
            [read_text [file join $deployed LICENSE-examplemath.txt]] eq [read_text [file join $ROOT LICENSE]] &&
            [string match {*Vincent Vercauteren*} [read_text [file join $deployed NOTICE-examplemath.txt]]]}]
        set result [run_utf8 -timeout 5s -- $image 2147483647 2147483647]
        check "$host extension: adjacent stubs DLL loads from unrelated cwd" [expr {
            [dict get $result status] eq "ok" && [string trim [dict get $result out]] eq "4294967294"}]
        set result [run_utf8 -timeout 5s -- $image 2147483648 1]
        check "$host extension: native argument bounds fail clearly" [expr {
            [dict get $result exit] == 1 && [string match {*signed 32-bit integers*} [dict get $result err]]}]
        file copy -force [file join $deployed examplemath.dll] [file join $unrelated examplemath.dll]
        file rename [file join $deployed examplemath.dll] [file join $deployed examplemath.dll.absent]
        set result [run_utf8 -timeout 5s -- $image 1 2]
        check "$host extension: missing adjacent DLL never falls back to cwd" [expr {
            [dict get $result exit] == 1 && [string match {*Required adjacent extension is missing:*} [dict get $result err]]}]
    }
    check "examples leave inspected files unchanged" [expr {
        [hash file sha256 [file join $directory {café 雪.txt}]] eq $originalHash}]
    check "examples leave no supervised children" [expr {[child list] eq $originalChildren}]
} finally {
    cd $originalDirectory
    if {[file dirname [file normalize $WORK]] ne $TEMP_ROOT} { error "refusing escaped example cleanup" }
    file delete -force $WORK
}
puts "$checks example packaging checks, $fails failures"
exit [expr {$fails != 0}]
