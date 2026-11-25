package require machteld 30-
set here [file dirname [file normalize [info script]]]
namespace eval mediaFixture {
    variable parts {}
    variable requested {}
    variable refresh 0
    variable gap 0
    variable waiting 0
    variable abandoned 0
    variable peers {}
    # MPEG-2 PSI sections use a non-reflected CRC and no final xor.
    proc psi {hex} {
        set data [binary format H* $hex]
        set crc 0xffffffff
        binary scan $data cu* bytes
        foreach byte $bytes {
            set crc [expr {$crc ^ ($byte<<24)}]
            for {set i 0} {$i<8} {incr i} {
                set crc [expr {(($crc<<1) ^ (($crc & 0x80000000) ? 0x04c11db7 : 0)) & 0xffffffff}]
            }
        }
        return [binary format ca*I 0 $data $crc]
    }
    proc packet {pid start cc payload} {
        set n [string length $payload]
        set a [expr {(($pid>>8)&31) | ($start?64:0)}]
        set b [expr {$pid & 255}]
        if {$n == 184} {return [binary format cccca* 71 $a $b [expr {16|($cc&15)}] $payload]}
        set adapt [expr {183-$n}]
        set result [binary format ccccc 71 $a $b [expr {48|($cc&15)}] $adapt]
        if {$adapt > 0} {append result [binary format c 0] [binary format c* [lrepeat [expr {$adapt-1}] 255]]}
        append result $payload
        return $result
    }
    proc ts {data {streamType 15}} {
        set result [packet 0 1 0 [psi 00b00d0001c100000001e100]]
        append result [packet 256 1 0 [psi [format {02b0120001c10000e101f000%02xe101f000} $streamType]]]
        set pes [binary format H6cSccca* 000001 192 [expr {[string length $data]+3}] 128 0 0 $data]
        set i 0
        for {set at 0} {$at < [string length $pes]} {incr at 184} {
            append result [packet 257 [expr {$at==0}] $i [string range $pes $at [expr {$at+183}]]]
            incr i
        }
        return $result
    }
    proc splitFrames {bytes} {
        set frames {}
        for {set pos 0} {$pos < [string length $bytes]} {} {
            binary scan [string range $bytes [expr {$pos+3}] [expr {$pos+5}]] cu3 sizes
            lassign $sizes a b c
            set n [expr {(($a&3)<<11)|($b<<3)|($c>>5)}]
            if {$n < 7} {error "invalid synthetic fixture frame"}
            lappend frames [string range $bytes $pos [expr {$pos+$n-1}]]
            incr pos $n
        }
        set group [expr {[llength $frames]/3}]
        return [list [join [lrange $frames 0 [expr {$group-1}]] {}] \
            [join [lrange $frames $group [expr {2*$group-1}]] {}] [join [lrange $frames [expr {2*$group}] end] {}]]
    }
    proc closePeer {sock} {
        variable peers
        catch {close $sock}
        dict unset peers $sock
    }
    proc accept {sock address port} {
        variable peers
        dict set peers $sock {}
        chan configure $sock -blocking 0 -translation binary -buffering none
        fileevent $sock readable [list mediaFixture::serve $sock]
    }
    proc watchClose {sock} {
        if {[catch {read $sock}] || [eof $sock]} {set ::mediaFixture::abandoned 1; closePeer $sock}
    }
    proc serve {sock} {
        variable requested
        variable refresh
        variable peers
        variable parts
        if {[catch {read $sock} data] || [eof $sock]} {closePeer $sock; return}
        dict append peers $sock $data
        if {[string first "\r\n\r\n" [dict get $peers $sock]] < 0} return
        set path [lindex [dict get $peers $sock] 1]
        lappend requested $path
        set response {200 OK}
        set extra {}
        switch -glob -- $path {
            /start {
                set response {302 Found}
                set extra "Location: /radio/master.m3u8\r\n"
                set body {}
            }
            /radio/master.m3u8 {
                set body "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=32000\nunused.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=96000\nlive.m3u8\n"
            }
            /radio/live.m3u8 {
                incr refresh
                set first [expr {$refresh == 1 ? 10 : $::mediaFixture::gap ? 13 : 11}]
                set body "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:$first\n"
                foreach n [list $first [expr {$first+1}]] {append body "#EXTINF:0.2,\n$n.ts\n"}
                if {$refresh > 1} {append body "#EXT-X-ENDLIST\n"}
            }
            /radio/*.ts {
                scan [file tail $path] %d n
                set body [ts [lindex $parts [expr {$n-10}]]]
            }
            /held.m3u8 {
                puts -nonewline $sock "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n#EXTM3U\n\r\n"
                fileevent $sock readable [list mediaFixture::watchClose $sock]
                set ::mediaFixture::waiting 1
                return
            }
            default {set response {404 Not Found}; set body {}}
        }
        puts -nonewline $sock "HTTP/1.1 $response\r\n[set extra]Connection: close\r\nContent-Length: [string length $body]\r\n\r\n"
        puts -nonewline $sock $body
        closePeer $sock
    }
}
proc receiveHls {session event data} {
    switch $event {
        segment {
            lappend ::sequences [dict get $data sequence]
            if {[dict get $data codec] ne "aac"} {error "wrong elementary stream codec"}
            append ::payload [dict get $data data]
            if {$::device && !$::stopAfterOne} {
                $::decoder feed [dict get $data data]
                playDecoded
            }
            if {$::stopAfterOne} {$session stop; set ::finished stopped}
        }
        end {
            if {$::device && !$::stopAfterOne} {
                $::decoder finish
                playDecoded
                $::output finish
            }
            set ::finished done
        }
        error {set ::finished [list error $data]}
    }
}
proc playDecoded {} {
    while {[dict get [set frame [$::decoder read]] state] eq "data"} {
        set pcm [dict get $frame pcm]
        if {[dict get $frame rate] != 48000 || [dict get $frame channels] != 2} {error "wrong decoded HLS PCM format"}
        if {[$::output write $pcm] != [string length $pcm]} {error "HLS playback buffer filled unexpectedly"}
        incr ::played [expr {[string length $pcm]/8}]
    }
}
set device [expr {$argv eq {--device}}]
set source [expr {$device ? "silence-lc.aac" : "tone-lc.aac"}]
set f [open [file join $here fixtures audio $source] rb]
try {set original [read $f]} finally {close $f}
set mediaFixture::parts [mediaFixture::splitFrames $original]
set known [::machteld::audio demux [mediaFixture::ts $original]]
if {[dict get $known codec] ne "aac" || [dict get $known data] ne $original} {error "TS framing changed payload bytes"}
foreach bad [list [binary format x189] [binary format x564]] {
    if {![catch {::machteld::audio demux $bad} msg opts] || [dict get $opts -errorcode] ne {MACHTELD AUDIO format}} {error "malformed TS accepted"}
}
set listener [socket -server mediaFixture::accept -myaddr 127.0.0.1 0]
set base http://127.0.0.1:[lindex [chan configure $listener -sockname] end]
try {
    if {$device} {
        set decoder [::machteld::audio decoder aac]
        set output [::machteld::audio output 48000 2]
        set played 0
    }
    foreach stopAfterOne {0 1} {
        set sequences {}
        set payload [binary format x0]
        set mediaFixture::refresh 0
        set mediaFixture::requested {}
        set finished {}
        set h [::machteld::hls start $base/start receiveHls]
        set timer [after 12000 {set ::finished timeout}]
        try {
            vwait finished
            after cancel $timer
            if {$stopAfterOne} {
                if {$finished ne "stopped" || $sequences ne {10}} {error "HLS stop failed: $finished $sequences"}
                set seen $mediaFixture::requested
                after 1100 {set ::settled 1}
                vwait settled
                if {$seen ne $mediaFixture::requested || [dict get [$h status] state] ne "stopped"} {error "HTTP continued after stop"}
            } else {
                if {$finished ne "done" || $sequences ne {10 11 12} || $payload ne $original} {error "HLS ordering: $finished $sequences"}
                if {$device} {
                    set deadline [expr {[clock milliseconds]+8000}]
                    while {[dict get [set status [$output status]] state] ne "done"} {
                        if {[dict get $status state] eq "error" || [clock milliseconds]>$deadline} {error "HLS playback: $status"}
                        after 5 {set ::advanceAudio 1}
                        vwait ::advanceAudio
                    }
                    if {$played < 24000 || [dict get $status acceptedFrames] != $played || [dict get $status queuedFrames] != 0} {
                        error "HLS PCM did not finish playback: $status"
                    }
                    puts "Windows played $played decoded HLS frames from the original silence fixture"
                }
                if {$mediaFixture::requested ne {/start /radio/master.m3u8 /radio/live.m3u8 /radio/10.ts /radio/11.ts /radio/live.m3u8 /radio/12.ts}} {
                    error "unexpected HLS requests: $mediaFixture::requested"
                }
            }
        } finally {after cancel $timer; $h close}
    }
    set stopAfterOne 0
    set mediaFixture::gap 1
    set mediaFixture::refresh 0
    set finished {}
    set h [::machteld::hls start $base/radio/live.m3u8 {apply {{s event item} {
        if {$event eq "error"} {set ::finished [dict get $item errorcode]}
    }}}]
    set timeout [after 8000 {set ::finished timeout}]
    try {
        vwait finished
        if {$finished ne {MACHTELD HLS gap}} {error "missing sequence was hidden: $finished"}
    } finally {after cancel $timeout; $h close}
    set h [::machteld::hls start $base/held.m3u8 {apply {{s event item} {error "callback after stop"}}}]
    set timeout [after 5000 {set ::mediaFixture::waiting timeout}]
    try {
        vwait ::mediaFixture::waiting
        if {$mediaFixture::waiting ne "1"} {error "fixture did not start pending request"}
        $h stop
        after cancel $timeout
        set timeout [after 5000 {set ::mediaFixture::abandoned timeout}]
        if {!$mediaFixture::abandoned} {vwait ::mediaFixture::abandoned}
        if {$mediaFixture::abandoned ne "1"} {error "stopping HLS did not close its open response"}
    } finally {after cancel $timeout; $h close}
} finally {
    if {[info exists decoder]} {$decoder close}
    if {[info exists output]} {$output close}
    close $listener
    foreach ch [dict keys $mediaFixture::peers] {mediaFixture::closePeer $ch}
}
set encrypted "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:1,\nx.ts\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:1,\ny.ts\n"
if {![catch {::machteld::audio playlist $base/list $encrypted} msg opts] || [dict get $opts -errorcode] ne {MACHTELD AUDIO unsupported}} {
    error "mixed encrypted playlist was accepted"
}
puts "HLS delivered three original AAC segments in order across overlapping playlists and stopped all further requests"
