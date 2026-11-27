# Exercise the recipient's interactive path with only the copied executable
# and archive in the working directory. The file on disk, not an echoed
# console command, establishes that rebuilding actually completed.
proc testEmbeddedRebuild {exe directory inputName outputName} {
    set output [file join $directory $outputName]
    if {[file exists $output]} {error "prompt test needs a fresh destination"}
    set commands [list [list set input $inputName] [list set output $outputName] \
        {set root [zipfs mount $input build]} \
        {::machteld::ArchiveEntry $root} \
        {source -encoding utf-8 [file join $root compiler compiler.tcl]} \
        {::appcompiler::project::pack [file join $root project inputs application.dict] $output}]
    set token [::machteld::pty spawn -dir $directory -- $exe]
    try {
        ::machteld::pty expect $token -timeout 10s {{*machteld %*} {} timeout {error "missing Tcl prompt"}}
        ::machteld::pty send $token "[join $commands {; }]\r"
        set transcript ""
        set deadline [expr {[clock milliseconds] + 20000}]
        while {[clock milliseconds] < $deadline && ![file isfile $output] && [dict get [::machteld::pty info $token] running]} {
            append transcript [::machteld::pty read $token -timeout 100ms]
        }
        if {![file isfile $output]} {
            error "two-file rebuild in the runtime prompt failed: [::machteld::pty strip $transcript]"
        }
    } finally {
        ::machteld::pty close $token
    }
}
