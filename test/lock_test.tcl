package require machteld

# The contender and the owner run in separate instances of this executable.
if {[llength $argv]} {
    lassign $argv role path ready
    set token [lock try $path]
    switch -- $role {
        contender {
            puts [expr {$token eq "" ? "busy" : "acquired"}]
            if {$token ne ""} { lock release $token }
        }
        owner {
            if {$token eq ""} { error "test owner could not acquire the lock" }
            close [open $ready {WRONLY CREAT EXCL}]
            vwait ::forever
        }
        default { error "unknown test role" }
    }
    exit 0
}

proc check {name condition} {
    if {!$condition} { error "FAIL $name" }
    puts "ok   $name"
}
proc refused {code command} {
    expr {[catch {uplevel 1 $command} message options] &&
            [dict get $options -errorcode] eq [list MACHTELD LOCK $code]}
}
proc contender {path} {
    set r [run -timeout 20s -- [info nameofexecutable] $::script contender $path]
    if {[dict get $r status] ne "ok" || [dict get $r exit] != 0} {
        error "contender failed: $r"
    }
    return [string trim [encoding convertfrom -profile strict utf-8 [dict get $r out]]]
}

set script [file normalize [info script]]
set work [file tempdir]
try {
    set path [file join $work {édition 世界 🚉.lock}]
    set token [lock try $path]
    check "first owner gets a token and a coordination file" [expr {$token ne "" && [file isfile $path]}]
    check "second acquisition in one interpreter is busy" [expr {[lock try $path] eq ""}]
    check "a separate process receives busy while the owner is live" [expr {[contender $path] eq "busy"}]
    check "an active coordination file cannot be replaced by deletion" [expr {[catch {file delete $path}]}]
    check "explicit release consumes the token" [expr {[lock release $token] eq "" &&
            [refused nohandle {lock release $token}]}]
    check "coordination file persists and a new process can acquire it" \
            [expr {[file isfile $path] && [contender $path] eq "acquired"}]

    set f [open $path wb]
    puts -nonewline $f "already here"
    close $f
    set childInterp [interp create]
    try {
        interp eval $childInterp {load {} machteldlock}
        set otherToken [interp eval $childInterp [list ::machteld::lock try $path]]
        set local [lock try [file join $work another.lock]]
        try {
            check "different resources are independent and tokens belong to their interpreter" \
                    [expr {$local ne "" && $otherToken ne "" && [lock try $path] eq "" &&
                    [refused nohandle {lock release $otherToken}] &&
                    [interp eval $childInterp [list catch [list ::machteld::lock release $local]]]}]
        } finally { lock release $local }
    } finally { interp delete $childInterp }
    set token [lock try $path]
    check "interpreter teardown releases ownership" [expr {$token ne ""}]
    lock release $token
    set f [open $path rb]
    try { check "acquiring an existing file preserves its data" [expr {[read $f] eq "already here"}] } finally { close $f }

    set ready [file join $work ready]
    set owner [child start -timeout 45s -- [info nameofexecutable] $script owner $path $ready]
    try {
        set deadline [expr {[clock milliseconds] + 15000}]
        while {![file exists $ready] && [clock milliseconds] < $deadline} { after 20 }
        check "the independently launched owner acquired the resource" [file exists $ready]
        check "a parent cannot acquire its child's lock" [expr {[lock try $path] eq ""}]
        child kill $owner
        child wait $owner -timeout 10s
    } finally { child close $owner }
    # Windows can finish releasing file locks shortly after process termination.
    set deadline [expr {[clock milliseconds] + 5000}]
    while {[set token [lock try $path]] eq "" && [clock milliseconds] < $deadline} { after 20 }
    check "forced owner termination releases ownership without stale-file deletion" \
            [expr {$token ne "" && [file isfile $path]}]
    lock release $token

    check "malformed calls, unknown tokens and invalid paths have distinct errors" [expr {
        [refused usage {lock try}] && [refused usage {lock unknown $path}] &&
        [refused nohandle {lock release ""}] && [refused badvalue {lock try ""}] &&
        [refused badvalue {lock try "a\x00b"}] && [refused badvalue {lock try //zipfs:/missing/app.lock}] &&
        [refused oserror {lock try [file join $work missing-parent leaf.lock]}]}]
} finally { file delete -force $work }

puts "ALL LOCK CHECKS PASSED"
