namespace eval ::appcompiler::project {}

proc ::appcompiler::project::requirePacker {} {
    if {![llength [info commands ::machteld::PackArchive]]} {
        return -code error -errorcode {APPCOMPILER PROJECT PACK} \
            "packing requires a Machteld executable with the pack command"
    }
}

proc ::appcompiler::project::fileIdentity {path} {
    set facts [::machteld::canon $path]
    return [list [dict get $facts volume] [dict get $facts file]]
}

# An input on zipfs is protected by preserving its backing archive. A mount
# created from bytes has no disk file to protect.
proc ::appcompiler::project::backingFile {path} {
    while {[lindex [file system $path] 0] eq "zipfs"} {
        set path [lindex [zipfs info $path] 0]
        if {$path eq {} || ![file exists $path]} { return {} }
    }
    return $path
}

proc ::appcompiler::project::outputPath {requested protected} {
    set out [file normalize $requested]
    if {$requested eq {} || [lindex [file system $out] 0] ne "native"} {
        return -code error -errorcode {APPCOMPILER PROJECT OUTPUT} "choose an archive output on disk"
    }
    if {[file exists $out]} {
        set target [fileIdentity $out]
        set checked {}
        foreach path $protected {
            set path [backingFile $path]
            if {$path eq {} || [dict exists $checked $path]} { continue }
            dict set checked $path 1
            if {$target eq [fileIdentity $path]} {
                return -code error -errorcode {APPCOMPILER PROJECT OUTPUT} \
                    "output would replace a project input, its archive, or the compiler: $requested"
            }
        }
    }
    return $out
}

proc ::appcompiler::project::stageBytes {path bytes} {
    file mkdir [file dirname $path]
    set channel [open $path {WRONLY CREAT EXCL BINARY}]
    try { puts -nonewline $channel $bytes } finally { close $channel }
}

proc ::appcompiler::project::pack {manifest output} {
    requirePacker
    set built [build $manifest]
    set manifest [file normalize $manifest]
    set project [dict get $built project]
    set inputs [dict get $project files]
    set root [file dirname $manifest]
    set exe [file normalize [info nameofexecutable]]
    set protected [list $exe $manifest]
    foreach path [dict keys $inputs] { lappend protected [file join $root $path] }
    foreach member $::appcompiler::compilerFiles {
        lappend protected [file join $::appcompiler::compilerDirectory $member]
    }
    set out [outputPath $output $protected]

    set work [file normalize [file tempdir]]
    set identity [fileIdentity $work]
    try {
        set app [file join $work app]
        stageBytes [file join $app main.tcl] [encoding convertto -profile strict utf-8 [dict get $built artifact script]]
        set originals [file join $app project inputs]
        stageBytes [file join $originals application.dict] [dict get $project manifestBytes]
        dict for {name bytes} $inputs { stageBytes [file join $originals $name] $bytes }
        file mkdir [file join $app compiler]
        foreach member $::appcompiler::compilerFiles {
            file copy -- [file join $::appcompiler::compilerDirectory $member] [file join $app compiler $member]
        }
        # This is the implementation dispatched by the host's pack command.
        # Absolute paths keep the operation independent of the caller's cwd.
        ::machteld::PackArchive $app -o $out
    } finally {
        if {![catch {fileIdentity $work} current] && $current eq $identity} {
            catch {file delete -force -- $work}
        }
    }
    return $out
}

proc ::appcompiler::project::rebuild {archive output} {
    requirePacker
    if {![llength [info commands ::machteld::ArchiveEntry]]} {
        return -code error -errorcode {APPCOMPILER PROJECT PACK} \
            "rebuilding requires a Machteld executable that verifies archive inventories"
    }
    set archive [file normalize $archive]
    set output [outputPath $output [list $archive]]
    set name "appcompiler-[binary encode hex [::machteld::hash random 16]]"
    set mount [zipfs mount $archive $name]
    try {
        ::machteld::ArchiveEntry $mount
        return [pack [file join $mount project inputs application.dict] $output]
    } finally { zipfs unmount $mount }
}
