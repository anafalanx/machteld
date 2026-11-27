package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::decodeTest {variable count 0; variable probes {}; variable legacy {}}
proc ::decodeTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::decodeTest::traceEncoding {command op} {
    variable probes
    if {[lindex $command 1] in {names dirs system} || "q32-missing-test" in $command} {
        lappend probes $command
    }
}
proc ::decodeTest::call {app fn bytes name} {
    $app eval [list ::decodeApp::reader::$fn $bytes $name]
}
proc ::decodeTest::success {result expected label} {
    lassign $result tag actual
    equal $tag ok "$label succeeds"
    equal [binary encode hex [encoding convertto utf-8 $actual]] [binary encode hex [encoding convertto utf-8 $expected]] \
        "$label preserves the expected Unicode text"
}
proc ::decodeTest::problem {result code offset label} {
    lassign $result tag problem
    equal [list $tag [dict get $problem code]] [list err $code] "$label is a typed decoding failure"
    equal [expr {[dict get $problem message] ne {}}] 1 "$label supplies a message"
    if {$offset eq {}} {
        equal [dict exists $problem byteOffset] 0 "$label claims no position in the byte input"
    } else {
        equal [dict get $problem byteOffset] $offset "$label uses a zero-based byte offset"
    }
    return [dict get $problem origin]
}
proc ::decodeTest::site {model fn} {
    set expression [dict get {strict decode_text preview preview_text} $fn]
    set line 0
    foreach text [split $model \n] {
        incr line
        if {[string trim $text] eq [format {$out ::= %s($source, $codec)?} $expression]} {
            return [list reader $line [expr {[string first ? $text] + 1}]]
        }
    }
    error "missing $fn fixture location"
}
proc ::decodeTest::direct {sources} {
    variable probes
    variable legacy
    set model [dict get $sources reader]
    trace add execution ::encoding enter ::decodeTest::traceEncoding
    try {
        equal [::appcompiler::check $sources] {} "source type checking accepts a literal encoding unavailable on the host"
        set compiled [::appcompiler::compile $sources ::decodeApp]
    } finally {trace remove execution ::encoding enter ::decodeTest::traceEncoding}
    equal $probes {} "checking and compilation do not consult the encoding registry or try the requested codec"
    set app [interp create]
    try {
        $app eval [dict get $compiled script]
        equal [$app eval {package provide application-compiler}] {} "emitted decoders run in a compiler-free interpreter"
        foreach {name bytes expected} [list utf-8 {} {} utf-16le {} {} utf-8 4100e99baaf09f9a80 "A\u0000雪\U0001F680" \
                utf-16le 410000003dd880de "A\u0000\U0001F680" utf-16be 00410000d83dde80 "A\u0000\U0001F680"] {
            foreach fn {strict preview} {
                success [call $app $fn [binary decode hex $bytes] $name] $expected "$fn $name $bytes"
            }
        }
        success [call $app explicit [binary decode hex 41e99baa] utf-8] "A雪" "explicit nominal bytes and encoding extraction"
        foreach {name hex code offset preview} [list \
                utf-8 41e99baaf09f9a80ff5a UTF8 8 "A雪\U0001F680\uFFFDZ" \
                utf-16le 4100ea9610 DECODE 4 "A雪\uFFFD" \
                utf-16le 41003dd85a00 DECODE 2 "A\uFFFDZ" \
                utf-16le 410000d8ff DECODE 2 "A\uFFFD\uFFFD" \
                utf-16be 0041dc00005a DECODE 2 "A\uFFFDZ"] {
            set raw [binary decode hex $hex]
            set origin [problem [call $app strict $raw $name] $code $offset "strict $name $hex"]
            equal [list [dict get $origin module] [dict get $origin line] [dict get $origin column]] [site $model strict] \
                "strict $name failure locates the original propagation operator"
            success [call $app preview $raw $name] $preview "preview $name $hex"
            lassign [call $app keep $raw $name] tag saved
            equal [list $tag [binary encode hex $saved] [binary encode hex $raw]] [list ok $hex $hex] \
                "the source bytes survive preview and strict failure unchanged"
        }
        set wireName [::machteld::json unwrap [::machteld::json decode -typed {"utf-8\u0000tail"}]]
        foreach {label name} [list empty {} unavailable q32-missing-test Tcl-NUL "utf-8\u0000tail" JSON-NUL $wireName] {
            foreach fn {strict preview} {
                set origin [problem [call $app $fn {} $name] ENCODING {} "$fn with $label encoding and empty input"]
                equal [list [dict get $origin module] [dict get $origin line] [dict get $origin column]] [site $model $fn] \
                    "unavailable encoding points to the requesting operation"
            }
        }
        foreach fn {strict preview} {
            foreach hex {41 41eda080ed9fbf} {
                problem [call $app $fn [binary decode hex $hex] cesu-8] ENCODING {} \
                    "$fn refuses the unreliable CESU-8 decoder for $hex"
            }
        }
        set legacy [expr {"cp1252" in [$app eval {encoding names}]}]
        if {$legacy} {
            set raw [binary decode hex 80e9]
            foreach fn {strict preview} {
                success [call $app $fn $raw cp1252] "\u20AC\u00E9" "$fn Windows-1252"
            }
        }
    } finally {interp delete $app}
}
proc ::decodeTest::standalone {sources} {
    set model [dict get $sources reader]
    set script [dict get [::appcompiler::application $sources reader] script]
    set tmp [file tempdir]
    set path [file join $tmp main.tcl]
    try {
        set ch [open $path w]
        try {chan configure $ch -encoding utf-8 -translation lf; puts -nonewline $ch $script} finally {close $ch}
        set raw [binary decode hex 41e99baaf09f9a80ff5a]
        set exe [info nameofexecutable]
        equal [glob -directory $tmp -tails *] main.tcl "standalone directory contains only generated Tcl"
        set run [::machteld::run -dir $tmp -timeout 10s -stdin $raw -- $exe $path preview utf-8]
        equal [list [dict get $run exit] [binary encode hex [dict get $run out]] [dict get $run err]] \
            {0 41e99baaf09f9a80efbfbd5a {}} "standalone preview writes the exact replacement bytes"
        set run [::machteld::run -dir $tmp -timeout 10s -stdin $raw -- $exe $path strict utf-8]
        set where [join [site $model strict] :]
        equal [list [dict get $run exit] [dict get $run out]] {1 {}} "standalone strict failure emits no partial text"
        equal [string match "$where: *byte offset 8*" [dict get $run err]] 1 "standalone failure reports the source site and byte offset"
        set run [::machteld::run -dir $tmp -timeout 10s -stdin $raw -- $exe $path preview q32-missing-test]
        set message [dict get $run err]
        set where [join [site $model preview] :]
        equal [list [dict get $run exit] [dict get $run out] [string match "$where: *" $message] \
            [string first {byte offset} $message]] {1 {} 1 -1} "standalone unavailable encoding reports a source site without a byte offset"
    } finally {file delete -- $path; file delete -- $tmp}
}
proc ::decodeTest::diagnostics {} {
    foreach {code body} {
        ARGUMENT_TYPE {fn .x($p: .packet) -> result<text,problem> { return decode_text($p, 'utf-8') }}
        ARGUMENT_TYPE {fn .x($raw: bytes, $name: .name) -> result<text,problem> { return preview_text($raw, $name) }}
        ARGUMENT_TYPE {fn .x($raw: text) -> result<text,problem> { return decode_text($raw, 'utf-8') }}
        CALL_ARITY {fn .x($raw: bytes) -> result<text,problem> { return decode_text($raw) }}
        DISCARDED_RESULT {fn .x($raw: bytes) -> unit { preview_text($raw, 'utf-8')
    return unit }}
    } {
        set model "distinct .packet = bytes\ndistinct .name = text\n$body"
        set ds [::appcompiler::check [dict create bad $model]]
        equal [lmap d $ds {dict get $d code}] [list $code] "decode builtin diagnostic for [lindex [split $body \n] 0]"
    }
}

namespace eval ::decodeTest {
    set model {alias .octets = bytes
alias .encoding = text
alias .decoded = result<text,problem>
distinct .packet = bytes
distinct .name = text
export fn .strict($source: .octets, $codec: .encoding) -> .decoded {
    $out ::= decode_text($source, $codec)?
    return ok($out)
}
export fn .preview($source: .octets, $codec: .encoding) -> .decoded {
    $out ::= preview_text($source, $codec)?
    return ok($out)
}
export fn .keep($source: bytes, $codec: text) -> result<bytes,problem> {
    $view ::= preview_text($source, $codec)?
    return ok($source)
}
export fn .explicit($source: .packet, $codec: .name) -> .decoded {
    return decode_text(underlying($source), underlying($codec))
}
fn .unused($raw: bytes) -> .decoded { return decode_text($raw, 'q32-missing-test') }
fn .main($args: list<text>) -> result<unit,problem> {
    $raw ::= read_stdin_bytes()?
    $value ::= match $args {
        ['strict', $codec] => .strict($raw, $codec)
        ['preview', $codec] => .preview($raw, $codec)
        _ => err(problem('expected a decoding mode and encoding'))
    }
    return write_stdout_utf8($value?)
}}
    set sources [dict create reader $model]
    direct $sources
    standalone $sources
    diagnostics
    set coverage [expr {$legacy ? "cp1252 tested" : "cp1252 unavailable"}]
    puts "application compiler decoding: $count assertions passed ($coverage)"
}
