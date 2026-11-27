package require machteld
package require sqlite3

namespace eval ::importTest {variable checks 0}

proc ::importTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::importTest::inputFile {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}

proc ::importTest::invoke {cwd exe args input {failurePattern {}}} {
    set run [::machteld::run -dir $cwd -timeout 30s -stdin $input -- $exe {*}$args]
    set out [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run out]] "\r\n"]
    set err [string trimright [encoding convertfrom -profile strict utf-8 [dict get $run err]] "\r\n"]
    equal [dict get $run truncated] {} "captured whole command output"
    equal [dict get $run exit] [expr {$failurePattern ne {} ? 1 : 0}] "[list {*}$args] exit ($err)"
    if {$failurePattern eq {}} {
        equal $err {} "successful command has no diagnostic"
    } else {
        equal $out {} "rejected batch has no success output"
        equal [string match $failurePattern $err] 1 "import diagnostic ($err)"
    }
    return $out
}

proc ::importTest::at {cwd host at {entity 007}} {
    set input [format {{"entity":"%s","at":%d}} $entity $at]
    set out [invoke $cwd $host {observations.machteld at observations.db} $input]
    set findings {}
    foreach line [split $out \n] {
        set row [::machteld::json decode $line]
        lappend findings [lmap key {source id field starts ends value disputed} {dict get $row $key}]
        equal [dict get $row entity] $entity "text identifier keeps its spelling"
    }
    return $findings
}

proc ::importTest::exercise {work root} {
    set author [file join $work author]
    file copy [file join $root examples typed-import] $author
    set recipient [file join $work {moved application}]
    file mkdir $recipient
    set exe [info nameofexecutable]
    set archive [file join $author observations.machteld]
    invoke $author $exe [list [file join $root tools application_project.tcl] pack project.dict $archive] {}
    invoke $author $exe {create_sample.tcl observations.db} {}
    set north [inputFile [file join $author north.json]]
    set south [inputFile [file join $author south.json]]
    set invalid [inputFile [file join $author invalid.json]]
    file rename -- $archive [file join $recipient observations.machteld]
    set database [file join $recipient observations.db]
    file rename -- [file join $author observations.db] $database
    file rename -- $author [file join $work put-away]
    set host [file join $recipient machteld.exe]
    file copy -- $exe $host
    set merge {observations.machteld import observations.db}

    equal [invoke $recipient $host $merge $north] {inserted 1} "first source"
    equal [invoke $recipient $host $merge $south] {inserted 1} "independent contrasting source"
    set first {north n1 colour 10 30 blue 0}
    set second {south s1 colour 20 40 green 0}
    set disagreement [list [lreplace $first end end 1] [lreplace $second end end 1]]
    equal [at $recipient $host 9] {} "before either interval"
    equal [at $recipient $host 10] [list $first] "inclusive start"
    equal [at $recipient $host 20] $disagreement "each claim flagged in overlap"
    equal [at $recipient $host 29] $disagreement "both accounts remain reconstructible"
    equal [at $recipient $host 30] [list $second] "exclusive end clears disagreement"
    equal [at $recipient $host 40] {} "gap after both intervals"
    equal [at $recipient $host 25 7] {} "007 differs from 7"

    equal [invoke $recipient $host $merge $north] {inserted 0} "identical replay"
    set reordered {{"claims":[{"page":4,"value":"blue","ends":30,"starts":10,"field":"colour","entity":"007","id":"n1"}],"source":"north"}}
    equal [invoke $recipient $host $merge $reordered] {inserted 0} "reordered fields replay the same claim"
    invoke $recipient $host $merge $invalid {*starts_must_precede_ends*}
    equal [at $recipient $host 25] $disagreement "valid prefix of invalid batch rolled back"
    set revision {{"source":"north","claims":[
        {"id":"new","entity":"007","field":"weight","starts":20,"ends":29,"value":"heavy"},
        {"id":"n1","entity":"007","field":"colour","starts":10,"ends":30,"value":"blue","page":5}]}}
    invoke $recipient $host $merge $revision {*reused claim id 'n1'*}
    equal [at $recipient $host 25] $disagreement "changed source evidence rolls back preceding claim"
    set duplicate {{"source":"east","claims":[
        {"id":"e1","entity":"007","field":"weight","starts":20,"ends":30,"value":"heavy"},
        {"id":"e1","entity":"007","field":"weight","starts":20,"ends":30,"value":"heavy"}]}}
    equal [invoke $recipient $host $merge $duplicate] {inserted 1} "duplicate within one batch reads its pending write"
    equal [at $recipient $host 25] [concat $disagreement {{east e1 weight 20 30 heavy 0}}] "different fields are independent"
    set agreement [string map {north east} $north]
    equal [invoke $recipient $host $merge $agreement] {inserted 1} "two sources can reuse a local id"
    equal [at $recipient $host 12] [list [lreplace $first 0 0 east] $first] "independent sources agreeing are both retained"
    set utf8 [encoding convertto utf-8 {{"source":"sud","claims":[
        {"id":"é1","entity":"007","field":"label","starts":40,"ends":50,"value":"café 雪"}]}}]
    equal [invoke $recipient $host $merge $utf8] {inserted 1} "UTF-8 batch"
    equal [at $recipient $host 42] {{sud é1 label 40 50 {café 雪} 0}} "UTF-8 evidence survives the archive boundary"
    sqlite3 verify $database -readonly 1 -create 0
    try {
        equal [verify onecolumn {SELECT count(*) FROM claims}] 5 "durable count including replays and rollbacks"
        equal [verify onecolumn {SELECT json_extract(payload, '$.page') FROM claims WHERE source='north' AND id='n1'}] 4 "original source-specific evidence preserved"
    } finally {verify close}
}

set root [file dirname [file dirname [file normalize [info script]]]]
set work [file normalize [file tempdir]]
try {
    ::importTest::exercise $work $root
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "typed import archive: $::importTest::checks assertions passed"
