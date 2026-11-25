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
    [dict get $verified files] >= 6 && [dict get $verified files] < 20}]

set work [file join $env(TEMP) machteld-reference-test-[pid]-[binary encode hex [hash random 8]]]
file mkdir $work
set destination [file join $work exported]
set extracted [docs extract $destination]
check {extract publishes a complete standalone reference} [expr {
    [file isfile [file join $destination identity.dict]] &&
    [file isfile [file join $destination reference.db]] &&
    [file isfile [file join $destination manifest.sha256]] &&
    [dict get $extracted corpus_sha256] eq [dict get $status corpus_sha256]}]
check {extract never replaces an existing destination} [expr {
    [errorcode [list docs extract $destination]] eq {MACHTELD DOCS exists}}]

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
    proc ::machteld::PayloadRoot {} [list return //zipfs:/$mountName]
    catch {::machteld::ReferenceDb close}
    set ::machteld::DOCS_IDENTITY {}
    set corruptCode [errorcode {docs status}]
    set corruptHelpCode [errorcode {help dict}]
    # This existing zipfs directory has no reference/ child: it models a
    # wrapped payload whose runtime is present but whose corpus was omitted.
    proc ::machteld::PayloadRoot {} [list return //zipfs:/$mountName/reference/licenses]
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
check {help discovery advertises agent query primitives} [expr {
    [string match {*docs get*docs search*docs schema*} [help]]}]

file delete -force $work
if {$fails} { puts stderr "$fails reference test(s) failed"; exit 1 }
puts "reference tests passed"
