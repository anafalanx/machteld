# Focused macht contract tests: refusals by name, arms agreeing byte-for-byte,
# routes landing where declared, and the metered cell's guarantees.

package require machteld

set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc errcode_of {script} {
    if {[catch {uplevel 1 $script} message options] == 0} { return {} }
    return [dict get $options -errorcode]
}
proc lastroute {} {
    set e [lindex [macht stats] end]
    return [lindex $e 1]
}

# ---- fixture: small, hostile on purpose (unicode, empty strings, zeros) ------
set SCHEMA {naam s pad s status i bytes i a i b i c i}
set ROWS {}
for {set i 0} {$i < 4000} {incr i} {
    set naam [expr {$i % 97 == 0 ? "café-é$i" : "file$i"}]
    set pad [lindex {/api/users /api/orders /web/home /static/js} [expr {$i % 4}]]
    set status [lindex {200 200 404 500} [expr {$i % 4}]]
    lappend ROWS [list $naam $pad $status [expr {$i * 7 % 100000}] \
        [expr {$i % 1000}] [expr {($i * 3) % 1000}] [expr {$i % 97}]]
}
lappend ROWS {{} {} 404 0 0 0 0}
lappend ROWS {ééé /api/x 404 99999 999 999 96}

macht reset
set H [macht load $ROWS -schema $SCHEMA]
check "load returns a data token" [string match data#* $H]
check "info reports the row count" \
    [expr {[dict get [macht info $H] n] == [llength $ROWS]}]

# ---- refusals, each by name --------------------------------------------------
check "glob ? is refused" [string match {MACHTELD MACHT refused} \
    [errcode_of {macht count where {[string match "a?c" $naam]} -data $H}]]
check "string length is refused" [string match {MACHTELD MACHT refused} \
    [errcode_of {macht sum {[string length $naam]} where {$status == 200} -data $H}]]
check "string ordering is refused" [string match {MACHTELD MACHT refused} \
    [errcode_of {macht count where {$naam < "x"} -data $H}]]
check "unknown bracketed command is refused" [string match {MACHTELD MACHT refused} \
    [errcode_of {macht count where {[regexp {x} $naam]} -data $H}]]
check "bare words are refused" [string match {MACHTELD MACHT refused} \
    [errcode_of {macht count where {status == 404} -data $H}]]
check "backslash in a literal is refused" [string match {MACHTELD MACHT refused} \
    [errcode_of {macht count where {$naam == "a\\b"} -data $H}]]
check "unknown field is a type error" [string match {MACHTELD MACHT type} \
    [errcode_of {macht count where {$zzz == 1} -data $H}]]
check "int/string mix is a type error" [string match {MACHTELD MACHT type} \
    [errcode_of {macht count where {$status == "x"} -data $H}]]
check "trailing input is a parse error" [string match {MACHTELD MACHT parse} \
    [errcode_of {macht count where {$status == 404 404} -data $H}]]
check "unknown handle is badvalue" [string match {MACHTELD MACHT badvalue} \
    [errcode_of {macht count where {$status == 404} -data data#999}]]
check "sandboxed with -parallel is refused" [string match {MACHTELD MACHT badvalue} \
    [errcode_of {macht count where {$status == 404} -data $H \
        -intent sandboxed -parallel auto}]]

# ---- the arms agree, route by route ------------------------------------------
set Q1SUM {$bytes}
set Q1WHERE {$status == 404 && [string match "/api/*" $pad]}
set r_tcl [macht sum $Q1SUM where $Q1WHERE -data $H -intent once]
check "once routes to the tcl arm" [expr {[lastroute] eq "tcl"}]
set r_cell [macht sum $Q1SUM where $Q1WHERE -data $H -intent sandboxed]
check "sandboxed routes to the metered cell" [expr {[lastroute] eq "lua-cell"}]
check "cell arm equals the tcl arm" [expr {$r_cell == $r_tcl}]
set r_par [macht sum $Q1SUM where $Q1WHERE -data $H -parallel 4]
check "parallel routes to the pool" [expr {[lastroute] eq "lua-par"}]
check "pool reduce equals the tcl arm" [expr {$r_par == $r_tcl}]

set c_tcl [macht count where {[string match "*é*" $naam]} -data $H -intent once]
set c_cell [macht count where {[string match "*é*" $naam]} -data $H -intent sandboxed]
set c_par [macht count where {[string match "*é*" $naam]} -data $H -parallel 4]
check "unicode glob agrees across all three arms" \
    [expr {$c_tcl == $c_cell && $c_cell == $c_par && $c_tcl > 0}]

set m_tcl [macht sum {($a * $b + $c) % 97} where {$status < 500} -data $H -intent once]
set m_cell [macht sum {($a * $b + $c) % 97} where {$status < 500} -data $H -intent sandboxed]
check "arithmetic agrees between the arms" [expr {$m_tcl == $m_cell}]
set m_abs [macht sum {abs($a - $b)} where {$status != 200} -data $H -intent once]
set m_abs2 [macht sum {abs($a - $b)} where {$status != 200} -data $H -intent sandboxed]
check "abs() agrees between the arms" [expr {$m_abs == $m_abs2}]

# ---- auto calibrates with the oracle riding along ----------------------------
macht sum $Q1SUM where {$status >= 400} -data $H
set sawcal 0
foreach e [macht stats] {
    if {[lindex $e 1] eq "calibrate" && [string match "*oracle equal*" [lindex $e 3]]} {
        set sawcal 1
    }
}
check "auto calibration ran with the oracle" $sawcal

# ---- the metered cell's guarantees (via the private primitive) ---------------
check "a tiny budget stops a large kernel" [string match {MACHTELD MACHT call} \
    [errcode_of {macht sum $Q1SUM where {$status == 404} -data $H \
        -intent sandboxed -budget 200}]]
::machteld::LuaCell open 16
::machteld::LuaCell loadtable {} {s}
::machteld::LuaCell compile __bomb \
    "function __bomb(rows)\n  local t = {}\n  local i = 1\n  while true do t\[i\] = string.rep(\"x\", 4096) i = i + 1 end\nend"
check "the allocator cap stops a memory bomb" [string match {MACHTELD MACHT call} \
    [errcode_of {::machteld::LuaCell call __bomb}]]
::machteld::LuaCell open 64
::machteld::LuaCell loadtable {} {s}
::machteld::LuaCell compile __chk "function __chk(rows) return tostring(os) .. tostring(io) end"
check "io and os are absent from the cell" \
    [expr {[::machteld::LuaCell call __chk] eq "nilnil"}]

# ---- lifecycle ---------------------------------------------------------------
macht close $H
check "a closed handle is refused" [string match {MACHTELD MACHT badvalue} \
    [errcode_of {macht info $H}]]
macht reset
check "reset leaves no routes" [expr {[llength [macht stats]] == 0}]

if {$fails} { puts "FAILED $fails macht tests"; exit 1 }
puts "ALL MACHT TESTS PASSED"
exit 0
