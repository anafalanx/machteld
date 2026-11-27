namespace eval ::appcompiler::project {}

proc ::appcompiler::project::invalid {message} {
    return -code error -errorcode {APPCOMPILER PROJECT INVALID} "project: $message"
}

proc ::appcompiler::project::dataDict {value label} {
    if {[catch {llength $value} words] || [catch {dict size $value} size] || $words != 2 * $size} {
        invalid "$label must be a dictionary with unique keys"
    }
    return $value
}

proc ::appcompiler::project::relativePath {path} {
    # Match the packer's Windows rules even when the input is a ZIP member.
    if {[llength [info commands ::machteld::_pack_relative]]} {
        if {[catch {::machteld::_pack_relative $path} path]} {invalid $path}
    } else {
        set path [string map {\\ /} $path]
    }
    if {$path eq "" || [file pathtype $path] ne "relative" || [regexp {[\x00-\x1f\x7f<>:"|?*]} $path]} {
        invalid "expected a portable relative file path, got [list $path]"
    }
    foreach part [split $path /] {
        if {$part in {{} . ..} || [string trimright $part {. }] ne $part ||
            [regexp -nocase {^(con|prn|aux|nul|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³]) *(\.|$)} $part]} {
            invalid "unsafe component in [list $path]"
        }
    }
    return $path
}

# Compare components, not just whole paths. On Windows, A/x and a/y name
# one directory; in a ZIP they would end up in two different directories.
proc ::appcompiler::project::reserve {relative inventoryVar} {
    upvar 1 $inventoryVar inventory
    set prefix {}
    foreach component [split $relative /] {
        if {$prefix ne ""} {append prefix /}
        append prefix $component
        set key [string tolower $prefix]
        set kind [expr {$prefix eq $relative ? "file" : "directory"}]
        if {[dict exists $inventory $key]} {
            lassign [dict get $inventory $key] existing role
            if {$kind ne "directory" || $role ne "directory" || $existing ne $prefix} {
                invalid "colliding project path [list $relative] at [list $existing]"
            }
        } else {
            dict set inventory $key [list $prefix $kind]
        }
    }
}

proc ::appcompiler::project::nativeInput {path cacheVar} {
    upvar 1 $cacheVar cache
    if {[llength [info commands ::machteld::_pack_no_links]]} {
        ::machteld::_pack_no_links $path cache
    } else {
        # Standalone Tcl also checks the original spelling of every ancestor.
        set current {}
        foreach part [file split [file join [pwd] $path]] {
            set current [file join $current $part]
            if {[file type $current] eq "link"} {invalid "linked input [list $current]"}
        }
    }
}

proc ::appcompiler::project::readBytes {path cacheVar} {
    upvar 1 $cacheVar cache
    set fs [lindex [file system $path] 0]
    switch -exact -- $fs {
        native {nativeInput $path cache}
        zipfs {}
        default {invalid "unsupported input filesystem [list $fs]"}
    }
    if {[file type $path] ne "file"} {invalid "expected a regular file: [list $path]"}
    set ch [open $path rb]
    try {return [read $ch]} finally {close $ch}
}

proc ::appcompiler::project::decode {bytes path} {
    if {[catch {encoding convertfrom -profile strict utf-8 $bytes} text]} {
        invalid "invalid UTF-8 in [list $path]"
    }
    # Editors can write a BOM. Keep it in the captured bytes, but omit it
    # from the manifest or source handed to the corresponding parser.
    if {[string index $text 0] eq "\ufeff"} {set text [string range $text 1 end]}
    return $text
}

proc ::appcompiler::project::load {manifest} {
    if {[file pathtype $manifest] eq "volumerelative" || [regexp {^//[.?]/} [string map {\\ /} $manifest]]} {
        invalid "volume-relative or device manifest paths are unsupported"
    }
    set cache {}
    set manifestBytes [readBytes $manifest cache]
    set data [dataDict [decode $manifestBytes $manifest] manifest]
    dict for {key ignored} $data {
        if {$key ni {schema edition minApi entry modules assets}} {invalid "unknown manifest key [list $key]"}
    }
    foreach key {schema edition minApi entry modules} {
        if {![dict exists $data $key]} {invalid "missing manifest key [list $key]"}
    }
    if {[dict get $data schema] ne "1"} {invalid "expected project schema 1"}
    set edition [dict get $data edition]
    if {$edition ne "1"} {invalid "unsupported language edition [list $edition]; supported edition is 1"}
    set minApi [dict get $data minApi]
    if {![regexp {\A[0-9][0-9.ab]*\Z} $minApi] || [catch {package vcompare $minApi 0}]} {
        invalid "minApi must be one concrete Tcl package version"
    }
    set host [package provide machteld]
    if {$host ne "" && [package vcompare $host $minApi] < 0} {
        invalid "minimum Machteld API $minApi is required; this host provides $host"
    }
    set entry [dict get $data entry]
    if {[catch {llength $entry} count] || $count != 2} {invalid "entry must name a module and function"}
    set identifier {\A[A-Za-z_][A-Za-z_0-9]*\Z}
    foreach name $entry {
        if {![regexp $identifier $name]} {invalid "invalid entry identifier [list $name]"}
    }
    set modules [dataDict [dict get $data modules] modules]
    if {![dict exists $modules [lindex $entry 0]]} {invalid "entry module is absent from modules"}
    set inventory {}
    reserve application.dict inventory
    set selected {}
    set names {}
    dict for {module path} $modules {
        if {![regexp $identifier $module]} {invalid "invalid module identifier [list $module]"}
        set folded [string tolower $module]
        if {[dict exists $names $folded]} {invalid "case-colliding module [list $module]"}
        dict set names $folded 1
        set path [relativePath $path]
        reserve $path inventory
        dict set selected $path $module
    }
    set assets [dict getdef $data assets {}]
    if {[catch {llength $assets}]} {invalid "assets must be a list of relative paths"}
    foreach path $assets {
        set path [relativePath $path]
        reserve $path inventory
        dict set selected $path {}
    }
    set root [file dirname $manifest]
    set files {}
    set sources {}
    dict for {path module} $selected {
        set bytes [readBytes [file join $root $path] cache]
        dict set files $path $bytes
        if {$module ne ""} {dict set sources $module [decode $bytes $path]}
    }
    return [dict create edition $edition minApi $minApi sources $sources entry $entry \
        files $files manifestBytes $manifestBytes]
}

proc ::appcompiler::project::build {manifest} {
    set project [load $manifest]
    set artifact [::appcompiler::application [dict get $project sources] {*}[dict get $project entry] \
        [dict get $project minApi]]
    return [dict create project $project artifact $artifact]
}
