# spike/pool/worker.tcl -- the far side of a channel-mode worker.
#
# Reads one JSON object per line, calls a handler, writes one JSON object per
# line. Nothing else. The framing is newline-delimited JSON because `json encode`
# escapes newlines inside strings, so a result can never split its own record --
# which is the property that makes `gets` a safe frame reader.
#
# Handlers live in PROCS on purpose: a hot loop at top level runs 3.6x slower
# (docs/parallel.md), so a worker template that invited top-level work would give
# most of the parallelism straight back.

fconfigure stdin  -translation lf -encoding utf-8
fconfigure stdout -translation lf -encoding utf-8 -buffering line

# --- handlers ---------------------------------------------------------------
proc h_sum {req} {
    set n [dict get $req n]
    set a 0.0
    for {set i 0} {$i < $n} {incr i} { set a [expr {$a + sqrt(double($i))}] }
    return [dict create sum $a]
}
proc h_echo  {req} { return [dict create echo [dict get $req text]] }
proc h_big   {req} { return [dict create blob [string repeat "x" [dict get $req bytes]]] }
proc h_boom  {req} { error "handler exploded on purpose" }
proc h_coded {req} { return -code error -errorcode {MACHTELD SPIKE deliberate} "a coded failure" }
proc h_die   {req} { exit 7 }
proc h_hang  {req} { after [dict get $req ms] ; return [dict create slept [dict get $req ms]] }
proc h_noise {req} {
    # Write to stderr as well, to see whether an unread stderr pipe can wedge us.
    puts stderr [string repeat "noise " [dict get $req lines]]
    return [dict create noised 1]
}

while {[gets stdin line] >= 0} {
    if {$line eq ""} continue
    if {[catch {json decode $line} req]} continue
    set id [expr {[dict exists $req id] ? [dict get $req id] : -1}]
    set op [expr {[dict exists $req op] ? [dict get $req op] : "sum"}]
    if {[catch {h_$op $req} res opts]} {
        # The error contract crosses the boundary as data: the code travels so the
        # director can re-raise something a caller can still `trap`.
        set code [dict get $opts -errorcode]
        puts [json encode [dict create id $id ok 0 code $code msg $res]]
    } else {
        puts [json encode [dict merge [dict create id $id ok 1] $res]]
    }
}
