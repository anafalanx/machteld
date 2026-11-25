package require machteld

set checks 0
proc check {label condition} {
    if {![uplevel 1 [list expr $condition]]} {error $label}
    incr ::checks
}
check advertised {[package versions machteld::network] eq "1.0"}
check lazy {[package provide machteld::network] eq {}}
package require machteld::network
set wifi [::machteld::network::wifi]
check enumeration {[dict get $wifi status] in {ok unavailable restricted}}
check enumeration-code {([dict get $wifi status] eq "ok") == ([dict get $wifi winerror] == 0)}
set guids {}
foreach a [dict get $wifi adapters] {
    check stable-id {[regexp {^\{[[:xdigit:]-]{36}\}$} [dict get $a guid]]}
    check distinct {[dict get $a guid] ni $guids}
    lappend guids [dict get $a guid]
    check state {[dict get $a state] in {connected disconnected disconnecting associating discovering authenticating adhoc unavailable}}
    check details {[dict get $a details] in {ok disconnected restricted unavailable}}
    if {[dict get $a details] eq "ok"} {
        check ssid {[string length [dict get $a ssid]] <= 32}
        check quality {[dict get $a quality] >= 0 && [dict get $a quality] <= 100}
        check rates {[dict get $a rxkbps] >= 0 && [dict get $a txkbps] >= 0}
    } else {
        check undisclosed {![dict exists $a ssid] && ![dict exists $a rxkbps]}
    }
}
set ping ::machteld::network::ping
set here [$ping 127.0.0.1 127.0.0.1 1000]
check loopback {[dict get $here status] eq "ok" && [dict get $here winerror] == 0}
check roundtrip {[string is entier -strict [dict get $here rttms]] && [dict get $here rttms] >= 0}
foreach input {
    {0.0.0.0 127.0.0.1} {127.0.0.1 0.0.0.0}
    {hostname 127.0.0.1} {127.0.0.1 localhost} {::1 ::1}
    {127.0.0.1 127.0.0.1 0} {127.0.0.1 127.0.0.1 60001}
} {
    catch {$ping {*}$input} msg opts
    check validation {[dict get $opts -errorcode] eq {MACHTELD NETWORK badvalue}}
}
set absent [$ping 192.0.2.241 127.0.0.1 50]
check explicit-source {[dict get $absent status] eq "error" && [dict get $absent winerror] != 0 && ![dict exists $absent rttms]}
set child [interp create]
try {
    check child {[interp eval $child {package require machteld::network; dict get [::machteld::network::ping 127.0.0.1 127.0.0.1] status}] eq "ok"}
} finally {interp delete $child}
set safe [interp create -safe]
try {check safe {[interp eval $safe {catch {package require machteld::network}}]}} finally {interp delete $safe}
puts "network diagnostics: $checks checks passed"
