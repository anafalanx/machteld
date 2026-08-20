# csv.tcl -- ::machteld::csv: CSV decoded to rows, rows encoded to CSV.
#
#   set rows [csv decode $text]                 ;# {{a b c} {d e f}}
#   set rows [csv decode $text -sep {;}]
#   set text [csv encode $rows]                 ;# minimal quoting, LF records
#   set text [csv encode $rows -eol crlf]
#
# A row is a Tcl list of fields; rows compose directly with `macht load`:
#
#   set h [macht load [csv decode $text] -schema {pad s status i bytes i}]
#
# THE CONTRACT IS A PORT, NOT AN INVENTION. Decode behavior is modeled on
# Text::CSV_XS (the CPAN reference implementation, H.Merijn Brand) with
# binary=1 and defaults, and was differential-tested against Text::CSV_XS
# 1.53 during development -- same rows out, same inputs refused. The
# behaviors that came from the oracle rather than from RFC 4180 reading:
#
#   - CR, LF, and CRLF are ALL record terminators (a bare \r ends a record);
#   - an empty line is a record with one empty field;
#   - a final record without a terminator is complete at end of input;
#   - a quote inside an unquoted field is refused (CSV_XS 2034), text after
#     a closing quote is refused (2023), and end-of-input inside a quoted
#     field is refused (2027) -- all as `{MACHTELD CSV parse}` here, with
#     the record and character position in the message.
#
# Inside a quoted field, separators, quotes-by-doubling, CR, LF, and CRLF
# are literal content. Decode is one forward scan that jumps with `string
# first` between special characters, so large unquoted stretches cost one
# search, not one test per character.
#
# ENCODE CLAIMS ROUND-TRIP, NOT BYTE-IDENTITY. Fields are quoted only when
# they contain the separator, a quote, CR, or LF (Text::CSV_XS also quotes
# spaces by default; that difference cannot change what a conforming reader
# decodes). The equivalence that is tested: `csv decode [csv encode $rows]`
# is $rows, and Text::CSV_XS decodes `csv encode $rows` to $rows.

proc ::machteld::csv {args} {
    if {![llength $args]} {
        Fail CSV usage "usage: csv decode text ?-sep char? | csv encode rows ?-sep char? ?-eol lf|crlf|cr?"
    }
    set sub [lindex $args 0]
    set rest [lrange $args 1 end]
    switch -- $sub {
        decode  { return [::machteld::CsvDecode $rest] }
        encode  { return [::machteld::CsvEncode $rest] }
        default { Fail CSV usage "csv: unknown subcommand \"$sub\": must be decode or encode" }
    }
}

# Shared option scan: one positional value, then option/value pairs drawn
# from $known. Returns {value optdict}.
proc ::machteld::CsvArgs {what argv known} {
    set value ""
    set haveValue 0
    set opts [dict create]
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {[string match -* $a] && $haveValue} {
            if {$a ni $known} { Fail CSV usage "csv $what: unknown option \"$a\"" }
            if {$i + 1 >= [llength $argv]} { Fail CSV usage "csv $what: option \"$a\" needs a value" }
            dict set opts $a [lindex $argv [incr i]]
        } elseif {!$haveValue} {
            set value $a
            set haveValue 1
        } else {
            Fail CSV usage "csv $what: unexpected argument \"$a\""
        }
    }
    if {!$haveValue} { Fail CSV usage "csv $what: missing argument" }
    return [list $value $opts]
}

proc ::machteld::CsvSep {what opts} {
    set sep ,
    if {[dict exists $opts -sep]} { set sep [dict get $opts -sep] }
    if {[string length $sep] != 1 || $sep in [list "\"" "\r" "\n"]} {
        Fail CSV badvalue "csv $what: -sep must be one character, not a quote or a line ending"
    }
    return $sep
}

proc ::machteld::CsvDecode {argv} {
    lassign [::machteld::CsvArgs decode $argv {-sep}] text opts
    set sep [::machteld::CsvSep decode $opts]

    set rows {}
    set n [string length $text]
    set pos 0
    set rec 1
    while {$pos < $n} {
        # One record: always at least one field, ended by CR/LF/CRLF or EOF.
        set fields {}
        set open 1
        while {$open} {
            if {[string index $text $pos] eq "\""} {
                # Quoted field: content runs quote to quote, "" is a literal ".
                set start $pos
                incr pos
                set field ""
                while 1 {
                    set q [string first "\"" $text $pos]
                    if {$q < 0} {
                        Fail CSV parse "csv decode: quoted field not terminated (record $rec, character [expr {$start + 1}])"
                    }
                    append field [string range $text $pos [expr {$q - 1}]]
                    set pos [expr {$q + 1}]
                    if {[string index $text $pos] eq "\""} {
                        append field "\""
                        incr pos
                        continue
                    }
                    break
                }
                lappend fields $field
                set c [string index $text $pos]
                if {$c eq $sep} {
                    incr pos
                } elseif {$c eq "\n"} {
                    incr pos
                    set open 0
                } elseif {$c eq "\r"} {
                    incr pos
                    if {[string index $text $pos] eq "\n"} { incr pos }
                    set open 0
                } elseif {$c eq ""} {
                    set open 0
                } else {
                    Fail CSV parse "csv decode: text after closing quote (record $rec, character [expr {$pos + 1}])"
                }
            } else {
                # Unquoted field: jump to the nearest special character.
                set best -1
                set bc ""
                foreach ch [list $sep "\"" "\r" "\n"] {
                    set i [string first $ch $text $pos]
                    if {$i >= 0 && ($best < 0 || $i < $best)} {
                        set best $i
                        set bc $ch
                    }
                }
                if {$best < 0} {
                    lappend fields [string range $text $pos end]
                    set pos $n
                    set open 0
                } elseif {$bc eq "\""} {
                    Fail CSV parse "csv decode: unescaped quote in unquoted field (record $rec, character [expr {$best + 1}])"
                } elseif {$bc eq $sep} {
                    lappend fields [string range $text $pos [expr {$best - 1}]]
                    set pos [expr {$best + 1}]
                } else {
                    lappend fields [string range $text $pos [expr {$best - 1}]]
                    set pos [expr {$best + 1}]
                    if {$bc eq "\r" && [string index $text $pos] eq "\n"} { incr pos }
                    set open 0
                }
            }
        }
        lappend rows $fields
        incr rec
    }
    return $rows
}

proc ::machteld::CsvEncode {argv} {
    lassign [::machteld::CsvArgs encode $argv {-sep -eol}] rows opts
    set sep [::machteld::CsvSep encode $opts]
    set eolName lf
    if {[dict exists $opts -eol]} { set eolName [dict get $opts -eol] }
    if {$eolName ni {lf crlf cr}} {
        Fail CSV badvalue "csv encode: -eol must be lf, crlf, or cr"
    }
    set eol [dict get {lf "\n" crlf "\r\n" cr "\r"} $eolName]

    if {[catch {llength $rows} nrows]} {
        Fail CSV badvalue "csv encode: rows must be a list of records"
    }
    set out ""
    set recno 0
    foreach row $rows {
        incr recno
        if {[catch {llength $row}]} {
            Fail CSV badvalue "csv encode: record $recno is not a list of fields"
        }
        set cooked {}
        foreach field $row {
            if {[string first $sep $field] >= 0 || [string first "\"" $field] >= 0 ||
                    [string first "\r" $field] >= 0 || [string first "\n" $field] >= 0} {
                lappend cooked "\"[string map [list "\"" "\"\""] $field]\""
            } else {
                lappend cooked $field
            }
        }
        append out [join $cooked $sep] $eol
    }
    return $out
}

::machteld::MetaDefine csv [dict create kind tcl args args domain CSV \
    codes {badvalue parse usage} options {-eol -sep} \
    doc machteld/command/csv]
