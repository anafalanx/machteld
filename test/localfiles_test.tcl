package require machteld

# Optional load run on an existing 100,000-entry directory of regular files:
#   machteld.exe test/localfiles_test.tcl --load DIRECTORY list|callback|stat
if {[lindex $argv 0] eq "--load"} {
    package require machteld::files
    lassign $argv option dir mode
    if {[llength $argv] != 3 || $mode ni {list callback stat}} {error "expected --load directory list|callback|stat"}
    proc countEntry {row} {incr ::seen}
    set elapsed {}
    set iterations [expr {$mode eq "stat" ? 3 : 20}]
    for {set i 0} {$i < $iterations} {incr i} {
        set seen 0
        set start [clock microseconds]
        switch $mode {
            list {set n [llength [::machteld::files::entries $dir]]}
            callback {
                set n [::machteld::files::entries $dir countEntry]
                if {$seen != $n} {error "callback count mismatch"}
            }
            stat {
                set n 0
                foreach path [glob -nocomplain -directory $dir *] {file stat $path info; incr n}
            }
        }
        lappend elapsed [expr {[clock microseconds]-$start}]
        if {$n != 100000} {error "expected 100000 files, found $n"}
    }
    puts [dict create mode $mode microseconds $elapsed]
    return
}

set checks 0
proc equal {label got want} {
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
    incr ::checks
}
proc code {script} {
    if {![catch {uplevel 1 $script} msg opts]} {return success}
    dict get $opts -errorcode
}

# Live Cloud Files acceptance on an NTFS test volume with the Windows cloud
# filter enabled. The provider needs permission to register this one temp root.
if {[lindex $argv 0] eq "--cloud"} {
    if {[llength $argv] != 2} {error "expected --cloud cloud_files_provider.exe"}
    package require machteld::files
    proc reply {ch} {
        set deadline [expr {[clock milliseconds]+15000}]
        while {[gets $ch line] < 0} {
            if {[eof $ch] || [clock milliseconds] >= $deadline} {error "cloud provider ended or timed out"}
            after 20
        }
        return $line
    }
    set scratch [file tempdir]
    try {
        set ch [open [list | [file normalize [lindex $argv 1]] [file nativename $scratch]] r+]
        try {
            fconfigure $ch -blocking 0 -translation {auto lf} -encoding utf-8 -buffering line
            equal ready [reply $ch] ready
            set rows {}
            foreach row [::machteld::files::entries $scratch] {dict set rows [dict get $row name] $row}
            set online [file join $scratch online-only.bin]
            set resident [file join $scratch resident.bin]
            equal "cloud reparse tag" [expr {[dict get $rows online-only.bin reparsetag] != 0}] 1
            equal "online flag" [dict get $rows online-only.bin offline] 1
            equal "genuine pinned flag" [dict get $rows pinned.bin pinned] 1
            equal "resident at listing" [dict get $rows resident.bin offline] 0
            equal "online open" [code {::machteld::files::openlocal $online}] {MACHTELD FILES offline}
            set data [::machteld::files::openlocal $resident]
            try {
                puts $ch evict
                equal "live read excludes dehydration" [reply $ch] {evict 80070020}
                equal "resident bytes" [read $data] ABC
            } finally {close $data}
            puts $ch evict
            equal "dehydrate after close" [reply $ch] {evict 00000000}
            equal "eviction since listing" [code {::machteld::files::openlocal $resident}] {MACHTELD FILES offline}
            puts $ch stop
            equal "no provider fetches" [reply $ch] {fetches 0}
        } finally {
            catch {puts $ch stop; flush $ch}
            fconfigure $ch -blocking 1
            close $ch
        }
    } finally {file delete -force -- $scratch}
    puts "live cloud files: $checks checks passed"
    return
}
equal advertised [package versions machteld::files] 1.0
equal lazy [package provide machteld::files] {}
package require machteld::files
set scratch [file tempdir]
set dir [file join $scratch fixture]
file mkdir $dir
try {
    equal empty [::machteld::files::entries $dir] {}
    set name "caf\u00e9 \U0001f33f.bin"
    set path [file join $dir $name]
    set bytes [binary decode hex 00ff0d0a801a01]
    set writer [open $path wb]
    try {puts -nonewline $writer $bytes} finally {close $writer}
    file attributes $path -hidden 1
    file mkdir [file join $dir nested]
    file mkdir [file join $scratch elsewhere]
    set mklink [run -dir $scratch -- $env(ComSpec) /d /c mklink /j {fixture\junction} elsewhere]
    if {[dict get $mklink exit] != 0} {error "junction fixture: [dict get $mklink err] [dict get $mklink out]"}
    set result [::machteld::files::entries $dir]
    set rows {}
    foreach row $result {dict set rows [dict get $row name] $row}
    equal names [lsort [dict keys $rows]] [lsort [list $name nested junction]]
    set row [dict get $rows $name]
    equal size [dict get $row size] 7
    equal mtime [dict get $row mtime] [file mtime $path]
    equal ticks [expr {[dict get $row filetime]/10000000-11644473600}] [file mtime $path]
    equal hidden [expr {!!([dict get $row attributes] & 2)}] 1
    equal regular [dict get $row reparsetag] 0
    equal local [dict get $row offline] 0
    equal junction [dict get $rows junction reparsetag] 2684354563
    equal directory [expr {!!([dict get $rows nested attributes] & 16)}] 1
    set streamed {}
    equal count [::machteld::files::entries $dir [list lappend streamed]] 3
    equal callbacks [lsort $streamed] [lsort $result]
    equal "callback errors propagate" [code {::machteld::files::entries $dir {apply {{row} {return -code error -errorcode {APP stopped} end}}}}] {APP stopped}
    equal "callback error releases enum handle" [llength [::machteld::files::entries $dir]] 3
    equal "empty prefix" [code {::machteld::files::entries $dir {}}] {MACHTELD FILES badvalue}
    equal "missing directory" [code {::machteld::files::entries [file join $dir absent]}] {MACHTELD FILES notfound}
    equal "missing file" [code {::machteld::files::openlocal [file join $dir absent]}] {MACHTELD FILES notfound}
    equal "NUL path" [code {::machteld::files::openlocal "$path\0suffix"}] {MACHTELD FILES badvalue}
    equal "directories are not streams" [code {::machteld::files::openlocal $dir}] {MACHTELD FILES badvalue}
    set ch [::machteld::files::openlocal $path]
    try {
        equal "binary read" [binary encode hex [read $ch]] [binary encode hex $bytes]
        seek $ch 2
        equal "bounded seek/read" [binary encode hex [read $ch 2]] 0d0a
        equal "ordinary writer excluded by live channel" [catch {open $path r+}] 1
    } finally {close $ch}
    set writer [open $path r+]
    try {equal "open writer reports busy" [code {::machteld::files::openlocal $path}] {MACHTELD FILES busy}} finally {close $writer}
    package require cffi
    set dll [cffi::Wrapper new kernel32.dll]
    $dll function SetFileAttributesW int {path winstring attributes uint}
    equal "install synthetic offline metadata" [SetFileAttributesW [file nativename $path] 4098] 1
    try {
        equal "changed after listing" [dict get $row offline] 0
        equal "file now unavailable" [code {::machteld::files::openlocal $path}] {MACHTELD FILES offline}
        foreach item [::machteld::files::entries $dir] {
            if {[dict get $item name] eq $name} {equal "new listing sees offline" [dict get $item offline] 1}
        }
        set ch [open $path rb]
        try {equal "normal Tcl read remains available" [read $ch] $bytes} finally {close $ch}
    } finally {
        SetFileAttributesW [file nativename $path] 2
        rename SetFileAttributesW {}
        $dll destroy
    }
    set safe [interp create -safe]
    try {equal "safe interpreter" [interp eval $safe {catch {package require machteld::files}}] 1} finally {interp delete $safe}
} finally {file delete -force -- $scratch}
puts "native files: $checks checks passed"
