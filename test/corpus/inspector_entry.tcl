package require machteld

# The staged test app selects this entry and keeps all five shipped Inspector
# scripts intact. Observe real process starts without changing worker arguments,
# JSON output, or the app's choice of worker command.
set here [file dirname [info script]]
if {[info exists env(MACHTELD_CORPUS_INSPECTOR)] && [lindex $argv 0] in {--headless --worker}} {
    lassign $env(MACHTELD_CORPUS_INSPECTOR) records expectedOrigin
    set role [string range [lindex $argv 0] 2 end]
    if {[file normalize $argv0] ne $expectedOrigin} {error "unexpected $role origin: $argv0"}
    set receipt [dict create pid [pid] origin $argv0 \
        worker_sha256 [hash file sha256 [file join $here inspect.tcl]]]
    publish bytes [file join $records $role.dict] [encoding convertto utf-8 $receipt]

    # Swap the archive only after its controller entered the old generation
    # and before the unmodified Inspector creates its worker.
    set update [file join $records update.machteld]
    if {$role eq "headless" && [file exists $update]} {
        if {[file extension $expectedOrigin] ne ".machteld"} {error "expected an archive"}
        publish file $expectedOrigin $update
    }
}
source -encoding utf-8 [file join $here main.tcl]
