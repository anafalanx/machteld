package require machteld

# Standalone acceptance probe for file-backed archive generations. Run with
# candidate/machteld.exe generation-stress.tcl. All fixtures are synthetic.
proc putFile {path bytes} {
    set f [open $path wb]
    try { puts -nonewline $f $bytes } finally { close $f }
}
proc getFile {path} {
    set f [open $path rb]
    try { return [read $f] } finally { close $f }
}
proc sendReport {work name value} {
    set path [file join $work $name]
    putFile $path.[pid].new [encoding convertto utf-8 $value]
    file rename -- $path.[pid].new $path
}
proc awaitReport {work name} {
    set deadline [expr {[clock milliseconds] + 60000}]
    set path [file join $work $name]
    while {![file exists $path]} {
        if {[file exists [file join $work abort]]} { error "driver aborted waiting for $name" }
        if {[clock milliseconds] > $deadline} {
            set log [file join $work child.log]
            error "timed out waiting for $name; child log: [expr {[file exists $log] ? [getFile $log] : {}}]"
        }
        after 25
    }
    return [encoding convertfrom -profile strict utf-8 [getFile $path]]
}
proc fingerprint {root} {
    # Two different generations use different bytes at both ends. One read
    # starts beyond 64 MiB, so the check exercises the large mounted asset.
    set f [open [file join $root data.bin] rb]
    try {
        set front [read $f 1024]
        seek $f -1024 end
        set back [read $f 1024]
        return [list [tell $f] [hash sum sha256 $front] [hash sum sha256 $back]]
    } finally { close $f }
}
proc verify {name actual wanted} {
    if {$actual ne $wanted} { error "$name: got <$actual>, expected <$wanted>" }
    puts "PASS $name"
}

if {[info exists ::probeGeneration]} {
    lassign $argv role work
    set root [file dirname [info script]]
    set proof [list $::probeGeneration {*}[fingerprint $root]]
    switch -exact -- $role {
        parent {
            sendReport $work parent $proof
            sendReport $work launch [app launch]
            publish file $argv0 [file join $work replacement.machteld]
            # Use Tcl's process launcher so this child outlives this parent.
            # A supervised Machteld child is deliberately killed with its owner.
            exec {*}[app launch] child $work < NUL > [file join $work child.log] 2>@1 &
            awaitReport $work child-ready
        }
        child {
            sendReport $work child-ready $proof
            awaitReport $work parent-exited
            sendReport $work child-after-exit [list $::probeGeneration {*}[fingerprint $root]]
            set grand [run -timeout 45s -- {*}[app launch] grandchild $work]
            if {[dict get $grand status] ne "ok" || [dict get $grand exit] != 0} { error "grandchild failed: $grand" }
            sendReport $work child-complete yes
        }
        grandchild { sendReport $work grandchild $proof }
        fresh { sendReport $work fresh $proof }
        crash-owner {
            sendReport $work crash-ready [list $proof [app launch]]
            vwait ::never
        }
        replay { puts [list REPLAY $::probeGeneration] }
        default { error "unexpected archive role: $role" }
    }
    return
}

set work [file tempdir]
set source [file join $work build]
set public [file join $work {shared application.machteld}]
set runtime [info nameofexecutable]
try {
    file mkdir $source
    file copy [info script] [file join $source probe.tcl]
    # The 256 KiB random block is larger than DEFLATE's 32 KiB history, so
    # repetition does not shrink the physical ZIP below the file-backed threshold.
    set block [hash random 262144]
    set data [file join $source data.bin]
    set f [open $data wb]
    try { for {set i 0} {$i < 260} {incr i} { puts -nonewline $f $block } } finally { close $f }
    foreach label {A B} destination [list $public [file join $work replacement.machteld]] {
        set entry [file join $source main.tcl]
        putFile $entry "package require machteld\nset ::probeGeneration $label\nsource \[file join \[file dirname \[info script\]\] probe.tcl\]\n"
        set patch [string repeat $label 128]
        set f [open $data r+b]
        try {
            puts -nonewline $f $patch
            seek $f -128 end
            puts -nonewline $f $patch
        } finally { close $f }
        set expected($label) [list $label {*}[fingerprint $source]]
        zipfs lmkzip $destination [list $entry main.tcl [file join $source probe.tcl] probe.tcl $data data.bin]
        set size [file size $destination]
        if {$size <= 67108864} { error "archive $label is too small to exercise file-backed storage: $size" }
        puts "PASS physical archive $label is $size bytes"
    }
    file delete -force $source

    # Synchronous Tcl exec returns after the actual parent exits. Its explicitly
    # redirected child uses separate streams, so it can stay alive independently.
    set log [file join $work parent.log]
    if {[catch {exec $runtime $public parent $work < NUL > $log 2>@1} why]} {
        error "parent failed: $why\n[getFile $log]"
    }
    verify "A parent read its original file-backed asset" [awaitReport $work parent] $expected(A)
    verify "A parent launched A child after publishing B" [awaitReport $work child-ready] $expected(A)
    set current [run -timeout 45s -- $runtime $public fresh $work]
    if {[dict get $current status] ne "ok" || [dict get $current exit] != 0} { error "fresh launch failed: $current" }
    verify "fresh direct launch reads B" [awaitReport $work fresh] $expected(B)
    sendReport $work parent-exited yes
    verify "A child still reads A after parent exit" [awaitReport $work child-after-exit] $expected(A)
    verify "A child starts an A grandchild after parent exit and replacement" [awaitReport $work grandchild] $expected(A)
    verify "grandchild exited successfully" [awaitReport $work child-complete] yes

    # The child can still be briefly in interpreter teardown after its last
    # report. A retained prefix may run A only until that last owner exits.
    set prefix [awaitReport $work launch]
    set deadline [expr {[clock milliseconds] + 20000}]
    while {1} {
        set stale [run -timeout 15s -- {*}$prefix replay $work]
        if {[dict get $stale status] eq "error" && [dict get $stale exit] != 0} { break }
        if {[dict get $stale status] ne "ok" || [string trim [dict get $stale out]] ne {REPLAY A}} {
            error "stale prefix unexpectedly ran a different generation: $stale"
        }
        if {[clock milliseconds] > $deadline} { error "stale generation remained available after all owners exited" }
        after 50
    }
    puts "PASS stale launch prefix expires without running B"

    set scratch [file join $work {isolated temp}]
    file mkdir $scratch
    set temporary [dict create TEMP [file nativename $scratch] TMP [file nativename $scratch]]
    set child [child start -timeout 90s -env $temporary -- $runtime $public crash-owner $work]
    try {
        lassign [awaitReport $work crash-ready] proof deadPrefix
        verify "sole owner has the large B archive mounted before termination" $proof $expected(B)
        child kill $child
        set result [child wait $child -timeout 15s]
        if {[dict get $result status] eq "timeout"} { error "crash fixture failed to stop" }
    } finally { child close $child }
    set expired [run -timeout 15s -env $temporary -- {*}$deadPrefix replay $work]
    if {[dict get $expired status] ne "error" || [dict get $expired exit] == 0} {
        error "terminated owner's generation remained available: $expired"
    }
    set deadline [expr {[clock milliseconds] + 5000}]
    while {[llength [set files [glob -nocomplain -tails -directory $scratch *]]]} {
        if {[clock milliseconds] > $deadline} { error "orphaned files after forced exit: $files" }
        after 50
    }
    puts "PASS forced process exit expires its generation and leaves its temporary directory empty"
} finally {
    # A failed parent can leave a waiting Tcl child. Signal this owned fixture
    # before cleanup; its 60-second deadline also bounds unexpected exits.
    putFile [file join $work abort] x
    set deadline [expr {[clock milliseconds] + 5000}]
    while {[catch {file delete -force $work} failure]} {
        if {[clock milliseconds] > $deadline} { error "probe cleanup failed: $failure" }
        after 50
    }
}
puts "ALL GENERATION STRESS CHECKS PASSED"
