package require machteld
package require machteld::network

set checks 0
proc check {label condition} {
    if {![uplevel 1 [list expr $condition]]} {error $label}
    incr ::checks
}
proc listen {address} {::machteld::network::udp open $address 0}
proc deliver {sender to value} {$sender send [dict get $to address] [dict get $to port] $value}
proc await {var} {
    upvar #0 $var signal
    set timer [after 5000 [list set ::$var timedout]]
    try {vwait ::$var} finally {after cancel $timer}
    if {$signal eq "timedout"} {error "timeout waiting for $var"}
}
proc got {wanted socket} {
    set r [$socket receive]
    if {$r eq {}} {error "spurious readable callback"}
    lappend ::packets [list [binary encode hex [dict get $r bytes]] [dict get $r address] [dict get $r port]]
    if {[llength $::packets] == $wanted} {set ::completed yes}
}
proc exchange {address} {
    set rx [listen $address]
    set tx [listen $address]
    try {
        set dst [$rx local]
        set src [$tx local]
        check local {[dict get $dst address] eq $address && [dict get $dst port] > 0}
        check distinct {[dict get $dst port] != [dict get $src port]}
        check idle {[$rx receive] eq {} && [$rx readable] eq {}}
        set ::packets {}
        set wanted {00ff 80 {} 7500ff 7e}
        foreach hex $wanted {
            check sent {[deliver $tx $dst [binary decode hex $hex]] == [string length $hex] / 2}
        }
        # Install after arrival. Each invocation consumes just one datagram.
        $rx readable [list got [llength $wanted]]
        check watch {[$rx readable] eq {got 5}}
        await completed
        check ordered {[lmap p $::packets {lindex $p 0}] eq $wanted}
        foreach p $::packets {
            check sender {[lrange $p 1 2] eq [list $address [dict get $src port]]}
        }
        $rx readable {}
        check drained {[$rx receive] eq {}}
        set bound [::machteld::network::udp open 127.0.0.1 0]
        try {
            catch {::machteld::network::udp open 127.0.0.1 [dict get [$bound local] port]} msg options
            check exclusive {[lrange [dict get $options -errorcode] 0 2] eq {MACHTELD UDP oserror}}
        } finally {$bound close}
        set lim [expr {$address eq "::1" ? 65527 : 65507}]
        set big [binary format a$lim z]
        check max-send {[deliver $tx $dst $big] == $lim}
        set data [dict get [$rx receive] bytes]
        check max-integrity {$data eq $big}
        set tooBig [binary format a[expr {$lim + 1}] {}]
        catch {deliver $tx $dst $tooBig} msg options
        check oversize {[dict get $options -errorcode] eq {MACHTELD UDP badvalue}}
        set other [expr {$address eq "::1" ? "127.0.0.1" : "::1"}]
        catch {$tx send $other 1 ab} msg options
        check mixed-family {[dict get $options -errorcode] eq {MACHTELD UDP badvalue}}
        check text {[deliver $tx $dst "Grüße"] == 7}
        check utf8 {[binary encode hex [dict get [$rx receive] bytes]] eq "4772c3bcc39f65"}
    } finally {$rx close; $tx close}
}
proc reentrantClose {s} {
    set ::last [dict get [$s receive] bytes]
    $s close
    set ::completed yes
}
proc failRead {s} {set ::consumed [$s receive]; error {UDP callback failure}}
proc bgerror {msg} {set ::background $msg}

if {$argv eq {--tk}} {
    package require Tk
    wm title . "Machteld UDP event test"
    frame .w
    set ::drawn 0
    bind .w <<UDPFrame>> {incr ::drawn}
    set rx [listen 127.0.0.1]; set tx [listen 127.0.0.1]
    try {
        $rx readable reentrantClose
        set dst [$rx local]
        # A changing widget and virtual event must run while UDP is idle.
        pack .w; update
        after 5 {.w configure -width 37; event generate .w <<UDPFrame>>; set ::frame yes}
        await frame
        update idletasks
        check responsive {$::drawn > 0 && [winfo reqwidth .w] == 37}
        after 5 [list deliver $tx $dst pong]
        await completed
        check after-frame {$::last eq "pong"}
    } finally {catch {$rx close}; $tx close; destroy .}
    puts "UDP with Tk: $checks checks passed"
    return
}

exchange 127.0.0.1
exchange ::1
foreach ep {{localhost 0} {::1%abc 0} {::1%4294967296 0} {127.0.0.1 -1} {127.0.0.1 65536}} {
    catch {::machteld::network::udp open {*}$ep} msg opt
    check endpoint {[dict get $opt -errorcode] eq {MACHTELD UDP badvalue}}
}
set tx [listen 127.0.0.1]
try {
    set ::late 0
    for {set i 0} {$i < 40} {incr i} {
        set rx [listen 127.0.0.1]
        set dst [$rx local]
        $rx readable {apply {{s} {incr ::late}}}
        deliver $tx $dst packet
        after 2
        # A queued read may already exist. Close and reuse the same port.
        $rx close
        set replacement [::machteld::network::udp open 127.0.0.1 [dict get $dst port]]
        try {update; check retired {[$replacement receive] eq {} && $::late == 0}} finally {$replacement close}
    }
    set rx [listen 127.0.0.1]
    set dst [$rx local]
    $rx readable {apply {{s} {incr ::late}}}
    deliver $tx $dst pending
    after 10
    $rx readable {}
    update
    check cancelled {$::late == 0 && [dict get [$rx receive] bytes] eq "pending"}
    $rx readable failRead
    deliver $tx $dst broken
    await background
    check callback-error {$::background eq "UDP callback failure" && [$rx readable] eq {}}
    $rx readable reentrantClose
    rename $rx ::renamedUdp
    deliver $tx $dst final
    await completed
    check reentrant {$::last eq "final" && [info commands ::renamedUdp] eq {}}
    set child [interp create]
    try {
        set dst [interp eval $child {
            package require machteld::network
            set s [::machteld::network::udp open 127.0.0.1 0]
            $s readable {apply {{socket} {error {deleted interpreter callback}}}}
            $s local
        }]
        deliver $tx $dst orphan
        after 10
    } finally {interp delete $child}
    update
    check child-events {$::background eq "UDP callback failure"}
} finally {$tx close}
puts "UDP datagrams: $checks checks passed"
