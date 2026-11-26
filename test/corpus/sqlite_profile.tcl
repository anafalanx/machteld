# Three generations of the same application share one durable SQLite profile.
proc ::corpus::profileGeneration {ctx name version sql} {
    set original [file join [dict get $ctx repo] test corpus apps sqlite-profile]
    set staged [file join [dict get $ctx root] stage-$name]
    file copy -- $original $staged
    if {$version != 1} {
        ::machteld::publish bytes [file join $staged version.txt] $version
        ::machteld::publish bytes [file join $staged migration.sql] $sql
    }
    return [build $ctx $staged $name]
}

proc ::corpus::profileResult {ctx prefix args} {
    set result [run $ctx $prefix {*}$args]
    set reply [string trim [dict get $result out]]
    # Accept application errors only when both the protocol and exit status
    # identify them. A crash, timeout or host error must fail the scenario.
    if {![dict exists $reply ok] || [dict get $reply ok] ni {0 1}} {
        error "invalid profile app reply to [lindex $args 0]: $result"
    }
    set process [list [dict get $result status] [dict get $result exit]]
    if {([dict get $reply ok] && $process ne {ok 0}) ||
            (![dict get $reply ok] && $process ne {error 20})} {
        error "unexpected profile app exit for [lindex $args 0]: $result"
    }
    return $reply
}

proc ::corpus::sqlite_profile {ctx} {
    package require sqlite3
    set goodSql {CREATE TABLE sample_tag(id INTEGER PRIMARY KEY REFERENCES sample(id), tag TEXT NOT NULL);
                 INSERT INTO sample_tag SELECT id,'migrated' FROM sample;}
    set one [profileGeneration $ctx original 1 {}]
    set broken [profileGeneration $ctx broken 2 "$goodSql INSERT INTO sample_tag VALUES(1,'duplicate');"]
    set two [profileGeneration $ctx upgraded 2 $goodSql]
    set current [install $ctx $one]
    set old [install $ctx $one retained]
    set data [file join [dict get $ctx root] {application data}]
    file mkdir $data
    set profile [file join $data {example profile.sqlite}]
    set brokenBackup [file join $data before-failed-upgrade.db]
    set backup [file join $data before-upgrade.db]
    set label {café 🚉 [section]; $5}
    set initial [dict create version 1 row [list $label 00FF0180]]

    check "first installation seeds a profile" {
        [dict get [profileResult $ctx $current seed $profile $label 00ff0180] value] eq "seeded"}
    sqlite3 ::corpus::observedDb $profile -readonly 1 -create 0
    try {
        check "the on-disk profile uses WAL" {[observedDb onecolumn {PRAGMA journal_mode}] eq "wal"}
    } finally {observedDb close}
    check "a new process reads Unicode text and exact blob bytes" {
        [dict get [profileResult $ctx $current read $profile] value] eq $initial}

    set replacement [install $ctx $broken]
    check "broken generation replaces the installed app at the same path" {$replacement eq $current}
    set held [::machteld::lock try "$profile.lock"]
    try {
        check "a locked profile rejects migration before creating a backup" {
            [dict get [profileResult $ctx $current upgrade $profile $brokenBackup] code] eq {PROFILE_APP BUSY} &&
            ![file exists $brokenBackup]}
    } finally {::machteld::lock release $held}
    set failed [profileResult $ctx $current upgrade $profile $brokenBackup]
    check "failed migration reports its SQL constraint failure" {
        ![dict get $failed ok] && [string match -nocase {*constraint*} [dict get $failed message]]}
    check "the profile and pre-failure backup retain their original schema and data" {
        [dict get [profileResult $ctx $old read $profile] value] eq $initial &&
        [dict get [profileResult $ctx $old read $brokenBackup] value] eq $initial}

    set retained [::machteld::hash file sha256 $brokenBackup]
    set replacement [install $ctx $two]
    check "corrected generation replaces the installed app at the same path" {$replacement eq $current}
    set collision [profileResult $ctx $current upgrade $profile $brokenBackup]
    check "an existing backup stays byte-identical and blocks the upgrade" {
        [dict get $collision code] eq {MACHTELD SQLITE exists} && [::machteld::hash file sha256 $brokenBackup] eq $retained &&
        [dict get [profileResult $ctx $old read $profile] value] eq $initial}
    check "corrected generation migrates the same profile" {
        [dict get [profileResult $ctx $current upgrade $profile $backup] value] eq "upgraded"}
    check "migration retains the original row and creates the related row" {
        [dict get [profileResult $ctx $current read $profile] value] eq [dict merge $initial {version 2 tags migrated}]}
    check "restart recognizes the current schema without reapplying migration" {
        [dict get [profileResult $ctx $current upgrade $profile $backup] value] eq "current"}
    check "old generation refuses the newer schema" {
        [dict get [profileResult $ctx $old read $profile] code] eq {PROFILE_APP NEWER}}
    set restored [file join $data {restored profile.sqlite}]
    check "old generation restores and reopens the pre-upgrade profile" {
        [dict get [profileResult $ctx $old restore $restored $backup] value] eq "restored" &&
        [dict get [profileResult $ctx $old read $restored] value] eq $initial}
    sqlite3 ::corpus::observedDb $restored -readonly 1 -create 0
    try {
        check "restored database has version one, the original blob and no migrated table" {
            [observedDb onecolumn {PRAGMA user_version}] == 1 &&
            [observedDb eval {SELECT label, typeof(payload), hex(payload) FROM sample}] eq [list $label blob 00FF0180] &&
            [observedDb onecolumn {SELECT count(*) FROM sqlite_schema WHERE name='sample_tag'}] == 0}
    } finally {observedDb close}

    set foreign [file join $data unrelated.db]
    sqlite3 ::corpus::observedDb $foreign
    try {observedDb eval {PRAGMA application_id=781; CREATE TABLE unrelated(value)}} finally {observedDb close}
    set before [::machteld::hash file sha256 $foreign]
    set unwanted [file join $data unrelated-backup.db]
    check "an unrelated database keeps its original bytes" {
        [dict get [profileResult $ctx $current upgrade $foreign $unwanted] code] eq {PROFILE_APP FOREIGN} &&
        [::machteld::hash file sha256 $foreign] eq $before && ![file exists $unwanted]}
    if {[dict get $ctx form] in {archive wrapped}} {
        set installed [lsort [glob -tails -directory [home $ctx] *]]
        set expected [lsort [lmap path $current {file tail $path}]]
        check "the installation contains only the files used to launch this form" {
            $installed eq $expected && [llength $current] == ([dict get $ctx form] eq "archive" ? 2 : 1)}
    }
}
