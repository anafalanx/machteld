package require machteld

namespace eval ::migrationTest {variable checks 0}

proc ::migrationTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::migrationTest::command {exe cwd arguments} {
    set run [::machteld::run -dir $cwd -timeout 15s -- $exe {*}$arguments]
    equal [dict get $run truncated] {} "complete child output"
    set stdout [encoding convertfrom -profile strict utf-8 [dict get $run out]]
    set stderr [encoding convertfrom -profile strict utf-8 [dict get $run err]]
    return [list [dict get $run exit] $stdout $stderr]
}

proc ::migrationTest::success {exe cwd args} {
    lassign [command $exe $cwd $args] status out err
    equal [list $status $err] {0 {}} "successful [list {*}$args] ($err)"
    return [string trimright $out "\r\n"]
}

proc ::migrationTest::callbacks {exe cwd prefix} {
    set title {007; [error BAD] $name 雪}
    set failure {unknown field 'missing'}
    set results {}
    foreach {args expected} [list [list shelf $title] [list 0 "Shelf: $title\n" {}] \
        {id {}} [list 0 "Inventory ID: \n" {}] \
        {missing 2} [list 1 {} "[list {CARDS FIELD UNKNOWN} $failure]\n"]] {
        set result [command $exe $cwd [list {*}$prefix {*}$args]]
        equal $result $expected "callback [list {*}$args]"
        lappend results $result
    }
    set signature [success $exe $cwd {*}$prefix --legacy-signature]
    equal $signature [list {field value} {TCL WRONGARGS} {wrong # args: should be "::cards::caption field value"}] \
        "Tcl introspection and arity diagnostic"
    return $results
}

proc ::migrationTest::readText {path} {
    set ch [open $path rb]
    try {encoding convertfrom -profile strict utf-8 [read $ch]} finally {close $ch}
}

proc ::migrationTest::writeText {path text} {
    set ch [open $path wb]
    try {puts -nonewline $ch [encoding convertto -profile strict utf-8 $text]} finally {close $ch}
}

proc ::migrationTest::probeEntry {entry} {
    # Instrument the unchanged entry in a disposable copy. The opt-in line
    # remains first and all ordinary callbacks still run the original code.
    set script [readText $entry]
    set pos [string first \n $script]
    set probe {if {[lindex $argv 0] eq "--entry-context"} {
        chan configure stdout -translation lf -encoding utf-8
        puts [list [file normalize $argv0] [file normalize [info script]] \
            [lindex [file system [info script]] 0] [pwd] $argc $argv]
        return
    }
    if {$argv eq "--legacy-signature"} {
        lappend ::auto_path [file join [file dirname [info script]] lib]
        package require cards::captions 1.0
        catch {::cards::caption shelf} message options
        puts [list [info args ::cards::caption] [dict get $options -errorcode] $message]
        return
    }}
    writeText $entry [string replace $script $pos $pos "\n$probe\n"]
}

proc ::migrationTest::context {exe cwd prefix identity packed} {
    set args [list --entry-context {two words} {}]
    set result [success $exe $cwd {*}$prefix {*}$args]
    lassign $result argv0 script filesystem current argc argv
    equal $argv0 [file normalize $identity] "public application identity"
    if {$packed} {
        equal $filesystem zipfs "Tcl entry came from the validated archive"
        equal [string match {*/project/inputs/main.tcl} $script] 1 "original Tcl entry inside archive"
    } else {
        equal $filesystem native "Tcl entry came from disk"
        equal $script $argv0 "Tcl entry filename"
    }
    equal $current $cwd "unrelated caller directory"
    equal $argc 3 "argument count"
    equal $argv $args "argument word boundaries"
}

proc ::migrationTest::guardedEntry {author manifest} {
    # A traditional sourceable Tcl script only starts itself when launched
    # directly. The project adapter sources its definitions then calls main.
    writeText [file join $author guarded.tcl] {package require machteld
lappend auto_path [file join [file dirname [info script]] lib]
package require cards::captions 1.0
namespace eval ::legacy {variable calls 0}
proc ::legacy::main {arguments} {
    variable calls
    puts [list [incr calls] [::cards::caption {*}$arguments]]
}
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    ::legacy::main $::argv
}}
    writeText [file join $author startup.tcl] {package require machteld
source -encoding utf-8 [file join [file dirname [info script]] guarded.tcl]
::legacy::main $::argv}
    set project [file join $author guarded.dict]
    set assets [concat [dict get $manifest assets] guarded.tcl]
    writeText $project [dict replace $manifest tclEntry startup.tcl assets $assets]
    return $project
}

proc ::migrationTest::invalidManifests {exe cwd driver dir manifest} {
    set path [file join $dir invalid.dict]
    writeText [file join $dir incomplete.tcl] "package require machteld\nset value \{"
    set channel [open [file join $dir malformed.tcl] wb]
    try {puts -nonewline $channel [binary decode hex c328]} finally {close $channel}
    foreach {label data} [list \
            {two entry points} [dict replace $manifest entry {logic twice}] \
            {missing entry} [dict remove $manifest tclEntry] \
            {escaping entry} [dict replace $manifest tclEntry ../main.tcl] \
            {entry also listed as an asset} [dict replace $manifest assets main.tcl] \
            {incomplete Tcl} [dict replace $manifest tclEntry incomplete.tcl] \
            {invalid UTF-8} [dict replace $manifest tclEntry malformed.tcl]] {
        writeText $path $data
        lassign [command $exe $cwd [list $driver check --json $path]] exit stdout stderr
        equal [list $exit $stderr] {1 {}} "rejected manifest ($label)"
        set report [::machteld::json decode $stdout]
        equal [dict get [lindex [dict get $report diagnostics] 0] code] PROJECT_INVALID "manifest diagnostic ($label)"
    }
}

proc ::migrationTest::exportSurface {work exe driver packed} {
    set dir [file join $work exports]
    file mkdir $dir
    writeText [file join $dir types.src] {export record .reading { id: int }}
    writeText [file join $dir logic.src] {fn .factor($number: int) -> int => $number * 2
export fn .twice($number: int) -> int => .factor($number)
extern fn .read_host() -> text = ['::fixture::fetch']
export fn .lookup() -> text => .read_host()}
    writeText [file join $dir main.tcl] {package require machteld
namespace eval ::fixture {}
proc ::fixture::fetch {} {return -code error -errorcode {FIXTURE UNAVAILABLE} {stock file offline}}
if {$argv eq "--uncaught"} {::application::logic::lookup}
proc failure {prefix} {
    catch {{*}$prefix} message options
    set where [dict get $options -appcompilerlocation]
    list $message [dict get $options -errorcode] [dict get $where module] [dict get $where line]
}
namespace eval ::caller {
    namespace import ::application::logic::twice ::application::logic::lookup
    set out [dict create twice [twice 7] command [namespace origin twice] \
        nativeError [failure ::caller::lookup] inputError [failure [list ::caller::twice wrong]] \
        private [info commands ::application::logic::factor]]
    catch {::application::logic::factor 1} message options
    dict set out privateError [lrange [dict get $options -errorcode] 0 2]
    puts $out
}}
    set manifest {schema 1 edition 1 minApi 30 tclEntry main.tcl modules {logic logic.src types types.src}}
    set path [file join $dir project.dict]
    writeText $path $manifest
    invalidManifests $exe $work $driver $dir $manifest
    set calls [list [list $driver run $path]]
    if {$packed} {
        set archive [file join $work surface.machteld]
        success $exe $work $driver pack $path $archive
        lappend calls [list $archive]
    }
    foreach prefix $calls {
        lassign [command $exe $work [list {*}$prefix --uncaught]] code out err
        equal [list $code $out] {1 {}} "uncaught export error fails the application"
        equal [string match {*stock file offline*} $err] 1 "uncaught export keeps the Tcl message"
        equal [regexp {\(typed source logic:3:[1-9][0-9]*\)} $err] 1 "uncaught export names its original typed source line"
        set actual [success $exe $work {*}$prefix]
        equal [dict get $actual twice] 14 "public export calls private typed code"
        equal [dict get $actual command] ::application::logic::twice "namespace import selects the public Tcl command"
        equal [dict get $actual nativeError] {{stock file offline} {FIXTURE UNAVAILABLE} logic 3} "native error keeps its message, code and extern source line"
        equal [dict get $actual inputError] {{expected int at $number} {APPCOMPILER ARGUMENT TYPE} logic 2} "export type guard identifies its source"
        equal [dict get $actual private] {} "private function has no public Tcl name"
        equal [dict get $actual privateError] {TCL LOOKUP COMMAND} "private command cannot be called on the public surface"
    }
    writeText [file join $dir typesonly.tcl] {package require machteld
puts ready}
    writeText $path [dict replace $manifest tclEntry typesonly.tcl modules {types types.src}]
    equal [success $exe $work $driver run $path] ready "application with a declarations-only typed module"
    if {$packed} {
        set archive [file join $work typesonly.machteld]
        success $exe $work $driver pack $path $archive
        equal [success $exe $work $archive] ready "packed project with no typed functions"
    }
}

proc ::migrationTest::exercise {work root packed} {
    set exe [info nameofexecutable]
    set driver [file join $root tools application_project.tcl]
    exportSurface $work $exe $driver $packed
    set sample [file join $root examples mixed-migration]
    set author [file join $work {author's work}]
    set caller [file join $work {unrelated caller}]
    file mkdir $author $caller
    file copy [file join $sample lib] $author
    set main [file join $author main.tcl]
    file copy [file join $sample main.tcl] $main
    probeEntry $main
    set adapter [file join $author lib captions.tcl]
    file copy -force [file join $sample before captions.tcl] $adapter
    set project [file join $author project.dict]
    set manifest [readText [file join $sample project.dict]]
    writeText $project [dict replace $manifest modules {}]
    set guarded [guardedEntry $author $manifest]
    set once [success $exe $caller [file join $author guarded.tcl] id 007]
    equal $once {1 {Inventory ID: 007}} "original guarded entry starts once on disk"

    set original [callbacks $exe $caller [list $main]]
    context $exe $caller [list $main] $main 0
    set run [list $driver run $project]
    equal [callbacks $exe $caller $run] $original "unmigrated project with zero typed modules"
    context $exe $caller $run $main 0
    equal [success $exe $caller $driver test $project] {0 examples: 0 passed, 0 failed} "Tcl-only project examples"

    # Migrate only the captions package. Its caller, pkgIndex and field
    # catalogue remain byte-for-byte identical through the transition.
    file copy -force [file join $sample lib captions.tcl] $adapter
    file copy [file join $sample captions.src] $author
    writeText $project $manifest
    success $exe $caller $driver check $project
    equal [success $exe $caller $driver test $project] {2 examples: 2 passed, 0 failed} "examples resolve Tcl externs without launching the entry"
    equal [callbacks $exe $caller $run] $original "mixed source preserves the legacy callback contract"
    context $exe $caller $run $main 0
    equal [success $exe $caller $driver run $guarded id 007] $once "entry adapter starts guarded code once from source"
    if {!$packed} {return}

    set recipient [file join $work {recipient 雪}]
    file mkdir $recipient
    set draft [file join $author draft.machteld]
    success $exe $caller $driver pack $project $draft
    set guardedArchive [file join $work guarded.machteld]
    success $exe $caller $driver pack --without-source --without-compiler $guarded $guardedArchive
    set archive [file join $recipient cards.machteld]
    file rename -- $draft $archive
    set host [file join $recipient machteld.exe]
    file copy -- $exe $host
    file rename -- $author [file join $work put-away]
    equal [lsort [glob -directory $recipient -tails *]] {cards.machteld machteld.exe} "relocated runtime and archive"
    equal [callbacks $host $caller [list $archive]] $original "relocated archive needs no author directory"
    context $host $caller [list $archive] $archive 1
    equal [success $host $caller $guardedArchive id 007] $once "a source-free mixed archive keeps its Tcl entry and packages"

    set mount [zipfs mount $archive mixed-migration]
    set compiler [file join $recipient compiler]
    try {
        ::machteld::ArchiveEntry $mount
        file copy [file join $mount compiler] $compiler
    } finally {zipfs unmount $mount}
    set rebuilt [file join $recipient rebuilt.machteld]
    set bundledDriver [file join $compiler driver.tcl]
    success $host $caller $bundledDriver rebuild $archive $rebuilt
    equal [callbacks $host $caller [list $rebuilt]] $original "recipient rebuilds from both archived languages"
    context $host $caller [list $rebuilt] $rebuilt 1
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
set root [file dirname [file dirname [file normalize [info script]]]]
set work [file normalize [file tempdir]]
try {
    ::migrationTest::exercise $work $root [expr {$argv eq "-pack"}]
} finally {
    if {[file normalize $work] eq $work && [file dirname $work] ne $work} {file delete -force -- $work}
}
puts "application compiler mixed migration: $::migrationTest::checks assertions passed"
