package require machteld

# Deliberately read-only. Potentially slow filesystem calls live in this child,
# not a Tk callback. stdout is JSONL; stderr is human-readable diagnostics.
fconfigure stdout -encoding utf-8 -translation lf -buffering line
fconfigure stderr -encoding utf-8 -translation lf -buffering line
proc send {record} { puts [json encode -dict $record] }
try {
    if {[llength $argv] != 2} { error "expected directory and inspection mode" }
    lassign $argv directory mode
    if {$mode ni {inspect slow fail noisy}} { error "unknown mode" }
    set directory [file normalize $directory]
    if {![file isdirectory $directory]} { error "Not a directory: $directory" }
    send [dict create type progress value 0 message "Reading $directory"]
    if {$mode eq "fail"} {
        after 250
        error "Deliberate demonstration failure. No files were changed. Choose Inspect to recover."
    }
    if {$mode eq "slow"} {
        for {set i 0} {$i < 150} {incr i} {
            send [dict create type progress value [expr {100*$i/150}] message "Slow demonstration ($i/150); Cancel remains available."]
            after 100
        }
    }
    if {$mode eq "noisy"} {
        for {set i 0} {$i < 1200} {incr i} {
            puts stderr "Output demonstration $i: [string repeat diagnostic 12]"
            send [dict create type progress value [expr {$i/12}] message "Output demonstration $i/1200"]
        }
    }
    set entries [lsort -unique [glob -nocomplain -directory $directory * .*]]
    set entries [lmap path $entries {
        if {[file tail $path] in {. ..}} { continue }
        set path
    }]
    if {[llength $entries] > 500} { error "Directory has more than 500 entries; choose a smaller directory." }
    set n 0
    foreach path $entries {
        # Do not follow links for metadata; they are shown as links.
        file lstat $path metadata
        set kind $metadata(type)
        if {$kind ni {file directory link}} { set kind other }
        send [dict create type row name [json value string [file tail $path]] \
            path [json value string $path] kind $kind size $metadata(size)]
        incr n
        send [dict create type progress value [expr {100*$n/max(1,[llength $entries])}] \
            message "Read $n of [llength $entries] entries"]
    }
    send [dict create type complete]
} on error {message options} {
    puts stderr $message
    exit 3
}
