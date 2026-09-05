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
proc wait_for_watch_pending {token minimum {milliseconds 3000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        set state [watch info $token]
        if {[dict get $state pending] >= $minimum ||
                [dict get $state dropped] || [dict get $state failed]} {
            return 1
        }
        after 10
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
# Depth applies to VALID JSON too deep for the contract; an unclosed flood
# is a parse error (the J1-table ruling, plan-machteld-015).
check "JSON reports depth separately from syntax" [expr {
    [errcode_of [list json decode \
        "[string repeat \[ 600][string repeat \] 600]"]] eq {MACHTELD JSON depth}}]
check "an unclosed flood is parse, not depth" [expr {
    [errcode_of [list json decode [string repeat \[ 600]]] eq {MACHTELD JSON parse}}]
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

# A remove followed by an add for the same path is deliberately one batch: the
# default coalescer promises priority, not last-event-wins behavior.
set precedence_path [file join $watch_root precedence.txt]
set channel [open $precedence_path w]
puts $channel old
close $channel
set precedence_watcher [watch start $watch_root]
file delete -force $precedence_path
set channel [open $precedence_path w]
puts $channel new
close $channel
set precedence_ready [wait_for_watch_pending $precedence_watcher 2]
set precedence_events [watch read $precedence_watcher]
set precedence_action ""
foreach event $precedence_events {
    if {[dict get $event path] eq "precedence.txt"} {
        set precedence_action [dict get $event action]
        break
    }
}
check "watch precedence batch becomes ready" $precedence_ready
check_equal "watch removal outranks a later addition" $precedence_action removed
watch close $precedence_watcher

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

# The redirect canary (plan-machteld-015 H1/H2). Server B is the CANARY: it
# listens for a bounded window and writes a hit file on ANY connection - the
# provable zero. Server A answers 301/302/303/307/308 with relative and
# absolute Locations; the absolute ones point at B (a different port: the
# cross-origin case on loopback). Every `-redirect none` request must stop
# at the first response, Location intact, with ZERO requests reaching B and
# the Authorization/Cookie sentinels appearing nowhere in any result.
set portB_file [file join $WORK http-canary.port]
set hit_file [file join $WORK http-canary.hit]
file delete -- $hit_file
set canary [child start -- $HTTP_FIXTURE $portB_file -canary $hit_file 4]
check "canary fixture starts" [wait_for_file $portB_file]
set portB [string trim [slurp $portB_file]]
set portA_file [file join $WORK http-redir.port]
set serverA [child start -- $HTTP_FIXTURE $portA_file 12 http://127.0.0.1:$portB/ok]
check "redirect fixture starts" [wait_for_file $portA_file]
set portA [string trim [slurp $portA_file]]
set baseA http://127.0.0.1:$portA
set sentinelHeaders [dict create Authorization "Bearer SENTINEL123" Cookie "s=SENTINEL456"]
set redirOk 1
set locOk 1
set cleanOk 1
foreach code {301 302 303 307 308} {
    foreach form {rel abs} {
        set r [http get $baseA/redir/$code/$form -redirect none \
            -headers $sentinelHeaders -timeout 3s]
        if {[dict get $r status] != $code} { set redirOk 0 }
        set loc [expr {[dict exists $r headers location]
                       ? [dict get $r headers location] : ""}]
        if {$form eq "rel" && $loc ne "/ok"} { set locOk 0 }
        if {$form eq "abs" && $loc ne "http://127.0.0.1:$portB/ok"} { set locOk 0 }
        if {[string match *SENTINEL* $r]} { set cleanOk 0 }
    }
}
check "-redirect none stops at every first 3xx (5 codes x rel/abs)" $redirOk
check "-redirect none returns the Location header intact" $locOk
check "no sentinel appears in any -redirect none result" $cleanOk
check "the canary logged ZERO requests" [expr {![file exists $hit_file]}]
# H2: the omitted-option behavior is untouched - a follow still follows
# (two requests reach server A: the 302, then /ok).
set r [http get $baseA/redir/302/rel -timeout 3s]
check "omitted-option redirect still follows to the target" [expr {
    [dict get $r status] == 200 && [dict get $r body] eq "LOCAL-OK"}]
check "-redirect rejects anything but none" [expr {
    [errcode_of [list http get $baseA/ok -redirect follow]] eq {MACHTELD HTTP badvalue}}]
set result [child wait $serverA -timeout 8s]
check "redirect fixture exits cleanly" [expr {[dict get $result status] eq "ok"}]
child close $serverA
set result [child wait $canary -timeout 8s]
check "the canary exits cleanly, hit file still absent" [expr {
    [dict get $result status] eq "ok" && ![file exists $hit_file]}]
child close $canary

check "HTTP rejects non-HTTP schemes" [expr {
    [errcode_of {http get ftp://127.0.0.1/file}] eq {MACHTELD HTTP badvalue}}]
check "HTTP offers no certificate bypass" [expr {
    "-insecure" ni [dict get $metadata http options]}]
check "HTTP GET rejects the POST-only -type option" [expr {
    [errcode_of [list http get $base/ok -type text/plain]] eq {MACHTELD HTTP usage}}]
check "HTTP manifest advertises exact GET options" [expr {
    [dict get $metadata http subcommands get options]
        eq {-agent -headers -maxbody -redirect -timeout}}]
check "HTTP manifest advertises exact POST options" [expr {
    [dict get $metadata http subcommands post options]
        eq {-agent -headers -maxbody -redirect -timeout -type}}]
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

# Public certificate probes are deliberately outside the hermetic local lane.
if {[info exists ::env(MACHTELD_TEST_PUBLIC_TLS)] && $::env(MACHTELD_TEST_PUBLIC_TLS) eq "1"} {
    foreach endpoint {expired.badssl.com self-signed.badssl.com wrong.host.badssl.com} {
        check "HTTP rejects $endpoint" [expr {
            [errcode_of [list http get https://$endpoint/ -timeout 20s]] eq {MACHTELD HTTP tls}}]
    }
}

# 0.21 regressions: typed values through `encode -list`, NUL inside strings,
# strict duplicate detection, and constructors refusing a typed container.
set typed_array [json value array [list [json value number 1] [json value number 2]]]
check "json encode -list honours a typed value" [expr {
    [json encode -list $typed_array] eq {[1,2]}}]
check "json encode -plain refuses a typed value at the top level" [expr {
    [errcode_of [list json encode -list -plain $typed_array]] eq {MACHTELD JSON type}}]
set with_nul "a\u0000b"
check "json carries a NUL inside a string both ways" [expr {
    [json encode -- $with_nul] eq {"a\u0000b"} && [json decode {"a\u0000b"}] eq $with_nul}]
check "json value string carries a NUL to the wire" [expr {
    [json encode [json value string $with_nul]] eq {"a\u0000b"}}]
check "json value array refuses a typed handle by name" [expr {
    [errcode_of [list json value array $typed_array]] eq {MACHTELD JSON type}}]
check "json decode -typed rejects a duplicate key" [expr {
    [errcode_of {json decode -typed {{"a":1,"b":2,"a":3}}}] eq {MACHTELD JSON strict}}]
check "json decode -typed accepts distinct keys" [expr {
    [json type [json decode -typed {{"a":1,"b":2,"c":3}}]] eq "object"}]
check "json exists requires a path" [expr {
    [errcode_of [list json exists $typed_array]] eq {TCL WRONGARGS}}]
check "json encodes an arithmetic series as an array" [expr {
    [json encode [lseq 1 3]] eq {[1,2,3]}}]
check "http refuses credentials in a url" [expr {
    [errcode_of {http get http://user:secret@127.0.0.1:9/}] eq {MACHTELD HTTP badvalue}}]
check "http refuses an empty -type" [expr {
    [errcode_of {http post http://127.0.0.1:9/ body -type ""}] eq {MACHTELD HTTP badvalue}}]
check "watch start refuses a file by name" [expr {
    [errcode_of [list watch start $binary_path]] eq {MACHTELD WATCH badvalue}}]
check "dirs names an unknown option" [expr {
    [errcode_of [list dirs $WORK -bogus 1]] eq {MACHTELD DIRS usage}}]

file delete -force $WORK
if {$fails} {
    puts stderr "$fails native test(s) failed"
    exit 1
}
puts "ALL NATIVE TESTS PASSED"
