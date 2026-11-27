# These procedures are embedded in the generated application's runtime
# namespace. Input, output and JSON are touched only when the program asks.
proc problem {message} {return [dict create message $message]}

# A Tcl caller supplies concrete, canonical type names before the ordinary
# arguments of a generic export. Validate every name even for an empty list,
# an absent optional, or a parameter that occurs only in the result type.
proc concreteType {type schemas} {
    if {$type in {int decimal text bytes bool unit problem instant local_datetime process_stream}} {return 1}
    if {[string length $type] > 8192 || $type eq ""} {return 0}
    set parts [typeParts $type]
    set head [lindex $parts 0]
    set children [lrange $parts 1 end]
    switch -exact -- $head {
        optional {
            if {[string index $type end] ne "?"} {return 0}
            set arity 1
        }
        list - ref {set arity 1}
        callable {
            set arity [llength $children]
            if {$arity == 0} {return 0}
        }
        map - result {set arity 2}
        range {return [expr {$type eq "range<int>"}]}
        default {
            if {![dict exists $schemas $head]} {return 0}
            set arity [llength [lindex [dict get $schemas $head] 2]]
        }
    }
    if {[llength $children] != $arity} {return 0}
    foreach child $children {if {![concreteType $child $schemas]} {return 0}}
    if {$head eq "map" && [scalarBase [lindex $children 0]] ni {int decimal text bool}} {return 0}
    return 1
}

proc bindTypes {variables arguments} {
    if {[catch {llength $arguments} count] || $count != [llength $variables]} {
        reject {type arguments} "[llength $variables] concrete type argument(s)"
    }
    set schemas [schemas]
    set bindings {}
    foreach variable $variables argument $arguments {
        if {[catch {concreteType $argument $schemas} valid] || !$valid} {
            reject {type arguments} "a concrete type, got [list $argument]"
        }
        dict set bindings $variable $argument
    }
    return $bindings
}

# Prefixes carry ordinary Tcl values, including all captures. The generated
# table is the only source of executable target commands and their signatures.
proc callbackSignature {key types path} {
    set targets [callbackTargets]
    if {![dict exists $targets $key]} {reject $path {a callable from this application}}
    lassign [dict get $targets $key] command variables parameters result
    set bindings [bindTypes $variables $types]
    set parameters [lmap type $parameters {substituteType $type $bindings}]
    return [list $command $parameters [substituteType $result $bindings]]
}

proc guardCallable {type value path} {
    if {[catch {llength $value} size] || $size != 4 ||
            [lindex $value 0] ne "[namespace current]::invokeCallback"} {reject $path $type}
    lassign $value dispatch key types captures
    lassign [callbackSignature $key $types $path] command parameters result
    if {[catch {llength $captures} count] || $count > [llength $parameters]} {reject $path $type}
    set remaining [list {*}[lrange $parameters $count end] $result]
    if {$type ne "callable<[join $remaining ,]>"} {reject $path $type}
    set checked {}
    foreach item $captures expected [lrange $parameters 0 $count-1] {
        lappend checked [guard $expected $item "$path capture [llength $checked]" 1]
    }
    return [list $dispatch $key $types $checked]
}

proc bindCallback {callback args} {
    lassign $callback dispatch key types captures
    return [list $dispatch $key $types [list {*}$captures {*}$args]]
}

# A scope owns the only table entry. Tcl copies carry its opaque ticket,
# never the cell or its cleanup. Even mutually referring cells expire.
proc newReference {type initial} {
    variable referenceOwner
    variable referenceCells
    variable referenceSerial
    if {![info exists referenceOwner]} {
        set referenceOwner [binary encode hex [::machteld::hash random 16]]
    }
    set key [incr referenceSerial]-[binary encode hex [::machteld::hash random 16]]
    set referenceCells($key) [list $type $initial]
    return [list $referenceOwner $key]
}

proc referenceKey {ticket path} {
    variable referenceOwner
    variable referenceCells
    if {[catch {llength $ticket} size] || $size != 2 ||
            ![info exists referenceOwner] || [lindex $ticket 0] ne $referenceOwner} {
        reject $path {a live reference from this application}
    }
    set key [lindex $ticket 1]
    if {![info exists referenceCells($key)]} {
        return -code error -errorcode {APPCOMPILER REFERENCE EXPIRED} "shared reference at $path is no longer live"
    }
    return $key
}

proc guardReference {type ticket path} {
    variable referenceCells
    set key [referenceKey $ticket $path]
    if {[lindex $referenceCells($key) 0] ne $type} {reject $path "ref<$type>"}
    return $ticket
}

proc ref_get {ticket} {
    variable referenceCells
    set key [referenceKey $ticket ref_get]
    return [lindex $referenceCells($key) 1]
}

proc ref_set {ticket value} {
    variable referenceCells
    set key [referenceKey $ticket ref_set]
    set type [lindex $referenceCells($key) 0]
    set referenceCells($key) [list $type [guard $type $value {ref_set value}]]
    return {}
}

proc ref_same {left right} {
    return [expr {[referenceKey $left ref_same] eq [referenceKey $right ref_same]}]
}

proc endReference {ticket} {
    variable referenceCells
    unset referenceCells([lindex $ticket 1])
}

# Completed tickets remain valid for idempotent close. Only a live entry
# in the issuing application's stream table can release native resources.
proc guardStream {ticket path} {
    variable streamOwner
    if {![info exists streamOwner] || [catch {llength $ticket} size] || $size != 2 ||
            [lindex $ticket 0] ne $streamOwner || ![regexp {\A[0-9a-f]{32}\Z} [lindex $ticket 1]]} {
        reject $path {a process stream from this application}
    }
    return $ticket
}

# Tcl packages and Tk may call an exported prefix directly. Validate all
# supplied arguments even when its original X function was private.
proc invokeCallback {key types captures args} {
    lassign [callbackSignature $key $types callback] command parameters result
    if {[catch {llength $captures} count] || $count + [llength $args] != [llength $parameters]} {
        reject callback "[llength $parameters] total captured and supplied arguments"
    }
    set checked {}
    foreach item [list {*}$captures {*}$args] expected $parameters {
        lappend checked [guard $expected $item "callback argument [llength $checked]" 1]
    }
    if {[llength $types]} {tailcall $command $types {*}$checked}
    tailcall $command {*}$checked
}

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

# Carry an unwinding failure alongside a second failure from a finalizer.
# Problems and Tcl errors can also come from foreign code; preserve an
# existing extension value even when it was not supplied as a Tcl list.
proc appendCleanup {data key detail} {
    set previous [dict getdef $data $key {}]
    if {[catch {llength $previous}]} {set previous [list $previous]}
    lappend previous $detail
    dict set data $key $previous
    return $data
}

proc failedClose {bodyCode body bodyOptions closeCode close closeOptions errorType location} {
    if {$closeCode == 0} {
        set close [atResult $close $location]
        set detail [lindex $close 1]
        # A typed closer failure returns from the function owning the scope.
        set closeOptions [dict create -code 0 -level 1]
    } else {
        set origin [mappedLocation $closeOptions [sourceMap] $location]
        dict set closeOptions -appcompilerlocation $origin
        set detail [dict create code CLEANUP_FAULT message $close \
            errorCode [dict getdef $closeOptions -errorcode NONE] origin $origin]
        if {[dict exists $closeOptions -appcompilercleanup]} {
            dict set detail cleanupFailures [dict get $closeOptions -appcompilercleanup]
        }
    }
    if {$bodyCode == 1} {
        set bodyOptions [appendCleanup $bodyOptions -appcompilercleanup $detail]
        return [list $body $bodyOptions]
    }
    if {$bodyCode == 2 && [lindex $body 0] eq "err"} {
        if {$errorType eq "problem"} {
            set primary [appendCleanup [lindex $body 1] cleanupFailures $detail]
            return [list [list err $primary] $bodyOptions]
        }
        # A caller may have a scalar error type. Adding fields to that value
        # would violate its contract. Keep it intact on the unexpected fault.
        dict set closeOptions -appcompilerprimary $body
    }
    return [list $close $closeOptions]
}

proc locationPrefix {location} {
    return "[dict get $location module]:[dict get $location line]:[dict get $location column]: "
}

proc guardLocation {location path} {
    if {[catch {dict size $location}] || [dict getdef $location module {}] eq {}} {
        reject $path {a source location with a nonempty module}
    }
    foreach field {line column} {
        if {![dict exists $location $field]} {reject $path.$field {a positive integer}}
        set position [guard int [dict get $location $field] $path.$field]
        if {$position < 1} {reject $path.$field {a positive integer}}
        dict set location $field $position
    }
    return $location
}

# A nested extern may already have located the failing command. Native Tcl
# can also supply arbitrary error options, so validate before retaining one.
proc errorLocation {options {fallback {}}} {
    if {[dict exists $options -appcompilerlocation]
            && ![catch {guardLocation [dict get $options -appcompilerlocation] {error location}} location]} {
        return $location
    }
    return $fallback
}

# The prefix and arguments are Tcl list elements. Run the command in the
# global scope, even when the wrapper was called from another Tcl namespace.
proc externInvoke {location prefix args} {
    set code [catch {uplevel #0 [list {*}$prefix {*}$args]} value options]
    if {$code == 0} {return $value}
    if {$code == 1} {
        dict set options -appcompilerlocation [errorLocation $options $location]
        return -options $options $value
    }
    # A nonstandard completion must not escape the wrapper's return checks.
    return -code error -errorcode [list APPCOMPILER EXTERN COMPLETION $code] \
        -appcompilerlocation $location "extern command returned Tcl completion code $code"
}

proc externResult {location type value} {
    if {[catch {guard $type $value {extern result} 1} result options]} {
        dict set options -appcompilerlocation $location
        dict set options -errorcode {APPCOMPILER EXTERN RESULT}
        return -options $options $result
    }
    return $result
}

proc mappedLocation {options sourceMap {fallback {}}} {
    set where [errorLocation $options]
    if {$where ne {}} {return $where}
    foreach frame [split [dict getdef $options -errorinfo {}] \n] {
        if {[regexp {^\s*\(procedure "([^"]+)" line ([0-9]+)\)} $frame -> procName bodyLine]
                && [dict exists $sourceMap $procName $bodyLine]} {
            return [dict get $sourceMap $procName $bodyLine]
        }
    }
    return $fallback
}

# Public Tcl commands in a mixed project call this bridge. Preserve Tcl's
# message and error code for legacy catch handlers and Tk background errors.
proc callExport {command declaration args} {
    try {
        $command {*}$args
    } on error {message options} {
        set where [mappedLocation $options [sourceMap] $declaration]
        dict set options -appcompilerlocation $where
        dict append options -errorinfo "\n    (typed source [string trimright [locationPrefix $where] {: }])"
        return -options $options $message
    }
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
        set where [mappedLocation $options $sourceMap]
        set prefix [expr {$where eq {} ? {} : [locationPrefix $where]}]
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

proc decode_text {bytes encodingName} {
    if {$encodingName eq "utf-8"} {return [decode_utf8 $bytes]}
    return [decodeNamed strict $encodingName $bytes]
}

proc preview_text {bytes encodingName} {
    return [decodeNamed replace $encodingName $bytes]
}

proc decodeNamed {profile encodingName bytes} {
    # Ordinary names can use Tcl's cached lookup directly. Only pass unusual
    # spellings to Tcl when advertised; its file lookup accepts paths, and a
    # NUL in a native-origin name can truncate the lookup on older hosts.
    if {$encodingName eq {} || [string first \u0000 $encodingName] >= 0 ||
            (![regexp {\A[A-Za-z0-9][A-Za-z0-9_.-]*\Z} $encodingName] && $encodingName ni [encoding names])} {
        return [list err [dict create code ENCODING message {expected the name of an available Tcl encoding}]]
    }
    if {$encodingName eq "cesu-8"} {
        return [list err [dict create code ENCODING \
            message {cesu-8 is unavailable because the bundled converter cannot reliably preserve data}]]
    }
    try {
        set text [encoding convertfrom -profile $profile -failindex offset $encodingName $bytes]
    } trap {TCL LOOKUP ENCODING} {message options} {
        return [list err [dict create code ENCODING message $message]]
    } on error {message options} {
        return [list err [dict create code DECODE message $message]]
    }
    if {$offset < 0} {return [list ok $text]}
    set size [string length $bytes]
    # Tcl 9.0.4's replacement profile can stop before one trailing byte
    # after replacing an unpaired UTF-16 surrogate. That byte cannot form
    # another code unit; preserve its position with its own replacement.
    if {$profile eq "replace" && $offset == $size - 1 && $size % 2 == 1 &&
            $encodingName in {utf-16 utf-16le utf-16be unicode ucs-2 ucs-2le ucs-2be}} {
        return [list ok $text\ufffd]
    }
    if {$offset == $size} {
        set message "incomplete $encodingName sequence at end of input (byte offset $offset)"
    } else {
        set message "invalid $encodingName sequence at byte offset $offset"
    }
    return [list err [dict create code DECODE byteOffset $offset message $message]]
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

# A NUL read through older native JSON can have a different internal byte
# spelling from the same Tcl character. Dictionary keys must use one spelling.
proc mapTextKey {value} {
    if {[string first \u0000 $value] < 0} {return $value}
    return [encoding convertfrom -profile strict utf-8 [encoding convertto -profile strict utf-8 $value]]
}

# Ask the native decoder for its own string representation. Quote each
# non-NUL part with the native writer so quotes, backslashes and literal
# \u sequences stay distinct from the inserted JSON escape. Plain decode
# suffices here: the constructed document is always a single JSON string.
proc nativeJsonText {value} {
    if {[string first \u0000 $value] < 0} {return $value}
    set interiors {}
    foreach part [split [mapTextKey $value] \u0000] {
        if {$part eq {}} {lappend interiors {}; continue}
        set encoded [::machteld::json encode -- [::machteld::json value string $part]]
        lappend interiors [string range $encoded 1 end-1]
    }
    return [::machteld::json decode "\"[join $interiors {\u0000}]\""]
}

proc mapLookup {map key} {
    if {[dict exists $map $key]} {return [list some [dict get $map $key]]}
    return [list none]
}

proc require_key {map key} {
    if {[dict exists $map $key]} {return [list ok [dict get $map $key]]}
    return [list err [dict create code MISSING_KEY message "missing map key [list $key]"]]
}

# Distinct scalar keys share the Tcl representation of their declared base.
proc scalarBase {type} {
    if {[string index $type 0] eq "."} {
        lassign [specializeSchema $type [schemas]] kind base
        if {$kind eq "distinct"} {return $base}
    }
    return $type
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
        instant - local_datetime {
            set value [fromWire text $node $path]
            if {[catch {temporalCanonical $head $value}]} {invalidWire "$path expects canonical $head text"}
            return $value
        }
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
            set rebuilt [::machteld::json value string [nativeJsonText $value]]
            if {[::machteld::json encode -- $rebuilt] ne [::machteld::json encode -- $node]} {
                invalidWire "$path cannot be preserved as text by this runtime"
            }
            return [mapTextKey $value]
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
        bytes - callable - ref {invalidWire "$path has no JSON representation for $head"}
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
            if {[scalarBase [lindex $parts 1]] ne "text"} {invalidWire "$path requires text keys for a JSON object"}
            if {$actual ne "object"} {invalidWire "$path expects an object, got $actual"}
            set out {}
            dict for {key child} [typedMembers $node] {
                set key [mapTextKey $key]
                if {[dict exists $out $key]} {invalidWire "$path contains duplicate Unicode map keys"}
                dict set out $key [fromWire [lindex $parts 2] $child "$path\[[list $key]\]"]
            }
            return $out
        }
    }
    lassign [specializeSchema $type [schemas]] kind members
    if {$kind eq "distinct"} {return [fromWire $members $node $path]}
    if {$kind ne "record"} {
        invalidWire "$path has no declared record wire format for $type"
    }
    if {$actual ne "object"} {invalidWire "$path expects an object, got $actual"}
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
    set head [lindex $parts 0]
    switch -exact -- $head {
        text {return [::machteld::json value string [nativeJsonText $value]]}
        instant - local_datetime {
            if {[catch {temporalCanonical $type $value}]} {invalidWire "$path expects canonical $type text"}
            return [::machteld::json value string $value]
        }
        int  {return [::machteld::json value number [guard int $value $path]]}
        decimal {return [::machteld::json value number [guard decimal $value $path]]}
        bool {return [::machteld::json value boolean [guard bool $value $path]]}
        bytes - callable - ref {invalidWire "$path has no JSON representation for $head"}
        list {
            set nodes {}
            foreach element $value {lappend nodes [toWire [lindex $parts 1] $element $path]}
            return [::machteld::json value array $nodes]
        }
        map {
            if {[scalarBase [lindex $parts 1]] ne "text"} {invalidWire "$path requires text keys for a JSON object"}
            set nodes {}
            dict for {key item} $value {
                dict set nodes [nativeJsonText $key] [toWire [lindex $parts 2] $item "$path\[[list $key]\]"]
            }
            return [::machteld::json value object $nodes]
        }
        optional {
            if {[lindex $value 0] ne "some"} {invalidWire "$path has no present value"}
            return [toWire [lindex $parts 1] [lindex $value 1] $path]
        }
    }
    lassign [specializeSchema $type [schemas]] kind members
    if {$kind eq "distinct"} {return [toWire $members $value $path]}
    if {$kind ne "record"} {
        invalidWire "$path has no declared record wire format for $type"
    }
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
    } trap {TCL ENCODING} {message opts} {
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
    } trap {TCL ENCODING} {message opts} {
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
        decimal - instant - local_datetime {return [string equal $left $right]}
        text {
            if {[string equal $left $right]} {return 1}
            if {[string first \u0000 $left] < 0} {return 0}
            return [string equal [mapTextKey $left] [mapTextKey $right]]
        }
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
    lassign [specializeSchema $type [schemas]] kind members
    if {$kind eq "distinct"} {return [equal $members $left $right]}
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
