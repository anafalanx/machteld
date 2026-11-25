# HLS transport for Tcl applications. Each live session owns one bounded
# asynchronous HTTP request and one reload timer.
namespace eval ::machteld::media {}
oo::class create ::machteld::media::Hls {
    variable callback playlist stream timer state body kind last item queue ended delay depth

    constructor {url prefix} {
        if {![llength $prefix]} {::machteld::Fail HLS usage "a callback command prefix is required"}
        set callback $prefix
        set playlist $url
        set stream {}
        set state running
        set queue {}
        set last -1
        set ended 0
        set depth 0
        set timer [after 0 [namespace code {my reload}]]
    }

    destructor {my stop}
    method close {} {my destroy}
    method status {} {return [dict create state $state sequence $last url $playlist]}
    method stop {} {
        if {[info exists timer] && $timer ne {}} {after cancel $timer; set timer {}}
        if {[info exists stream] && $stream ne {}} {$stream close; set stream {}}
        if {[info exists state] && $state eq "running"} {set state stopped}
        set body {}
        set queue {}
    }
    method fail {message options} {
        if {$state ne "running"} return
        my stop
        set state error
        uplevel #0 [list {*}$callback [self] error [dict create message $message errorcode [dict get $options -errorcode]]]
    }
    method fetch {type url} {
        set timer {}
        set kind $type
        set body [binary format x0]
        set limit [expr {$type eq "playlist" ? "1M" : "16M"}]
        set stream [::machteld::http stream $url -maxbody $limit]
        $stream readable [namespace code {my receive}]
    }
    method reload {} {
        try {my fetch playlist $playlist} on error {m o} {my fail $m $o}
    }
    method advance {} {
        set timer {}
        if {[llength $queue]} {
            set item [lindex $queue 0]
            set queue [lrange $queue 1 end]
            my fetch segment [dict get $item url]
        } elseif {$ended} {
            set state done
            uplevel #0 [list {*}$callback [self] end [dict create sequence $last]]
        } else {
            set timer [after $delay [namespace code {my reload}]]
        }
    }
    method receive {token} {
        if {$state ne "running" || $stream ne $token} return
        set me [self]
        try {
            set event [$token next]
            switch -- [dict get $event event] {
                headers {
                    if {[dict get $event status] < 200 || [dict get $event status] > 299} {
                        ::machteld::Fail HLS http "HLS $kind returned HTTP [dict get $event status]"
                    }
                    if {$kind eq "playlist"} {set playlist [dict get $event url]}
                }
                data {append body [dict get $event data]}
                eof {
                    $token close
                    set stream {}
                    if {$kind eq "playlist"} {
                        set result [::machteld::audio playlist $playlist $body]
                        set body {}
                        if {[dict get $result kind] eq "master"} {
                            if {[incr depth] > 4} {::machteld::Fail HLS playlist "too many nested master playlists"}
                            set best -1
                            foreach candidate [dict get $result variants] {
                                set bandwidth [dict get $candidate bandwidth]
                                if {$bandwidth > $best} {set playlist [dict get $candidate url]; set best $bandwidth}
                            }
                            set timer [after 0 [namespace code {my reload}]]
                            return
                        }
                        set queue {}
                        foreach segment [dict get $result segments] {
                            set sequence [dict get $segment sequence]
                            if {$sequence > $last} {lappend queue $segment}
                        }
                        if {$last >= 0 && [llength $queue] && [dict get [lindex $queue 0] sequence] > $last+1} {
                            ::machteld::Fail HLS gap "live playlist no longer contains the next sequence [expr {$last+1}]"
                        }
                        set ended [dict get $result ended]
                        set delay [expr {max(500,round(500*[dict get $result target]))}]
                    } else {
                        set elementary [::machteld::audio demux $body]
                        set body {}
                        set last [dict get $item sequence]
                        uplevel #0 [list {*}$callback $me segment [dict merge $item $elementary]]
                        if {![info object isa object $me] || $state ne "running"} return
                    }
                    my advance
                    return
                }
                cancelled {return}
            }
            $token readable [namespace code {my receive}]
        } on error {message options} {
            if {[info object isa object $me]} {my fail $message $options}
        }
    }
    unexport fail fetch reload advance receive
}

proc ::machteld::hls {operation args} {
    if {$operation ne "start" || [llength $args] != 2} {Fail HLS usage {hls start playlistUrl commandPrefix}}
    lassign $args url callback
    if {![regexp -nocase {^https?://[^[:space:]]+$} $url]} {Fail HLS usage {an HTTP or HTTPS playlist URL is required}}
    return [::machteld::media::Hls new $url $callback]
}
::machteld::MetaDefine hls [dict create kind tcl args {operation args} domain HLS \
    codes {gap http playlist usage} doc machteld/command/hls \
    subcommands [dict create start [dict create doc machteld/command/hls#start]]]
