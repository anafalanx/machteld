package require machteld 0.21

# tools/reference.tcl -- build the complete, offline reference carried by the
# runtime. Inputs are the hash-pinned source archives, not the mutable
# dependency source checkout. Every output byte is deterministic and every
# inventory decision is explicit.
#
#     machteld.exe tools/reference.tcl ?--cache DIR? ?--output DIR? ?--tclsh EXE? ?--keep-work?
#
# The Tcl port (2026-10-28) of tools/generate-reference.ps1, made to write the
# same bytes: where PowerShell 5.1 compares strings, looks up keys or matches
# patterns without regard to case, or where .NET's \s, `$` and IsWhiteSpace
# differ from Tcl's, this file says so and does what PowerShell did. The
# upstream converter and the final validator run on the static tclsh of the
# dependency cache, as before.

namespace eval ::ref {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable generator machteld-reference-v1
    # .NET's whitespace: char.IsWhiteSpace and the regex class \s.
    variable ws "\t\n\v\f\r \u0085   -     　"
    variable S "\[$ws\]"
    variable NS "\[^$ws\]"
}

# ---- basic helpers ----

proc ::ref::fail {message} {
    return -code error -errorcode {REFERENCE fail} "generate-reference: $message"
}

proc ::ref::writeUtf8Lf {path text} {
    file mkdir [file dirname $path]
    set text [string map [list \r\n \n \r \n] $text]
    set channel [open $path wb]
    puts -nonewline $channel [encoding convertto utf-8 $text]
    close $channel
}

proc ::ref::readBytes {path} {
    set channel [open $path rb]
    try {
        return [read $channel]
    } finally {
        close $channel
    }
}

proc ::ref::readUtf8Strict {path} {
    if {[catch {encoding convertfrom -profile strict utf-8 [readBytes $path]} text]} {
        fail "not valid UTF-8: [file nativename $path]"
    }
    return $text
}

proc ::ref::sha256 {path} {
    hash file sha256 $path
}

proc ::ref::assertArchive {path expected name} {
    if {![file isfile $path]} {
        fail "missing pinned $name archive: [file nativename $path]"
    }
    set actual [sha256 $path]
    if {$actual ne [string tolower $expected]} {
        fail "$name archive SHA-256 mismatch: expected $expected, got $actual"
    }
}

# Tcl counts characters where .NET counts UTF-16 units; the corpus has no
# text beyond the BMP, and a future occurrence fails instead of publishing
# divergent offsets.
proc ::ref::assertNoSurrogates {text label} {
    if {[regexp {[\U00010000-\U0010FFFF\uD800-\uDFFF]} $text]} {
        fail "$label contains non-BMP text; section offset encoding must be upgraded"
    }
}

proc ::ref::isWhiteSpace {char} {
    variable ws
    regexp "^\[$ws\]\$" $char
}

# .NET String.Trim(): .NET whitespace at both ends.
proc ::ref::netTrim {text} {
    variable S
    regsub "^${S}+" $text {} text
    regsub "${S}+\$" $text {} text
    return $text
}

proc ::ref::collapse {text} {
    variable S
    netTrim [regsub -all "${S}+" $text { }]
}

proc ::ref::normalizeSlashPath {path} {
    set value [string map {\\ /} $path]
    if {$value eq "" || [string match /* $value] || [string match */ $value] ||
            [string first : $value] >= 0 || [regexp {[\x00-\x1f\x7f]} $value] ||
            [regexp {(^|/)\.\.?(/|$)} $value] || [string first // $value] >= 0} {
        fail "unsafe logical reference path: $path"
    }
    return $value
}

proc ::ref::resolveLogicalPath {baseFile relative} {
    set parts {}
    foreach part [lrange [split [string map {\\ /} $baseFile] /] 0 end-1] {
        if {$part ne ""} {
            lappend parts $part
        }
    }
    foreach part [split [string map {\\ /} $relative] /] {
        if {$part eq "" || $part eq "."} {
            continue
        }
        if {$part eq ".."} {
            if {[llength $parts] == 0} {
                fail "relative link escapes HTML root: $baseFile -> $relative"
            }
            set parts [lrange $parts 0 end-1]
        } else {
            lappend parts $part
        }
    }
    join $parts /
}

proc ::ref::slug {text} {
    set text [string tolower [netHtmlDecode $text]]
    set out ""
    set dash 0
    foreach char [split $text ""] {
        if {[string is alnum -strict $char]} {
            append out $char
            set dash 0
        } elseif {!$dash && $out ne ""} {
            append out -
            set dash 1
        }
    }
    string trim $out -
}

# Lowercase and collapsed .NET whitespace; the validator gates the corpus
# against .NET/Tcl case and whitespace divergences.
proc ::ref::normalizeSearch {text} {
    collapse [string tolower $text]
}

proc ::ref::stripMarkdown {text} {
    regsub -all -nocase {<a id="[^"]+"></a>} $text { } text
    regsub -all {!\[([^\]]*)\]\([^)]*\)} $text {\1} text
    regsub -all {\[([^\]]+)\]\([^)]*\)} $text {\1} text
    regsub -all {[`*_#>|]} $text { } text
    collapse $text
}

proc ::ref::rewriteAuthoredLinks {text sourceKind} {
    set out ""
    set at 0
    foreach {whole label target} [regexp -all -inline -indices {\[([^\]]+)\]\(([^)]+)\)} $text] {
        lassign $whole from to
        append out [string range $text $at [expr {$from - 1}]]
        set at [expr {$to + 1}]
        set labelText [string range $text {*}$label]
        set targetText [string range $text {*}$target]
        if {[regexp {^[A-Za-z][A-Za-z0-9+.-]*:} $targetText] || [string match #* $targetText]} {
            append out [string range $text $from $to]
            continue
        }
        set hash [string first # $targetText]
        if {$hash >= 0} {
            set path [string range $targetText 0 [expr {$hash - 1}]]
            set fragment [string range $targetText $hash end]
        } else {
            set path $targetText
            set fragment ""
        }
        if {$sourceKind eq "guide"} {
            if {[regexp -nocase {^reference/machteld/(index|agent)\.md$} $path -> m]} {
                set stable machteld/$m
            } elseif {[regexp -nocase {^reference/machteld/command/([a-z0-9-]+)\.md$} $path -> m]} {
                set stable machteld/command/$m
            } elseif {[regexp -nocase {^([a-z0-9-]+)\.md$} $path -> m]} {
                set stable machteld/guide/$m
            } else {
                fail "unsupported authored guide link target $targetText"
            }
        } else {
            if {[regexp -nocase {^command/([a-z0-9-]+)\.md$} $path -> m]} {
                set stable machteld/command/$m
            } elseif {[regexp -nocase {^(index|agent)\.md$} $path -> m]} {
                set stable machteld/$m
            } else {
                fail "unsupported authored reference link target $targetText"
            }
        }
        append out "\[$labelText\]($stable$fragment)"
    }
    append out [string range $text $at end]
}

# ---- typed values: what the catalog is made of, for its two serializations ----
#
# {S text} string, {N n} number, {B 0|1} boolean, {Z} null, {L items} list of
# typed values, {D dict} dict of key -> typed value in insertion order.

proc ::ref::S {text} {list S $text}
proc ::ref::N {n} {list N $n}
proc ::ref::B {flag} {list B [expr {$flag ? 1 : 0}]}
proc ::ref::L {items} {list L $items}
proc ::ref::Ls {strings} {list L [lmap s $strings {list S $s}]}
proc ::ref::D {args} {list D [dict create {*}$args]}

# The value under a path of keys, its tag removed.
proc ::ref::get {node args} {
    foreach key $args {
        set node [dict get [lindex $node 1] $key]
    }
    lindex $node 1
}

proc ::ref::tclWord {value} {
    if {$value eq ""} {
        return "{}"
    }
    set value [string map [list \
        \b {\b} \t {\t} \n {\n} \v {\v} \f {\f} \r {\r} { } {\ } \" {\"} \$ {\$} \; {\;} \
        \[ {\[} \\ {\\} \] {\]} \{ {\{} \} {\}}] $value]
    # What the map leaves: other controls, DEL, and .NET's whitespace beyond
    # the ASCII the map escaped.
    regsub -all -command "\[\\x00-\\x07\\x0e-\\x1f\\x7f\u0085   -     　\]" $value {apply {{char} {
        format {\u%04x} [scan $char %c]
    }}}
}

proc ::ref::tclData {node} {
    lassign $node tag value
    switch $tag {
        S - N {return $value}
        B {return $value}
        Z {return ""}
        L {return [join [lmap item $value {tclWord [tclData $item]}] { }]}
        D {
            set words {}
            dict for {key item} $value {
                lappend words [tclWord $key] [tclWord [tclData $item]]
            }
            return [join $words { }]
        }
    }
    error "untyped catalog value: $node"
}

proc ::ref::jsonString {text} {
    set text [string map [list \\ {\\} \" {\"} \b {\b} \t {\t} \n {\n} \f {\f} \r {\r}] $text]
    set text [regsub -all -command {[\x00-\x1f]} $text {apply {{char} {format {\u%04x} [scan $char %c]}}}]
    return "\"$text\""
}

proc ::ref::jsonValue {node} {
    lassign $node tag value
    switch $tag {
        S {return [jsonString $value]}
        N {return $value}
        B {return [expr {$value ? "true" : "false"}]}
        Z {return null}
        L {return "\[[join [lmap item $value {jsonValue $item}] ,]\]"}
        D {
            set parts {}
            dict for {key item} $value {
                lappend parts "[jsonString $key]:[jsonValue $item]"
            }
            return "{[join $parts ,]}"
        }
    }
    error "untyped catalog value: $node"
}

proc ::ref::jsonDeterministic {node} {
    return "[jsonValue $node]\n"
}

# ---- HTML from the official converter ----

namespace eval ::ref {
    variable entities [dict create]
    # name -> character, as .NET's WebUtility decoded them; PowerShell's @{}
    # looks names up without regard to case, so lookups here do too.
    foreach {name code} {
        Aacute 00c1 Acirc 00c2 acute 00b4 AElig 00c6 Agrave 00c0 amp 0026 Aring 00c5 Atilde 00c3
        Auml 00c4 brvbar 00a6 Ccedil 00c7 cedil 00b8 cent 00a2 copy 00a9 curren 00a4 deg 00b0
        die 00a8 divide 00f7 Eacute 00c9 Ecirc 00ca Egrave 00c8 ETH 00d0 Euml 00cb euro 20ac
        frac12 00bd frac14 00bc frac34 00be gt 003e Iacute 00cd Icirc 00ce iexcl 00a1 Igrave 00cc
        iquest 00bf Iuml 00cf laquo 00ab ldquo 201c lt 003c macr 00af mdash 2014 micro 00b5
        middot 00b7 minus 2212 nbsp 00a0 ndash 2013 not 00ac Ntilde 00d1 Oacute 00d3 ocirc 00f4
        Ograve 00d2 ordf 00aa ordm 00ba Oslash 00d8 Otilde 00d5 Ouml 00d6 para 00b6 plusmn 00b1
        pound 00a3 prime 2032 quot 0022 raquo 00bb rarr 2192 rdquo 201d reg 00ae sect 00a7
        sup1 00b9 sup2 00b2 sup3 00b3 szlig 00df THORN 00de times 00d7 Uacute 00da Ucirc 00db
        Ugrave 00d9 Uuml 00dc Yacute 00dd yen 00a5 yuml 00ff
    } {
        dict set entities [string tolower $name] [format %c 0x$code]
    }
    unset name code
    variable allowedTags {a b body br dd div dl dt font h2 h3 h4 head html i li link meta ol p pre small table td title tr tt ul}
}

# WebUtility.HtmlDecode for the slugger's input: the known names (case as
# .NET matches them) and numeric references; anything else stays as it is.
proc ::ref::netHtmlDecode {text} {
    if {[string first & $text] < 0} {
        return $text
    }
    regsub -all -command {&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z0-9]+);} $text {apply {{whole name} {
        if {[regexp {^#([0-9]+)$} $name -> n]} {
            return [format %c [scan $n %d]]
        }
        if {[regexp {^#[xX]([0-9A-Fa-f]+)$} $name -> n]} {
            return [format %c [scan $n %x]]
        }
        variable ::ref::entities
        if {[dict exists $::ref::entities [string tolower $name]]} {
            return [dict get $::ref::entities [string tolower $name]]
        }
        return $whole
    }}}
}

proc ::ref::decodeHtml {text label} {
    variable entities
    if {[string first & $text] < 0} {
        return $text
    }
    set out ""
    set length [string length $text]
    for {set i 0} {$i < $length} {} {
        set amp [string first & $text $i]
        if {$amp < 0} {
            append out [string range $text $i end]
            break
        }
        append out [string range $text $i [expr {$amp - 1}]]
        set semi [string first \; $text [expr {$amp + 1}]]
        if {$semi < 0 || $semi - $amp > 20} {
            fail "$label contains malformed HTML entity"
        }
        set name [string range $text [expr {$amp + 1}] [expr {$semi - 1}]]
        if {[regexp {^#([0-9]+)$} $name -> digits]} {
            set code [scan $digits %d]
        } elseif {[regexp -nocase {^#x([0-9A-Fa-f]+)$} $name -> digits]} {
            set code [scan $digits %x]
        } elseif {[dict exists $entities [string tolower $name]]} {
            append out [dict get $entities [string tolower $name]]
            set i [expr {$semi + 1}]
            continue
        } else {
            fail "$label contains unknown HTML entity &$name;"
        }
        if {$code < 0 || $code > 0x10ffff || ($code >= 0xd800 && $code <= 0xdfff)} {
            fail "$label contains invalid numeric HTML entity &$name;"
        }
        append out [format %c $code]
        set i [expr {$semi + 1}]
    }
    return $out
}

proc ::ref::parseHtmlTag {raw label start end} {
    variable allowedTags
    variable S
    set inner [netTrim [string range $raw 1 end-1]]
    if {[regexp -nocase "^!DOCTYPE${S}+html\$" $inner]} {
        return [dict create kind doctype name doctype closing 0 self 1 attr {} start $start end $end raw $raw]
    }
    if {[string match !--* $inner]} {
        fail "$label contains unsupported HTML comment"
    }
    set closing 0
    if {[string match /* $inner]} {
        set closing 1
        regsub "^${S}+" [string range $inner 1 end] {} inner
    }
    set self 0
    if {[string match */ $inner]} {
        set self 1
        regsub "${S}+\$" [string range $inner 0 end-1] {} inner
    }
    set length [string length $inner]
    set i 0
    while {$i < $length && ([string is alnum -strict [string index $inner $i]] || [string index $inner $i] eq ":")} {
        incr i
    }
    if {$i == 0} {
        fail "$label contains malformed tag $raw"
    }
    set name [string tolower [string range $inner 0 [expr {$i - 1}]]]
    if {$name ni $allowedTags} {
        fail "$label contains unknown tag <$name>"
    }
    set attrs [dict create]
    while {$i < $length} {
        while {$i < $length && [isWhiteSpace [string index $inner $i]]} {incr i}
        if {$i >= $length} {
            break
        }
        set begin $i
        while {$i < $length} {
            set c [string index $inner $i]
            if {![string is alnum -strict $c] && $c ni {- : _}} {
                break
            }
            incr i
        }
        if {$begin == $i} {
            fail "$label contains malformed attribute in $raw"
        }
        set key [string tolower [string range $inner $begin [expr {$i - 1}]]]
        while {$i < $length && [isWhiteSpace [string index $inner $i]]} {incr i}
        set value ""
        if {$i < $length && [string index $inner $i] eq "="} {
            incr i
            while {$i < $length && [isWhiteSpace [string index $inner $i]]} {incr i}
            if {$i >= $length} {
                fail "$label has missing value for attribute $key"
            }
            set c [string index $inner $i]
            if {$c eq "\"" || $c eq "'"} {
                incr i
                set close [string first $c $inner $i]
                if {$close < 0} {
                    fail "$label has unterminated attribute $key"
                }
                set value [string range $inner $i [expr {$close - 1}]]
                set i [expr {$close + 1}]
            } else {
                set begin $i
                while {$i < $length && ![isWhiteSpace [string index $inner $i]]} {incr i}
                set value [string range $inner $begin [expr {$i - 1}]]
            }
        }
        if {[dict exists $attrs $key]} {
            fail "$label repeats HTML attribute $key"
        }
        dict set attrs $key [decodeHtml $value "$label attribute $key"]
    }
    dict create kind tag name $name closing $closing self $self attr $attrs start $start end $end raw $raw
}

proc ::ref::htmlTokens {html label} {
    assertNoSurrogates $html $label
    set tokens {}
    set length [string length $html]
    for {set i 0} {$i < $length} {} {
        if {[string index $html $i] ne "<"} {
            set next [string first < $html $i]
            if {$next < 0} {
                set next $length
            }
            lappend tokens [dict create kind text text [decodeHtml [string range $html $i [expr {$next - 1}]] $label] \
                start $i end $next]
            set i $next
            continue
        }
        if {![regexp -start $i -indices {\A<(?:[^"'>]|"[^"]*"|'[^']*')*>} $html span]} {
            fail "$label has unterminated HTML tag"
        }
        set j [lindex $span 1]
        lappend tokens [parseHtmlTag [string range $html $i $j] $label $i [expr {$j + 1}]]
        set i [expr {$j + 1}]
    }
    return $tokens
}

proc ::ref::isTag {token args} {
    expr {[dict get $token kind] eq "tag" && [dict get $token name] in $args}
}

proc ::ref::tokenPlainText {tokens start end} {
    set out ""
    for {set i $start} {$i < $end} {incr i} {
        set t [lindex $tokens $i]
        if {[dict get $t kind] eq "text"} {
            append out [dict get $t text]
        } elseif {[dict get $t kind] eq "tag" && ![dict get $t closing] && [dict get $t name] in {br p dd dt li}} {
            append out " "
        }
    }
    collapse $out
}

proc ::ref::inspectHtmlPage {html label} {
    set tokens [htmlTokens $html $label]
    set count [llength $tokens]
    set anchors [dict create]
    set sections {}
    set used [dict create]
    set contentToken -1
    for {set i 0} {$i < $count} {incr i} {
        set t [lindex $tokens $i]
        if {![isTag $t h3 h4] || [dict get $t closing]} {
            continue
        }
        set name [dict get $t name]
        set close [expr {$i + 1}]
        while {$close < $count && !([isTag [lindex $tokens $close] $name] && [dict get [lindex $tokens $close] closing])} {
            incr close
        }
        if {$close >= $count} {
            fail "$label has unclosed <$name>"
        }
        set anchor ""
        for {set j [expr {$i + 1}]} {$j < $close} {incr j} {
            set a [lindex $tokens $j]
            if {[isTag $a a] && ![dict get $a closing] && [dict exists $a attr name]} {
                set anchor [dict get $a attr name]
                break
            }
        }
        # PowerShell's -notmatch: without regard to case.
        if {![regexp -nocase {^M[0-9]+$} $anchor]} {
            continue
        }
        if {$contentToken < 0} {
            set contentToken $i
        }
        set heading [tokenPlainText $tokens [expr {$i + 1}] $close]
        set base [slug $heading]
        if {$base eq ""} {
            set base [string tolower $anchor]
        }
        set slug $base
        set suffix 2
        while {[dict exists $used $slug]} {
            set slug $base-$suffix
            incr suffix
        }
        dict set used $slug 1
        dict set anchors $anchor $slug
        lappend sections [dict create slug $slug heading $heading anchor $anchor \
            level [expr {$name eq "h3" ? 2 : 3}] htmlStart [dict get $t start] tokenStart $i tokenEnd $close]
    }
    if {$contentToken < 0 || [llength $sections] < 2 || ![string equal -nocase [dict get [lindex $sections 0] heading] NAME]} {
        fail "$label has no canonical NAME section (tokens=$count, sections=[llength $sections])"
    }
    # Inline converter anchors map to their containing heading, so every
    # rewritten link resolves to a catalogued section.
    for {set i $contentToken} {$i < $count} {incr i} {
        set t [lindex $tokens $i]
        if {![isTag $t a] || [dict get $t closing] || ![dict exists $t attr name]} {
            continue
        }
        set name [dict get $t attr name]
        if {![regexp -nocase {^M[0-9]+$} $name] || [dictHasNocase $anchors $name]} {
            continue
        }
        set containing ""
        foreach section $sections {
            if {[dict get $section tokenStart] <= $i} {
                set containing $section
            } else {
                break
            }
        }
        if {$containing eq ""} {
            fail "$label has an inline anchor before its first section"
        }
        dict set anchors $name [dict get $containing slug]
    }
    set nameSection [lindex $sections 0]
    set next [lindex $sections 1]
    set nameText [tokenPlainText $tokens [expr {[dict get $nameSection tokenEnd] + 1}] [dict get $next tokenStart]]
    variable S
    if {![regexp -indices "${S}+\[–—-\]${S}+" $nameText separator]} {
        fail "$label NAME section has no name/summary separator: $nameText"
    }
    set namePart [string range $nameText 0 [expr {[lindex $separator 0] - 1}]]
    set summary [netTrim [string range $nameText [expr {[lindex $separator 1] + 1}] end]]
    set names {}
    foreach name [split $namePart ,] {
        set name [netTrim $name]
        if {$name ne ""} {
            lappend names $name
        }
    }
    if {[llength $names] == 0} {
        fail "$label NAME section has no names"
    }
    set copyright ""
    for {set i $contentToken} {$i < $count} {incr i} {
        set t [lindex $tokens $i]
        if {[isTag $t div] && ![dict get $t closing] && [dict exists $t attr class] &&
                [string equal -nocase [dict get $t attr class] copy]} {
            set close [expr {$i + 1}]
            while {$close < $count && !([isTag [lindex $tokens $close] div] && [dict get [lindex $tokens $close] closing])} {
                incr close
            }
            set copyright [tokenPlainText $tokens [expr {$i + 1}] $close]
            break
        }
    }
    dict create tokens $tokens anchors $anchors sections $sections contentToken $contentToken \
        names $names summary $summary copyright $copyright
}

# A dict lookup without regard to case, as PowerShell's ordered dictionaries do.
proc ::ref::dictHasNocase {d key} {
    if {[dict exists $d $key]} {
        return 1
    }
    foreach k [dict keys $d] {
        if {[string equal -nocase $k $key]} {
            return 1
        }
    }
    return 0
}

proc ::ref::dictGetNocase {d key} {
    if {[dict exists $d $key]} {
        return [dict get $d $key]
    }
    foreach k [dict keys $d] {
        if {[string equal -nocase $k $key]} {
            return [dict get $d $k]
        }
    }
    error "no key $key"
}

proc ::ref::escapeMarkdownText {text} {
    string map {\\ \\\\ \[ \\\[ \] \\\]} $text
}

# ---- one converted page as Markdown ----

namespace eval ::ref::page {
    namespace path {::machteld ::ref}
}

# The rendering state of one page lives in namespace variables of
# ::ref::page, reset for each page.
proc ::ref::page::reset {} {
    variable b ""
    variable cell ""
    variable inCell 0
    variable row {}
    variable inRow 0
    variable table {}
    variable inTable 0
    variable pendingBullet ""
}

proc ::ref::page::append {text} {
    variable b
    ::append b $text
}

proc ::ref::page::appendInline {text} {
    variable inCell
    if {$inCell} {
        variable cell
        ::append cell $text
    } else {
        variable b
        ::append b $text
    }
}

proc ::ref::page::break {{count 1}} {
    variable b
    if {$b eq ""} {
        return
    }
    set end [string length $b]
    while {$end > 0 && [string index $b $end-1] eq " "} {
        incr end -1
    }
    if {$end < [string length $b]} {
        set b [string range $b 0 $end-1]
    }
    set present 0
    for {set j [expr {[string length $b] - 1}]} {$j >= 0 && $present < $count && [string index $b $j] eq "\n"} {incr j -1} {
        incr present
    }
    while {$present < $count} {
        ::append b \n
        incr present
    }
}

proc ::ref::page::cellBreak {{count 1}} {
    variable inCell
    if {!$inCell} {
        break $count
        return
    }
    variable cell
    if {$cell ne "" && ![::ref::isWhiteSpace [string index $cell end]]} {
        ::append cell " "
    }
}

proc ::ref::page::flushPendingBullet {text} {
    variable pendingBullet
    if {$pendingBullet eq ""} {
        return $text
    }
    # .NET '^\s*(\S.*)$': '.' stops at a newline, and '$' matches at the end
    # or before a final newline.
    set S $::ref::S
    set NS $::ref::NS
    if {![regexp "^${S}*(${NS}\[^\n\]*)\n?\$" $text -> rest]} {
        return ""
    }
    appendInline "$pendingBullet$rest"
    set pendingBullet ""
    return ""
}

proc ::ref::page::flushPendingBulletMarkup {} {
    variable pendingBullet
    if {$pendingBullet eq ""} {
        return
    }
    appendInline $pendingBullet
    set pendingBullet ""
}

proc ::ref::page::finishCell {label} {
    variable inCell
    if {!$inCell} {
        return
    }
    variable inRow
    if {!$inRow} {
        ::ref::fail "$label has a table cell outside a row"
    }
    variable row
    variable cell
    lappend row $cell
    set cell ""
    set inCell 0
}

proc ::ref::page::finishRow {label} {
    variable inRow
    if {!$inRow} {
        return
    }
    variable inTable
    if {!$inTable} {
        ::ref::fail "$label has a table row outside a table"
    }
    variable inCell
    variable row
    if {$inCell} {
        variable cell
        lappend row $cell
        set cell ""
        set inCell 0
    }
    variable table
    lappend table $row
    set row {}
    set inRow 0
}

proc ::ref::stableLink {href htmlRelative htmlToId pageAnchors} {
    if {[regexp {^[A-Za-z][A-Za-z0-9+.-]*:} $href]} {
        return $href
    }
    set hash [string first # $href]
    if {$hash >= 0} {
        set pathPart [string range $href 0 [expr {$hash - 1}]]
        set fragment [string range $href [expr {$hash + 1}] end]
    } else {
        set pathPart $href
        set fragment ""
    }
    set targetPath $htmlRelative; if {$pathPart ne ""} {set targetPath [resolveLogicalPath $htmlRelative $pathPart]}
    if {![dictHasNocase $htmlToId $targetPath]} {
        return ""
    }
    set targetId [dictGetNocase $htmlToId $targetPath]
    if {$fragment ne "" && [dictHasNocase $pageAnchors $targetId] &&
            [dictHasNocase [dictGetNocase $pageAnchors $targetId] $fragment]} {
        return "$targetId#[dictGetNocase [dictGetNocase $pageAnchors $targetId] $fragment]"
    }
    return $targetId
}

proc ::ref::convertHtmlPage {html htmlRelative id inspection htmlToId pageAnchors} {
    set tokens [dict get $inspection tokens]
    set sections [dict get $inspection sections]
    set title [lindex [dict get $inspection names] 0]
    page::reset
    page::append "# $title\n\n"
    page::append "_Upstream [string toupper [lindex [split $id /] 0]] 9.0.4 reference; normalized from the official manual source._\n\n"
    set inPre 0
    set skipDepth 0
    set started 0
    set inline {}
    set links {}
    set anchorModes {}
    set lists {}
    set headingDepth 0
    set contentToken [dict get $inspection contentToken]
    set count [llength $tokens]
    for {set i $contentToken} {$i < $count} {incr i} {
        set t [lindex $tokens $i]
        if {[dict get $t kind] eq "text"} {
            if {!$started || $skipDepth > 0} {
                continue
            }
            set text [dict get $t text]
            if {$page::pendingBullet ne ""} {
                set text [page::flushPendingBullet $text]
                if {$text eq ""} {
                    continue
                }
            }
            if {$page::inCell} {
                ::append page::cell $text
                continue
            }
            if {$inPre} {
                page::append $text
            } else {
                page::append [escapeMarkdownText $text]
            }
            continue
        }
        if {[dict get $t kind] ne "tag"} {
            continue
        }
        if {!$started} {
            if {$i == $contentToken} {
                set started 1
            } else {
                continue
            }
        }
        set name [dict get $t name]
        set closing [dict get $t closing]
        if {$name in {head title h2}} {
            if {!$closing} {incr skipDepth} else {incr skipDepth -1}
            continue
        }
        if {$skipDepth > 0} {
            continue
        }
        switch -- $name {
            a {
                if {!$closing} {
                    if {$page::pendingBullet ne "" && [dict exists $t attr href]} {
                        page::flushPendingBulletMarkup
                    }
                    set anchorName ""; if {[dict exists $t attr name]} {set anchorName [dict get $t attr name]}
                    if {$anchorName ne "" && $headingDepth == 0 && [sectionWithAnchor $sections $anchorName]} {
                        set slug [dictGetNocase [dict get $inspection anchors] $anchorName]
                        if {!$inPre} {
                            page::break 2
                            page::append "<a id=\"$slug\"></a>\n"
                        }
                    }
                    # The converter wraps heading text in a named anchor
                    # without href: an anchor element, not a Markdown link.
                    set hasHref [dict exists $t attr href]
                    lappend anchorModes $hasHref
                    if {!$hasHref} {
                        continue
                    }
                    set href ""; if {!$inPre} {set href [stableLink [dict get $t attr href] $htmlRelative $htmlToId $pageAnchors]}
                    lappend links $href
                    if {$href ne ""} {
                        page::appendInline "\["
                    }
                } else {
                    if {[llength $anchorModes] == 0} {
                        fail "$htmlRelative closes an unopened anchor"
                    }
                    set hasHref [lindex $anchorModes end]
                    set anchorModes [lrange $anchorModes 0 end-1]
                    if {!$hasHref} {
                        continue
                    }
                    if {[llength $links] == 0} {
                        fail "$htmlRelative closes an unopened link"
                    }
                    set href [lindex $links end]
                    set links [lrange $links 0 end-1]
                    if {$href ne ""} {
                        page::appendInline "\]($href)"
                    }
                }
            }
            b - i - tt - font - small {
                if {!$closing && $page::pendingBullet ne ""} {
                    page::flushPendingBulletMarkup
                }
                set mark [dict get {b ** i * tt ` font {} small {}} $name]
                if {!$closing} {
                    lappend inline $mark
                    if {$mark ne "" && !$inPre} {
                        page::appendInline $mark
                    }
                } else {
                    if {[llength $inline] == 0} {
                        fail "$htmlRelative closes unopened <$name>"
                    }
                    set open [lindex $inline end]
                    set inline [lrange $inline 0 end-1]
                    if {$open ne "" && !$inPre} {
                        page::appendInline $open
                    }
                }
            }
            h3 - h4 {
                if {!$closing} {
                    page::break 2
                    foreach section $sections {
                        if {[dict get $section tokenStart] == $i} {
                            page::append "<a id=\"[dict get $section slug]\"></a>\n"
                            break
                        }
                    }
                    if {$name eq "h3"} {page::append "## "} else {page::append "### "}
                    incr headingDepth
                } else {
                    incr headingDepth -1
                    page::break 2
                }
            }
            pre {
                if {!$closing} {
                    if {[string match -nocase */c-api/* $id]} {
                        set language c
                    } elseif {[string match -nocase */application/* $id]} {
                        set language text
                    } else {
                        set language tcl
                    }
                    page::break 2
                    page::append "```$language\n"
                    set inPre 1
                } else {
                    set inPre 0
                    page::break 1
                    page::append ```
                    page::break 2
                }
            }
            br {
                page::cellBreak 1
            }
            p {
                page::cellBreak 2
            }
            ul - ol {
                if {!$closing} {
                    lappend lists $name
                    page::cellBreak 1
                } else {
                    if {[llength $lists]} {
                        set lists [lrange $lists 0 end-1]
                    }
                    page::cellBreak 2
                }
            }
            li {
                if {$closing} {
                    fail "$htmlRelative has unhandled tag <li>"
                }
                page::cellBreak 1
                set indent [string repeat "  " [expr {max(0, [llength $lists] - 1)}]]
                set bullet "- "; if {[llength $lists] && [lindex $lists end] eq "ol"} {set bullet "1. "}
                set page::pendingBullet "$indent$bullet"
            }
            dl {
                if {$closing} {page::cellBreak 2} else {page::cellBreak 1}
            }
            dt - dd {
                if {!$closing} {
                    page::cellBreak 1
                    if {$name eq "dt"} {
                        set page::pendingBullet "- "
                    }
                }
            }
            table {
                if {!$closing} {
                    if {$page::inTable || $page::inRow || $page::inCell} {
                        fail "$htmlRelative nests tables or leaves table state open"
                    }
                    set page::table {}
                    set page::inTable 1
                    page::break 2
                } else {
                    if {!$page::inTable} {
                        fail "$htmlRelative closes unopened table"
                    }
                    page::finishRow $htmlRelative
                    renderTable $page::table
                    set page::table {}
                    set page::inTable 0
                    page::break 2
                }
            }
            tr {
                if {!$closing} {
                    if {!$page::inTable} {
                        fail "$htmlRelative opens a row outside a table"
                    }
                    page::finishRow $htmlRelative
                    set page::row {}
                    set page::inRow 1
                } else {
                    if {!$page::inTable || !$page::inRow} {
                        fail "$htmlRelative malformed table row"
                    }
                    page::finishRow $htmlRelative
                }
            }
            td {
                if {!$closing} {
                    if {!$page::inRow} {
                        fail "$htmlRelative opens a cell outside a row"
                    }
                    page::finishCell $htmlRelative
                    set page::cell ""
                    set page::inCell 1
                } else {
                    if {!$page::inRow || !$page::inCell} {
                        fail "$htmlRelative malformed table cell"
                    }
                    page::finishCell $htmlRelative
                }
            }
            div {
                if {!$closing && [dict exists $t attr class] && [string equal -nocase [dict get $t attr class] copy]} {
                    page::break 2
                    page::append "> "
                } elseif {$closing} {
                    page::break 2
                }
            }
            html - body - link - meta {}
            default {
                fail "$htmlRelative has unhandled tag <$name>"
            }
        }
    }
    if {$page::pendingBullet ne "" || $inPre || [llength $links] || [llength $anchorModes] || [llength $inline] ||
            $page::inTable || $page::inRow || $page::inCell} {
        fail "$htmlRelative ended with unbalanced rendering state"
    }
    set markdown [string map [list \r ""] $page::b]
    regsub -all {[ \t]+\n} $markdown \n markdown
    regsub -all {\n{3,}} $markdown \n\n markdown
    set markdown "[netTrim $markdown]\n"
    if {[regexp -nocase {</?(?:b|i|dl|dt|dd|table|tr|td|font|pre|p|br)\y} $markdown]} {
        fail "$htmlRelative leaked converter markup into Markdown"
    }
    set copyright [dict get $inspection copyright]
    if {$copyright ne ""} {
        set notice [normalizeSearch $copyright]
        if {[string first $notice [normalizeSearch $markdown]] < 0} {
            # The complete decoded upstream notice, verbatim, when Markdown
            # rendering separated its punctuation.
            set markdown "[netTrimEnd $markdown]\n\n> $copyright\n"
        }
        if {[string first $notice [normalizeSearch $markdown]] < 0} {
            fail "$htmlRelative normalization lost per-page notice: $notice"
        }
    }
    return $markdown
}

# A product's version; expr would read 0.21 as a number.
proc ::ref::productVersion {product version} {
    if {$product eq "machteld"} {
        return $version
    }
    return 9.0.4
}

proc ::ref::netTrimEnd {text} {
    variable S
    regsub "${S}+\$" $text {} text
    return $text
}

proc ::ref::sectionWithAnchor {sections anchor} {
    foreach section $sections {
        if {[string equal -nocase [dict get $section anchor] $anchor]} {
            return 1
        }
    }
    return 0
}

proc ::ref::renderTable {table} {
    if {[llength $table] == 0} {
        return
    }
    set width 0
    foreach row $table {
        set width [expr {max($width, [llength $row])}]
    }
    set ri 0
    foreach row $table {
        while {[llength $row] < $width} {
            lappend row ""
        }
        set cells [lmap c $row {string map {| \\|} [collapse $c]}]
        page::append "| [join $cells { | }] |"
        page::break 1
        if {$ri == 0} {
            page::append "| [join [lrepeat $width ---] { | }] |"
            page::break 1
        }
        incr ri
    }
}

# ---- sections ----

# The lines of text with their newlines, as .NET's '.*?(?:\n|$)' finds them.
proc ::ref::chunks {text} {
    set out {}
    set at 0
    set length [string length $text]
    while {$at < $length} {
        set nl [string first \n $text $at]
        if {$nl < 0} {
            lappend out [string range $text $at end]
            break
        }
        lappend out [string range $text $at $nl]
        set at [expr {$nl + 1}]
    }
    return $out
}

proc ::ref::markdownSections {text label} {
    assertNoSurrogates $text $label
    variable S
    set found {}
    set slugs {}
    set pendingAnchor ""
    set pendingAnchorStart -1
    set offset 0
    set fence ""
    foreach chunk [chunks $text] {
        set line [string trimright $chunk \n]
        if {[regexp "^${S}*(`{3,}|~{3,})" $line -> marker]} {
            if {$fence eq ""} {
                set fence [string index $marker 0]
            } elseif {[string index $marker 0] eq $fence} {
                set fence ""
            }
            set pendingAnchor ""
            set pendingAnchorStart -1
            incr offset [string length $chunk]
            continue
        }
        if {$fence ne ""} {
            incr offset [string length $chunk]
            continue
        }
        if {[regexp -nocase {^<a id="([a-z0-9][a-z0-9-]*)"></a>$} $line -> anchor]} {
            set pendingAnchor $anchor
            set pendingAnchorStart $offset
        } elseif {[headingLine $line hashes headingText]} {
            set heading [stripMarkdown $headingText]
            set slug $pendingAnchor; if {$slug eq ""} {set slug [slug $heading]}
            if {$slug eq ""} {
                fail "$label contains an unnameable heading"
            }
            if {[string tolower $slug] in $slugs} {
                fail "$label repeats section slug $slug"
            }
            lappend slugs [string tolower $slug]
            set start [expr {$pendingAnchor ne "" ? $pendingAnchorStart : $offset}]
            if {$start < 0} {
                set start $offset
            }
            lappend found [dict create slug $slug heading $heading level [string length $hashes] \
                start $start end [string length $text]]
            set pendingAnchor ""
            set pendingAnchorStart -1
        } elseif {[netTrim $line] ne ""} {
            set pendingAnchor ""
            set pendingAnchorStart -1
        }
        incr offset [string length $chunk]
    }
    closeSections $found
}

# '^(#{2,3})\s+(.+?)\s*$' as .NET matches it, by hand.
proc ::ref::headingLine {line hashesVar textVar} {
    upvar 1 $hashesVar hashes $textVar text
    variable S
    if {![regexp "^(#{2,3})(${S}+)(.*)\$" $line -> h gap rest]} {
        return 0
    }
    set rest [netTrimEnd $rest]
    if {$rest eq ""} {
        # Whitespace only: .NET gives one whitespace character to (.+?) when
        # \s+ can spare it, and fails otherwise.
        if {[string length $gap] < 2} {
            return 0
        }
        set rest [string index $gap end]
    }
    set hashes $h
    set text $rest
    return 1
}

proc ::ref::closeSections {sections} {
    set count [llength $sections]
    for {set i 0} {$i < $count} {incr i} {
        for {set j [expr {$i + 1}]} {$j < $count} {incr j} {
            if {[dict get [lindex $sections $j] level] <= [dict get [lindex $sections $i] level]} {
                lset sections $i [dict replace [lindex $sections $i] end [dict get [lindex $sections $j] start]]
                break
            }
        }
    }
    return $sections
}

proc ::ref::htmlSections {text inspection} {
    set out {}
    foreach s [dict get $inspection sections] {
        lappend out [dict create slug [dict get $s slug] heading [dict get $s heading] level [dict get $s level] \
            start [dict get $s htmlStart] end [string length $text]]
    }
    closeSections $out
}

proc ::ref::sourceSections {text label} {
    assertNoSurrogates $text $label
    variable S
    variable NS
    set out {}
    set used [dict create]
    # .NET '(?m)^\.(SH|SS)\s+(?:"([^"]+)"|(\S.*))$': \s may cross a newline,
    # '.' does not, '^' and '$' hold at line ends.
    set pattern "(?n)^\\.(SH|SS)${S}+(?:\"(\[^\"\]+)\"|(${NS}.*))\$"
    foreach {whole kind quoted bare} [regexp -all -inline -indices $pattern $text] {
        if {[lindex $quoted 0] >= 0} {
            set heading [string range $text {*}$quoted]
        } else {
            set heading [netTrim [string range $text {*}$bare]]
        }
        regsub -all -nocase {\\f[BRIP]} $heading {} heading
        set base [slug $heading]
        if {$base eq ""} {
            continue
        }
        set slug $base
        set n 2
        while {[dict exists $used $slug]} {
            set slug $base-$n
            incr n
        }
        dict set used $slug 1
        lappend out [dict create slug $slug heading $heading \
            level [expr {[string range $text {*}$kind] eq "SH" ? 2 : 3}] \
            start [lindex $whole 0] end [string length $text]]
    }
    closeSections $out
}

proc ::ref::fencedCodeBlocks {text label} {
    assertNoSurrogates $text $label
    set blocks {}
    set openMarker ""
    set language ""
    set content ""
    foreach chunk [chunks $text] {
        set line [string trimright [string trimright $chunk \n] \r]
        if {$openMarker eq ""} {
            if {[regexp {^(`{3,}|~{3,})(.*)$} $line -> openMarker info]} {
                set info [netTrim $info]
                set language ""; if {$info ne ""} {set language [string tolower [lindex [regexp -inline "^${::ref::NS}+" $info] 0]]}
                set content ""
            }
            continue
        }
        if {[regexp {^(`{3,}|~{3,})[ \t]*$} $line -> closeMarker]} {
            if {[string index $closeMarker 0] eq [string index $openMarker 0] &&
                    [string length $closeMarker] >= [string length $openMarker]} {
                lappend blocks [dict create language $language content $content]
                set openMarker ""
                set language ""
                set content ""
                continue
            }
        }
        append content $line
        if {[string index $chunk end] eq "\n"} {
            append content \n
        }
    }
    if {$openMarker ne ""} {
        fail "$label contains an unclosed $openMarker code fence"
    }
    return $blocks
}

proc ::ref::sectionsDict {sections withOffsets} {
    set d [dict create]
    foreach s $sections {
        if {$withOffsets} {
            dict set d [dict get $s slug] [D start [N [dict get $s start]] end [N [dict get $s end]]]
        } else {
            dict set d [dict get $s slug] [S [dict get $s heading]]
        }
    }
    list D $d
}

proc ::ref::formatRecord {root relative sections} {
    set relative [normalizeSlashPath $relative]
    set path [file join $root {*}[split $relative /]]
    if {![file isfile $path]} {
        fail "format file missing: $relative"
    }
    set text [readUtf8Strict $path]
    assertNoSurrogates $text $relative
    D path [S $relative] sha256 [S [sha256 $path]] bytes [N [file size $path]] \
        characters [N [string length $text]] sections [sectionsDict $sections 1]
}

proc ::ref::frontMatter {text label} {
    set lines [split [string map [list \r ""] $text] \n]
    if {[llength $lines] < 3 || [lindex $lines 0] ne "---"} {
        fail "$label has no front matter"
    }
    set d [dict create]
    set end -1
    for {set i 1} {$i < [llength $lines]} {incr i} {
        set line [lindex $lines $i]
        if {$line eq "---"} {
            set end $i
            break
        }
        if {![regexp -nocase "^(\[a-z_\]+):${::ref::S}?(.*)\$" $line -> key value]} {
            fail "$label has invalid front matter"
        }
        dict set d $key $value
    }
    if {$end < 0} {
        fail "$label has unterminated front matter"
    }
    foreach key {id type title summary commands} {
        if {![dict exists $d $key]} {
            fail "$label front matter lacks $key"
        }
    }
    return $d
}

proc ::ref::guideMetadata {text label} {
    set lines [split [string map [list \r ""] $text] \n]
    if {[llength $lines] < 3 || [lindex $lines 0] ne "---"} {
        fail "$label has no guide front matter"
    }
    set metadata [dict create]
    set end -1
    for {set i 1} {$i < [llength $lines]} {incr i} {
        set line [lindex $lines $i]
        if {$line eq "---"} {
            set end $i
            break
        }
        if {![regexp -nocase "^(\[a-z_\]+):${::ref::S}?(.*)\$" $line -> key value]} {
            fail "$label has invalid guide front matter"
        }
        dict set metadata $key $value
    }
    if {$end < 0} {
        fail "$label has unterminated guide front matter"
    }
    foreach key {type title description} {
        if {![dict exists $metadata $key]} {
            fail "$label guide front matter lacks $key"
        }
    }
    dict create metadata $metadata body [join [lrange $lines [expr {$end + 1}] end] \n]
}

proc ::ref::corpusHash {inventory} {
    set material ""
    foreach path [lsort [dict keys $inventory]] {
        append material "$path\0[get [dict get $inventory $path] sha256]\0"
    }
    hash sum sha256 [encoding convertto utf-8 $material]
}

# Every file under root, as {relative fullName} pairs in the order
# PowerShell sorted FullName: ordinal, with backslashes.
proc ::ref::filesUnder {root} {
    set found {}
    set pending [list ""]
    while {[llength $pending]} {
        set dir [lindex $pending end]
        set pending [lrange $pending 0 end-1]
        set here $root; if {$dir ne ""} {set here [file join $root {*}[split $dir /]]}
        foreach path [glob -nocomplain -directory $here *] {
            set name [file tail $path]
            set relative $name; if {$dir ne ""} {set relative $dir/$name}
            if {[file isdirectory $path]} {
                lappend pending $relative
            } else {
                lappend found [list $relative $path]
            }
        }
    }
    lsort -index 0 -command {apply {{a b} {
        string compare [string map {/ \\} $a] [string map {/ \\} $b]
    }}} $found
}

proc ::ref::copyBytes {source destination} {
    file mkdir [file dirname $destination]
    file copy -force $source $destination
}

# The whitelisted entries of a source archive, extracted through Tcl's zipfs.
proc ::ref::extractControlledSources {archive rootName product destination withTools} {
    set mount refsrc-$product-[pid]
    zipfs mount $archive $mount
    try {
        set base //zipfs:/$mount/$rootName
        set docs {}
        foreach path [zipfs list //zipfs:/$mount/*] {
            set relative [string range $path [string length //zipfs:/$mount/] end]
            if {[regexp -nocase "^[regexAnyEscape $rootName]/doc/\[A-Za-z0-9_\]\[A-Za-z0-9_.-\]*\\.(?:1|3|n)\$" $relative]} {
                lappend docs $relative
            }
        }
        set expected [expr {$product eq "tcl" ? 249 : 177}]
        if {[llength $docs] != $expected} {
            fail "$product archive core manual inventory is [llength $docs], expected $expected"
        }
        set wanted $docs
        foreach relative {doc/man.macros doc/license.terms README.md} {
            if {![file isfile $base/$relative]} {
                fail "$product archive lacks exactly one $rootName/$relative"
            }
            lappend wanted $rootName/$relative
        }
        set header generic/tk.h; if {$product eq "tcl"} {set header generic/tcl.h}
        if {![file isfile $base/$header]} {
            fail "$product archive lacks $rootName/$header"
        }
        lappend wanted $rootName/$header
        if {$withTools} {
            foreach relative {tools/tcltk-man2html.tcl tools/tcltk-man2html-utils.tcl} {
                if {![file isfile $base/$relative]} {
                    fail "Tcl archive lacks $rootName/$relative"
                }
                lappend wanted $rootName/$relative
            }
        }
        foreach entry $wanted {
            set relative [string range $entry [string length $rootName/] end]
            if {[string first \\ $relative] >= 0 || [string first : $relative] >= 0 ||
                    [regexp {(^|/)\.\.?(/|$)} $relative]} {
                fail "$product archive has unsafe whitelisted path $relative"
            }
            copyBytes //zipfs:/$mount/$entry [file join $destination $rootName {*}[split $relative /]]
        }
    } finally {
        zipfs unmount //zipfs:/$mount
    }
    if {[file isdirectory [file join $destination $rootName pkgs]]} {
        fail "$product controlled source unexpectedly contains extension packages"
    }
}

proc ::ref::regexAnyEscape {text} {
    regsub -all {[][\\.^$*+?(){}|]} $text {\\&}
}

proc ::ref::addUnique {mapVar key value} {
    upvar 1 $mapVar map
    if {![dict exists $map $key]} {
        dict set map $key {}
    }
    if {$value ni [dict get $map $key]} {
        dict lappend map $key $value
    }
}

proc ::ref::readJsonFile {path} {
    json decode [readUtf8Strict $path]
}

proc ::ref::uniqueName {} {
    binary encode hex [hash random 16]
}

# ---- the whole reference ----

proc ::ref::main {argv} {
    variable root
    variable generator
    variable S
    set cache [file join $root .cache deps]
    set output [file join $root out reference]
    set tclsh ""
    set keepWork 0
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --cache {set argv [lassign $argv cache]}
            --output {set argv [lassign $argv output]}
            --tclsh {set argv [lassign $argv tclsh]}
            --keep-work {set keepWork 1}
            default {fail "unknown option $option; reference.tcl ?--cache DIR? ?--output DIR? ?--tclsh EXE? ?--keep-work?"}
        }
    }
    set cache [file normalize $cache]
    set output [file normalize $output]
    set lockPath [file join $root tools dependencies.lock.json]
    if {![file isfile $lockPath]} {
        fail "dependency lock missing: $lockPath"
    }
    set lock [readJsonFile $lockPath]
    foreach entry [dict get $lock archives] {
        dict set locked [dict get $entry id] $entry
    }
    set tclLock [dict get $locked tcltk]
    set tkLock [dict get $locked tk]
    if {[dict get $tclLock version] ne "9.0.4" || [dict get $tkLock version] ne "9.0.4"} {
        fail "reference generator requires pinned Tcl/Tk 9.0.4"
    }
    set tclArchive [file join $cache downloads [dict get $tclLock file]]
    set tkArchive [file join $cache downloads [dict get $tkLock file]]
    assertArchive $tclArchive [dict get $tclLock sha256] Tcl
    assertArchive $tkArchive [dict get $tkLock sha256] Tk
    if {$tclsh eq ""} {
        foreach candidate [list [file join $cache prefix bin tclsh90s.exe] [file join $cache prefix bin tclsh90.exe]] {
            if {[file isfile $candidate]} {
                set tclsh $candidate
                break
            }
        }
    }
    if {$tclsh eq "" || ![file isfile $tclsh]} {
        fail "static Tcl 9 shell not found; pass --tclsh"
    }

    set headerText [readUtf8Strict [file join $root src machteld.h]]
    if {![regexp -nocase "(?n)^#define${S}+MACHTELD_VERSION${S}+\"(\[0-9\]+\\.\[0-9\]+(?:\\.\[0-9\]+)?)\"${S}*\$" $headerText -> version]} {
        fail "src/machteld.h has no canonical MACHTELD_VERSION"
    }
    set preludeText [readUtf8Strict [file join $root tcl machteld.tcl]]
    if {![regexp -nocase "(?n)^${S}*variable${S}+version${S}+(\[0-9\]+\\.\[0-9\]+(?:\\.\[0-9\]+)?)${S}*\$" $preludeText -> preludeVersion]} {
        fail "tcl/machteld.tcl has no canonical version variable"
    }
    if {$preludeVersion ne $version} {
        fail "C/Tcl runtime version mismatch: $version vs $preludeVersion"
    }
    # The wrap launcher derives its pin from ::machteld::version at run time; a
    # literal there would be a third copy of the version that could fall behind.
    if {[regexp -nocase {package require machteld [0-9]} $preludeText]} {
        fail "tcl/machteld.tcl carries a literal launcher pin"
    }

    set parent [file dirname $output]
    file mkdir $parent
    set claim [file join $parent .machteld-reference-[uniqueName]]
    set work $claim.work
    set candidate $claim.output
    file mkdir $work
    try {
        set source [file join $work source-stage]
        file mkdir $source
        extractControlledSources $tclArchive tcl9.0.4 tcl $source 1
        extractControlledSources $tkArchive tk9.0.4 tk $source 0
        set htmlOut [file join $work html]
        set converter [file join $source tcl9.0.4 tools tcltk-man2html.tcl]
        set result [run -timeout 30m -- $tclsh $converter --srcdir=$source --htmldir=$htmlOut --useversion=9.0.4]
        set converterOut "[encoding convertfrom utf-8 [dict get $result out]][encoding convertfrom utf-8 [dict get $result err]]"
        writeUtf8Lf [file join $work converter.stdout] $converterOut
        if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
            fail "upstream converter failed ([dict get $result exit])\n$converterOut"
        }
        if {[regexp -nocase {warn|error|ignored|couldn.t} $converterOut]} {
            fail "upstream converter reported a diagnostic\n$converterOut"
        }
        if {![regexp "(?n)^Rescanning 426 pages to build cross links and write out${S}*\$" $converterOut] ||
                ![regexp "(?n)^Done${S}*\$" $converterOut]} {
            fail "upstream converter progress did not confirm all 426 pages"
        }
        foreach {wing expected} {TclCmd 140 TclLib 108 TkCmd 89 TkLib 87 UserCmd 2} {
            set count [llength [lmap f [glob -nocomplain -directory [file join $htmlOut $wing] *.html] {
                if {[string equal -nocase [file rootname [file tail $f]] index]} continue
                set f
            }]]
            if {$count != $expected} {
                fail "converted $wing inventory is $count, expected $expected"
            }
        }

        file mkdir $candidate
        foreach dir {markdown source html licenses} {
            file mkdir [file join $candidate $dir]
        }
        # Every official HTML artifact, indexes, keyword pages and CSS
        # included, so cross-links stay useful after extraction.
        foreach item [glob -nocomplain -directory $htmlOut *] {
            file copy -force $item [file join $candidate html]
        }
        foreach {product rootName} {tcl tcl9.0.4 tk tk9.0.4} {
            set doc [file join $source $rootName doc]
            set dest [file join $candidate source $product doc]
            file mkdir $dest
            foreach file [glob -nocomplain -type f -directory $doc *] {
                if {[string tolower [file extension $file]] in {.1 .3 .n .macros .terms}} {
                    copyBytes $file [file join $dest [file tail $file]]
                }
            }
        }

        set documents [dict create]
        set aliases [dict create]
        set fragments [dict create]
        set htmlToId [dict create]
        set pageAnchors [dict create]
        set pages {}
        foreach product {tcl tk} {
            set doc [file join $candidate source $product doc]
            set files [lsort [lmap f [glob -nocomplain -type f -directory $doc *] {
                if {[string tolower [file extension $f]] ni {.1 .3 .n}} continue
                file tail $f
            }]]
            foreach name $files {
                set extension [string tolower [file extension $name]]
                set type [dict get {.n command .3 c-api .1 application} $extension]
                set wing [switch -- $product/$type {
                    tcl/command {format TclCmd}
                    tcl/c-api {format TclLib}
                    tk/command {format TkCmd}
                    tk/c-api {format TkLib}
                    default {format UserCmd}
                }]
                set base [file rootname $name]
                set id $product/$type/[string tolower $base]
                set htmlRel $wing/$base.html
                foreach page $pages {
                    if {[string equal -nocase [dict get $page id] $id]} {
                        fail "duplicate lowercased canonical ID $id"
                    }
                }
                set htmlPath [file join $candidate html $wing $base.html]
                if {![file isfile $htmlPath]} {
                    fail "official converter omitted $htmlRel for $name"
                }
                set html [readUtf8Strict $htmlPath]
                set inspect [inspectHtmlPage $html $htmlRel]
                dict set htmlToId $htmlRel $id
                dict set pageAnchors $id [dict get $inspect anchors]
                lappend pages [dict create product $product type $type base $base id $id source [file join $doc $name] \
                    sourceName $name htmlRel $htmlRel html $html inspect $inspect]
            }
        }
        set tclPages [llength [lmap p $pages {if {[dict get $p product] ne "tcl"} continue; set p}]]
        if {$tclPages != 249 || [llength $pages] - $tclPages != 177} {
            fail "internal page inventory drift"
        }

        foreach page $pages {
            dict with page {}
            set mdRel markdown/$product/$type/[string tolower $base].md
            set markdown [convertHtmlPage $html $htmlRel $id $inspect $htmlToId $pageAnchors]
            writeUtf8Lf [file join $candidate {*}[split $mdRel /]] $markdown
            set mdSections [markdownSections $markdown $mdRel]
            set htmlSections [htmlSections $html $inspect]
            set sourceText [readUtf8Strict $source]
            set srcSections [sourceSections $sourceText $sourceName]
            set srcRel source/$product/doc/$sourceName
            set formats [D \
                markdown [formatRecord $candidate $mdRel $mdSections] \
                html [formatRecord $candidate html/$htmlRel $htmlSections] \
                source [formatRecord $candidate $srcRel $srcSections]]
            set names [dict get $inspect names]
            dict set documents $id [D id [S $id] product [S $product] version [S 9.0.4] type [S $type] \
                title [S [lindex $names 0]] summary [S [dict get $inspect summary]] names [Ls $names] \
                sections [sectionsDict $mdSections 0] formats $formats path [S $mdRel] raw_path [S $srcRel] \
                source_file [S $sourceName] content_sha256 [S [get $formats markdown sha256]] \
                source_sha256 [S [get $formats source sha256]] bytes [N [get $formats markdown bytes]]]
            foreach alias [concat [list $id $base] $names [list "$product:[lindex $names 0]" "$product [lindex $names 0]"]] {
                addUnique aliases [normalizeSearch $alias] $id
            }
            dict for {old slug} [dict get $inspect anchors] {
                if {![dictHasNocase $fragments "$id#$slug"]} {
                    dict set fragments "$id#$slug" [D id [S $id] section [S $slug]]
                }
            }
        }

        # Authored command, index and agent pages.
        set authored {}
        foreach dir [list [file join $root docs reference machteld] [file join $root docs reference machteld command]] {
            foreach f [glob -nocomplain -type f -directory $dir *.md] {
                lappend authored [list [string map {/ \\} [file nativename $f]] $f]
            }
        }
        foreach pair [lsort -index 0 $authored] {
            set path [lindex $pair 1]
            set text [rewriteAuthoredLinks [readUtf8Strict $path] reference]
            set fm [frontMatter $text [file nativename $path]]
            set id [dict get $fm id]
            set relative [string range $id [string length machteld/] end]
            set mdRel markdown/machteld/$relative.md
            writeUtf8Lf [file join $candidate {*}[split $mdRel /]] $text
            set sections [markdownSections $text $id]
            set formats [D markdown [formatRecord $candidate $mdRel $sections]]
            set commands {}
            foreach c [split [dict get $fm commands] ,] {
                set c [netTrim $c]
                if {$c ne ""} {
                    lappend commands $c
                }
            }
            set names $commands; if {![llength $commands]} {set names [list [dict get $fm title]]}
            if {[dictHasNocase $documents $id]} {
                fail "duplicate authored ID $id"
            }
            dict set documents $id [D id [S $id] product [S machteld] version [S $version] type [S [dict get $fm type]] \
                title [S [dict get $fm title]] summary [S [dict get $fm summary]] names [Ls $names] \
                sections [sectionsDict $sections 0] formats $formats path [S $mdRel] raw_path [S ""] \
                source_file [S [file tail $path]] content_sha256 [S [get $formats markdown sha256]] \
                source_sha256 [S ""] bytes [N [get $formats markdown bytes]]]
            foreach alias [concat [list $id [dict get $fm title]] $commands] {
                addUnique aliases [normalizeSearch $alias] $id
            }
            foreach s $sections {
                set slug [dict get $s slug]
                if {$slug in {synopsis arguments-and-options results errors lifetime-and-timeouts examples constraints see-also}} {
                    continue
                }
                if {![dictHasNocase $fragments "$id#$slug"]} {
                    dict set fragments "$id#$slug" [D id [S $id] section [S $slug]]
                }
            }
        }
        foreach name [lsort [lmap f [glob -nocomplain -type f -directory [file join $root docs] *.md] {file tail $f}]] {
            set path [file join $root docs $name]
            set text [rewriteAuthoredLinks [readUtf8Strict $path] guide]
            set guide [guideMetadata $text [file nativename $path]]
            set base [file rootname $name]
            set id machteld/guide/$base
            set mdRel markdown/machteld/guide/$base.md
            writeUtf8Lf [file join $candidate {*}[split $mdRel /]] $text
            set title [dict get $guide metadata title]
            set summary [dict get $guide metadata description]
            set sections [markdownSections $text $id]
            set formats [D markdown [formatRecord $candidate $mdRel $sections]]
            dict set documents $id [D id [S $id] product [S machteld] version [S $version] type [S guide] \
                title [S $title] summary [S $summary] names [Ls [list $title]] sections [sectionsDict $sections 0] \
                formats $formats path [S $mdRel] raw_path [S ""] source_file [S $name] \
                content_sha256 [S [get $formats markdown sha256]] source_sha256 [S ""] bytes [N [get $formats markdown bytes]]]
            foreach alias [list $id $base $title] {
                addUnique aliases [normalizeSearch $alias] $id
            }
        }

        # A standalone extracted reference is itself a distribution.
        foreach {product file from title} [list \
                machteld Apache-2.0.txt [file join $root LICENSE] "Machteld Apache License 2.0" \
                tcl Tcl-9.0.4.txt [file join $root licenses Tcl-9.0.4.txt] "Tcl 9.0.4 license" \
                tk Tk-9.0.4.txt [file join $root licenses Tk-9.0.4.txt] "Tk 9.0.4 license"] {
            set rel licenses/$file
            copyBytes $from [file join $candidate licenses $file]
            assertNoSurrogates [readUtf8Strict [file join $candidate licenses $file]] $rel
            set formats [D markdown [formatRecord $candidate $rel {}] source [formatRecord $candidate $rel {}]]
            set id $product/license
            dict set documents $id [D id [S $id] product [S $product] \
                version [S [productVersion $product $version]] type [S license] title [S $title] \
                summary [S "Verbatim distribution notice for $product."] names [Ls [list $title]] sections [D] \
                formats $formats path [S $rel] raw_path [S $rel] source_file [S $file] \
                content_sha256 [S [get $formats markdown sha256]] source_sha256 [S [get $formats source sha256]] \
                bytes [N [get $formats markdown bytes]]]
            foreach alias [list $id "$product license" $title] {
                addUnique aliases [normalizeSearch $alias] $id
            }
        }

        set agentText [readUtf8Strict [file join $candidate markdown machteld agent.md]]
        set bootstrap [join {
            "# Machteld embedded reference: start here"
            ""
            "This directory is the complete offline reference for the exact Machteld, Tcl,"
            "and Tk versions that carried it.  The canonical query interface is `machteld"
            "docs`; read `markdown/machteld/agent.md` for the compact agent workflow."
            ""
            "`tcl/application/tclsh` and `tk/application/wish` reproduce upstream shell"
            "manuals.  They do not promise that Machteld's host accepts every tclsh or wish"
            "option.  `machteld/command/docs`, the Machteld host help, and entry-contract"
            "pages govern Machteld itself."
            ""
            "Corpus identity: see `catalog.dict`, `catalog.json`, and `manifest.sha256`."
            "Schema and response contracts: see `schema.json`."
        } \n]
        writeUtf8Lf [file join $candidate START-HERE.md] $bootstrap
        writeUtf8Lf [file join $candidate AGENTS.md] "$bootstrap\n---\n\n$agentText"
        foreach name {START-HERE.md AGENTS.md} {
            set text [readUtf8Strict [file join $candidate $name]]
            if {[string first \t $text] >= 0 || ![regexp -nocase "`machteld${S}+docs`" $text] ||
                    ![regexp -nocase {`tcl/application/tclsh`} $text] || ![regexp -nocase {`tk/application/wish`} $text] ||
                    ![regexp -nocase {`machteld/command/docs`} $text]} {
                fail "$name lost literal Markdown code spans or contains a tab"
            }
        }

        set schema [D schema [N 1] title [S "Machteld embedded reference schema"] generator [S $generator] \
            catalog [D \
                encoding [S "catalog.dict is inert canonical Tcl dict/list data; catalog.json is an equivalent JSON view"] \
                fields [Ls {aliases auxiliary corpus_sha256 documents fragments generator inventory machteld_version products schema search}] \
                document [S "id, product, version, type, title, summary, names, sections, formats; each format has path, sha256, bytes, and character-offset sections"] \
                ids [S "Canonical IDs are lowercase. Ordinary pages use product/type/name; Tcl/Tk names are lowercased source basenames. The only special two-part IDs are machteld/agent, machteld/index, machteld/license, tcl/license, and tk/license. Original spelling remains in names, aliases, and representation paths. Lowercased collisions fail generation."] \
                aliases [S "Unicode-lowercased, whitespace-collapsed keys map to ordered candidate ID lists; ambiguity is explicit and never silently resolved"]] \
            integrity [D \
                meaning [S "consistency and provenance identity, not cryptographic authenticity; there is no separately trusted compiled root hash"] \
                corpus_sha256 [S "SHA-256 of concatenated UTF-8 bytes path NUL lowercase-file-sha256 NUL for every ordinally sorted catalog inventory path"] \
                inventory_scope [S "all Markdown, HTML, source, license, bootstrap, and schema payload files; catalog/search/manifest files are excluded to avoid recursive hashes"] \
                manifest [S "manifest.sha256 hashes every pack file except itself, including catalog.dict, catalog.json, and search.dict"]] \
            formats [D markdown [S "normalized agent-readable Markdown"] html [S "verbatim output of the pinned upstream converter"] \
                source [S "verbatim upstream roff/manual source"]] \
            docs_host [D \
                routes [D full [Ls {{docs ...} {--docs ...}}] wrapped [Ls {{--machteld-docs ...}}]] \
                options [Ls {--json {--output FILE}}] \
                gui [S "--output FILE required except for extract"] \
                operations [Ls {status list schema verify get outline search extract}] \
                json_envelope [D success [D ok [B 1] result [S value]] \
                    failure [D ok [B 0] error [D domain [S DOCS] code [S code] message [S message]]]] \
                pagination [S "list/search return total, offset, limit, returned, truncated, next, and items"]]]
        writeUtf8Lf [file join $candidate schema.json] [jsonDeterministic $schema]

        # Every normalized catalog link, once the complete ID and fragment set exists.
        dict for {id record} $documents {
            if {![dict exists [get $record formats] markdown]} {
                continue
            }
            set mdPath [file join $candidate {*}[split [get $record formats markdown path] /]]
            if {[string tolower [file extension $mdPath]] ni {.md .txt}} {
                continue
            }
            set text [readUtf8Strict $mdPath]
            foreach {whole target} [regexp -all -inline {\[[^\]]+\]\(([^)]+)\)} $text] {
                if {[regexp {^[A-Za-z][A-Za-z0-9+.-]*:} $target]} {
                    continue
                }
                set hash [string first # $target]
                set base $target; if {$hash >= 0} {set base [string range $target 0 [expr {$hash - 1}]]}
                if {![dictHasNocase $documents $base]} {
                    fail "[get $record id] links to missing stable ID $target"
                }
                if {$hash >= 0 && ![dictHasNocase $fragments $target]} {
                    fail "[get $record id] links to missing stable fragment $target"
                }
            }
        }

        checkRepresentatives $candidate $documents

        set inventory [dict create]
        foreach pair [filesUnder $candidate] {
            lassign $pair rel path
            if {$rel in {catalog.dict catalog.json search.dict manifest.sha256}} {
                continue
            }
            set rel [normalizeSlashPath $rel]
            if {[dict exists $inventory $rel]} {
                fail "duplicate inventory path $rel"
            }
            dict set inventory $rel [D sha256 [S [sha256 $path]] bytes [N [file size $path]]]
        }
        set corpusHash [corpusHash $inventory]
        set represented [dict create]
        dict for {id record} $documents {
            dict for {name format} [get $record formats] {
                set path [normalizeSlashPath [get $format path]]
                if {![dict exists $inventory $path]} {
                    fail "document representation is absent from inventory: [get $record id] -> $path"
                }
                dict set represented $path 1
            }
        }
        set auxiliary [lsort [lmap path [dict keys $inventory] {
            if {[dict exists $represented $path]} continue
            set path
        }]]
        if {[dict size $represented] + [llength $auxiliary] != [dict size $inventory]} {
            fail "document/auxiliary partition does not exactly cover inventory"
        }
        set productCounts [dict create]
        foreach product {machteld tcl tk} {
            set catalogCount 0
            set manualCount 0
            dict for {id record} $documents {
                if {[string equal -nocase [get $record product] $product]} {
                    incr catalogCount
                    if {![string equal -nocase [get $record type] license]} {
                        incr manualCount
                    }
                }
            }
            if {($product eq "tcl" && $manualCount != 249) || ($product eq "tk" && $manualCount != 177)} {
                fail "$product manual page count drifted to $manualCount"
            }
            dict set productCounts $product [D version [S [productVersion $product $version]] \
                documents [N $catalogCount] manual_pages [N $manualCount]]
        }
        checkSchema $documents

        set searchDocs [dict create]
        foreach id [lsort [dict keys $documents]] {
            set r [dict get $documents $id]
            set text [readUtf8Strict [file join $candidate {*}[split [get $r formats markdown path] /]]]
            set searchText $text
            if {[string match -nocase machteld/guide/* [get $r id]]} {
                set searchText [dict get [guideMetadata $text [get $r formats markdown path]] body]
            }
            set priority [switch -nocase -- [get $r product]/[get $r type] {
                machteld/command {format 400} tcl/command {format 300} tk/command {format 250}
                machteld/guide {format 220} machteld/index {format 220} tcl/application {format 200}
                tk/application {format 200} tcl/c-api {format 100} tk/c-api {format 90} default {format 180}
            }]
            set snippets [dict create]
            set display [dict create]
            set spans [get $r formats markdown sections]
            dict for {slug heading} [get $r sections] {
                if {![dict exists $spans $slug]} {
                    continue
                }
                set start [get [dict get $spans $slug] start]
                set end [get [dict get $spans $slug] end]
                set plain [stripMarkdown [string range $text $start [expr {$end - 1}]]]
                if {[string length $plain] > 240} {
                    set plain "[netTrim [string range $plain 0 239]]..."
                }
                dict set display $slug [S $plain]
                dict set snippets $slug [S [normalizeSearch $plain]]
            }
            dict set searchDocs $id [D priority [N $priority] title [S [normalizeSearch [get $r title]]] \
                aliases [S [normalizeSearch [join [lmap n [get $r names] {lindex $n 1}] { }]]] \
                summary [S [normalizeSearch [get $r summary]]] body [S [normalizeSearch [stripMarkdown $searchText]]] \
                snippets [list D $snippets] display_snippets [list D $display]]
        }
        set search [D schema [N 1] normalization [S unicode-lower-whitespace-v1] documents [list D $searchDocs]]
        writeUtf8Lf [file join $candidate search.dict] "[tclData $search]\n"

        set searchPath [file join $candidate search.dict]
        set searchFacts [D path [S search.dict] sha256 [S [sha256 $searchPath]] bytes [N [file size $searchPath]]]
        set aliasNode [dict create]
        dict for {alias ids} $aliases {
            dict set aliasNode $alias [Ls $ids]
        }
        set catalog [D aliases [list D $aliasNode] auxiliary [Ls $auxiliary] corpus_sha256 [S $corpusHash] \
            documents [list D $documents] fragments [list D $fragments] generator [S $generator] \
            inventory [list D $inventory] machteld_version [S $version] products [list D $productCounts] \
            schema [N 1] search $searchFacts]
        writeUtf8Lf [file join $candidate catalog.dict] "[tclData $catalog]\n"
        writeUtf8Lf [file join $candidate catalog.json] [jsonDeterministic $catalog]

        set manifestLines [list "# machteld reference pack v1; SHA-256 consistency manifest (self excluded)"]
        foreach pair [filesUnder $candidate] {
            lassign $pair rel path
            if {$rel eq "manifest.sha256"} {
                continue
            }
            lappend manifestLines "[sha256 $path]  $rel"
        }
        writeUtf8Lf [file join $candidate manifest.sha256] "[join $manifestLines \n]\n"
        set rows [lmap row [split [readUtf8Strict [file join $candidate manifest.sha256]] \n] {
            if {$row eq ""} continue
            set row
        }]
        if {[llength $rows] != [llength $manifestLines] || [lindex $rows 0] ne [lindex $manifestLines 0]} {
            fail "manifest shape changed while writing"
        }

        # The inert catalog and search indexes, read back by the exact Tcl the
        # build uses.
        set validator [file join $work validate.tcl]
        set fixturePath [file join $work serializer-fixture.list]
        set fixture [list {} "a b" "a\t b" "a\n b" "a\v b" "a\f b" "a\r b" "a\u0001b" "a\u007fb" 00123 true \
            "na\u00efve \u03a9" [join [list {braces { and } brackets [ and ] dollars $ semicolon ; backslash} \\] { }]]
        writeUtf8Lf $fixturePath "[tclData [Ls $fixture]]\n"
        writeUtf8Lf $validator [validatorScript]
        set result [run -timeout 10m -- $tclsh $validator $candidate $fixturePath]
        if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
            fail "Tcl rejected generated inert indexes (exit [dict get $result exit]): [encoding convertfrom utf-8 [dict get $result err]]"
        }

        # A generated pack is immutable: the destination must be absent, so
        # publication is one rename and never replaces what another owns.
        if {[file exists $output]} {
            fail "output already exists; reference packs are immutable: [file nativename $output]"
        }
        file rename $candidate $output
        puts "reference: [dict size $documents] catalog documents; Tcl 249, Tk 177; corpus $corpusHash"
    } finally {
        if {!$keepWork} {
            file delete -force $work
            if {[file exists $candidate]} {
                file delete -force $candidate
            }
        }
    }
}

proc ::ref::validatorScript {} {
    return {if {[llength $argv] != 2} {error {usage: validate.tcl REFERENCE SERIALIZER-FIXTURE}}
set root [lindex $argv 0]
proc read_utf8 {path} {
    set ch [open $path r]
    fconfigure $ch -encoding utf-8 -translation lf
    try {return [read $ch]} finally {close $ch}
}
proc normalize {value} {
    return [string trim [regsub -all {\s+} [string tolower $value] { }]]
}
foreach name {catalog.dict search.dict} {
    set value [read_utf8 [file join $root $name]]
    if {[catch {dict size $value} message]} {error "$name is not inert dict data: $message"}
    if {[dict get $value schema] != 1} {error "$name schema is not 1"}
}
set c [read_utf8 [file join $root catalog.dict]]
set search [read_utf8 [file join $root search.dict]]
if {[dict size [dict get $c documents]] < 400} {error {catalog is unexpectedly small}}
if {![dict exists $c documents tcl/command/dict formats markdown]} {error {dict page is absent}}
dict for {alias candidates} [dict get $c aliases] {
    if {$alias ne [normalize $alias]} {error "Tcl normalization disagrees for alias: $alias"}
}
dict for {id fields} [dict get $search documents] {
    if {[lsort [dict keys $fields]] ne {aliases body display_snippets priority snippets summary title}} {
        error "search record fields disagree for $id"
    }
    set priority [dict get $fields priority]
    if {![string is integer -strict $priority] || $priority ni {400 300 250 220 200 180 100 90}} {
        error "search priority is not one canonical scalar integer for $id: $priority"
    }
    foreach field {title aliases summary body} {
        set value [dict get $fields $field]
        if {$value ne [normalize $value]} {error "Tcl normalization disagrees for $id $field"}
    }
    dict for {slug value} [dict get $fields snippets] {
        if {$value ne [normalize $value]} {error "Tcl normalization disagrees for $id snippet $slug"}
    }
}
# Serializer round-trip covers every Tcl list separator/control class plus
# numeric-looking and Unicode values independently of the production corpus.
set fixture [list {} "a b" "a\t b" "a\n b" "a\v b" "a\f b" "a\r b" \
    "a\u0001b" "a\u007fb" {00123} {true} "na\u00efve \u03a9"]
lappend fixture [join [list {braces { and } brackets [ and ] dollars $ semicolon ; backslash} \\] { }]
set encoded [string trimright [read_utf8 [lindex $argv 1]] \n]
if {[llength $encoded] != [llength $fixture]} {error {serializer fixture list shape changed}}
foreach actual $encoded expected $fixture {
    if {$actual ne $expected} {error {serializer fixture failed to round-trip}}
}
}
}

# The representative fidelity gates: prose, code, tables, C API, Tk widgets,
# and large syntax and index pages.
proc ::ref::checkRepresentatives {candidate documents} {
    variable S
    set read {{candidate documents id} {
        ::ref::readUtf8Strict [file join $candidate {*}[split [::ref::get [dict get $documents $id] path] /]]
    }}
    foreach id {tcl/command/dict tcl/command/chan tcl/command/http tcl/c-api/filesystem tk/command/text tk/command/canvas tk/command/keysyms} {
        if {![dict exists $documents $id]} {
            fail "representative page absent: $id"
        }
        set md [apply $read $candidate $documents $id]
        if {[string length $md] < 500 || ![regexp -nocase {(?n)^## (NAME|SYNOPSIS|DESCRIPTION)} $md]} {
            fail "representative normalization too small or sectionless: $id"
        }
        if {[regexp -nocase {</?(?:b|i|dl|dt|dd|table|tr|td|font)\y} $md]} {
            fail "representative normalization leaked HTML: $id"
        }
        set type [get [dict get $documents $id] type]
        set fence tcl; if {$type eq "c-api"} {set fence c} elseif {$type eq "application"} {set fence text}
        if {[regexp {(?n)^```} $md] && ![regexp -nocase "(?n)^```$fence${S}*\$" $md]} {
            fail "representative normalization has no $fence language fence: $id"
        }
    }
    set dict [readUtf8Strict [file join $candidate markdown tcl command dict.md]]
    if {![regexp -nocase "(?n)^## NAME${S}*\$" $dict] || ![regexp -nocase "(?n)^## SYNOPSIS${S}*\$" $dict]} {
        fail "dict normalization lost canonical heading/synopsis structure"
    }
    if {![regexp -nocase "(?n)^\\| .+ \\|${S}*\$" [readUtf8Strict [file join $candidate markdown tk command colors.md]]]} {
        fail "Tk colors normalization lost table structure"
    }
    foreach id {machteld/guide/index machteld/guide/overview} {
        if {![dict exists $documents $id]} {
            fail "authored guide absent: $id"
        }
        set summary [get [dict get $documents $id] summary]
        if {[regexp "^${S}*---" $summary] || [regexp -nocase "\\ytype:${S}" $summary]} {
            fail "$id summary leaked YAML front matter"
        }
    }
    dict for {id record} $documents {
        if {[get $record product] ni {tcl tk} || ![dict exists [get $record formats] markdown]} {
            continue
        }
        set md [readUtf8Strict [file join $candidate {*}[split [get $record formats markdown path] /]]]
        foreach section [markdownSections $md "$id quality scan"] {
            if {[dict get $section heading] eq ""} {
                fail "$id normalization contains an empty heading"
            }
        }
        if {[regexp "(?n)^-${S}*\$" $md]} {
            fail "$id normalization contains a dangling list marker"
        }
        set insideFence 0
        foreach line [split [string map [list \r ""] $md] \n] {
            if {[regexp "^${S}*(`{3,}|~{3,})" $line]} {
                set insideFence [expr {!$insideFence}]
                continue
            }
            if {$insideFence && [regexp -nocase {\[[^\]]+\]\((?:machteld|tcl|tk)/[^)]+\)} $line]} {
                fail "$id normalization rewrote a source-code link inside a fence"
            }
        }
        if {$insideFence} {
            fail "$id normalization left an unclosed code fence"
        }
    }
    foreach {id expected} {
        tcl/command/split {name synopsis description examples parsing-record-oriented-files see-also keywords}
        tk/command/text {name synopsis standard-options widget-specific-options description indices tags marks embedded-windows embedded-images the-selection the-insertion-cursor the-modified-flag the-undo-mechanism peer-widgets asynchronous-update-of-line-heights widget-command bindings known-issues issues-concerning-chars-and-indices performance-issues known-bugs see-also keywords}
        tcl/command/msgcat {name synopsis description commands locale-specification namespaces-and-message-catalogs location-and-format-of-message-files recommended-message-setup-for-packages positional-codes-for-format-and-scan-commands package-private-locale changing-package-options package-options callback-invocation object-oriented-programming examples credits see-also keywords}
    } {
        set actual [dict keys [get [dict get $documents $id] sections]]
        if {$actual ne $expected} {
            fail "$id outline contains fenced-code headings or lost semantic headings: [join $actual ,]"
        }
    }
    set linkPattern {\]\((?:machteld|tcl|tk)/[^)]+\)}
    set blocks [fencedCodeBlocks [readUtf8Strict [file join $candidate markdown tcl c-api adderrinfo.md]] "tcl/c-api/adderrinfo fence fidelity"]
    if {![llength [lmap b $blocks {if {[dict get $b language] ne "c" || ![regexp {Tcl_EvalEx\(interp, script, -1, 0\);} [dict get $b content]]} continue; set b}]] ||
            [llength [lmap b $blocks {if {![regexp -nocase $linkPattern [dict get $b content]]} continue; set b}]]} {
        fail "C normalization corrupted a copyable Tcl_EvalEx source signature inside a fence"
    }
    set blocks [fencedCodeBlocks [readUtf8Strict [file join $candidate markdown tcl command split.md]] "tcl/command/split fence fidelity"]
    if {![llength [lmap b $blocks {if {[dict get $b language] ne "tcl" || ![regexp -nocase "split${S}+\"comp\\.lang\\.tcl\"${S}+\\." [dict get $b content]]} continue; set b}]] ||
            [llength [lmap b $blocks {if {![regexp -nocase $linkPattern [dict get $b content]]} continue; set b}]]} {
        fail "Tcl normalization corrupted a copyable split command inside a fence"
    }
    foreach {id pattern} {
        tcl/command/interp {hidden command}
        tcl/command/mathfunc function
        tcl/command/mathop operator
        tcl/c-api/filesystem {## SEE ALSO.*\*\*\[cd\].*## KEYWORDS.*stat.*access}
        tcl/c-api/setchanerr channel
        tk/command/bind event
        tk/command/canvas canvas
        tk/command/colors {(?:alice blue|antique white)}
        tk/command/event event
        tk/command/font font
        tk/command/palette palette
        tk/command/ttk_combobox combobox
    } {
        if {![dict exists $documents $id]} {
            fail "implicit-table representative page absent: $id"
        }
        set md [readUtf8Strict [file join $candidate {*}[split [get [dict get $documents $id] formats markdown path] /]]]
        if {![regexp -nocase "(?n)^\\| .+ \\|${S}*\$" $md] || ![regexp -nocase $pattern $md]} {
            fail "$id normalization lost implicit table rows or trailing content"
        }
    }
}

# Every record and format has exactly schema 1's fields, and every section
# range lies inside its format.
proc ::ref::checkSchema {documents} {
    set recordKeys {bytes content_sha256 formats id names path product raw_path sections source_file source_sha256 summary title type version}
    set formatKeys {bytes characters path sections sha256}
    dict for {id record} $documents {
        if {[lsort [dict keys [lindex $record 1]]] ne $recordKeys} {
            fail "$id document fields do not match catalog schema 1"
        }
        dict for {formatName format} [get $record formats] {
            if {$formatName ni {markdown html source} || [lsort [dict keys [lindex $format 1]]] ne $formatKeys} {
                fail "$id $formatName format fields do not match catalog schema 1"
            }
            set priorStart 0
            dict for {slug range} [get $format sections] {
                if {![dict exists [get $record sections] $slug]} {
                    fail "$id $formatName has undeclared section $slug"
                }
                set start [get $range start]
                set end [get $range end]
                if {$start < 0 || $end < $start || $start < $priorStart || $end > [get $format characters]} {
                    fail "$id $formatName section $slug has invalid character bounds"
                }
                set priorStart $start
            }
        }
    }
}

# Only as the entry: another tool may load these procs.
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    try {
        ::ref::main $argv
    } trap {REFERENCE fail} {message} {
        puts stderr $message
        exit 1
    }
}
