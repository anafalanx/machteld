# machteld.tcl -- the machteld prelude.
#
# Sourced by the C host from zipfs before Tcl_Main evaluates an entry file.

namespace eval ::machteld {
    variable version 30
    # MANIFEST is appended to this prelude at build time by tools/genmanifest.tcl
    # from the explicit native specification, after checking its command set
    # against src/*.c. Declared empty here so an unpackaged prelude never invents
    # native facts.
    variable MANIFEST {}
    variable TCL_MANIFEST {}
}

proc ::machteld::version {} {
    variable version
    return $version
}

# Explicit public facts for Tcl-authored verbs. Command bodies are programs,
# not an API-description language: comments and refactors must not change what
# `manifest` claims. C facts remain generated into MANIFEST.
proc ::machteld::MetaDefine {verb facts} {
    variable TCL_MANIFEST
    if {[catch {dict size $facts}]} { error "MetaDefine $verb: facts must be a dict" }
    if {![dict exists $facts kind] || [dict get $facts kind] ne "tcl"} {
        error "MetaDefine $verb: Tcl metadata must declare {kind tcl}"
    }
    if {[dict exists $TCL_MANIFEST $verb]} {
        error "MetaDefine $verb: metadata is already registered"
    }
    dict set TCL_MANIFEST $verb $facts
    return
}

proc ::machteld::MetaMergeEntry {verb base extra} {
    set extending [expr {[dict exists $base kind] && [dict get $base kind] eq "c"}]
    if {$extending && $verb ne "pty"} {
        error "manifest: Tcl metadata cannot extend C verb \"$verb\""
    }
    if {!$extending} {
        error "manifest: duplicate metadata for \"$verb\""
    }
    if {[dict exists $base domain] && [dict exists $extra domain] &&
        [dict get $base domain] ne [dict get $extra domain]} {
        error "manifest: conflicting domain for \"$verb\""
    }
    if {$extending} {
        dict unset extra kind
        if {[dict exists $extra args]} { dict unset extra args }
    }
    foreach key {codes options replycodes} {
        if {![dict exists $extra $key]} continue
        set values [dict get $extra $key]
        if {[dict exists $base $key]} { set values [concat [dict get $base $key] $values] }
        dict set base $key [lsort -unique $values]
        dict unset extra $key
    }
    if {[dict exists $extra subcommands]} {
        set subs [expr {[dict exists $base subcommands] ? [dict get $base subcommands] : {}}]
        dict for {name sfacts} [dict get $extra subcommands] {
            if {[dict exists $subs $name]} {
                error "manifest: Tcl metadata duplicates $verb subcommand \"$name\""
            }
            dict set subs $name $sfacts
        }
        dict set base subcommands $subs
        dict unset extra subcommands
    }
    return [dict merge $base $extra]
}

# manifest: the palette describing itself ([creed] 4). One dict, no arguments,
# no subcommand vocabulary -- navigate it with `dict get`, which is Tcl the
# reader already knows and which reserves no words this surface would then be
# frozen around.
#
#   dict keys [manifest]                     -> the C verbs
#   dict get [manifest] run options          -> {-cpu -dir -env -mem ...}
#   dict get [manifest] pty subcommands read options   -> -timeout
#   dict get [manifest] child codes          -> what `child` can throw
#
# Native facts come from the explicit build specification. Tcl facts are explicit
# registrations next to their implementations; the suite checks both against live
# behavior.
proc ::machteld::manifest {} {
    variable MANIFEST
    variable TCL_MANIFEST
    set m $MANIFEST
    dict for {verb facts} $TCL_MANIFEST {
        if {[dict exists $m $verb]} {
            dict set m $verb [MetaMergeEntry $verb [dict get $m $verb] $facts]
        } else {
            dict set m $verb $facts
        }
    }
    return $m
}

::machteld::MetaDefine version [dict create kind tcl args {} doc machteld/command/version]
::machteld::MetaDefine manifest [dict create kind tcl args {} doc machteld/command/manifest]
::machteld::MetaDefine scope [dict create kind tcl args {body} doc machteld/command/scope]

# scope { body }: run body, then close (tree-kill) any children started within
# it that are still alive at the closing brace -- bounded lifetime by lexical
# structure. Pure Tcl over the child registry; nests naturally (each scope
# touches only the children born inside it). Runs the cleanup even if body
# throws, and re-raises the body's result/error unchanged.
proc ::machteld::scope {body} {
    set before [::machteld::child list]
    catch {uplevel 1 $body} result options
    foreach c [::machteld::child list] {
        if {$c ni $before} {
            catch {::machteld::child close $c}
        }
    }
    # Returning through this procedure consumes one level. Restore that level
    # so the caller receives the same completion it would get from the body.
    dict incr options -level
    return -options $options $result
}

# Remove ANSI/VT escape sequences from text, so output captured from a
# pseudo-console (pty read) can be matched or displayed as clean text. Strips CSI
# (ESC [ ...), OSC (ESC ] ... BEL/ST), and the common two/one-char ESC sequences
# (charset select, keypad, cursor save/restore). Printable text, newlines, tabs,
# and carriage returns are preserved. ESC/BEL/backslash are built with [format
# %c] and literal brackets are matched with bracket-classes ([[] is a literal
# '['), so the source carries no control characters and no escape ambiguity.
proc ::machteld::PtyStrip {s} {
    set E  [format %c 27]  ;# ESC
    set B  [format %c 7]   ;# BEL
    set BS [string repeat [format %c 92] 2]  ;# "\\" -- a regex-literal backslash (ESC-\ ST)
    regsub -all [string cat $E {[[][0-?]*[ -/]*[@-~]}] $s {} s
    regsub -all [string cat $E {[]].*?(?:} $B {|} $E $BS {)}] $s {} s
    regsub -all [string cat $E {[()#][0-9A-Za-z]}] $s {} s
    regsub -all [string cat $E {[=>78McDEHM]}] $s {} s
    return $s
}

# One raiser keeps Tcl-authored commands on the native error contract.
proc ::machteld::Fail {domain code msg} {
    return -code error -errorcode [list MACHTELD $domain $code] $msg
}

# Stage bytes beside the destination. Only a file successfully created by
# this call is ours to remove; never truncate or remove a colliding name.
proc ::machteld::PublishBytes {destination value args} {
    if {$destination eq "" || [string first \u0000 $destination] >= 0 ||
            [lindex [file system $destination] 0] ne "native"} {
        Fail PUBLISH badvalue "publish: expected a native destination file path"
    }
    set directory [file dirname [file normalize $destination]]
    if {![file isdirectory $directory]} {
        Fail PUBLISH badvalue "publish: destination parent must be an existing directory"
    }
    set candidate [file join $directory ".machteld-save-[binary encode hex [hash random 16]].tmp"]
    set channel [open $candidate {WRONLY CREAT EXCL BINARY} 0600]
    try {
        try {
            set owned [PublishCleanup $channel]
            PublishWrite $channel $value
        } finally {
            close $channel
        }
        set published [Publish $candidate $destination {*}$args]
    } trap {MACHTELD PUBLISH unconfirmed} {message options} {
        # The move consumed our staging file, so this name is no longer ours.
        return -options $options $message
    } on error {message options} {
        if {[info exists owned]} {catch {PublishCleanup $candidate $owned}}
        return -options $options $message
    }
    return $published
}

proc ::machteld::publish {args} {
    set options [lrange $args 3 end]
    if {[llength $args] < 3 || $options ni {{} -flush} || [lindex $args 0] ni {file bytes}} {
        Fail PUBLISH usage "usage: publish file path stagedFile ?-flush? | publish bytes path value ?-flush?"
    }
    lassign $args mode destination value
    try {
        if {$mode eq "file"} { return [Publish $value $destination {*}$options] }
        return [PublishBytes $destination $value {*}$options]
    } trap {MACHTELD PUBLISH} {message options} {
        return -options $options $message
    } on error {message options} {
        Fail PUBLISH oserror $message
    }
}

::machteld::MetaDefine publish [dict create kind tcl args args domain PUBLISH \
    codes {badvalue oserror unconfirmed usage} doc machteld/command/publish \
    subcommands [dict create \
        file [dict create options -flush doc machteld/command/publish#file] \
        bytes [dict create options -flush doc machteld/command/publish#bytes]]]

# _dur2ms: parse a duration with an explicit unit (500ms, 30s, 5m, 2h) to
# milliseconds. Bare numbers are rejected -- the same rule the C option parser
# enforces, so a stray `-timeout 100` can never silently mean "100 seconds".
# The maximum is one less than Win32's INFINITE sentinel (0xFFFFFFFF), matching
# the native timeout options. Compare the decimal text before arithmetic so an
# enormous input cannot force Tcl to construct an enormous bignum.
# Takes the caller's domain, the same way the C option parser does: the domain
# is the verb you invoked, never the helper that happened to fail.
proc ::machteld::_dur2ms {dom d} {
    if {![regexp {^([0-9]+)(ms|s|m|h)$} $d -> n u]} {
        Fail $dom badvalue "bad duration \"$d\": use an explicit unit (500ms, 30s, 5m, 2h)"
    }
    set factor [dict get {ms 1 s 1000 m 60000 h 3600000} $u]
    set maximum 4294967294
    set limit [expr {$maximum / $factor}]
    set normalized [string trimleft $n 0]
    if {$normalized eq ""} { set normalized 0 }
    if {[string length $normalized] > [string length $limit] ||
            ([string length $normalized] == [string length $limit] &&
             [string compare $normalized $limit] > 0)} {
        Fail $dom badvalue "bad duration \"$d\": maximum is 4294967294ms"
    }
    return [expr {$normalized * $factor}]
}

# pty: extend the C core (spawn/send/read/close/list) with a Tcl-level `expect`,
# an interaction loop layered over `pty read`. The C command is renamed aside and
# a namespace ensemble re-presents it as `pty` with the extra subcommand.
if {[info commands ::machteld::pty] ne ""} {
    rename ::machteld::pty ::machteld::PtyCore

    # pty expect $tok ?-timeout dur? {pattern {body} ... ?timeout {body}?}
    # Read from the pseudo-console until the (VT-stripped) accumulated output
    # glob-matches one of the patterns, then run that body in the caller's scope
    # and return its result. If nothing matches before the deadline, run the
    # `timeout` body (default: raise an error). Default deadline 10s.
    proc ::machteld::PtyExpect {tok args} {
        set timeout_ms 10000
        while {[llength $args] > 1 && [string index [lindex $args 0] 0] eq "-"} {
            set opt [lindex $args 0]
            if {$opt eq "-timeout"} {
                set timeout_ms [::machteld::_dur2ms PTY [lindex $args 1]]
                set args [lrange $args 2 end]
            } else {
                Fail PTY usage "pty expect: unknown option \"$opt\""
            }
        }
        if {[llength $args] != 1} {
            Fail PTY usage "usage: pty expect tok ?-timeout dur? {pattern body ...}"
        }
        set pats {}
        set tbody {return -code error -errorcode {MACHTELD PTY timeout} "pty expect: timed out"}
        if {[llength [lindex $args 0]] % 2} {
            Fail PTY usage "pty expect: patterns must be pattern/body pairs"
        }
        foreach {pat body} [lindex $args 0] {
            if {$pat eq "timeout"} { set tbody $body } else { lappend pats $pat $body }
        }
        set buf ""
        set deadline [expr {[clock milliseconds] + $timeout_ms}]
        while {1} {
            set remaining [expr {$deadline - [clock milliseconds]}]
            if {$remaining <= 0} { return [uplevel 1 $tbody] }
            set slice [expr {min(100, $remaining)}]
            append buf [::machteld::PtyCore read $tok -timeout ${slice}ms]
            if {$buf ne ""} {
                set clean [::machteld::PtyStrip $buf]
                foreach {pat body} $pats {
                    if {[string match $pat $clean]} { return [uplevel 1 $body] }
                }
            }
            if {[clock milliseconds] >= $deadline} { return [uplevel 1 $tbody] }
        }
    }

    # Tcl's default ensemble miss is {TCL LOOKUP SUBCOMMAND ...}.  Keep the
    # public PTY command on Machteld's error contract without enabling prefix
    # matching or adding an implicit dispatch path.
    proc ::machteld::PtyUnknown {ensemble subcommand args} {
        Fail PTY usage "pty: unknown subcommand \"$subcommand\""
    }

    # The runtime suite checks this explicit public map against the merged
    # manifest, so changing either side alone is a release failure.
    namespace ensemble create -command ::machteld::pty -prefixes 0 \
        -unknown ::machteld::PtyUnknown -map {
        spawn  {::machteld::PtyCore spawn}
        send   {::machteld::PtyCore send}
        read   {::machteld::PtyCore read}
        close  {::machteld::PtyCore close}
        list   {::machteld::PtyCore list}
        info   {::machteld::PtyCore info}
        expect ::machteld::PtyExpect
        strip  ::machteld::PtyStrip
    }
    ::machteld::MetaDefine pty [dict create kind tcl args args domain PTY codes {badvalue timeout usage} \
        doc machteld/command/pty \
        options {-timeout} subcommands [dict create \
            expect [dict create options {-timeout} doc machteld/command/pty#expect] \
            strip  [dict create options {} doc machteld/command/pty#strip]]]
}


# Stamp an opted-in machteld program into a standalone console or GUI exe. The
# application always lives below archive-root `app`; runtime-owned names remain
# at the root and therefore impose no naming policy on application files.
proc ::machteld::_children {dir} {
    set seen {}
    foreach item [concat \
            [glob -nocomplain -directory $dir *] \
            [glob -nocomplain -types hidden -directory $dir *] \
            [glob -nocomplain -directory $dir .*] \
            [glob -nocomplain -types hidden -directory $dir .*]] {
        if {[file tail $item] in {. ..}} continue
        # Preserve the spelling present on disk.  The staging filesystem is a
        # normal case-insensitive Windows directory, so reject a source tree
        # that could not be copied there without merging or overwriting names.
        dict set seen [string map {\\ /} [file normalize $item]] $item
    }
    set folded {}
    foreach item [dict values $seen] {
        set tail [file tail $item]
        set key [string tolower $tail]
        if {[dict exists $folded $key] && [dict get $folded $key] ne $tail} {
            Fail PACK badvalue \
                "pack: sibling names differ only by case: \"[dict get $folded $key]\" and \"$tail\""
        }
        dict set folded $key $tail
    }
    return [lsort [dict values $seen]]
}

proc ::machteld::_canon_key {facts} {
    return [list [dict get $facts volume] [dict get $facts file]]
}
proc ::machteld::_path_key {path} {
    return [string tolower [string trimright [string map {\\ /} $path] /]]
}
proc ::machteld::_inside {parent child} {
    set parent [_path_key $parent]
    set child [_path_key $child]
    return [expr {$child eq $parent || [string first "$parent/" $child] == 0}]
}
proc ::machteld::_zip_entries {root {rel ""}} {
    set out {}
    set dir [expr {$rel eq "" ? $root : [file join $root $rel]}]
    foreach item [::machteld::_children $dir] {
        set name [file tail $item]
        set zrel [expr {$rel eq "" ? $name : [file join $rel $name]}]
        if {[file type $item] eq "directory"} {
            lappend out {*}[::machteld::_zip_entries $root $zrel]
        } else {
            lappend out $item [string map {\\ /} $zrel]
        }
    }
    return $out
}

proc ::machteld::_new_workdir {parent} {
    for {set tries 0} {$tries < 32} {incr tries} {
        set suffix [binary encode hex [hash random 16]]
        set work [file join $parent .machteld-pack-$suffix]
        if {[file exists $work]} continue
        if {![catch {file mkdir $work}]} {
            set facts [canon $work]
            return [list $work [_canon_key $facts]]
        }
    }
    Fail PACK oserror "pack: cannot create a unique work directory beside the output"
}

proc ::machteld::_pack_relative {relative} {
    set relative [string map {\\ /} $relative]
    if {$relative eq "" || [file pathtype $relative] ne "relative" ||
            [regexp {[\x00-\x1f\x7f<>:"|?*]} $relative]} {
        Fail PACK badvalue "pack: asset must be a plain relative file path: $relative"
    }
    foreach part [split $relative /] {
        if {$part in {{} . ..} || [string trimright $part {. }] ne $part ||
                [regexp -nocase {^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)} $part]} {
            Fail PACK badvalue "pack: unsafe asset path component in $relative"
        }
    }
    return $relative
}

# Check lexical ancestors before normalize can erase a junction's spelling.
# Preserve the filesystem palette's distinction between name surrogates and
# ordinary content behind a cloud/filter reparse tag.
proc ::machteld::_pack_no_links {path {cacheName ""}} {
    if {$cacheName eq ""} { set cache {} } else { upvar 1 $cacheName cache }
    if {[file pathtype $path] eq "volumerelative"} {
        Fail PACK badvalue "pack: volume-relative input path is unsupported"
    }
    set current ""
    foreach part [file split [file join [pwd] $path]] {
        set current [file join $current $part]
        if {[file isdirectory $current]} {
            if {![dict exists $cache directories $current]} {
                if {[catch {links $current -depth 0} survey] ||
                        [llength [dict get $survey errors]] || [llength [dict get $survey links]]} {
                    Fail PACK badvalue "pack: selected path has an unreadable or name-surrogate ancestor: $current"
                }
                dict set cache directories $current 1
            }
        } else {
            if {[catch {file type $current} type]} {
                Fail PACK notfound "pack: selected file does not exist: $current"
            }
            if {$type ne "file"} { Fail PACK badvalue "pack: selected path is not a regular file: $current" }
            set parent [file dirname $current]
            if {![dict exists $cache filelinks $parent]} {
                if {[catch {links $parent -depth 1} survey] || [llength [dict get $survey errors]]} {
                    Fail PACK badvalue "pack: selected file cannot be inspected: $current"
                }
                set found {}
                foreach row [dict get $survey links] { dict set found [_path_key [dict get $row path]] 1 }
                dict set cache filelinks $parent $found
            }
            if {[dict exists $cache filelinks $parent [_path_key $current]]} {
                Fail PACK badvalue "pack: selected file is a name surrogate: $current"
            }
        }
    }
}

proc ::machteld::_pack_snapshot {path {root ""} {cacheName ""}} {
    if {$cacheName eq ""} { set cache {} } else { upvar 1 $cacheName cache }
    _pack_no_links $path cache
    if {[catch {
        set before [canon $path]
        if {[dict get $before kind] ne "file"} { error "not a regular file" }
        set size [file size $path]
        set digest [hash file sha256 $path]
        set after [canon $path]
    } message]} { Fail PACK badvalue "pack: cannot snapshot selected file $path: $message" }
    if {[_canon_key $before] ne [_canon_key $after] || $size != [file size $path]} {
        Fail PACK badvalue "pack: selected file changed during inspection: $path"
    }
    if {$root ne "" && ![_inside $root [dict get $after path]]} {
        Fail PACK badvalue "pack: selected asset resolves outside the input directory: $path"
    }
    return [dict create path $path identity [_canon_key $after] bytes $size sha256 $digest]
}

proc ::machteld::_pack_same_snapshot {before after} {
    foreach key {path identity bytes sha256} {
        if {[dict get $before $key] ne [dict get $after $key]} { return 0 }
    }
    return 1
}

proc ::machteld::_pack_data_dict {text label} {
    if {[catch {dict size $text} size] || [llength $text] != 2 * $size} {
        Fail PACK badvalue "pack: $label must be a dictionary without duplicate keys"
    }
    return [dict create {*}$text]
}

proc ::machteld::_pack_manifest {path {defaultEntry ""}} {
    if {[file isfile $path] && [file size $path] > 1048576} { Fail PACK badvalue "pack: manifest exceeds 1 MiB" }
    set snapshot [_pack_snapshot $path]
    if {[dict get $snapshot bytes] > 1048576} { Fail PACK badvalue "pack: manifest exceeds 1 MiB" }
    if {[catch {
        set channel [open $path rb]
        try { set bytes [read $channel 1048577] } finally { close $channel }
        set text [encoding convertfrom -profile strict utf-8 $bytes]
    } message]} { Fail PACK badvalue "pack: cannot read UTF-8 manifest: $message" }
    if {[string length $bytes] > 1048576 || [hash sum sha256 $bytes] ne [dict get $snapshot sha256]} {
        Fail PACK badvalue "pack: manifest changed while being read"
    }
    # Accept the UTF-8 signature emitted by common Windows editors. Its bytes
    # remain part of the source snapshot; only dictionary parsing ignores it.
    if {[string index $text 0] eq "\ufeff"} { set text [string range $text 1 end] }
    set data [_pack_data_dict $text manifest]
    foreach key [dict keys $data] {
        if {$key ni {schema entry files metadata}} { Fail PACK badvalue "pack: unknown manifest key $key" }
    }
    if {![dict exists $data schema] || [dict get $data schema] ne "1" || ![dict exists $data files]} {
        Fail PACK badvalue "pack: manifest requires schema 1 and an explicit files list"
    }
    if {[catch {llength [dict get $data files]} count] || $count < 1 || $count > 10000} {
        Fail PACK badvalue "pack: manifest files must list between 1 and 10000 files"
    }
    if {![dict exists $data entry]} {
        if {$defaultEntry eq ""} { Fail PACK badvalue "pack: project manifest needs an entry" }
        dict set data entry $defaultEntry
    }
    set metadata {}
    if {[dict exists $data metadata]} {
        set metadata [_pack_data_dict [dict get $data metadata] metadata]
        foreach key [dict keys $metadata] {
            if {$key ni {name version description author publisher copyright icon}} {
                Fail PACK badvalue "pack: unknown application metadata key $key"
            }
        }
    }
    return [dict create entry [_pack_relative [dict get $data entry]] files [dict get $data files] \
        metadata $metadata snapshot $snapshot]
}

proc ::machteld::_pack_check_tree {sourceRoot} {
    if {[catch {links $sourceRoot} survey]} {
        Fail PACK oserror "pack: cannot inspect input directory: $survey"
    }
    if {[llength [dict get $survey errors]] || [llength [dict get $survey links]]} {
        Fail PACK badvalue "pack: input directory contains an unreadable path or name surrogate"
    }
}

proc ::machteld::_pack_tree_files {root {relative ""} {cacheName ""}} {
    if {$cacheName eq ""} { set cache {} } else { upvar 1 $cacheName cache }
    set directory [file join $root $relative]
    _pack_no_links $directory cache
    set files {}
    foreach path [_children $directory] {
        set name [_pack_relative [string map {\\ /} [file join $relative [file tail $path]]]]
        switch -- [file type $path] {
            directory { lappend files {*}[_pack_tree_files $root $name cache] }
            file { lappend files $name }
            default { Fail PACK badvalue "pack: input contains an unsupported path type: $path" }
        }
    }
    return [lsort $files]
}

# Directory enumeration is shared only within this one inventory pass. Every
# final source recheck gets a fresh cache; file identities and bytes are never
# cached across snapshots. Large same-directory manifests remain linear.
proc ::machteld::_pack_actual_relative {root relative cacheName} {
    upvar 1 $cacheName cache
    set current $root; set actual {}
    foreach requested [split $relative /] {
        if {![dict exists $cache children $current]} {
            if {![file isdirectory $current]} { Fail PACK notfound "pack: selected parent is not a directory: $current" }
            _pack_no_links $current cache
            set names {}
            foreach path [_children $current] { dict set names [string tolower [file tail $path]] $path }
            dict set cache children $current $names
        }
        set key [string tolower $requested]
        if {![dict exists $cache children $current $key]} { Fail PACK notfound "pack: selected asset component does not exist: $requested" }
        set current [dict get $cache children $current $key]
        lappend actual [file tail $current]
    }
    return [list $current [join $actual /]]
}

proc ::machteld::_pack_inventory {root selected canonicalRoot} {
    set records {}; set folded {}; set cache {}
    foreach name $selected {
        set name [_pack_relative $name]
        lassign [_pack_actual_relative $root $name cache] path actual
        set actual [string map {\\ /} $actual]
        set key [string tolower $actual]
        if {[dict exists $folded $key]} { Fail PACK badvalue "pack: duplicate or case-colliding selected asset: $name" }
        dict set folded $key 1
        dict set records $actual [_pack_snapshot $path $canonicalRoot cache]
    }
    set sorted {}
    foreach name [lsort [dict keys $records]] { dict set sorted $name [dict get $records $name] }
    return $sorted
}

proc ::machteld::_pack_verify_inputs {sourceRoot sourceIdentity selected records wholeTree manifestSnapshot} {
    _pack_no_links $sourceRoot
    if {[_canon_key [canon $sourceRoot]] ne $sourceIdentity} {
        Fail PACK badvalue "pack: input directory was replaced while packaging"
    }
    if {$wholeTree} { set selected [_pack_tree_files $sourceRoot] }
    set current [_pack_inventory $sourceRoot $selected [dict get [canon $sourceRoot] path]]
    if {[dict keys $current] ne [dict keys $records]} { Fail PACK badvalue "pack: selected file inventory changed while packaging" }
    dict for {name snapshot} $records {
        if {![_pack_same_snapshot $snapshot [dict get $current $name]]} {
            Fail PACK badvalue "pack: selected asset changed while packaging: $name"
        }
    }
    if {$manifestSnapshot ne {} && ![_pack_same_snapshot $manifestSnapshot [_pack_snapshot [dict get $manifestSnapshot path]]]} {
        Fail PACK badvalue "pack: project manifest changed while packaging"
    }
}

proc ::machteld::_pack_archive_inventory {root} {
    set inventory {}
    foreach {path relative} [_zip_entries $root] {
        dict set inventory $relative [dict create bytes [file size $path] sha256 [hash file sha256 $path]]
    }
    return $inventory
}

proc ::machteld::_pack_verify_candidate {candidate inventory {entry {}} {appRoot {}}} {
    set mount "machteld-pack-[binary encode hex [hash random 16]]"
    zipfs mount $candidate $mount
    try {
        if {$entry ne ""} {
            set entryPath [file join //zipfs:/$mount $entry]
            if {$appRoot ne "" && [ArchiveEntry [file join //zipfs:/$mount $appRoot]] ne $entryPath} {
                Fail PACK badvalue "pack: candidate inventory selects a different entry"
            }
            EntryCheck $entryPath
        }
        set actual [_pack_archive_inventory //zipfs:/$mount]
        if {[lsort [dict keys $actual]] ne [lsort [dict keys $inventory]]} {
            Fail PACK badvalue "pack: candidate archive inventory differs from staging"
        }
        dict for {name expected} $inventory {
            if {[dict get $actual $name] ne $expected} {
                Fail PACK badvalue "pack: candidate archive differs from staging: $name"
            }
        }
    } finally { zipfs unmount $mount }
}

# Check the physical output location before creating a candidate alongside it.
# Return the destination identity when a previous build already exists.
proc ::machteld::_pack_destination {out sourceCanon entryCanon single} {
    if {[file isdirectory $out]} { Fail PACK badvalue "pack: output \"$out\" is a directory" }
    set outParent [file dirname $out]
    if {![file isdirectory $outParent]} {
        Fail PACK notfound "pack: output directory \"$outParent\" does not exist"
    }
    if {[catch {canon $outParent} parentCanon]} {
        Fail PACK badvalue "pack: output directory cannot be resolved: $parentCanon"
    }
    if {!$single && [_inside [dict get $sourceCanon path] [dict get $parentCanon path]]} {
        Fail PACK badvalue "pack: output cannot be inside the input directory"
    }
    if {[file exists $out]} {
        if {[catch {canon $out} outCanon]} {
            Fail PACK badvalue "pack: existing output cannot be resolved: $outCanon"
        }
        if {[_canon_key $entryCanon] eq [_canon_key $outCanon]} {
            Fail PACK badvalue "pack: output cannot overwrite its input entry"
        }
        if {!$single && [_inside [dict get $sourceCanon path] [dict get $outCanon path]]} {
            Fail PACK badvalue "pack: output cannot be inside the input directory"
        }
        if {![catch {canon [info nameofexecutable]} hostCanon] &&
                [_canon_key $hostCanon] eq [_canon_key $outCanon]} {
            Fail PACK badvalue "pack: output cannot overwrite the running host"
        }
    }
    if {[info exists outCanon]} { return $outCanon }
    return {}
}

# Read the pinned generation mounted by the native entry gate. The file list
# is inert data. Verify every mounted member before returning the entry path.
proc ::machteld::ArchiveEntry {root {countVar ""} {inventoryVar ""}} {
    set indexName machteld-inventory.dict
    set index [file join $root $indexName]
    if {![file isfile $index]} {
        Fail ENTRY inventory "archive has no $indexName; pack the original application sources with Machteld 30"
    }
    try {
        if {[file size $index] > 4194304} { error "inventory exceeds 4 MiB" }
        set channel [open $index rb]
        try { set bytes [read $channel 4194305] } finally { close $channel }
        if {[string length $bytes] > 4194304} { error "inventory exceeds 4 MiB" }
        set record [_pack_data_dict [encoding convertfrom -profile strict utf-8 $bytes] inventory]
        if {[lsort [dict keys $record]] ne {entry files schema} || [dict get $record schema] ne "1"} {
            error "expected archive inventory schema 1, entry and files"
        }
        set entry [dict get $record entry]
        set files [_pack_data_dict [dict get $record files] files]
        if {[dict size $files] > 10000 || ![dict exists $files $entry] || [dict exists $files $indexName]} {
            error "invalid entry or file list"
        }
        if {$countVar ne ""} { upvar 1 $countVar count; set count [dict size $files] }
        foreach {path name} [_zip_entries $root] {
            if {$name eq $indexName} continue
            if {[_pack_relative $name] ne $name || ![dict exists $files $name]} { error "unexpected member: $name" }
            set facts [_pack_data_dict [dict get $files $name] "record for $name"]
            if {[lsort [dict keys $facts]] ne {bytes sha256} ||
                    [file size $path] ne [dict get $facts bytes] ||
                    ![regexp {^[a-f0-9]{64}$} [dict get $facts sha256]] ||
                    [hash file sha256 $path] ne [dict get $facts sha256]} {
                error "size or SHA-256 mismatch: $name"
            }
            dict unset files $name
        }
        if {[dict size $files]} { error "missing member: [lindex [dict keys $files] 0]" }
        if {$inventoryVar ne ""} {upvar 1 $inventoryVar verified; set verified [dict get $record files]}
    } on error {message options} {
        Fail ENTRY inventory "invalid application archive inventory: $message"
    }
    return [file join $root {*}[split $entry /]]
}

proc ::machteld::WithAppArchive {path rootVar script} {
    upvar 1 $rootVar root
    set mount "machteld-app-[binary encode hex [hash random 16]]"
    if {[catch {zipfs mount $path $mount} message]} {Fail ENTRY inventory $message}
    set root //zipfs:/$mount
    try {uplevel 1 $script} finally {zipfs unmount $mount}
}

proc ::machteld::_pack_plan {input {entryOverride ""} {selectionManifest ""}} {
    _pack_no_links $input
    set input [file normalize $input]
    set single [expr {![file isdirectory $input]}]
    if {$single && ($entryOverride ne "" || $selectionManifest ne "")} {
        Fail PACK usage "pack: --entry and --manifest apply only to directories"
    }
    set project [expr {$selectionManifest ne "" || ($single &&
        [string equal -nocase [file extension $input] ".dict"] && [catch {::machteld::EntryCheck $input}])}]
    set manifestSnapshot {}
    set metadata {}
    set entry [expr {$entryOverride eq "" ? "main.tcl" : [_pack_relative $entryOverride]}]
    if {$project} {
        if {$selectionManifest eq ""} {
            set spec [_pack_manifest $input]
            set sourceRoot [file dirname $input]
        } else {
            _pack_no_links $selectionManifest
            set spec [_pack_manifest [file normalize $selectionManifest] $entry]
            if {$entryOverride ne "" && $entry ne [dict get $spec entry]} {
                Fail PACK badvalue "pack: --entry and the manifest entry disagree"
            }
            set sourceRoot $input
        }
        set selected [dict get $spec files]
        set entry [dict get $spec entry]
        set manifestSnapshot [dict get $spec snapshot]
        set metadata [dict get $spec metadata]
    } elseif {$single} {
        set sourceRoot [file dirname $input]
        set selected [list [file tail $input]]
    } else {
        set sourceRoot $input
        _pack_check_tree $sourceRoot
        set selected [_pack_tree_files $sourceRoot]
        if {$entry ni $selected} {
            if {$entryOverride eq ""} {Fail PACK notfound "pack: directory must contain a root main.tcl"}
            Fail PACK notfound "pack: directory must contain its entry $entry"
        }
    }
    set sourceCanon [canon $sourceRoot]
    set records [_pack_inventory $sourceRoot $selected [dict get $sourceCanon path]]
    if {$project && ![dict exists $records $entry]} {
        Fail PACK badvalue "pack: entry must appear in files with its on-disk spelling"
    }
    set entryPath [expr {$single && !$project ? $input : [file join $sourceRoot $entry]}]
    set entries {}; set inventory {}
    dict for {name record} $records {
        set member [expr {$single && !$project ? "main.tcl" : $name}]
        if {[string equal -nocase [lindex [split $member /] 0] "machteld-inventory.dict"]} {
            Fail PACK badvalue "pack: machteld-inventory.dict is reserved"
        }
        lappend entries [dict get $record path] $member
        dict set inventory $member [dict create bytes [dict get $record bytes] sha256 [dict get $record sha256]]
    }

    set indexBytes [encoding convertto -profile strict utf-8 [dict create schema 1 entry $entry files $inventory]]
    if {[dict size $inventory] > 10000 || [string length $indexBytes] > 4194304} {
        Fail PACK badvalue "pack: inventory exceeds 10000 files or 4 MiB"
    }
    return [dict create single $single project $project entry $entry entryPath $entryPath \
        selected $selected sourceRoot $sourceRoot sourceCanon $sourceCanon records $records \
        metadata $metadata manifestSnapshot $manifestSnapshot entries $entries inventory $inventory indexBytes $indexBytes]
}

# CLI-only so Tk retains its global pack geometry manager.
proc ::machteld::PackArchive {args} {
    lassign $args input flag out
    if {[llength $args] != 3 || $input eq "" || $flag ne "-o" || $out eq ""} {
        Fail PACK usage "usage: pack script-or-directory-or-project.dict -o name.machteld"
    }
    if {![string equal -nocase [file extension $out] ".machteld"]} {
        Fail PACK badvalue "pack: output must have the .machteld extension"
    }
    try {
        set plan [_pack_plan $input]
        dict with plan {}
        set out [file normalize $out]
        set existing [_pack_destination $out $sourceCanon [canon $entryPath] $single]
        if {$project && $existing ne {}} {
            set identity [_canon_key $existing]
            foreach snapshot [linsert [dict values $records] end $manifestSnapshot] {
                if {[dict get $snapshot identity] eq $identity} {
                    Fail PACK badvalue "pack: output cannot replace a selected file or the project manifest"
                }
            }
        }
        lassign [_new_workdir [file dirname $out]] work workKey
        set index [file join $work machteld-inventory.dict]
        set channel [open $index {WRONLY CREAT EXCL BINARY}]
        try { puts -nonewline $channel $indexBytes } finally { close $channel }
        lappend entries $index machteld-inventory.dict
        dict set inventory machteld-inventory.dict [dict create bytes [file size $index] sha256 [hash file sha256 $index]]
        set candidate [file join $work candidate.machteld]
        zipfs lmkzip $candidate $entries
        _pack_verify_candidate $candidate $inventory $entry
        _pack_verify_inputs $sourceRoot [_canon_key $sourceCanon] $selected $records [expr {!$single}] $manifestSnapshot
        ::machteld::Publish $candidate $out
    } trap {MACHTELD PUBLISH} {msg opts} {
        Fail PACK [lindex [dict get $opts -errorcode] 2] $msg
    } trap {MACHTELD ENTRY} {msg opts} {
        Fail PACK [lindex [dict get $opts -errorcode] 2] "pack: $msg"
    } finally {
        if {[info exists workKey] && ![catch {canon $work} finalWork] && [_canon_key $finalWork] eq $workKey} {
            catch {file delete -force $work}
        }
    }
    return $out
}

proc ::machteld::app {args} {
    if {[lindex $args 0] eq "data" && [llength $args] == 2} {
        return [AppDataRoot [lindex $args 1]]
    }
    if {$args ne {launch}} { Fail APP usage "usage: app launch | app data local|roaming" }
    variable launchPrefix
    if {![info exists launchPrefix]} { Fail APP state "app launch requires an active application" }
    return $launchPrefix
}

::machteld::MetaDefine app [dict create kind tcl args args domain APP codes {oserror state usage} \
    options {} doc machteld/command/app subcommands [dict create \
        data [dict create options {} doc machteld/command/app#data] \
        launch [dict create options {} doc machteld/command/app#launch]]]

proc ::machteld::browser {args} {
    package require machteld::browser 1.0
    tailcall ::machteld::browser::Dispatch {*}$args
}

::machteld::MetaDefine browser [dict create kind tcl args args domain BROWSER \
    codes {badvalue busy closed launch notfound ownership protocol timeout usage oserror} \
    options {} doc machteld/command/browser subcommands [dict create \
        launch [dict create options {-profile -executable -headless -timeout} doc machteld/command/browser#launch] \
        attach [dict create options {-profile -timeout} doc machteld/command/browser#attach] \
        navigate [dict create options {} doc machteld/command/browser#navigate] \
        wait [dict create options {-timeout} doc machteld/command/browser#wait] \
        cancel [dict create options {} doc machteld/command/browser#cancel] \
        release [dict create options {} doc machteld/command/browser#release] \
        close [dict create options {-timeout} doc machteld/command/browser#close]]]

# Called after all Tcl parts and the native manifest are loaded. Keep Tk's
# global names available even before Tk is loaded. Tcl's namespace path sees
# all commands in a namespace, including commands it has not exported.
proc ::machteld::InstallPalette {} {
    namespace eval ::machteld::palette {}
    dict for {name facts} [manifest] {
        if {[dict exists $facts qualified_only] && [dict get $facts qualified_only]} continue
        if {[llength [info commands ::machteld::$name]]} {
            interp alias {} ::machteld::palette::$name {} ::machteld::$name
        }
    }
    namespace eval :: {
        if {"::machteld::palette" ni [namespace path]} {
            namespace path [concat [namespace path] ::machteld::palette]
        }
    }
}

# Tk on demand: a static build ships no Tk DLL, so wire `package require Tk`
# straight to the in-process, statically-linked Tk_Init via `load {} Tk`. Tk is
# not initialized -- and no window is created -- until a script actually asks.
# The version label is the linked library's own TK_PATCH_LEVEL, recorded by the
# host in ::machteld::tk_patchlevel before this prelude runs, so it cannot
# drift from the Tk that `load {} Tk` initializes. Outside a machteld host (a
# tool sourcing this file in a plain tclsh) there is no linked Tk to register.
if {[info exists ::machteld::tk_patchlevel]} {
    package ifneeded Tk $::machteld::tk_patchlevel {load {} Tk}
}
package provide machteld $::machteld::version

# One-line banner on the first interactive prompt, then a plain branded prompt.
# (tcl_prompt1 is never invoked in non-interactive/script mode, so scripts stay
# silent.)
set ::tcl_prompt1 {
    puts "machteld [::machteld::version] - compact Windows runtime for Tcl/Tk 9 (Tcl [info patchlevel])"
    set ::tcl_prompt1 {puts -nonewline "machteld % "; flush stdout}
    puts -nonewline "machteld % "
    flush stdout
}
