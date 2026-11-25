# RFC 6455 client for the app-owned browser's loopback control connection.
# Ordinary Tcl channel events keep timers, Tk and cancellation responsive.
namespace eval ::machteld::browser::wire {
    variable channel
    variable phase
    variable input
    variable partial
    variable fragments
    variable reference
    variable path
    variable port
    variable wake
    variable pending
    variable next
}

proc ::machteld::browser::wire::Drop {t code message} {
    variable channel; variable phase; variable pending; variable wake
    if {[info exists channel($t)]} {
        catch {fileevent $channel($t) readable {}}
        catch {fileevent $channel($t) writable {}}
        catch {close $channel($t)}
        unset channel($t)
    }
    set phase($t) failed
    set wake($t) [list $code $message]
    foreach slot [array names pending "$t,*"] {
        if {$pending($slot) eq "pending"} {set pending($slot) [list $code $message]}
    }
    ::machteld::browser::Disconnected $t $message
}

proc ::machteld::browser::wire::Forget {t} {
    variable phase
    if {[info exists phase($t)] && $phase($t) eq "open"} {
        catch {Frame $t 8 [binary format S 1000]}
    }
    if {[info exists phase($t)]} {Drop $t closed {browser control connection closed}}
    foreach name {phase input partial fragments reference path port wake next} {
        variable $name
        unset -nocomplain [format {%s(%s)} $name $t]
    }
    # Active request waiters consume their terminal result when they unwind.
}

proc ::machteld::browser::wire::Await {variableName timeout} {
    upvar #0 $variableName value
    if {$value eq "pending"} {
        set timer [after $timeout [list set $variableName [list timeout {browser operation timed out}]]]
        try {vwait $variableName} finally {after cancel $timer}
    }
    lassign $value code body
    if {$code ne "ok"} {::machteld::browser::Fail $code $body}
    return $body
}

proc ::machteld::browser::wire::Connect {t p resource timeout} {
    variable channel; variable phase; variable input; variable partial; variable fragments
    variable reference; variable path; variable port; variable wake; variable next
    set phase($t) opening
    set channel($t) [socket -async 127.0.0.1 $p]
    fconfigure $channel($t) -blocking 0 -translation binary -buffering none
    set input($t) {}; set partial($t) {}; set fragments($t) 0; set next($t) 0
    set path($t) $resource; set port($t) $p; set wake($t) pending
    set key [binary encode base64 [::machteld::hash random 16]]
    set reference($t) [binary encode base64 [::machteld::hash sum sha1 "${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" -binary]]
    fileevent $channel($t) writable [list [namespace current]::Handshake $t $key]
    fileevent $channel($t) readable [list [namespace current]::Read $t]
    Await [namespace current]::wake($t) $timeout
}

proc ::machteld::browser::wire::Handshake {t key} {
    variable channel; variable port; variable path
    if {![info exists channel($t)]} return
    fileevent $channel($t) writable {}
    if {[catch {
        set error [fconfigure $channel($t) -error]
        if {$error ne {}} {error $error}
        puts -nonewline $channel($t) "GET $path($t) HTTP/1.1\r\nHost: 127.0.0.1:$port($t)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: $key\r\n\r\n"
    } message]} {Drop $t protocol $message}
}

proc ::machteld::browser::wire::Frame {t opcode payload} {
    variable channel
    set length [string length $payload]
    if {$length > 131072} {::machteld::browser::Fail badvalue {browser request exceeds 128 KiB}}
    if {![info exists channel($t)]} {::machteld::browser::Fail closed {browser control connection is closed}}
    set header [binary format cc [expr {128 | $opcode}] [expr {128 | min($length,126)}]]
    if {$length >= 65536} {set header [binary format ccW [expr {128 | $opcode}] 255 $length]
    } elseif {$length >= 126} {append header [binary format S $length]}
    set key [::machteld::hash random 4]
    binary scan $key cu* mask
    binary scan $payload cu* bytes
    set output {}; set i 0
    foreach byte $bytes {lappend output [expr {$byte ^ [lindex $mask [expr {$i & 3}]]}]; incr i}
    puts -nonewline $channel($t) "$header$key[binary format c* $output]"
}

proc ::machteld::browser::wire::Upgrade {t} {
    variable input; variable reference; variable phase; variable wake
    set end [string first "\r\n\r\n" $input($t)]
    if {$end < 0} {
        if {[string length $input($t)] > 16384} {error "oversized browser handshake"}
        return 0
    }
    if {$end > 16384} {error "oversized browser handshake"}
    set header [split [string map [list "\r\n" "\n"] [string range $input($t) 0 $end-1]] "\n"]
    if {![regexp {^HTTP/1\.1 101(?: |$)} [lindex $header 0]]} {error "browser refused websocket upgrade"}
    set fields {}
    foreach line [lrange $header 1 end] {
        if {![regexp {^([^:[:space:]]+):[ \t]*(.*)$} $line -> key value]} {error "invalid browser handshake"}
        set key [string tolower $key]
        if {[dict exists $fields $key]} {error "duplicate browser handshake field"}
        dict set fields $key [string trim $value]
    }
    if {![string equal -nocase [dict get $fields upgrade] websocket] ||
            "upgrade" ni [lmap part [split [string tolower [dict get $fields connection]] ,] {string trim $part}] ||
            [dict get $fields sec-websocket-accept] ne $reference($t) ||
            [dict exists $fields sec-websocket-extensions]} {error "invalid browser websocket upgrade"}
    set input($t) [string range $input($t) $end+4 end]
    set phase($t) open; set wake($t) [list ok {}]
    return 1
}

proc ::machteld::browser::wire::Parse {t} {
    variable input; variable partial; variable fragments; variable phase
    if {$phase($t) eq "opening" && ![Upgrade $t]} return
    while {[string length $input($t)] >= 2} {
        binary scan $input($t) cucu first second
        set op [expr {$first & 15}]; set fin [expr {$first & 128}]
        if {($first & 112) || ($second & 128) || $op ni {0 1 8 9 10}} {error "invalid browser frame"}
        set length [expr {$second & 127}]; set head 2
        if {$length == 126} {
            if {[binary scan $input($t) @2Su length] == 0} return
            if {$length < 126} {error "noncanonical browser frame"}
            set head 4
        } elseif {$length == 127} {
            if {[binary scan $input($t) @2Wu length] == 0} return
            if {$length < 65536} {error "noncanonical browser frame"}
            set head 10
        }
        if {$length > 4194304 || ($op >= 8 && (!$fin || $length > 125))} {error "oversized browser frame"}
        if {[string length $input($t)] < $head+$length} return
        set payload [string range $input($t) $head [expr {$head+$length-1}]]
        set input($t) [string range $input($t) [expr {$head+$length}] end]
        switch $op {
            8 {Drop $t closed {browser closed its control connection}; return}
            9 {Frame $t 10 $payload}
            10 {}
            default {
                if {($op == 1 && $fragments($t)) || ($op == 0 && !$fragments($t))} {error "invalid fragmented browser message"}
                if {[string length $partial($t)]+$length > 4194304} {error "oversized browser message"}
                append partial($t) $payload
                set fragments($t) [expr {!$fin}]
                if {$fin} {
                    set packet [::machteld::json decode [encoding convertfrom -profile strict utf-8 $partial($t)]]
                    set partial($t) {}
                    Receive $t $packet
                }
            }
        }
    }
}

proc ::machteld::browser::wire::Read {t} {
    variable channel; variable input
    if {![info exists channel($t)]} return
    if {[catch {
        set bytes [read $channel($t) 32768]
        if {$bytes ne {}} {append input($t) $bytes; Parse $t}
        if {[info exists channel($t)] && [eof $channel($t)]} {Drop $t closed {browser control connection ended}}
    } message]} {Drop $t protocol $message}
}

proc ::machteld::browser::wire::Send {t method parameters session} {
    variable next
    set id [incr next($t)]
    set request [dict create id [::machteld::json value number $id] method [::machteld::json value string $method]]
    dict set request params [::machteld::json value object $parameters]
    if {$session ne {}} {dict set request sessionId [::machteld::json value string $session]}
    Frame $t 1 [encoding convertto -profile strict utf-8 [::machteld::json encode [::machteld::json value object $request]]]
    return $id
}

proc ::machteld::browser::wire::Request {t method parameters session timeout} {
    variable pending
    set id [Send $t $method $parameters $session]
    set pending($t,$id) pending
    try {Await [namespace current]::pending($t,$id) $timeout} finally {unset -nocomplain pending($t,$id)}
}

proc ::machteld::browser::wire::Receive {t packet} {
    variable pending
    if {[dict exists $packet id] && [info exists pending($t,[dict get $packet id])]} {
        set slot "$t,[dict get $packet id]"
        if {[dict exists $packet error]} {set pending($slot) [list protocol {browser rejected the requested operation}]
        } else {set pending($slot) [list ok [dict get $packet result]]}
    } else {::machteld::browser::Message $t $packet}
}
