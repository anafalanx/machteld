package require machteld

# Explicit source-overlay development runs only. Normal suite runs exercise
# the implementation embedded in the executable under test.
if {[info exists ::env(MACHTELD_TEST_WORKER_SOURCE)]} {
    dict unset ::machteld::TCL_MANIFEST worker
    source $::env(MACHTELD_TEST_WORKER_SOURCE)
}

worker on echo {text} { return $text }
worker on delay {milliseconds text} {
    after $milliseconds
    return $text
}
worker on big {bytes} { return [string repeat x $bytes] }
worker on noise {bytes} {
    puts stderr [string repeat diagnostic $bytes]
    return ok
}
worker on digest {path {algorithm sha256}} { hash file $algorithm $path }
worker on coded {} { hash sum no-such-algorithm value }
worker on plain {} { error "plain worker error" }
worker on typed {} { json value boolean true }
worker on die {} { exit 9 }
worker on effect-die {path} {
    set f [open $path a]
    puts $f effect
    close $f
    exit 9
}
worker on effect-fail {path} {
    set f [open $path a]
    puts $f effect
    close $f
    error "effect completed; reported failure" {} {FIXTURE reported}
}
worker serve {*}$argv
