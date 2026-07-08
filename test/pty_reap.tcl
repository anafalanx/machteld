# pty_reap.tcl -- does `pty close` reap the ConPTY host? Run from C:\z\_machteld:
#     build\machteld.exe test\pty_reap.tcl
# Then tell Claude; it reads C:\z\_machteld\pty_reap.txt.
#
# On this machine the pty host is the inbox conhost.exe (OpenConsole.exe is
# Windows Terminal's own host, unrelated). We watch BOTH: the DELTA around each
# spawn/close is the signal. A clean host reaps -- the count that rose at spawn
# falls back after close. Note: `exec tasklist` is itself a console process, so
# expect +/-1 jitter on conhost; a persistent climb (1..2..3) is the real tell.

set OUT [file normalize [file join [file dirname [info script]] .. pty_reap.txt]]
set f [open $OUT w]; fconfigure $f -translation lf
proc log {m} { puts $::f $m; flush $::f }

proc n {img base} {
    if {[catch {exec tasklist /nh /fi "IMAGENAME eq $img"} o]} { return -1 }
    return [regexp -all -nocase -- $base $o]
}
proc snap {} { return "conhost=[n conhost.exe conhost]  OpenConsole=[n OpenConsole.exe OpenConsole]" }

log "reap test (machteld [::machteld::version])"
log "baseline:                 [snap]"
for {set i 1} {$i <= 3} {incr i} {
    set p [pty spawn -- cmd]
    after 400
    log "pty #$i spawned:           [snap]"
    pty close $p
    after 1500
    log "pty #$i 1.5s after close:  [snap]"
}
after 2000
log "final (+2s):              [snap]"
close $f
puts "wrote $OUT -- reap test done (this run counts conhost, the real pty host)."
