package require machteld

set checks 0
proc equal {label actual expected} {
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr ::checks
}

# Independent oracle: xxhsum 0.8.3 -H3, with byte i = (131*i + 17) % 256.
# Exercise every input-size transition and cross several 64 KiB channel reads.
set bytes {}
for {set i 0} {$i < 256} {incr i} {lappend bytes [expr {(131*$i + 17) % 256}]}
set pattern [binary format a* [string repeat [binary format c* $bytes] 1025]]
set vectors {
    0 2d06800538d394c2  1 f319fe2bdfcdfebd  3 a107bb65b715c89b  4 509f0567aa8a3123
    8 b1433dc39b7f946e  9 fe2542440b36ddc7  16 715189ff3dcdcff6 17 7d33163b8af0179c
    128 ee847f7fcef4ddbc 129 7e3e7b750239d4fc 240 44089a144aade02d 241 ed93572e52acac83
    1024 f0c5763fadfacd25 65537 a793068b5df40f22 262147 d79c13cab6ab4413
}
equal advertised [hash algorithms] {md5 sha1 sha256 sha384 sha512 xxh3-64}
equal abc [hash sum xxh3-64 abc] 78af5f94892f3950
equal binary [hash sum xxh3-64 [binary decode hex 00ff80]] 2682fcb65dac5d83
equal unicode [hash sum xxh3-64 "a\0\u00e9\U0001f680"] ea0cb1640870eafb
set baseline [hash list]
dict for {n expected} $vectors {
    set data [binary format a* [string range $pattern 0 [expr {$n-1}]]]
    equal "sum $n" [hash sum xxh3-64 $data] $expected
    equal "binary $n" [binary encode hex [hash sum xxh3-64 $data -binary]] $expected
    set token [hash start xxh3-64]
    hash update $token [binary format a* {}]
    set offset 0
    while {$offset < $n} {
        foreach size {1 23 253 17 1019 65521} {
            hash update $token [binary format a* [string range $data $offset [expr {$offset+$size-1}]]]
            incr offset $size
            if {$offset >= $n} break
        }
    }
    equal "stream $n" [binary encode hex [hash final $token -binary]] $expected
}
equal consumed [hash list] $baseline
catch {hash final $token} msg opts
equal nohandle [dict get $opts -errorcode] {MACHTELD HASH nohandle}
catch {hash hmac xxh3-64 k abc} msg opts
equal noncrypto [dict get $opts -errorcode] {MACHTELD HASH badvalue}
equal "HMAC-SHA256 with empty key and message" [hash hmac sha256 {} {}] \
    b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad
set work [file tempdir]
try {
    set source [file join $work source]
    file mkdir $source
    set file [file join $source fixture.bin]
    set ch [open $file wb]
    try {puts -nonewline $ch $data} finally {close $ch}
    equal file [hash file xxh3-64 $file] $expected
    equal "file binary" [binary encode hex [hash file xxh3-64 $file -binary]] $expected
    set zip [file join $work fixture.zip]
    zipfs mkzip $zip $source $source
    set mount [zipfs mount $zip xxh3-[pid]]
    try {equal zipfs [hash file xxh3-64 [file join $mount fixture.bin]] $expected} finally {zipfs unmount $mount}
    catch {hash file xxh3-64 [file join $work missing]} msg opts
    equal missing [dict get $opts -errorcode] {MACHTELD HASH notfound}

    # Existing catalogs store the 64 bits in a signed SQLite INTEGER, then
    # display printf('%016x',hash). The stored value comes from xxhsum's vector.
    package require sqlite3
    sqlite3 db [file join $work catalog.db]
    try {
        db eval {CREATE TABLE files(hash INTEGER); INSERT INTO files VALUES(-2910429497819184109)}
        set stored [db onecolumn {SELECT hash FROM files}]
        binary scan [hash file xxh3-64 $file -binary] W signed
        equal "unchanged file in signed catalog" $signed $stored
        equal "catalog display" [db onecolumn {SELECT printf('%016x',hash) FROM files}] [hash file xxh3-64 $file]
    } finally {db close}
} finally {file delete -force -- $work}
puts "XXH3-64: $checks checks passed"
