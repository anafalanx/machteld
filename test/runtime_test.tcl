# Tcl runtime services: CLI/logging, worker protocol, pool, pmap, help/version.

package require machteld

set MT [info nameofexecutable]
set HERE [file dirname [file normalize [info script]]]
set WORKER [file join $HERE fixtures worker_program.tcl]
set WORK [file join $env(TEMP) machteld-runtime-test-[pid]]
file delete -force $WORK
file mkdir $WORK

set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} message options] == 0} { return {} }
    return [dict get $options -errorcode]
}
proc result_of {reply} {
    return [expr {[dict exists $reply result] ? [dict get $reply result] : ""}]
}

set expected {canon child cli detach dirs docs hash help http json links log manifest mtps pmap pool pty run scope store version wait watch worker wrap}
check "package version is 0.11.0" [expr {[package require machteld] eq "0.11.0"}]
check "manifest exposes the compact runtime surface" [expr {
    [lsort [dict keys [manifest]]] eq $expected}]
set metadata [manifest]
set pty_map [namespace ensemble configure ::machteld::pty -map]
check "PTY public ensemble agrees with merged manifest" [expr {
    [lsort [dict keys $pty_map]] eq
    [lsort [dict keys [dict get $metadata pty subcommands]]]}]
check "worker separates reply-only protocol codes" [expr {
    [dict get $metadata worker codes] eq {badvalue usage} &&
    [dict get $metadata worker replycodes] eq {failed notfound parse usage}}]
check "pool separates poison reply from raised codes" [expr {
    [dict get $metadata pool codes] eq {badvalue launch nohandle timeout usage} &&
    [dict get $metadata pool replycodes] eq {poison}}]
check "help advertises bounded embedded-reference discovery" [expr {
    [string match {*docs get*} [help]] && [string match {*docs search*} [help]] &&
    [string match {*docs schema*} [help]]}]
check "version command agrees with the package" [expr {[version] eq "0.11.0"}]
set embedded_module_path [file normalize \
    [file join [file dirname [info library]] tcl9 9.0]]
check "embedded Tcl modules include msgcat" [expr {
    [package require msgcat 1.7] eq "1.7.1" &&
    [string match {//zipfs:/*} $embedded_module_path] &&
    $embedded_module_path in [tcl::tm::path list]}]
check "embedded clock has catalogs and named timezone data" [expr {
    [string match {*UTC 1970} [clock format 0 -timezone :UTC]] &&
    [string match {*1970} [clock format 0 -locale nl_BE -timezone :Europe/Brussels]]}]
check "embedded Tcl library carries legacy encodings" [expr {
    [binary encode hex [encoding convertto cp1252 \u20ac]] eq "80"}]
set notice_ok 1
foreach {notice expected} {
    Apache-2.0.txt 03fd93cceb0f40b82b132e58cff1b8d0d6d1f987a530f22aa5c024a84bfb2f69
    Tcl-9.0.4.txt c0a69a2bfd757361ec7e6143973b103c90409316b49e9c88db26ad6388e79f16
    Tk-9.0.4.txt  2cde822b93ca16ae535c954b7dfe658b4ad10df2a193628d1b358f1765e8b198
} {
    set path [file join //zipfs:/app/licenses $notice]
    if {![file isfile $path]} {
        set notice_ok 0
        continue
    }
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    if {[hash sum sha256 $bytes] ne $expected} { set notice_ok 0 }
}
check "embedded runtime carries exact Apache, Tcl, and Tk licenses" $notice_ok

set spec {
    --count {type int default 2 min 1 max 8 help "number of iterations"}
    --quiet {type flag help "suppress output"}
    format  {type string default text choices {text json}}
}
set parsed [cli parse {--count 4 --quiet json} $spec]
check "CLI parses typed options and positionals" [expr {
    [dict get $parsed count] == 4 && [dict get $parsed quiet] &&
    [dict get $parsed format] eq "json"}]
check "CLI supplies declared defaults" [expr {
    [dict get [cli parse {} $spec] count] == 2}]
check "CLI returns --help as data" [expr {[dict get [cli parse {--help} $spec] help]}]
set requiredHelpSpec {
    --token {type string required 1}
    path    {type string required 1}
}
check "CLI help bypasses missing required values" [expr {
    [dict get [cli parse {--help} $requiredHelpSpec] help]}]
check "CLI help still rejects unexpected positional arguments" [expr {
    [errcode_of {cli parse {one two --help} $requiredHelpSpec}]
        eq {MACHTELD CLI usage}}]
check "CLI help still rejects malformed provided options" [expr {
    [errcode_of {cli parse {--token --help} $requiredHelpSpec}]
        eq {MACHTELD CLI usage}}]
check "CLI enforces integer ranges" [expr {
    [errcode_of {cli parse {--count 99} $spec}] eq {MACHTELD CLI usage}}]
set badCliSpecs [list \
    "default type" {--count {type int default many}} \
    "flag default" {--quiet {type flag default maybe}} \
    "default constraints" {--count {type int default 9 max 8}} \
    "minimum type" {--count {type int min low}} \
    "maximum type" {--count {type int max high}} \
    "range applicability" {--name {min 1}} \
    "range order" {--count {type int min 2 max 1}} \
    "choice type" {--count {type int choices {1 many}}} \
    "flag choices" {--quiet {type flag choices {0 1}}} \
    "default choice" {--format {default yaml choices {text json}}} \
    "required boolean" {path {required maybe}} \
    "malformed choices" [dict create --format [dict create choices "\{"]]]
foreach {label badSpec} $badCliSpecs {
    check "CLI rejects invalid $label in the spec" [expr {
        [errcode_of [list cli parse {--not-declared} $badSpec]] eq {MACHTELD CLI badvalue}}]
}
set booleanSpec {--quiet {type flag default off required no}}
check "CLI preserves valid boolean declarations" [expr {
    [dict get [cli parse {} $booleanSpec] quiet] eq "off"}]
check "CLI durations require units" [expr {
    [cli duration 2s] == 2000 && [errcode_of {cli duration 2}] eq {MACHTELD CLI badvalue}}]
check "CLI durations accept the finite DWORD boundary" [expr {
    [cli duration 4294967294ms] == 4294967294 &&
    [cli duration 0000000001193h] == 4294800000}]
foreach value {4294967295ms 4294968s 71583m 1194h 999999999999999999999999999999999999999999ms} {
    check "CLI durations reject out-of-range $value" [expr {
        [errcode_of [list cli duration $value]] eq {MACHTELD CLI badvalue}}]
}

set logfile [file join $WORK runtime.log]
log configure -level info -file $logfile
log info "hello world" key "two words"
check "log filters below its threshold" [expr {![log debug hidden]}]
set channel [open $logfile r]
set logtext [read $channel]
close $channel
check "log renders structured values unambiguously" [string match {*INFO*hello world*key="two words"*} $logtext]
check "log configuration is introspectable" [expr {
    [dict get [log configure] level] eq "info" && [dict get [log configure] file] eq $logfile}]
check "log rejects unknown levels" [expr {
    [errcode_of {log configure -level verbose}] eq {MACHTELD LOG badvalue}}]
log configure -channel stderr

# Worker schema and namespace placement are tested in-process before transport.
worker on local-double {value} { expr {$value * 2} }
check "worker reports registered argument schema" [expr {
    [dict get [worker ops] local-double] eq "value"}]
namespace eval ::runtime_fixture {
    namespace path ::machteld
    proc helper {value} { return "local:$value" }
    worker on namespaced {value} { helper $value }
}
check "worker handler stays in its declaring namespace" [expr {
    [::runtime_fixture::WorkerOp_namespaced x] eq "local:x"}]

# Real protocol framing over channel-mode supervision, including malformed
# input recovery and preservation of semantic error codes.
set worker [child start -channels -- $MT $WORKER]
set info [child info $worker]
set input [dict get $info stdin]
set output [dict get $info stdout]
fconfigure $input -buffering line
proc ask_worker {request} {
    puts $::input [json encode -dict $request]
    flush $::input
    return [json decode [gets $::output]]
}
set reply [ask_worker {id 4 op echo text hello}]
check "worker protocol returns the request id" [expr {
    [dict get $reply id] == 4 && [result_of $reply] eq "hello"}]
set reply [ask_worker {id 5 op coded}]
check "worker protocol preserves semantic error codes" [expr {
    ![dict get $reply ok] && [dict get $reply code] eq {MACHTELD HASH badvalue}}]
puts $input "not JSON"
flush $input
set reply [json decode [gets $output]]
check "malformed request gets a failure reply" [expr {
    [dict get $reply code] eq {MACHTELD WORKER parse}}]
check "worker survives malformed input" [expr {
    [result_of [ask_worker {id 6 op echo text alive}]] eq "alive"}]
child close $worker

# Pool correctness, ordering, large-pipe behavior and stderr draining preserve
# Preserve the useful pool failure-mode findings as executable regressions.
set pool_token [pool create -width 4 -- $MT $WORKER]
set requests {}
for {set index 0} {$index < 24} {incr index} {
    lappend requests [dict create op echo text value-$index]
}
pool submit $pool_token $requests
set replies [pool wait $pool_token -timeout 30s]
check "pool returns every submitted item" [expr {[llength $replies] == 24}]
set expected_results {}
for {set index 0} {$index < 24} {incr index} { lappend expected_results value-$index }
check "pool preserves submission order" [expr {
    [lmap reply $replies {result_of $reply}] eq $expected_results}]
check "healthy pool reports no worker deaths" [expr {[dict get [pool info $pool_token] dead] == 0}]
check "pool rejects a second batch instead of mixing old and new replies" [expr {
    [errcode_of [list pool submit $pool_token [list [dict create op echo text later]]]]
        eq {MACHTELD POOL usage}}]
pool close $pool_token

set pool_token [pool create -width 2 -- $MT $WORKER]
pool submit $pool_token [list [dict create op big bytes 1048576] [dict create op big bytes 2097152]]
set replies [pool wait $pool_token -timeout 30s]
check "multi-megabyte pool replies do not deadlock" [expr {
    [lmap reply $replies {string length [result_of $reply]}] eq {1048576 2097152}}]
pool close $pool_token

set pool_token [pool create -width 2 -- $MT $WORKER]
pool submit $pool_token [lrepeat 8 [dict create op noise bytes 10000]]
set replies [pool wait $pool_token -timeout 30s]
check "worker stderr cannot wedge the pool" [expr {[llength $replies] == 8}]
check "pool retains a bounded stderr diagnostic tail" [string match *diagnostic* [dict get [pool info $pool_token] stderr]]
pool close $pool_token

set pool_token [pool create -width 2 -maxtries 2 -- $MT $WORKER]
pool submit $pool_token [list [dict create op echo text before] [dict create op die] [dict create op echo text after]]
set replies [pool wait $pool_token -timeout 30s]
set pool_info [pool info $pool_token]
check "pool requeues work after worker death" [expr {
    [dict get $pool_info dead] >= 1 && [dict get $pool_info requeued] >= 1}]
check "poison item has a finite failure" [expr {
    [llength $replies] == 3 && ![dict get [lindex $replies 1] ok]}]
check "healthy items around poison still finish" [expr {
    [result_of [lindex $replies 0]] eq "before" &&
    [result_of [lindex $replies 2]] eq "after"}]
pool close $pool_token

set before [child list]
scope { pool create -width 3 -- $MT $WORKER }
check "scope reaps every pool worker" [expr {[child list] eq $before}]

# pmap closes its pool on all paths and re-raises a worker's structured failure.
set requests [lmap value {a b c d e f} {dict create op echo text $value}]
check "pmap returns plain ordered results" [expr {
    [pmap $requests -width 3 -timeout 30s -- $MT $WORKER] eq {a b c d e f}}]
set before [child list]
check "pmap preserves worker error domain" [expr {
    [errcode_of [list pmap [list {op coded}] -width 1 -timeout 30s -- $MT $WORKER]]
        eq {MACHTELD HASH badvalue}}]
check "pmap closes workers after failure" [expr {[child list] eq $before}]
check "pmap relabels uncoded worker errors" [expr {
    [errcode_of [list pmap [list {op plain}] -width 1 -timeout 30s -- $MT $WORKER]]
        eq {MACHTELD PMAP failed}}]

file delete -force $WORK
if {$fails} {
    puts stderr "$fails runtime test(s) failed"
    exit 1
}
puts "ALL RUNTIME TESTS PASSED"
