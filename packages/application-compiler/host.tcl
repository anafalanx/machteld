# These procedures are embedded in the generated application's runtime
# namespace. Input, output and JSON are touched only when the program asks.
proc problem {message} {return [dict create message $message]}

proc atResult {result location} {
    lassign $result tag value
    if {$tag eq "err" && ![dict exists $value origin]} {
        dict set value origin $location
        return [list err $value]
    }
    return $result
}

proc propagate {result location} {
    lassign $result tag value
    switch -exact -- $tag {
        ok {return $value}
        err {
            if {$location ne ""} {set result [atResult $result $location]}
            return -code return $result
        }
        default {error "invalid result tag [list $tag]"}
    }
}

proc locationPrefix {location} {
    return "[dict get $location module]:[dict get $location line]:[dict get $location column]: "
}

proc launch {entry sourceMap arguments} {
    try {
        lassign [$entry $arguments] tag value
        if {$tag eq "ok"} {return 0}
        if {$tag ne "err"} {error "invalid application entry result"}
        set where [dict getdef $value origin {}]
        set prefix [expr {$where eq "" ? "" : [locationPrefix $where]}]
        puts stderr "$prefix[dict get $value message]"
        return 1
    } on error {message options} {
        set prefix ""
        foreach frame [split [dict get $options -errorinfo] \n] {
            if {[regexp {^\s*\(procedure "([^"]+)" line ([0-9]+)\)} $frame -> procName bodyLine]
                    && [dict exists $sourceMap $procName $bodyLine]} {
                set prefix [locationPrefix [dict get $sourceMap $procName $bodyLine]]
                break
            }
        }
        puts stderr "${prefix}application error: $message"
        return 1
    }
}

proc read_stdin_bytes {} {
    if {[catch {
        set state [list -translation [chan configure stdin -translation] \
            -encoding [chan configure stdin -encoding] -eofchar [chan configure stdin -eofchar]]
        try {
            chan configure stdin -translation binary
            read stdin
        } finally {chan configure stdin {*}$state}
    } value]} {return [list err [dict create code READ message $value]]}
    return [list ok $value]
}

proc decode_utf8 {bytes} {
    set offset -1
    set text [encoding convertfrom -profile strict -failindex offset utf-8 $bytes]
    if {$offset >= 0} {
        return [list err [dict create code UTF8 byteOffset $offset \
            message "invalid UTF-8 at byte offset $offset"]]
    }
    return [list ok $text]
}

proc write_stdout_utf8 {text} {
    if {[catch {
        set state [list -translation [chan configure stdout -translation] \
            -encoding [chan configure stdout -encoding] -eofchar [chan configure stdout -eofchar]]
        set bytes [encoding convertto -profile strict utf-8 $text]
        try {
            chan configure stdout -translation binary
            puts -nonewline stdout $bytes
            flush stdout
        } finally {chan configure stdout {*}$state}
    } message]} {return [list err [dict create code WRITE message $message]]}
    return [list ok {}]
}

proc invalidWire {message} {
    return -code error -errorcode {APPLICATION DATA} $message
}

proc mapLookup {map key} {
    if {[dict exists $map $key]} {return [list some [dict get $map $key]]}
    return [list none]
}

proc require_key {map key} {
    if {[dict exists $map $key]} {return [list ok [dict get $map $key]]}
    return [list err [dict create code MISSING_KEY message "missing map key [list $key]"]]
}

# Both int and decimal keys are already canonical. For equal signs and
# integer widths, lexical order of the digits gives their exact magnitude.
# Tcl's integer sort is machine-width and real sort converts to double.
proc compareNumericMapKeys {left right} {
    set negative [expr {[string index $left 0] eq "-"}]
    set rightNegative [expr {[string index $right 0] eq "-"}]
    if {$negative != $rightNegative} {return [expr {$negative ? -1 : 1}]}
    set leftWidth [string first . $left]
    set rightWidth [string first . $right]
    if {$leftWidth < 0} {set leftWidth [string length $left]}
    if {$rightWidth < 0} {set rightWidth [string length $right]}
    set order [expr {$leftWidth - $rightWidth}]
    if {$order == 0} {set order [string compare $left $right]}
    return [expr {$negative ? -$order : $order}]
}

proc sorted_keys {keyType map} {
    set keys [dict keys $map]
    switch -exact -- $keyType {
        text - bool {return [lsort -ascii $keys]}
        int - decimal {return [lsort -command [namespace current]::compareNumericMapKeys $keys]}
        default {error "unsupported map key type [list $keyType]"}
    }
}

proc typedMembers {node} {
    set children {}
    foreach key [dict keys [::machteld::json unwrap $node]] {
        dict set children $key [::machteld::json get $node $key]
    }
    # Older hosts can lose a NUL inside a key during Tcl conversion. Check
    # the reconstruction before permitting a write through such a boundary.
    set rebuilt [::machteld::json value object $children]
    if {[::machteld::json encode -- $rebuilt] ne [::machteld::json encode -- $node]} {
        invalidWire "object keys cannot be preserved by this JSON runtime"
    }
    return $children
}

proc fromWire {type node path} {
    set parts [typeParts $type]
    set head [lindex $parts 0]
    set actual [::machteld::json type $node]
    switch -exact -- $head {
        optional {return [list some [fromWire [lindex $parts 1] $node $path]]}
        decimal {
            if {$actual ne "number"} {invalidWire "$path expects a decimal number, got $actual"}
            if {[catch {decimal::canonical [::machteld::json unwrap $node]} value]} {
                invalidWire "$path expects a fixed-point JSON number"
            }
            return $value
        }
        text {
            if {$actual ne "string"} {invalidWire "$path expects text, got $actual"}
            set value [::machteld::json unwrap $node]
            set rebuilt [::machteld::json value string $value]
            if {[::machteld::json encode -- $rebuilt] ne [::machteld::json encode -- $node]} {
                invalidWire "$path cannot be preserved as text by this runtime"
            }
            return $value
        }
        int {
            if {$actual ne "number"} {invalidWire "$path expects an integer, got $actual"}
            set digits [::machteld::json unwrap $node]
            if {![regexp {\A-?(?:0|[1-9][0-9]*)\Z} $digits]} {
                invalidWire "$path expects an integer JSON literal"
            }
            scan $digits %lld value
            return $value
        }
        bool {
            if {$actual ne "boolean"} {invalidWire "$path expects a boolean, got $actual"}
            return [::machteld::json unwrap $node]
        }
        list {
            if {$actual ne "array"} {invalidWire "$path expects an array, got $actual"}
            set out {}
            set size [llength [::machteld::json unwrap $node]]
            for {set i 0} {$i < $size} {incr i} {
                lappend out [fromWire [lindex $parts 1] [::machteld::json get $node $i] "$path\[$i\]"]
            }
            return $out
        }
        map {
            if {[lindex $parts 1] ne "text"} {invalidWire "$path requires text keys for a JSON object"}
            if {$actual ne "object"} {invalidWire "$path expects an object, got $actual"}
            set out {}
            dict for {key child} [typedMembers $node] {
                dict set out $key [fromWire [lindex $parts 2] $child "$path\[[list $key]\]"]
            }
            return $out
        }
    }
    set table [schemas]
    if {![dict exists $table $type] || [lindex [dict get $table $type] 0] ne "record"} {
        invalidWire "$path has no declared record wire format for $type"
    }
    if {$actual ne "object"} {invalidWire "$path expects an object, got $actual"}
    set members [lindex [dict get $table $type] 1]
    set out [typedMembers $node]
    dict for {name fieldType} $members {
        if {![dict exists $out $name]} {
            if {[string index $fieldType end] eq "?"} {continue}
            invalidWire "$path is missing required field $name"
        }
        dict set out $name [fromWire $fieldType [dict get $out $name] "$path.$name"]
    }
    return $out
}

proc toWire {type value path} {
    set parts [typeParts $type]
    switch -exact -- [lindex $parts 0] {
        text {return [::machteld::json value string $value]}
        int  {return [::machteld::json value number [guard int $value $path]]}
        decimal {return [::machteld::json value number [guard decimal $value $path]]}
        bool {return [::machteld::json value boolean [guard bool $value $path]]}
        list {
            set nodes {}
            foreach element $value {lappend nodes [toWire [lindex $parts 1] $element $path]}
            return [::machteld::json value array $nodes]
        }
        map {
            if {[lindex $parts 1] ne "text"} {invalidWire "$path requires text keys for a JSON object"}
            set nodes {}
            dict for {key item} $value {
                dict set nodes $key [toWire [lindex $parts 2] $item "$path\[[list $key]\]"]
            }
            return [::machteld::json value object $nodes]
        }
        optional {
            if {[lindex $value 0] ne "some"} {invalidWire "$path has no present value"}
            return [toWire [lindex $parts 1] [lindex $value 1] $path]
        }
    }
    set table [schemas]
    if {![dict exists $table $type] || [lindex [dict get $table $type] 0] ne "record"} {
        invalidWire "$path has no declared record wire format for $type"
    }
    set members [lindex [dict get $table $type] 1]
    set nodes {}
    dict for {name child} $value {
        if {[dict exists $members $name]} {
            set fieldType [dict get $members $name]
            if {[string index $fieldType end] eq "?" && $child eq "none"} {continue}
            dict set nodes $name [toWire $fieldType $child "$path.$name"]
        } else {
            # Demand a retained wire value; guessing from Tcl text could
            # silently change a future field's type or numeric precision.
            ::machteld::json type $child
            dict set nodes $name $child
        }
    }
    return [::machteld::json value object $nodes]
}

proc decode_json {type text} {
    try {
        set root [::machteld::json decode -typed $text]
        return [list ok [fromWire $type $root value]]
    } trap {APPLICATION DATA} {message opts} {
        return [list err [dict create code JSON_SCHEMA message $message]]
    } trap {MACHTELD JSON} {message opts} {
        return [list err [dict create code JSON message $message]]
    }
}

proc encode_json {type value} {
    try {
        return [list ok [::machteld::json encode -- [toWire $type $value value]]]
    } trap {APPLICATION DATA} {message opts} {
        return [list err [dict create code JSON_SCHEMA message $message]]
    } trap {MACHTELD JSON} {message opts} {
        return [list err [dict create code JSON message $message]]
    }
}

# Compare JSON numbers as a coefficient and a decimal exponent, without
# expanding an exponent or converting to floating point.
proc decimalKey {token} {
    if {![regexp {\A(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\Z} \
            $token -> sign whole fraction exponent]} {invalidWire "invalid JSON number"}
    set coefficient [string trimleft $whole$fraction 0]
    if {$coefficient eq ""} {return {0 0}}
    if {$exponent eq ""} {set power 0} else {scan $exponent %lld power}
    set trimmed [string trimright $coefficient 0]
    set power [expr {$power - [string length $fraction] + [string length $coefficient] - [string length $trimmed]}]
    return [list $sign$trimmed $power]
}

proc equalWire {left right} {
    set type [::machteld::json type $left]
    if {$type ne [::machteld::json type $right]} {return 0}
    switch -exact -- $type {
        object {
            set l [typedMembers $left]
            set r [typedMembers $right]
            if {[dict size $l] != [dict size $r]} {return 0}
            dict for {key child} $l {
                if {![dict exists $r $key] || ![equalWire $child [dict get $r $key]]} {return 0}
            }
            return 1
        }
        array {
            set count [llength [::machteld::json unwrap $left]]
            if {$count != [llength [::machteld::json unwrap $right]]} {return 0}
            for {set i 0} {$i < $count} {incr i} {
                if {![equalWire [::machteld::json get $left $i] [::machteld::json get $right $i]]} {return 0}
            }
            return 1
        }
        number {
            return [string equal [decimalKey [::machteld::json unwrap $left]] \
                [decimalKey [::machteld::json unwrap $right]]]
        }
        null {return 1}
        default {return [string equal [::machteld::json unwrap $left] [::machteld::json unwrap $right]]}
    }
}

proc equal {type left right} {
    set parts [typeParts $type]
    switch -exact -- [lindex $parts 0] {
        int - bool {return [expr {$left == $right}]}
        decimal {return [string equal $left $right]}
        text {return [string equal $left $right]}
        optional {
            if {[lindex $left 0] ne [lindex $right 0]} {return 0}
            if {[lindex $left 0] eq "none"} {return 1}
            return [equal [lindex $parts 1] [lindex $left 1] [lindex $right 1]]
        }
        list {
            if {[llength $left] != [llength $right]} {return 0}
            foreach a $left b $right {if {![equal [lindex $parts 1] $a $b]} {return 0}}
            return 1
        }
        map {
            if {[dict size $left] != [dict size $right]} {return 0}
            dict for {key a} $left {
                if {![dict exists $right $key] || ![equal [lindex $parts 2] $a [dict get $right $key]]} {
                    return 0
                }
            }
            return 1
        }
    }
    lassign [dict get [schemas] $type] kind members
    if {$kind eq "choice"} {
        set tag [lindex $left 0]
        if {$tag ne [lindex $right 0]} {return 0}
        foreach t [dict get $members $tag] a [lrange $left 1 end] b [lrange $right 1 end] {
            if {![equal $t $a $b]} {return 0}
        }
        return 1
    }
    dict for {name t} $members {
        if {![equal $t [dict getdef $left $name none] [dict getdef $right $name none]]} {return 0}
        dict unset left $name
        dict unset right $name
    }
    if {[dict size $left] != [dict size $right]} {return 0}
    dict for {key extra} $left {
        if {![dict exists $right $key] || ![equalWire $extra [dict get $right $key]]} {return 0}
    }
    return 1
}
