# Deliberately malformed peers and teardown cases for the protocol tests.
package require machteld
if {[info exists ::env(MACHTELD_TEST_WORKER_SOURCE)]} {
    set sourceRoot [file dirname $::env(MACHTELD_TEST_WORKER_SOURCE)]
    foreach verb {worker pool pmap} {
        dict unset ::machteld::TCL_MANIFEST $verb
        source [file join $sourceRoot $verb.tcl]
    }
}
set mode [lindex $argv 0]
if {$mode eq "parent-exit"} {
    set p [pool create -width 2 -- [info nameofexecutable] \
        [file join [file dirname [info script]] worker_program.tcl]]
    pool submit $p {{op delay milliseconds 10000 text late} {op delay milliseconds 10000 text later}}
    foreach c [child list] { puts [dict get [child info $c] pid] }
    flush stdout
    exit 0
}
if {$mode eq "interpreter-delete"} {
  for {set iteration 0} {$iteration < 3} {incr iteration} {
    set slave [interp create]
    interp eval $slave { load {} machteldproc; load {} machteldjson }
    interp eval $slave [list source $::machteld::prelude]
    if {[info exists sourceRoot]} {
        foreach verb {worker pool pmap} {
            interp eval $slave [list dict unset ::machteld::TCL_MANIFEST $verb]
            interp eval $slave [list source [file join $sourceRoot $verb.tcl]]
        }
    }
    set p [interp eval $slave [list pool create -width 2 -- [info nameofexecutable] \
        [file join [file dirname [info script]] worker_program.tcl]]]
    interp eval $slave [list pool submit $p {{op delay milliseconds 10000 text late}}]
    set pids [interp eval $slave { lmap c [child list] { dict get [child info $c] pid } }]
    interp delete $slave
    foreach process_id $pids {
        set deadline [expr {[clock milliseconds] + 1000}]
        while {[clock milliseconds] < $deadline && ![catch {mtps info $process_id}]} { after 10 }
        puts [expr {[catch {mtps info $process_id}] ? "dead" : "alive"}]
    }
  }
    flush stdout
    exit 0
}

fconfigure stdin -translation lf -encoding utf-8
fconfigure stdout -translation binary -buffering none
if {$mode eq "no-read"} {
    # Pretend request zero finished without reading the megabyte input. A
    # director must not grow Tcl's output queue by feeding subsequent items.
    after 150
    puts stdout {{"id":0,"ok":1,"result":"pretend"}}
    after 10000
    exit
}
set request [json decode [gets stdin]]
set id [dict get $request id]
set mixed [expr {$mode eq "mixed-flood"}]
if {$mixed} { set mode [expr {$id % 2 ? "sustained-stderr" : "sustained-flood"}] }
switch -- $mode {
    unterminated {
        puts -nonewline stdout [string repeat x [lindex $argv 1]]
        after 10000
    }
    split-unicode {
        set bytes [encoding convertto utf-8 [json encode -plain -dict \
            [dict create id $id ok 1 result "caf\u00e9 \u4e16\u754c"]]]
        set split [string first [binary decode hex c3] $bytes]
        puts -nonewline stdout [string range $bytes 0 $split]
        after 30
        puts stdout [string range $bytes $split+1 end]
    }
    final {
        puts -nonewline stdout [encoding convertto utf-8 \
            [json encode -plain -dict [dict create id $id ok 1 result final]]]
    }
    partial-utf8 {
        puts -nonewline stdout [binary decode hex c3]
    }
    wrong-ok {
        puts stdout [json encode -plain -dict [dict create id $id ok nonsense result no]]
    }
    blank-flood {
        puts -nonewline stdout [string repeat \n 65536]
        puts stdout [json encode -plain -dict [dict create id $id ok 1 result alive]]
    }
    sustained-flood {
        fconfigure stderr -translation binary -buffering none
        # No sleeps or idle gaps: both pipes must keep progressing while the
        # director gives ordinary timers a chance to run during the flood.
        set floodTurns [expr {$mixed ? 4 : 16}]
        for {set turn 0} {$turn < $floodTurns} {incr turn} {
            puts -nonewline stdout [string repeat \n 65536]
            puts stderr "flood-turn=$turn [string repeat x 4096]"
        }
        puts stdout [json encode -plain -dict [dict create id $id ok 1 result alive]]
    }
    sustained-stderr {
        fconfigure stderr -translation binary -buffering none
        # Leave stdout mid-frame while continuously filling stderr, so a test
        # can require idle and timer progress before the final reply arrives.
        puts -nonewline stdout "\{\"id\":$id,\"ok\":1,\"result\":\""
        set floodTurns [expr {$mixed ? 64 : 128}]
        for {set turn 0} {$turn < $floodTurns} {incr turn} {
            puts stderr "flood-turn=$turn [string repeat x 65500]"
        }
        puts stdout "alive\"\}"
    }
    stderr-bytes {
        fconfigure stderr -translation binary -buffering none
        puts -nonewline stderr [string repeat [binary decode hex c3a9] 100000]
        puts stdout [json encode -plain -dict [dict create id $id ok 1 result alive]]
    }
    default { error "unknown fixture mode $mode" }
}
