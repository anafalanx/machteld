package require machteld 30-

proc equal {got want label} {
    if {$got ne $want} {error "$label: expected [list $want], got [list $got]"}
}
proc fails {code args} {
    if {![catch [list ::machteld::intervals {*}$args] msg opts]} {
        error "accepted invalid call: $args"
    }
    equal [dict get $opts -errorcode] [list MACHTELD INTERVALS $code] $args
}
proc checkGaps {low high raw gaps} {
    set flat {}
    foreach gap $gaps {lappend flat {*}$gap}
    equal [intervals gaps $low $high $raw] $flat "flat gaps for $low..$high in $raw"
    equal [::machteld::intervals gaps -pairs $low $high $raw] $gaps "pair layout"
}

set min [expr {-(1 << 63)}]
set max [expr {(1 << 63) - 1}]
checkGaps $min $max {} [list [list $min $max]]
checkGaps $min $max [list $max $max $min $min] [list [list [expr {$min + 1}] [expr {$max - 1}]]]
checkGaps $min $max [list 0 $max $min -1] {}
checkGaps $min $min [list $max $max] [list [list $min $min]]
checkGaps $max $max [list $max $max] {}
checkGaps 1 10 {12 24 0 1 8 10 2 2 5 5 2 4 5 5} {{6 7}}
checkGaps 2 9 {0 0 12 15} {{2 9}}
checkGaps 1 9 {1 1 3 3 5 5 7 7 9 9} {{2 2} {4 4} {6 6} {8 8}}
checkGaps 0x0 0xA {0b0 0x2 0o4 0xA} {{3 3}}

foreach args [list {} {gaps} {gap 0 1 {}} {gaps -p 0 1 {}} {gaps 0 1 {} extra}] {
    fails usage {*}$args
}
foreach args [list {2 1 {}} {0 5 {3 2}} {0 5 {0 5 99 6}} {0 5 {0}} {0 5 {0 5 6 x}} \
        {0 NaN {}} {0 5 {1 2.0}} [list 0 5 \{] [list 0 [expr {$max + 1}] {}] \
        [list [expr {$min - 1}] 0 {}] [list 0 5 [list 0 [expr {2**64 - 1}]]]] {
    fails input gaps {*}$args
    fails input gaps -pairs {*}$args
}

# An independent occupancy oracle checks every subset of seven points.
# Feed covered intervals in reverse order and repeat overlapping runs.
for {set mask 0} {$mask < 128} {incr mask} {
    set raw {}
    for {set point 6} {$point >= 0} {incr point -1} {
        if {!($mask & (1 << $point))} continue
        lappend raw $point $point
        if {$point > 0 && ($mask & (1 << ($point - 1)))} {
            lappend raw [expr {$point - 1}] $point
        }
    }
    for {set low 0} {$low < 7} {incr low} {
        for {set high $low} {$high < 7} {incr high} {
            set expected {}
            set first {}
            for {set point $low} {$point <= $high} {incr point} {
                if {$mask & (1 << $point)} {
                    if {$first ne {}} {lappend expected [list $first [expr {$point - 1}]]}
                    set first {}
                } elseif {$first eq {}} {
                    set first $point
                }
            }
            if {$first ne {}} {lappend expected [list $first $high]}
            checkGaps $low $high $raw $expected
        }
    }
}

lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] packages application-compiler]
package require application-compiler 0.1
set module {
    export extern fn .gaps($lo:int, $hi:int, $spans:list<int>) -> list<int> = ['::machteld::intervals', 'gaps']
    export extern fn .pairs($lo:int, $hi:int, $spans:list<int>) -> list<list<int>> = ['::machteld::intervals', 'gaps', '-pairs']
}
set program [::appcompiler::compile [dict create intervals $module] ::intervalApp]
namespace eval :: [dict get $program script]
equal [::intervalApp::intervals::gaps 1 6 {3 4}] {1 2 5 6} "typed X flat call"
equal [::intervalApp::intervals::pairs 1 6 {3 4}] {{1 2} {5 6}} "typed X pair call"
puts "inclusive interval tests passed"
