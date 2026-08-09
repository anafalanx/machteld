# worker.tcl -- ::machteld::worker: the far side of a channel-mode child.
#
#   worker on  sum  {n}            { expr {$n * 2} }
#   worker on  hash {path {alg sha256}} { hash file $alg $path }
#   worker ops                     ;# what this worker answers, and with what
#   worker serve                   ;# read a line, dispatch, write a line, to EOF
#
# One JSON object per line, in and out. `json encode` escapes newlines, so a
# value can never split its own record -- which is what makes `gets` a safe frame
# reader and saves inventing a length prefix.
#
#   request   {id 7 op hash path C:/x.iso}
#   reply     {id 7 ok 1 result 9f86d0...}
#   failure   {id 7 ok 0 code {MACHTELD HASH notfound} msg "cannot read ..."}
#
# THE ARGUMENT LIST IS THE SCHEMA. `worker on hash {path}` says a hash request
# carries `path`, and the dispatcher pulls it out of the request dict by name.
# Two things follow that are worth having: the protocol documents itself, so
# `worker ops` can answer what this worker accepts; and a handler is necessarily
# a PROC, whose body Tcl compiles to local variable slots. That is not a style
# preference -- the same loop at top level runs 3.6x slower (docs/parallel.md),
# so a design that invited top-level handler bodies would hand most of the
# parallelism straight back.
#
# A HANDLER MUST NOT WRITE TO STDOUT. Stdout *is* the protocol: a stray `puts`
# injects a line that is not a reply, and the director either skips it or -- far
# worse -- reads it as an answer to something. Use `log`, which goes to stderr or
# to a file. This cannot be enforced from here without taking the channel away
# from the handler entirely, so it is stated instead, loudly.

namespace eval ::machteld {
    variable WORKER_OPS {}      ;# op -> the proc implementing it
}

proc ::machteld::worker {args} {
    variable WORKER_OPS
    set subs {on ops serve}
    set opts {}
    if {![llength $args]} {
        Fail WORKER usage "usage: worker on op args body | worker ops | worker serve"
    }
    set sub [lindex $args 0]
    if {$sub ni $subs} {
        Fail WORKER usage "worker: unknown subcommand \"$sub\": must be [join $subs {, }]"
    }

    if {$sub eq "on"} {
        if {[llength $args] != 4} { Fail WORKER usage "usage: worker on op arglist body" }
        lassign $args _ op arglist body
        if {$op eq ""} { Fail WORKER badvalue "worker: an operation needs a name" }
        # Defined as a real proc rather than kept as a script to eval: a proc body
        # is compiled once, an evaled script is re-parsed on every request.
        #
        # In the CALLER'S namespace, not machteld's. A handler body has to read
        # like the code around it: a tool written inside `namespace eval ::mytool`
        # calls its own helpers by bare name everywhere else, and a body compiled
        # somewhere else fails on them -- not at definition time but at REQUEST
        # time, arriving as a per-item failure reply from another process, which
        # is the latest and least legible place to learn about a typo'd scope.
        # Defining it here means the ordinary namespace rule applies to handlers
        # exactly as it applies to every other line in that file: bare palette
        # verbs need `namespace path ::machteld`, which such a namespace needs
        # anyway. At global scope -- what a small worker script uses -- both the
        # palette and the script's own procs resolve with nothing declared.
        set ns [uplevel 1 {namespace current}]
        if {$ns eq "::"} { set ns "" }
        set pname ${ns}::WorkerOp_$op
        proc $pname $arglist $body
        dict set WORKER_OPS $op $pname
        return
    }

    if {$sub eq "ops"} {
        if {[llength $args] != 1} { Fail WORKER usage "usage: worker ops" }
        # Rebuilt with defaults, so this answers what a request may contain and
        # not merely what it is called: `{path {alg sha256}}` says alg is optional
        # while a bare `path` says it is not. `info args` alone loses that.
        set out [dict create]
        dict for {op pname} $WORKER_OPS {
            set spec {}
            foreach aname [info args $pname] {
                if {[info default $pname $aname dflt]} {
                    lappend spec [list $aname $dflt]
                } else {
                    lappend spec $aname
                }
            }
            dict set out $op $spec
        }
        return $out
    }

    # SERVE. Blocking on purpose: a worker's whole job is to answer, so there is
    # nothing else for it to be doing between requests, and a blocking `gets` is
    # both simpler and cheaper than an event loop that never has a second source.
    if {[llength $args] != 1} { Fail WORKER usage "usage: worker serve" }
    fconfigure stdin  -translation lf -encoding utf-8
    fconfigure stdout -translation lf -encoding utf-8 -buffering line
    while {[gets stdin line] >= 0} {
        if {$line eq ""} continue
        WorkerAnswer $line
    }
    return
}

# One request in, one reply out. Nothing in here may throw: a worker that dies on
# a malformed line takes its in-flight item with it and forces the director to
# notice a death, requeue, and respawn -- an expensive way to report a typo.
proc ::machteld::WorkerAnswer {line} {
    variable WORKER_OPS
    if {[catch {json decode $line} req]} {
        puts [json encode [dict create id -1 ok 0 code {MACHTELD WORKER parse} \
                                       msg "request is not valid JSON"]]
        return
    }
    set id [expr {[dict exists $req id] ? [dict get $req id] : -1}]
    set op [expr {[dict exists $req op] ? [dict get $req op] : ""}]
    if {![dict exists $WORKER_OPS $op]} {
        puts [json encode [dict create id $id ok 0 code {MACHTELD WORKER notfound} \
                                       msg "no handler for \"$op\""]]
        return
    }
    set pname [dict get $WORKER_OPS $op]

    # Bind the handler's parameters from the request by NAME. A parameter with a
    # default may be omitted; one without may not, and saying which is missing
    # beats letting the handler fail on an empty string three lines later.
    #
    # `info default`, NOT `info args`. `info args` returns parameter NAMES only:
    # for `{path {alg sha256}}` it answers `path alg`, with the default nowhere in
    # sight -- so a length check on the result can never see one, and every
    # optional parameter looks required. `info default` is the only way to ask.
    set argv {}
    foreach aname [info args $pname] {
        if {[dict exists $req $aname]} {
            lappend argv [dict get $req $aname]
        } elseif {$aname eq "args"} {
            ;# the catch-all: absent means empty, never missing
        } elseif {[info default $pname $aname dflt]} {
            lappend argv $dflt
        } else {
            puts [json encode [dict create id $id ok 0 code {MACHTELD WORKER usage} \
                                           msg "$op needs \"$aname\""]]
            return
        }
    }

    if {[catch {$pname {*}$argv} res opts]} {
        # The error contract crosses the process boundary as DATA. The code
        # travels so the director can re-raise something a caller can still
        # `trap` on -- an error that arrives as prose has stopped being part of
        # the contract.
        set code [dict get $opts -errorcode]
        puts [json encode [dict create id $id ok 0 code $code msg $res]]
        return
    }
    puts [json encode [dict create id $id ok 1 result $res]]
}
