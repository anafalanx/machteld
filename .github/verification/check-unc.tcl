package require machteld
set root [file normalize [lindex $argv 0]]
if {![string match {//*} $root]} { error "expected a UNC pathname, got <$root>" }
puts "Read publication directory <$root>"
set work [file tempdir [file join $root "sample-generation-"]]
try {
    if {![string equal -nocase [file normalize [file dirname $work]] $root]} {
        error "temporary directory <$work> outside expected UNC location <$root>"
    }
    set file [file join $work "small marker 雪"]
    set channel [open $file w]
    puts -nonewline $channel "marker"
    close $channel
    set channel [open $file r]
    set contents [read $channel]
    close $channel
    if {$contents ne "marker"} { error "SMB marker round trip failed" }
    puts "PASS UNC and Tcl Unicode marker in <$work>"
} finally {
    file delete -force $work
}
