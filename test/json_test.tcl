# json_test.tcl -- ::machteld::json against nst/JSONTestSuite plus a mapping suite.
#   machteld.exe test/json_test.tcl
#
# The suite and yyjson reader are vendored independently: the corpus defines
# conformance cases while the pinned reader supplies the parsing core. 318 cases
# live in test/jsontestsuite, named by the suite's own convention:
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
# `lseq` builds Tcl 9's other list representation; it is a list in every sense.
check "an lseq value is an array"    [expr {[json encode [lseq 3]] eq {[0,1,2]}}]
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
foreach width {0 1 127 8192} {
    set run [string repeat {列車/source} $width]
    set key "\"$run\u0000"
    set value "\n$run\\\u001b$run\t"
    set expected [format {{"\"%s\u0000":"\n%s\\\u001b%s\t"}} $run $run $run]
    check "plain transport quotes escaped keys and values around $width runs" [expr {
        [json encode -plain -dict -- [dict create $key $value]] eq $expected}]
}

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

# ---- typed mode (plan-machteld-015 J2-J5) -----------------------------------

# J2: the six distinctions, exact on the wire; nested empties; spelling.
check "typed: the six distinctions hold on the wire" [expr {
    [json encode [json value array [list \
        [json value null] [json value boolean false] [json value boolean true] \
        [json value number 0] [json value string 0] [json value string {}]]]] \
    eq {[null,false,true,0,"0",""]}}]
check "typed: nested empty object and array stay distinct" [expr {
    [json encode [json value object [dict create \
        a [json value object {}] b [json value array {}]]]] \
    eq {{"a":{},"b":[]}}}]
check "typed: number spelling survives verbatim" [expr {
    [json encode [json value array [list \
        [json value number -0] [json value number 1e10] \
        [json value number 1234567890123456789012345678901234567890]]]] \
    eq {[-0,1e10,1234567890123456789012345678901234567890]}}]
check "typed: a numeric-looking string stays quoted" [expr {
    [json encode [json value string 12345]] eq {"12345"}}]

# J5: the CDP wire, the handoff's acceptance list verbatim.
check "typed: CDP request wire text is exact" [expr {
    [json encode [json value object [dict create \
        id [json value number 7] \
        sessionId [json value string 12345] \
        params [json value object [dict create \
            flatten [json value boolean true] \
            returnByValue [json value boolean true] \
            userGesture [json value boolean true] \
            awaitPromise [json value boolean false]]]]]] \
    eq {{"id":7,"sessionId":"12345","params":{"flatten":true,"returnByValue":true,"userGesture":true,"awaitPromise":false}}}}]

# J3, the honest form: the number gate; the constructor gate on plain and
# shimmered leaves (indistinguishable by design - that is the law's edge);
# the container guarantee; the named unguarded routes as executable warnings.
foreach bad {Inf 01234 1_000 .5} {
    check "typed: number gate refuses $bad" [expr {
        [catch {json value number $bad} m opts] &&
        [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
}
check "typed: number gate refuses an injection string" [expr {
    [catch {json value number "1\},\"x\":\{"} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
check "typed: a plain scalar leaf refuses at construction" [expr {
    [catch {json value object [dict create a 1]} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
set b [json value boolean true]
string length $b   ;# a string op on the HANDLE strips its intrep - route a
check "typed: a shimmered handle refuses at the next construction" [expr {
    [catch {json value object [dict create x $b]} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
check "typed: an unshimmered handle copies into a container exactly" [expr {
    [json encode [json value object [dict create \
        keep [json value boolean true]]]] eq {{"keep":true}}}]
check "typed: route b documented - a typed leaf in a PLAIN dict encodes while its intrep survives" [expr {
    [json encode [dict create wrap [json value boolean true]]] eq {{"wrap":true}}}]

# J4: strict decode.
foreach width {0 7 8 9 15 16 17 63 64 65} {
    set prefix [string repeat A $width]
    foreach {suffix escaped} [list Z Z \u0000 {\u0000} é é 🚆 🚆] {
        set key $prefix$suffix
        set wire [format {{"%s":true}} $prefix$escaped]
        set length [string length [encoding convertto utf-8 $wire]]
        set read [json decode -typed -maxbytes $length $wire]
        set built [json value object [dict create $key [json value boolean true]]]
        check "typed: text and key at byte $width in [list $escaped]" [expr {
            [json encode -- $built] eq $wire && [json unwrap [json get $read $key]] == 1 &&
            [catch {json decode -typed -maxbytes [expr {$length-1}] $wire} m opts] &&
            [dict get $opts -errorcode] eq {MACHTELD JSON limit}}]
    }
}
check "typed: duplicate keys refuse by name" [expr {
    [catch {json decode -typed {{"a":1,"a":2}}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON strict}}]
check "typed: nested duplicate keys refuse too" [expr {
    [catch {json decode -typed {{"x":{"id":1,"id":2}}}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON strict}}]
check "typed: an unpaired surrogate escape is a parse error" [expr {
    [catch {json decode -typed "\"\ud800\""} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON parse}}]
check "typed: -maxbytes refuses over its limit" [expr {
    [catch {json decode -typed -maxbytes 4 {{"a":1}}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON limit}}]
check "typed: -maxbytes without -typed refuses even at the default" [expr {
    [catch {json decode -maxbytes 16777216 {null}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON usage}}]
check "typed: -maxbytes may raise the default below the hard cap" [expr {
    [json type [json decode -typed -maxbytes 16777217 {null}]] eq "null"}]
check "typed: -maxbytes above the hard cap refuses" [expr {
    [catch {json decode -typed -maxbytes 999999999 {1}} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON limit}}]
check "typed: depth cap holds in typed decode" [expr {
    [catch {json decode -typed "[string repeat {[} 600][string repeat {]} 600]"} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON depth}}]
# Strict duplicate detection stays near-linear: a large object must not turn
# `decode -typed` into quadratic work, and a duplicate buried in it still
# refuses by name.
set members {}
for {set i 0} {$i < 200000} {incr i} { lappend members "\"k$i\":$i" }
check "typed: a 200k-member object decodes strictly" [expr {
    [json type [json decode -typed "\{[join $members ,]\}"]] eq "object"}]
check "typed: a duplicate deep in a large object refuses" [expr {
    [catch {json decode -typed "\{[join $members ,],\"k77777\":0\}"} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON strict}}]
unset members

# Inspecting typed values and walking their children.
set TYPEDDOC [json decode -typed {{"id":7,"result":{"ok":true,"n":42},"s":"S1"}}]
foreach handle [list [json get $TYPEDDOC result] \
        [json value object [dict create ok [json value boolean true] n [json value number 42]]]] {
    set first [json encode -- $handle]
    set second [json encode -dict -- $handle]
    check "typed root exports plain text and retains its typed children" [expr {
        $first eq {{"ok":true,"n":42}} && $second eq $first &&
        [catch {json type $first}] && [catch {json type $second}] &&
        [json type $handle] eq "object" && [json type [json get $handle n]] eq "number"}]
}
check "typed: type reads the tag" [expr {
    [json type $TYPEDDOC] eq "object" &&
    [json type [json get $TYPEDDOC result ok]] eq "boolean" &&
    [json type [json get $TYPEDDOC id]] eq "number"}]
check "typed: unwrap exits to plain exactly" [expr {
    [json unwrap [json get $TYPEDDOC id]] == 7 &&
    [json unwrap [json get $TYPEDDOC result]] eq {ok 1 n 42}}]
check "typed: exists answers, get refuses by name" [expr {
    [json exists $TYPEDDOC result n] == 1 &&
    [json exists $TYPEDDOC nope] == 0 &&
    [catch {json get $TYPEDDOC nope} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON absent}}]
check "typed: exists requires at least one path step" [catch {json exists $TYPEDDOC}]

# Return the children out of the parent's scope, for both document backends.
proc keptObjectChildren {built} {
    set key "a\u0000b"
    if {$built} {
        set array [json value array [list [json value boolean true] [json value number 1.00e+7] \
            [json value null] [json value object [dict create c [json value number 8]]]]]
        set parent [json value object [dict create a [json value string primary] $key $array]]
    } else {
        set parent [json decode -typed {{"a":"primary","a\u0000b":[true,1.00e+7,null,{"c":8}]}}]
    }
    return [json children $parent]
}
foreach backend {parsed built} {
    set children [keptObjectChildren [expr {$backend eq "built"}]]
    set key "a\u0000b"
    check "typed: $backend children preserve key spelling and member order" [expr {
        [dict keys $children] eq [list a $key] && [json unwrap [dict get $children a]] eq "primary"}]
    set leaves [json children [dict get $children $key]]
    unset children
    check "typed: $backend children retain identity, numeric spelling and nested documents" [expr {
        [lmap item $leaves {json type $item}] eq {boolean number null object} &&
        [json unwrap [lindex $leaves 1]] eq "1.00e+7" &&
        [json unwrap [dict get [json children [lindex $leaves 3]] c]] eq "8"}]
}
# Keep constructed scalars and nested child handles independently across
# both scalar allocation paths. The string sizes below count external UTF-8.
foreach size {126 127 128 129 4097} {
    set number "-[string repeat 9 [expr {$size-1}]]"
    set text "[string repeat a [expr {$size-7}]]é\u0000🌍"
    set leaf [json value string $text]
    set numberNode [json value number $number]
    set paired [json value object [dict create s $leaf n $numberNode]]
    set packed [json value array [list $paired $leaf]]
    set child [json get $packed 0]
    set alias $leaf
    unset numberNode paired packed leaf
    set nestedText [json get $child s]
    set nestedNumber [json get $child n]
    unset child
    check "typed: independent scalar and nested children at $size bytes" [expr {
        [json type $alias] eq "string" && [json unwrap $alias] eq $text &&
        [json unwrap $nestedText] eq $text && [json type $nestedNumber] eq "number" &&
        [json encode -- $nestedNumber] eq $number}]
    check "typed: malformed $size-byte numeric spelling is rejected" [expr {
        [catch {json value number "[string repeat 8 [expr {$size-1}]]x"} m opts] &&
        [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
}
foreach kind {array object} {
    check "typed: empty $kind has no children" [expr {[json children [json value $kind {}]] eq {}}]
}
foreach value [list [json value null] [json value number 1] [json value string ""] "plain"] {
    check "typed: children rejects a scalar or plain value" [expr {
        [catch {json children $value} msg opts] && [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
}
check "typed: children takes exactly one argument" [expr {
    [catch {json children}] && [catch {json children $TYPEDDOC id}]}]

if {[llength [info commands ::machteld::x::compareEvidence]]} {
    foreach {left right expected} {
        {{"a\u0000":[1.00,true,"𐐷"]}} {{"a\u0000":[1.00,true,"\ud801\udc37"]}} 1
        {["a\u0000b",null]} {["a\u0000c",null]} 0
        {{"x":1,"y":2}} {{"y":2,"x":1}} -1
        {[1.00e200]} {[10e199]} -1
    } {
        set a [json decode -typed $left]
        set b [json decode -typed $right]
        check "evidence proof: $left compared with $right" [expr {[::machteld::x::compareEvidence $a $b] == $expected}]
    }
    set parsed [json decode -typed {[1.00]}]
    set built [json value array [list [json value number 1.00]]]
    check "evidence proof delegates constructed and untyped inputs" [expr {
        [::machteld::x::compareEvidence $built $parsed] == -1 &&
        [::machteld::x::compareEvidence $parsed plain] == -1 &&
        [json encode -- $parsed] eq {[1.00]} && [json encode -- $built] eq {[1.00]}}]
}

# J7's organ half: the wire path refuses typed values by name.
check "typed: encode -plain refuses a typed value" [expr {
    [catch {json encode -plain [json value boolean true]} m opts] &&
    [dict get $opts -errorcode] eq {MACHTELD JSON type}}]
check "typed: encode -plain still passes plain values byte-identically" [expr {
    [json encode -plain -dict {a 1 b x}] eq {{"a":1,"b":"x"}}}]
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
    # never a silent drift. The step-10 boundary audit also rejects malformed
    # raw UTF-8: bytearrays now reach yyjson verbatim instead of being silently
    # reinterpreted as Tcl characters. The 2026-08-24 ruling flipped the ten
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
        i_string_UTF-8_invalid_sequence.json             reject
        i_string_UTF8_surrogate_U+D800.json              reject
        i_string_incomplete_surrogate_and_escape_valid.json reject
        i_string_incomplete_surrogate_pair.json          reject
        i_string_incomplete_surrogates_escape_valid.json reject
        i_string_invalid_lonely_surrogate.json           reject
        i_string_invalid_surrogate.json                  reject
        i_string_invalid_utf-8.json                      reject
        i_string_inverted_surrogates_U+1D11E.json        reject
        i_string_iso_latin_1.json                        reject
        i_string_lone_second_surrogate.json              reject
        i_string_lone_utf8_continuation_byte.json        reject
        i_string_not_in_unicode_range.json               reject
        i_string_overlong_sequence_2_bytes.json          reject
        i_string_overlong_sequence_6_bytes.json          reject
        i_string_overlong_sequence_6_bytes_null.json     reject
        i_string_truncated-utf-8.json                    reject
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

# Private compiler projection takes a dictionary layout and an intact typed array.
if {[llength [info commands ::machteld::x::projectRows]]} {
    set layout [dict create label text verified bool n int]
    set array [json decode -typed {[{"n":-0,"retained":{"k\u0000v":1.200e4},"label":"雪\u0000z","verified":false}]}]
    set projected [::machteld::x::projectRows $layout $array]
    set row [lindex $projected 0 0]
    check "projection preserves field order, text and exact integer" [expr {
        [dict keys $row] eq {n retained label verified} && [dict get $row label] eq "雪\u0000z" &&
        [dict get $row n] eq "0" && [dict get $row verified] eq "0"}]
    set child [dict get $row retained]
    unset row projected array
    check "projected evidence survives its document handle" [expr {
        [json type $child] eq "object" && [json encode -- $child] eq {{"k\u0000v":1.200e4}}}]
    foreach exact [list 1000000000000000000 9223372036854775808 -9223372036854775809 [string repeat 9 200]] {
        set document [json decode -typed [format {[{"label":"coil","verified":true,"n":%s}]} $exact]]
        set projected [::machteld::x::projectRows $layout $document]
        set number [dict get [lindex $projected 0 0] n]
        check "projected integer has the portable reader's fresh numeric representation" \
            [string match {*no string representation} [tcl::unsupported::representation $number]]
        check "projected arbitrary-precision integer is exact" [expr {
            [llength $projected] == 1 && [dict get [lindex $projected 0 0] n] eq $exact}]
    }
    set large {}
    for {set i 0} {$i<17} {incr i} {dict set large k$i int}
    set array [json decode -typed {[{"label":"x","verified":true,"n":2},{"label":"y","n":1e3,"verified":true}]}]
    lassign [::machteld::x::projectRows $layout $array] failed row
    check "projection identifies the first failed row" [expr {$failed == 1 && [json type $row] eq "object"}]
    # Direct callers may alias the source, use opaque layout entries or supply a
    # long identifier. The ordinary generated reader handles declined layouts.
    set longName [string repeat x 256]
    foreach descriptor [list $large $child $array [dict create $longName text] [dict create title $child]] {
        check "invalid row or layout declines without mutating input" [expr {
            [::machteld::x::projectRows $descriptor $array] eq {} && [json type $array] eq "array" && [json type $child] eq "object"}]
    }
}

if {[llength [info commands ::machteld::x::projectScalars]]} {
    set read ::machteld::x::projectScalars
    foreach {type wire expected} {
        int {[-0,1000000000000000000,-9223372036854775809]} {0 1000000000000000000 -9223372036854775809}
        bool {[true,false,true]} {1 0 1}
        text {["","雪\u0000\ud83d\udd2c"]} {{} "雪\x00🔬"}
    } {
        set array [json decode -typed $wire]
        set projected [$read $type $array]
        unset array
        check "projected $type list owns all its values" [expr {
            [llength $projected] == 1 && [lindex $projected 0] eq [list {*}$expected]}]
    }
    foreach {type wire} {int {[1,1e2]} int {[2,1.0]} bool {[true,1]} text {["x",null]} int {[]} int {{}}} {
        set input [json decode -typed $wire]
        check "unsupported $type list uses the original reader" [expr {[$read $type $input] eq {}}]
    }
    set array [json decode -typed {[1,2]}]
    check "typed array also supplied as descriptor retains its type" [expr {
        [$read $array $array] eq {} && [json type $array] eq "array"}]
    check "constructed arrays use the portable reader" [expr {
        [$read int [json value array [list [json value number 1]]]] eq {}}]
}

puts "\n[expr {$fails == 0 ? {ALL PASS} : {FAILURES}}]: $fails failure(s)"
exit $fails
