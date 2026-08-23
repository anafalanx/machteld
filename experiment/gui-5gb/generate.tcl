# generate.tcl -- the 5 GB access log (plan-machteld-014, the GUI spike).
#
# Deterministic: one LCG seed drives everything; the sha256 of the pilot
# and of the full file are logged so any run can be checked against the
# banked numbers. Realistic by construction:
#   tijd i       epoch seconds, 30 days ending 2026-08-23
#   ip s         drawn from EXACTLY 50,000 distinct addresses (dictionary
#                mode, deliberately near the 65,536 escape)
#   method s     10 draws over 5 distinct
#   pad s        ~2,000 distinct route paths (ids live in query, not here)
#   query s      "" on ~40% of rows, else session/id-bearing - tens of
#                millions distinct: SPAN MODE BY DESIGN, the honest column
#   status i, bytes i, dur i
#   verwijzer s  ~1,000 distinct referers
#   agent s      ~800 distinct real-shaped UA strings (quoted csv: they
#                carry commas and parentheses)
#
# The hot loop is inline (the first pilot ran at 0.7 MB/s on a rnd proc;
# proc-free it holds a usable rate) and every row costs one LCG step
# plus splits of that step - deterministic and cheap.
#
# usage:  machteld generate.tcl OUT.csv ?-mb N?      (pilot: -mb 50)
#         default is the full 5 GB (5120 MB)

package require machteld 0.13.0

set out [lindex $argv 0]
set mb 5120
if {[lindex $argv 1] eq "-mb"} { set mb [lindex $argv 2] }
if {$out eq ""} { puts stderr "usage: generate.tcl OUT.csv ?-mb N?"; exit 1 }
set target [expr {$mb * 1024 * 1024}]

# ---------------- the distinct-value pools ----------------
# 50,000 ips: 10.(0..199).7.(1..250).
set ips {}
for {set i 0} {$i < 50000} {incr i} {
    lappend ips "10.[expr {$i / 250}].7.[expr {$i % 250 + 1}]"
}
# ~2,000 paths.
set resources {users orders products carts sessions invoices payments events
    reports batches uploads accounts profiles teams projects tickets alerts
    devices sensors readings baskets vendors coupons refunds shipments
    warehouses categories reviews wishlists subscriptions}
set tails {{} /list /new /active /archive /export /stats /latest /pending
    /all /recent /summary /count /bulk /search /verify /sync /audit /flags
    /labels /notes}
set pads {}
foreach r $resources {
    foreach t $tails {
        lappend pads "/api/v1/$r$t" "/api/v2/$r$t"
    }
    lappend pads "/static/$r.js" "/static/$r.css"
}
lappend pads /index.html /health /metrics /favicon.ico /robots.txt
set npads [llength $pads]
# ~1,000 referers.
set verwijzers {}
foreach host {www.example.com shop.example.com app.example.com m.example.com
    partner.voorbeeld.nl zoek.voorbeeld.nl} {
    foreach p {/ /home /search /cat /deals /help /login /landing} {
        for {set i 0} {$i < 21} {incr i} {
            lappend verwijzers "https://$host$p?c=$i"
        }
    }
}
lappend verwijzers "-"
set nverw [llength $verwijzers]
# ~800 agents: browser-version x platform grid, real widths, quoted.
set agents {}
set platforms {
    {Windows NT 10.0; Win64; x64}
    {Windows NT 11.0; Win64; x64}
    {Macintosh; Intel Mac OS X 10_15_7}
    {X11; Linux x86_64}
    {iPhone; CPU iPhone OS 17_5 like Mac OS X}
    {Linux; Android 14; Pixel 8}
}
foreach pl $platforms {
    for {set v 80} {$v < 140} {incr v} {
        lappend agents "\"Mozilla/5.0 ($pl) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$v.0.0.0 Safari/537.36\""
    }
    for {set v 78} {$v < 140} {incr v} {
        lappend agents "\"Mozilla/5.0 ($pl; rv:$v.0) Gecko/20100101 Firefox/$v.0\""
    }
    for {set v 17} {$v < 27} {incr v} {
        lappend agents "\"Mozilla/5.0 ($pl) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/1[expr {$v * 7 % 40 + 100}].0.0.0 Safari/537.36 Edg/1[expr {$v * 7 % 40 + 100}].0.0.0\""
    }
    for {set v 15} {$v < 18} {incr v} {
        lappend agents "\"Mozilla/5.0 ($pl) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/$v.5 Safari/605.1.15\""
    }
}
set nagents [llength $agents]
set methods {GET GET GET GET GET GET POST POST PUT DELETE}
set statuses {200 200 200 200 200 200 200 204 301 304 304 400 401 403 404 404 500 503}

puts "distinct: ips 50000, pads $npads, verwijzers $nverw, agents $nagents"

# ---------------- the write (inline hot loop) ----------------
set f [open $out wb]
chan configure $f -buffersize 4194304
puts $f "tijd,ip,method,pad,query,status,bytes,dur,verwijzer,agent"
set t0 [clock milliseconds]
set epoch0 [expr {[clock scan 2026-08-23] - 30 * 86400}]
set written 0
set rows 0
set buf ""
set buflen 0
set S 20260823
while {$written < $target} {
    # One LCG step per draw, all inline.
    set S [expr {($S * 1103515245 + 12345) % 2147483648}]; set r1 $S
    set S [expr {($S * 1103515245 + 12345) % 2147483648}]; set r2 $S
    set S [expr {($S * 1103515245 + 12345) % 2147483648}]; set r3 $S
    set S [expr {($S * 1103515245 + 12345) % 2147483648}]; set r4 $S
    # zipf-ish skew: half of all traffic from 1/50th of the ips.
    set line [expr {$epoch0 + ($rows / 11) % 2592000}]
    append line "," [lindex $ips [expr {$r1 % 2 ? $r1 / 2 % 1000 : $r1 / 2 % 50000}]] \
        "," [lindex $methods [expr {$r2 % 10}]] \
        "," [lindex $pads [expr {$r2 / 10 % $npads}]]
    if {$r3 % 10 < 4} {
        append line ","
    } else {
        append line ",s=[format %08x [expr {$r3 * 7919 + $r4 % 65536}]]&r=[expr {$r4 % 1000000}]"
    }
    append line "," [lindex $statuses [expr {$r3 / 10 % 18}]] \
        "," [expr {$r4 % 200000 + 90}] \
        "," [expr {$r3 / 180 % 2000 + 1}] \
        "," [lindex $verwijzers [expr {$r4 / 7 % $nverw}]] \
        "," [lindex $agents [expr {$r1 / 13 % $nagents}]] "\n"
    append buf $line
    # NEVER [string length $buf] here: append invalidates the cached
    # character count and string length rescans the WHOLE buffer -
    # quadratic (measured: 0.3 MB/s with the scan, ~40x without).
    set n [string length $line]
    incr written $n
    incr buflen $n
    incr rows
    if {$buflen >= 2097152} {
        puts -nonewline $f $buf
        set buf ""
        set buflen 0
    }
}
puts -nonewline $f $buf
close $f

set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
# %lld, not %d: format %d truncates a wide to 32 bits and reported the
# first full 5 GB write as "1073741940 bytes" (= 5368709236 mod 2^32).
puts [format "wrote %lld bytes, %d rows, %.1fs (%.1f MB/s)" \
    [file size $out] $rows $dt [expr {[file size $out] / 1048576.0 / $dt}]]
puts "sha256 [string range [hash file sha256 $out] 0 31]..."
