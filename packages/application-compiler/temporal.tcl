# The generated runtime uses the proleptic Gregorian calendar throughout.
# Decimal fraction digits stay as text to preserve nanosecond precision.
proc temporalMonthDays {year month} {
    if {$month == 2 && $year % 4 == 0 && ($year % 100 != 0 || $year % 400 == 0)} {
        return 29
    }
    return [lindex {0 31 28 31 30 31 30 31 31 30 31 30 31} $month]
}

proc temporalParts {value} {
    if {![regexp {\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.([0-9]{1,9}))?\Z} $value -> fraction]} {
        return {}
    }
    # %d reads leading zeroes as decimal, including in months 08 and 09.
    lassign [scan $value {%4d-%2d-%2dT%2d:%2d:%2d}] year month day hour minute second
    if {$year == 0 || $month < 1 || $month > 12 || $day < 1 || $day > [temporalMonthDays $year $month]
            || $hour > 23 || $minute > 59 || $second > 59} {
        return {}
    }
    return [list $year $month $day $hour $minute $second [string trimright $fraction 0]]
}

proc temporalText {year month day hour minute second fraction} {
    set text [format {%04d-%02d-%02dT%02d:%02d:%02d} $year $month $day $hour $minute $second]
    if {$fraction ne {}} {append text . $fraction}
    return $text
}

proc temporalError {code message} {return [list err [dict create code $code message $message]]}

proc parse_local_datetime {text} {
    set parts [temporalParts $text]
    if {$parts eq {}} {
        return [temporalError INVALID_LOCAL_DATETIME {expected a valid Gregorian YYYY-MM-DDTHH:MM:SS with an optional 1-9 digit fraction}]
    }
    return [list ok [temporalText {*}$parts]]
}

proc temporalAtOffset {parts eastSeconds} {
    lassign $parts year month day hour minute second fraction
    set utcSeconds [expr {3600 * $hour + 60 * $minute + $second - $eastSeconds}]
    # Offsets in this profile can cross at most one midnight.
    if {$utcSeconds < 0} {
        incr utcSeconds 86400
        incr day -1
        if {$day == 0} {
            incr month -1
            if {$month == 0} {set month 12; incr year -1}
            set day [temporalMonthDays $year $month]
        }
    } elseif {$utcSeconds >= 86400} {
        incr utcSeconds -86400
        incr day
        if {$day > [temporalMonthDays $year $month]} {
            set day 1
            incr month
            if {$month == 13} {set month 1; incr year}
        }
    }
    if {$year < 1 || $year > 9999} {
        return [temporalError INSTANT_RANGE {UTC year must be between 0001 and 9999}]
    }
    # Every UTC instant has the same width, so BINARY text order is chronological.
    append fraction [string repeat 0 [expr {9 - [string length $fraction]}]]
    set utc [temporalText $year $month $day [expr {$utcSeconds / 3600}] \
            [expr {($utcSeconds / 60) % 60}] [expr {$utcSeconds % 60}] $fraction]
    return [list ok ${utc}Z]
}

proc parse_instant {text} {
    set eastMinutes 0
    if {[string index $text end] eq "Z"} {
        set local [string range $text 0 end-1]
    } else {
        set zone [string range $text end-5 end]
        if {$zone eq "-00:00" || ![regexp {\A([+-])([0-9]{2}):([0-9]{2})\Z} $zone -> sign hours minutes]} {
            return [temporalError INVALID_INSTANT {expected a UTC designator Z or a known numeric offset in the form +HH:MM or -HH:MM}]
        }
        set hours [scan $hours %d]
        set minutes [scan $minutes %d]
        set eastMinutes [expr {60 * $hours + $minutes}]
        if {$minutes > 59 || $eastMinutes > 840} {
            return [temporalError INVALID_INSTANT {offset must be between -14:00 and +14:00 with minutes between 00 and 59}]
        }
        if {$sign eq "-"} {set eastMinutes [expr {-$eastMinutes}]}
        set local [string range $text 0 end-6]
    }
    set parts [temporalParts $local]
    if {$parts eq {}} {
        return [temporalError INVALID_INSTANT {expected a valid Gregorian date and time before the UTC offset}]
    }
    return [temporalAtOffset $parts [expr {60 * $eastMinutes}]]
}

proc resolve_offset {local eastMinutes} {
    if {![string is entier -strict $eastMinutes] || $eastMinutes < -840 || $eastMinutes > 840} {
        return [temporalError INVALID_OFFSET {expected an integer offset in minutes east of UTC, between -840 and 840}]
    }
    set parts [temporalParts $local]
    if {$parts eq {}} {
        return [temporalError INVALID_LOCAL_DATETIME {expected a valid local date and time}]
    }
    return [temporalAtOffset $parts [expr {60 * $eastMinutes}]]
}

proc temporalCanonical {type value} {
    switch -exact -- $type {
        local_datetime {set result [parse_local_datetime $value]}
        instant {set result [parse_instant $value]}
        default {error "unknown temporal type [list $type]"}
    }
    lassign $result tag canonical
    if {$tag ne "ok" || $value ne $canonical} {
        return -code error -errorcode {APPCOMPILER ARGUMENT TYPE} "expected canonical $type"
    }
    return $canonical
}
