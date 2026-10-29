# Bounded, deterministic hostile-input and round-trip coverage for the native
# JSON boundary. Runs with the shipped host or the instrumented headless JSON
# harness; no network, desktop interaction, or external fixture is required.
package require machteld
set fails 0
set total 0
proc check {name body} {
    incr ::total
    if {[catch {uplevel 1 [list expr $body]} ok options] || !$ok} {
        incr ::fails
        puts "FAIL $name: $ok"
    }
}
proc code {script} {
    if {![catch {uplevel 1 $script} message options]} {return {}}
    return [dict get $options -errorcode]
}

# Tcl's internal C0 80 representation is not UTF-8 on the JSON wire.
set nul "a\0b"
check {plain NUL has a JSON escape} {[json encode $nul] eq {"a\u0000b"}}
check {plain NUL round-trip} {[json decode [json encode $nul]] eq $nul}
set typed [json value string $nul]
check {typed NUL has a JSON escape} {[json encode $typed] eq {"a\u0000b"}}
check {typed NUL round-trip} {[json unwrap [json decode -typed [json encode $typed]]] eq $nul}
set object [dict create $nul [json value string "\0end"]]
set constructed [json value object $object]
set decoded [json decode -typed {{"a\u0000b":"\u0000end"}}]
foreach object [list $constructed $decoded] {
    check {NUL object key exists} {[json exists $object $nul]}
    check {NUL object key lookup} {[json unwrap [json get $object $nul]] eq "\0end"}
    check {NUL object key unwrap} {[dict get [json unwrap $object] $nul] eq "\0end"}
    check {NUL object key encode} {[json encode $object] eq {{"a\u0000b":"\u0000end"}}}
}
check {plain object key NUL} {
    [dict get [json decode [json encode [dict create $nul text]]] $nul] eq "text"
}

# Real raw bytes must reach the parser. Reinterpreting them as Tcl characters
# used to turn malformed UTF-8 into accepted (and different) strings.
foreach hex {
    228022 22bf22 22c08022 22c122 22c222 22e0808022
    22eda08022 22edbfbf22 22f080808022 22f490808022
    22f580808022 22f88880808022 22fe22 22ff22 2261006222
    efbbbf7b7d fffe7b007d00
} {
    foreach typedFlag {{} -typed} {
        set bytes [binary decode hex $hex]
        check "malformed raw UTF-8 $hex $typedFlag" {
            [code [list json decode {*}$typedFlag $bytes]] eq {MACHTELD JSON parse}
        }
    }
}
foreach hex {22c3a922 22e4b89622 22f09f988022 225c753030303022} {
    set bytes [binary decode hex $hex]
    set decoded [json decode -typed $bytes]
    check "valid raw UTF-8 $hex" {
        [json encode [json decode -typed [encoding convertto utf-8 [json encode $decoded]]]] eq [json encode $decoded]
    }
}
foreach surrogate [list "\ud800" "\udfff" "x\ud800y"] {
    check {plain surrogate refuses} {[code [list json encode $surrogate]] eq {MACHTELD JSON type}}
    check {typed surrogate refuses at construction} {[code [list json value string $surrogate]] eq {MACHTELD JSON type}}
    check {plain surrogate key refuses} {[code [list json encode [dict create $surrogate ok]]] eq {MACHTELD JSON type}}
    check {typed surrogate key refuses} {[code [list json value object [dict create $surrogate [json value null]]]] eq {MACHTELD JSON type}}
    check {surrogate JSON text refuses} {[code [list json decode "\"$surrogate\""]] eq {MACHTELD JSON parse}}
}

# Depth is a property of the full value, not only the caller's newest wrapper.
set max [json value null]
for {set n 0} {$n < 511} {incr n} {set max [json value array [list $max]]}
check {constructed depth boundary succeeds} {[string length [json encode $max]] == 1026}
check {constructed array crossing depth cap fails} {
    [code [list json value array [list $max]]] eq {MACHTELD JSON depth}
}
check {constructed object crossing depth cap fails} {
    [code [list json value object [dict create x $max]]] eq {MACHTELD JSON depth}
}
check {plain list embedding typed subtree obeys total depth} {
    [code [list json encode -list [list $max]]] eq {MACHTELD JSON depth}
}
check {plain dict embedding typed subtree obeys total depth} {
    [code [list json encode [dict create x $max]]] eq {MACHTELD JSON depth}
}
set immutable [json decode -typed [json encode $max]]
check {decoded subtree composition obeys total depth} {
    [code [list json value array [list $immutable]]] eq {MACHTELD JSON depth}
}
check {depth failure leaves input intact} {[json encode $max] eq [json encode $immutable]}

# A fixed LCG makes failures reproducible without a fuzzing dependency. These
# strings exercise all escaping paths, combining marks, supplementary planes,
# NUL, and the maximum Unicode scalar as both member names and string values.
set alphabet [list a z 0 " " "\t" "\r" "\n" "\0" "\x01" "\x1f" "\"" "\\" "\u00e9" "\u0301" "\u4e16" "\U0001f600" "\U0010ffff"]
set seed 0x5a17
for {set case 0} {$case < 128} {incr case} {
    set text s
    for {set index 0} {$index < 24} {incr index} {
        set seed [expr {(1664525 * $seed + 1013904223) & 0xffffffff}]
        append text [lindex $alphabet [expr {$seed % [llength $alphabet]}]]
    }
    check "plain generated round-trip $case" {[json decode [json encode $text]] eq $text}
    set typed [json value object [dict create $text [json value string $text]]]
    set encoded [json encode $typed]
    set round [json decode -typed [encoding convertto utf-8 $encoded]]
    check "typed generated key round-trip $case" {[json unwrap [json get $round $text]] eq $text}
    check "typed generated canonical round-trip $case" {[json encode $round] eq $encoded}
}

# Every truncated prefix of this document is invalid; every one-byte mutation
# either rejects with a structured error or survives a strict canonical cycle.
set wire [encoding convertto utf-8 {{"key\u0000":{"array":[null,true,false,1.50,-2e3,"é😀"]},"tail":[]}}]
for {set length 0} {$length < [string length $wire]} {incr length} {
    set prefix [binary format a* [string range $wire 0 $length-1]]
    check "truncated prefix $length" {[code [list json decode -typed $prefix]] eq {MACHTELD JSON parse}}
}
set mutationCount 0
binary scan $wire cu* octets
for {set offset 0} {$offset < [llength $octets]} {incr offset} {
    foreach replacement {0 34 92 128 255} {
        set mutation [binary format cu* [lreplace $octets $offset $offset $replacement]]
        if {[catch {json decode -typed $mutation} value options]} {
            check "mutation error $offset/$replacement" {
                [dict get $options -errorcode] in {{MACHTELD JSON parse} {MACHTELD JSON strict}}
            }
        } else {
            set canonical [json encode $value]
            check "mutation cycle $offset/$replacement" {
                [json encode [json decode -typed [encoding convertto utf-8 $canonical]]] eq $canonical
            }
        }
        incr mutationCount
    }
}

# Repeated error/ownership paths. Sorted duplicate detection (>16 members) and
# duplicate names containing NUL are separate from the small-object algorithm.
set members {}
for {set n 0} {$n < 40} {incr n} {lappend members "\"k$n\":$n"}
lappend members {"k39":99}
set duplicate "\{[join $members ,]\}"
for {set n 0} {$n < 100} {incr n} {
    check "plain duplicate keeps last value $n" {
        [dict get [json decode {{"a\u0000":1,"a\u0000":2}}] "a\0"] eq "2"
    }
    check "sorted duplicate reject $n" {[code [list json decode -typed $duplicate]] eq {MACHTELD JSON strict}}
    check "NUL duplicate reject $n" {[code {json decode -typed {{"a\u0000":1,"a\u0000":2}}}] eq {MACHTELD JSON strict}}
    set parent [json decode -typed {{"child":{"value":"alive"}}}]
    set child [json get $parent child]
    unset parent
    check "child owns document $n" {[json unwrap [json get $child value]] eq "alive"}
}
foreach count {0 -1 67108865 999999999999999999999999999} {
    check "bounded maxbytes rejects $count" {
        [code [list json decode -typed -maxbytes $count null]] in {{MACHTELD JSON usage} {MACHTELD JSON limit}}
    }
}
check {maxbytes measures wire bytes} {[json unwrap [json decode -typed -maxbytes 4 [binary decode hex 22c3a922]]] eq "é"}
check {maxbytes rejects one byte too few} {[code {json decode -typed -maxbytes 3 [binary decode hex 22c3a922]}] eq {MACHTELD JSON limit}}
puts "native adversarial: [expr {$total-$fails}]/$total passed; $fails failed; seed 0x5a17; $mutationCount byte mutations"
exit [expr {$fails ? 1 : 0}]
