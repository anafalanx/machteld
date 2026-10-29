# Native path rejection must precede any open, creation or publication.
package require machteld
set checks 0
set failures 0
proc check {name condition} {
    incr ::checks
    if {$condition} {puts "ok   $name"} else {puts "FAIL $name"; incr ::failures}
}
proc code {script} {
    if {[catch {uplevel 1 $script} message options]} {return [dict get $options -errorcode]}
    return {}
}
proc writebytes {path bytes} {
    set channel [open $path wb]
    try {puts -nonewline $channel $bytes} finally {close $channel}
}
proc readbytes {path} {
    if {![file exists $path]} {return MISSING}
    set channel [open $path rb]
    try {return [read $channel]} finally {close $channel}
}
set scratch [file tempfile marker machteld-native-filesystem-]
close $scratch
file delete $marker
file mkdir $marker
try {
    set candidate [file join $marker candidate]
    set destination [file join $marker destination]
    foreach suffix [list "\0suffix" "\ud800" "\udfff"] {
        foreach side {candidate destination} {
            writebytes $candidate new
            writebytes $destination original
            set source $candidate
            set target $destination
            if {$side eq "candidate"} {append source $suffix} else {append target $suffix}
            check "publication rejects malformed $side U+[format %04X [scan $suffix %c]]" \
                [expr {[code {::machteld::Publish $source $target}] eq {MACHTELD WRAP badvalue}}]
            check "rejected publication retains candidate" [expr {[readbytes $candidate] eq "new"}]
            check "rejected publication retains destination" [expr {[readbytes $destination] eq "original"}]
        }
        store open
        store put sentinel retained
        set before [lsort [glob -nocomplain -tails -directory $marker *]]
        check "store rejects malformed path" [expr {
            [code {store open "[file join $marker data.db]$suffix"}] eq {MACHTELD STORE badvalue}}]
        check "rejected open retains current store" [expr {
            ![catch {store get sentinel} value] && $value eq "retained"}]
        check "rejected open creates no alternate file" [expr {
            [lsort [glob -nocomplain -tails -directory $marker *]] eq $before}]
        store close
    }
    set unicode [file join $marker "caf\u00e9-\U0001f600.db"]
    store open $unicode
    store put unicode exact
    store close
    check "store creates exact non-BMP filename" [file exists $unicode]
    store open $unicode
    check "Unicode store persists" [expr {[store get unicode] eq "exact"}]
    store close
    set target [file join $marker "published-\U0001f600"]
    writebytes $candidate content
    ::machteld::Publish $candidate $target
    check "valid Unicode publication remains supported" [expr {[readbytes $target] eq "content"}]
} finally {
    catch {store close}
    file delete -force $marker
}
puts "native filesystem: $checks checks, $failures failures"
if {$failures} {exit 1}
