package require machteld

if {$argv eq {--worker}} {
    worker on detect {hex} {
        package require machteld::encoding
        ::machteld::encoding::detect [binary decode hex $hex]
    }
    worker serve
    return
}
set checks 0
proc equal {label got want} {
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
    incr ::checks
}
equal advertised [package versions machteld::encoding] 1.0
equal lazy [package provide machteld::encoding] {}
package require machteld::encoding
set detect ::machteld::encoding::detect
foreach {tclEncoding name text} {
    utf-8 UTF-8 {Le café est ouvert. Καλημέρα! 世界を読む。}
    cp1252 windows-1252 {La rivière était fraîche cet été. L’élève préfère étudier à l’école, où le café coûte 3 €. }
    cp1251 windows-1251 {Вечером мы читали книги и слушали музыку, когда на улице пошёл дождь. }
    cp932 Shift_JIS {春になると花が咲きます。毎日図書館で日本語の新聞を読んでいます。}
} {
    set data [encoding convertto $tclEncoding [string repeat $text 6]]
    set before [binary encode hex $data]
    set result [$detect $data]
    equal "$tclEncoding match" [dict get $result status] match
    equal "$tclEncoding name" [string tolower [dict get $result encoding]] [string tolower $name]
    equal "$tclEncoding score" [expr {0 < [dict get $result confidence] <= 100}] 1
    equal "$tclEncoding bytes inspected" [dict get $result samplebytes] [expr {[string length $before]/2}]
    equal "$tclEncoding bytes preserved" [binary encode hex $data] $before
}
equal "empty bytes" [$detect [binary format a* {}]] {status nomatch encoding {} confidence 0 samplebytes 0}
set ascii [encoding convertto ascii "One\nline.\t"]
equal "ambiguous ASCII" [$detect $ascii] {status nomatch encoding {} confidence 0 samplebytes 10}
set wide [binary decode hex fffe41000000e9002000420000004300]
equal "UTF-16 BOM with embedded NUL" [dict get [$detect $wide] encoding] UTF-16LE
set prefix [binary format a* [string repeat a 1048576]]
append prefix [binary decode hex ff]
set prefix [binary format a* $prefix]
equal "bounded prefix" [$detect $prefix] {status nomatch encoding {} confidence 0 samplebytes 1048576}
foreach str [list {plain text} "é" "世界"] {
    catch {$detect $str} msg options
    equal "text requires explicit conversion" [dict get $options -errorcode] {MACHTELD ENCODING badvalue}
}
set f [file tempfile path]
try {
    fconfigure $f -translation binary
    puts -nonewline $f $wide
    seek $f 0
    equal "actual binary channel read" [dict get [$detect [read $f]] encoding] UTF-16LE
} finally {close $f; file delete -- $path}
set child [interp create]
try {
    equal "independent interpreter" [interp eval $child {
        package require machteld::encoding
        dict get [::machteld::encoding::detect [binary decode hex efbbbf616263]] encoding
    }] UTF-8
} finally {interp delete $child}
set safe [interp create -safe]
try {equal "safe interpreter" [interp eval $safe {catch {package require machteld::encoding}}] 1} finally {interp delete $safe}
set pool [pool create -width 1 -- [info nameofexecutable] [file normalize [info script]] --worker]
try {
    pool submit $pool [list [dict create op detect hex [binary encode hex $wide]]]
    set reply [lindex [pool wait $pool -timeout 30s] 0]
    equal "worker completed" [dict get $reply ok] 1
    equal "worker byte sample" [dict get $reply result encoding] UTF-16LE
} finally {pool close $pool}
puts "encoding detector: $checks checks passed"
