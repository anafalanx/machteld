package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::textTest {variable count 0}
proc ::textTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::textTest::hex {text} {binary encode hex [encoding convertto utf-8 $text]}
proc ::textTest::cases {} {
    set values {}
    lappend values [list empty {""} {}]
    set dollars {$name ${$n + 1} ${another} $::known [incr ::probe] ; {*}$items}
    lappend values [list dollars [format {"%s"} $dollars] $dollars]
    lappend values [list controls {"\"\\\n\r\t\0\b\f"} [format "%c%c%c%c%c%c%c%c" 34 92 10 13 9 0 8 12]]
    lappend values [list scalars {"\u{0}\u{000041}\u{1a}\u{D7FF}\u{e000}\u{1F680}\u{10ffff}"} \
        [format "%c%c%c%c%c%c%c" 0 65 26 0xD7FF 0xE000 0x1F680 0x10FFFF]]
    lappend values [list slash_n {"\\n and \\u{41}"} {\n and \u{41}}]
    lappend values [list quotes {"doesn't expand \"$x\" or [incr ::probe]"} {doesn't expand "$x" or [incr ::probe]}]
    set raw {literal \" \n \0 \u{41} ${$x + 1} [incr ::probe] 雪}
    lappend values [list raw [format {'%s'} $raw] $raw]
    set physical "雪\r\n\U0001F680\nend\rline"
    lappend values [list multi_double [format {"%s"} $physical] $physical]
    lappend values [list multi_single [format {'%s'} $physical] $physical]
    return $values
}

proc ::textTest::execution {} {
    set functions {}
    set values [cases]
    foreach item $values {
        lassign $item name literal expected
        lappend functions [format {export fn .%s() -> text { return %s }} $name $literal]
        lappend functions [format {export fn .matches_%s($xs: list<text>) -> bool {
    return match $xs { [%s] => true
        _ => false }
}} $name $literal]
    }
    lappend functions {fn .main($args: list<text>) -> result<unit,problem> { return write_stdout_utf8(.scalars()) }}
    set sources [dict create words [join $functions \n]]
    equal [::appcompiler::check $sources] {} "text literals check as expressions and list patterns"
    set built [::appcompiler::compile $sources ::textApp]
    set app [interp create]
    try {
        $app eval {set ::probe 0; set ::known would_expand}
        $app eval [dict get $built script]
        foreach item $values {
            lassign $item name literal expected
            equal [hex [$app eval [list ::textApp::words::$name]]] [hex $expected] "$name retains the exact Unicode value"
            equal [$app eval [list ::textApp::words::matches_$name [list $expected]]] 1 "$name pattern matches the same value"
            equal [$app eval [list ::textApp::words::matches_$name [list "$expected!"]]] 0 "$name pattern requires the whole value"
        }
        equal [$app eval {set ::probe}] 0 "Tcl commands embedded in expressions and patterns remain inert"
    } finally {interp delete $app}

    set artifact [::appcompiler::application $sources words]
    set out [file tempfile path]
    try {
        try {
            chan configure $out -encoding utf-8 -translation lf
            puts -nonewline $out [dict get $artifact script]
        } finally {close $out}
        set run [::machteld::run -timeout 10s -- [info nameofexecutable] $path]
        set expected [lindex [lsearch -inline -index 0 -exact $values scalars] 2]
        equal [list [dict get $run exit] [binary encode hex [dict get $run out]] [dict get $run err]] \
            [list 0 [hex $expected] {}] "standalone script emits exact UTF-8 through NUL, Ctrl-Z and supplementary scalars"
    } finally {file delete -- $path}
}

proc ::textTest::at {source code line first last label} {
    set errors [::appcompiler::check [dict create words $source]]
    equal [lmap e $errors {dict get $e code}] [list $code] "$label diagnostic"
    set node [dict get [lindex $errors 0] node]
    equal [list [dict get $node module] [dict get $node line] [dict get $node column] \
        [dict get $node endLine] [dict get $node endColumn]] [list words $line $first $line $last] "$label source span"
}
proc ::textTest::locations {} {
    set open [format "fn .bad() -> text %c\n    return " 123]
    set quote [format %c 34]
    set slash [format %c 92]
    set prefix "$open${quote}first\r\n\U0001F680 x"
    foreach {label tail} [list unknown q escaped_dollar {$} no_braces u0041 empty_hex {u{}} \
            non_hex {u{1g}} seven_digits {u{0000041}} above_max {u{110000}} \
            high_surrogate {u{d800}} low_surrogate {u{DFFF}} unclosed_unicode [format {u%c12} 123]] {
        at "$prefix$slash$tail$quote" E_PARSE_ESCAPE 3 4 5 $label
    }
    at "$prefix$slash" E_PARSE_ESCAPE 3 4 5 "backslash at end of source"
    at "$open${quote}raw text with no closing quote" E_PARSE_STRING 2 12 13 "unterminated double quote"

    # The column after an escape uses the number of characters in the source.
    # Physical CRLF starts one new line. An escaped newline does not.
    set lead {fn .take($value: text, $n: int) -> text { return $value }}
    set head [format {fn .bad() -> text %c return .take(} 123]
    set tail [format {, $missing) %c} 125]
    set spelled {"雪\n\u{1F680}\""}
    set col [expr {[string length $head] + [string length $spelled] + 3}]
    at "$lead\n$head$spelled$tail" UNKNOWN_BINDING 2 $col [expr {$col + 8}] "token following adjacent escapes"
    set finalLine [format {%send\n\u{1f680}"} \U0001F680]
    set col [expr {[string length $finalLine] + 3}]
    at "$lead\r\n$head${quote}first\r\n$finalLine$tail" UNKNOWN_BINDING 3 $col [expr {$col + 8}] \
        "token after mixed physical and escaped newlines"
}

proc ::textTest::sourceScalars {} {
    # Construct the code points in Tcl so no file decoder can replace them.
    set rocket [format %c 0x1F680]
    set high [format %c 0xD800]
    set low [format %c 0xDFFF]
    set template "export fn .value() -> text %c\r\n    return '%s'\r\n%c"
    at [format $template 123 "$rocket$high$rocket" 125] E_SOURCE_UNICODE 2 14 15 \
        "isolated high surrogate in raw text between supplementary characters"
    at "fn .ok() -> int { return 1 }\r\n# ${rocket}x$low$rocket" E_SOURCE_UNICODE 2 5 6 \
        "isolated low surrogate inside a comment after CRLF"

    set neighbors [format "%c%c%c%c" 0xD7FF 0x10000 0x10FFFF 0xE000]
    set source "[format $template 123 $neighbors 125]\r\n# $neighbors"
    equal [::appcompiler::check [dict create words $source]] {} \
        "valid raw source scalars surrounding the surrogate range and supplementary planes"
}

::textTest::execution
::textTest::locations
::textTest::sourceScalars
puts "application compiler text: $::textTest::count assertions passed"
