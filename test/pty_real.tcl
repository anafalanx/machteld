# pty_real.tcl -- interactive pty flow on a REAL terminal (send / capture /
# expect), logged to a file so Claude can read the result. Run from
# C:\z\_machteld:   build\machteld.exe test\pty_real.tcl
# Then tell Claude; it reads C:\z\_machteld\pty_real.txt. The headless CI sandbox
# cannot route a child through a pseudo-console, so this interactive path is
# verified here. Host reaping is covered separately by pty_reap.tcl.

set OUT [file normalize [file join [file dirname [info script]] .. pty_real.txt]]
set f [open $OUT w]
fconfigure $f -translation lf
proc log {m} { puts $::f $m; flush $::f }

log "pty real-terminal test  (machteld [::machteld::version])"
set p [pty spawn -- cmd]
log "spawned $p"

# drain cmd's banner + first prompt
set b ""
for {set i 0} {$i < 20} {incr i} { append b [pty read $p -timeout 100ms] }
log "banner: [string length $b] bytes"

# raw send + capture
if {[catch {pty send $p "echo REAL-MARKER-42\r"} e]} { log "send FAILED: $e" } else { log "send ok" }
set r ""
for {set i 0} {$i < 40} {incr i} {
    append r [pty read $p -timeout 100ms]
    if {[string match *REAL-MARKER-42* $r]} break
}
log "raw capture: MARKER=[string match *REAL-MARKER-42* $r]"

# pty expect: drive fresh commands and match their output -- the real use of it
if {[catch {
    pty send $p "echo EXPECT-MARKER-99\r"
    pty expect $p -timeout 5s {
        {*EXPECT-MARKER-99*} { log "expect: matched echo marker" }
        timeout              { log "expect: TIMEOUT on echo marker" }
    }
    pty send $p "ver\r"
    pty expect $p -timeout 5s {
        {*Windows*} { log "expect: matched ver output" }
        timeout     { log "expect: TIMEOUT on ver" }
    }
} e]} { log "expect FAILED: $e" }

log "about to pty close"
pty close $p
log "pty close returned cleanly"
close $f
puts "wrote $OUT -- pty flow complete"
