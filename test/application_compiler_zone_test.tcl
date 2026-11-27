package require machteld
source -encoding utf-8 [file join [file dirname [info script]] .. packages application-compiler compiler.tcl]

namespace eval ::zoneTest {
    variable checks 0
    variable source {export fn .candidates($observed: text, $zone: text) -> result<list<instant>,problem> =>
    resolve_zone(parse_local_datetime($observed)?, $zone)

fn .print($observed: text, $zone: text) -> result<unit,problem> {
    $instants ::= .candidates($observed, $zone)?
    for $at in $instants {
        write_stdout_utf8($"${instant_text($at)}\n")?
    }
    return ok(unit)
}

fn .main($args: list<text>) -> result<unit,problem> =>
    match $args {
        [$wall, $zone] => .print($wall, $zone)
        _ => err(problem('expected WALL_TIME ZONE'))
    }}
}

proc ::zoneTest::equal {actual expected label} {
    variable checks
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr checks
}

proc ::zoneTest::checkTypes {} {
    foreach {source code} {
        {fn .f($t: text) -> result<list<instant>,problem> => resolve_zone($t, 'UTC')} ARGUMENT_TYPE
        {fn .f($t: instant) -> result<list<instant>,problem> => resolve_zone($t, 'UTC')} ARGUMENT_TYPE
        {fn .f($t: local_datetime) -> result<list<instant>,problem> => resolve_zone($t, 60)} ARGUMENT_TYPE
        {fn .f($t: local_datetime) -> result<list<instant>,problem> => resolve_zone($t)} CALL_ARITY
        {fn .f($t: local_datetime) -> result<instant,problem> => resolve_zone($t, 'UTC')} RETURN_TYPE
    } {
        set diagnostics [::appcompiler::check [dict create sample $source]]
        equal [lmap d $diagnostics {dict get $d code}] [list $code] $source
    }
}

proc ::zoneTest::candidates {} {
    # Each row gives a wall reading followed by all UTC instants, earliest first.
    # Keep expectations literal so the test does not use the resolver as its oracle.
    foreach {zone wall expected} {
        Europe/Brussels 2026-01-12T12:00:00 {2026-01-12T11:00:00.000000000Z}
        Europe/Brussels 2026-07-12T12:00:00 {2026-07-12T10:00:00.000000000Z}
        Europe/Brussels 2026-03-29T01:59:59.999999999 {2026-03-29T00:59:59.999999999Z}
        Europe/Brussels 2026-03-29T02:00:00 {}
        Europe/Brussels 2026-03-29T02:59:59.999999999 {}
        Europe/Brussels 2026-03-29T03:00:00 {2026-03-29T01:00:00.000000000Z}
        Europe/Brussels 2026-10-25T01:59:59.999999999 {2026-10-24T23:59:59.999999999Z}
        Europe/Brussels 2026-10-25T02:00:00 {2026-10-25T00:00:00.000000000Z 2026-10-25T01:00:00.000000000Z}
        Europe/Brussels 2026-10-25T02:59:59.999999999 {2026-10-25T00:59:59.999999999Z 2026-10-25T01:59:59.999999999Z}
        Europe/Brussels 2026-10-25T03:00:00 {2026-10-25T02:00:00.000000000Z}
        Australia/Lord_Howe 2024-04-07T01:45:00 {2024-04-06T14:45:00.000000000Z 2024-04-06T15:15:00.000000000Z}
        Australia/Lord_Howe 2024-10-06T02:15:00 {}
        Australia/Lord_Howe 2024-10-06T02:30:00 {2024-10-05T15:30:00.000000000Z}
        Pacific/Apia 2011-12-30T12:00:00 {}
        Pacific/Apia 2011-12-31T00:00:00 {2011-12-30T10:00:00.000000000Z}
        Pacific/Apia 1892-07-04T12:00:00.000000001 {1892-07-03T23:26:56.000000001Z 1892-07-04T23:26:56.000000001Z}
        Europe/Brussels 1880-01-01T00:00:00.000000001 {1879-12-31T23:42:30.000000001Z}
        Asia/Kathmandu 2026-01-01T00:00:00 {2025-12-31T18:15:00.000000000Z}
        Asia/Kathmandu 1986-01-01T00:10:00 {}
        Asia/Katmandu 2026-01-01T00:00:00 {2025-12-31T18:15:00.000000000Z}
        Etc/GMT+1 2026-01-01T00:00:00 {2026-01-01T01:00:00.000000000Z}
        UTC 0001-01-01T00:00:00 {0001-01-01T00:00:00.000000000Z}
        Europe/Brussels 0001-01-01T00:17:30 {0001-01-01T00:00:00.000000000Z}
        Europe/Brussels 1500-03-01T00:00:00 {1500-02-28T23:42:30.000000000Z}
        Europe/Brussels 1600-03-01T00:00:00 {1600-02-29T23:42:30.000000000Z}
        Europe/Brussels 2099-07-12T12:00:00 {2099-07-12T10:00:00.000000000Z}
        UTC 2099-12-31T23:59:59.999999999 {2099-12-31T23:59:59.999999999Z}
        Pacific/Apia 2099-12-31T23:59:59 {2099-12-31T10:59:59.000000000Z}
    } {
        equal [::zoneApp::observations::candidates $wall $zone] [list ok $expected] "$zone $wall"
    }
}

proc ::zoneTest::problem {wall zone code} {
    lassign [::zoneApp::observations::candidates $wall $zone] tag detail
    equal $tag err "typed error for [list $wall $zone]"
    equal [dict get $detail code] $code "problem code for [list $wall $zone]"
}

proc ::zoneTest::invalid {} {
    set wall 2026-03-29T02:30:00
    foreach zone [list {} :localtime :Europe/Brussels Europe/brussels europe/Brussels \
            Europe/Unknown Europe//Brussels ../UTC /Etc/UTC {Europe\Brussels} \
            {C:/zoneinfo} {Europe/*} {Europe/Brussels } +01:00 {X/[clock seconds]} \
            "Europe/Brussels\x00" "Europe/Brussels\n"] {
        problem $wall $zone INVALID_ZONE
    }
    problem 2026-02-29T12:00:00 UTC INVALID_LOCAL_DATETIME
    problem 0001-01-01T00:00:00 Etc/GMT-1 INSTANT_RANGE
    problem 2099-12-31T23:00:00 Etc/GMT+1 ZONE_RANGE
    problem 2100-01-01T00:00:00 UTC ZONE_RANGE
    problem 2100-01-01T00:00:00 Pacific/Apia ZONE_RANGE
}

proc ::zoneTest::missingRules {script} {
    set app [interp create]
    try {
        $app eval $script
        # A plain Tcl interpreter may already know this zone. Only the
        # catalog belonging to the running Machteld host supplies its rules.
        $app eval {namespace eval ::tcl::clock {
            set TZData(:Europe/Brussels) {{-9223372036854775808 0 0 UTC}}
        }}
        lassign [$app eval {::zoneApp::observations::candidates 2026-03-29T02:30:00 Europe/Brussels}] tag detail
        equal $tag err "missing host catalog returns a typed error"
        equal [dict get $detail code] ZONE_DATA "missing host rules stay distinguishable from a clock gap"
    } finally {interp delete $app}
}

proc ::zoneTest::systemEncoding {} {
    # Chatham has not been looked up in this application. Its first read must
    # interpret the catalog bytes the same way under a different system encoding.
    set original [encoding system]
    try {
        encoding system unicode
        set result [::zoneApp::observations::candidates 2026-07-01T12:00:00 Pacific/Chatham]
    } finally {encoding system $original}
    equal $result {ok 2026-06-30T23:15:00.000000000Z} "zone lookup under a UTF-16 system encoding"
}

proc ::zoneTest::packed {work} {
    variable source
    set author [file join $work author]
    set delivery [file join $work delivery]
    file mkdir $author $delivery
    set manifest [file join $author project.dict]
    ::appcompiler::project::stageBytes $manifest {schema 1 edition 1 minApi 30 entry {observations main} modules {observations events.src}}
    ::appcompiler::project::stageBytes [file join $author events.src] [encoding convertto -profile strict utf-8 $source]
    set archive [file join $delivery events.machteld]
    ::appcompiler::project::pack $manifest $archive
    file rename -- $author [file join $work retired]
    set exe [file join $delivery machteld.exe]
    file copy -- [info nameofexecutable] $exe
    set fold "2026-10-25T00:30:00.000000001Z\n2026-10-25T01:30:00.000000001Z\n"
    foreach {hostZone wall expected} [list :Pacific/Apia 2026-10-25T02:30:00.000000001 $fold \
            :America/New_York 2026-10-25T02:30:00.000000001 $fold :UTC 2026-03-29T02:30:00 {}] {
        set run [::machteld::run -dir $delivery -env [dict create TZ $hostZone TCL_TZ $hostZone TCLLIBPATH {}] \
            -timeout 30s -- $exe $archive $wall Europe/Brussels]
        equal [dict get $run exit] 0 "relocated app exit (host $hostZone)"
        equal [dict get $run truncated] {} "complete output (host $hostZone)"
        equal [dict get $run err] {} "relocated app stderr (host $hostZone)"
        equal [dict get $run out] $expected "packed candidates (host $hostZone)"
    }
}

if {$argv ni {{} -pack}} {error "usage: [file tail [info script]] ?-pack?"}
::zoneTest::checkTypes
set artifact [::appcompiler::compile [dict create observations $::zoneTest::source] ::zoneApp]
namespace eval :: [dict get $artifact script]
::zoneTest::candidates
::zoneTest::invalid
::zoneTest::missingRules [dict get $artifact script]
::zoneTest::systemEncoding
if {$argv eq "-pack"} {
    set work [file normalize [file tempdir]]
    try {
        ::zoneTest::packed $work
    } finally {
        if {[file dirname $work] ne $work && [file normalize $work] eq $work} {file delete -force -- $work}
    }
}
puts "application compiler named zones: $::zoneTest::checks assertions passed"
