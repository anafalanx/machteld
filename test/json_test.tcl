# json_test.tcl -- ::machteld::json against nst/JSONTestSuite plus a mapping suite.
#   machteld.exe test/json_test.tcl
#
# The suite is VENDORED, the parser is not: docs/ecosystem-policy.md prefers
# owning a snapshot you can read, and for a parser the thing worth borrowing is
# the conformance corpus rather than someone else's implementation. 318 cases in
# test/jsontestsuite, named by the suite's own convention:
#
#   y_*  MUST parse            n_*  MUST be rejected
#   i_*  implementation-defined -- we record what we do and why, and a CHANGE in
#        that behaviour shows up as a diff here rather than as a surprise later.

package require machteld

set HERE [file dirname [file normalize [info script]]]
set CORPUS [file join $HERE jsontestsuite]

set fails 0
proc check {name ok} {
    if {$ok} { puts "ok   $name" } else { incr ::fails ; puts "FAIL $name" }
}

# ---- the mapping, which is the part the corpus does not test ----------------

check "decode object -> dict"   [expr {[json decode {{"a":1,"b":2}}] eq {a 1 b 2}}]
check "decode array -> list"    [expr {[json decode {[1,2,3]}] eq {1 2 3}}]
check "decode nested"           [expr {[dict get [json decode {{"a":{"b":[1,2]}}}] a b] eq {1 2}}]
check "decode string"           [expr {[json decode {"hi"}] eq "hi"}]
check "decode true -> 1"        [expr {[json decode {true}] == 1}]
check "decode false -> 0"       [expr {[json decode {false}] == 0}]
check "decode null -> empty"    [expr {[json decode {null}] eq ""}]

# Numbers keep their literal text, so nothing is lost to a double on the way in.
check "big integer is exact"    [expr {[json decode {123456789012345678901234567890}]
                                       eq "123456789012345678901234567890"}]
check "and Tcl can do arithmetic on it" [expr {
    [json decode {123456789012345678901234567890}] + 1
    == 123456789012345678901234567891}]
check "float text is preserved" [expr {[json decode {1.50}] eq "1.50"}]
check "exponent text preserved" [expr {[json decode {1e2}] eq "1e2"}]

# Escapes and Unicode.
check "escapes decode"          [expr {[json decode {"a\nb\t\"c\""}] eq "a\nb\t\"c\""}]
check "\\u decodes"             [expr {[json decode {"é"}] eq "é"}]
check "surrogate pair decodes"  [expr {[json decode {"😀"}] eq "\U0001F600"}]
check "utf-8 passes through"    [expr {[json decode "\"café\""] eq "café"}]

# ---- encode, and the ambiguity the contract had to answer -------------------

check "encode dict"             [expr {[json encode -dict {a 1 b x}] eq {{"a":1,"b":"x"}}}]
check "encode list"             [expr {[json encode -list {1 2 3}] eq {[1,2,3]}}]
check "encode string"           [expr {[json encode hello] eq {"hello"}}]
check "encode number"           [expr {[json encode 42] eq {42}}]
check "encode escapes"          [expr {[json encode "a\"b\nc"] eq {"a\"b\nc"}}]
# THE SENTENCE RULE, and it is the postcode rule one level up. Guessing
# structure from the TEXT would make every string containing a space an array.
check "a sentence stays a string"  [expr {[json encode "hello world"] eq {"hello world"}}]
check "...and a real list does not" [expr {[json encode [list hello world]] eq {["hello","world"]}}]
check "a real dict is an object"    [expr {[json encode [dict create a 1]] eq {{"a":1}}}]
check "-dict and -list are exclusive" [expr {
    [catch {json encode -dict -list {}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON usage}}]
check "-- preserves an option-looking -dict scalar" [expr {
    [json encode -- -dict] eq {"-dict"}}]
check "-- preserves an option-looking -list scalar" [expr {
    [json encode -- -list] eq {"-list"}}]

# THE POSTCODE RULE. `string is integer` would call 01234 a number and emit
# 1234 -- a silent corruption. A leading zero is not a valid JSON number, so it
# stays a string and the value survives.
check "a leading zero stays a string" [expr {[json encode 01234] eq {"01234"}}]
check "...and round-trips"            [expr {[json decode [json encode 01234]] eq "01234"}]
check "a real number does not quote"  [expr {[json encode 1234] eq {1234}}]
check "hex is not a JSON number"      [expr {[json encode 0x10] eq {"0x10"}}]
check "Inf is not a JSON number"      [expr {[json encode Inf] eq {"Inf"}}]

# Round trips that must hold exactly.
foreach doc {
    {{"a":1,"b":[1,2,3],"c":"x"}}
    {[1,2,3]}
    {{"nested":{"deep":{"deeper":[true,false,null]}}}}
    {{"big":123456789012345678901234567890,"f":1.5,"e":1e10}}
} {
    # No -dict needed: decode builds real dict and list objects, so encode reads
    # the structure off the value rather than guessing it back out of the text.
    set once  [json decode $doc]
    set twice [json decode [json encode $once]]
    check "round trip stable: [string range $doc 0 30]" [expr {$once eq $twice}]
    check "and the TEXT is stable too: [string range $doc 0 20]" [expr {
        [json encode $once] eq [json encode $twice]}]
}

# The emitter's byte choices are contract behavior (plan-machteld-015: the
# reader moved to yyjson, the emitter deliberately did not - these fixtures
# pin what "byte-identical plain encode" means).
check "control characters escape as lowercase \\u00xx" [expr {
    [json encode [format %c 1]] eq {"\u0001"} &&
    [json encode [format %c 31]] eq {"\u001f"}}]
check "the seven short escapes are the short forms" [expr {
    [json encode "\"\\\b\f\n\r\t"] eq {"\"\\\b\f\n\r\t"}}]
check "solidus is not escaped" [expr {[json encode "a/b"] eq {"a/b"}}]
check "non-ASCII passes through as raw UTF-8" [expr {
    [json encode "héllo"] eq "\"héllo\""}]

# The depth law applies to VALID JSON that is too deep for the contract; an
# unclosed bracket flood is invalid JSON and fails as parse (a J1-table
# ruling, plan-machteld-015: the old hand parser tripped its depth counter
# before discovering the missing closers - implementation order, not law).
check "depth is capped, not crashed" [expr {
    [catch {json decode "[string repeat {[} 5000][string repeat {]} 5000]"} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON depth}}]
check "an unclosed bracket flood is a parse error" [expr {
    [catch {json decode [string repeat {[} 5000]} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON parse}}]
check "a parse failure is coded"     [expr {
    [catch {json decode {nope}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON parse}}]

# ---- the conformance corpus -------------------------------------------------

if {![file isdirectory $CORPUS]} {
    puts "\nSKIP conformance: no corpus at $CORPUS"
} else {
    set ny 0 ; set nn 0 ; set ni 0
    set badY {} ; set badN {} ; set idefined {}
    foreach f [lsort [glob -nocomplain -directory $CORPUS *.json]] {
        set name [file tail $f]
        set fh [open $f rb] ; set data [read $fh] ; close $fh
        # The corpus is raw bytes, including deliberately invalid UTF-8. Feed it
        # verbatim: decoding it as text first would repair the very inputs the
        # n_string_invalid_utf8_* cases exist to check.
        set ok [expr {![catch {json decode $data}]}]
        switch -glob -- $name {
            y_* { incr ny ; if {!$ok} { lappend badY $name } }
            n_* { incr nn ; if {$ok}  { lappend badN $name } }
            i_* { incr ni ; lappend idefined [list $name [expr {$ok ? "accept" : "reject"}]] }
        }
    }
    puts ""
    check "every y_ case parses ($ny cases)"     [expr {$badY eq ""}]
    check "every n_ case is rejected ($nn cases)" [expr {$badN eq ""}]
    if {$badY ne ""} { puts "     should have parsed: [join [lrange $badY 0 12] { }]" }
    if {$badN ne ""} { puts "     should have been rejected: [join [lrange $badN 0 12] { }]" }
    # i_ cases are ours to choose. Record the split so a change in behaviour is
    # visible as a diff rather than discovered by a user.
    set acc 0
    foreach p $idefined { if {[lindex $p 1] eq "accept"} { incr acc } }
    puts "note i_ (implementation-defined): $acc accepted, [expr {$ni - $acc}] rejected, of $ni"

    # The ASSERTED i_ table (plan-machteld-015 J1: a gate, not an
    # observation). Every implementation-defined case is pinned by name;
    # a behavior change here is a failing check demanding a new ruling,
    # never a silent drift. The 2026-08-24 ruling flipped the ten
    # unpaired-surrogate-escape cases from accept (as U+FFFD) to reject:
    # machteld does not manufacture replacement characters from broken
    # input. The raw-invalid-UTF-8 accepts are the corpus harness's
    # bytearray path (bytes launder to code points before the parser and
    # always have); real invalid bytes on the wire stay refused by the
    # boundary's own laws.
    set ITABLE {
        i_number_double_huge_neg_exp.json                accept
        i_number_huge_exp.json                           accept
        i_number_neg_int_huge_exp.json                   accept
        i_number_pos_double_huge_exp.json                accept
        i_number_real_neg_overflow.json                  accept
        i_number_real_pos_overflow.json                  accept
        i_number_real_underflow.json                     accept
        i_number_too_big_neg_int.json                    accept
        i_number_too_big_pos_int.json                    accept
        i_number_very_big_negative_int.json              accept
        i_object_key_lone_2nd_surrogate.json             reject
        i_string_1st_surrogate_but_2nd_missing.json      reject
        i_string_1st_valid_surrogate_2nd_invalid.json    reject
        i_string_UTF-16LE_with_BOM.json                  reject
        i_string_UTF-8_invalid_sequence.json             accept
        i_string_UTF8_surrogate_U+D800.json              accept
        i_string_incomplete_surrogate_and_escape_valid.json reject
        i_string_incomplete_surrogate_pair.json          reject
        i_string_incomplete_surrogates_escape_valid.json reject
        i_string_invalid_lonely_surrogate.json           reject
        i_string_invalid_surrogate.json                  reject
        i_string_invalid_utf-8.json                      accept
        i_string_inverted_surrogates_U+1D11E.json        reject
        i_string_iso_latin_1.json                        accept
        i_string_lone_second_surrogate.json              reject
        i_string_lone_utf8_continuation_byte.json        accept
        i_string_not_in_unicode_range.json               accept
        i_string_overlong_sequence_2_bytes.json          accept
        i_string_overlong_sequence_6_bytes.json          accept
        i_string_overlong_sequence_6_bytes_null.json     accept
        i_string_truncated-utf-8.json                    accept
        i_string_utf16BE_no_BOM.json                     reject
        i_string_utf16LE_no_BOM.json                     reject
        i_structure_500_nested_arrays.json               accept
        i_structure_UTF-8_BOM_empty_object.json          reject
    }
    set idict [dict create]
    foreach p $idefined { dict set idict [lindex $p 0] [lindex $p 1] }
    set itableBad {}
    foreach {name expected} $ITABLE {
        if {![dict exists $idict $name]} {
            lappend itableBad "$name missing from corpus"
        } elseif {[dict get $idict $name] ne $expected} {
            lappend itableBad "$name: [dict get $idict $name], table says $expected"
        }
    }
    check "the i_ table holds, case by case ([expr {[llength $ITABLE] / 2}] pinned)" \
        [expr {$itableBad eq "" && [dict size $idict] == [llength $ITABLE] / 2}]
    if {$itableBad ne ""} { puts "     [join [lrange $itableBad 0 6] {; }]" }
}

puts "\n[expr {$fails == 0 ? {ALL PASS} : {FAILURES}}]: $fails failure(s)"
exit $fails
