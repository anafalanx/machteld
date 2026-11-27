package require machteld

# The same driver ships with editable archives and serves checkout callers.
try {
    source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler driver.tcl]
} on error {message options} {
    if {[lrange $argv 0 1] eq {check --json}} {
        # The driver could not load to format its own report.
        chan configure stdout -translation binary
        puts stdout {{"schema":1,"ok":false,"diagnostics":[{"code":"INTERNAL_ERROR","message":"could not load the project driver","node":null}]}}
    } else {
        puts stderr $message
    }
    exit 1
}
