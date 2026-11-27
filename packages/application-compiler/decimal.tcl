# Both the compiler and the generated application install these procedures in
# their own decimal namespace. A fixed-point value is coefficient / 10**scale.
proc parts {value} {
    if {![regexp {\A([+-]?)([0-9]+)(?:\.([0-9]+))?\Z} $value -> sign whole fraction]} {
        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected a fixed-point decimal"
    }
    set fraction [string trimright $fraction 0]
    # Strip leading zeroes before Tcl arithmetic can interpret them as octal.
    set digits [string trimleft $whole$fraction 0]
    if {$digits eq {}} { return {0 0} }
    if {$sign eq "-"} { set digits -$digits }
    return [list $digits [string length $fraction]]
}

proc fromParts {coefficient scale} {
    if {$coefficient == 0} { return 0 }
    if {$scale == 0} { return $coefficient }
    set digits [string trimleft $coefficient -]
    set point [expr {[string length $digits] - $scale}]
    if {$point <= 0} {
        set magnitude "0.[string repeat 0 [expr {-$point}]]$digits"
    } else {
        set magnitude "[string range $digits 0 $point-1].[string range $digits $point end]"
    }
    set magnitude [string trimright [string trimright $magnitude 0] .]
    if {$coefficient < 0} { return -$magnitude }
    return $magnitude
}

proc canonical {value} { return [fromParts {*}[parts $value]] }

proc calc {op a b} {
    lassign [parts $a] left leftScale
    lassign [parts $b] right rightScale
    if {$op eq "*"} {
        return [fromParts [expr {$left * $right}] [expr {$leftScale + $rightScale}]]
    }
    set scale [expr {max($leftScale, $rightScale)}]
    set left [expr {$left * 10**($scale - $leftScale)}]
    set right [expr {$right * 10**($scale - $rightScale)}]
    switch -exact -- $op {
        + { return [fromParts [expr {$left + $right}] $scale] }
        - { return [fromParts [expr {$left - $right}] $scale] }
        default { return -code error -errorcode {APPCOMPILER ARGUMENT OPERATOR} "unknown decimal operator" }
    }
}

# Return a reduced fraction with positive denominator. Denominator zero
# marks a division failure for all three public division operations.
proc ratio {a b} {
    lassign [parts $a] numerator aScale
    lassign [parts $b] denominator bScale
    if {$denominator == 0} { return {0 0} }
    if {$numerator == 0} { return {0 1} }
    if {$denominator < 0} {
        set numerator [expr {-$numerator}]
        set denominator [expr {-$denominator}]
    }
    if {$bScale > $aScale} {
        set numerator [expr {$numerator * 10**($bScale - $aScale)}]
    } elseif {$aScale > $bScale} {
        set denominator [expr {$denominator * 10**($aScale - $bScale)}]
    }
    set x [expr {abs($numerator)}]
    set y $denominator
    while {$y != 0} {
        set remainder [expr {$x % $y}]
        set x $y
        set y $remainder
    }
    return [list [expr {$numerator / $x}] [expr {$denominator / $x}]]
}

proc divisionError {code message} { return [list err [dict create code $code message $message]] }

# A reduced fraction terminates in base ten exactly when its denominator
# has no prime factors other than 2 and 5. Return an empty list otherwise.
proc finiteParts {numerator denominator} {
    set twos 0
    while {$denominator % 2 == 0} {
        set denominator [expr {$denominator / 2}]
        incr twos
    }
    set fives 0
    while {$denominator % 5 == 0} {
        set denominator [expr {$denominator / 5}]
        incr fives
    }
    if {$denominator != 1} { return {} }
    set scale [expr {max($twos, $fives)}]
    set coefficient [expr {$numerator * 2**($scale - $twos) * 5**($scale - $fives)}]
    return [list $coefficient $scale]
}

proc divide {a b} {
    lassign [ratio $a $b] numerator denominator
    if {$denominator == 0} { return [divisionError DIVIDE_BY_ZERO "division by zero"] }
    set finite [finiteParts $numerator $denominator]
    if {![llength $finite]} {
        return [divisionError NONTERMINATING_DECIMAL "quotient has no finite decimal representation"]
    }
    return [list ok [fromParts {*}$finite]]
}

proc quotient {a b} {
    lassign [ratio $a $b] numerator denominator
    if {$denominator == 0} { return [divisionError DIVIDE_BY_ZERO "division by zero"] }
    # Tcl integer division rounds down for negative operands. Divide the
    # magnitude first so the language's integer quotient truncates toward zero.
    set whole [expr {abs($numerator) / $denominator}]
    if {$numerator < 0} { set whole [expr {-$whole}] }
    return [list ok $whole]
}

proc rounded {a b places mode} {
    set integerPlaces [regexp {\A[+-]?[0-9]+\Z} $places]
    if {$integerPlaces} { set places [lindex [parts $places] 0] }
    if {!$integerPlaces || $places < 0} {
        return [divisionError ROUND_PLACES "rounding requires a nonnegative number of decimal places"]
    }
    if {$mode ni {half_even half_away}} {
        return [divisionError ROUND_MODE "rounding requires half_even or half_away"]
    }
    lassign [ratio $a $b] numerator denominator
    if {$denominator == 0} { return [divisionError DIVIDE_BY_ZERO "division by zero"] }
    # A terminating value already within the requested scale needs no padding,
    # even when the caller requests many more places than the value uses.
    set finite [finiteParts $numerator $denominator]
    if {[llength $finite] && [lindex $finite 1] <= $places} {
        return [list ok [fromParts {*}$finite]]
    }
    if {![llength $finite] && $places > 100000} {
        return [divisionError ROUND_SCALE_LIMIT "rounding a nonterminating quotient supports at most 100000 decimal places"]
    }
    set scaled [expr {abs($numerator) * 10**$places}]
    set whole [expr {$scaled / $denominator}]
    set twiceRemainder [expr {2 * ($scaled % $denominator)}]
    if {$twiceRemainder > $denominator ||
            ($twiceRemainder == $denominator && ($mode eq "half_away" || $whole % 2 == 1))} {
        incr whole
    }
    if {$numerator < 0} { set whole [expr {-$whole}] }
    return [list ok [fromParts $whole $places]]
}
