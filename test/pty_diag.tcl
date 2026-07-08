# pty_diag.tcl -- capture a ConPTY child's output to a FILE with flushed
# checkpoints, so even if teardown hangs the file has the VT stream AND shows
# exactly where it wedged. The file is closed BEFORE the risky pty close, so a
# hang there can't lose data. Run from C:\z\_machteld:
#     build\machteld.exe test\pty_diag.tcl
# Writes C:\z\_machteld\pty_diag.txt. If it hangs: Ctrl-C / close the window;
# the file is already complete.

set OUT [file normalize [file join [file dirname [info script]] .. pty_diag.txt]]
set f [open $OUT w]
fconfigure $f -translation lf
proc log {msg} { puts $::f $msg; flush $::f }
proc esc {s} {
    set o ""
    foreach ch [split $s ""] {
        scan $ch %c c
        if {$c == 27} { append o "<ESC>" } elseif {$c == 13} { append o "<CR>" } \
        elseif {$c == 10} { append o "<LF>\n" } elseif {$c == 9} { append o "<TAB>" } \
        elseif {$c < 32 || $c == 127} { append o [format "<%02X>" $c] } else { append o $ch }
    }
    return $o
}

log "machteld [::machteld::version]  --  ConPTY diagnostic"
log "CHECKPOINT: about to pty spawn"
set p [pty spawn -- cmd]
log "CHECKPOINT: spawned $p"

set b ""
for {set i 0} {$i < 25} {incr i} { append b [pty read $p -timeout 100] }
log "CHECKPOINT: banner read ([string length $b] bytes)"
log "--- banner (escaped) ---"
log [esc $b]

log "CHECKPOINT: about to send 'echo DIAG-MARKER-123'"
if {[catch {pty send $p "echo DIAG-MARKER-123\r"} e]} { log "  (pty send failed: $e -- expected in a headless sandbox)" }
set r ""
for {set i 0} {$i < 30} {incr i} {
    append r [pty read $p -timeout 100]
    if {[string match *DIAG-MARKER-123* $r]} break
}
log "CHECKPOINT: response read ([string length $r] bytes, marker seen: [string match *DIAG-MARKER-123* $r])"
log "--- response (escaped) ---"
log [esc $r]

log "CHECKPOINT: about to send 'exit'"
catch {pty send $p "exit\r"}
after 300
log "CHECKPOINT: capture complete; about to pty close (if this is the LAST line, close hung)"
close $f

pty close $p

set f [open $OUT a]
puts $f "CHECKPOINT: pty close returned cleanly -- no hang"
close $f
puts "wrote $OUT (complete)"
