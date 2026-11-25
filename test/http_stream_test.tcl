package require machteld 30-

# One real loopback TCP peer on this interpreter: blocked client operations
# would stop its headers, body and watchdog from being serviced.
namespace eval fixture {
    variable peers {}
    variable bulk [binary format c* [lrepeat 16384 173]]
    variable length [expr {20 * 1024 * 1024}]
    variable sent 0
    variable requests {}
    variable first [binary format H* 00ff807f41]
    proc closePeer {chan} {
        variable peers
        catch {close $chan}
        dict unset peers $chan
    }
    proc accept {chan addr port} {
        variable peers
        dict set peers $chan {}
        chan configure $chan -blocking 0 -translation binary -buffering none
        fileevent $chan readable [list fixture::request $chan]
    }
    proc request {chan} {
        variable peers
        variable requests
        variable first
        variable length
        if {[catch {read $chan} bytes] || [eof $chan]} {closePeer $chan; return}
        dict append peers $chan $bytes
        if {[string first "\r\n\r\n" [dict get $peers $chan]] < 0} {return}
        set request [dict get $peers $chan]
        set path [lindex $request 1]
        dict set requests $path $request
        fileevent $chan readable [list fixture::drain $chan]
        switch -- $path {
            /late {return}
            /redirect {
                puts -nonewline $chan "HTTP/1.1 302 Found\r\nConnection: close\r\nLocation: /small\r\nContent-Length: 0\r\n\r\n"
                closePeer $chan
            }
            /bulk {
                puts -nonewline $chan "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: $length\r\n\r\n"
                fileevent $chan writable [list fixture::produce $chan]
            }
            /hold {
                puts -nonewline $chan "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Test: yes\r\n\r\n5\r\n"
                puts -nonewline $chan $first
                puts -nonewline $chan "\r\n"
            }
            default {
                puts -nonewline $chan "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\n"
                puts -nonewline $chan $first
                closePeer $chan
            }
        }
    }
    proc drain {chan} {
        if {[catch {read $chan}] || [eof $chan]} {closePeer $chan}
    }
    proc produce {chan} {
        variable sent
        variable length
        variable bulk
        if {[catch {
            while {$sent < $length && [chan pending output $chan] < 65536} {
                puts -nonewline $chan $bulk
                incr sent [string length $bulk]
            }
            if {$sent >= $length} {fileevent $chan writable {}}
        }]} {closePeer $chan}
    }
}

proc expect {expression message} {
    if {![uplevel 1 [list expr $expression]]} {error $message}
    incr ::checks
}
proc tick {duration} {
    set token [after $duration {set ::ticks 1}]
    vwait ::ticks
    after cancel $token
}
proc readable {s} {set ::ready $s}
proc event {s} {
    set r [$s next]
    if {[dict get $r event] ne "pending"} {return $r}
    set ::ready {}
    $s readable readable
    set timer [after 20000 {set ::ready timeout}]
    try {vwait ::ready} finally {after cancel $timer}
    if {$::ready ne $s} {error "stream readiness expired"}
    set r [$s next]
    if {[dict get $r event] eq "pending"} {error "notified before a stream event was ready"}
    return $r
}
set checks 0
set listener [socket -server fixture::accept -myaddr 127.0.0.1 0]
set base http://127.0.0.1:[lindex [chan configure $listener -sockname] end]
set handles {}
try {
    set s [::machteld::http stream $base/hold -headers {X-Caller kept}]
    lappend handles $s
    set headers [event $s]
    expect {[dict get $headers event] eq "headers" && [dict get $headers status] == 200 &&
        [dict get $headers headers x-test] eq "yes" && [string match -nocase "*X-Test: yes*" [dict get $headers rawheaders]]} "missing response metadata"
    expect {[string match -nocase "*X-Caller: kept*" [dict get $fixture::requests /hold]]} "client header was lost"
    set early [event $s]
    expect {[dict get $early event] eq "data" && [dict get $early data] eq $fixture::first} "first binary chunk waited for EOF"
    set waiting [$s next]
    expect {[dict get $waiting event] eq "pending"} "open response failed to remain pending"
    set ::ready {}
    $s readable readable
    set started [clock milliseconds]
    $s cancel
    set timer [after 2000 {set ::ready timeout}]
    try {vwait ::ready} finally {after cancel $timer}
    expect {$::ready eq $s && [dict get [$s next] event] eq "cancelled" &&
        [clock milliseconds] - $started < 2000} "cancellation while waiting for more body bytes was late"
    $s cancel
    $s close

    set s [::machteld::http stream $base/late -timeout 500ms]
    lappend handles $s
    set rc [catch {event $s} message options]
    expect {$rc && [dict get $options -errorcode] eq {MACHTELD HTTP timeout}} "header timeout lost its error code"
    $s close

    set s [::machteld::http stream $base/late -timeout 15s]
    lappend handles $s
    set deadline [expr {[clock milliseconds] + 5000}]
    while {![dict exists $fixture::requests /late] && [clock milliseconds] < $deadline} {tick 5; $s next}
    expect {[dict exists $fixture::requests /late]} "headers fixture never received request"
    set started [clock milliseconds]
    $s cancel
    expect {[dict get [$s next] event] eq "cancelled" && [clock milliseconds] - $started < 1000} "cancel before headers blocked"
    $s close

    set s [::machteld::http stream $base/redirect -redirect none]
    lappend handles $s
    set redirect [event $s]
    expect {[dict get $redirect status] == 302 && [dict get $redirect headers location] eq "/small" &&
        [dict get [event $s] event] eq "eof"} "no-redirect response changed"
    $s close

    set s [::machteld::http stream $base/small -maxbody 4]
    lappend handles $s
    event $s
    set rc [catch {event $s} message options]
    expect {$rc && [dict get $options -errorcode] eq {MACHTELD HTTP toobig}} "wrong byte-limit failure"
    $s close

    set before [dict get [::machteld::mtps info [pid]] private]
    set s [::machteld::http stream $base/bulk]
    lappend handles $s
    event $s
    tick 400
    set peak [dict get [::machteld::mtps info [pid]] private]
    expect {$fixture::sent < $fixture::length} "an idle consumer drained the entire large response"
    set total 0
    set biggest 0
    set sampleAt 1048576
    while {1} {
        set r [event $s]
        if {[dict get $r event] eq "eof"} break
        set bytes [dict get $r data]
        set n [string length $bytes]
        if {[string trim $bytes [binary format c 173]] ne {}} {error "bulk data changed"}
        incr total $n
        set biggest [expr {max($biggest,$n)}]
        if {$total >= $sampleAt} {
            set peak [expr {max($peak,[dict get [::machteld::mtps info [pid]] private])}]
            incr sampleAt 1048576
        }
    }
    expect {$total == $fixture::length && $biggest > 0 && $biggest <= 65536} "incorrect total or unbounded chunk"
    expect {$peak - $before < $fixture::length / 2} "private bytes grew by at least half the response"
    puts "20 MiB response, largest chunk $biggest bytes, peak sampled private-byte increase [expr {$peak - $before}]"
    expect {[dict get [$s next] event] eq "eof"} "EOF was not stable"
    $s close

    set s [::machteld::http stream $base/small]
    lappend handles $s
    set ::closed 0
    $s readable [list apply {{handle} {
        $handle next
        $handle close
        set ::closed 1
    }}]
    set timeout [after 5000 {set ::closed -1}]
    try {vwait ::closed} finally {after cancel $timeout}
    expect {$::closed == 1 && [info commands $s] eq {}} "closing a stream in its own callback failed"

    set rc [catch {::machteld::http stream file:///local.txt} message options]
    expect {$rc && [dict get $options -errorcode] eq {MACHTELD HTTP badvalue}} "non-HTTP URL was accepted"

    # Exercise late native completions after interpreter deletion on each
    # side of a request, with an event already queued and a callback armed.
    for {set i 0} {$i < 24} {incr i} {
        set slave [interp create]
        try {
            $slave eval {load {} machteldhttp}
            set handle [$slave eval [list ::machteld::http stream $base/late]]
            $slave eval [list $handle readable {apply {{s} {}}}]
            if {$i % 3 == 0} {update}
            if {$i % 3 == 1} {$slave eval [list $handle cancel]}
        } finally {
            interp delete $slave
        }
        update
    }
    expect {1} "interpreter disposal failed"

    if {[info exists ::env(MACHTELD_TEST_PUBLIC_TLS)] && $::env(MACHTELD_TEST_PUBLIC_TLS) eq "1"} {
        foreach endpoint {expired.badssl.com self-signed.badssl.com wrong.host.badssl.com} {
            set s [::machteld::http stream https://$endpoint/ -timeout 15s]
            lappend handles $s
            set rc [catch {event $s} message options]
            expect {$rc && [dict get $options -errorcode] eq {MACHTELD HTTP tls}} "stream accepted invalid TLS from $endpoint"
            $s close
        }
        set s [::machteld::http stream https://example.com/ -timeout 15s]
        lappend handles $s
        expect {[dict get [event $s] status] == 200 && [dict get [event $s] event] eq "data"} "trusted HTTPS failed"
        $s close
    }
} finally {
    foreach handle $handles {if {[llength [info commands $handle]]} {$handle close}}
    foreach chan [dict keys $fixture::peers] {fixture::closePeer $chan}
    close $listener
}
puts "$checks response streaming checks passed"
