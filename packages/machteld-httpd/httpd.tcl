package require Tcl 9.0
namespace eval ::machteld::httpd {}

proc ::machteld::httpd::listen {handler args} {
    set port 0
    if {[llength $args] == 2 && [lindex $args 0] eq "-port"} {
        set port [lindex $args 1]
    } elseif {[llength $args]} {
        return -code error -errorcode {MACHTELD HTTPD usage} "usage: listen handler ?-port number?"
    }
    if {![llength $handler] || ![string is integer -strict $port] || $port < 0 || $port > 65535} {
        return -code error -errorcode {MACHTELD HTTPD badvalue} "expected a handler prefix and a port from 0 through 65535"
    }
    return [Server new $handler $port]
}

oo::class create ::machteld::httpd::Server {
    variable handler listener port clients

    constructor {callback requested} {
        set handler $callback
        set clients {}
        set listener [socket -server [namespace code {my accept}] -myaddr 127.0.0.1 $requested]
        set port [lindex [fconfigure $listener -sockname] end]
    }
    method port {} {return $port}
    method address {} {return 127.0.0.1}
    method close {} {my destroy}
    destructor {
        if {[info exists listener]} {close $listener}
        foreach ch [dict keys $clients] {my drop $ch}
    }

    method accept {ch peer peerPort} {
        if {$peer ne "127.0.0.1" || [dict size $clients] >= 32} {close $ch; return}
        fconfigure $ch -blocking 0 -buffering none -translation binary
        set timer [after 15000 [namespace code [list my drop $ch]]]
        dict set clients $ch [dict create timer $timer input {}]
        fileevent $ch readable [namespace code [list my readRequest $ch]]
    }
    method drop {ch} {
        if {![dict exists $clients $ch]} return
        after cancel [dict get $clients $ch timer]
        dict unset clients $ch
        catch {close $ch}
    }

    method readRequest {ch} {
        if {![dict exists $clients $ch]} return
        if {[catch {read $ch 16384} chunk] || ($chunk eq "" && [eof $ch])} {
            my drop $ch
            return
        }
        set client [dict get $clients $ch]
        dict append client input $chunk
        set input [dict get $client input]
        if {![dict exists $client request]} {
            set cut [string first "\r\n\r\n" $input]
            if {$cut > 16384 || ($cut < 0 && [string length $input] > 16387)} {
                my errorReply $ch 431
                return
            }
            if {$cut < 0} {dict set clients $ch $client; return}
            if {[catch {my parseHead [string range $input 0 $cut-1]} parsed options]} {
                set status [lindex [dict get $options -errorcode] 2]
                my errorReply $ch [expr {$status in {400 405 413 417 501} ? $status : 400}]
                return
            }
            lassign $parsed request length
            set input [string range $input $cut+4 end]
            dict set client input $input
            dict set client request $request
            dict set client length $length
        }
        if {[string length $input] < [dict get $client length]} {
            dict set clients $ch $client
            return
        }
        set request [dict get $client request]
        dict set request body [binary format a* [string range $input 0 [expr {[dict get $client length]-1}]]]
        dict set clients $ch request $request
        fileevent $ch readable {}
        if {[catch {uplevel #0 [list {*}$handler $request]} response]} {
            if {[dict exists $clients $ch]} {my errorReply $ch 500}
            return
        }
        if {![dict exists $clients $ch]} return
        if {[catch {my sendReply $ch $response [expr {[dict get $request method] eq "HEAD"}]}]} {
            my errorReply $ch 500
        }
    }
    method parseHead {input} {
        set lines [split [string map [list "\r\n" \n] $input] \n]
        if {[regexp {[\x00-\x08\x0a-\x1f\x7f]} [string map [list "\r\n" {}] $input]] ||
                ![regexp {^([A-Z]+) (/[^\x00-\x20#]*) HTTP/(1\.[01])$} [lindex $lines 0] -> method target version]} {
            throw {HTTPD REQUEST 400} "invalid request line"
        }
        if {$method ni {GET HEAD POST}} {throw {HTTPD REQUEST 405} "unsupported method"}
        set headers {}
        foreach line [lrange $lines 1 end] {
            if {![regexp {^([!#$%&'*+.^_`|~a-zA-Z0-9-]+):[ \t]*(.*)$} $line -> name value]} {
                throw {HTTPD REQUEST 400} "invalid header"
            }
            set name [string tolower $name]
            if {$name in {host content-length} && [dict exists $headers $name]} {
                throw {HTTPD REQUEST 400} "duplicate header"
            }
            dict lappend headers $name [string trim $value " \t"]
        }
        set authority [string tolower [lindex [dict getdef $headers host {}] 0]]
        set accepted [list "localhost:$port" "127.0.0.1:$port"]
        if {$port == 80} {lappend accepted localhost 127.0.0.1}
        if {($version eq "1.1" || $authority ne "") && $authority ni $accepted} {
            throw {HTTPD REQUEST 400} "invalid local authority"
        }
        if {[dict exists $headers transfer-encoding]} {throw {HTTPD REQUEST 501} "unsupported transfer coding"}
        if {[dict exists $headers expect]} {throw {HTTPD REQUEST 417} "unsupported expectation"}
        set length [lindex [dict getdef $headers content-length 0] 0]
        if {![regexp {^[0-9]+$} $length]} {throw {HTTPD REQUEST 400} "invalid content length"}
        set length [string trimleft $length 0]
        if {$length eq ""} {set length 0}
        if {[string length $length] > 7 || $length > 1048576} {throw {HTTPD REQUEST 413} "request body too large"}
        return [list [dict create method $method target $target headers $headers] $length]
    }

    method errorReply {ch status} {
        set head [expr {[dict exists $clients $ch request method] &&
            [dict get $clients $ch request method] eq "HEAD"}]
        if {[catch {my sendReply $ch [dict create status $status text "HTTP $status\n"] $head}]} {my drop $ch}
    }
    method sendReply {ch response head} {
        set status [dict getdef $response status 200]
        if {![regexp {^[2-5][0-9][0-9]$} $status]} {error "invalid status"}
        set text [dict exists $response text]
        if {$text == [dict exists $response bytes]} {error "supply either text or bytes"}
        if {$text} {
            set body [encoding convertto utf-8 [dict get $response text]]
            set type {text/plain; charset=utf-8}
        } else {
            set body [binary format a* [dict get $response bytes]]
            set type application/octet-stream
        }
        set size [string length $body]
        if {$size > 4194304 || ($status in {204 304} && $size)} {error "invalid response body length"}
        set type [dict getdef $response type $type]
        if {![regexp {^[\x20-\x7e]+$} $type] || [string length $type] > 1024} {error "invalid content type"}
        set reasons {200 OK 201 Created 204 {No Content} 304 {Not Modified} 400 {Bad Request}
            404 {Not Found} 405 {Method Not Allowed} 413 {Content Too Large} 417 {Expectation Failed}
            431 {Request Header Fields Too Large} 500 {Internal Server Error} 501 {Not Implemented}}
        set header "HTTP/1.1 $status [dict getdef $reasons $status Response]\r\nConnection: close\r\nContent-Type: $type\r\n"
        if {$status ni {204 304}} {append header "Content-Length: $size\r\n"}
        if {$status == 405} {append header "Allow: GET, HEAD, POST\r\n"}
        append header "\r\n"
        fileevent $ch readable {}
        dict set clients $ch input {}
        dict set clients $ch body [expr {$head ? {} : $body}]
        dict set clients $ch sent 0
        if {[catch {puts -nonewline $ch $header}]} {my drop $ch; return}
        fileevent $ch writable [namespace code [list my drain $ch]]
        my drain $ch
    }
    method drain {ch} {
        if {[catch {flush $ch}]} {my drop $ch; return}
        if {[chan pending output $ch]} return
        set body [dict get $clients $ch body]
        set sent [dict get $clients $ch sent]
        if {$sent >= [string length $body]} {
            my drop $ch
            return
        }
        set next [expr {min($sent + 16384, [string length $body])}]
        if {[catch {puts -nonewline $ch [string range $body $sent $next-1]}]} {my drop $ch; return}
        dict set clients $ch sent $next
    }
    unexport accept drop readRequest parseHead errorReply sendReply drain
}

package provide machteld::httpd 1.0
