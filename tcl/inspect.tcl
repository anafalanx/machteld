# Shell inspection shares the entry parser, packaging inventory and live
# command manifest. All inspected application inputs remain data.
proc ::machteld::InspectCheck {args} {
    if {[llength $args] != 1 || [lindex $args 0] eq ""} {
        Fail CHECK usage "usage: --check script-or-directory-or-project.dict-or-archive.machteld ?--json?"
    }
    set input [lindex $args 0]
    set path $input
    try {
        if {![file exists $input]} { Fail CHECK notfound "target does not exist: $input" }
        set target [file normalize $input]
        set path $target
        if {[file isfile $input] && [string equal -nocase [file extension $input] ".machteld"]} {
            set kind archive
            set mount "machteld-check-[binary encode hex [hash random 16]]"
            if {[catch {zipfs mount $target $mount} message]} { Fail ENTRY inventory $message }
            try {
                set root //zipfs:/$mount
                set entryPath [ArchiveEntry $root files]
                set entry [string range $entryPath [expr {[string length $root] + 1}] end]
                set path "$target!/$entry"
                EntryCheck $entryPath -inspect
            } finally { zipfs unmount $mount }
        } else {
            set plan [_pack_plan $input]
            set path [dict get $plan entryPath]
            set kind [expr {[dict get $plan project] ? "project" : [dict get $plan single] ? "script" : "directory"}]
            set entry [expr {$kind eq "script" ? [file tail $path] : [dict get $plan entry]}]
            set files [dict size [dict get $plan records]]
            EntryCheck $path -inspect
        }
    } on error {message options} {
        dict set options -inspection-path $path
        return -options $options $message
    }
    return [dict create schema 1 kind $kind path $target entry $entry files $files \
        executed 0 doc machteld/application/host]
}

# Only source the shipped package indices inside the pinned executable to
# discover lazy registrations. Never run a loader or search ambient auto_path.
proc ::machteld::InspectPackages {} {
    set packages [dict create Tcl tcl/command/package Tk tk/command/tk machteld machteld/application/host \
        sqlite3 machteld/package/sqlite3 cffi machteld/package/cffi]
    set library [file join [PayloadRoot] tcl_library]
    foreach dir [glob -nocomplain -types d -directory $library machteld-*] {
        set name [string range [file tail $dir] [string length machteld-] end]
        source -encoding utf-8 [file join $dir pkgIndex.tcl]
        dict set packages machteld::$name machteld/package/$name
    }
    return $packages
}

proc ::machteld::InspectManifest {args} {
    set manifest [manifest]
    if {![llength $args]} {
        return [dict create schema 1 version [version] commands [lsort [dict keys $manifest]] \
            packages [lsort [dict keys [InspectPackages]]] probed 0]
    }
    lassign $args selector name detail
    if {$selector eq "command" && [llength $args] in {2 3}} {
        if {![dict exists $manifest $name]} { Fail MANIFEST notfound "unknown public command: $name" }
        set facts [dict get $manifest $name]
        set result [dict create schema 1 command $name]
        if {[llength $args] == 3} {
            if {![dict exists $facts subcommands $detail]} {
                Fail MANIFEST notfound "unknown subcommand of $name: $detail"
            }
            dict set result subcommand $detail
            set facts [dict get $facts subcommands $detail]
        }
        dict set result facts $facts
        return $result
    }
    if {$selector eq "package" && [llength $args] in {2 3} &&
            ([llength $args] == 2 || $detail eq "--probe")} {
        set packages [InspectPackages]
        if {![dict exists $packages $name]} { Fail MANIFEST notfound "unknown bundled package: $name" }
        set loaded [package provide $name]
        set versions [package versions $name]
        if {$loaded ne ""} { lappend versions $loaded }
        set result [dict create schema 1 package $name versions [lsort -unique $versions] \
            bundled 1 loaded [expr {$loaded ne ""}] probed 0 doc [dict get $packages $name]]
        if {$detail ne "--probe"} { return $result }
        switch -- $name {
            sqlite3 {
                package require sqlite3
                ::sqlite3 ::machteld::InspectDb :memory:
                try {
                    set value [InspectDb onecolumn {
                        CREATE VIRTUAL TABLE docs USING fts5(body, tokenize='trigram');
                        INSERT INTO docs VALUES ('machteld');
                        SELECT count(*) FROM docs WHERE docs MATCH 'cht';
                    }]
                    if {$value != 1} { Fail MANIFEST probe "SQLite FTS5 trigram probe returned an unexpected result" }
                    dict set result engine [InspectDb onecolumn {SELECT sqlite_version()}]
                    dict set result features {fts5 trigram}
                } finally { InspectDb close }
            }
            machteld::browser {
                package require machteld::browser
                try {
                    dict set result executable [::machteld::browser::Executable {}]
                    dict set result detected 1
                } trap {MACHTELD BROWSER notfound} {} {
                    dict set result detected 0
                }
            }
            default { Fail MANIFEST unsupported "no read-only host probe for package: $name" }
        }
        dict set result loaded 1
        dict set result probed 1
        return $result
    }
    Fail MANIFEST usage "usage: --manifest ?command NAME ?SUBCOMMAND? | package NAME ?--probe?? ?--json?"
}

# The contract's list and dictionary fields need distinct JSON types even
# when empty or when an option has only one possible value.
proc ::machteld::InspectJson {record} {
    set pairs {}
    dict for {key value} $record {
        switch -- $key {
            args - codes - replycodes - options - returns - commands - packages - features - versions {
                set encoded [DocsJStringArray $value]
            }
            qualified_only - executed - loaded - bundled - probed - detected { set encoded [DocsJBool $value] }
            schema - files - line { set encoded [DocsJNumber $value] }
            defaults - limits {
                set fields {}
                dict for {name limit} $value { lappend fields $name [DocsJNumber $limit] }
                set encoded [DocsJObject $fields]
            }
            subcommands {
                set fields {}
                dict for {name facts} $value { lappend fields $name [InspectJson $facts] }
                set encoded [DocsJObject $fields]
            }
            facts { set encoded [InspectJson $value] }
            default { set encoded [DocsJString $value] }
        }
        lappend pairs $key $encoded
    }
    return [DocsJObject $pairs]
}

proc ::machteld::InspectHost {domain command doc argv} {
    set json [expr {"--json" in $argv}]
    try {
        if {$json} {
            set index [lsearch -exact $argv --json]
            set argv [lreplace $argv $index $index]
            if {"--json" in $argv} { Fail $domain usage "duplicate --json option" }
        }
        set result [$command {*}$argv]
        if {$json} { return [DocsJObject [list ok true result [InspectJson $result]]] }
        return $result
    } on error {message options} {
        set code [dict get $options -errorcode]
        if {[lindex $code 0] ne "MACHTELD"} { set code [list MACHTELD $domain oserror] }
        set diagnostic [dict create domain [lindex $code 1] code [lindex $code 2] message $message doc $doc]
        if {[lindex $code 1] eq "PACK"} { dict set diagnostic doc machteld/guide/packaging }
        if {[dict exists $options -inspection-path]} { dict set diagnostic path [dict get $options -inspection-path] }
        if {[lindex $code 1] eq "ENTRY" && [string is integer -strict [lindex $code 3]]} {
            dict set diagnostic line [lindex $code 3]
        }
        if {$json} { set message [DocsJObject [list ok false error [InspectJson $diagnostic]]] }
        return -code error -errorcode $code $message
    }
}

proc ::machteld::CheckHost {args} {
    InspectHost CHECK InspectCheck machteld/application/host $args
}
proc ::machteld::ManifestHost {args} {
    InspectHost MANIFEST InspectManifest machteld/command/manifest $args
}
