package require machteld
namespace eval ::machteld::browser {
    variable session
    variable notice
    variable serial 0
}
source -encoding utf-8 [file join [file dirname [info script]] wire.tcl]

proc ::machteld::browser::Fail {code message} {
    return -code error -errorcode [list MACHTELD BROWSER $code] $message
}

proc ::machteld::browser::Nonce {} {binary encode hex [::machteld::hash random 16]}

proc ::machteld::browser::Options {defaults words} {
    if {[llength $words] % 2} {Fail usage {expected option and value pairs}}
    set seen {}
    foreach {key value} $words {
        if {![dict exists $defaults $key] || [dict exists $seen $key]} {Fail usage "unknown or duplicate browser option $key"}
        dict set seen $key 1
        dict set defaults $key $value
    }
    return $defaults
}

proc ::machteld::browser::Deadline {duration} {
    expr {[clock clicks -milliseconds] + [::machteld::_dur2ms BROWSER $duration]}
}

proc ::machteld::browser::Remaining {deadline} {
    set ms [expr {$deadline - [clock clicks -milliseconds]}]
    if {$ms <= 0} {Fail timeout {browser operation timed out}}
    return $ms
}

proc ::machteld::browser::Tick {deadline} {
    variable serial
    set name [namespace current]::tick[incr serial]
    set timer [after [expr {min(40,[Remaining $deadline])}] [list set $name 1]]
    try {vwait $name} finally {after cancel $timer; unset -nocomplain $name}
}

proc ::machteld::browser::Executable {selected} {
    if {$selected eq {}} {
        foreach {var parts} {
            ProgramFiles(x86) {Microsoft Edge Application msedge.exe}
            ProgramFiles {Microsoft Edge Application msedge.exe}
            ProgramFiles {Google Chrome Application chrome.exe}
            LOCALAPPDATA {Google Chrome Application chrome.exe}
            LOCALAPPDATA {Chromium Application chrome.exe}
        } {
            if {[info exists ::env($var)] && [file isfile [set path [file join $::env($var) {*}$parts]]]} {return [file normalize $path]}
        }
        Fail notfound {no installed Edge or Chromium browser was found}
    }
    if {[string first \0 $selected] >= 0 || [string tolower [file tail $selected]] ni {msedge.exe chrome.exe chromium.exe}} {
        Fail badvalue {select a local Edge or Chromium executable}
    }
    if {![file isfile $selected]} {Fail notfound {the selected browser is unavailable}}
    return [file normalize $selected]
}

# A marker binds the opt-in to the actual directory, including across application
# restarts. Unmarked nonempty directories are refused before creating any file.
proc ::machteld::browser::Plain {path} {
    if {[catch {set facts [::machteld::canon $path]}] || [dict get $facts kind] ne "file" ||
            [dict get $facts links] != 1 || [file type $path] ne "file" ||
            [::machteld::_path_key [dict get $facts path]] ne [::machteld::_path_key $path]} {
        Fail ownership {browser ownership file must be a regular file in the selected profile}
    }
    return [::machteld::_canon_key $facts]
}

proc ::machteld::browser::ReadSmall {path} {
    set identity [Plain $path]
    set f [open $path rb]
    try {set bytes [read $f 4097]} finally {close $f}
    if {[string length $bytes] > 4096 || $identity ne [Plain $path] ||
            [catch {encoding convertfrom -profile strict utf-8 $bytes} value]} {
        Fail ownership {invalid browser profile record}
    }
    return $value
}

proc ::machteld::browser::Profile {raw create} {
    if {$raw eq {} || [string first \0 $raw] >= 0 || [file pathtype $raw] eq "volumerelative" ||
            [string match {//*} [string map {\\ /} $raw]]} {
        Fail badvalue {supply a profile directory path}
    }
    set parent [file dirname $raw]
    set missing {}
    while {![file exists $parent]} {
        if {!$create} {Fail notfound {browser profile does not exist}}
        if {![catch {file lstat $parent st}] || [file dirname $parent] eq $parent} {Fail ownership {invalid profile parent}}
        lappend missing $parent
        set parent [file dirname $parent]
    }
    if {[catch {::machteld::_pack_no_links $parent}] || ![file isdirectory $parent]} {Fail ownership {profile parent must be an ordinary local directory}}
    foreach dir [lreverse $missing] {
        file mkdir $dir
        if {[catch {::machteld::_pack_no_links $dir}]} {Fail ownership {invalid profile parent}}
    }
    if {![file exists $raw]} {
        if {!$create} {Fail notfound {browser profile does not exist}}
        if {![catch {file lstat $raw st}]} {Fail ownership {invalid browser profile path}}
        file mkdir $raw
    }
    if {![file isdirectory $raw] || [catch {::machteld::_pack_no_links $raw}]} {Fail ownership {profile must be an ordinary directory}}
    set profile [file normalize $raw]
    set identity [::machteld::_canon_key [::machteld::canon $profile]]
    set marker [file join $profile .machteld-browser-owner]
    if {[catch {file lstat $marker st}]} {
        if {!$create || [llength [::machteld::_children $profile]]} {Fail ownership {profile has no Machteld ownership marker}}
        set f [open $marker {WRONLY CREAT EXCL BINARY}]
        try {puts -nonewline $f [dict create schema 1 identity $identity owner [Nonce]]} finally {close $f}
    }
    set record [ReadSmall $marker]
    if {[catch {expr {[dict get $record schema] eq "1" && [dict get $record identity] eq $identity &&
            [regexp {^[a-f0-9]{32}$} [dict get $record owner]]}} ok] || !$ok} {
        Fail ownership {profile ownership marker does not match the selected directory}
    }
    return [list $profile [dict get $record owner]]
}

proc ::machteld::browser::Receipt {s} {
    set file [file join [dict get $s profile] .machteld-browser-session]
    if {[catch {file lstat $file st}]} {return {}}
    set r [ReadSmall $file]
    if {[catch {expr {[dict get $r schema] eq "1" && [dict get $r owner] eq [dict get $s owner] &&
            [string is wideinteger -strict [dict get $r pid]] && [string is wideinteger -strict [dict get $r stamp]] &&
            [regexp {^[a-f0-9]{32}$} [dict get $r tag]] && [dict exists $r endpoint] && [dict exists $r target]}} ok] || !$ok} {
        Fail ownership {invalid browser session receipt}
    }
    return $r
}

proc ::machteld::browser::Persist {t} {
    variable session
    set s $session($t)
    set path [file join [dict get $s profile] .machteld-browser-session]
    if {![catch {file lstat $path st}]} {Plain $path}
    ::machteld::publish bytes $path [encoding convertto utf-8 [dict get $s receipt]]
}

proc ::machteld::browser::RecordStart {t pid stamp} {
    variable session
    dict set session($t) receipt pid $pid
    dict set session($t) receipt stamp $stamp
    Persist $t
}

proc ::machteld::browser::Configure {t deadline starting pid stamp} {
    variable session
    set s $session($t)
    set r [dict get $s receipt]
    set file [file join [dict get $s profile] DevToolsActivePort]
    while {1} {
        if {$starting} {
            set alive [::machteld::BrowserStartupOwner $pid $stamp]
        } else {
            set alive [::machteld::BrowserPeer $pid $stamp]
        }
        if {!$alive} {Fail closed {owned browser process exited before connection}}
        if {[file exists $file]} {
            set report [string trimright [ReadSmall $file] "\r\n"]
            if {[regexp {^([1-9][0-9]{0,4})\r?\n(/devtools/browser/[0-9a-fA-F-]{36})$} $report -> port resource] &&
                    $port <= 65535 && [dict get $s previousEndpoint] ne [list $port $resource]} {
                if {$starting} {
                    set successor [::machteld::BrowserStartupOwner $pid $stamp $port]
                    if {$successor ne {}} {
                        lassign $successor pid stamp
                        RecordStart $t $pid $stamp
                        break
                    }
                } elseif {[::machteld::BrowserPeer $pid $stamp $port]} break
            }
        }
        Tick $deadline
    }
    set endpoint [list $port $resource]
    if {[dict get $r endpoint] ne {} && [dict get $r endpoint] ne $endpoint} {Fail ownership {owned browser endpoint changed}}
    wire::Connect $t $port $resource [Remaining $deadline]
    if {![::machteld::BrowserPeer $pid $stamp $port]} {Fail ownership {browser listener changed during connection}}
    set target [dict get $r target]
    if {$target eq {}} {
        set url "about:blank#machteld-[dict get $r tag]"
        set pages [wire::Request $t Target.getTargets {} {} [Remaining $deadline]]
        foreach row [dict get $pages targetInfos] {
            if {[dict get $row type] eq "page" && [dict get $row url] eq $url} {set target [dict get $row targetId]; break}
        }
        if {$target eq {}} {
            set params [dict create url [::machteld::json value string $url]]
            set target [dict get [wire::Request $t Target.createTarget $params {} [Remaining $deadline]] targetId]
        }
        dict set session($t) receipt target $target
        dict set session($t) receipt endpoint $endpoint
        Persist $t
    }
    set params [dict create targetId [::machteld::json value string $target] flatten [::machteld::json value boolean true]]
    set attached [wire::Request $t Target.attachToTarget $params {} [Remaining $deadline]]
    set flat [dict get $attached sessionId]
    dict set session($t) flat $flat
    wire::Request $t Page.enable {} $flat [Remaining $deadline]
    wire::Request $t Page.setLifecycleEventsEnabled [dict create enabled [::machteld::json value boolean true]] $flat [Remaining $deadline]
    dict set session($t) receipt target $target
    dict set session($t) receipt endpoint $endpoint
    Persist $t
    dict set session($t) state open
    return $t
}

proc ::machteld::browser::Acquire {op words} {
    variable session
    set create [expr {$op eq "launch"}]
    set defaults [dict create -profile {} -timeout 30s]
    if {$create} {dict set defaults -headless 0; dict set defaults -executable {}}
    set options [Options $defaults $words]
    set deadline [Deadline [dict get $options -timeout]]
    if {$create} {
        set headless [dict get $options -headless]
        if {![string is boolean -strict $headless]} {Fail badvalue {-headless requires a boolean}}
        set exe [Executable [dict get $options -executable]]
    }
    lassign [Profile [dict get $options -profile] $create] profile owner
    set path [file join $profile .machteld-browser-lock]
    if {![catch {file lstat $path st}]} {Plain $path}
    set lock [::machteld::lock try $path]
    if {$lock eq {}} {Fail busy {another controller holds this browser profile}}
    set t "browser-[Nonce]"
    set session($t) [dict create profile $profile owner $owner lock $lock state starting flat {} nav {} previousEndpoint {}]
    try {
        set r [Receipt $session($t)]
        set alive [expr {$r ne {} && [::machteld::BrowserPeer [dict get $r pid] [dict get $r stamp]]}]
        if {!$create} {
            if {!$alive} {Fail closed {there is no live Machteld browser in this profile}}
            dict set session($t) receipt $r
            return [Configure $t $deadline 0 [dict get $r pid] [dict get $r stamp]]
        }
        if {$alive} {Fail busy {browser is already running, use attach}}
        if {$r ne {}} {dict set session($t) previousEndpoint [dict get $r endpoint]}
        set tag [Nonce]
        dict set session($t) receipt [dict create schema 1 owner $owner tag $tag target {} endpoint {}]
        set args [list "--user-data-dir=[file nativename $profile]" --remote-debugging-port=0 --remote-debugging-address=127.0.0.1 \
            --no-first-run --no-default-browser-check --disable-background-networking --disable-background-mode]
        if {$headless} {lappend args --headless=new}
        lappend args "about:blank#machteld-$tag"
        return [::machteld::BrowserStart $exe $args [list [namespace current]::RecordStart $t] [list [namespace current]::Configure $t $deadline 1]]
    } on error {message opts} {
        Release $t
        return -options $opts $message
    }
}

proc ::machteld::browser::Lookup {t {mustOpen 1}} {
    variable session
    if {![info exists session($t)]} {Fail closed {unknown or released browser session}}
    if {$mustOpen && [dict get $session($t) state] ne "open"} {Fail closed {browser is no longer connected}}
    return $session($t)
}

proc ::machteld::browser::Finish {t status {message {}}} {
    variable session; variable notice
    if {[dict get $session($t) nav] eq {} || [dict get $session($t) nav status] ne "pending"} return
    dict set session($t) nav status $status
    dict set session($t) nav message $message
    dict set session($t) nav loads {}
    incr notice($t)
}

proc ::machteld::browser::Disconnected {t message} {
    variable session
    if {[info exists session($t)]} {
        if {[dict get $session($t) state] ne "closing"} {dict set session($t) state disconnected}
        Finish $t failed $message
    }
}

proc ::machteld::browser::Message {t packet} {
    variable session
    if {![info exists session($t)]} return
    set s $session($t)
    set flat [dict get $s flat]
    if {[dict exists $packet method] && [dict get $packet method] eq "Target.detachedFromTarget" &&
            [dict exists $packet params sessionId] && [dict get $packet params sessionId] eq $flat} {
        dict set session($t) state tabclosed
        Finish $t failed {the selected browser tab closed}
        return
    }
    set nav [dict get $s nav]
    if {$nav eq {} || [dict get $nav status] ne "pending" || ![dict exists $packet sessionId] ||
            [dict get $packet sessionId] ne $flat} return
    if {[dict exists $packet id]} {
        if {[dict get $packet id] != [dict get $nav id]} return
        if {[dict exists $packet error] || [dict exists $packet result errorText]} {
            set reason {browser rejected navigation}
            if {[dict exists $packet result errorText]} {set reason [dict get $packet result errorText]}
            Finish $t failed $reason
            return
        }
        if {![dict exists $packet result frameId] ||
                ([dict exists $packet result isDownload] && [dict get $packet result isDownload])} {
            Finish $t failed {navigation produced no document}
            return
        }
        if {![dict exists $packet result loaderId]} {Finish $t ready; return}
        set target [list [dict get $packet result frameId] [dict get $packet result loaderId]]
        dict set session($t) nav document $target
        if {$target in [dict get $nav loads]} {Finish $t ready}
    } elseif {[dict exists $packet method] && [dict get $packet method] eq "Page.lifecycleEvent" &&
            [dict get $packet params name] eq "load"} {
        set completed [list [dict get $packet params frameId] [dict get $packet params loaderId]]
        if {[dict get $nav document] eq $completed} {Finish $t ready
        } elseif {[dict get $nav document] eq {}} {
            # A load can arrive before the Page.navigate response associates
            # our navigation with its exact frame and document loader.
            dict set session($t) nav loads [lrange [linsert [dict get $nav loads] end $completed] end-31 end]
        }
    }
}

proc ::machteld::browser::Navigate {t url} {
    variable session
    set s [Lookup $t]
    if {[string length $url] > 65536 || ![regexp -nocase {^https?://[^/?#[:space:]]+} $url] || [regexp {[[:cntrl:][:space:]]} $url]} {
        Fail badvalue {expected an HTTP or HTTPS URL}
    }
    if {[dict get $s nav] ne {} && [dict get $s nav status] eq "pending"} {Fail busy {cancel or finish the pending navigation}}
    set nav "navigation-[Nonce]"
    set id [wire::Send $t Page.navigate [dict create url [::machteld::json value string $url]] [dict get $s flat]]
    dict set session($t) nav [dict create token $nav id $id url $url status pending message {} document {} loads {}]
    return $nav
}

proc ::machteld::browser::Navigation {t token} {
    set s [Lookup $t 0]
    set nav [dict get $s nav]
    if {$nav eq {} || [dict get $nav token] ne $token} {Fail notfound {unknown or replaced navigation token}}
    return $nav
}

proc ::machteld::browser::Report {nav status} {
    return [dict create status $status url [dict get $nav url] message [dict get $nav message]]
}

proc ::machteld::browser::Wait {t token args} {
    variable notice
    set opts [Options {-timeout 30s} $args]
    set deadline [Deadline [dict get $opts -timeout]]
    while {1} {
        set nav [Navigation $t $token]
        set status [dict get $nav status]
        if {$status ne "pending"} {return [Report $nav $status]}
        set ms [expr {$deadline - [clock clicks -milliseconds]}]
        if {$ms <= 0} {return [Report $nav timeout]}
        set timer [after $ms [list incr [namespace current]::notice($t)]]
        try {vwait [namespace current]::notice($t)} finally {after cancel $timer}
    }
}

proc ::machteld::browser::Cancel {t token} {
    set nav [Navigation $t $token]
    if {[dict get $nav status] eq "pending"} {
        set s [Lookup $t]
        wire::Send $t Page.stopLoading {} [dict get $s flat]
        Finish $t cancelled
    }
    set nav [Navigation $t $token]
    return [Report $nav [dict get $nav status]]
}

proc ::machteld::browser::Release {t} {
    variable session; variable notice
    set s [Lookup $t 0]
    wire::Forget $t
    unset session($t)
    unset -nocomplain notice($t)
    ::machteld::lock release [dict get $s lock]
    return
}

proc ::machteld::browser::Close {t args} {
    variable session
    set s [Lookup $t 0]
    set opts [Options {-timeout 10s} $args]
    set deadline [Deadline [dict get $opts -timeout]]
    set r [dict get $s receipt]
    set pid [dict get $r pid]; set stamp [dict get $r stamp]
    if {[::machteld::BrowserPeer $pid $stamp]} {
        if {[dict get $s state] in {open tabclosed}} {
            wire::Send $t Browser.close {} {}
            dict set session($t) state closing
        } elseif {[dict get $s state] ne "closing"} {
            Fail closed {browser connection was lost, release and reattach this profile}
        }
        while {[::machteld::BrowserPeer $pid $stamp]} {Tick $deadline}
    }
    Release $t
    return
}

proc ::machteld::browser::Dispatch {args} {
    set argv [lassign $args op]
    try {
        switch -- $op {
            attach - launch {return [Acquire $op $argv]}
            navigate - cancel {
                if {[llength $argv] != 2} {Fail usage "browser $op requires a session and a value"}
                if {$op eq "navigate"} {return [Navigate {*}$argv]}
                return [Cancel {*}$argv]
            }
            wait {
                if {[llength $argv] < 2} {Fail usage {browser wait requires a session and a navigation}}
                return [Wait {*}$argv]
            }
            close {
                if {![llength $argv]} {Fail usage {browser close requires a session}}
                return [Close {*}$argv]
            }
            release {
                if {[llength $argv] != 1} {Fail usage {browser release requires one session}}
                return [Release {*}$argv]
            }
            default {Fail usage {expected browser launch, attach, navigate, wait, cancel, release or close}}
        }
    } trap {MACHTELD BROWSER} {message opts} {
        return -options $opts $message
    } on error {message opts} {
        Fail oserror $message
    }
}

package provide machteld::browser 1.0
