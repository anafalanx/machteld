# Standalone applications use the same verified application inventory as pack.
# Only full distributions carry the application host template.
proc ::machteld::wrap {args} {
    set input ""; set output ""; set entry ""; set selection ""
    set gui 0; set preview 0
    while {[llength $args]} {
        set args [lassign $args option]
        switch -exact -- $option {
            --console {set gui 0}
            --gui {set gui 1}
            --plan {set preview 1}
            -o - --entry - --manifest {
                set args [lassign $args value]
                if {$value eq ""} {Fail WRAP usage "wrap: $option needs a value"}
                switch -- $option {
                    -o {set output $value}
                    --entry {set entry $value}
                    --manifest {set selection $value}
                }
            }
            default {
                if {[string match -* $option]} {Fail WRAP usage "wrap: unknown option \"$option\""}
                if {$input ne ""} {Fail WRAP usage "wrap: unexpected argument \"$option\""}
                set input $option
            }
        }
    }
    if {$input eq "" || $output eq ""} {
        Fail WRAP usage {usage: wrap input -o app.exe ?--console|--gui? ?--plan? ?--manifest file? ?--entry path?}
    }
    if {![string equal -nocase [file extension $output] .exe]} {Fail WRAP badvalue "wrap: output must have the .exe extension"}
    if {![file exists $input]} {Fail WRAP notfound "wrap: input does not exist: $input"}
    if {![llength [info commands ::machteld::WrapTemplate]] ||
            ![file isfile [file join [PayloadRoot] basekit app.exe]]} {
        Fail WRAP unsupported "wrap: this host carries no standalone application template"
    }
    try {
        if {[file isfile $input] && [string equal -nocase [file extension $input] .machteld]} {
            if {$entry ne ""} {Fail WRAP usage "wrap: --entry applies only to directories"}
            set snapshot [_pack_snapshot $input]
            WithAppArchive $input root {
                _wrap_build [_wrap_archive_plan $root $selection $snapshot] $output $gui $preview
            }
        } else {
            _wrap_build [_pack_plan $input $entry $selection] $output $gui $preview
        }
    } trap {MACHTELD PACK} {message options} {
        Fail WRAP [lindex [dict get $options -errorcode] 2] [regsub {^pack:} $message {wrap:}]
    } trap {MACHTELD ENTRY} {message options} {
        Fail WRAP [lindex [dict get $options -errorcode] 2] "wrap: $message"
    } trap {MACHTELD PUBLISH} {message options} {
        Fail WRAP [lindex [dict get $options -errorcode] 2] "wrap: $message"
    } trap {MACHTELD WRAP} {message options} {
        return -options $options $message
    } on error {message options} {
        Fail WRAP oserror "wrap: $message"
    }
}

proc ::machteld::_wrap_archive_plan {root manifest snapshot} {
    set entryPath [ArchiveEntry $root "" files]
    set entry [string range $entryPath [expr {[string length $root] + 1}] end]
    set members [lsort [dict keys $files]]
    set metadata {}; set manifestSnapshot {}
    if {$manifest ne ""} {
        _pack_no_links $manifest
        set spec [_pack_manifest [file normalize $manifest]]
        set declared [lmap name [dict get $spec files] {_pack_relative $name}]
        if {[dict get $spec entry] ne $entry || [lsort $declared] ne $members} {
            Fail WRAP badvalue "wrap: manifest entry and files must match the verified application archive"
        }
        set metadata [dict get $spec metadata]
        set manifestSnapshot [dict get $spec snapshot]
    }
    set entries {}
    foreach name $members {lappend entries [file join $root $name] $name}
    set bytes [encoding convertto -profile strict utf-8 [dict create schema 1 entry $entry files $files]]
    set parent [file dirname [file normalize [dict get $snapshot path]]]
    return [dict create entry $entry entryPath $entryPath inventory $files entries $entries indexBytes $bytes \
        single 1 sourceCanon [canon $parent] records {} metadata $metadata \
        manifestSnapshot $manifestSnapshot archiveSnapshot $snapshot]
}

proc ::machteld::_wrap_verify_inputs {plan icon} {
    if {[dict exists $plan archiveSnapshot]} {
        set before [dict get $plan archiveSnapshot]
        if {![_pack_same_snapshot $before [_pack_snapshot [dict get $before path]]]} {
            Fail WRAP badvalue "wrap: input archive changed while packaging"
        }
        set before [dict get $plan manifestSnapshot]
        if {$before ne {} && ![_pack_same_snapshot $before [_pack_snapshot [dict get $before path]]]} {
            Fail WRAP badvalue "wrap: project manifest changed while packaging"
        }
    } else {
        dict with plan {}
        _pack_verify_inputs $sourceRoot [_canon_key $sourceCanon] $selected $records \
            [expr {!$single && $manifestSnapshot eq {}}] $manifestSnapshot
    }
    if {$icon ne {} && ![_pack_same_snapshot $icon [_pack_snapshot [dict get $icon path]]]} {
        Fail WRAP badvalue "wrap: icon changed while packaging"
    }
}

proc ::machteld::_wrap_bytes {path bytes} {
    set channel [open $path {WRONLY CREAT EXCL BINARY}]
    try {puts -nonewline $channel $bytes} finally {close $channel}
}

proc ::machteld::_wrap_build {plan output gui preview} {
    set out [file normalize $output]
    set entryPath [dict get $plan entryPath]
    set manifest [dict get $plan manifestSnapshot]
    set metadata [dict get $plan metadata]
    set stem [file rootname [file tail $out]]
    if {$metadata eq {}} {set metadata [dict create name $stem version 0.0.0.0]}
    dict set metadata internal_name $stem
    dict set metadata original_filename [file tail $out]
    set icon {}
    if {[dict exists $metadata icon] && [dict get $metadata icon] ne ""} {
        set path [dict get $metadata icon]
        if {[file pathtype $path] eq "relative"} {
            set path [file join [file dirname [dict get $manifest path]] $path]
        }
        _pack_no_links $path
        set path [file normalize $path]
        if {[file isfile $path] && [file size $path] > 16777216} {Fail WRAP badvalue "wrap: icon exceeds 16 MiB"}
        set icon [_pack_snapshot $path]
        dict set metadata icon $path
    }
    set native [ValidateIdentity $metadata]
    set metadata $native
    dict set metadata icon [expr {$icon eq {} ? {} : [dict create bytes [dict get $icon bytes] sha256 [dict get $icon sha256]]}]
    set mainInput [expr {[dict exists $plan archiveSnapshot] ? [dict get $plan archiveSnapshot path] : $entryPath}]
    set existing [_pack_destination $out [dict get $plan sourceCanon] [canon $mainInput] [dict get $plan single]]
    if {$existing ne {}} {
        foreach record [concat [dict values [dict get $plan records]] [list $manifest $icon]] {
            if {$record ne {} && [_canon_key $existing] eq [dict get $record identity]} {
                Fail WRAP badvalue "wrap: output cannot replace a selected input, manifest or icon"
            }
        }
    }
    EntryCheck $entryPath -inspect
    set appEntry "app/[dict get $plan entry]"
    set appInfo [dict create schema 1 entry $appEntry host [expr {$gui ? "gui" : "console"}] \
        with_docs 0 metadata $metadata runtime [dict create name Machteld version [version] author {Vincent Vercauteren}] \
        files [dict get $plan inventory]]
    if {$preview} {
        _wrap_verify_inputs $plan $icon
        return $appInfo
    }
    lassign [_new_workdir [file dirname $out]] work workKey
    try {
        set stage [file join $work stage]
        set app [file join $stage app]
        file mkdir $app
        set root [PayloadRoot]
        # Copy these trusted runtime roots by name. The manual, the app
        # template and other distribution-only files never enter the image.
        foreach name {tcl_library tcl9 tk_library licenses machteld.tcl} {
            file copy [file join $root $name] [file join $stage $name]
        }
        foreach {path member} [dict get $plan entries] {
            set target [file join $app {*}[split $member /]]
            file mkdir [file dirname $target]
            file copy $path $target
        }
        set files [dict get $plan inventory]
        set copied [_pack_archive_inventory $app]
        if {[lsort [dict keys $copied]] ne [lsort [dict keys $files]]} {
            Fail WRAP badvalue "wrap: staged application has a different file list"
        }
        foreach name [dict keys $files] {
            foreach field {bytes sha256} {
                if {[dict get $copied $name $field] ne [dict get $files $name $field]} {
                    Fail WRAP badvalue "wrap: staged application differs from selected input: $name"
                }
            }
        }
        _wrap_bytes [file join $app machteld-inventory.dict] [dict get $plan indexBytes]
        _wrap_bytes [file join $stage app-info.dict] [encoding convertto -profile strict utf-8 $appInfo]
        set bare [file join $work bare.exe]
        WrapTemplate $bare $gui
        if {$icon ne {}} {
            set stagedIcon [file join $work app.ico]
            file copy [dict get $icon path] $stagedIcon
            if {[hash file sha256 $stagedIcon] ne [dict get $icon sha256]} {Fail WRAP badvalue "wrap: staged icon changed"}
            dict set native icon $stagedIcon
        }
        StampIdentity $bare $native
        set archiveTime [clock scan 2000-01-01T12:00:00 -format %Y-%m-%dT%H:%M:%S -timezone :localtime]
        set entries [_zip_entries $stage]
        foreach {path name} $entries {
            if {[file attributes $path -readonly]} {file attributes $path -readonly 0}
            file mtime $path $archiveTime
        }
        set candidate [file join $work candidate.exe]
        set inventory [_pack_archive_inventory $stage]
        zipfs lmkimg $candidate $entries {} $bare
        _pack_verify_candidate $candidate $inventory $appEntry app
        _wrap_verify_inputs $plan $icon
        Publish $candidate $out
    } finally {
        if {![catch {canon $work} identity] && [_canon_key $identity] eq $workKey} {
            catch {file delete -force -- $work}
        }
    }
    return $out
}

::machteld::MetaDefine wrap [dict create kind tcl args args domain WRAP \
    codes {badvalue encoding inventory notfound optin oserror syntax unsupported usage version} \
    options {--console --entry --gui --manifest --plan -o} doc machteld/command/wrap]
