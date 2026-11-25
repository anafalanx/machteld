package require machteld

# The earlier runtime builds its own executable. It must remain runnable
# after the shared runtime and archive are upgraded independently.
if {[llength $argv] != 1} {error "usage: legacy_wrapper_test.tcl build-driver"}
set runtime [info nameofexecutable]
set legacy [file normalize [lindex $argv 0]]
if {[string trim [dict get [run -- $legacy --version] out]] ne "0.21"} {
    set legacy [file join [file dirname [file dirname [file normalize [info script]]]] dist 0.21 machteld.exe]
}
if {[string trim [dict get [run -- $legacy --version] out]] ne "0.21"} {error "requires the 0.21 build driver"}
set work [file tempdir]
try {
    set src [file join $work application.tcl]
    set f [open $src {WRONLY CREAT EXCL}]
    try {puts $f {package require machteld
puts [list [package provide machteld] $argv]}} finally {close $f}
    set dir [file join $work relocated]
    file mkdir $dir
    set previous [file join $dir previous.exe]
    set argvWords [list {two words} {} {--help}]
    # 0.21 embeds its entire reference in each executable.
    set result [run -timeout 10m -- $legacy wrap $src -o $previous --console]
    if {[dict get $result status] ne "ok"} {error "0.21 packaging failed: $result"}
    file delete $src
    set result [run -dir $dir -timeout 10s -- $previous {*}$argvWords]
    if {[dict get $result status] ne "ok" || [string trim [dict get $result out]] ne [list 0.21 $argvWords]} {
        error "legacy executable could not run independently: $result"
    }
    # Run the same application fixture through the current archive path after
    # relocation, with the executable, archive and launch directory independent.
    set app [file join $work shared.machteld]
    set fixture [file join [file dirname [file normalize [info script]]] hello_tool]
    ::machteld::PackArchive $fixture -o $app
    set host [file join $dir machteld.exe]
    file copy $runtime $host
    set appDir [file join $work applications]
    file mkdir $appDir
    set relocated [file join $appDir sample.machteld]
    file rename $app $relocated
    set result [run -dir $work -timeout 30s -- $host $relocated {*}$argvWords]
    if {[dict get $result status] ne "ok"} {error "relocated archive failed: $result"}
    set f [open [file join $dir _hello_ran.txt] r]
    try {set marker [read $f]} finally {close $f}
    foreach line [list "version:[package present machteld]" "argv:$argvWords" "argc:[llength $argvWords]" \
            run:yes store:yes sqlite3:yes help-query:ok] {
        if {$line ni [split $marker "\n"]} {error "missing archive result '$line': $marker"}
    }
    if {![regexp -line {^runtime:msgcat:[0-9.]+ modules:embedded cp1252:80 clock:.+} $marker] ||
            ![regexp -line {^docs-corpus:[0-9a-f]{64}$} $marker]} {
        error "relocated archive did not receive runtime libraries and help: $marker"
    }
    if {[dict exists [manifest] wrap] || [llength [info commands ::machteld::wrap]]} {
        error "the shared runtime advertises wrap"
    }
    set result [run -dir $work -- $runtime wrap absent.tcl -o unexpected.exe]
    if {[dict get $result exit] == 0 || [file exists [file join $work unexpected.exe]]} {
        error "the retired CLI unexpectedly produced an executable"
    }
    zipfs mount $runtime verifyDelivered
    try {
        if {[file exists //zipfs:/verifyDelivered/basekit]} {error "runtime still carries embedded executable templates"}
        foreach item {reference/catalog.dict licenses/Apache-2.0.txt tcl_library/init.tcl tk_library/tk.tcl} {
            if {![file isfile //zipfs:/verifyDelivered/$item]} {error "missing runtime member: $item"}
        }
    } finally {zipfs unmount verifyDelivered}
} finally {file delete -force -- $work}
puts "Legacy executable, retired command and shared runtime contents verified."
