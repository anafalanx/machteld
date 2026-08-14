# Complete live contract for the embedded agent reference.
package require machteld 0.10.2

set fails 0
proc check {name condition {detail ""}} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name $detail" }
}
proc errorcode {script} {
    if {![catch {uplevel 1 $script} message options]} { return {} }
    return [dict get $options -errorcode]
}

set status [docs status]
check {status identifies schema and runtime} [expr {
    [dict get $status schema] == 1 && [dict get $status machteld] eq "0.10.2" &&
    [dict get $status root] eq "self" && [string length [dict get $status corpus_sha256]] == 64}]
check {status inventories exact Tcl/Tk manuals} [expr {
    [dict get $status products tcl version] eq "9.0.4" &&
    [dict get $status products tk version] eq "9.0.4" &&
    [dict get $status products tcl documents] == 250 &&
    [dict get $status products tk documents] == 178 &&
    [dict get $status products tcl manual_pages] == 249 &&
    [dict get $status products tk manual_pages] == 177}]

set schema [docs schema]
check {schema describes all operations and bounded retrieval} [expr {
    [dict get $schema schema] == 1 && [dict get $schema catalog_schema] == 1 &&
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

set source [docs get tcl/command/dict -format source -limit 100]
set html [docs get tcl/command/dict -format html -limit 100]
check {upstream source and HTML representations are retained} [expr {
    [dict get $source format] eq "source" && [string match {*.n} [dict get $source path]] &&
    [dict get $html format] eq "html" && [string match {*.html} [dict get $html path]]}]
check {authored Machteld pages refuse nonexistent upstream representation} [expr {
    [errorcode {docs get machteld/command/run -format source}] eq {MACHTELD DOCS unsupported}}]

set capi [docs get tcl/c-api/crtobjcmd -limit 80]
check {C API IDs are canonical lowercase} [expr {[dict get $capi id] eq "tcl/c-api/crtobjcmd"}]
set alias [docs get Tcl_CreateObjCommand -limit 80]
check {original C API spelling is an exact alias} [expr {[dict get $alias id] eq [dict get $capi id]}]
set normalizedAlias [docs get {  Tcl   Tcl_CreateObjCommand  } -limit 80]
check {alias lookup lowercases, trims, and collapses whitespace} [expr {
    [dict get $normalizedAlias id] eq [dict get $capi id]}]
set savedCatalog $::machteld::DOCS_CATALOG
dict set ::machteld::DOCS_CATALOG aliases __test_ambiguous__ \
    {tcl/command/dict tcl/command/list}
set ambiguousCode [errorcode {docs get __test_ambiguous__}]
set ::machteld::DOCS_CATALOG $savedCatalog
check {ambiguous aliases are explicit rather than guessed} [expr {
    $ambiguousCode eq {MACHTELD DOCS ambiguous}}]

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
check {search rejects one-character terms while get accepts exact short names} [expr {
    [errorcode {docs search a}] eq {MACHTELD DOCS badvalue} &&
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
    [dict get $verified files] > 1000}]

set work [file join $env(TEMP) machteld-reference-test-[pid]-[binary encode hex [hash random 8]]]
file mkdir $work
set destination [file join $work exported]
set extracted [docs extract $destination]
check {extract publishes a complete standalone reference} [expr {
    [file isfile [file join $destination catalog.dict]] &&
    [file isfile [file join $destination search.dict]] &&
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
    set channel [open [file join $fixtureRoot reference catalog.dict] ab]
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
    set ::machteld::DOCS_LOADED 0
    set ::machteld::DOCS_CATALOG {}
    set ::machteld::DOCS_SEARCH_LOADED 0
    set ::machteld::DOCS_SEARCH {}
    set corruptCode [errorcode {docs status}]
    set corruptHelpCode [errorcode {help dict}]
    set fixtureResult ""
} fixtureError]
if {$rootRenamed} {
    catch {rename ::machteld::PayloadRoot {}}
    catch {rename ::machteld::PayloadRootLive ::machteld::PayloadRoot}
}
set ::machteld::DOCS_LOADED 0
set ::machteld::DOCS_CATALOG {}
set ::machteld::DOCS_SEARCH_LOADED 0
set ::machteld::DOCS_SEARCH {}
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
set outputResult [::machteld::DocsHost status --json --output $output]
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
catch {::machteld::DocsHostGui status --json} guiReply guiOptions
check {GUI adapter requires output with a typed failure envelope} [expr {
    [dict get [json decode $guiReply] ok] == 0 &&
    [dict get $guiOptions -errorcode] eq {MACHTELD DOCS usage}}]

check {help delegates exact pages through the trusted reference} [expr {
    [string length [help tcl/command/dict]] > 100}]
check {help translates docs discovery failures into its own domain} [expr {
    [errorcode {help a}] eq {MACHTELD HELP notfound}}]
check {help discovery advertises agent query primitives} [expr {
    [string match {*docs get*docs search*docs schema*} [help]]}]

file delete -force $work
if {$fails} { puts stderr "$fails reference test(s) failed"; exit 1 }
puts "reference tests passed"
