# Focused store contract and cross-process SQLite contention tests.

package require machteld

if {[llength $argv] != 1} {
    puts stderr "usage: store_test.tcl sqlite_lock_fixture.exe"
    exit 2
}
set LOCKER [file normalize [lindex $argv 0]]
set WORK [file join $env(TEMP) machteld-store-test-[pid]]
file delete -force $WORK
file mkdir $WORK
set DB [file join $WORK store.db]

set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} message options] == 0} { return {} }
    return [dict get $options -errorcode]
}
proc wait_for_file {path {milliseconds 3000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        if {[file exists $path] && [file size $path] > 0} { return 1 }
        after 25
    }
    return 0
}

check "get before open reports notopen" [expr {
    [errcode_of {store get missing}] eq {MACHTELD STORE notopen}}]
check "store rejects an empty database path" [expr {
    [errcode_of {store open {}}] eq {MACHTELD STORE badvalue}}]
store open $DB

set bytes [binary format H* 0001ff80410042]
store put binary-key $bytes
set roundtrip [store get binary-key]
check "stored bytes including NUL round-trip" [expr {
    [binary encode hex $roundtrip] eq [binary encode hex $bytes]}]
check "stored value returns as a bytearray" [string match *bytearray* \
    [tcl::unsupported::representation $roundtrip]]
set unicode "caf\u00e9 \U0001F600"
store put unicode-key $unicode
check "non-bytearray strings are stored as UTF-8" [expr {
    [encoding convertfrom utf-8 [store get unicode-key]] eq $unicode}]

check "missing get reports notfound" [expr {
    [errcode_of {store get absent-key}] eq {MACHTELD STORE notfound}}]
check "delete existing key returns one" [expr {[store del binary-key] == 1}]
check "delete missing key returns zero" [expr {[store del binary-key] == 0}]

foreach {name script} {
    "store version exact arity" {store version extra}
    "store keys exact arity" {store keys extra}
    "store close exact arity" {store close extra}
} {
    check $name [expr {[errcode_of $script] ne {}}]
}

# Another process holds an exclusive SQLite write lock. The retained store API
# must wait rather than immediately return SQLITE_BUSY; the 1.2s hold is under
# the configured five-second busy timeout.
set ready [file join $WORK lock.ready]
set locker [child start -- $LOCKER $DB $ready 1200]
check "lock fixture acquired an exclusive lock" [wait_for_file $ready]
set started [clock milliseconds]
set put_error [errcode_of {store put after-contention value}]
set elapsed [expr {[clock milliseconds] - $started}]
check "store waits through cross-process contention" [expr {
    $put_error eq {} && $elapsed >= 800 && $elapsed < 5000}]
set lock_result [child wait $locker]
check "lock holder exited successfully" [expr {[dict get $lock_result status] eq "ok"}]
child close $locker
check "write after contention is durable" [expr {
    [binary encode hex [store get after-contention]] eq
    [binary encode hex [encoding convertto utf-8 value]]}]

store close
store open
store put memory-key memory-value
check "store open without a path uses an in-memory database" [expr {
    [encoding convertfrom utf-8 [store get memory-key]] eq "memory-value"}]
store close
file delete -force $WORK
if {$fails} {
    puts stderr "$fails store test(s) failed"
    exit 1
}
puts "ALL STORE TESTS PASSED"
