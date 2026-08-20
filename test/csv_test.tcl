# Focused csv contract tests. The decode contract is a port of Text::CSV_XS
# (binary=1, defaults) and every fixture below was differential-verified
# against Text::CSV_XS 1.53 during development (2026-08-20): same rows out,
# same inputs refused, across these cases and 200 seeded round-trip fuzz
# cases. Encode claims round-trip equivalence, not byte-identity with the
# oracle; the round-trip loop and the seeded fuzz below hold that claim.

package require machteld

set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} message options] == 0} { return {} }
    return [dict get $options -errorcode]
}

# ---- decode: the ordinary shapes ---------------------------------------------
check "plain fields" [expr {[csv decode "a,b,c\n"] eq {{a b c}}}]
check "crlf records" [expr {[csv decode "a,b\r\nc,d\r\n"] eq {{a b} {c d}}}]
check "quoted separator" [expr {[csv decode "\"a,b\",c\n"] eq {{a,b c}}}]
check "doubled quotes" [expr {[csv decode "\"say \"\"hi\"\"\",x\n"] eq {{{say "hi"} x}}}]
check "embedded lf" [expr {[csv decode "\"line1\nline2\",x\n"] eq [list [list "line1\nline2" x]]}]
check "embedded crlf" [expr {[csv decode "\"l1\r\nl2\",x\n"] eq [list [list "l1\r\nl2" x]]}]
check "empty fields" [expr {[csv decode "a,,c\n,,\n"] eq {{a {} c} {{} {} {}}}}]
check "alternate separator" [expr {[csv decode "a;b\n" -sep {;}] eq {{a b}}}]

# ---- decode: semantics that came from the oracle, not from RFC reading -------
check "bare CR is a record end" [expr {[csv decode "a\rb,c\n"] eq {a {b c}}}]
check "bare CR between records" [expr {[csv decode "a,b\rc,d\n"] eq {{a b} {c d}}}]
check "empty line is one empty field" [expr {[csv decode "a,b\n\nc,d\n"] eq {{a b} {{}} {c d}}}]
check "final record may lack a terminator" [expr {[csv decode "a,b"] eq {{a b}}}]
check "lone newline is one empty-field record" [expr {[csv decode "\n"] eq {{{}}}}]
check "empty input is no records" [expr {[csv decode ""] eq {}}]
check "quoted field closed by end of input" [expr {[csv decode "\"ab\""] eq {ab}}]

# ---- decode: refusals, on the machteld error contract ------------------------
check "quote in unquoted field is refused" [expr {
    [errcode_of {csv decode "a\"b,c\n"}] eq {MACHTELD CSV parse}}]
check "text after closing quote is refused" [expr {
    [errcode_of {csv decode "\"ab\"x,c\n"}] eq {MACHTELD CSV parse}}]
check "space before quote makes it unquoted, then refused" [expr {
    [errcode_of {csv decode " \"a\" ,b\n"}] eq {MACHTELD CSV parse}}]
check "unterminated quoted field is refused" [expr {
    [errcode_of {csv decode "\"ab\ncd"}] eq {MACHTELD CSV parse}}]
check "parse error names record and character" [expr {
    [catch {csv decode "ok,line\na\"b\n"} msg] &&
    [string match "*record 2*character*" $msg]}]
check "multi-character separator is refused" [expr {
    [errcode_of {csv decode "a,b\n" -sep ab}] eq {MACHTELD CSV badvalue}}]
check "quote as separator is refused" [expr {
    [errcode_of {csv decode "a,b\n" -sep "\""}] eq {MACHTELD CSV badvalue}}]
check "unknown subcommand is usage" [expr {
    [errcode_of {csv parse "a,b"}] eq {MACHTELD CSV usage}}]
check "unknown option is usage" [expr {
    [errcode_of {csv decode "a,b" -header 1}] eq {MACHTELD CSV usage}}]
check "missing argument is usage" [expr {
    [errcode_of {csv decode}] eq {MACHTELD CSV usage}}]

# ---- encode ------------------------------------------------------------------
check "encode minimal quoting" [expr {[csv encode {{a b} {c,x {say "hi"}}}] eq \
    "a,b\n\"c,x\",\"say \"\"hi\"\"\"\n"}]
check "encode quotes line endings" [expr {[csv encode [list [list "l1\nl2" b]]] eq \
    "\"l1\nl2\",b\n"}]
check "encode crlf eol" [expr {[csv encode {{a b}} -eol crlf] eq "a,b\r\n"}]
check "encode alternate separator" [expr {[csv encode {{a b,c}} -sep {;}] eq "a;b,c\n"}]
check "encode refuses a non-list" [expr {
    [errcode_of {csv encode "\{"}] eq {MACHTELD CSV badvalue}}]
check "encode refuses a bad eol" [expr {
    [errcode_of {csv encode {{a}} -eol cr+lf}] eq {MACHTELD CSV badvalue}}]

# ---- round-trip: decode(encode(rows)) is rows --------------------------------
set nasty [list \
    [list "plain" "with space" ""] \
    [list "com,ma" "qu\"ote" "new\nline" "cr\rlf"] \
    [list "café" "三" "\U0001F682"] \
    [list "" "" ""] \
    [list "  leading" "trailing  " ",\"\r\n mixed"]]
check "round-trip, default framing" [expr {[csv decode [csv encode $nasty]] eq $nasty}]
check "round-trip, crlf and semicolon" [expr {
    [csv decode [csv encode $nasty -eol crlf -sep {;}] -sep {;}] eq $nasty}]

# Seeded fuzz: deterministic rows through encode/decode, both framings.
set seed 20260820
proc rnd {} {
    set ::seed [expr {($::seed * 1103515245 + 12345) & 0x7fffffff}]
    return $::seed
}
set tokens [list a bb "" , {;} "\"" " " "\n" "\r" "\r\n" "é" "\U0001F682"]
set fuzzok 1
for {set c 0} {$c < 60} {incr c} {
    set rows {}
    set nrow [expr {1 + [rnd] % 4}]
    for {set r 0} {$r < $nrow} {incr r} {
        set row {}
        set nfield [expr {1 + [rnd] % 5}]
        for {set i 0} {$i < $nfield} {incr i} {
            set parts {}
            set ntok [expr {[rnd] % 5}]
            for {set t 0} {$t < $ntok} {incr t} {
                lappend parts [lindex $tokens [expr {[rnd] % [llength $tokens]}]]
            }
            lappend row [join $parts ""]
        }
        lappend rows $row
    }
    if {[csv decode [csv encode $rows]] ne $rows ||
        [csv decode [csv encode $rows -eol crlf -sep {;}] -sep {;}] ne $rows} {
        set fuzzok 0
        break
    }
}
check "seeded fuzz round-trips (60 cases, two framings)" [expr {$fuzzok}]

# ---- composition: csv rows feed macht directly -------------------------------
set text "alfa,3\nomega,20\nanders,9\n"
set h [macht load [csv decode $text] -schema {naam s bytes i}]
check "macht sums a csv column" [expr {
    [macht sum {$bytes} where {[string match "a*" $naam]} -data $h -intent once] == 12}]
check "macht counts csv rows" [expr {
    [macht count where {$bytes > 8} -data $h -intent once] == 2}]
macht close $h

if {$fails} { puts "FAILED $fails csv checks"; exit 1 }
puts "csv tests passed"
