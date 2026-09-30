# Build provenance is inert data, separate from the public runtime version.
# Development packages carry this record; historical released artifacts do not.
namespace eval ::machteld::buildidentity {}

proc ::machteld::buildidentity::validate {record} {
    set fields {schema channel runtime_version source_revision input_sha256 reference_sha256}
    if {[catch {llength $record} length] || $length != 2 * [llength $fields]} {
        error "build identity must contain exactly the schema 1 fields"
    }
    set seen {}
    foreach {key value} $record {
        if {$key ni $fields || [dict exists $seen $key]} {
            error "unknown or repeated build identity field: $key"
        }
        dict set seen $key $value
    }
    if {[dict get $seen schema] ne "1" || [dict get $seen channel] ne "development"} {
        error "unsupported build identity schema or channel"
    }
    if {![regexp {^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$} \
            [dict get $seen runtime_version]]} {
        error "invalid runtime version in build identity"
    }
    set revision [dict get $seen source_revision]
    if {$revision ne "unknown" && ![regexp {^([0-9a-f]{40}|[0-9a-f]{64})$} $revision]} {
        error "invalid source revision in build identity"
    }
    foreach key {input_sha256 reference_sha256} {
        if {![regexp {^[0-9a-f]{64}$} [dict get $seen $key]]} {
            error "invalid SHA-256 in build identity: $key"
        }
    }
    set canonical {}
    foreach key $fields { dict set canonical $key [dict get $seen $key] }
    return $canonical
}

proc ::machteld::buildidentity::read {path} {
    set f [open $path rb]
    try { set bytes [::read $f 4097] } finally { close $f }
    if {[string length $bytes] > 4096} { error "build identity exceeds 4096 bytes" }
    set text [encoding convertfrom -profile strict utf-8 $bytes]
    return [validate [string trim $text]]
}

proc ::machteld::buildidentity::write {path record} {
    set record [validate $record]
    set f [open $path {WRONLY CREAT EXCL}]
    try {
        fconfigure $f -encoding utf-8 -translation lf
        puts $f $record
    } finally { close $f }
}

proc ::machteld::buildidentity::create {path runtime revision inputHash referenceHash} {
    write $path [dict create schema 1 channel development runtime_version $runtime \
        source_revision $revision input_sha256 $inputHash reference_sha256 $referenceHash]
}
