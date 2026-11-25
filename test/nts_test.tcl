package require machteld
package require machteld::network

if {[llength $argv] != 1} {error "usage: nts_test.tcl independentServer.exe"}
set server [file normalize [lindex $argv 0]]
set checks 0
proc check {name value} {
    if {![uplevel 1 [list expr $value]]} {error $name}
    incr ::checks
}
set nts ::machteld::network::nts
proc serve {mode body} {
    global server
    set tmp [file tempfile stem]
    close $tmp
    set cert $stem.der; set marker $stem.port
    set child [child start -timeout 10s -- $server $mode $cert $marker]
    try {
        set until [expr {[clock milliseconds]+4500}]
        while {![file exists $marker] || [file size $marker] < 2} {
            if {[clock milliseconds] > $until || ![dict get [child info $child] running]} {
                error "fixture $mode failed to start: [child wait $child -timeout 1ms]"
            }
            after 10
        }
        set f [open $marker]; try {set port [string trim [read $f]]} finally {close $f}
        set f [open $cert rb]; try {set root [read $f]} finally {close $f}
        apply [list {mode port root} $body] $mode $port $root
        if {$mode ni {stall udpstall}} {
            set r [child wait $child -timeout 5s]
            if {[dict get $r status] ne "ok"} {error "fixture $mode: $r"}
        }
    } finally {child close $child; file delete -force -- $stem $marker $cert}
}
foreach mode {ok tickets samepeer ipv6} {
    serve $mode {
        set j [::machteld::network::nts start localhost -port $port -timeout 5000 -trustroot $root]
        try {
            set r [$j wait]
            check ok {[$j status] eq "ok" && [$j result] eq $r}
            check authenticated-time {[dict get $r unixms] >= 2085978497250 && [dict get $r unixms] < 2085978499250}
            check measured {2 == [dict get $r stratum] && [dict get $r rttms] >= 0 && [dict get $r rttms] < 4000}
            $j cancel
            check terminal {[$j result] eq $r}
        } finally {$j close}
    }
}
foreach {mode stage} {tag {NTS authentication} timestamp {NTS authentication} uid {NTS authentication}
                      origin {NTP header} badmode {NTP header} critical {NTS-KE negotiation}
                      wronghost {TLS certificate} wrongroot {TLS certificate} noalpn {TLS ALPN}
                      warning {NTS-KE negotiation} duplicate {NTS-KE negotiation}} {
    set ::expectedStage $stage
    serve $mode {
        set raised [catch {::machteld::network::nts sample localhost -port $port -timeout 5000 -trustroot $root} msg options]
        check rejected {$raised && [lrange [dict get $options -errorcode] 0 3] eq [list MACHTELD NTS failed $::expectedStage]}
        check no-time {![string match *unixms* $msg]}
    }
}
serve untrusted {
    catch {::machteld::network::nts sample localhost -port $port -timeout 4000} msg opts
    check default-trust {[lrange [dict get $opts -errorcode] 0 3] eq {MACHTELD NTS failed {TLS handshake}}}
}
serve udpstall {
    set start [clock milliseconds]
    catch {::machteld::network::nts sample localhost -port $port -timeout 550 -trustroot $root} msg opts
    check udp-deadline {[dict get $opts -errorcode] eq {MACHTELD NTS timeout}}
    check bounded {[clock milliseconds]-$start < 1800}
}
serve stall {
    set j [::machteld::network::nts start localhost -port $port -timeout 10000 -trustroot $root]
    set start [clock milliseconds]
    try {
        check pending {[$j status] eq "pending"}
        catch {$j result} msg opts
        check pending-result {[dict get $opts -errorcode] eq {MACHTELD NTS pending}}
        $j cancel
        catch {$j wait} msg opts
        check cancelled {[$j status] eq "cancelled" && [dict get $opts -errorcode] eq {MACHTELD NTS cancelled}}
        check prompt {[clock milliseconds]-$start < 1000}
    } finally {$j close}
}
serve stall {
    set sub [interp create]
    try {
        interp eval $sub [list set cmd [list ::machteld::network::nts start localhost -port $port -trustroot $root]]
        interp eval $sub {package require machteld::network; set j [{*}$cmd]}
    } finally {interp delete $sub}
    check deleted-interpreter {1}
}
foreach args {{sample {} -port 1} {sample localhost -timeout 0} {sample localhost -port 65536} {sample localhost -trustroot {}}} {
    catch {$nts {*}$args} why options
    check bad-value {[dict get $options -errorcode] eq {MACHTELD NTS badvalue}}
}
puts "authenticated time: $checks checks passed"
