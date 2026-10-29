package require machteld
fconfigure stdout -translation binary -buffering none
switch -- [lindex $argv 0] {
    flood-out - flood-err - flood-both {
        set mode [lindex $argv 0]
        fconfigure stderr -translation binary -buffering none
        for {set i 1} {$i <= 64} {incr i} {
            if {$mode in {flood-out flood-both}} {
                puts [json encode -dict [dict create type progress value $i message [string repeat x 60000]]]
            }
            if {$mode in {flood-err flood-both}} {
                puts -nonewline stderr [string repeat [format %02d $i] 32768]
            }
        }
        puts [json encode -dict [dict create type progress value 99 message finished-writing]]
        puts {{"type":"complete"}}
    }
    oversize { puts -nonewline [string repeat x 70000] }
    partial { puts -nonewline {"unfinished"} }
    duplicate { puts {{"type":"complete","type":"complete"}} }
    invalidutf8 { puts [binary format H* ff] }
    incomplete { puts {{"type":"progress","value":1,"message":"no completion"}} }
    aftercomplete { puts {{"type":"complete"}}; puts {{"type":"complete"}} }
    rows {
        for {set i 0} {$i < 501} {incr i} {
            puts {{"type":"row","name":"x","path":"x","kind":"file","size":0}}
        }
    }
    default { exit 7 }
}
