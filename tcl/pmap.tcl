# pmap.tcl -- ::machteld::pmap: run a list of requests across a pool, in one call.
#
#   set digests [pmap $reqs -width 8 -- $exe --worker]
#   set replies [pmap $reqs -raw -width 8 -- $exe --worker]
#
# Sugar over `pool`, and it earns its place for two reasons rather than brevity.
#
# 1. THE POOL IS ALWAYS CLOSED. Create, submit, wait, close is four calls with
#    three chances to leak a pool of live processes if anything in between
#    raises. Here the close is in a finally, so a failure costs an error and not
#    a fistful of orphaned workers.
#
# 2. A WORKER'S FAILURE IS RE-RAISED WITH THE WORKER'S OWN ERRORCODE. `pool`
#    hands back replies, failures included, because a director usually wants to
#    see all of them. A *map* is different: `lmap` does not return error markers,
#    it propagates. So `pmap` returns plain results and, if any item failed,
#    raises that item's error carrying the code it was raised with in the worker
#    -- `{MACHTELD HASH notfound}`, not `{MACHTELD PMAP something}`. This is the
#    point at which the error contract has travelled the whole way: raised in one
#    process, `trap`-able in another, unflattened.
#
#    pmap's OWN failures -- a malformed call, a bad width -- are `{MACHTELD PMAP
#    ...}`, because the domain is the verb you called. A worker's failure is not
#    pmap's failure, and relabelling it would erase the only useful thing about
#    it.
#
# `-raw` opts out and returns the replies as `pool wait` gives them, for a caller
# that wants to inspect partial success rather than have it thrown.
#
# WHAT THIS CANNOT DO, and why: it takes an OP the worker registered, never a
# script block. A closure cannot cross a process boundary, and shipping script
# text per item would hand every worker an `eval` and defeat the bytecode caching
# that makes a handler worth calling twice. Workers are configured once, then fed
# data -- which is the same reason `worker on` defines a proc.
#
# Building the requests is ordinary Tcl and stays that way:
#
#     set reqs [lmap p $paths {list op digest path $p}]
#     set digests [pmap $reqs -width 8 -- $exe --worker]

proc ::machteld::pmap {args} {
    set subs {}
    set opts {-width -maxtries -timeout -raw}
    if {[llength $args] < 2} {
        Fail PMAP usage "usage: pmap requests ?-width n? ?-timeout dur? ?-raw? -- command ?arg ...?"
    }
    set reqs [lindex $args 0]
    set rest [lrange $args 1 end]

    set raw 0
    set width 4
    set maxtries 3
    set timeout 300000
    set i 0
    for {} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        if {$a eq "--"} { incr i ; break }
        if {![string match -* $a]} break
        if {$a eq "-raw"} { set raw 1 ; continue }
        if {$i + 1 >= [llength $rest]} { Fail PMAP usage "pmap: option \"$a\" needs a value" }
        set v [lindex $rest [expr {$i + 1}]]
        switch -- $a {
            -width    { set width $v }
            -maxtries { set maxtries $v }
            -timeout  { set timeout [_dur2ms PMAP $v] }
            default   { Fail PMAP usage "pmap: unknown option \"$a\"" }
        }
        incr i
    }
    set cmd [lrange $rest $i end]
    if {![llength $cmd]} { Fail PMAP usage "pmap: no command given" }
    if {![llength $reqs]} { return {} }

    # The pool's own validation is not duplicated here -- it would be a second
    # copy of a rule, and second copies drift. But a POOL error raised while
    # setting up a pmap is still a pmap failure to the caller, so the domain is
    # restated without inventing new codes.
    set p ""
    set rc [catch {
        set p [pool create -width $width -maxtries $maxtries -- {*}$cmd]
        pool submit $p $reqs
        pool wait $p -timeout [expr {$timeout / 1000}]s
    } replies opts]
    # ALWAYS, on every path. This is the whole first reason for the verb.
    if {$p ne ""} { catch {pool close $p} }
    if {$rc} {
        set code [dict get $opts -errorcode]
        if {[lindex $code 0] eq "MACHTELD" && [lindex $code 1] eq "POOL"} {
            Fail PMAP [lindex $code 2] $replies
        }
        return -options $opts $replies
    }

    if {$raw} { return $replies }

    # Plain results, and the first failure propagates. Scanned in submission
    # order, so which error a caller sees does not depend on which worker
    # happened to finish first -- the same reason the results are ordered.
    set out {}
    foreach r $replies {
        if {![dict exists $r ok] || ![dict get $r ok]} {
            set msg  [expr {[dict exists $r msg] ? [dict get $r msg] : "item failed"}]
            set code [expr {[dict exists $r code] ? [dict get $r code] : ""}]
            # A handler that raised a plain `error` has errorcode NONE, which
            # nothing can trap on. Passing that through would hand back a code
            # that means nothing, so it becomes a pmap failure instead.
            #
            # Raised through Fail rather than by assembling the errorcode into a
            # variable, and that is not a style choice: `-errorcode $code` is
            # invisible to BOTH the manifest derivation and the registry closure
            # test, which match on literals. So `failed` was a code this verb
            # could throw while declaring only `badvalue usage` and appearing
            # nowhere in the contract -- precisely the undeclared-code defect
            # those gates exist to catch, in the verb that came after them. It
            # surfaced from a break-test aimed at something else.
            if {$code eq "" || $code eq "NONE"} { Fail PMAP failed $msg }
            return -code error -errorcode $code $msg
        }
        lappend out [expr {[dict exists $r result] ? [dict get $r result] : ""}]
    }
    return $out
}
