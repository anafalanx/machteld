package require machteld

if {$argv eq {--worker}} {
    worker on nativePid {} {
        package require -exact cffi 2.0.3
        set dll [cffi::Wrapper new kernel32.dll]
        $dll function GetCurrentProcessId uint {}
        try {return [expr {[GetCurrentProcessId] == [pid]}]} finally {
            rename GetCurrentProcessId {}
            $dll destroy
        }
    }
    worker serve
    return
}

proc check {name expression} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL $name"}
    puts "ok   $name"
}
set self [file normalize [info script]]
set fixture [file normalize [lindex $argv 0]]
set dependency [file normalize [lindex $argv 1]]
set scratch [file join $env(TEMP) machteld-cffi-[pid]-[binary encode hex [hash random 8]]]
set originalDir [pwd]
set originalPath $env(PATH)
file mkdir $scratch
try {
    check {lazy static package is advertised before use} {
        [package versions cffi] eq "2.0.3" && [package provide cffi] eq "" && ![namespace exists ::cffi]
    }
    check {exact package and libffi backend} {
        [package require -exact cffi 2.0.3] eq "2.0.3" && [cffi::pkgconfig get backend] eq "libffi"
    }
    check {callback and development commands are absent} {
        [info commands ::cffi::callback] eq {} && [info commands ::cffi::sandbox] eq {}
    }
    set system [cffi::Wrapper new kernel32.dll]
    $system function GetCurrentProcessId uint {}
    $system destroy
    check {bound symbol retains its module after wrapper destruction} {[GetCurrentProcessId] == [pid]}
    rename GetCurrentProcessId {}

    set safe [interp create -safe]
    try {
        check {safe interpreter cannot initialize the static package} {
            [catch {interp invokehidden $safe load {} Cffi}] &&
            [interp eval $safe {catch {package require cffi}}] && ![interp eval $safe {namespace exists ::cffi}]
        }
    } finally {interp delete $safe}
    set child [interp create]
    try {
        check {normal child can independently require and use cffi} {
            [interp eval $child {
                package require -exact cffi 2.0.3
                set d [cffi::Wrapper new kernel32.dll]
                $d function GetCurrentProcessId uint {}
                GetCurrentProcessId
            }] == [pid]
        }
    } finally {interp delete $child}

    set adjacent [file join $scratch "pé\U0001f600"]
    file mkdir $adjacent
    set candidate [file join $adjacent [file tail $fixture]]
    file copy $fixture $candidate
    file copy $dependency $scratch
    cd $scratch
    set env(PATH) "[file nativename [file dirname $fixture]];$originalPath"
    foreach path [list {} [file tail $fixture] [file join [file tail $adjacent] [file tail $fixture]] \
                       "C:[file tail $fixture]" "kernel32.dll\u0000ignored"] {
        check "DLL addressing rejects [list $path]" {[catch {cffi::Wrapper new $path}]}
    }
    check {a private dependency present only in cwd or PATH is rejected} {[catch {cffi::Wrapper new $candidate}]}
    file copy $dependency $adjacent
    set dll [cffi::Wrapper new $candidate]
    check {loaded private DLL still cannot satisfy a bare system name} {
        [catch {cffi::Wrapper new [file tail $candidate]}]
    }
    $dll function FixtureDependency int {}
    $dll function FixtureWideW winstring {text winstring}
    $dll function FixtureUnpairedW winstring {}
    $dll function FixtureMultiW {winstring multisz} {}
    check {an absolute DLL finds its adjacent private dependency} {[FixtureDependency] == 30}
    set text "A\U0001f600é"
    check {Windows text round trips a supplementary character} {[FixtureWideW $text] eq $text}
    check {invalid UTF-16 input and single or MULTI_SZ results raise errors} {
        [catch {FixtureWideW "\ud800"}] && [catch {FixtureUnpairedW}] && [catch {FixtureMultiW}]
    }
    check {invalid Windows memory APIs return Tcl errors} {[catch {cffi::memory fromwinstring "\udc00"}]}
    set p [cffi::memory frombinary [binary decode hex 00d80000]]
    try {
        check {invalid Windows memory text is rejected} {[catch {cffi::memory towinstring $p}]}
    } finally {cffi::memory free $p}
    check {symbol lookup preserves the cffi error family} {
        [catch {$dll addressof MissingFixtureEntry} message options] &&
        [lrange [dict get $options -errorcode] 0 1] eq {cffi NOT_FOUND}
    }
    foreach cmd {FixtureDependency FixtureWideW FixtureUnpairedW FixtureMultiW} {rename $cmd {}}
    $dll destroy
    file delete $candidate
    check {last wrapper and binding release the DLL} {![file exists $candidate]}
    set pool [pool create -width 1 -- [info nameofexecutable] $self --worker]
    try {
        pool submit $pool [list [dict create op nativePid]]
        set reply [lindex [pool wait $pool -timeout 30s] 0]
        check {worker initializes its own cffi and calls the native API} {
            [dict get $reply ok] && [dict get $reply result]
        }
    } finally {pool close $pool}
} finally {
    set env(PATH) $originalPath
    cd $originalDir
    file delete -force $scratch
}
