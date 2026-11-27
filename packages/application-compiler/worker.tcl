# One pool with one supervised child per task. Each application gets its own
# registry and its own coroutine/owner identities.
variable workerSequence 0
variable workerOwners [dict create application {}]
variable workerWindows {}
variable workerHandlers {}
variable workerCloseHooks {}
variable workerTasks {}
variable workerTimeout 300000

proc workerProblem {code message} {return [list err [dict create code $code message $message]]}

# The outer pool protocol uses plain JSON. Prefix and base64 keep every
# payload a single JSON string. The inner Tcl list is read strictly as data.
# A generated concrete type and the existing recursive guards govern both ends.
proc workerEncode {type value} {
    variable workerMessageTypes
    if {![dict exists $workerMessageTypes $type]} {error {undeclared worker message type}}
    set data [list $type [guard $type $value message workerOutput]]
    if {[string length $data] <= 65536} {
        set bytes [encoding convertto -profile strict utf-8 $data]
        if {[string length $bytes] <= 65536} {return X1.[binary encode base64 -maxlen 0 $bytes]}
    }
    return -code error -errorcode {APPCOMPILER WORKER LIMIT} {worker message exceeds 65536 bytes}
}

proc workerDecode {type frame} {
    variable workerMessageTypes
    if {![dict exists $workerMessageTypes $type]} {error {undeclared worker message type}}
    if {[string length $frame] > 87387 || ![string match X1.* $frame]} {error {invalid typed worker frame}}
    set bytes [binary decode base64 -strict [string range $frame 3 end]]
    if {[string length $bytes] > 65536} {error {oversized typed worker frame}}
    set data [encoding convertfrom -profile strict utf-8 $bytes]
    if {[llength $data] != 2 || [lindex $data 0] ne $type} {error {worker message type mismatch}}
    return [guard $type [lindex $data 1] message worker]
}

proc workerInvoke {name frame} {
    variable workerTable
    lassign [dict get $workerTable $name] command request reply location
    set input [workerDecode $request $frame]
    try {
        set result [$command $input]
    } on error {message options} {
        set result [list err [dict create code WORKER_FAULT message $message \
            origin [mappedLocation $options [sourceMap] $location]]]
    }
    return [workerEncode $reply $result]
}

proc workerServe {} {
    variable workerTable
    dict for {name signature} $workerTable {
        ::machteld::worker on $name {frame} [format {tailcall %s %s $frame} [list [namespace current]::workerInvoke] [list $name]]
    }
    ::machteld::worker serve -maxframe 90000
}

proc guardTask {reply task path} {
    variable workerTasks
    if {![dict exists $workerTasks $task] || [dict get $workerTasks $task reply] ne "result<$reply,problem>"} {
        reject $path "a live task<$reply>"
    }
    return $task
}

proc workerStart {scope name input} {
    variable workerSequence
    variable workerTasks
    variable workerTable
    variable workerHandlers
    variable workerOwners
    variable workerTimeout
    set handler [info coroutine]
    if {$scope ne "start_app" && ![dict exists $workerHandlers $handler]} {
        return -code error -errorcode {APPCOMPILER WORKER CONTEXT} {start requires a managed handler; use start_app for application ownership}
    }
    set owner [expr {$scope eq "start_app" ? "application" : [dict get $workerHandlers $handler]}]
    if {![dict exists $workerOwners $owner]} {return -code error -errorcode {APPCOMPILER WORKER OWNER_CLOSED} {worker owner closed}}
    lassign [dict get $workerTable $name] command request reply
    set task [namespace current]::task[incr workerSequence]
    dict set workerTasks $task [dict create owner $owner reply $reply pool {} waiter {} notice {}]
    try {
        set frame [workerEncode $request $input]
        set prefix [::machteld::app launch]
        set pool [::machteld::pool create -width 1 -maxtries 1 -timeout ${workerTimeout}ms -maxitems 1 -maxframe 90000 \
            -maxbatch 90001 -maxresults 90001 -- {*}$prefix --machteld-typed-worker-v1]
        dict set workerTasks $task pool $pool
        ::machteld::pool call $pool [dict create op $name frame $frame] -command [list [namespace current]::workerFinished $task]
    } on error {message options} {
        set code [expr {[dict get $options -errorcode] eq {APPCOMPILER WORKER LIMIT} ? "WORKER_LIMIT" : "WORKER_START"}]
        workerReady $task [workerProblem $code $message]
    }
    return $task
}

proc workerFinished {task pool batch} {
    variable workerTasks
    if {![dict exists $workerTasks $task] || [dict get $workerTasks $task pool] ne $pool} return
    try {
        set replies [::machteld::pool result $pool $batch]
        if {[llength $replies] != 1} {error {worker returned an unexpected number of replies}}
        set item [lindex $replies 0]
        if {![dict get $item ok]} {
            set native [dict get $item code]
            set code [expr {$native in {{MACHTELD WORKER limit} {APPCOMPILER WORKER LIMIT}} ? "WORKER_LIMIT" : "WORKER_FAILED"}]
            set result [workerProblem $code [dict get $item msg]]
        } else {
            set result [workerDecode [dict get $workerTasks $task reply] [dict get $item result]]
        }
    } on error {message options} {
        set code [expr {[dict get $options -errorcode] eq {MACHTELD POOL limit} ? "WORKER_LIMIT" : "WORKER_PROTOCOL"}]
        set result [workerProblem $code $message]
    }
    workerReady $task $result
}

proc workerReady {task result} {
    variable workerTasks
    if {![dict exists $workerTasks $task] || [dict exists $workerTasks $task result]} return
    set pool [dict get $workerTasks $task pool]
    dict set workerTasks $task pool {}
    if {$pool ne {}} {::machteld::pool close $pool}
    dict set workerTasks $task result $result
    if {[dict get $workerTasks $task waiter] ne {}} {
        dict set workerTasks $task notice [after 0 [list [namespace current]::workerDeliver $task]]
    }
}

proc workerDeliver {task} {
    variable workerTasks
    variable workerHandlers
    variable workerOwners
    if {![dict exists $workerTasks $task]} return
    dict set workerTasks $task notice {}
    set co [dict get $workerTasks $task waiter]
    if {![dict exists $workerHandlers $co] || ![dict exists $workerOwners [dict get $workerHandlers $co]]} return
    eventBoundary worker-resume $co ready
}

proc await {task} {
    variable workerTasks
    variable workerHandlers
    variable workerOwners
    set co [info coroutine]
    if {![dict exists $workerHandlers $co]} {return [workerProblem WORKER_CONTEXT {await requires an application entry or workers handle}]}
    if {![dict exists $workerOwners [dict get $workerHandlers $co]]} {
        return -code error -errorcode {APPCOMPILER WORKER OWNER_CLOSED} {worker owner closed}
    }
    if {![dict exists $workerTasks $task]} {return [workerProblem WORKER_TASK {task was already consumed or released}]}
    if {[dict get $workerTasks $task waiter] ne {}} {return [workerProblem WORKER_TASK {task already has a waiting handler}]}
    if {![dict exists $workerTasks $task result]} {
        dict set workerTasks $task waiter $co
        set wake [yield]
        if {$wake eq "closed"} {return -code error -errorcode {APPCOMPILER WORKER OWNER_CLOSED} {worker owner closed}}
    }
    set result [dict get $workerTasks $task result]
    dict unset workerTasks $task
    return $result
}

proc cancel {task} {
    workerReady $task [workerProblem WORKER_CANCELED {worker task canceled}]
    return {}
}

proc workerHandle {owner prefix args} {
    variable workerSequence
    variable workerOwners
    variable workerHandlers
    if {![dict exists $workerOwners $owner]} {error {worker owner is closed or unknown}}
    set co [namespace current]::handler[incr workerSequence]
    dict set workerHandlers $co $owner
    coroutine $co [namespace current]::workerRunHandler $co [list {*}$prefix {*}$args]
}

proc workerRunHandler {co command} {
    variable workerHandlers
    try {
        uplevel #0 $command
    } trap {APPCOMPILER WORKER OWNER_CLOSED} {} {
        return
    } finally {
        dict unset workerHandlers $co
    }
}

proc workerOwnerLive {owner} {
    variable workerOwners
    return [dict exists $workerOwners $owner]
}
proc workerOnClose {owner prefix} {
    variable workerCloseHooks
    variable workerSequence
    if {$owner eq "application" || ![workerOwnerLive $owner]} {error "invalid handler owner"}
    set token [incr workerSequence]
    dict set workerCloseHooks $owner $token $prefix
    return $token
}
proc workerForgetClose {owner token} {
    variable workerCloseHooks
    if {[dict exists $workerCloseHooks $owner $token]} {
        dict unset workerCloseHooks $owner $token
        if {![dict size [dict get $workerCloseHooks $owner]]} {dict unset workerCloseHooks $owner}
    }
}

proc workerCloseOwner {owner} {
    variable workerOwners
    variable workerWindows
    variable workerTasks
    variable workerHandlers
    variable workerCloseHooks
    if {$owner eq "application"} {error {application scope lasts until process exit}}
    if {![dict exists $workerOwners $owner]} return
    set window [dict get $workerOwners $owner]
    dict unset workerOwners $owner
    if {$window ne ""} {
        dict unset workerWindows $window
        set tag [namespace current]::$owner
        bind $tag <Destroy> {}
        if {[winfo exists $window]} {
            bindtags $window [lsearch -all -inline -not -exact [bindtags $window] $tag]
        }
    }
    set hooks [dict getdef $workerCloseHooks $owner {}]
    dict unset workerCloseHooks $owner
    set faults {}
    dict for {token prefix} $hooks {
        if {[catch {{*}$prefix} message options]} {lappend faults [list $message $options]}
    }
    set stopped {}
    # Detach a window's suspended handler even when another scope owns its task.
    dict for {task state} $workerTasks {
        set co [dict get $state waiter]
        if {$co ne "" && [dict getdef $workerHandlers $co {}] eq $owner} {
            dict set stopped $co 1
            dict set workerTasks $task waiter {}
            set timer [dict get $state notice]
            if {$timer ne ""} {after cancel $timer; dict set workerTasks $task notice {}}
        }
        if {[dict get $state owner] eq $owner} {
            cancel $task
            # A handler in a different, surviving scope receives cancellation.
            if {[dict get $workerTasks $task waiter] eq ""} {dict unset workerTasks $task}
        }
    }
    dict for {co unused} $stopped {
        if {[llength [info commands $co]] && [catch {$co closed} message options]} {
            lappend faults [list $message $options]
        }
    }
    if {[llength $faults]} {
        lassign [lindex $faults 0] message options
        return -options $options $message
    }
}

proc workerWindowDestroyed {owner destroyed} {
    variable workerOwners
    if {[dict getdef $workerOwners $owner {}] eq $destroyed} {workerCloseOwner $owner}
}

proc workerControl {subcommand args} {
    variable workerOwners
    variable workerSequence
    variable workerWindows
    variable workerTimeout
    switch -exact -- $subcommand {
        timeout {
            if {[llength $args] == 0} {return $workerTimeout}
            set ms [lindex $args 0]
            if {[llength $args] != 1 || ![string is entier -strict $ms] || $ms < 1 || $ms > 4294967294} {
                error {worker timeout must be 1 through 4294967294 milliseconds}
            }
            set workerTimeout [expr {$ms + 0}]
        }
        owner {
            if {[llength $args]} {error {usage: workers owner}}
            set owner owner#[incr workerSequence]
            dict set workerOwners $owner {}
            return $owner
        }
        window {
            if {[llength $args] != 1} {error {usage: workers window TOPLEVEL}}
            set window [lindex $args 0]
            if {![winfo exists $window] || [winfo toplevel $window] ne $window} {error {expected a live Tk toplevel}}
            if {[dict exists $workerWindows $window]} {return [dict get $workerWindows $window]}
            set owner owner#[incr workerSequence]
            # A private tag avoids overwriting the application's own Destroy binding.
            set tag [namespace current]::$owner
            bind $tag <Destroy> [list [namespace current]::eventBoundary worker-window-close \
                [list [namespace current]::workerWindowDestroyed $owner] %W]
            bindtags $window [linsert [bindtags $window] 0 $tag]
            dict set workerWindows $window $owner
            dict set workerOwners $owner $window
            return $owner
        }
        handle {tailcall [namespace current]::workerHandle {*}$args}
        close {tailcall [namespace current]::workerCloseOwner {*}$args}
        default {error {expected workers owner, window, handle, close or timeout}}
    }
}

# Only the outermost typed console entry drives an event loop. A Tcl/Tk
# application retains its own loop; an awaiting handler only yields its coroutine.
proc workerMain {command args} {
    variable workerSequence
    set done [namespace current]::entry[incr workerSequence]
    try {
        workerHandle application [list [namespace current]::workerMainBody $done $command] {*}$args
        if {![info exists $done]} {vwait $done}
        lassign [set $done] status options
        return -options $options $status
    } finally {unset -nocomplain $done}
}

proc workerMainBody {done command args} {
    catch {$command {*}$args} status options
    set $done [list $status $options]
}
