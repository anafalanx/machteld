# macht.tcl -- the macht family: command engines (docs/engine.md).
#
# One verb owns an engine's whole life, in the palette's usual shape:
#     macht start|stop|status|load|def|run|free|stats|conform
#
# The engine is the executable itself in engine mode (--machteld-engine),
# an ordinary supervised child speaking protocol 1 over binary stdio
# frames; a sidecar started with -exe speaks the same wire. There is no
# translation and no oracle: kernels are Lua, written by the program
# author, trusted as written; the machine is proven by the build gates.
# The engine is a cache, never the truth: any engine may be killed at any
# instant (budget does exactly that) and the program starts another.

namespace eval ::machteld::macht {
    namespace path ::machteld ;# child, json, version, cli resolve bare
    variable SEQ 0            ;# engine token counter
    variable E                ;# per-token engine records (array of dicts)
    variable DEFAULT ""       ;# lazily started default engine token
    variable WAKE             ;# per-channel vwait flags
    array set E {}
    array set WAKE {}
}

proc ::machteld::macht::Fail {code msg} {
    return -level 2 -code error -errorcode [list MACHTELD MACHT $code] $msg
}

# ---------- frames ----------

proc ::machteld::macht::WaitReadable {ch ms} {
    variable WAKE
    set WAKE($ch) ""
    set timer [after $ms [list set ::machteld::macht::WAKE($ch) timeout]]
    chan event $ch readable [list set ::machteld::macht::WAKE($ch) ready]
    vwait ::machteld::macht::WAKE($ch)
    chan event $ch readable {}
    after cancel $timer
    return $WAKE($ch)
}

# Read exactly n bytes; deadline < 0 waits forever. Engine death raises
# died; a passed deadline kills the engine and raises budget.
proc ::machteld::macht::ReadExact {tok n deadline} {
    variable E
    set ch [dict get $E($tok) out]
    set data ""
    while {[string length $data] < $n} {
        set chunk [chan read $ch [expr {$n - [string length $data]}]]
        append data $chunk
        if {[string length $data] == $n} { break }
        if {[chan eof $ch]} {
            Died $tok
        }
        set wait 3600000
        if {$deadline >= 0} {
            set wait [expr {$deadline - [clock milliseconds]}]
            if {$wait <= 0} { Budget $tok }
        }
        if {[WaitReadable $ch $wait] eq "timeout" && $deadline >= 0} {
            Budget $tok
        }
    }
    return $data
}

proc ::machteld::macht::SendFrame {tok payload} {
    variable E
    set ch [dict get $E($tok) in]
    set bytes [encoding convertto utf-8 $payload]
    if {[catch {
        chan puts -nonewline $ch [binary format i [string length $bytes]]
        chan puts -nonewline $ch $bytes
        chan flush $ch
    }]} {
        Died $tok
    }
}

proc ::machteld::macht::RecvReply {tok deadline} {
    set hdr [ReadExact $tok 4 $deadline]
    binary scan $hdr iu len
    return [json decode [encoding convertfrom utf-8 \
        [ReadExact $tok $len $deadline]]]
}

# Engine death and budget kill: both end the engine; only the code differs.
proc ::machteld::macht::Died {tok} {
    Cleanup $tok
    Fail died "engine $tok exited or closed its pipe; its handles are gone"
}
proc ::machteld::macht::Budget {tok} {
    Cleanup $tok
    Fail budget "budget exhausted: engine $tok was killed; its handles are gone"
}
proc ::machteld::macht::Cleanup {tok} {
    variable E
    variable DEFAULT
    if {![info exists E($tok)]} { return }
    set c [dict get $E($tok) child]
    catch {child kill $c}
    catch {child wait $c -timeout 2s}
    catch {child close $c}
    unset E($tok)
    if {$DEFAULT eq $tok} { set DEFAULT "" }
}

# One request/reply exchange. In-order replies are the wire contract; a
# reply whose id does not match is a protocol violation.
proc ::machteld::macht::Ask {tok req {budgetMs -1}} {
    variable E
    set id [dict get $E($tok) seq]
    dict set E($tok) seq [expr {$id + 1}]
    dict set req id $id
    SendFrame $tok [json encode -plain -dict $req]
    set deadline [expr {$budgetMs >= 0 ? [clock milliseconds] + $budgetMs : -1}]
    set r [RecvReply $tok $deadline]
    if {![dict exists $r id] || [dict get $r id] != $id} {
        Cleanup $tok
        Fail protocol "engine $tok answered out of order; it was stopped"
    }
    if {![dict get $r ok]} {
        Fail [dict get $r error code] [dict get $r error message]
    }
    return $r
}

# ---------- lifecycle ----------

proc ::machteld::macht::StartEngine {threads memory exe} {
    variable SEQ
    variable E
    if {$exe eq ""} {
        set cmd [list [info nameofexecutable] --machteld-engine]
        if {$threads > 0} { lappend cmd $threads }
    } else {
        set cmd [list $exe]
    }
    set opts {}
    if {$memory ne ""} { lappend opts -mem $memory }
    if {[catch {child start -channels {*}$opts -- {*}$cmd} c]} {
        Fail noengine "engine did not start: $c"
    }
    set io [child info $c]
    set in [dict get $io stdin]
    set out [dict get $io stdout]
    chan configure $in -translation binary -buffering none -blocking 1
    chan configure $out -translation binary -blocking 0
    set tok "macht#[incr SEQ]"
    set E($tok) [dict create child $c in $in out $out seq 1 caps {} \
        pid [dict get $io pid]]
    if {[catch {
        Ask $tok [dict create op hello protocol 1 host machteld \
            version [::machteld::version]]
    } h opts2]} {
        catch {Cleanup $tok}
        return -options $opts2 $h
    }
    if {[dict get $h protocol] != 1} {
        Cleanup $tok
        Fail protocol "engine speaks protocol [dict get $h protocol], not 1"
    }
    dict set E($tok) caps [dict get $h capabilities]
    dict set E($tok) engine [dict get $h engine]
    return $tok
}

# The lazy default: the first work subcommand starts one engine with
# default limits; an explicit `macht start` exists for control and for
# additional engines.
proc ::machteld::macht::Target {optsVar} {
    upvar 1 $optsVar opts
    variable E
    variable DEFAULT
    if {[dict exists $opts -engine]} {
        set tok [dict get $opts -engine]
        dict unset opts -engine
        if {![info exists E($tok)]} {
            Fail noengine "no engine $tok"
        }
        return $tok
    }
    if {$DEFAULT eq "" || ![info exists E($DEFAULT)]} {
        set DEFAULT [StartEngine 0 "" ""]
    }
    return $DEFAULT
}

proc ::machteld::macht::Options {argsIn allowed} {
    set opts [dict create]
    set rest {}
    for {set i 0} {$i < [llength $argsIn]} {incr i} {
        set a [lindex $argsIn $i]
        if {[dict exists $allowed $a]} {
            if {[dict get $allowed $a]} {
                incr i
                if {$i >= [llength $argsIn]} {
                    Fail usage "option $a needs a value"
                }
                dict set opts $a [lindex $argsIn $i]
            } else {
                dict set opts $a 1
            }
        } else {
            lappend rest $a
        }
    }
    return [list $opts $rest]
}

proc ::machteld::macht::Require {tok cap} {
    variable E
    if {$cap ni [dict get $E($tok) caps]} {
        Fail refused "engine $tok does not declare capability $cap"
    }
}

# ---------- the public family ----------

proc ::machteld::macht {sub args} {
    variable ::machteld::macht::E
    variable ::machteld::macht::DEFAULT
    switch -- $sub {
        start {
            lassign [::machteld::macht::Options $args \
                {-threads 1 -memory 1 -exe 1}] opts rest
            if {[llength $rest]} {
                ::machteld::macht::Fail usage "start takes only options"
            }
            set threads 0
            if {[dict exists $opts -threads]} {
                set threads [dict get $opts -threads]
                if {![string is integer -strict $threads] || $threads < 1} {
                    ::machteld::macht::Fail badvalue \
                        "-threads is a positive integer"
                }
            }
            set memory [expr {[dict exists $opts -memory]
                              ? [dict get $opts -memory] : ""}]
            set exe [expr {[dict exists $opts -exe]
                           ? [dict get $opts -exe] : ""}]
            return [::machteld::macht::StartEngine $threads $memory $exe]
        }
        stop {
            set tok [expr {[llength $args] ? [lindex $args 0] : $DEFAULT}]
            if {$tok eq "" || ![info exists E($tok)]} {
                ::machteld::macht::Fail noengine "no engine to stop"
            }
            catch {::machteld::macht::Ask $tok [dict create op quit] 500}
            ::machteld::macht::Cleanup $tok
            return
        }
        status {
            set tok [expr {[llength $args] ? [lindex $args 0] : $DEFAULT}]
            if {$tok eq "" || ![info exists E($tok)]} {
                ::machteld::macht::Fail noengine "no engine to observe"
            }
            set r [::machteld::macht::Ask $tok [dict create op stats]]
            dict unset r id
            dict unset r ok
            dict set r pid [dict get $E($tok) pid]
            dict set r capabilities [dict get $E($tok) caps]
            return $r
        }
        load {
            lassign [::machteld::macht::Options $args \
                {-engine 1 -csv 1 -lines 1 -schema 1 -header 0}] opts rest
            if {[llength $rest]} {
                ::machteld::macht::Fail usage \
                    "load takes -csv PATH or -lines PATH plus options"
            }
            set tok [::machteld::macht::Target opts]
            if {[dict exists $opts -csv] == [dict exists $opts -lines]} {
                ::machteld::macht::Fail usage \
                    "load takes exactly one of -csv PATH or -lines PATH"
            }
            if {[dict exists $opts -lines]} {
                ::machteld::macht::Require $tok load.lines
                set req [dict create op load format lines \
                    path [file normalize [dict get $opts -lines]]]
            } else {
                ::machteld::macht::Require $tok load.csv
                set req [dict create op load format csv \
                    path [file normalize [dict get $opts -csv]]]
                if {[dict exists $opts -schema]} {
                    dict set req schema [lrange [dict get $opts -schema] 0 end]
                }
                if {[dict exists $opts -header]} {
                    dict set req header 1
                }
            }
            set r [::machteld::macht::Ask $tok $req]
            return [dict get $r handle]
        }
        def {
            lassign [::machteld::macht::Options $args {-engine 1}] opts rest
            if {[llength $rest] != 2} {
                ::machteld::macht::Fail usage "def takes NAME CHUNK"
            }
            set tok [::machteld::macht::Target opts]
            ::machteld::macht::Require $tok lua
            lassign $rest name chunk
            ::machteld::macht::Ask $tok \
                [dict create op def name $name chunk $chunk]
            return $name
        }
        run {
            lassign [::machteld::macht::Options $args \
                {-engine 1 -shards 1 -reduce 1 -budget 1 -json 1}] opts rest
            if {[llength $rest] < 1} {
                ::machteld::macht::Fail usage "run takes NAME ?ARG ...?"
            }
            set tok [::machteld::macht::Target opts]
            ::machteld::macht::Require $tok lua
            set req [dict create op run name [lindex $rest 0]]
            set wireArgs {}
            foreach a [lrange $rest 1 end] {
                # J7 (plan-machteld-015): a TYPED json value refuses at the
                # boundary BEFORE the handle scan below can shimmer it to a
                # plain string - the engine's own json map (bool -> 1/0) is
                # contracted law, and silent degradation through it would
                # recreate the ambiguity typed mode ends. The probe comes
                # first: regexp stringifies its subject.
                if {![catch {json type $a}]} {
                    ::machteld::macht::Fail badvalue \
                        "a typed json value cannot cross the engine boundary; unwrap it first"
                }
                if {[regexp {^(pool|res)#\d+$} $a]} {
                    lappend wireArgs [dict create handle $a]
                } else {
                    lappend wireArgs $a
                }
            }
            if {[dict exists $opts -json]} {
                lappend wireArgs [json decode [dict get $opts -json]]
            }
            if {[llength $wireArgs]} {
                dict set req args $wireArgs
            }
            if {[dict exists $opts -shards]} {
                ::machteld::macht::Require $tok shards
                dict set req shards [dict get $opts -shards]
            }
            if {[dict exists $opts -reduce]} {
                ::machteld::macht::Require $tok reduce
                dict set req reduce [dict get $opts -reduce]
            }
            set budgetMs -1
            if {[dict exists $opts -budget]} {
                set budgetMs [::machteld::cli duration \
                    [dict get $opts -budget]]
            }
            set r [::machteld::macht::Ask $tok $req $budgetMs]
            if {[dict exists $r spilled]} {
                return [dict get $r handle]
            }
            return [dict get $r value]
        }
        free {
            lassign [::machteld::macht::Options $args {-engine 1}] opts rest
            if {[llength $rest] != 1} {
                ::machteld::macht::Fail usage "free takes HANDLE"
            }
            set tok [::machteld::macht::Target opts]
            ::machteld::macht::Ask $tok \
                [dict create op free handle [lindex $rest 0]]
            return
        }
        stats {
            set tok [expr {[llength $args] ? [lindex $args 0] : $DEFAULT}]
            if {$tok eq "" || ![info exists E($tok)]} {
                ::machteld::macht::Fail noengine "no engine to report"
            }
            set r [::machteld::macht::Ask $tok [dict create op stats]]
            dict unset r id
            dict unset r ok
            return $r
        }
        conform {
            if {[llength $args] < 1} {
                ::machteld::macht::Fail usage "conform takes EXE ?ARG ...?"
            }
            return [::machteld::macht::Conform [lindex $args 0] \
                [lrange $args 1 end]]
        }
        default {
            ::machteld::macht::Fail usage "unknown subcommand '$sub'\
                (start, stop, status, load, def, run, free, stats, conform)"
        }
    }
}

# ---------- conformance ----------

# The bounded fixture suite behind `macht conform`: does EXE behave as a
# protocol-1 engine? Every read is deadlined; a hang is a failed check,
# never a hung program. Returns {ok 0|1 checks {{name 0|1} ...}}.
proc ::machteld::macht::Conform {exe extra} {
    variable E
    variable SEQ
    if {[catch {child start -channels -- $exe {*}$extra} c]} {
        Fail noengine "conform target did not start: $c"
    }
    set io [child info $c]
    set in [dict get $io stdin]
    set out [dict get $io stdout]
    chan configure $in -translation binary -buffering none -blocking 1
    chan configure $out -translation binary -blocking 0
    set tok "conform#[incr SEQ]"
    set E($tok) [dict create child $c in $in out $out seq 1 caps {} \
        pid [dict get $io pid]]
    set checks {}
    set caps {}
    set alive 1
    foreach step {
        hello-negotiates
        unknown-op-is-coded
        lua-def-run
        int64-exact
        quit-clean
    } {
        set pass 0
        if {$alive} {
            switch -- $step {
                hello-negotiates {
                    if {![catch {
                        set h [Ask $tok [dict create op hello protocol 1 \
                            host machteld version [::machteld::version]] 2000]
                    }]} {
                        set caps [dict get $h capabilities]
                        set pass [expr {[dict get $h protocol] == 1}]
                    } else {
                        set alive [info exists E($tok)]
                    }
                }
                unknown-op-is-coded {
                    if {![catch {Ask $tok \
                            [dict create op zzz-nonsense] 2000} r ropts]} {
                        set pass 0
                    } else {
                        set pass [expr {[lindex \
                            [dict get $ropts -errorcode] 2] eq "usage"}]
                        set alive [info exists E($tok)]
                    }
                }
                lua-def-run {
                    if {"lua" ni $caps} {
                        set pass 1    ;# not declared, not required
                    } elseif {![catch {
                        Ask $tok [dict create op def name conform_double \
                            chunk {function conform_double(x) return 2*x end}] 2000
                        set r [Ask $tok [dict create op run \
                            name conform_double args [list 21]] 2000]
                    }]} {
                        set pass [expr {[dict get $r value] == 42}]
                    } else {
                        set alive [info exists E($tok)]
                    }
                }
                int64-exact {
                    if {"lua" ni $caps} {
                        set pass 1
                    } elseif {![catch {
                        Ask $tok [dict create op def name conform_echo \
                            chunk {function conform_echo(x) return x end}] 2000
                        set r [Ask $tok [dict create op run name conform_echo \
                            args [list 9007199254740993]] 2000]
                    }]} {
                        set pass [expr {[dict get $r value] == 9007199254740993}]
                    } else {
                        set alive [info exists E($tok)]
                    }
                }
                quit-clean {
                    if {![catch {Ask $tok [dict create op quit] 2000}]} {
                        set w [child wait $c -timeout 3s]
                        set pass [expr {[dict get $w exit] == 0}]
                    }
                }
            }
        }
        lappend checks [list $step $pass]
    }
    catch {Cleanup $tok}
    set ok 1
    foreach chk $checks {
        if {![lindex $chk 1]} { set ok 0 }
    }
    return [dict create ok $ok checks $checks]
}

# One verb, wrap's shape: the family forms are documented prose, not
# manifest subcommand claims -- adding those means adding the full
# per-subcommand reference apparatus, the way child does it.
::machteld::MetaDefine macht [dict create kind tcl args args domain MACHT \
    codes {usage badvalue noengine died nohandle type lua budget memory \
           refused protocol conform} \
    options {-engine -threads -memory -exe -csv -lines -schema -header \
             -shards -reduce -budget -json} \
    doc machteld/command/macht]
