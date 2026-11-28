# Both the compiler and the generated application install these procedures in
# their own decimal namespace. A fixed-point value is coefficient / 10**scale.
proc canonical {value} {
    # A native value can expose decimal text while its caller retains the handle.
    append value {}
    if {![regexp {\A[+-]?[0-9]+(?:\.[0-9]+)?\Z} $value]} {
        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected a fixed-point decimal"
    }
    set magnitude [string trimleft $value +-0]
    if {[string first . $magnitude] >= 0} {
        set magnitude [string trimright [string trimright $magnitude 0] .]
        if {[string index $magnitude 0] eq "."} {set magnitude 0$magnitude}
    }
    if {$magnitude eq ""} {return 0}
    if {[string index $value 0] eq "-"} {return -$magnitude}
    return $magnitude
}

if {[llength [info commands ::interp]] && [llength [info commands ::machteld::x::canonicalDecimal]] &&
        "canonicalDecimal" in [namespace eval ::machteld::x {namespace export}]} {
    interp alias {} [namespace current]::canonical {} ::machteld::x::canonicalDecimal
}

# Typed operands have canonical fixed-point spelling. Use a base-ten scan
# because removing the point from 0.08 leaves digits Tcl would read as octal.
proc canonicalParts {value} {
    set point [string first . $value]
    if {$point < 0} {return [list $value 0]}
    scan [string replace $value $point $point] %lld coefficient
    return [list $coefficient [expr {[string length $value] - $point - 1}]]
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

proc calc {op a b} {
    lassign [canonicalParts $a] left leftScale
    lassign [canonicalParts $b] right rightScale
    if {$op eq "*"} {
        return [fromParts [expr {$left * $right}] [expr {$leftScale + $rightScale}]]
    }
    if {$leftScale < $rightScale} {
        set left [expr {$left * 10**($rightScale - $leftScale)}]
        set leftScale $rightScale
    } elseif {$rightScale < $leftScale} {
        set right [expr {$right * 10**($leftScale - $rightScale)}]
    }
    switch -exact -- $op {
        + { return [fromParts [expr {$left + $right}] $leftScale] }
        - { return [fromParts [expr {$left - $right}] $leftScale] }
        default { return -code error -errorcode {APPCOMPILER ARGUMENT OPERATOR} "unknown decimal operator" }
    }
}

if {[llength [info commands ::machteld::x::tryDecimalArithmetic]] &&
        "tryDecimalArithmetic" in [namespace eval ::machteld::x {namespace export}]} {
    proc calc {op a b} [string cat {
        set bounded [::machteld::x::tryDecimalArithmetic $op $a $b]
        if {$bounded ne {}} {return $bounded}
    } [info body calc]]
}

# Exact division needs a reduced fraction. Short rounded division can use
# the original integer ratio. A zero denominator marks division failure.
proc ratio {a b {allowUnreduced 0}} {
    lassign [canonicalParts $a] numerator aScale
    lassign [canonicalParts $b] denominator bScale
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
    # Long division at this scale needs no GCD for ordinary integer operands.
    # Retain the original arithmetic and Tcl diagnostics on trace replacements.
    if {$x == 1 || $denominator == 1 || ($allowUnreduced &&
            [string is wideinteger -strict $x] && [string is wideinteger -strict $denominator])} {
        return [list $numerator $denominator]
    }
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
    set scale 0
    if {$denominator % 10 == 0} {
        set shortened [string trimright $denominator 0]
        set scale [expr {[string length $denominator] - [string length $shortened]}]
        set denominator $shortened
    }
    if {$denominator == 1} { return [list $numerator $scale] }
    if {$denominator % 2 == 0} {
        set prime 2
        set complement 5
    } elseif {$denominator % 5 == 0} {
        set prime 5
        set complement 2
    } else {
        return {}
    }
    # After removing all tens, at most one of their prime factors remains.
    # Divide by powers with exponents 1, 2, 4, ... and finish in descending
    # order. Even a denominator such as 2**10000 takes logarithmically many
    # divisions to factor.
    set powers {}
    set factor $prime
    set step 1
    set exponent 0
    while {$denominator % $factor == 0} {
        lappend powers [list $factor $step]
        set denominator [expr {$denominator / $factor}]
        incr exponent $step
        if {$denominator == 1} break
        set factor [expr {$factor * $factor}]
        incr step $step
    }
    foreach power [lreverse $powers] {
        if {$denominator == 1} break
        lassign $power factor step
        if {$denominator % $factor == 0} {
            set denominator [expr {$denominator / $factor}]
            incr exponent $step
        }
    }
    if {$denominator != 1} { return {} }
    return [list [expr {$numerator * $complement**$exponent}] [expr {$scale + $exponent}]]
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
    # A single ASCII digit is already a canonical number of decimal places.
    if {![string match {[0-9]} $places]} {
        set integerPlaces [regexp {\A[+-]?[0-9]+\Z} $places]
        if {$integerPlaces} {scan $places %lld places}
        if {!$integerPlaces || $places < 0} {
            return [divisionError ROUND_PLACES "rounding requires a nonnegative number of decimal places"]
        }
    }
    if {$mode ni {half_even half_away}} {
        return [divisionError ROUND_MODE "rounding requires half_even or half_away"]
    }
    lassign [ratio $a $b [expr {$places <= 18}]] numerator denominator
    if {$denominator == 0} { return [divisionError DIVIDE_BY_ZERO "division by zero"] }
    if {$places > 100000} {
        # A terminating value needs no artificial padding at a huge scale.
        set finite [finiteParts $numerator $denominator]
        if {![llength $finite]} {
            return [divisionError ROUND_SCALE_LIMIT "rounding a nonterminating quotient supports at most 100000 decimal places"]
        }
        if {[lindex $finite 1] <= $places} { return [list ok [fromParts {*}$finite]] }
    }

    set magnitude [expr {abs($numerator)}]
    set whole [expr {$magnitude / $denominator}]
    set remainder [expr {$magnitude % $denominator}]
    set fraction {}
    # Long division in blocks avoids building and formatting a single huge
    # scaled integer. Every remainder is exact; only the last one is rounded.
    while {$remainder != 0 && $places > 0} {
        set count [expr {min($places, 18)}]
        set scaled [expr {$remainder * 10**$count}]
        set digits [expr {$scaled / $denominator}]
        set remainder [expr {$scaled % $denominator}]
        append fraction [string repeat 0 [expr {$count - [string length $digits]}]] $digits
        incr places -$count
    }
    set last [expr {$fraction eq {} ? $whole % 10 : [string index $fraction end]}]
    set twiceRemainder [expr {2 * $remainder}]
    if {$twiceRemainder > $denominator ||
            ($twiceRemainder == $denominator && ($mode eq "half_away" || $last % 2 == 1))} {
        # A trailing run of nines becomes zeroes, which canonical output omits.
        set fraction [string trimright $fraction 9]
        if {$fraction eq {}} {
            incr whole
        } else {
            set digit [expr {[string index $fraction end] + 1}]
            set fraction [string replace $fraction end end $digit]
        }
    }
    set fraction [string trimright $fraction 0]
    set result $whole
    if {$fraction ne {}} { append result . $fraction }
    if {$numerator < 0 && $result ne "0"} { set result -$result }
    return [list ok $result]
}
