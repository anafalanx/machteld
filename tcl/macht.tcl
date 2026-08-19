# macht.tcl -- ::machteld::macht: serious calculation from plain Tcl.
#
#   set h [macht load $rows -schema {naam s pad s status i bytes i}]
#   macht sum {$bytes} where {$status == 404 && [string match "/api/*" $pad]} -data $h
#   macht count where {$bytes > 90000} -data $h -intent {sweep 50}
#
# The condition and the expression ARE Tcl: expr syntax, $fields from the
# declared schema, and a whitelist of commands. macht parses that surface,
# type-checks it against the schema, and generates TWO bodies from one AST:
#
#   - the Tcl arm is the user's own validated text, verbatim, inside the
#     standard loop -- perfect fidelity to Tcl semantics by construction;
#   - the Lua arm is compiled from the AST into the metered cell
#     (::machteld::LuaCell), or into the shard pool for -parallel.
#
# Before a Lua body is ever trusted, both arms run on a sample and must agree
# byte-for-byte -- and that same differential run IS the calibration that
# tells the router whether Lua earns its marshal (measured, never guessed).
#
# THE SEAM IS CLOSED (decision 2026-08-19): there is no way to hand macht Lua
# text, and constructs whose Tcl and Lua meanings diverge are REFUSED by
# name, never approximated:
#   - glob `?` and `[]` (character-wise in Tcl, byte-wise in Lua);
#   - `string length` (characters in Tcl, bytes in Lua) -- refused until a
#     byte-honest spelling is contracted;
#   - string ordering with < <= > >= (collation unspecified).
#
# Routing: -intent once (always the Tcl arm; a single shot never repays a
# marshal) | {sweep K} (buy the marshal when K times the measured saving
# exceeds it) | sandboxed (the metered cell, with -budget) | auto (default:
# ski-rental -- run Tcl and account the spend against the marshal price; when
# the rent reaches the price, calibrate, and promote only if the measured
# ratio clears the bar). -parallel shards the handle across the pool and
# reduces integer partials; sum and count are monoids, which is why that is
# sound. Every routing decision lands in `macht stats`.

namespace eval ::machteld::macht {
    variable RATIO_MIN 1.2
    variable MARSHAL_US_PER_ROW 0.9   ;# measured (reken, 2026-08-19): ~840ms/1M
    variable BUDGET_DEFAULT 100000000
    variable CAL [dict create]        ;# fingerprint -> {ratio R ttcl T}
    variable LOG {}
    variable HANDLES [dict create]    ;# data#N -> handle dict
    variable hn 0
    variable qn 0
    variable cell_open 0
    variable pool_n 0
}

# ---- errors ------------------------------------------------------------------
proc ::machteld::macht::Fail {code msg} {
    return -code error -errorcode [list MACHTELD MACHT $code] $msg
}

# ---- lexer over the Tcl-expr surface ----------------------------------------
# Produces {type value} tokens: num ident(field) str op call-open etc. The
# bracketed command forms are lexed as structured units so the whitelist is
# enforced at the token level, not discovered mid-parse.
proc ::machteld::macht::Lex {src} {
    set toks {}
    set i 0
    set n [string length $src]
    while {$i < $n} {
        set c [string index $src $i]
        if {[string is space $c]} { incr i; continue }
        if {$c eq "\$"} {
            incr i
            set j $i
            while {$j < $n && ([string is alnum [string index $src $j]]
                    || [string index $src $j] eq "_")} { incr j }
            if {$j == $i} { Fail parse "bare \$ without a field name" }
            lappend toks [list field [string range $src $i [expr {$j-1}]]]
            set i $j
            continue
        }
        if {[string is digit $c]} {
            set j $i
            while {$j < $n && [string is digit [string index $src $j]]} { incr j }
            lappend toks [list num [string range $src $i [expr {$j-1}]]]
            set i $j
            continue
        }
        if {$c eq "\""} {
            set j [string first "\"" $src [expr {$i+1}]]
            if {$j < 0} { Fail parse "unterminated string literal" }
            set v [string range $src [expr {$i+1}] [expr {$j-1}]]
            foreach {bad why} [list \\ backslash \$ substitution \[ command-substitution] {
                if {[string first $bad $v] >= 0} {
                    Fail refused "refused: $why inside a string literal"
                }
            }
            lappend toks [list str $v]
            set i [expr {$j+1}]
            continue
        }
        if {$c eq "\["} {
            set j [string first "\]" $src $i]
            if {$j < 0} { Fail parse "unterminated \[...\] command" }
            set body [string range $src [expr {$i+1}] [expr {$j-1}]]
            lappend toks [list cmd $body]
            set i [expr {$j+1}]
            continue
        }
        set matched 0
        foreach op {&& || == != <= >= < > + - * % ( ) !} {
            set l [string length $op]
            if {[string range $src $i [expr {$i+$l-1}]] eq $op} {
                lappend toks [list op $op]
                incr i $l
                set matched 1
                break
            }
        }
        if {$matched} { continue }
        if {[string is alpha $c]} {
            set j $i
            while {$j < $n && [string is alnum [string index $src $j]]} { incr j }
            set w [string range $src $i [expr {$j-1}]]
            if {$w eq "abs"} {
                lappend toks [list func abs]
                set i $j
                continue
            }
            Fail refused "refused: bare word '$w' (fields are \$-prefixed; only abs(...) and \[string match ...\] are known)"
        }
        Fail parse "unexpected character '$c'"
    }
    lappend toks [list eof ""]
    return $toks
}

# ---- parser: tokens -> typed AST ---------------------------------------------
# nodes: {num V} {str V} {field IDX NAME T} {bin OP L R} {cmp OP T L R}
#        {glob FIELDNODE PAT} {log OP L R} {not X} {abs X}
namespace eval ::machteld::macht {
    variable PT {}
    variable PP 0
    variable PSCHEMA {}
}
proc ::machteld::macht::Pk {} {
    variable PT; variable PP
    return [lindex $PT $PP]
}
proc ::machteld::macht::Nx {} {
    variable PT; variable PP
    set t [lindex $PT $PP]
    incr PP
    return $t
}
proc ::machteld::macht::Typeof {node} {
    switch -- [lindex $node 0] {
        num { return int }
        str { return str }
        field { return [lindex $node 3] }
        bin - abs { return int }
        default { return bool }
    }
}

proc ::machteld::macht::PField {name} {
    variable PSCHEMA
    set idx 0
    foreach {f t} $PSCHEMA {
        if {$f eq $name} {
            return [list field $idx $name [expr {$t eq "i" ? "int" : "str"}]]
        }
        incr idx
    }
    Fail type "unknown field \$$name (schema: [dict keys $PSCHEMA])"
}

proc ::machteld::macht::PCmdToken {body} {
    # Whitelisted bracketed commands. `string length` is refused BY NAME:
    # Tcl counts characters, Lua counts bytes, and 'café' must never have
    # two lengths depending on which arm won the route.
    if {[catch {llength $body}]} {
        Fail parse "unparseable \[...\] command"
    }
    set words $body
    if {[lindex $words 0] eq "string" && [lindex $words 1] eq "match"} {
        if {[llength $words] != 4} {
            Fail parse "\[string match ...\]: expected pattern and \$field"
        }
        set pat [lindex $words 2]
        set arg [lindex $words 3]
        foreach bad [list ? \[ \]] {
            if {[string first $bad $pat] >= 0} {
                Fail refused "refused: '$bad' in a match pattern -- character (Tcl) vs byte (Lua) semantics diverge; only '*' and literals"
            }
        }
        if {[string index $arg 0] ne "\$"} {
            Fail parse "\[string match ...\]: the subject must be a \$field"
        }
        set f [PField [string range $arg 1 end]]
        if {[lindex $f 3] ne "str"} {
            Fail type "\[string match ...\] needs a string field"
        }
        return [list glob $f $pat]
    }
    if {[lindex $words 0] eq "string" && [lindex $words 1] eq "length"} {
        Fail refused "refused: \[string length\] -- characters (Tcl) vs bytes (Lua); a byte-honest length is not contracted yet"
    }
    Fail refused "refused: \[[lindex $words 0] ...\] is not in the macht whitelist"
}

proc ::machteld::macht::PPrim {} {
    set t [Nx]
    lassign $t type val
    switch -- $type {
        num { return [list num $val] }
        str { return [list str $val] }
        field { return [PField $val] }
        cmd { return [PCmdToken $val] }
        func {
            if {[lindex [Pk] 1] ne "("} { Fail parse "abs needs (...)" }
            Nx
            set e [PExpr]
            if {[lindex [Nx] 1] ne ")"} { Fail parse "abs: missing )" }
            if {[Typeof $e] ne "int"} { Fail type "abs() takes an integer" }
            return [list abs $e]
        }
        op {
            if {$val eq "("} {
                set e [PExpr]
                if {[lindex [Nx] 1] ne ")"} { Fail parse "missing )" }
                return $e
            }
            if {$val eq "-"} {
                set e [PPrim]
                if {[Typeof $e] ne "int"} { Fail type "unary - takes an integer" }
                return [list bin - [list num 0] $e]
            }
            if {$val eq "!"} {
                set e [PPrim]
                if {[Typeof $e] ne "bool"} { Fail type "! takes a condition" }
                return [list not $e]
            }
        }
    }
    Fail parse "unexpected '$val'"
}
proc ::machteld::macht::PMul {} {
    set l [PPrim]
    while {[lindex [Pk] 0] eq "op" && [lindex [Pk] 1] in {* %}} {
        set op [lindex [Nx] 1]
        set r [PPrim]
        if {[Typeof $l] ne "int" || [Typeof $r] ne "int"} {
            Fail type "'$op' takes integers"
        }
        set l [list bin $op $l $r]
    }
    return $l
}
proc ::machteld::macht::PAdd {} {
    set l [PMul]
    while {[lindex [Pk] 0] eq "op" && [lindex [Pk] 1] in {+ -}} {
        set op [lindex [Nx] 1]
        set r [PMul]
        if {[Typeof $l] ne "int" || [Typeof $r] ne "int"} {
            Fail type "'$op' takes integers"
        }
        set l [list bin $op $l $r]
    }
    return $l
}
proc ::machteld::macht::PCmp {} {
    set l [PAdd]
    if {[lindex [Pk] 0] ne "op" || [lindex [Pk] 1] ni {== != < <= > >=}} {
        return $l
    }
    set op [lindex [Nx] 1]
    set r [PAdd]
    set lt [Typeof $l]
    set rt [Typeof $r]
    if {$lt ne $rt} { Fail type "comparing $lt with $rt" }
    if {$lt eq "bool"} { Fail type "cannot compare conditions" }
    if {$lt eq "str" && $op ni {== !=}} {
        Fail refused "refused: string ordering ('$op') -- collation unspecified"
    }
    return [list cmp $op $lt $l $r]
}
proc ::machteld::macht::PAnd {} {
    set l [PCmp]
    while {[lindex [Pk] 0] eq "op" && [lindex [Pk] 1] eq "&&"} {
        Nx
        set r [PCmp]
        if {[Typeof $l] ne "bool" || [Typeof $r] ne "bool"} {
            Fail type "'&&' takes conditions"
        }
        set l [list log and $l $r]
    }
    return $l
}
proc ::machteld::macht::PExpr {} {
    set l [PAnd]
    while {[lindex [Pk] 0] eq "op" && [lindex [Pk] 1] eq "||"} {
        Nx
        set r [PAnd]
        if {[Typeof $l] ne "bool" || [Typeof $r] ne "bool"} {
            Fail type "'||' takes conditions"
        }
        set l [list log or $l $r]
    }
    return $l
}
proc ::machteld::macht::Parse {src schema wantType what} {
    variable PT [Lex $src]
    variable PP 0
    variable PSCHEMA $schema
    set ast [PExpr]
    if {[lindex [Pk] 0] ne "eof"} {
        Fail parse "trailing input after $what: '[lindex [Pk] 1]'"
    }
    if {[Typeof $ast] ne $wantType} {
        Fail type "$what must be $wantType, is [Typeof $ast]"
    }
    return $ast
}

# ---- the Lua arm (the Tcl arm is the user's own text, verbatim) --------------
proc ::machteld::macht::LuaQuote {s} {
    return "\"[string map {\\ \\\\ \" \\\"} $s]\""
}
proc ::machteld::macht::GlobToLua {pat} {
    set out "^"
    foreach ch [split $pat ""] {
        if {$ch eq "*"} {
            append out ".*"
        } elseif {[string first $ch {^$()%.[]+-?}] >= 0} {
            append out "%" $ch
        } else {
            append out $ch
        }
    }
    return "$out$"
}
proc ::machteld::macht::El {n} {
    switch -- [lindex $n 0] {
        num { return [lindex $n 1] }
        str { return [LuaQuote [lindex $n 1]] }
        field { return [lindex $n 2] }
        bin { return "([El [lindex $n 2]] [lindex $n 1] [El [lindex $n 3]])" }
        cmp {
            set op [lindex $n 1]
            if {$op eq "!="} { set op "~=" }
            return "([El [lindex $n 3]] $op [El [lindex $n 4]])"
        }
        glob {
            return "(string.find([El [lindex $n 1]], [LuaQuote [GlobToLua [lindex $n 2]]]) ~= nil)"
        }
        log { return "([El [lindex $n 2]] [lindex $n 1] [El [lindex $n 3]])" }
        not { return "(not [El [lindex $n 1]])" }
        abs { return "(math.abs([El [lindex $n 1]]))" }
    }
}
proc ::machteld::macht::LuaSrc {name fields kind exprAst condAst} {
    if {$kind eq "sum"} {
        set act "acc = acc + ([El $exprAst])"
    } else {
        set act "acc = acc + 1"
    }
    set cond [El $condAst]
    set unpack {}
    for {set i 0} {$i < [llength $fields]} {incr i} {
        lappend unpack "r\[[expr {$i+1}]\]"
    }
    return "function ${name}(rows)\n  local acc = 0\n  for __i = 1, #rows do\n    local r = rows\[__i\]\n    local [join $fields ,] = [join $unpack ,]\n    if $cond then $act end\n  end\n  return acc\nend"
}
proc ::machteld::macht::TclArm {name fields kind exprText condText} {
    # The user's validated text runs verbatim: whatever Tcl meant, Tcl gets.
    if {$kind eq "sum"} {
        set act "incr acc \[expr {$exprText}\]"
    } else {
        set act "incr acc"
    }
    set body "set acc 0\nforeach __r \$rows {\n    lassign \$__r [join $fields { }]\n    if {$condText} { $act }\n}\nreturn \$acc"
    proc ::machteld::macht::$name {rows} $body
    return ::machteld::macht::$name
}

# ---- handles -----------------------------------------------------------------
proc ::machteld::macht::NeedHandle {token} {
    variable HANDLES
    if {![dict exists $HANDLES $token]} {
        Fail badvalue "unknown data handle '$token'"
    }
    return [dict get $HANDLES $token]
}
proc ::machteld::macht::MarshalEstMs {n} {
    variable MARSHAL_US_PER_ROW
    return [expr {$n * $MARSHAL_US_PER_ROW / 1000.0}]
}
proc ::machteld::macht::Note {fp route ms note} {
    variable LOG
    lappend LOG [list $fp $route [format %.1f $ms] $note]
}
proc ::machteld::macht::EnsureCell {} {
    variable cell_open
    if {!$cell_open} {
        ::machteld::LuaCell open 256
        set cell_open 1
    }
}
proc ::machteld::macht::EnsurePool {want} {
    variable pool_n
    if {$pool_n == 0} {
        set pool_n [::machteld::LuaCell popen $want 256]
    }
    return $pool_n
}

proc ::machteld::macht::CmdLoad {argv} {
    variable HANDLES; variable hn
    if {[llength $argv] != 3 || [lindex $argv 1] ne "-schema"} {
        Fail badvalue "usage: macht load rows -schema {field type ...}"
    }
    lassign $argv rows _ schema
    if {[llength $schema] == 0 || [llength $schema] % 2} {
        Fail badvalue "schema must be a non-empty {field type ...} dict"
    }
    set fields {}
    set types {}
    foreach {f t} $schema {
        if {$t ni {i s}} { Fail badvalue "field '$f': type must be i or s" }
        lappend fields $f
        lappend types $t
    }
    set nf [llength $fields]
    foreach r $rows {
        if {[llength $r] != $nf} {
            Fail badvalue "a row has [llength $r] fields; schema has $nf"
        }
    }
    set token data#[incr hn]
    dict set HANDLES $token [dict create rows $rows schema $schema \
        fields $fields types $types n [llength $rows] \
        marshalled 0 pmarshalled 0 spent 0.0]
    return $token
}

proc ::machteld::macht::Calibrate {fp h tclArm luaName kind exprAst condAst fields} {
    variable CAL
    EnsureCell
    set rows [dict get $h rows]
    set n [dict get $h n]
    if {[dict get $h marshalled]} {
        set sample $rows
        set scale 1.0
    } else {
        set take [expr {min(10000, $n)}]
        set sample [lrange $rows 0 [expr {$take - 1}]]
        set scale [expr {$take > 0 ? double($n) / $take : 1.0}]
        ::machteld::LuaCell loadtable $sample [dict get $h types]
    }
    set t0 [clock microseconds]
    set rt [$tclArm $sample]
    set t1 [clock microseconds]
    set rl [::machteld::LuaCell call $luaName]
    set t2 [clock microseconds]
    if {$rt != $rl} {
        Fail state "ORACLE: the arms disagree ($rt vs $rl) for {$fp} -- refusing the route"
    }
    set ttcl [expr {($t1 - $t0) / 1000.0}]
    set tlua [expr {max(0.001, ($t2 - $t1) / 1000.0)}]
    set ratio [expr {$ttcl / $tlua}]
    dict set CAL $fp [dict create ratio $ratio ttcl [expr {$ttcl * $scale}]]
    Note $fp calibrate [expr {$ttcl + $tlua}] "oracle equal; ratio [format %.1f $ratio]x"
    return $ratio
}

# ---- the router --------------------------------------------------------------
proc ::machteld::macht::Run {kind exprText condText argv} {
    variable HANDLES; variable CAL; variable RATIO_MIN
    variable BUDGET_DEFAULT; variable qn

    set token ""
    set intent auto
    set budget 0
    set parallel 0
    foreach {o v} $argv {
        switch -- $o {
            -data { set token $v }
            -intent { set intent $v }
            -budget { set budget $v }
            -parallel { set parallel $v }
            default { Fail badvalue "unknown option $o" }
        }
    }
    if {$token eq ""} { Fail badvalue "-data handle is required" }
    if {$parallel ne "" && $parallel != 0} {
        if {$intent eq "sandboxed"} {
            Fail badvalue "sandboxed runs in the metered cell; -parallel does not combine with it"
        }
        if {$parallel ne "auto" && !([string is integer -strict $parallel]
                && $parallel > 0)} {
            Fail badvalue "-parallel takes auto or a positive state count"
        }
    }
    set h [NeedHandle $token]
    set fields [dict get $h fields]
    set schema [dict get $h schema]
    set n [dict get $h n]

    # One AST; the Tcl arm is the user's text, the Lua arm is generated.
    set condAst [Parse $condText $schema bool "the where condition"]
    set exprAst {}
    if {$kind eq "sum"} {
        set exprAst [Parse $exprText $schema int "the sum expression"]
    }
    set fp [list $kind $exprText $condText [dict get $h schema]]
    incr qn
    set tclArm [TclArm __m_tcl$qn $fields $kind $exprText $condText]
    set luaName __m_lua$qn
    set luaReady 0

    set rows [dict get $h rows]

    # Parallel is explicit: shard the handle across the pool, reduce partials.
    if {$parallel ne "" && $parallel != 0} {
        set want [expr {$parallel eq "auto" ? 0 : $parallel}]
        set np [EnsurePool $want]
        set src [LuaSrc $luaName $fields $kind $exprAst $condAst]
        ::machteld::LuaCell pcompile $luaName $src
        if {![dict get $h pmarshalled]} {
            set t0 [clock microseconds]
            ::machteld::LuaCell pmarshal $rows [dict get $h types]
            set dt [expr {([clock microseconds] - $t0) / 1000.0}]
            dict set HANDLES $token pmarshalled 1
            set h [dict get $HANDLES $token]
            Note $fp pmarshal $dt "sharded across $np states"
        }
        # The pool result must equal the Tcl arm; prove it on a sample once
        # per fingerprint (the pool shares the single-state emitters, so the
        # cell calibration covers the codegen; this checks the reduce).
        set t0 [clock microseconds]
        set parts [::machteld::LuaCell pcall $luaName]
        set r 0
        foreach p $parts { incr r $p }
        set dt [expr {([clock microseconds] - $t0) / 1000.0}]
        if {![dict exists $CAL [list par $fp]]} {
            set rt [$tclArm $rows]
            if {$rt != $r} {
                Fail state "ORACLE: parallel reduce disagrees with the Tcl arm ($r vs $rt)"
            }
            dict set CAL [list par $fp] [dict create ratio checked ttcl 0]
            Note $fp oracle 0 "parallel reduce equals the Tcl arm"
        }
        Note $fp lua-par $dt "$np partials reduced"
        return $r
    }

    switch -glob -- $intent {
        sandboxed {
            EnsureCell
            set src [LuaSrc $luaName $fields $kind $exprAst $condAst]
            ::machteld::LuaCell compile $luaName $src
            if {![dict get $h marshalled]} {
                set t0 [clock microseconds]
                ::machteld::LuaCell loadtable $rows [dict get $h types]
                Note $fp marshal [expr {([clock microseconds] - $t0) / 1000.0}] \
                    "sandbox intent pays the marshal"
                dict set HANDLES $token marshalled 1
            }
            if {$budget == 0} { set budget $BUDGET_DEFAULT }
            set t0 [clock microseconds]
            set r [::machteld::LuaCell call $luaName $budget]
            Note $fp lua-cell [expr {([clock microseconds] - $t0) / 1000.0}] "budget $budget"
            return $r
        }
        once {
            set t0 [clock microseconds]
            set r [$tclArm $rows]
            Note $fp tcl [expr {([clock microseconds] - $t0) / 1000.0}] "once"
            return $r
        }
        sweep* {
            set K [lindex $intent 1]
            if {![string is integer -strict $K] || $K < 1} {
                Fail badvalue "-intent {sweep K}: K must be a positive integer"
            }
            set cached [expr {[dict exists $CAL $fp] ? [dict get $CAL $fp ratio] : ""}]
            if {$cached eq ""} {
                set src [LuaSrc $luaName $fields $kind $exprAst $condAst]
                EnsureCell
                ::machteld::LuaCell compile $luaName $src
                set luaReady 1
                set cached [Calibrate $fp $h $tclArm $luaName $kind $exprAst $condAst $fields]
                set h [dict get $HANDLES $token]
            }
            set ttcl [dict get $CAL $fp ttcl]
            set save [expr {$K * $ttcl * (1.0 - 1.0 / $cached)}]
            if {$cached >= $RATIO_MIN && $save > [MarshalEstMs $n]
                    && ![dict get $h marshalled]} {
                if {!$luaReady} {
                    EnsureCell
                    ::machteld::LuaCell compile $luaName \
                        [LuaSrc $luaName $fields $kind $exprAst $condAst]
                    set luaReady 1
                }
                set t0 [clock microseconds]
                ::machteld::LuaCell loadtable $rows [dict get $h types]
                Note $fp marshal [expr {([clock microseconds] - $t0) / 1000.0}] \
                    "sweep $K: projected saving [format %.0f $save] ms"
                dict set HANDLES $token marshalled 1
                set h [dict get $HANDLES $token]
            }
            if {[dict get $h marshalled] && $cached >= $RATIO_MIN} {
                if {!$luaReady} {
                    EnsureCell
                    ::machteld::LuaCell compile $luaName \
                        [LuaSrc $luaName $fields $kind $exprAst $condAst]
                }
                set t0 [clock microseconds]
                set r [::machteld::LuaCell call $luaName]
                Note $fp lua [expr {([clock microseconds] - $t0) / 1000.0}] "sweep"
                return $r
            }
            set t0 [clock microseconds]
            set r [$tclArm $rows]
            Note $fp tcl [expr {([clock microseconds] - $t0) / 1000.0}] "sweep, tcl wins"
            return $r
        }
        auto {
            set cached [expr {[dict exists $CAL $fp] ? [dict get $CAL $fp ratio] : ""}]
            if {[dict get $h marshalled]} {
                if {$cached eq ""} {
                    EnsureCell
                    ::machteld::LuaCell compile $luaName \
                        [LuaSrc $luaName $fields $kind $exprAst $condAst]
                    set luaReady 1
                    set cached [Calibrate $fp $h $tclArm $luaName $kind $exprAst $condAst $fields]
                    set h [dict get $HANDLES $token]
                }
                if {$cached >= $RATIO_MIN} {
                    if {!$luaReady} {
                        EnsureCell
                        ::machteld::LuaCell compile $luaName \
                            [LuaSrc $luaName $fields $kind $exprAst $condAst]
                    }
                    set t0 [clock microseconds]
                    set r [::machteld::LuaCell call $luaName]
                    Note $fp lua [expr {([clock microseconds] - $t0) / 1000.0}] "resident"
                    return $r
                }
            }
            set t0 [clock microseconds]
            set r [$tclArm $rows]
            set dt [expr {([clock microseconds] - $t0) / 1000.0}]
            set spent [expr {[dict get $h spent] + $dt}]
            dict set HANDLES $token spent $spent
            Note $fp tcl $dt \
                "ski: spent [format %.0f $spent] of [format %.0f [MarshalEstMs $n]] ms"
            if {$spent >= [MarshalEstMs $n] && ![dict get $h marshalled]} {
                if {$cached eq ""} {
                    EnsureCell
                    ::machteld::LuaCell compile $luaName \
                        [LuaSrc $luaName $fields $kind $exprAst $condAst]
                    set cached [Calibrate $fp $h $tclArm $luaName $kind $exprAst $condAst $fields]
                }
                if {$cached >= $RATIO_MIN} {
                    set t0 [clock microseconds]
                    ::machteld::LuaCell loadtable $rows [dict get $h types]
                    Note $fp marshal [expr {([clock microseconds] - $t0) / 1000.0}] \
                        "ski-rental bought: ratio [format %.1f $cached]x"
                    dict set HANDLES $token marshalled 1
                }
            }
            return $r
        }
        default {
            Fail badvalue "unknown -intent '$intent' (once, {sweep K}, sandboxed, auto)"
        }
    }
}

# ---- the public verb ---------------------------------------------------------
proc ::machteld::macht {sub args} {
    switch -- $sub {
        load { return [::machteld::macht::CmdLoad $args] }
        sum {
            if {[llength $args] < 3 || [lindex $args 1] ne "where"} {
                ::machteld::macht::Fail badvalue \
                    "usage: macht sum {expr} where {cond} -data handle ?options?"
            }
            return [::machteld::macht::Run sum [lindex $args 0] \
                [lindex $args 2] [lrange $args 3 end]]
        }
        count {
            if {[llength $args] < 2 || [lindex $args 0] ne "where"} {
                ::machteld::macht::Fail badvalue \
                    "usage: macht count where {cond} -data handle ?options?"
            }
            return [::machteld::macht::Run count "" \
                [lindex $args 1] [lrange $args 2 end]]
        }
        info {
            set h [::machteld::macht::NeedHandle [lindex $args 0]]
            return [dict create n [dict get $h n] \
                schema [dict get $h schema] \
                marshalled [dict get $h marshalled] \
                pmarshalled [dict get $h pmarshalled] \
                spent_ms [format %.1f [dict get $h spent]]]
        }
        close {
            variable ::machteld::macht::HANDLES
            ::machteld::macht::NeedHandle [lindex $args 0]
            dict unset ::machteld::macht::HANDLES [lindex $args 0]
            return
        }
        stats {
            return $::machteld::macht::LOG
        }
        reset {
            set ::machteld::macht::HANDLES [dict create]
            set ::machteld::macht::CAL [dict create]
            set ::machteld::macht::LOG {}
            catch {::machteld::LuaCell close}
            catch {::machteld::LuaCell pclose}
            set ::machteld::macht::cell_open 0
            set ::machteld::macht::pool_n 0
            return
        }
        default {
            ::machteld::macht::Fail badvalue \
                "unknown subcommand '$sub' (load, sum, count, info, close, stats, reset)"
        }
    }
}

# One verb, wrap's shape: the operation forms (load / sum / count / info /
# close / stats / reset) are documented prose, not manifest subcommand
# claims -- adding those later means adding their full per-subcommand
# reference apparatus (anchors, sections, doc ids), the way child does it.
::machteld::MetaDefine macht [dict create kind tcl args args domain MACHT \
    codes {badvalue parse type refused state call thread} \
    options {-data -intent -budget -parallel -schema} \
    doc machteld/command/macht]
