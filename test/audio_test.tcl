package require machteld 30-
set here [file dirname [file normalize [info script]]]
set sourceDir [file join $here fixtures audio]
set checks 0
proc verify {test message} {
    if {![uplevel 1 [list expr $test]]} {error $message}
    incr ::checks
}
proc getBytes {file} {set ch [open $file rb]; try {read $ch} finally {close $ch}}
proc drainDecoder {d dest} {
    upvar 1 $dest result
    while {1} {
        set frame [$d read]
        if {[dict get $frame state] ne "data"} {return [dict get $frame state]}
        if {[dict get $frame rate] != 48000 || [dict get $frame channels] != 2 ||
                [dict get $frame format] ne "f32le"} {error "unexpected decoded PCM format"}
        append result [dict get $frame pcm]
    }
}
proc decode {codec bytes widths} {
    set d [::machteld::audio decoder $codec]
    try {
        set pcm [binary format x0]
        set index 0
        set turn 0
        while {$index < [string length $bytes]} {
            set n [lindex $widths [expr {$turn % [llength $widths]}]]
            $d feed [string range $bytes $index [expr {$index+$n-1}]]
            incr index $n
            incr turn
            drainDecoder $d pcm
        }
        $d finish
        if {[drainDecoder $d pcm] ne "eof"} {error "decoder did not drain"}
        return $pcm
    } finally {$d close}
}
proc verifyTone {pcm codec} {
    set frames [expr {[string length $pcm]/8}]
    verify {$frames >= 24000 && $frames <= 32000} "$codec decoded duration was $frames frames"
    # Inside the original 0.5 s sine, after encoder delay, before end padding.
    binary scan [string range $pcm [expr {9600*8}] [expr {19200*8-1}]] r* samples
    set count 0
    set sum 0.0
    set prev 0.0
    foreach {left right} $samples {
        if {$prev <= 0 && $left > 0} {incr count}
        set sum [expr {$sum+$left*$left}]
        set prev $left
    }
    set rms [expr {sqrt($sum/9600)}]
    verify {$count >= 86 && $count <= 90 && $rms > 0.13 && $rms < 0.44} "$codec tone: $count crossings, rms $rms"
}
foreach {codec file} {mp3 tone.mp3 aac tone-lc.aac aac tone-he.aac} {
    set bytes [getBytes [file join $sourceDir $file]]
    set whole [decode $codec $bytes {65536}]
    verifyTone $whole $file
    set pieces [decode $codec $bytes {1 3 7 37 613 31 4096}]
    verify {$whole eq $pieces} "$file decode changed with chunk boundaries"
    set d [::machteld::audio decoder $codec]
    try {
        $d feed [string range $bytes 0 end-15]
        $d finish
        set rc [catch {drainDecoder $d rest} msg opts]
        verify {$rc && [dict get $opts -errorcode] eq {MACHTELD AUDIO format}} "$file truncation was hidden"
    } finally {$d close}
}
foreach codec {mp3 aac} {
    set d [::machteld::audio decoder $codec]
    try {
        set rc [catch {$d feed [binary format x262145]} msg opts]
        verify {$rc && [dict get $opts -errorcode] eq {MACHTELD AUDIO limit}} "$codec input cap missing"
        $d feed [binary format H* 0021006415]
        $d finish
        set rc [catch {$d read} msg opts]
        verify {$rc && [dict get $opts -errorcode] eq {MACHTELD AUDIO format}} "$codec accepted malformed input"
    } finally {$d close}
}
# An offline runner may lack audio hardware. The --device qualification below
# requires an actual endpoint, renders silence and waits for queued frames.
if {$argv in {{--device} {--audible}}} {
    package require Tk
    wm withdraw .
    label .pulse -text 0
    set pulse 0
    proc pulse {} {
        .pulse configure -text [incr ::pulse]
        set ::heartbeat [after 5 pulse]
    }
    pulse
    proc awaitDevice {o target} {
        set deadline [expr {[clock milliseconds]+8000}]
        while {1} {
            set status [$o status]
            if {[dict get $status state] eq $target} {return $status}
            if {[dict get $status state] eq "error" || [clock milliseconds] >= $deadline} {error "audio device: $status"}
            after 5 {set ::audioTick 1}
            vwait ::audioTick
        }
    }
    for {set i 0} {$i < 3} {incr i} {
        set o [::machteld::audio output 48000 2]
        try {
            set count 0
            foreach n {256 1009 3200} {
                set accepted [$o write [binary format x[expr {8*$n}]]]
                incr count $n
                verify {$accepted == 8*$n} "output failed to accept ordered buffer"
            }
            if {$i == 1} {
                $o stop
                awaitDevice $o stopped
                verify {[catch {$o write [binary format x8]}]} "stopped stream accepted input"
            } else {
                $o finish
                set result [awaitDevice $o done]
                verify {[dict get $result queuedFrames] == 0 && [dict get $result acceptedFrames] == $count} "incomplete drain"
            }
        } finally {$o close}
    }
    if {$argv eq {--audible}} {
        set o [::machteld::audio output 48000 2]
        try {
            set tone [decode mp3 [getBytes [file join $sourceDir tone.mp3]] {4096}]
            verify {[$o write $tone] == [string length $tone]} "audible fixture was truncated"
            $o finish
            awaitDevice $o done
            puts "The endpoint played the half-second 440 Hz tone. Record the listener's observation separately."
        } finally {$o close}
    }
    after cancel $heartbeat
    verify {$pulse >= 3 && [.pulse cget -text] == $pulse} "Tk stopped processing callbacks during audio playback"
    destroy .
}
puts "$checks audio checks passed"
