# Exercise public Tcl-to-X BLOB admission, file reads and a committed SQLite import.
package require machteld
package require sqlite3
set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set mode {}
set compilers {}
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set option [lindex $argv $i]] {
        --once {set mode once}
        --timings {set mode timings}
        --embedded {
            if {[dict exists $compilers current]} {error "select the candidate compiler once"}
            dict set compilers current [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$option needs a compiler directory"}
            set name [expr {$option eq "--compiler" ? "current" : "previous"}]
            if {[dict exists $compilers $name]} {error "select the $name compiler once"}
            dict set compilers $name [lindex $argv $i]
        }
        default {error {usage: blob-archive.tcl ?--embedded | --compiler path? ?--compare-with path? ?--once | --timings?}}
    }
}
if {![dict exists $compilers current]} {dict set compilers current [file join $root packages application-compiler]}
set timed [expr {$mode eq "timings" || ($mode eq {} && [dict exists $compilers previous])}]
set source {extern fn .sha($data: bytes) -> text = ['::machteld::hash','sum','sha256']
export fn .store($path: text, $pass: int, $blocks: list<bytes>) -> result<int,problem> {
    $index := 0
    using $tx ::= sql_begin($path)? {
        for $block in $blocks {
            sql_exec($tx, 'INSERT INTO blocks(pass, ordinal, size, digest, payload) VALUES (?1, ?2, ?3, ?4, ?5)', $pass, $index, len($block), .sha($block), $block)?
            $index = $index + 1
        }
        sql_commit($tx)?
    }
    return ok($index)
}}
dict for {name directory} $compilers {
    set child [interp create]
    try {
        $child eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set compiled [$child eval [list ::appcompiler::compile [dict create blocks $source] ::blob_$name]]
        namespace eval :: [dict get $compiled script]
    } finally {interp delete $child}
}

proc makeFile {path count blockSize} {
    set alphabet [binary format c* [lseq 0 to 255]]
    set marker [encoding convertto -profile strict utf-8 "雪 Δ Ångström 🧪"]
    set pattern [string repeat $alphabet [expr {1 + $blockSize/256}]]
    set hashes {}
    set f [open $path {WRONLY CREAT EXCL BINARY}]
    try {
        for {set i 0} {$i < $count} {incr i} {
            # A short final record exercises partial reads. Every block ends in three NULs.
            set size [expr {$i == $count-1 ? $blockSize-517 : $blockSize}]
            set middle [string range $pattern 0 [expr {$size-4-[string length $marker]-3-1}]]
            set bytes [binary format Ia*a*H* $i $marker $middle 000000]
            puts -nonewline $f $bytes
            lappend hashes [::machteld::hash sum sha256 $bytes]
        }
    } finally {close $f}
    return $hashes
}
proc readBlocks {path size} {
    set f [open $path rb]
    set blocks {}
    try {
        while {1} {
            set block [read $f $size]
            if {$block eq {}} {break}
            lappend blocks $block
        }
    } finally {close $f}
    return $blocks
}
proc verify {database source hashes size passes} {
    set file [open $source rb]
    sqlite3 reader $database -readonly 1
    try {
        set seen 0
        set count [llength $hashes]
        reader eval {SELECT pass, ordinal, size, digest, typeof(payload) AS storage, payload FROM blocks ORDER BY pass, ordinal} row {
            set ordinal [expr {$seen % $count}]
            if {$ordinal == 0} {seek $file 0}
            set expected [read $file $size]
            if {$row(pass) != $seen / $count || $row(ordinal) != $ordinal ||
                    $row(size) != [string length $expected] || $row(storage) ne "blob" ||
                    $row(payload) ne $expected || $row(digest) ne [lindex $hashes $ordinal]} {
                error "wrong archived row at pass $row(pass), block $row(ordinal)"
            }
            incr seen
        }
        if {$seen != $passes * $count} {error "archived $seen rows, expected [expr {$passes*$count}]"}
    } finally {reader close; close $file}
}
proc exercise {name mode database source hashes blockSize} {
    set passes 3
    set start [clock microseconds]
    sqlite3 writer $database
    try {
        writer eval {CREATE TABLE blocks(pass INTEGER, ordinal INTEGER, size INTEGER, digest TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(pass,ordinal)) STRICT}
    } finally {writer close}
    for {set pass 0} {$pass < $passes} {incr pass} {
        if {$mode eq "fresh" || $pass == 0} {set blocks [readBlocks $source $blockSize]}
        set answer [::blob_${name}::blocks::store $database $pass $blocks]
        if {$answer ne [list ok [llength $hashes]]} {error "failed to import: $answer"}
        if {$mode eq "fresh"} {unset blocks}
    }
    set commit [clock microseconds]
    verify $database $source $hashes $blockSize $passes
    return [list [expr {$commit-$start}] [expr {[clock microseconds]-$commit}]]
}
set dir [file normalize [file tempdir]]
try {
    set size 16384
    set count [expr {$timed ? 128 : 4}]
    set rounds [expr {$timed ? 6 : 0}]
    set file [file join $dir fixture.bin]
    set hashes [makeFile $file $count $size]
    # Independent SHA-256 fixtures cover every byte, including the short final block.
    set expectedDigest [dict get {
        4   0a835fe15fb588175bc0dff6a0b72db515bac3ea69ebda9229f482d8ee312991
        128 bc07fd9cb6f098fc49c23ade8a9ffaac3d0a1708b3683e86a0fd8c75130f9328
    } $count]
    if {[::machteld::hash file sha256 $file] ne $expectedDigest} {error "BLOB fixture bytes differ"}
    if {$timed} {puts [join {round compiler input import_us verification_us} \t]}
    for {set i 0} {$i <= $rounds} {incr i} {
        set names [dict keys $compilers]
        if {$i%2} {set names [lreverse $names]}
        set modes [expr {($i/2)%2 ? {reused fresh} : {fresh reused}}]
        foreach mode $modes {
            foreach name $names {
                set db [file join $dir archive.db]
                lassign [exercise $name $mode $db $file $hashes $size] ingestion verification
                file delete -- $db
                if {$i} {puts [join [list $i $name $mode $ingestion $verification] \t]}
            }
        }
    }
    if {!$timed} {puts "compiler BLOB archive: $count blocks in three committed imports, fresh and reused, verified byte for byte"}
} finally {file delete -force -- $dir}
