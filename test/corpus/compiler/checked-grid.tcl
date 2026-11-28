package require machteld

# A second handwritten reference for the corpus grid. Every reached operation
# rounds to binary64, checks the finite range and normalizes zero. The standard
# corpus keeps its ordinary Tcl reference for the same finite inputs.
namespace eval ::checkedGrid {}
proc ::checkedGrid::finite {number} {
    if {abs($number) > 1.7976931348623157e308} {
        return -code error -errorcode {GRID OVERFLOW} "binary64 overflow"
    }
    return [expr {$number == 0.0 ? 0.0 : $number}]
}
proc ::checkedGrid::add {a b} {finite [expr {$a + $b}]}
proc ::checkedGrid::sub {a b} {finite [expr {$a - $b}]}
proc ::checkedGrid::mul {a b} {finite [expr {$a * $b}]}

proc ::checkedGrid::oscillator {steps x factor y bias} {
    set hits 0
    for {set i 0} {$i < $steps} {incr i} {
        if {[mul $x $factor] <= [add $y $bias]} {incr hits}
        set next [sub [mul $factor $x] $y]
        set y $x
        set x $next
    }
    return [list ok [dict create hits $hits x $x y $y]]
}
proc ::checkedGrid::stateBits {result} {
    lassign $result tag state
    if {$tag ne "ok" || [dict size $state] != 3} {error "unexpected oscillator state: $result"}
    set bits [binary encode hex [binary format Q2 [list [dict get $state x] [dict get $state y]]]]
    return [list [dict get $state hits] $bits]
}

proc ::checkedGrid::step {numerator denominator axis} {
    variable origins
    if {[catch {finite [expr {double($denominator)}]} divisor]} {
        return [list err [dict create code BINARY64_OVERFLOW message "conversion exceeds the finite binary64 range" \
            origin [dict get $origins $axis cast]]]
    }
    if {$divisor == 0.0} {
        return [list err [dict create code DIVIDE_BY_ZERO message "division by zero" origin [dict get $origins $axis divide]]]
    }
    # Every nonzero integer divisor has magnitude at least one.
    return [list ok [finite [expr {$numerator / $divisor}]]]
}

proc ::checkedGrid::grid {width height limit} {
    foreach name {width height limit} {
        set raw [set $name]
        if {![regexp {\A[+-]?[0-9]+\Z} $raw]} {
            return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} [format {expected int at $%s} $name]
        }
        scan $raw %lld $name
    }
    set horizontal [step 3.0 $width x]
    if {[lindex $horizontal 0] eq "err"} {return $horizontal}
    set vertical [step 2.0 $height y]
    if {[lindex $vertical 0] eq "err"} {return $vertical}
    set dx [lindex $horizontal 1]
    set dy [lindex $vertical 1]
    set total 0
    for {set y 0} {$y < $height} {incr y} {
        set cy [sub [mul [finite [expr {double($y)}]] $dy] 1.0]
        for {set x 0} {$x < $width} {incr x} {
            set cx [sub [mul [finite [expr {double($x)}]] $dx] 2.0]
            set zx 0.0
            set zy 0.0
            set count 0
            while {$count < $limit && [add [mul $zx $zx] [mul $zy $zy]] <= 4.0} {
                set nx [add [sub [mul $zx $zx] [mul $zy $zy]] $cx]
                set ny [add [mul [mul 2.0 $zx] $zy] $cy]
                set zx $nx
                set zy $ny
                incr count
            }
            incr total $count
        }
    }
    return [list ok $total]
}

set here [file dirname [file normalize [info script]]]
set timing 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [set flag [lindex $argv $i]] {
        --timings {set timing 1}
        --embedded {
            if {[info exists compiler]} {error "select the candidate compiler once"}
            set compiler [file join [::machteld::PayloadRoot] tcl_library application-compiler]
        }
        --compiler - --compare-with {
            if {[incr i] >= [llength $argv]} {error "$flag requires a compiler directory"}
            if {$flag eq "--compiler"} {
                if {[info exists compiler]} {error "select the candidate compiler once"}
                set compiler [lindex $argv $i]
            } else {set baseline [lindex $argv $i]; set timing 1}
        }
        default {error "usage: checked-grid.tcl ?--embedded | --compiler directory? ?--compare-with directory? ?--timings?"}
    }
}
if {![info exists compiler]} {set compiler [file join $here .. .. .. packages application-compiler]}
set ch [open [file join $here kernels.src] r]
try {chan configure $ch -encoding utf-8; set source [read $ch]} finally {close $ch}

# Identify the two observable failures in each grid dimension by their actual
# source columns. Width is converted and divided before height is converted.
set lines [split $source \n]
foreach axis {x y} {
    set i [lsearch -glob $lines [format {*$%sstep ::= *} $axis]]
    set sites [regexp -all -inline -indices {\?} [lindex $lines $i]]
    if {$i < 0 || [llength $sites] != 2} {error "unexpected ${axis}step source"}
    foreach name {cast divide} site $sites {
        dict set ::checkedGrid::origins $axis $name [dict create module kernels line [expr {$i+1}] column [expr {1+[lindex $site 0]}]]
    }
}
set versions [dict create X $compiler]
if {[info exists baseline]} {dict set versions baseline $baseline}
set functions [dict create checked ::checkedGrid::grid]
set oscillators [dict create checked ::checkedGrid::oscillator]
set oscillatorSource {export record .state {
    hits: int
    x: binary64
    y: binary64
}
export fn .run($steps: int, $a: binary64, $factor: binary64, $b: binary64, $bias: binary64) -> result<.state,problem> {
    $x := $a
    $y := $b
    $hits := 0
    for $i in 0..$steps {
        if ($x * $factor)? <= ($y + $bias)? { $hits = $hits + 1 }
        $next ::= (($factor * $x)? - $y)?
        $y = $x
        $x = $next
    }
    return ok(make<.state>(hits: $hits, x: $x, y: $y))
}}
dict for {name directory} $versions {
    set target ::program_$name
    set build [interp create]
    try {
        $build eval [list source -encoding utf-8 [file join $directory compiler.tcl]]
        set artifact [$build eval [list ::appcompiler::compile [dict create kernels $source oscillator $oscillatorSource] $target]]
    } finally {interp delete $build}
    namespace eval :: [dict get $artifact script]
    dict set functions $name ${target}::kernels::escape_grid
    dict set oscillators $name ${target}::oscillator::run
}
set oscillatorArgs {14000 0.125 0.875 0.75 0.25}
set expectedState [::checkedGrid::stateBits [::checkedGrid::oscillator {*}$oscillatorArgs]]
if {$expectedState ne {8449 bfbc41319ff252503fe4c4d050b1bd82}} {error "wrong reference oscillator state"}
dict for {name fn} $oscillators {
    if {[::checkedGrid::stateBits [$fn {*}$oscillatorArgs]] ne $expectedState} {error "$name wrong oscillator state"}
}
foreach {args count} {{4 3 8} 62 {1 1 5} 1 {+003 002 0} 0 {-1 2 7} 0 {32 24 32} 9714} {
    dict for {name fn} $functions {if {[$fn {*}$args] ne [list ok $count]} {error "$name wrong count for $args"}}
}
set huge [expr {10**400}]
foreach args [list {0 3 8} {3 0 8} [list $huge 0 0] [list 0 $huge 0] [list -1 $huge 0]] {
    set expected [::checkedGrid::grid {*}$args]
    if {[lindex $expected 0] ne "err"} {error "expected a checked failure"}
    dict for {name fn} $functions {
        lassign [$fn {*}$args] tag problem
        if {$tag ne "err"} {error "$name accepted invalid dimensions $args"}
        foreach path {code message {origin module} {origin line} {origin column}} {
            if {[dict get $problem {*}$path] ne [dict get [lindex $expected 1] {*}$path]} {
                error "$name wrong $path for $args"
            }
        }
    }
}
dict for {name fn} $functions {
    if {![catch {$fn 0 0 7.1} msg opts] || [dict get $opts -errorcode] ne {APPCOMPILER ARGUMENT TYPE}} {
        error "$name missed malformed limit before grid evaluation"
    }
}
foreach {op args bits} {
    mul {-5e-324 0.5} 0000000000000000
    mul {2.2250738585072014e-308 0.5} 0008000000000000
    add {1.0 1.1102230246251565e-16} 3ff0000000000000
} {
    if {[binary encode hex [binary format Q [::checkedGrid::$op {*}$args]]] ne $bits} {error "reference failed $op $args"}
}
if {![catch {::checkedGrid::mul 1.7976931348623157e308 2.0} msg opts] || [dict get $opts -errorcode] ne {GRID OVERFLOW}} {
    error "reference missed overflow"
}
if {!$timing} {puts "checked grid: results, errors, source locations, rounding and oscillator state passed"; return}

set orders {{checked X} {X checked}}
if {[info exists baseline]} {
    set orders {{checked X baseline} {X baseline checked} {baseline checked X}
                {checked baseline X} {baseline X checked} {X checked baseline}}
}
puts "round\tposition\timplementation\tmicroseconds_per_grid\tmicroseconds_per_oscillator"
for {set round 0} {$round < 12} {incr round} {
    set pos 0
    foreach name [lindex $orders [expr {$round % [llength $orders]}]] {
        set fn [dict get $functions $name]
        set us [lindex [time {set value [$fn 32 24 32]} 1] 0]
        if {$value ne {ok 9714}} {error "$name grid changed during timing"}
        set fn [dict get $oscillators $name]
        set oscUs [lindex [time {set state [$fn {*}$oscillatorArgs]} 1] 0]
        if {[::checkedGrid::stateBits $state] ne $expectedState} {error "$name oscillator changed during timing"}
        puts [join [list [expr {$round+1}] [incr pos] $name $us $oscUs] \t]
    }
}
