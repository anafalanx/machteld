package require Tk
package require machteld::job 1.0

namespace eval ::lookup {
    variable job {}
    variable temporary {}
    variable renderTimer {}
    variable phase idle
    variable category All
    variable status {}
}

proc ::lookup::open {path workerCommand} {
    variable file $path
    variable worker $workerCommand
    variable needsDemo [expr {$path eq {}}]
    variable categories
    variable job

    wm title . "Catalogue Lookup"
    wm minsize . 470 300
    wm geometry . 690x500
    wm protocol . WM_DELETE_WINDOW ::lookup::close
    ttk::frame .filters -padding 10
    ttk::label .filters.label -text Category
    ttk::combobox .filters.category -values $categories -textvariable ::lookup::category \
        -state readonly -width 12
    ttk::button .filters.search -text Search -command ::lookup::search
    ttk::button .filters.cancel -text Cancel -command ::lookup::cancel
    grid .filters.label .filters.category .filters.search .filters.cancel -padx 3
    ttk::treeview .results -columns {id category name} -show headings -selectmode browse
    foreach {column label width stretch} {id ID 75 0 category Category 100 0 name Name 300 1} {
        .results heading $column -text $label
        .results column $column -width $width -stretch $stretch
    }
    ttk::scrollbar .scroll -command {.results yview}
    .results configure -yscrollcommand {.scroll set}
    ttk::frame .footer -padding 10
    ttk::label .footer.status -textvariable ::lookup::status -wraplength 350
    ttk::button .footer.next -text {Next page} -command ::lookup::next
    grid .footer.status .footer.next -sticky ew -padx 3
    grid columnconfigure .footer 0 -weight 1
    grid .filters -row 0 -column 0 -columnspan 2 -sticky w
    grid .results -row 1 -column 0 -sticky nsew -padx {10 0}
    grid .scroll -row 1 -column 1 -sticky ns -padx {0 10}
    grid .footer -row 2 -column 0 -columnspan 2 -sticky ew
    grid columnconfigure . 0 -weight 1
    grid rowconfigure . 1 -weight 1
    bind .filters.category <<ComboboxSelected>> ::lookup::search
    bind . <Control-Return> {::lookup::search; break}
    bind . <Escape> {::lookup::cancel; break}
    bind . <Destroy> {if {[string equal %W .]} {::lookup::close}}

    set job [::machteld::job::Job new ::lookup::onJob]
    search
}

proc ::lookup::clearTimer {} {
    variable renderTimer
    if {$renderTimer ne {}} { after cancel $renderTimer; set renderTimer {} }
}

proc ::lookup::discardDemo {} {
    variable temporary
    if {$temporary eq {}} { return }
    file delete -force $temporary ${temporary}-journal
    set temporary {}
}

proc ::lookup::search {} {
    variable category
    startPage $category 0
}

proc ::lookup::next {} {
    variable phase
    variable more
    variable filter
    variable lastId
    if {$phase eq "ready" && $more} { startPage $filter $lastId }
}

proc ::lookup::startPage {selection cursor} {
    variable phase
    variable filter $selection
    variable lastId $cursor
    variable pending {}
    variable received 0
    variable sealed 0
    variable workerDone 0
    variable more 0
    variable status
    variable job
    variable file
    variable worker
    variable temporary
    variable needsDemo
    if {$phase eq "closed"} { return }
    # Ignore the old job's synchronous cancellation notification during a restart.
    set phase idle
    $job cancel
    clearTimer
    set rows [.results children {}]
    if {[llength $rows]} { .results delete $rows }
    .footer.next state disabled
    .filters.cancel state !disabled
    set phase loading
    try {
        if {$needsDemo} {
            discardDemo
            set channel [file tempfile temporary]
            ::close $channel
            set file $temporary
            set status "Preparing the 125,000-item demo…"
            $job start [list {*}$worker seed $file]
        } else {
            set status "Opening catalogue…"
            $job start [list {*}$worker page $file $filter $cursor]
        }
    } on error {message options} {
        fail $message
    }
}

proc ::lookup::onJob {source event data} {
    variable phase
    variable needsDemo
    variable filter
    variable status
    variable sealed
    variable workerDone
    if {$phase ne "loading"} { return }
    switch -- $event {
        lines {
            foreach line $data {
                set record [::machteld::json decode -typed -maxbytes 4096 $line]
                accept [::machteld::json unwrap $record]
            }
            scheduleRender
        }
        finished {
            if {[dict get $data phase] ne "done"} {
                set reason [string trim [dict get $data log]]
                if {$reason eq {}} { set reason [dict get $data error] }
                fail $reason
            } elseif {$needsDemo} {
                set needsDemo 0
                startPage $filter 0
            } elseif {!$sealed} {
                fail "The worker closed before the end of the page."
            } else {
                set workerDone 1
                scheduleRender
            }
        }
    }
}

proc ::lookup::accept {record} {
    variable status
    variable sealed
    variable pending
    variable received
    variable pageSize
    variable lastId
    variable more
    if {$sealed} { error "Unexpected data after the end of the page" }
    switch -- [dict get $record type] {
        opened { set status "Reading catalogue…" }
        row {
            set id [dict get $record id]
            if {$received >= $pageSize || ![string is wideinteger -strict $id] || $id <= $lastId} {
                error "Unexpected catalogue row"
            }
            set lastId $id
            lappend pending [list $id [dict get $record category] [dict get $record name]]
            incr received
        }
        end {
            set more [dict get $record more]
            if {$more ni {0 1} || ($more && $received != $pageSize)} { error "Invalid page cursor" }
            set sealed 1
        }
        default { error "Unknown worker reply" }
    }
}

proc ::lookup::scheduleRender {} {
    variable renderTimer
    if {$renderTimer eq {}} { set renderTimer [after 1 ::lookup::render] }
}

proc ::lookup::render {} {
    variable phase
    variable renderTimer {}
    variable pending
    variable workerDone
    variable received
    variable more
    variable status
    if {$phase ne "loading"} { return }
    # Even a full page delivered in a single pipe read gets multiple Tk turns.
    foreach row [lrange $pending 0 7] { .results insert {} end -id [lindex $row 0] -values $row }
    set pending [lrange $pending 8 end]
    if {[llength $pending]} {
        scheduleRender
    } elseif {$workerDone} {
        set phase [expr {$received ? "ready" : "empty"}]
        set status [expr {$received ? "$received items on this page." : "No matching items."}]
        .filters.cancel state disabled
        if {$more} { .footer.next state !disabled }
    }
}

proc ::lookup::fail {message} {
    variable phase error
    variable status "Lookup failed: [string range $message 0 360]"
    clearTimer
    set rows [.results children {}]
    if {[llength $rows]} { .results delete $rows }
    .filters.cancel state disabled
    .footer.next state disabled
}

proc ::lookup::cancel {} {
    variable phase
    variable job
    variable status
    if {$phase ne "loading"} { return }
    set phase canceled
    $job cancel
    clearTimer
    set rows [.results children {}]
    if {[llength $rows]} { .results delete $rows }
    set status "Canceled."
    .filters.cancel state disabled
    .footer.next state disabled
}

proc ::lookup::close {} {
    variable phase
    variable job
    if {$phase eq "closed"} { return }
    set phase closed
    clearTimer
    if {$job ne {}} { $job destroy; set job {} }
    try { discardDemo } finally { if {[winfo exists .]} { destroy . } }
}
