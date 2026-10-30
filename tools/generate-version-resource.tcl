# Generate one Windows VERSIONINFO resource from Machteld's canonical header.
#
# Usage:
#   tclsh generate-version-resource.tcl HEADER console|gui OUTPUT.rc
#
# machteld's version is one natural number, and the string version is exactly
# as authored in the header. Windows' fixed numeric version has four fields,
# so the other three are zero: 22 is 22.0.0.0.

if {[llength $argv] != 3} {
    puts stderr "usage: generate-version-resource.tcl HEADER console|gui OUTPUT.rc"
    exit 2
}
lassign $argv header kind output

if {$kind ni {console gui}} {
    puts stderr "generate-version-resource.tcl: kind must be console or gui"
    exit 2
}

set channel [open $header r]
fconfigure $channel -encoding utf-8 -translation lf
try {
    set text [read $channel]
} finally {
    close $channel
}

set pattern {(?m)^#define[ \t]+MACHTELD_VERSION[ \t]+"([1-9][0-9]*)"[ \t]*$}
if {![regexp $pattern $text -> version]} {
    puts stderr "generate-version-resource.tcl: canonical MACHTELD_VERSION is absent"
    exit 1
}

set numeric {}
foreach component [list $version 0 0 0] {
    scan $component %d number
    if {$number < 0 || $number > 65535} {
        puts stderr "generate-version-resource.tcl: version component is outside 0..65535"
        exit 1
    }
    lappend numeric $number
}
set fixed [join $numeric ,]

if {$kind eq "console"} {
    set description "machteld runtime"
    set internalName "machteld"
    set originalFilename "machteld.exe"
} else {
    set description "Machteld GUI application host"
    set internalName "machteld-gui"
    set originalFilename "machteld-gui.exe"
}

file mkdir [file dirname [file normalize $output]]
set channel [open $output w]
fconfigure $channel -encoding utf-8 -translation lf
try {
    puts $channel "1 VERSIONINFO"
    puts $channel " FILEVERSION $fixed"
    puts $channel " PRODUCTVERSION $fixed"
    puts $channel { FILEFLAGSMASK 0x3fL}
    puts $channel { FILEFLAGS 0x0L}
    puts $channel { FILEOS 0x00040004L}
    puts $channel { FILETYPE 0x1L}
    puts $channel { FILESUBTYPE 0x0L}
    puts $channel {BEGIN}
    puts $channel {    BLOCK "StringFileInfo"}
    puts $channel {    BEGIN}
    puts $channel {        BLOCK "040904B0"}
    puts $channel {        BEGIN}
    foreach {name value} [list \
            Author "Vincent Vercauteren" \
            CompanyName "Vincent Vercauteren" \
            FileDescription $description \
            FileVersion $version \
            InternalName $internalName \
            LegalCopyright "Copyright 2026 Vincent Vercauteren" \
            OriginalFilename $originalFilename \
            ProductName Machteld \
            ProductVersion $version] {
        puts $channel "            VALUE \"$name\", \"$value\\0\""
    }
    puts $channel {        END}
    puts $channel {    END}
    puts $channel {    BLOCK "VarFileInfo"}
    puts $channel {    BEGIN}
    puts $channel {        VALUE "Translation", 0x0409, 1200}
    puts $channel {    END}
    puts $channel {END}
} finally {
    close $channel
}

puts "version-resource: $kind $version -> [file nativename $output]"
