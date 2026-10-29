# Headless scheduling checks, including deterministic continuously ready Tcl
# channels. No Tk package, desktop interaction, or visible windows.
package require machteld
set example [file join [file dirname [file normalize [info script]]] .. examples project-inspector]
if {![llength [info commands ::inspector::Job]]} { source [file join $example model.tcl] }

namespace eval ::inspector_fairness {
    namespace path ::machteld
    variable checks 0
    variable state
    proc check {name condition} {
        variable checks
        incr checks
        if {!$condition} { error "FAIL GUI-model fairness: $name" }
        puts "ok   GUI-model fairness: $name"
    }
    proc observe {job snapshot} {
        variable state
        if {!$state(began) && ([dict get $snapshot progress] > 0 || [dict get $snapshot log] ne {})} {
            set state(began) 1
            set state(timer) [after idle [list ::inspector_fairness::idle $job]]
        }
    }
    proc idle {job} {
        variable state
        set snapshot [$job snapshot]
        # Do not count the idle gap after all output has drained but before the
        # lifecycle poll reaps the child. Marker 99 precedes completion on wire.
        if {[dict get $snapshot phase] eq "running" && [dict get $snapshot progress] != 99} {
            incr state(idles)
            dict set state(progressSeen) [list [dict get $snapshot progress] \
                [string range [dict get $snapshot log] end-19 end]] 1
            set state(timer) [after idle [list ::inspector_fairness::idle $job]]
        }
    }
    proc exercise {worker mode label {expected done}} {
        variable state
        array set state {began 0 idles 0 progressSeen {} timer {}}
        set job [::inspector::Job new $worker ::inspector_fairness::observe]
        try {
            $job start $mode
            set deadline [expr {[clock milliseconds]+12000}]
            while {[dict get [$job snapshot] phase] eq "running" && [clock milliseconds] < $deadline} {
                set wake [after 5 {set ::inspector_fairness::awake 1}]
                vwait ::inspector_fairness::awake
                after cancel $wake
            }
            set snapshot [$job snapshot]
            check "$label settles as $expected" [expr {[dict get $snapshot phase] eq $expected}]
            if {$expected eq "error"} {
                check "$label preserves timeout despite root exit zero" [string match {*status timeout, exit 0*} [dict get $snapshot error]]
            }
            check "$label gets recurring idle opportunities while output progresses" [expr {
                $state(began) && $state(idles) >= 3 && [dict size $state(progressSeen)] >= 3}]
            check "$label keeps diagnostic retention bounded" [expr {[string length [dict get $snapshot log]] <= 8192}]
        } finally {
            if {$state(timer) ne {}} { after cancel $state(timer) }
            $job destroy
        }
    }
    proc ready_child {sub args} {
        variable state
        switch -- $sub {
            start {
                set state(stdin) [open NUL w]
                set state(stdout) [open $state(outputFile) rb]
                set state(stderr) [open $state(errorFile) rb]
                return ready-channel-test
            }
            info { return [dict create stdin $state(stdin) stdout $state(stdout) stderr $state(stderr) running 0] }
            wait { return [dict create exit 0 status $state(status)] }
            close { foreach name {stdin stdout stderr} { catch {close $state($name)} } }
            default { error "unexpected test child command: $sub" }
        }
    }
    proc run {fixture} {
        variable state
        set initialChildren [child list]
        set initialChannels [lsort [chan names]]
        set initialTimers [lsort [after info]]
        foreach mode {flood-out flood-err flood-both} {
            exercise $fixture $mode "real pipe $mode"
        }
        # A live pipe may accidentally go idle while Windows wakes its writer.
        # Files are continuously readable: this proves that the model itself
        # yields, independently of those incidental producer/scheduler gaps.
        set output [file tempfile outputFile]
        set errors [file tempfile errorFile]
        set state(outputFile) $outputFile
        set state(errorFile) $errorFile
        fconfigure $output -encoding utf-8 -translation lf
        try {
            for {set i 1} {$i <= 64} {incr i} {
                puts $output [json encode -dict [dict create type progress value $i message [string repeat x 60000]]]
                puts -nonewline $errors [string repeat [format %02d $i] 32768]
            }
            puts $output [json encode -dict [dict create type progress value 99 message finished-writing]]
            puts $output {{"type":"complete"}}
        } finally { close $output; close $errors }
        rename ::machteld::child ::machteld::InspectorOriginalChild
        interp alias {} ::machteld::child {} ::inspector_fairness::ready_child
        try {
            set state(status) ok
            exercise $fixture ignored "continuously ready stdout and stderr"
            set state(status) timeout
            exercise $fixture ignored "completed protocol but timed-out process tree" error
        } finally {
            rename ::machteld::child {}
            rename ::machteld::InspectorOriginalChild ::machteld::child
            file delete $outputFile $errorFile
        }
        check "all fairness channels, children and timers released" [expr {
            [child list] eq $initialChildren && [lsort [chan names]] eq $initialChannels &&
            [lsort [after info]] eq $initialTimers}]
    }
}
::inspector_fairness::run [file join [file dirname [file normalize [info script]]] fixtures inspector_protocol.tcl]
