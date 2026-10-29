# Focused, headless regressions for ValidateIdentity/StampIdentity. Run with
# identity_driver.exe SCRIPT BARE-CONSOLE BARE-GUI WORKDIR. The caller owns work.
package require machteld
lassign $argv console gui work
file mkdir $work
set checks 0
set failures 0
proc check {name condition {detail ""}} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::failures; puts "FAIL $name $detail" }
}
proc bytes {path data} {
    set ch [open $path wb]
    try { puts -nonewline $ch $data } finally { close $ch }
}
proc slurp {path} {
    set ch [open $path rb]
    try { return [read $ch] } finally { close $ch }
}
proc bad {name metadata} {
    set failed [catch {::machteld::ValidateIdentity $metadata} message options]
    check $name [expr {$failed && [dict get $options -errorcode] eq {MACHTELD WRAP badvalue}}] $message
}
set name "Planning \u03a9 \U0001f680"
set metadata [dict create name $name version 2.7 internal_name tool original_filename tool.exe]
set normalized [::machteld::ValidateIdentity $metadata]
check {normalization retains Unicode and authored short version} [expr {
    [dict get $normalized name] eq $name && [dict get $normalized version] eq "2.7"}]
check {description defaults to name and ownership never defaults to runtime author} [expr {
    [dict get $normalized description] eq $name && [dict get $normalized author] eq "" &&
    [dict get $normalized publisher] eq "" && [dict get $normalized copyright] eq "" &&
    [dict get $normalized icon] eq "" && [dict size $normalized] == 9}]
foreach key {name version internal_name original_filename} {
    bad "missing required $key" [dict remove $metadata $key]
    bad "empty required $key" [dict replace $metadata $key ""]
}
bad {unknown metadata key} [dict merge $metadata {extra no}]
bad {malformed metadata dictionary} {name}
foreach version {0 0.21 1.2.3 65535.65535.65535.65535 01.002} {
    set actual [::machteld::ValidateIdentity [dict replace $metadata version $version]]
    check "valid version $version remains exact" [expr {[dict get $actual version] eq $version}]
}
foreach version {1. 1..2 .1 1.2.3.4.5 65536 -1 +1 1.2-rc1 1,2 {1 2} 1.2.65536 999999999999999999999999} {
    bad "invalid version $version" [dict replace $metadata version $version]
}
foreach value [list "a\0b" "a\nb" "a\rb" "a\tb" "a\u007fb" "a\u0085b" "a\ud800b"] {
    bad {control or malformed Unicode is refused} [dict replace $metadata name $value]
}
check {1024 UTF16 units accepted} [expr {![catch {
    ::machteld::ValidateIdentity [dict replace $metadata name [string repeat \U0001f680 512]]
}]}]
bad {UTF16 unit limit counts non-BMP characters twice} \
    [dict replace $metadata name [string repeat \U0001f680 513]]
bad {ASCII text over limit is refused} [dict replace $metadata name [string repeat a 1025]]
foreach key {internal_name original_filename} {
    foreach value {../tool {C:\tool} directory/tool} {
        bad "private $key must be a leaf spelling" [dict replace $metadata $key $value]
    }
}

# One valid 1x1 32-bit DIB icon, with both the XOR pixel and DWORD AND mask.
# Specify the header explicitly to avoid native structure/alignment assumptions.
set dib [binary decode hex 280000000100000002000000010020000000000004000000000000000000000000000000000000000000ffff00000000]
set ico "[binary decode hex 00000100010001010000010020003000000016000000]$dib"
set icon [file join $work valid.ico]
bytes $icon $ico
set withIcon [dict replace $metadata icon $icon]
check {valid DIB icon validates headlessly} [expr {![catch {
    ::machteld::ValidateIdentity $withIcon
} message]}] $message
proc png_chunk {kind data} {
    return "[binary format I [string length $data]]$kind$data[binary format I [zlib crc32 "$kind$data"]]"
}
set png "[binary decode hex 89504e470d0a1a0a][png_chunk IHDR [binary format IIccccc 1 1 8 6 0 0 0]]"
append png [png_chunk IDAT [zlib compress [binary decode hex 00ff0000ff]]] [png_chunk IEND ""]
set pngIcon [file join $work valid-png.ico]
bytes $pngIcon "[binary decode hex 0000010001000101000001002000][binary format ii [string length $png] 22]$png"
check {valid PNG icon validates headlessly} [expr {![catch {
    ::machteld::ValidateIdentity [dict replace $metadata icon $pngIcon]
} message]}] $message
set multipleIcon [file join $work valid-multiple.ico]
set entryA "[binary decode hex 0101000001002000][binary format ii [string length $dib] 38]"
set entryB "[binary decode hex 0101000001002000][binary format ii [string length $png] [expr {38 + [string length $dib]}]]"
bytes $multipleIcon "[binary decode hex 000001000200]$entryA$entryB$dib$png"
check {multi-image mixed PNG and DIB icon validates headlessly} [expr {![catch {
    ::machteld::ValidateIdentity [dict replace $metadata icon $multipleIcon]
} message]}] $message
set malformed [file join $work malformed.ico]
set invalidIcons [list "" abc [string range $ico 0 20] \
    [string replace $ico 2 3 [binary decode hex 0200]] \
    [string replace $ico 4 5 [binary decode hex 0000]] \
    [string replace $ico 4 5 [binary decode hex 0101]] \
    [string replace $ico 18 21 [binary decode hex ffffffff]] \
    [string replace $ico 14 17 [binary decode hex ffffffff]] \
    [string replace $ico 6 6 [binary decode hex 02]] \
    [string replace $ico 9 9 [binary decode hex 01]] \
    [string replace $ico 26 29 [binary decode hex ffffffff]]]
foreach invalid $invalidIcons {
    bytes $malformed $invalid
    bad {malformed icon container is refused} [dict replace $metadata icon $malformed]
}
bytes $malformed [string repeat x [expr {16 * 1024 * 1024 + 1}]]
bad {oversized icon is refused before decoding} [dict replace $metadata icon $malformed]
set twoHeader [binary decode hex 000001000200]
set entry1 [string range $ico 6 21]
set entry1 [string replace $entry1 12 15 [binary decode hex 26000000]]
bytes $malformed "$twoHeader$entry1$entry1$dib"
bad {overlapping icon image ranges are refused} [dict replace $metadata icon $malformed]

foreach kind {console gui} bare [list $console $gui] {
    set target [file join $work "$kind-\u03a9.exe"]
    file copy $bare $target
    set before [slurp $target]
    set failed [catch {::machteld::StampIdentity $target [dict replace $metadata version nope]} message options]
    check "$kind invalid metadata cannot mutate the bare host" [expr {
        $failed && [dict get $options -errorcode] eq {MACHTELD WRAP badvalue} && [slurp $target] eq $before}]
    set multiple [dict replace $withIcon icon $multipleIcon]
    set stamped [::machteld::StampIdentity $target $multiple]
    check "$kind stamping returns normalized identity" [expr {$stamped eq [::machteld::ValidateIdentity $multiple]}]
    check "$kind stamping actually changes resource bytes" [expr {[slurp $target] ne $before}]
    # Re-stamping also exercises removal/replacement of existing icons rather
    # than accumulating stale IDs. The PS test inspects the resource inventory.
    ::machteld::StampIdentity $target [dict replace $withIcon name "Second $name" version 3.4.5.6]
    set overlay [file join $work $kind-overlay.exe]
    bytes $overlay "[slurp $target]ZIP-PAYLOAD"
    set overlayBefore [slurp $overlay]
    set failed [catch {::machteld::StampIdentity $overlay $metadata} message options]
    check "$kind overlay host is refused unchanged" [expr {
        $failed && [dict get $options -errorcode] eq {MACHTELD WRAP badvalue} && [slurp $overlay] eq $overlayBefore}]
    set signed [file join $work $kind-signed.exe]
    set image [slurp $target]
    binary scan $image @60iu pe
    binary scan $image @[expr {$pe + 24}]su magic
    set security [expr {$pe + 24 + ($magic == 523 ? 112 : 96) + 32}]
    set image [string replace $image $security [expr {$security + 7}] [binary format ii 512 128]]
    bytes $signed $image
    set failed [catch {::machteld::StampIdentity $signed $metadata} message options]
    check "$kind certificate-bearing host is refused unchanged" [expr {
        $failed && [dict get $options -errorcode] eq {MACHTELD WRAP badvalue} && [slurp $signed] eq $image}]
}
if {$failures} { error "$failures of $checks native identity checks failed" }
puts "ALL $checks NATIVE IDENTITY CHECKS PASSED"
