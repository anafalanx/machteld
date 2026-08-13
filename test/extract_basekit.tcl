# Extract the console basekit from a packaged Machteld image for the entry
# suite's damaged/missing-payload refusal check.

if {[llength $argv] != 2} {
    puts stderr {usage: extract_basekit.tcl MACHTELD-IMAGE OUTPUT}
    exit 2
}
lassign $argv image output
set image [file normalize $image]
set output [file normalize $output]
if {![file isfile $image]} { error "Machteld image not found: $image" }
if {[file exists $output]} { error "basekit output already exists: $output" }

set mount machteld-entry-basekit-[pid]
zipfs mount $image $mount
try {
    set embedded [file join //zipfs:/$mount basekit console.exe]
    if {![file isfile $embedded]} { error "packaged console basekit is missing: $embedded" }
    file copy $embedded $output
} finally {
    zipfs unmount $mount
}
if {![file isfile $output]} { error "basekit extraction produced no file: $output" }
