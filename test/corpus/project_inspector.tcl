# Use the same inputs, assertions and unchanged Inspector scripts across all
# deployments. Only the archive supports replacing the published app in flight.
proc ::corpus::inspectorRead {path} {
    set f [open $path r]
    try {fconfigure $f -encoding utf-8; return [read $f]} finally {close $f}
}

proc ::corpus::project_inspector {ctx} {
    set root [dict get $ctx root]
    set source [file join [dict get $ctx repo] examples project-inspector]
    set stage [file join $root inspector-stage]
    file copy -- $source $stage
    set manifest [inspectorRead [file join $stage app.dict]]
    file copy -- [file join [dict get $ctx repo] test corpus inspector_entry.tcl] $stage
    dict set manifest entry inspector_entry.tcl
    dict lappend manifest files inspector_entry.tcl
    ::machteld::publish bytes [file join $stage app.dict] $manifest
    set artifact [build $ctx $stage inspector]
    set prefix [install $ctx $artifact]
    set origin [file normalize [lindex $prefix end]]

    set data [file join $root {données 雪}]
    set records [file join $root observations]
    file mkdir $data $records
    set sample [file join $data {café 雪.txt}]
    set numeric [file join $data 123]
    ::machteld::publish bytes $sample {read-only sample}
    ::machteld::publish bytes $numeric {numeric name}
    set originalSample [::machteld::hash file sha256 $sample]
    set originalNumeric [::machteld::hash file sha256 $numeric]

    set saved [array get ::env MACHTELD_CORPUS_INSPECTOR]
    set ::env(MACHTELD_CORPUS_INSPECTOR) [list $records $origin]
    try {
        set result [run $ctx $prefix --headless $data]
        check {headless inspection succeeds} {[dict get $result status] eq "ok" && [dict get $result exit] == 0}
        set model [::machteld::json decode [dict get $result out]]
        check {inspection finishes at 100 percent} {
            [dict get $model phase] eq "done" && [dict get $model progress] == 100}
        set files {}
        foreach row [dict get $model rows] {
            dict set files [dict get $row name] [list [dict get $row path] [dict get $row kind] [dict get $row size]]
        }
        check {two rows preserve Unicode paths, file kind, and byte lengths} {
            [llength [dict get $model rows]] == 2 &&
            [dict get $files 123] eq [list $numeric file [file size $numeric]] &&
            [dict get $files {café 雪.txt}] eq [list $sample file [file size $sample]]}
        check {numeric-looking filename is a JSON string} {[string match {*"name":"123"*} [dict get $result out]]}
        set parent [inspectorRead [file join $records headless.dict]]
        set worker [inspectorRead [file join $records worker.dict]]
        set expectedDigest [::machteld::hash file sha256 [file join $source inspect.tcl]]
        check {controller and a distinct worker start the installed entry and see the shipped worker script} {
            [dict get $parent pid] != [dict get $worker pid] &&
            [dict get $parent origin] eq $origin && [dict get $worker origin] eq $origin &&
            [dict get $parent worker_sha256] eq $expectedDigest && [dict get $worker worker_sha256] eq $expectedDigest}

        set result [run $ctx $prefix --headless $data noisy]
        check {noisy worker exits successfully} {[dict get $result status] eq "ok"}
        set model [::machteld::json decode [dict get $result out]]
        check {sustained output completes with bounded diagnostics} {
            [dict get $model phase] eq "done" && [string length [dict get $model log]] == 8192}
        set result [run $ctx $prefix --headless $data fail]
        check {worker failure reaches the controller exit code} {[dict get $result exit] == 1}
        set model [::machteld::json decode [dict get $result out]]
        check {failed worker reports its reason and leaves the inspected files intact} {
            [dict get $model phase] eq "error" && [string match {*Deliberate demonstration failure*} [dict get $model error]] &&
            [::machteld::hash file sha256 $sample] eq $originalSample && [::machteld::hash file sha256 $numeric] eq $originalNumeric}
        set result [run $ctx $prefix --worker $data inspect]
        check {direct worker role exits successfully} {[dict get $result status] eq "ok"}
        set lines [split [string trim [dict get $result out]] \n]
        check {direct worker emits its final JSON completion record} {
            [dict get [::machteld::json decode [lindex $lines end]] type] eq "complete"}
        set result [run $ctx $prefix --headless]
        check {invalid arguments return usage before GUI startup} {
            [dict get $result exit] == 2 && [string match {*usage:*} [dict get $result err]]}

        if {[dict get $ctx form] eq "archive"} {
            set replacement [file join $root upgrade-stage]
            file mkdir $replacement
            ::machteld::publish bytes [file join $replacement main.tcl] "package require machteld\nputs inspector-version-two\n"
            ::machteld::publish bytes [file join $replacement app.dict] {schema 1 entry main.tcl files main.tcl}
            set upgrade [build $ctx $replacement inspector-v2]
            file copy -- $upgrade [file join $records update.machteld]
            set result [run $ctx $prefix --headless $data]
            check {worker launched after archive replacement completes the old controller's inspection} {
                [dict get $result status] eq "ok" &&
                [dict get [::machteld::json decode [dict get $result out]] phase] eq "done"}
            set result [run $ctx $prefix --headless $data]
            check {fresh launch at the same path runs the replacement version} {
                [dict get $result status] eq "ok" && [string trim [dict get $result out]] eq "inspector-version-two"}
        }
    } finally {
        unset ::env(MACHTELD_CORPUS_INSPECTOR)
        array set ::env $saved
    }
}
