package require -exact machteld 30

proc check {label expression} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL $label"}
    puts "ok   $label"
}
proc invoke {args} {
    set r [run -dir $::empty -timeout 20s -- {*}$args]
    if {[dict get $r status] ni {ok error} || [dict get $r exit] ni {0 20}} {error "application did not finish: $r"}
    return [string trim [encoding convertfrom -profile strict utf-8 [dict get $r out]]]
}
proc invokeApp {archive args} {invoke $::host $archive {*}$args}
proc install {archive} {
    set path [file join [file dirname $::installed] update-staged.machteld]
    file copy -- $archive $path
    publish file $::installed $path
}
proc packVersion {name version sql} {
    publish bytes [file join $::src version.txt] $version
    publish bytes [file join $::src migration.sql] $sql
    set target [file join $::base $name.machteld]
    invoke [info nameofexecutable] pack $::manifest -o $target
    return $target
}
set base [file tempdir]
set empty [file join $base {empty cwd}]
set src [file join $base source]
set home [file join $base {移動 installation}]
set data [file join $base {application data}]
try {
    foreach dir [list $empty $src $home $data] {file mkdir $dir}
    set host [file join $home machteld.exe]
    file copy -- [info nameofexecutable] $host
    file copy -- [file join [file dirname [info script]] fixtures profile_app.tcl] [file join $src main.tcl]
    set manifest [file join $src project.dict]
    publish bytes $manifest [dict create schema 1 entry main.tcl files {main.tcl version.txt migration.sql}]
    set goodSql {CREATE TABLE sample_tag(id INTEGER PRIMARY KEY REFERENCES sample(id), tag TEXT NOT NULL);
                 INSERT INTO sample_tag SELECT id,'migrated' FROM sample;}
    set one [packVersion original 1 {}]
    set broken [packVersion broken 2 "$goodSql INSERT INTO sample_tag VALUES(1,'duplicate');"]
    set two [packVersion upgraded 2 $goodSql]
    file rename -- $src [file join $base {source unavailable to installed app}]
    set installed [file join $home {inventory app.machteld}]
    set profile [file join $data {example profile.sqlite}]
    set brokenBackup [file join $data before-failed-upgrade.db]
    set backup [file join $data before-upgrade.db]
    set label {café 🚉 [section]; $5}
    set initial [dict create version 1 row [list $label 00FF0180]]
    install $one
    check "relocated Tcl-only archive creates a synthetic WAL profile" {
        [dict get [invokeApp $installed seed $profile $label 00ff0180] value] eq "seeded"}
    check "new application process reads Unicode text and exact blob bytes" {
        [dict get [invokeApp $installed read $profile] value] eq $initial}
    install $broken
    set held [lock try "$profile.lock"]
    try {
        check "another process cannot migrate a locked profile or create a backup" {
            [dict get [invokeApp $installed upgrade $profile $brokenBackup] code] eq {PROFILE_APP BUSY} && ![file exists $brokenBackup]}
    } finally {lock release $held}
    set failed [invokeApp $installed upgrade $profile $brokenBackup]
    check "failed migration reports the SQL constraint failure" {
        ![dict get $failed ok] && [string match -nocase {*constraint*} [dict get $failed message]]}
    check "failed migration preserves version-one data and its recoverable backup" {
        [dict get [invokeApp $one read $profile] value] eq $initial &&
        [dict get [invokeApp $one read $brokenBackup] value] eq $initial}
    set retained [hash file sha256 $brokenBackup]
    install $two
    set collision [invokeApp $installed upgrade $profile $brokenBackup]
    check "an existing backup cannot be overwritten or an upgrade partially applied" {
        [dict get $collision code] eq {MACHTELD SQLITE exists} && [hash file sha256 $brokenBackup] eq $retained &&
        [dict get [invokeApp $one read $profile] value] eq $initial}
    check "published replacement migrates the same profile" {
        [dict get [invokeApp $installed upgrade $profile $backup] value] eq "upgraded"}
    check "migration keeps original values and creates the related row" {
        [dict get [invokeApp $installed read $profile] value] eq [dict merge $initial {version 2 tags migrated}]}
    check "the new application can be restarted without reapplying its migration" {
        [dict get [invokeApp $installed upgrade $profile $backup] value] eq "current"}
    check "old application refuses the newer on-disk schema" {
        [dict get [invokeApp $one read $profile] code] eq {PROFILE_APP NEWER}}
    set restored [file join $data {restored profile.sqlite}]
    check "old application can restore and reopen the verified pre-upgrade profile" {
        [dict get [invokeApp $one restore $restored $backup] value] eq "restored" &&
        [dict get [invokeApp $one read $restored] value] eq $initial}
    package require sqlite3
    set foreign [file join $data unrelated.db]
    sqlite3 foreignDb $foreign
    try {foreignDb eval {PRAGMA application_id=781; CREATE TABLE unrelated(value)}} finally {foreignDb close}
    set before [hash file sha256 $foreign]
    set unwanted [file join $data unrelated-backup.db]
    check "an unrelated database keeps its original bytes" {
        [dict get [invokeApp $two upgrade $foreign $unwanted] code] eq {PROFILE_APP FOREIGN} &&
        [hash file sha256 $foreign] eq $before && ![file exists $unwanted]}
    check "the relocated installation contains only the common host and Tcl app archive" {
        [lsort [glob -tails -directory $home *]] eq [list {inventory app.machteld} machteld.exe]}
} finally {file delete -force -- $base}
