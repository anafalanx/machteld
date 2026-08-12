# Hermetic smoke tests for the non-process native surface.

package require machteld

if {[llength $argv] != 2} {
    puts stderr "usage: native_test.tcl http_fixture.exe process_fixture.exe"
    exit 2
}
set HTTP_FIXTURE [file normalize [lindex $argv 0]]
set PROCESS_FIXTURE [file normalize [lindex $argv 1]]
set WORK [file join $env(TEMP) machteld-native-test-[pid]]
file delete -force $WORK
file mkdir $WORK

set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc check_equal {name actual expected} {
    if {$actual eq $expected} {
        puts "ok   $name"
    } else {
        incr ::fails
        puts "FAIL $name (expected [list $expected], got [list $actual])"
    }
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
proc slurp {path} {
    set channel [open $path rb]
    set value [read $channel]
    close $channel
    return $value
}

set expected_native {canon child detach dirs hash http json links mtps pty run store wait watch}
set metadata [manifest]
check "manifest exposes the exact native surface" [expr {
    [lsort [lmap verb [dict keys $metadata] {
        if {[dict get $metadata $verb kind] eq "c"} { set verb } else { continue }
    }]] eq $expected_native}]
foreach verb $expected_native {
    check "manifest command exists: $verb" [expr {[llength [info commands ::machteld::$verb]] == 1}]
}

check "SHA-256 known vector" [expr {
    [hash sum sha256 abc] eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]
set random [hash random 32]
check "cryptographic random returns requested bytes" [expr {[string length $random] == 32}]
set binary_path [file join $WORK binary-hash.bin]
set binary_value [binary format H* 000180ff4142007f]
set channel [open $binary_path wb]
puts -nonewline $channel $binary_value
close $channel
check "hash file reads raw bytes including NUL/80/FF" [expr {
    [hash file sha256 $binary_path] eq [hash sum sha256 $binary_value]}]
check "hash distinguishes a missing path" [expr {
    [errcode_of [list hash file sha256 [file join $WORK missing.bin]]] eq {MACHTELD HASH notfound}}]

set encoded [json encode -dict [dict create text "héllo" enabled true count 3]]
set decoded [json decode $encoded]
check "JSON native round-trip" [expr {
    [dict get $decoded text] eq "héllo" && [dict get $decoded enabled] eq "true"}]
check "JSON rejects trailing input" [expr {
    [errcode_of {json decode {{}x}}] eq {MACHTELD JSON parse}}]
check "JSON reports depth separately from syntax" [expr {
    [errcode_of [list json decode [string repeat \[ 600]]] eq {MACHTELD JSON depth}}]
check "JSON -- encodes option-looking scalars" [expr {
    [json encode -- -dict] eq {"-dict"} && [json encode -- -list] eq {"-list"}}]

set process [child start -- $PROCESS_FIXTURE hang 10000]
set process_id [dict get [child info $process] pid]
check_equal "mtps kill rejects duplicate -tree" \
    [errcode_of [list mtps kill $process_id -tree -tree]] {MACHTELD MTPS usage}
set killed [mtps kill $process_id]
check "mtps kill discloses partial-success shape" [expr {
    [lsort [dict keys $killed]] eq {failed killed}}]
check "mtps kill identifies the killed PID" [expr {
    $process_id in [dict get $killed killed] && [dict get $killed failed] eq {}}]
child wait $process
child close $process
check "mtps list exact arity" [expr {[errcode_of {mtps list extra}] ne {}}]

# Directory watching is exercised entirely inside a private local fixture.
set watch_root [file join $WORK watch]
file mkdir $watch_root
set watcher [watch start $watch_root -recursive]
set channel [open [file join $watch_root created.txt] w]
puts $channel data
close $channel
set events [watch read $watcher -timeout 3s]
check "watch observes a local file creation" [expr {
    [llength $events] > 0 && [lsearch -glob $events *created.txt*] >= 0}]
set info [watch info $watcher]
check "watch info identifies its root" [expr {[dict get $info directory] eq $watch_root}]
check "healthy watch info has an explicit zero Win32 status" [expr {
    ![dict get $info failed] && [dict get $info win32] == 0}]
check "watch manifest declares stable info keys" [expr {
    [dict get $metadata watch subcommands info returns]
        eq {armed directory dropped failed pending recursive token win32}}]
watch close $watcher

# WinHTTP is tested without public DNS or TLS dependencies. The fixture binds
# only the loopback interface and exits after the exact number of requests.
set port_file [file join $WORK http.port]
set server [child start -- $HTTP_FIXTURE $port_file 6]
check "local HTTP fixture starts" [wait_for_file $port_file]
set port [expr {[file exists $port_file] ? [string trim [slurp $port_file]] : 0}]
set base http://127.0.0.1:$port
set response [http get $base/ok -timeout 3s]
check "HTTP GET reaches loopback fixture" [expr {
    [dict get $response status] == 200 && [dict get $response body] eq "LOCAL-OK"}]
check "HTTP body is a bytearray" [string match *bytearray* \
    [tcl::unsupported::representation [dict get $response body]]]
check "HTTP preserves response headers" [expr {
    [dict get $response headers x-machteld-fixture] eq "local"}]
set response [http post $base/echo "a\0b" -type application/octet-stream -timeout 3s]
check "HTTP POST preserves binary body" [expr {[dict get $response body] eq "a\0b"}]
check "HTTP refuses an oversized local body" [expr {
    [errcode_of {http get $base/large -maxbody 100 -timeout 3s}] eq {MACHTELD HTTP toobig}}]
set response [http get $base/ok#must-not-reach-server -timeout 3s]
check "HTTP does not send URL fragments" [expr {[dict get $response status] == 200}]
set response [http post $base/type body -headers {Content-Type application/custom} -timeout 3s]
check "HTTP preserves caller Content-Type" [expr {
    [dict get $response status] == 200 && [dict get $response body] eq "TYPE-OK"}]
check_equal "HTTP receive timeout retains timeout code" \
    [errcode_of {http get $base/slow -timeout 1s}] {MACHTELD HTTP timeout}
set result [child wait $server -timeout 8s]
check "local HTTP fixture exits cleanly" [expr {[dict get $result status] eq "ok"}]
child close $server
check "HTTP rejects non-HTTP schemes" [expr {
    [errcode_of {http get ftp://127.0.0.1/file}] eq {MACHTELD HTTP badvalue}}]
check "HTTP offers no certificate bypass" [expr {
    "-insecure" ni [dict get $metadata http options]}]
check "HTTP GET rejects the POST-only -type option" [expr {
    [errcode_of [list http get $base/ok -type text/plain]] eq {MACHTELD HTTP usage}}]
check "HTTP manifest advertises exact GET options" [expr {
    [dict get $metadata http subcommands get options]
        eq {-agent -headers -maxbody -timeout}}]
check "HTTP manifest advertises exact POST options" [expr {
    [dict get $metadata http subcommands post options]
        eq {-agent -headers -maxbody -timeout -type}}]
foreach {label value} {
    "zero timeout" 0ms
    "bare timeout" 1
    "decimal timeout" 1.5s
    "unknown timeout unit" 1d
} {
    check "HTTP rejects $label" [expr {
        [errcode_of [list http get $base/ok -timeout $value]] eq {MACHTELD HTTP badvalue}}]
}
foreach value {1B 1K 1KB 1k 1kb 1M 1MB 1G 1GB} {
    check "HTTP accepts exact maxbody spelling $value" [expr {
        [errcode_of [list http get http://127.0.0.1:1/ -maxbody $value -timeout 1ms]]
            ne {MACHTELD HTTP badvalue}}]
}
foreach value {0 -1 1.5 1KiB 1MBx} {
    check "HTTP rejects invalid maxbody $value" [expr {
        [errcode_of [list http get $base/ok -maxbody $value]] eq {MACHTELD HTTP badvalue}}]
}
foreach {label script} [list \
    "NUL in URL" [list http get "http://127.0.0.1/\0x"] \
    "newline in agent" [list http get $base/ok -agent "bad\nagent"] \
    "newline in type" [list http post $base/echo x -type "bad\ntype"] \
    "newline in header value" [list http get $base/ok -headers [dict create X-Test "bad\nvalue"]]] {
    check "HTTP rejects $label" [expr {[errcode_of $script] eq {MACHTELD HTTP badvalue}}]
}

# Public certificate probes are deliberately outside the hermetic CI lane.
if {[info exists ::env(MACHTELD_TEST_PUBLIC_TLS)] && $::env(MACHTELD_TEST_PUBLIC_TLS) eq "1"} {
    foreach endpoint {expired.badssl.com self-signed.badssl.com wrong.host.badssl.com} {
        check "HTTP rejects $endpoint" [expr {
            [errcode_of [list http get https://$endpoint/ -timeout 20s]] eq {MACHTELD HTTP tls}}]
    }
}

file delete -force $WORK
if {$fails} {
    puts stderr "$fails native test(s) failed"
    exit 1
}
puts "ALL NATIVE TESTS PASSED"
