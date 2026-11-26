# The native driver injects a failed ReplaceFileW and leaves real files at
# the corresponding NTFS names. All observations use those names after return.
proc put {path bytes} {
    set ch [open $path {WRONLY CREAT EXCL BINARY}]
    try {puts -nonewline $ch $bytes} finally {close $ch}
}
proc content {path} {
    if {![file exists $path]} {return absent}
    set ch [open $path rb]
    try {return [read $ch]} finally {close $ch}
}
proc equal {label got want} {
    if {$got ne $want} {error "$::mode $label: expected [list $want], got [list $got]"}
    incr ::checks
}
set checks 0
set root [file tempdir]
try {
    # mode, calls, error, Win32 error, candidate/destination/backup/aside contents, diagnostic
    foreach row {
        {transient        2 0 0    absent candidate  absent  absent  ordinary}
        {persistent       4 1 1175 candidate prior   absent  absent  ordinary}
        {restore          1 1 1177 candidate prior   absent  absent  ordinary}
        {retain           1 1 1177 candidate competitor prior absent backup}
        {foreign          1 1 1175 candidate prior   foreign absent  ordinary}
        {inaccessible     1 1 1175 candidate prior   {}      absent  ordinary}
        {locked           1 1 1175 candidate prior   {}      absent  ordinary}
        {unknown          1 1 1175 candidate competitor foreign prior unknown}
        {edit-candidate   1 1 1175 {newer version} prior absent absent changed}
        {edit-destination 1 1 1175 candidate {newer version} absent absent changed}
        {swap-candidate   1 1 0    {competing candidate} prior absent candidate badvalue}
    } {
        lassign $row mode wantCalls wantError winerror wantSrc wantDst wantBackup wantAside diagnostic
        set dir [file join $root $mode]
        file mkdir $dir
        set src [file join $dir candidate]
        set dst [file join $dir destination]
        set aside [file join $dir aside]
        put $src candidate
        put $dst prior
        set candidateID [fixture_id $src]
        set priorID [fixture_id $dst]
        begin_case $mode $aside
        set rc [catch {::machteld::Publish $src $dst} message options]
        lassign [finish_case] calls backup
        equal {replacement calls} $calls $wantCalls
        equal {command status} $rc $wantError
        if {$rc} {
            equal {Tcl error domain} [dict get $options -errorcode] \
                [list MACHTELD PUBLISH [expr {$diagnostic eq "badvalue" ? "badvalue" : "oserror"}]]
            if {$winerror} {equal {original Windows error} [string match "*Windows error $winerror*" $message] 1}
        }
        equal candidate [content $src] $wantSrc
        equal destination [content $dst] $wantDst
        equal {candidate or prior moved by another writer} [content $aside] $wantAside
        equal {marker in the candidate's private test directory} [file normalize [file dirname $backup]] [file normalize $dir]
        equal {backup bytes} [content $backup] $wantBackup
        if {$wantDst in {prior {newer version}}} {equal {prior destination ID} [fixture_id $dst] $priorID}
        if {$wantDst eq "candidate"} {equal {published candidate ID} [fixture_id $dst] $candidateID}
        if {$wantAside eq "prior"} {equal {prior ID at unrelated name} [fixture_id $aside] $priorID}
        if {$wantAside eq "candidate"} {equal {candidate ID at unrelated name} [fixture_id $aside] $candidateID}
        if {$wantBackup ne "absent"} {equal {verified prior ID at backup} [expr {[fixture_id $backup] eq $priorID}] [expr {$wantBackup eq "prior"}]}
        set pattern .machteld-publish-backup-*
        set actual [lsort -unique [concat [glob -nocomplain -tails -directory $dir $pattern] \
            [glob -nocomplain -tails -types hidden -directory $dir $pattern]]]
        equal {recovery artifacts} $actual [expr {$wantBackup eq "absent" ? {} : [list [file tail $backup]]}]
        equal {prior backup diagnostic} [string match "*the prior destination remains at *" $message] [expr {$diagnostic eq "backup"}]
        if {$diagnostic eq "backup"} {equal {exact retained path} [expr {[string first "the prior destination remains at $backup" $message] >= 0}] 1}
        equal {unverified location diagnostic} [string match "*verify the prior file's location*" $message] [expr {$diagnostic eq "unknown"}]
        equal {changed input diagnostic} [string match "*input changed*" $message] [expr {$diagnostic eq "changed"}]
    }
} finally {file delete -force -- $root}
puts "atomic publication recovery: $checks checks passed"
