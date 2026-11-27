# Tcl's pinned tclZIC files contain a transition table or an alias. Read the
# declarations as lists, without evaluating Tcl or invoking the host TZ loader.
proc zoneValidName {name} {
    expr {[string length $name] <= 128 &&
        [regexp {\A[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z][A-Za-z0-9_+-]*)*\Z} $name]}
}

proc zoneTable {name {aliases {}}} {
    variable zoneCache
    if {[info exists zoneCache($name)]} {return $zoneCache($name)}
    if {![zoneValidName $name] || $name in $aliases} {error "invalid zone link"}

    set root [::machteld::PayloadRoot]
    set directory [file join $root tcl_library tzdata]
    # PayloadRoot pins either the executable or the wrapped host's private
    # snapshot. Reject zone entries supplied by an overlapping zipfs mount.
    set owner [lindex [zipfs info $root] 0]
    if {[lindex [zipfs info $directory] 0] ne $owner} {error "zone catalog belongs to another archive"}
    set path [file join $directory $name]
    if {![file isfile $path]} {
        if {[llength $aliases]} {error "missing zone link target"}
        return -code error -errorcode {APPCOMPILER ZONE UNKNOWN} "unknown zone name"
    }
    if {[lindex [zipfs info $path] 0] ne $owner} {error "zone file belongs to another archive"}
    set channel [open $path rb]
    try {
        gets $channel
        set declaration [read $channel]
    } finally {close $channel}

    if {[lindex $declaration end-1] ne "TZData(:$name)" || [lindex $declaration end-2] ne "set"} {
        error "invalid zone declaration"
    }
    set data [lindex $declaration end]
    if {[llength $declaration] == 6 && [lindex $declaration 0] eq "if" &&
            [regexp {\A\$TZData\(:(.+)\)\Z} $data -> target]} {
        lappend aliases $name
        return [set zoneCache($name) [zoneTable $target $aliases]]
    }
    if {[llength $declaration] != 3 || [lindex $data 0 0] ne "-9223372036854775808"} {
        error "missing initial zone offset"
    }
    set offsets {}
    set previous {}
    foreach row $data {
        lassign $row start offset
        if {[llength $row] != 4 || ![string is wideinteger -strict $start] ||
                ![string is integer -strict $offset] || abs($offset) > 86400 ||
                ($previous ne {} && $start < $previous)} {
            error "invalid zone transition"
        }
        dict set offsets $offset 1
        set previous $start
    }
    return [set zoneCache($name) [list $data [dict keys $offsets]]]
}

# Express the clock reading on the same proleptic Gregorian seconds axis as
# the UTC transitions, before applying an offset. 1970-01-01 is ordinal 719162
# when 0001-01-01 is zero. Fractions stay untouched in the original parts.
proc zoneLocalSeconds {parts} {
    lassign $parts year month day hour minute second
    set years [expr {$year - 1}]
    set beforeMonth [lindex {0 0 31 59 90 120 151 181 212 243 273 304 334} $month]
    if {$month > 2 && [temporalMonthDays $year 2] == 29} {incr beforeMonth}
    set days [expr {365 * $years + $years/4 - $years/100 + $years/400 + $beforeMonth + $day - 1 - 719162}]
    return [expr {$days * 86400 + $hour * 3600 + $minute * 60 + $second}]
}

proc resolve_zone {local zone} {
    set parts [temporalParts $local]
    if {![llength $parts]} {
        return [temporalError INVALID_LOCAL_DATETIME {expected a valid local date and time}]
    }
    if {![zoneValidName $zone]} {return [temporalError INVALID_ZONE {expected a bundled time-zone name}]}
    try {
        lassign [zoneTable $zone] transitions offsets
    } trap {APPCOMPILER ZONE UNKNOWN} {} {
        return [temporalError INVALID_ZONE {unknown time-zone name in the embedded catalog}]
    } on error {} {
        return [temporalError ZONE_DATA {the embedded time-zone rules are unavailable or invalid}]
    }
    # Tcl 9.0.4's tclZIC stops expanding open-ended recurring rules at 2100.
    if {[lindex $parts 0] > 2099} {
        return [temporalError ZONE_RANGE {named time-zone coverage ends in 2099}]
    }
    set seconds [zoneLocalSeconds $parts]
    set instants {}
    foreach offset $offsets {
        set utc [expr {$seconds - $offset}]
        set row [lsearch -sorted -integer -bisect -index 0 $transitions $utc]
        if {[lindex $transitions $row 1] != $offset} continue
        if {$utc >= 4102444800} {
            return [temporalError ZONE_RANGE {resolved UTC instant is beyond named time-zone coverage}]
        }
        lassign [temporalAtOffset $parts $offset] tag value
        if {$tag ne "ok"} {return [list $tag $value]}
        lappend instants $value
    }
    return [list ok [lsort -ascii $instants]]
}
