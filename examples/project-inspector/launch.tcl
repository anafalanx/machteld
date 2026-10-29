# Application-owned roles: no runtime special cases or shell command strings.
namespace eval ::inspector { variable finished 0 }

proc ::inspector::worker_command {entry} {
    if {[lindex [file system $entry] 0] eq "zipfs"} {
        return [list [info nameofexecutable] --worker]
    }
    return [list [info nameofexecutable] [file normalize $entry] --worker]
}

proc ::inspector::no_window {} {
    # GUI basekits initialize Tk before sourcing the entry. Destroy the
    # unmapped root before any event/idle processing in non-UI roles.
    if {[llength [info commands ::destroy]]} { ::destroy . }
}

proc ::inspector::finished {object state} {
    if {[dict get $state phase] ne "running"} { set ::inspector::finished 1 }
}

proc ::inspector::snapshot_json {state} {
    set fields {}
    dict for {key value} $state {
        if {$key eq "rows"} {
            set rows {}
            foreach row $value {
                set fieldsInRow {}
                dict for {name item} $row {
                    dict set fieldsInRow $name [::machteld::json value \
                        [expr {$name eq "size" ? "number" : "string"}] $item]
                }
                lappend rows [::machteld::json value object $fieldsInRow]
            }
            dict set fields $key [::machteld::json value array $rows]
        } else {
            dict set fields $key [::machteld::json value \
                [expr {$key eq "progress" ? "number" : "string"}] $value]
        }
    }
    return [::machteld::json encode [::machteld::json value object $fields]]
}

proc ::inspector::main {here arguments} {
    set role [lindex $arguments 0]
    if {$role in {--worker --headless}} {
        no_window
        fconfigure stdout -encoding utf-8 -translation lf
        fconfigure stderr -encoding utf-8 -translation lf
        try {
            set argv [lrange $arguments 1 end]
            if {$role eq "--worker"} {
                set ::argv $argv
                set ::argc [llength $argv]
                uplevel #0 [list source [file join $here inspect.tcl]]
                exit 0
            }
            if {[llength $argv] ni {1 2}} { error "usage: --headless directory ?inspect|slow|fail|noisy?" }
            lassign $argv directory mode
            if {$mode eq {}} { set mode inspect }
            source [file join $here model.tcl]
            set job [::inspector::Job new [file join $here inspect.tcl] \
                ::inspector::finished [worker_command [file join $here main.tcl]]]
            try {
                set ::inspector::finished 0
                $job start $directory $mode
                if {!$::inspector::finished} { vwait ::inspector::finished }
                set state [$job snapshot]
            } finally { $job destroy }
            puts [snapshot_json $state]
            exit [expr {[dict get $state phase] eq "done" ? 0 : 1}]
        } on error {message options} {
            puts stderr $message
            exit 2
        }
    }
    if {$role eq "--"} { set arguments [lrange $arguments 1 end] }
    if {[llength $arguments] > 1 || ($role ne "--" && [string match --* $role])} {
        no_window
        puts stderr "usage: ?--? ?directory? | --headless directory ?mode? | --worker directory mode"
        exit 2
    }
    package require Tk
    source [file join $here model.tcl]
    source [file join $here view.tcl]
    set directory [expr {[llength $arguments] ? [lindex $arguments 0] : [pwd]}]
    ::inspector::open $directory [file join $here inspect.tcl] \
        [worker_command [file join $here main.tcl]]
    vwait ::inspector::closed
}
