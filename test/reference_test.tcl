# Complete live contract for the embedded agent reference.
package require machteld

set fails 0
proc check {name condition {detail ""}} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name $detail" }
}
proc errorcode {script} {
    if {![catch {uplevel 1 $script} message options]} { return {} }
    return [dict get $options -errorcode]
}

# Derived, not hardcoded: the release gate caught 0.14.0 literals in two test
# files during the 0.15.0 sweep; the version comes from machteld.h or nowhere.
set header [open [file join [file dirname [info script]] .. src machteld.h] r]
set headerText [read $header]
close $header
if {![regexp -line {^#define\s+MACHTELD_VERSION\s+"([1-9][0-9]*)"} $headerText -> expectedVersion]} {
    error "src/machteld.h has no canonical MACHTELD_VERSION"
}

set status [docs status]
check {status identifies schema and runtime} [expr {
    [dict get $status schema] == 2 && [dict get $status machteld] eq $expectedVersion &&
    [dict get $status root] eq "self" && [string length [dict get $status corpus_sha256]] == 64}]
check {status inventories exact Tcl/Tk manuals} [expr {
    [dict get $status products tcl version] eq "9.0.4" &&
    [dict get $status products tk version] eq "9.0.4" &&
    [dict get $status products tcl documents] == 250 &&
    [dict get $status products tk documents] == 178 &&
    [dict get $status products tcl manual_pages] == 249 &&
    [dict get $status products tk manual_pages] == 177}]

set cffiManual [docs get cffi/manual/cookbook -section {defining-a-function} -all 1]
check {the bundled cffi manual preserves upstream declarations, as searchable Markdown} [expr {
    [dict get $status products cffi version] eq [lindex [package versions cffi] 0] &&
    [dict get $status products cffi manual_pages] == 4 &&
    [string first {WINAPI DWORD GetCurrentProcessId(void);} [dict get $cffiManual text]] >= 0 &&
    [errorcode {docs get cffi/manual/cookbook -format source}] eq {MACHTELD DOCS unsupported} &&
    [dict get [docs get cffi/license -limit 16] id] eq "cffi/license"}]

foreach {lookup section snippet} {
    cffi::pointer pointer {pointer subcommand}
    {cffi::pointer address} pointer-address {pointer address}
    {::cffi::memory get!} memory-get-bang {memory get!}
    { ::CFFI::Memory   get! } memory-get-bang {memory get!}
    {cffi::memory get} memory-get {memory get}
    {cffi::Wrapper function} wrapper-function {WRAPPEROBJ function fnname fntype parameters}
    {cffi::Wrapper new} wrapper-constructor {looks up bare DLL names in System32}
    {cffi::Struct new} struct-constructor {Struct create OBJNAME}
    {STRUCTOBJ new} struct-new {Allocates and initializes a native struct}
    {cffi::Union size} union-size {UNIONOBJ size}
    {cffi::Struct size} struct-size {STRUCTOBJ size}
    {cffi::Wrapper destroy} wrapper-destructor {WRAPPEROBJ destroy}
} {
    set result [docs get $lookup]
    set text [dict get $result text]
    check "cffi reference resolves $lookup to its signature and section" [expr {
        [dict get $result id] eq "cffi/manual/commands" && [dict get $result section] eq $section &&
        [dict get $result total] < 8192 && ![dict get $result truncated] &&
        [string first $snippet $text] >= 0 && [regexp -all -line {^### } $text] == 1 &&
        $text eq [dict get [docs get cffi/manual/commands#$section] text]}]
}
check {qualified cffi section lookups rank their owning page first in search} [expr {
    [dict get [lindex [dict get [docs search {cffi::Wrapper function} -limit 1] items] 0] id] eq "cffi/manual/commands"}]
foreach lookup {{cffi::callback} {cffi::callback new} {cffi::callback free} cffi/manual/commands#synopsis cffi/manual/concepts#callbacks} {
    set text [dict get [docs get $lookup -limit 400] text]
    check "$lookup explains synchronous-only Windows support immediately" [expr {
        [string first {Machteld on Windows disables native-to-Tcl callbacks.} $text] >= 0}]
}

set schema [docs schema]
check {schema describes all operations and bounded retrieval} [expr {
    [dict get $schema schema] == 2 && [dict get $schema catalog_schema] == 2 &&
    [lsort [dict keys [dict get $schema subcommands]]] eq
        {extract get list outline schema search status verify} &&
    [dict get $schema pagination get maximum_limit] == 1048576}]
check {schema declares boolean JSON envelopes and compact stable ids} [expr {
    [dict get $schema formats json_envelope success] eq {ok true result value} &&
    [dict get $schema formats json_envelope failure] eq {ok false error {domain DOCS code code message message}} &&
    [string match {*machteld/agent*} [dict get $schema identifiers canonical]] &&
    [string match {*machteld/index*} [dict get $schema identifiers canonical]] &&
    [string match {*product/license*} [dict get $schema identifiers canonical]]}]
check {stable agent guide id resolves despite its guide type} [expr {
    [dict get [docs get machteld/agent -limit 32] id] eq "machteld/agent"}]
set missingDocs {}
dict for {verb facts} [manifest] {
    set targets [list [dict get $facts doc]]
    if {[dict exists $facts subcommands]} {
        dict for {sub details} [dict get $facts subcommands] {
            lappend targets [dict get $details doc]
        }
    }
    foreach target $targets {
        if {[catch {docs get $target -limit 1}]} {lappend missingDocs $target}
    }
}
check {every running public command and subcommand resolves to its documented page or section} \
    [expr {![llength $missingDocs]}] $missingDocs
set packageIds [lmap item [dict get [docs list -scope machteld -type package -limit 200] items] {
    dict get $item id
}]
foreach name {browser cffi encoding files httpd job network sqlite sqlite3} {
    check "shipped package $name has a discoverable Markdown manual" \
        [expr {"machteld/package/$name" in $packageIds}]
}
check {host startup and a namespaced UDP command resolve from the packaged reference} [expr {
    [dict get [docs get machteld/application/host -limit 1] id] eq "machteld/application/host" &&
    [dict get [docs get ::machteld::network::udp -limit 1] id] eq "machteld/package/network"}]
check {stable two-part license ids resolve despite their license type} [expr {
    [dict get [docs get machteld/license -limit 16] id] eq "machteld/license" &&
    [dict get [docs get tcl/license -limit 16] id] eq "tcl/license" &&
    [dict get [docs get tk/license -limit 16] id] eq "tk/license"}]
set bootstrap [::machteld::DocsHost]
check {no-argument host route returns the complete agent bootstrap} [expr {
    [string match {*# Agent documentation bootstrap*} $bootstrap] &&
    [string match {*docs status*docs get*docs search*docs extract*} $bootstrap]}]
set bootstrapJson [json decode [::machteld::DocsHost --json]]
check {no-argument JSON route is a typed complete get response} [expr {
    [dict get $bootstrapJson ok] == 1 &&
    [dict get $bootstrapJson result id] eq "machteld/agent" &&
    ![dict get $bootstrapJson result truncated]}]

set dictPage [docs get tcl/command/dict -limit 200]
check {exact Tcl page retrieval is bounded} [expr {
    [dict get $dictPage id] eq "tcl/command/dict" &&
    [dict get $dictPage returned] <= 200 && [dict get $dictPage truncated] &&
    [dict get $dictPage next] eq [dict get $dictPage returned]}]
set nextPage [docs get tcl/command/dict -offset [dict get $dictPage next] -limit 200]
check {get continuation advances by Unicode characters} [expr {
    [dict get $nextPage offset] == [dict get $dictPage next] &&
    [dict get $nextPage text] ne [dict get $dictPage text]}]
set synopsis [docs get tcl/command/dict -section synopsis -all 1]
check {section retrieval returns the requested complete span} [expr {
    [dict get $synopsis section] eq "synopsis" && ![dict get $synopsis truncated] &&
    [string length [dict get $synopsis text]] > 20}]
set fragment [docs get machteld/command/child#start -limit 100]
check {fragment IDs select authored subcommand sections} [expr {
    [dict get $fragment id] eq "machteld/command/child" && [dict get $fragment section] eq "start"}]

check {schema two declares Markdown and rejects the retired representations} [expr {
    [dict get $status formats] eq {markdown} &&
    [errorcode {docs get tcl/command/dict -format html}] eq {MACHTELD DOCS unsupported} &&
    [errorcode {docs get tcl/command/dict -format source}] eq {MACHTELD DOCS unsupported}}]
check {authored Machteld pages refuse nonexistent upstream representation} [expr {
    [errorcode {docs get machteld/command/run -format source}] eq {MACHTELD DOCS unsupported}}]

set capi [docs get tcl/c-api/crtobjcmd -limit 80]
check {C API IDs are canonical lowercase} [expr {[dict get $capi id] eq "tcl/c-api/crtobjcmd"}]
set alias [docs get Tcl_CreateObjCommand -limit 80]
check {original C API spelling is an exact alias} [expr {[dict get $alias id] eq [dict get $capi id]}]
set normalizedAlias [docs get {  Tcl   Tcl_CreateObjCommand  } -limit 80]
check {alias lookup lowercases, trims, and collapses whitespace} [expr {
    [dict get $normalizedAlias id] eq [dict get $capi id]}]
# Choose an actual ambiguous name from this version's catalog.
set ambiguous [::machteld::ReferenceDb onecolumn {
    SELECT a.name FROM alias a WHERE NOT EXISTS (SELECT 1 FROM page WHERE id=a.name)
    GROUP BY a.name HAVING count(*)>1 ORDER BY a.name LIMIT 1}]
check {ambiguous aliases identify multiple candidates} [expr {
    $ambiguous ne "" && [errorcode [list docs get $ambiguous]] eq {MACHTELD DOCS ambiguous}}]
check {reference connection rejects writes even after query_only is disabled} [expr {
    ![catch {::machteld::ReferenceDb eval {PRAGMA query_only=OFF}}] &&
    [catch {::machteld::ReferenceDb eval {DELETE FROM page}}]}]
::machteld::ReferenceDb eval {PRAGMA query_only=ON}
set listed [docs list -scope tcl -type command -limit 7]
set listFiltersOk 1
foreach item [dict get $listed items] {
    if {[dict get $item product] ne "tcl" || [dict get $item type] ne "command"} { set listFiltersOk 0 }
}
check {list applies exact filters and stable pagination} [expr {
    [dict get $listed returned] == 7 && [dict get $listed next] == 7 &&
    $listFiltersOk}]
check {empty list filters mean unfiltered} [expr {
    [dict get [docs list -scope {} -type {} -limit 1] returned] == 1}]
set searched [docs search {dictionary key value} -scope tcl -type command -limit 5]
check {search is ranked, filtered, bounded, and actionable} [expr {
    [dict get $searched returned] > 0 && [dict get $searched returned] <= 5 &&
    [dict exists [lindex [dict get $searched items] 0] score] &&
    [dict get [lindex [dict get $searched items] 0] product] eq "tcl"}]
check {search rejects degenerate query} [expr {
    [errorcode {docs search {   }}] eq {MACHTELD DOCS badvalue}}]
foreach query {{-maxframe} {MACHTELD POOL} {tcl/command/dict} {read "binary" data}} {
    set result [docs search $query -limit 2]
    check "punctuation, options and plain-language queries produce bounded matches: $query" [expr {
        [dict get $result returned] > 0 && [dict get $result returned] <= 2}]
}
set resolved 0
set checkedSections 0
set mismatches {}
for {set offset 0} {$offset < [dict get $status documents]} {incr offset 200} {
    foreach page [dict get [docs list -offset $offset -limit 200] items] {
        set id [dict get $page id]
        set whole [docs get $id -all 1]
        set body [dict get $whole text]
        if {[hash sum sha256 [encoding convertto utf-8 $body]] ne [dict get $whole sha256]} {lappend mismatches $id}
        set spans [::machteld::ReferenceDb eval {SELECT slug,start,end FROM section WHERE id=$id ORDER BY start,slug}]
        foreach {slug start end} $spans {
            set slice [docs get $id#$slug -limit 19]
            if {[dict get $slice section] ne $slug || [dict get $slice total] != $end-$start ||
                    [dict get $slice text] ne [string range $body $start [expr {min($start+19,$end)-1}]]} {
                lappend mismatches $id#$slug
            }
            incr checkedSections
        }
        incr resolved
    }
}
check "all $resolved pages and $checkedSections section IDs retrieve the stored Markdown" [expr {
    $resolved == [dict get $status documents] && $checkedSections > 3000 && ![llength $mismatches]}] [lrange $mismatches 0 3]
check {search accepts short tokens and get resolves an exact short name} [expr {
    [dict get [docs search a -limit 1] returned] == 1 &&
    [dict get [docs get if -limit 16] id] eq {tcl/command/if}}]

foreach spelling {+1 01 0x10 1_0 -1} {
    check "pagination rejects noncanonical integer $spelling" [expr {
        [errorcode [list docs list -offset $spelling]] eq {MACHTELD DOCS badvalue}}]
}
check {public arity failures stay in the DOCS domain} [expr {
    [errorcode {docs}] eq {MACHTELD DOCS usage} &&
    [errorcode {docs status extra}] eq {MACHTELD DOCS usage} &&
    [errorcode {docs get}] eq {MACHTELD DOCS usage} &&
    [errorcode {docs outline}] eq {MACHTELD DOCS usage} &&
    [errorcode {docs search}] eq {MACHTELD DOCS usage} &&
    [errorcode {docs extract}] eq {MACHTELD DOCS usage}}]

set verified [docs verify]
check {verify proves the full declared corpus} [expr {
    [dict get $verified ok] && [dict get $verified documents] == [dict get $status documents] &&
    [dict get $verified corpus_sha256] eq [dict get $status corpus_sha256] &&
    [dict get $verified files] == 1}]

set work [file join $env(TEMP) machteld-reference-test-[pid]-[binary encode hex [hash random 8]]]
file mkdir $work
set destination [file join $work exported]
set extracted [docs extract $destination]
set exported [file join $destination reference.db]
check {the embedded and extracted documentation each contain only the same reference.db} [expr {
    [glob -tails -directory [::machteld::DocsRoot] *] eq {reference.db} &&
    [glob -tails -directory $destination *] eq {reference.db} &&
    [dict get $extracted files] == 1 && [dict get $extracted bytes] == [file size $exported] &&
    [hash file sha256 $exported] eq [dict get $status corpus_sha256] &&
    [dict get $extracted corpus_sha256] eq [dict get $status corpus_sha256]}]
sqlite3 ::exportedManual $exported -readonly 1
try {
    check {a standalone SQLite reader can search and retrieve the Markdown without sidecars} [expr {
        [exportedManual exists {SELECT 1 FROM search JOIN page ON page.rowid=search.rowid
            WHERE search MATCH '"dictionary"' AND page.id='tcl/command/dict'}] &&
        [exportedManual onecolumn {SELECT body FROM page WHERE id='tcl/command/dict'}] eq
            [dict get [docs get tcl/command/dict -all 1] text]}]
} finally {exportedManual close}
check {extract never replaces an existing destination} [expr {
    [errorcode [list docs extract $destination]] eq {MACHTELD DOCS exists}}]

# Put a competing directory in the namespace after all staged files have
# passed verification, immediately before the real Windows rename.
set competitor [file join $work late-target]
rename ::machteld::DirectoryStage ::machteld::ReferenceDirectoryStage
proc ::machteld::DirectoryStage {action from args} {
    if {$action eq "publish"} {
        set dest [lindex $args 0]
        file mkdir $dest
        set writer [open [file join $dest keep.txt] {WRONLY CREAT EXCL}]
        try {puts -nonewline $writer winner} finally {close $writer}
    }
    return [::machteld::ReferenceDirectoryStage $action $from {*}$args]
}
try {
    set lateCode [errorcode [list docs extract $competitor]]
} finally {
    rename ::machteld::DirectoryStage {}
    rename ::machteld::ReferenceDirectoryStage ::machteld::DirectoryStage
}
set reader [open [file join $competitor keep.txt] rb]
try {set winner [read $reader]} finally {close $reader}
check {a competing destination keeps its contents without receiving the staging directory} [expr {
    $lateCode eq {MACHTELD DOCS exists} && $winner eq "winner" &&
    [glob -tails -directory $competitor *] eq {keep.txt} &&
    ![llength [glob -nocomplain -directory $competitor .machteld-docs-*]] &&
    ![llength [glob -nocomplain -directory $work .machteld-docs-*]]}]

# Exercise fail-closed catalog parsing in an isolated mounted fixture without
# changing the executable's immutable payload.
set fixtureError ""
set fixtureStatus 0
set corruptCode {}
set corruptHelpCode {}
set mountName machteld-docs-corrupt-[pid]
set mounted 0
set rootRenamed 0
set fixtureStatus [catch {
    set fixtureRoot [file join $work corrupt-fixture]
    file mkdir $fixtureRoot
    file copy $destination [file join $fixtureRoot reference]
    file mkdir [file join $fixtureRoot extra]
    file copy $destination [file join $fixtureRoot extra reference]
    close [open [file join $fixtureRoot extra reference README.md] {WRONLY CREAT EXCL}]
    set channel [open [file join $fixtureRoot reference reference.db] ab]
    fconfigure $channel -translation binary
    puts -nonewline $channel [encoding convertto utf-8 { orphan}]
    close $channel
    set fixtureZip [file join $work corrupt.zip]
    zipfs mkzip $fixtureZip $fixtureRoot $fixtureRoot
    zipfs mount $fixtureZip $mountName
    set mounted 1
    rename ::machteld::PayloadRoot ::machteld::PayloadRootLive
    set rootRenamed 1
    catch {::machteld::ReferenceDb close}
    set ::machteld::DOCS_IDENTITY {}
    proc ::machteld::PayloadRoot {} [list return //zipfs:/$mountName/extra]
    check {a valid database beside a loose manual is rejected} [expr {
        [errorcode {docs status}] eq {MACHTELD DOCS corrupt}}]
    proc ::machteld::PayloadRoot {} [list return //zipfs:/$mountName]
    set corruptCode [errorcode {docs status}]
    set corruptHelpCode [errorcode {help dict}]
    # This existing zipfs directory has no reference/ child.
    proc ::machteld::PayloadRoot {} [list return //zipfs:/$mountName/reference]
    foreach query {
        {docs status}
        {docs list}
        {docs get tcl/command/dict}
        {docs outline tcl/command/dict}
        {docs search dictionary}
        {docs verify}
    } {
        check "omitted reference rejects $query with unsupported" [expr {
            [errorcode $query] eq {MACHTELD DOCS unsupported}}]
    }
    check {omitted reference rejects extraction with unsupported} [expr {
        [errorcode [list docs extract [file join $work omitted-export]]] eq
            {MACHTELD DOCS unsupported} &&
        ![file exists [file join $work omitted-export]]}]
    check {omitted reference retains schema and maps help query errors} [expr {
        [dict get [docs schema] schema] == 2 &&
        [errorcode {help dict}] eq {MACHTELD HELP unsupported}}]
    set noPackHelp [help]
    check {omitted reference help gives honest same-version recovery guidance} [expr {
        [string match {*carries no embedded reference pack*} $noPackHelp] &&
        [string match "*full Machteld [version] executable*" $noPackHelp] &&
        [string match {*offline documentation*docs schema*} $noPackHelp] &&
        ![string match {*contains the complete*} $noPackHelp]}]
    set fixtureResult ""
} fixtureError]
if {$rootRenamed} {
    catch {rename ::machteld::PayloadRoot {}}
    catch {rename ::machteld::PayloadRootLive ::machteld::PayloadRoot}
}
catch {::machteld::ReferenceDb close}
set ::machteld::DOCS_IDENTITY {}
if {$mounted} { catch {zipfs unmount $mountName} }
check {catalog corruption fails closed in an isolated fixture} [expr {
    $fixtureStatus == 0 && $fixtureError eq "" &&
    $corruptCode eq {MACHTELD DOCS corrupt} &&
    $corruptHelpCode eq {MACHTELD HELP oserror}}] $fixtureError

set jsonOk [::machteld::DocsHost --json get tcl/command/dict --limit 42]
set decoded [json decode $jsonOk]
check {host JSON uses typed success envelope} [expr {
    [dict get $decoded ok] == 1 && [dict get $decoded result returned] == 42 &&
    [dict get $decoded result id] eq "tcl/command/dict"}]
set statusJson [::machteld::DocsHost --json status]
check {status JSON keeps product counts numeric} [expr {
    [regexp {"manual_pages":249(?:,|\})} $statusJson] &&
    ![regexp {"manual_pages":"249"} $statusJson]}]
set schemaJson [::machteld::DocsHost --json schema]
set schemaDecoded [json decode $schemaJson]
check {schema JSON models the actual nested boolean envelopes} [expr {
    [dict get $schemaDecoded ok] == 1 &&
    [dict get $schemaDecoded result formats json_envelope success ok] == 1 &&
    [dict get $schemaDecoded result formats json_envelope success result] eq "value" &&
    [dict get $schemaDecoded result formats json_envelope failure ok] == 0 &&
    [dict get $schemaDecoded result formats json_envelope failure error domain] eq "DOCS" &&
    [regexp {"success":\{"ok":true,"result":"value"\}} $schemaJson] &&
    [regexp {"failure":\{"ok":false,"error":\{"domain":"DOCS"} $schemaJson]}]
check {JSON text quoting never infers numeric-looking strings} [expr {
    [::machteld::DocsJString 42] eq {"42"} &&
    [json decode [::machteld::DocsJString 42]] eq "42"}]
catch {::machteld::DocsHost nonsense --json} jsonBad jsonOptions
set decodedBad [json decode $jsonBad]
check {host parser errors use typed failure envelope and nonzero result} [expr {
    [dict get $decodedBad ok] == 0 && [dict get $decodedBad error domain] eq "DOCS" &&
    [dict get $decodedBad error code] eq "usage" &&
    [dict get $jsonOptions -errorcode] eq {MACHTELD DOCS usage}}]
set output [file join $work status.json]
rename ::machteld::Publish ::machteld::ReferenceTestPublish
proc ::machteld::Publish {staged destination} {
    set ::referenceOutputSibling [expr {[file dirname [file normalize $staged]] eq
        [file dirname [file normalize $destination]]}]
    return [::machteld::ReferenceTestPublish $staged $destination]
}
try {
    set outputResult [::machteld::DocsHost status --json --output $output]
} finally {
    rename ::machteld::Publish {}
    rename ::machteld::ReferenceTestPublish ::machteld::Publish
}
check {docs output stages on the destination volume in its own directory} $::referenceOutputSibling
set channel [open $output rb]
set outputText [read $channel]
close $channel
check {host JSON output publication returns no console payload} [expr {
    $outputResult eq "" && [dict get [json decode $outputText] ok] == 1}]

set errorOutput [file join $work error.json]
catch {::machteld::DocsHost nonsense --json --output $errorOutput} errorReply errorReplyOptions
set channel [open $errorOutput rb]
set errorOutputText [encoding convertfrom -profile strict utf-8 [read $channel]]
close $channel
check {host JSON publishes parser failures while preserving nonzero status} [expr {
    [dict get [json decode $errorOutputText] ok] == 0 &&
    [dict get $errorReplyOptions -errorcode] eq {MACHTELD DOCS usage}}]
set plainErrorOutput [file join $work error.txt]
catch {::machteld::DocsHost nonsense --output $plainErrorOutput} plainErrorReply plainErrorOptions
set channel [open $plainErrorOutput rb]
set plainErrorText [encoding convertfrom -profile strict utf-8 [read $channel]]
close $channel
check {host human mode also publishes parser failures} [expr {
    [string match {*unknown subcommand*} $plainErrorText] &&
    [dict get $plainErrorOptions -errorcode] eq {MACHTELD DOCS usage}}]
check {host output publication leaves no candidate files} [expr {
    ![llength [glob -nocomplain -directory $work .machteld-save-*]]}]
check {host rejects repeated JSON and noncanonical option syntax} [expr {
    [errorcode {::machteld::DocsHost --json --json status}] eq {MACHTELD DOCS usage} &&
    [errorcode {docs list --limit 1}] eq {MACHTELD DOCS usage}}]
catch {::machteld::DocsHost --json --json status} repeatedReply repeatedOptions
check {repeated JSON still returns the typed failure envelope} [expr {
    [dict get [json decode $repeatedReply] ok] == 0 &&
    [dict get $repeatedOptions -errorcode] eq {MACHTELD DOCS usage}}]
catch {::machteld::DocsHost get tcl/command/dict --limit} missingReply missingOptions
check {host reports missing option values through the DOCS domain} [expr {
    [dict get $missingOptions -errorcode] eq {MACHTELD DOCS usage}}]

check {help delegates exact pages through the trusted reference} [expr {
    [string length [help tcl/command/dict]] > 100}]
set longPage [docs get tk/command/text]
set longHelpRc [catch {help tk/command/text} longHelp]
set continuation [format {[Page truncated; continue with: docs get %s -offset %s]} \
    [dict get $longPage id] [dict get $longPage next]]
check {help returns a truncated real page with a literal continuation hint} [expr {
    [dict get $longPage truncated] && !$longHelpRc &&
    $longHelp eq "[dict get $longPage text]\n\n$continuation"}] $longHelpRc
check {help translates docs discovery failures into its own domain} [expr {
    [errorcode {help zxqzunknownmachteldverb}] eq {MACHTELD HELP notfound}}]
set startHere [help]
check {help discovery serves the searchable Markdown start page} [expr {
    $startHere eq [dict get [docs get machteld/start-here -all 1] text] &&
    [string first {machteld.exe app.tcl} $startHere] >= 0 &&
    [string first {machteld.exe pack app-directory -o app.machteld} $startHere] >= 0 &&
    [string first {machteld.exe app.machteld} $startHere] >= 0 &&
    [string first {docs get} $startHere] >= 0 && [string first {docs search} $startHere] >= 0 &&
    [string first {docs schema} $startHere] >= 0}]

file delete -force $work
if {$fails} { puts stderr "$fails reference test(s) failed"; exit 1 }
puts "reference tests passed"
