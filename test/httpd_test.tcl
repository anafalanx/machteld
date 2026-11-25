package require machteld
package require machteld::httpd 1.0

proc check {name condition} {
    if {!$condition} {error "failed: $name"}
    puts "ok   httpd: $name"
}
proc handle request {
    incr ::hits
    switch -- [dict get $request target] {
        /json {return [dict create type application/json text [json encode -dict [dict create calls $::hits]]]}
        /echo {return [dict create bytes [dict get $request body]]}
        /page {return [dict create type {text/html; charset=utf-8} text {<p>café 雪</p>}]}
        /large {return [dict create bytes [binary format a* [string repeat z 262144]]]}
        /invalid {return [dict create text BAD type "broken\r\nX-injected: yes"]}
        /error {error {private error detail}}
        /nocontent {return [dict create status 204 bytes {}]}
        default {return [dict create status 404 text {}]}
    }
}
proc collect ch {
    append ::reply [read $ch]
    if {[eof $ch]} {set ::answer 1}
}
proc request {port first {rest {}}} {
    set ch [socket 127.0.0.1 $port]
    fconfigure $ch -blocking 0 -translation binary -buffering none
    set ::reply {}
    unset -nocomplain ::answer
    set deadline [after 10000 {set ::answer 0}]
    set later {}
    try {
        fileevent $ch readable [list collect $ch]
        puts -nonewline $ch $first
        if {$rest ne {}} {set later [after 10 [list puts -nonewline $ch $rest]]}
        vwait ::answer
        if {!$::answer} {error "HTTP response timed out"}
    } finally {
        after cancel $deadline
        if {$later ne {}} {after cancel $later}
        close $ch
    }
    set cut [string first "\r\n\r\n" $::reply]
    if {$cut < 0 || ![regexp {^HTTP/1\.1 ([0-9]+) } $::reply -> status]} {error "invalid HTTP response"}
    return [list $status [string range $::reply 0 $cut-1] [string range $::reply $cut+4 end]]
}
proc tick {} {
    incr ::ticks
    if {[llength [info commands winfo]]} {wm title . "HTTP requests $::ticks"}
    set ::timer [after 2 tick]
}
if {$argv eq {--tk}} {package require Tk; update}
set hits 0
set ticks 0
set server [::machteld::httpd::listen handle]
try {
    set port [$server port]
    set host "Host: 127.0.0.1:$port\r\n"
    check "listens on an ephemeral loopback port" [expr {[$server address] eq "127.0.0.1" && $port > 0}]
    tick
    lassign [request $port "GET /pa" "ge HTTP/1.1\r\n${host}\r\n"] code headers body
    check "a split browser request receives UTF-8 HTML while timers run" [expr {
        $code == 200 && [string match {*Content-Type: text/html*} $headers] &&
        [encoding convertfrom utf-8 $body] eq {<p>café 雪</p>} && $ticks >= 2}]
    foreach unused {1 2} {
        lassign [request $port "GET /json HTTP/1.1\r\n${host}\r\n"] code headers body
        check "fresh JSON carries the current request count" [expr {$code == 200 && [dict get [json decode $body] calls] == $hits}]
    }
    set payload [binary decode hex ff0080000d0a61]
    lassign [request $port "POST /echo HTTP/1.1\r\n${host}Content-Length: 7\r\n\r\n" $payload] code headers body
    check "fragmented POST preserves binary bytes" [expr {$code == 200 && $body eq $payload}]
    lassign [request $port "HEAD /page HTTP/1.1\r\n${host}\r\n"] code headers body
    check "HEAD reports the GET length with an empty body" [expr {$code == 200 && $body eq {} &&
        [string match "*Content-Length: [string length [encoding convertto utf-8 {<p>café 雪</p>}]]*" $headers]}]
    lassign [request $port "GET /large HTTP/1.1\r\n${host}\r\n"] code headers body
    check "responses larger than a write chunk arrive intact" [expr {$body eq [string repeat z 262144]}]
    lassign [request $port "GET /nocontent HTTP/1.1\r\n${host}\r\n"] code headers body
    check "204 emits no body or length" [expr {$code == 204 && ![string match {*Content-Length*} $headers] && $body eq {}}]
    lassign [request $port "HEAD /error HTTP/1.1\r\n${host}\r\n"] code headers body
    check "HEAD errors also omit the response body" [expr {$code == 500 && $body eq {}}]
    set previous $hits
    foreach {wire expected} [list \
            "POST /echo HTTP/1.1\r\n${host}Content-Length: 1048577\r\n\r\n" 413 \
            "GET /page HTTP/1.1\r\nHost: example.invalid\r\n\r\n" 400 \
            "GET /page HTTP/1.1\r\n${host}${host}\r\n" 400 \
            "POST /echo HTTP/1.1\r\n${host}Content-Length: 0\r\nContent-Length: 1\r\n\r\n" 400 \
            "POST /echo HTTP/1.1\r\n${host}Content-Length: -1\r\n\r\n" 400 \
            "GET /page HTTP/1.1\r\n${host}X-A: [string repeat a 16400]\r\n\r\n" 431 \
            "POST /echo HTTP/1.1\r\n${host}Transfer-Encoding: chunked\r\n\r\n" 501 \
            "PUT /page HTTP/1.1\r\n${host}\r\n" 405] {
        check "invalid or unsupported request returns $expected" [expr {[lindex [request $port $wire] 0] == $expected}]
    }
    check "refused requests never reach the application" [expr {$previous == $hits}]
    foreach path {/invalid /error} {
        lassign [request $port "GET $path HTTP/1.1\r\n${host}\r\n"] code headers body
        check "handler failure returns a generic 500" [expr {$code == 500 && $body eq "HTTP 500\n"}]
    }
    set abandoned [socket 127.0.0.1 $port]
    puts -nonewline $abandoned "GET /pa"
    close $abandoned
    check "a disconnect during a header leaves the next request usable" [expr {
        [lindex [request $port "GET /page HTTP/1.1\r\n${host}\r\n"] 0] == 200}]
    set idle [socket 127.0.0.1 $port]
    try {
        update
        $server close
        set server {}
        check "closing with a partial client releases the listener" [catch {socket 127.0.0.1 $port}]
        set replacement [::machteld::httpd::listen handle -port $port]
        $replacement close
    } finally {close $idle}
} finally {
    if {$server ne {}} {$server close}
    if {[info exists timer]} {after cancel $timer}
    if {$argv eq {--tk}} {destroy .}
}
