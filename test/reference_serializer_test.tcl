package require machteld 0.21

# test/reference_serializer_test.tcl -- the reference generator's serializers
# (tools/reference.tcl) write what they always wrote: ::ref::tclWord escapes
# every one of the 65,536 UTF-16 code units by the established rule, and Tcl
# reads each word back as the text it came from; ::ref::jsonValue keeps its
# shapes and types, and what it writes decodes to the same values; and the
# dependency cache's static tclsh, which runs the upstream converter and the
# final validator, parses a serialized list exactly. No generation is run.
#
#     machteld.exe test/reference_serializer_test.tcl --tclsh EXE
#
# The Tcl port of tools/reference_serializer_smoke.ps1 (machteld 8bcc1ec),
# which proved the C# serializers against the PowerShell rule they replaced;
# the rule below is that PowerShell rule, written out again.

set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root tools reference.tcl]

if {[llength $argv] != 2 || [lindex $argv 0] ne "--tclsh"} {
    puts stderr "usage: reference_serializer_test.tcl --tclsh EXE"
    exit 2
}
set tclsh [file normalize [lindex $argv 1]]

set checks 0
set failures 0
proc check {name condition {detail ""}} {
    incr ::checks
    if {$condition} {
        puts "ok   $name"
    } else {
        incr ::failures
        puts "FAIL $name $detail"
    }
}

# The established rule (tools/reference_serializer_smoke.ps1's Tcl-Word): the
# named escapes; then \uXXXX for the other controls below 32, DEL, and what
# .NET's Char.IsWhiteSpace calls white space; every other code unit as it is.
set named [dict create 8 {\b} 9 {\t} 10 {\n} 11 {\v} 12 {\f} 13 {\r} 32 {\ } 34 {\"} 36 {\$} \
    59 {\;} 91 {\[} 92 {\\} 93 {\]} 123 {\{} 125 {\}}]
set dotnetWhite {9 10 11 12 13 32 0x85 0xa0 0x1680 0x2000 0x2001 0x2002 0x2003 0x2004 0x2005
    0x2006 0x2007 0x2008 0x2009 0x200a 0x2028 0x2029 0x202f 0x205f 0x3000}
set white {}
foreach code $dotnetWhite { dict set white [expr {$code}] 1 }
proc established {code} {
    if {[dict exists $::named $code]} {
        return [dict get $::named $code]
    }
    if {$code < 32 || $code == 127 || [dict exists $::white $code]} {
        return [format {\u%04x} $code]
    }
    return [format %c $code]
}

set all ""
set expected ""
set unitFailures {}
for {set code 0} {$code < 65536} {incr code} {
    set char [format %c $code]
    append all $char
    set want [established $code]
    append expected $want
    set got [::ref::tclWord $char]
    if {$got ne $want} {
        lappend unitFailures [format U+%04X $code]
    } elseif {[lindex $got 0] ne $char} {
        lappend unitFailures "[format U+%04X $code] (read back)"
    }
}
check {tclWord escapes every UTF-16 code unit by the established rule, and reads back} \
    [expr {![llength $unitFailures]}] [lrange $unitFailures 0 9]
check {tclWord of all 65,536 code units at once is the rule's word} [expr {[::ref::tclWord $all] eq $expected}]
check {Tcl reads that word back as the 65,536 code units} [expr {[lindex [::ref::tclWord $all] 0] eq $all}]
check {tclWord writes the empty string as braces} [expr {[::ref::tclWord ""] eq "{}"}]

# JSON: shapes and types, as the stage state was written.
set nested [::ref::D keys [::ref::Ls {{a b} 00123}] empty [::ref::L {}] truth [::ref::B 1] zero [::ref::N 0] nil {Z {}}]
set json [::ref::jsonValue $nested]
check {jsonValue keeps the shapes and types} \
    [expr {$json eq {{"keys":["a b","00123"],"empty":[],"truth":true,"zero":0,"nil":null}}}] $json
set decoded [json decode $json]
check {what jsonValue writes decodes to the same values} \
    [expr {[dict get $decoded keys] eq {{a b} 00123} && [dict get $decoded empty] eq {} &&
        [dict get $decoded truth] == 1 && [dict get $decoded zero] == 0 && [dict get $decoded nil] eq ""}] $decoded
set text "quote \" backslash \\ controls \b\t\n\f\r\x01\x1f end"
check {jsonValue escapes strings as JSON requires, and they decode back} \
    [expr {[json decode [::ref::jsonValue [::ref::S $text]]] eq $text}]
check {jsonDeterministic ends with one newline} \
    [expr {[::ref::jsonDeterministic $nested] eq "$json\n"}]

# The cache's tclsh parses a list tclData wrote exactly, as the converter and
# the validator read the catalog.
set unicode "na\u00efve \u03a9"
set fixture [list "" "a b" "a\t b" "a\n b" "a\v b" "a\f b" "a\r b" "a\x01b" "a\x7fb" 00123 true $unicode \
    [string cat {braces { and } brackets [ and ] dollars $ semicolon ; backslash } \\]]
set work [file join [file normalize $::env(TEMP)] machteld-reference-serializer-[pid]-[binary encode hex [hash random 8]]]
file mkdir $work
try {
    set listPath [file join $work fixture.list]
    set channel [open $listPath wb]
    puts -nonewline $channel [encoding convertto utf-8 "[::ref::tclData [::ref::Ls $fixture]]\n"]
    close $channel
    set script [file join $work parse.tcl]
    set channel [open $script wb]
    puts -nonewline $channel [encoding convertto utf-8 {
set ch [open [lindex $argv 0] r]; fconfigure $ch -encoding utf-8 -translation lf
set actual [string trimright [read $ch] \n]; close $ch
set expected [list {} "a b" "a\t b" "a\n b" "a\v b" "a\f b" "a\r b" \
    "a\u0001b" "a\u007fb" {00123} {true} "na\u00efve \u03a9"]
lappend expected [join [list {braces { and } brackets [ and ] dollars $ semicolon ; backslash} \\] { }]
if {[llength $actual] != [llength $expected]} {error {shape mismatch}}
foreach a $actual e $expected {if {$a ne $e} {error "value mismatch: <$a> != <$e>"}}
puts SERIALIZER-SMOKE-OK
}]
    close $channel
    set result [run -timeout 1m -- $tclsh $script $listPath]
    set output [string trim [encoding convertfrom utf-8 [dict get $result out]]]
    check {the dependency cache's tclsh parses a serialized list exactly} \
        [expr {[dict get $result exit] == 0 && $output eq "SERIALIZER-SMOKE-OK"}] \
        "$output [encoding convertfrom utf-8 [dict get $result err]]"
} finally {
    file delete -force $work
}

if {$failures} {
    puts stderr "$failures of $checks reference serializer checks failed"
    exit 1
}
puts "ALL $checks REFERENCE SERIALIZER CHECKS PASSED"
