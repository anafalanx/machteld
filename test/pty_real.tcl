# pty_real.tcl -- full pty flow on a REAL terminal, logged to a file so Claude
# can read the result and it survives any exit hang. Run from C:\z\_machteld:
#     build\machteld.exe test\pty_real.tcl
# Then tell Claude; it reads C:\z\_machteld\pty_real.txt directly. If machteld
# hangs at the very end (after "pty flow complete"), just close the window --
# the file is already complete, and that tells us the EXIT hang is real too.

set OUT [file normalize [file join [file dirname [info script]] .. pty_real.txt]]
set f [open $OUT w]
fconfigure $f -translation lf
proc log {m} { puts $::f $m; flush $::f }

log "pty real-terminal test  (machteld [::machteld::version])"
set p [pty spawn -- cmd]
log "spawned $p"

set b ""
for {set i 0} {$i < 20} {incr i} { append b [pty read $p -timeout 100ms] }
log "banner: [string length $b] bytes"

if {[catch {pty send $p "echo REAL-MARKER-42\r"} e]} { log "send FAILED: $e" } else { log "send ok" }
set r ""
for {set i 0} {$i < 40} {incr i} {
    append r [pty read $p -timeout 100ms]
    if {[string match *REAL-MARKER-42* $r]} break
}
log "response: [string length $r] bytes, MARKER captured: [string match *REAL-MARKER-42* $r]"

# --- pty expect: the Tcl interaction loop over pty read ---------------------
if {[catch {
    pty expect $p -timeout 5s {
        {*>*}    { log "expect: matched cmd prompt" }
        timeout  { log "expect: TIMEOUT waiting for prompt" }
    }
    pty send $p "echo EXPECT-MARKER-99\r"
    pty expect $p -timeout 5s {
        {*EXPECT-MARKER-99*} { log "expect: matched marker" }
        timeout              { log "expect: TIMEOUT waiting for marker" }
    }
} e]} { log "expect FAILED: $e" }

log "about to pty close (live cmd)"
close $f
pty close $p
set f [open $OUT a]
fconfigure $f -translation lf
puts $f "pty close returned cleanly"
flush $f
close $f
puts "wrote [file normalize [file join [file dirname [info script]] .. pty_real.txt]] -- pty flow complete"
