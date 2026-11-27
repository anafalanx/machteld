namespace eval ::reader {}

proc ::reader::acquire {path} {
    if {[catch {open $path rb} channel]} {
        return [list err [dict create code OPEN message $channel]]
    }
    return [list ok $channel]
}

proc ::reader::line {channel} {
    try {
        if {[gets $channel bytes] < 0} {return [list ok [list none]]}
        if {![eof $channel] && [string index $bytes end] eq "\r"} {
            set bytes [string range $bytes 0 end-1]
        }
        set text [encoding convertfrom -profile strict utf-8 $bytes]
        return [list ok [list some $text]]
    } on error {message} {
        return [list err [dict create code READ message $message]]
    }
}

proc ::reader::release {channel} {
    if {[catch {close $channel} message]} {return [list err [dict create code CLOSE message $message]]}
    return [list ok {}]
}

package provide example::reader 1.0
