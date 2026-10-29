namespace eval ::inspector {
    variable job {}; variable renderTimer {}; variable latest {}
    variable directory {}; variable progress 0; variable status Ready
    variable closed 0; variable shown 0
}

proc ::inspector::open {root worker {workerCommand {}}} {
    variable job; variable directory; variable closed; variable shown
    set directory $root; set closed 0; set shown 0
    wm title . "Machteld Project Inspector"
    wm geometry . 960x690
    wm minsize . 720 480
    wm protocol . WM_DELETE_WINDOW ::inspector::close
    ttk::frame .path -padding 8
    ttk::label .path.label -text Directory:
    ttk::entry .path.entry -textvariable ::inspector::directory
    ttk::button .path.browse -text Browse... -command ::inspector::browse
    grid .path.label .path.entry .path.browse -sticky ew -padx 3
    grid columnconfigure .path 1 -weight 1
    ttk::frame .toolbar -padding {8 0 8 8}
    # Creation order is also keyboard traversal order; keep it aligned with
    # the visible rows (disabled controls are skipped by Tk).
    ttk::button .toolbar.inspect -text Inspect -command {::inspector::start inspect}
    ttk::button .toolbar.cancel -text Cancel -command ::inspector::cancel -state disabled
    ttk::button .toolbar.copy -text {Copy diagnostics} -command ::inspector::copy
    foreach {name label mode} {slow {Slow demo} slow fail {Fail demo} fail noisy {Output demo} noisy} {
        ttk::button .toolbar.$name -text $label -command [list ::inspector::start $mode]
    }
    grid .toolbar.inspect .toolbar.cancel .toolbar.copy -padx 3 -pady 2 -sticky ew
    grid .toolbar.slow .toolbar.fail .toolbar.noisy -padx 3 -pady 2 -sticky ew
    ttk::panedwindow .panes -orient vertical
    ttk::frame .panes.files -padding {8 0}
    ttk::treeview .panes.files.table -columns {kind size} -selectmode browse
    set table .panes.files.table
    $table heading #0 -text Name; $table heading kind -text Kind; $table heading size -text Bytes
    $table column #0 -width 440 -minwidth 100
    $table column kind -width 100 -minwidth 70
    $table column size -width 110 -minwidth 70 -anchor e
    ttk::scrollbar .panes.files.scroll -orient vertical -command [list $table yview]
    $table configure -yscrollcommand {.panes.files.scroll set}
    grid $table .panes.files.scroll -sticky nsew
    grid rowconfigure .panes.files 0 -weight 1
    grid columnconfigure .panes.files 0 -weight 1
    ttk::frame .panes.detail -padding 8
    ttk::label .panes.detail.label -text {Selected entry / diagnostics (select text to copy):}
    text .panes.detail.text -height 9 -width 40 -wrap word -state disabled -takefocus 1
    ttk::scrollbar .panes.detail.scroll -command {.panes.detail.text yview}
    .panes.detail.text configure -yscrollcommand {.panes.detail.scroll set}
    grid .panes.detail.label -columnspan 2 -sticky w
    grid .panes.detail.text .panes.detail.scroll -sticky nsew
    grid rowconfigure .panes.detail 1 -weight 1
    grid columnconfigure .panes.detail 0 -weight 1
    .panes add .panes.files -weight 3
    .panes add .panes.detail -weight 2
    ttk::frame .foot -padding 8
    ttk::progressbar .foot.progress -variable ::inspector::progress -maximum 100
    ttk::label .foot.status -textvariable ::inspector::status -wraplength 900
    grid .foot.progress -sticky ew
    grid .foot.status -sticky ew -pady {5 0}
    grid columnconfigure .foot 0 -weight 1
    grid .path -sticky ew
    grid .toolbar -sticky ew
    grid .panes -sticky nsew
    grid .foot -sticky ew
    grid rowconfigure . 2 -weight 1
    grid columnconfigure . 0 -weight 1
    bind $table <<TreeviewSelect>> ::inspector::detail
    bind . <Control-Return> {::inspector::start inspect; break}
    bind . <Escape> {::inspector::cancel; break}
    bind . <Control-l> {focus .path.entry; .path.entry selection range 0 end; break}
    # Windows may map the native window after open returns. Request focus once
    # the entry is actually mapped, without stealing focus with -force.
    bind .path.entry <Map> {focus %W; bind %W <Map> {}}
    bind .foot.status <Configure> {%W configure -wraplength [expr {max(100,%w)}]}
    set job [::inspector::Job new $worker ::inspector::changed $workerCommand]
    changed $job [$job snapshot]
}
proc ::inspector::browse {} {
    variable directory
    set choice [tk_chooseDirectory -initialdir $directory -mustexist 1]
    if {$choice ne {}} { set directory $choice }
}
proc ::inspector::start {mode} {
    variable job; variable directory; variable shown
    if {[$job start $directory $mode]} {
        .panes.files.table delete [.panes.files.table children {}]
        set shown 0
    }
}
proc ::inspector::cancel {} { variable job; $job cancel }
proc ::inspector::changed {source snapshot} {
    variable latest; variable renderTimer
    set latest $snapshot
    # Coalesce high-rate updates. Rendering never calls update or vwait.
    if {$renderTimer eq {}} { set renderTimer [after 16 ::inspector::render] }
}
proc ::inspector::render {} {
    variable latest; variable renderTimer; variable progress; variable status; variable shown
    set renderTimer {}
    if {![winfo exists .panes]} { return }
    set progress [dict get $latest progress]
    set status "[string totitle [dict get $latest phase]] — [dict get $latest message]"
    set running [expr {[dict get $latest phase] eq "running"}]
    foreach name {inspect slow fail noisy} {
        .toolbar.$name configure -state [expr {$running ? "disabled" : "normal"}]
    }
    .toolbar.cancel configure -state [expr {$running ? "normal" : "disabled"}]
    set rows [dict get $latest rows]
    foreach row [lrange $rows $shown end] {
        .panes.files.table insert {} end -id row$shown -text [dict get $row name] \
            -values [list [dict get $row kind] [dict get $row size]]
        incr shown
    }
    detail
}
proc ::inspector::detail {} {
    variable latest
    if {$latest eq {} || ![winfo exists .panes.detail.text]} { return }
    set text {}
    set selected [.panes.files.table selection]
    if {[llength $selected] && [regexp {^row([0-9]+)$} [lindex $selected 0] -> index]} {
        set row [lindex [dict get $latest rows] $index]
        if {$row ne {}} {
            set text "[dict get $row path]\nKind: [dict get $row kind]\nBytes: [dict get $row size]\n\n"
        }
    }
    if {[dict get $latest error] ne {}} { append text "ERROR\n[dict get $latest error]\n\n" }
    append text "Diagnostic tail (up to 8192 characters):\n[dict get $latest log]"
    .panes.detail.text configure -state normal
    .panes.detail.text delete 1.0 end
    .panes.detail.text insert end $text
    .panes.detail.text configure -state disabled
}
proc ::inspector::copy {} {
    variable latest
    clipboard clear
    clipboard append "[dict get $latest error]\n[dict get $latest log]"
}
proc ::inspector::close {} {
    variable job; variable renderTimer; variable closed
    if {$renderTimer ne {}} { after cancel $renderTimer; set renderTimer {} }
    if {$job ne {}} { $job close; $job destroy; set job {} }
    destroy .
    set closed 1
}
