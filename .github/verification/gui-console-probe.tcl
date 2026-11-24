package require machteld
set repo [file normalize [lindex $argv 0]]
set dll [file normalize [lindex $argv 1]]
set work [file tempdir]
try {
    set source [file join $work project]
    set cwd [file join $work {elsewhere unrelated}]
    file mkdir $cwd
    file copy [file join $repo examples sqlite-lookup] $source
    file rename [file join $source main.tcl] [file join $source original.tcl]
    set f [open [file join $source main.tcl] w]
    puts $f {package require machteld
if {[lindex $argv 0] eq "--worker"} {
    load $::env(TEST_CONSOLE_DLL) Consoleprobe
    set role [lindex $argv 1]
    set f [open $::env(TEST_CONSOLE_REPORT) a]
    try {puts $f [list $role {*}$::consoleprobe]} finally {close $f}
    if {[dict get $::consoleprobe codepage] || [dict get $::consoleprobe window] || ![dict get $::consoleprobe job]} {
        error "unexpected worker console or ownership: $role $::consoleprobe"
    }
} else {
    package require Tk
    proc observe {deadline} {
        try {
            if {[clock milliseconds] > $deadline || $::lookup::phase eq "error"} {
                error "GUI never reached ready: $::lookup::phase, $::lookup::status"
            }
            if {$::lookup::phase eq "ready" && [winfo ismapped .results]} {
                set f [open $::env(TEST_CONSOLE_REPORT) a]
                try {puts $f [list GUI [llength [.results children {}]]]} finally {close $f}
                ::lookup::close
            } else {after 25 [list observe $deadline]}
        } on error {e o} {puts stderr [dict get $o -errorinfo]; exit 1}
    }
    after 25 [list observe [expr {[clock milliseconds]+45000}]]
}
source -encoding utf-8 [file join [file dirname [info script]] original.tcl]}
    close $f
    set archive [file join $work {Archive app.machteld}]
    set wrapped [file join $work {Wrapped app.exe}]
    set r [run -timeout 20s -- [info nameofexecutable] pack $source -o $archive]
    if {[dict get $r status] ne "ok"} {error $r}
    wrap $source -o $wrapped --entry main.tcl --gui
    file delete -force $source
    foreach mode {archive wrapped} {
        set command [expr {$mode eq "archive" ? [list [info nameofexecutable] $archive] : [list $wrapped]}]
        set report [file join $work $mode.log]
        set r [run -env [list TEST_CONSOLE_DLL $dll TEST_CONSOLE_REPORT $report] -dir $cwd -timeout 65s -- {*}$command]
        set f [open $report r]
        try {set lines [split [string trim [read $f]] "\n"]} finally {close $f}
        if {[dict get $r status] ne "ok" || $lines ne {{seed codepage 0 window 0 job 1} {page codepage 0 window 0 job 1} {GUI 50}}} {
            error "$mode $r report=$lines"
        }
        puts "PASS $mode displayed 50 Tk rows; seed and page workers each had GetConsoleCP=0, GetConsoleWindow=NULL and IsProcessInJob=TRUE"
    }
} finally {file delete -force $work}
