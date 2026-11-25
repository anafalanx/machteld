# Optional publication directory can be a Windows UNC share.
package require machteld
proc check {label condition} {
    if {!$condition} {error "FAILED: $label"}
    puts "ok   $label"
}
proc writeText {path text} {
    set f [open $path w]
    try {
        fconfigure $f -translation lf -encoding utf-8
        puts $f $text
    } finally {close $f}
}
proc invoke {args} {
    set r [run -timeout 30s -- {*}$args]
    if {[dict get $r status] ne "ok" || [dict get $r exit] != 0} {
        error "application failed: $r"
    }
    return [string trim [encoding convertfrom -profile strict utf-8 [dict get $r out]]]
}
if {[llength $argv] > 1} {error "usage: app_launch_test.tcl ?publication-directory?"}
if {[llength $argv]} {
    set base [file tempdir [file join [lindex $argv 0] machteld-launch-]]
} else {
    set base [file tempdir]
}
set exe [info nameofexecutable]
set child {}
try {
    set source [file join $base {source app}]
    file mkdir $source
    set main [file join $source main.tcl]
    set archive [file join $base {répertoire partagé.machteld}]
    set asset [file join $source value.txt]
    set signal [file join $base go]
    set ready [file join $base ready]
    set fixture {package require machteld
fconfigure stdout -encoding utf-8 -translation lf
set root [file dirname [info script]]
proc versionText {} {
    set f [open [file join $::root value.txt] r]
    try {return [string trim [read $f]]} finally {close $f}
}
switch -- [lindex $argv 0] {
    parent {
        lassign $argv role ready go
        set pool [pool create -width 1 -- {*}[app launch] serve]
        pool call $pool [dict create op identity]
        set before [dict get [lindex [pool wait $pool -timeout 10s] 0] result]
        set f [open $ready w]
        puts $f [app launch]
        close $f
        set deadline [expr {[clock milliseconds] + 15000}]
        while {![file exists $go] && [clock milliseconds] < $deadline} {after 20}
        if {![file exists $go]} {error "timed out waiting for publication"}
        set r [run -timeout 10s -- {*}[app launch] child {two words} {-option}]
        if {[dict get $r exit] != 0} {error $r}
        pool call $pool [dict create op identity]
        set after [dict get [lindex [pool wait $pool -timeout 10s] 0] result]
        pool close $pool
        if {$before ne $after || [lindex $after 1] ne [versionText]} {
            error "published update displaced a warm archive worker"
        }
        puts [list [versionText] [string trim [encoding convertfrom -profile strict utf-8 [dict get $r out]]]]
    }
    child {puts [list [versionText] $argv0 [lrange $argv 1 end]]}
    serve {worker on identity {} {list [pid] [versionText]}; worker serve}
    mark {set f [open [lindex $argv 1] w]; close $f}
    folders {puts [list [app data local] [app data roaming]]}
    prefix {
        set original [app launch]
        set argv0 changed
        cd [file dirname [pwd]]
        puts [expr {$original eq [app launch]}]
    }
    default {error "unknown role"}
}}
    writeText $main $fixture
    writeText $asset A
    check "direct prefix captures the absolute startup script" [expr {
        [app launch] eq [list $exe [file normalize [info script]]]}]
    check "changing working directory and argv0 preserves the captured prefix" \
        [expr {[invoke $exe $main prefix] eq "1"}]
    invoke $exe pack $source -o $archive
    set folders [list [app data local] [app data roaming]]
    set ps [file join $env(SystemRoot) System32 WindowsPowerShell v1.0 powershell.exe]
    set query {[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        [Environment]::GetFolderPath('LocalApplicationData', 'DoNotVerify')
        [Environment]::GetFolderPath('ApplicationData', 'DoNotVerify')}
    set actual [lmap path [split [invoke $ps -NoLogo -NoProfile -NonInteractive -Command $query] \n] {
        string map [list \\ /] [string trimright $path \r]
    }]
    check "local and roaming locations match the Windows profile" [expr {$folders eq $actual &&
        [file pathtype [lindex $folders 0]] eq "absolute" && [file pathtype [lindex $folders 1]] eq "absolute"}]
    check "direct and archived applications resolve the same user data" [expr {
        [invoke $exe $main folders] eq $folders && [invoke $exe $archive folders] eq $folders}]
    foreach arguments {{data} {data local extra} {data unsupported}} {
        check "app rejects invalid data query $arguments" [expr {
            [catch {app {*}$arguments} msg opts] && [dict get $opts -errorcode] eq {MACHTELD APP usage}}]
    }
    set child [child start -timeout 30s -- $exe $archive parent $ready $signal]
    set deadline [expr {[clock milliseconds] + 12000}]
    while {(![file exists $ready] || [file size $ready] == 0) &&
            [clock milliseconds] < $deadline && [dict get [child info $child] running]} {after 25}
    if {![file exists $ready] || [file size $ready] == 0} {
        error "archive reader failed to become ready: [child wait $child -timeout 0ms]"
    }
    set f [open $ready r]
    try {set pinned [string trim [read $f]]} finally {close $f}
    set ticket [lindex $pinned end]
    check "workers carry the complete captured archive SHA-256" [expr {
        [lindex $ticket end] eq [hash file sha256 $archive]}]
    set changed [lreplace $pinned end end [lreplace $ticket end end [string repeat 0 64]]]
    set marker [file join $base should-not-start]
    set refused [run -timeout 10s -- {*}$changed mark $marker]
    check "a mismatched expected digest fails before any archive code runs" [expr {
        [dict get $refused exit] != 0 && [string match {*SHA-256 mismatch*} [dict get $refused err]] &&
        ![file exists $marker]}]
    writeText $asset B
    invoke $exe pack $source -o $archive
    set origin [file normalize $archive]
    check "a fresh launch sees the published generation" [expr {
        [invoke $exe $archive child] eq [list B $origin {}]}]
    writeText $signal go
    set result [child wait $child -timeout 15s]
    set reply [string trim [encoding convertfrom -profile strict utf-8 [dict get $result out]]]
    check "the old parent and its new worker read their original assets and arguments" [expr {
        [dict get $result exit] == 0 && $reply eq [list A [list A $origin {{two words} -option}]]}]
    child close $child
    set child {}
    set stale [run -timeout 10s -- {*}$pinned child]
    check "an expired generation refuses to launch" [expr {
        [dict get $stale exit] != 0 && [string match {*generation*} [dict get $stale err]]}]
    check "app reports usage for unknown operations" [expr {
        [catch {app other} msg opts] && [dict get $opts -errorcode] eq {MACHTELD APP usage}}]
} finally {
    if {$child ne {}} {catch {child close $child}}
    file delete -force $base
}
puts "ALL APP LAUNCH CHECKS PASSED"
