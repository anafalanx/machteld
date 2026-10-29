# machteld.tcl -- the machteld prelude.
#
# Sourced by the C host from zipfs before Tcl_Main evaluates an entry file.

namespace eval ::machteld {
    variable version 0.22
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
    set code [catch {uplevel 1 $body} result options]
    foreach c [::machteld::child list] {
        if {$c ni $before} {
            catch {::machteld::child close $c}
        }
    }
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
            Fail WRAP badvalue \
                "wrap: sibling names differ only by case: \"[dict get $folded $key]\" and \"$tail\""
        }
        dict set folded $key $tail
    }
    return [lsort [dict values $seen]]
}

proc ::machteld::_copy_tree {src dst} {
    file mkdir $dst
    foreach item [::machteld::_children $src] {
        set target [file join $dst [file tail $item]]
        set type [file type $item]
        if {$type eq "directory"} {
            ::machteld::_copy_tree $item $target
        } elseif {$type eq "file"} {
            file copy $item $target
        } else {
            Fail WRAP badvalue "wrap: input contains unsupported path type \"$type\": $item"
        }
    }
}

# Resolve a relative application path one component at a time and retain the
# spelling actually present on disk. NTFS is usually case-insensitive while
# zipfs is case-sensitive, so copying the caller's spelling into the launcher
# can create an executable that packages successfully but cannot start.
proc ::machteld::_actual_relative {root relative} {
    set current $root
    set actual {}
    foreach requested [file split $relative] {
        if {![file isdirectory $current]} {
            Fail WRAP notfound "wrap: an entry component before \"$requested\" is not a directory"
        }
        set exact {}
        set folded {}
        foreach item [::machteld::_children $current] {
            set tail [file tail $item]
            if {$tail eq $requested} { lappend exact $item }
            if {[string equal -nocase $tail $requested]} { lappend folded $item }
        }
        if {[llength $exact] == 1} {
            set current [lindex $exact 0]
        } elseif {![llength $exact] && [llength $folded] == 1} {
            set current [lindex $folded 0]
        } elseif {![llength $exact] && ![llength $folded]} {
            Fail WRAP notfound "wrap: entry component \"$requested\" does not exist"
        } else {
            Fail WRAP badvalue "wrap: entry component \"$requested\" is ambiguous by case"
        }
        lappend actual [file tail $current]
    }
    return [list $current [file join {*}$actual]]
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
        set work [file join $parent .machteld-wrap-$suffix]
        if {[file exists $work]} continue
        if {![catch {file mkdir $work}]} {
            set facts [canon $work]
            return [list $work [_canon_key $facts]]
        }
    }
    Fail WRAP oserror "wrap: cannot create a unique work directory beside the output"
}

proc ::machteld::_write_launcher {path archiveEntry} {
    set channel [open $path {WRONLY CREAT EXCL}]
    try {
        fconfigure $channel -encoding utf-8 -translation lf
        # The pin is the running runtime's own version, so the launcher can
        # never disagree with the host that wraps it. The generated file still
        # carries a literal, which is what the entry gate parses.
        puts $channel "package require machteld [::machteld::version]"
        puts $channel "set argv0 \[file join \[file dirname \[info script\]\] [list $archiveEntry]\]"
        puts $channel {source $argv0}
    } finally {
        close $channel
    }
}

# Manifest data is never evaluated. Restrict archive names to unambiguous,
# portable Windows-relative file paths before asking the filesystem about them.
proc ::machteld::_wrap_relative {relative} {
    set relative [string map {\\ /} $relative]
    if {$relative eq "" || [file pathtype $relative] ne "relative" ||
            [regexp {[\x00-\x1f\x7f<>:"|?*]} $relative]} {
        Fail WRAP badvalue "wrap: asset must be a plain relative file path: $relative"
    }
    foreach part [split $relative /] {
        if {$part in {{} . ..} || [string trimright $part {. }] ne $part ||
                [regexp -nocase {^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)} $part]} {
            Fail WRAP badvalue "wrap: unsafe asset path component in $relative"
        }
    }
    return $relative
}

# Check lexical ancestors before normalize can erase a junction's spelling.
# Preserve the filesystem palette's distinction between name surrogates and
# ordinary content behind a cloud/filter reparse tag.
proc ::machteld::_wrap_no_links {path {cacheName ""}} {
    if {$cacheName eq ""} { set cache {} } else { upvar 1 $cacheName cache }
    if {[file pathtype $path] eq "volumerelative"} {
        Fail WRAP badvalue "wrap: volume-relative input path is unsupported"
    }
    set current ""
    foreach part [file split [file join [pwd] $path]] {
        set current [file join $current $part]
        if {[file isdirectory $current]} {
            if {![dict exists $cache directories $current]} {
                if {[catch {links $current -depth 0} survey] ||
                        [llength [dict get $survey errors]] || [llength [dict get $survey links]]} {
                    Fail WRAP badvalue "wrap: selected path has an unreadable or name-surrogate ancestor: $current"
                }
                dict set cache directories $current 1
            }
        } else {
            if {[catch {file type $current} type]} {
                Fail WRAP notfound "wrap: selected file does not exist: $current"
            }
            if {$type ne "file"} { Fail WRAP badvalue "wrap: selected path is not a regular file: $current" }
            set parent [file dirname $current]
            if {![dict exists $cache filelinks $parent]} {
                if {[catch {links $parent -depth 1} survey] || [llength [dict get $survey errors]]} {
                    Fail WRAP badvalue "wrap: selected file cannot be inspected: $current"
                }
                set found {}
                foreach row [dict get $survey links] { dict set found [_path_key [dict get $row path]] 1 }
                dict set cache filelinks $parent $found
            }
            if {[dict exists $cache filelinks $parent [_path_key $current]]} {
                Fail WRAP badvalue "wrap: selected file is a name surrogate: $current"
            }
        }
    }
}

proc ::machteld::_wrap_snapshot {path {root ""} {cacheName ""}} {
    if {$cacheName eq ""} { set cache {} } else { upvar 1 $cacheName cache }
    _wrap_no_links $path cache
    if {[catch {
        set before [canon $path]
        if {[dict get $before kind] ne "file"} { error "not a regular file" }
        set size [file size $path]
        set digest [hash file sha256 $path]
        set after [canon $path]
    } message]} { Fail WRAP badvalue "wrap: cannot snapshot selected file $path: $message" }
    if {[_canon_key $before] ne [_canon_key $after] || $size != [file size $path]} {
        Fail WRAP badvalue "wrap: selected file changed during inspection: $path"
    }
    if {$root ne "" && ![_inside $root [dict get $after path]]} {
        Fail WRAP badvalue "wrap: selected asset resolves outside the input directory: $path"
    }
    return [dict create path $path identity [_canon_key $after] bytes $size sha256 $digest]
}

proc ::machteld::_wrap_same_snapshot {before after} {
    foreach key {path identity bytes sha256} {
        if {[dict get $before $key] ne [dict get $after $key]} { return 0 }
    }
    return 1
}

proc ::machteld::_wrap_data_dict {text label} {
    if {[catch {dict size $text} size] || [llength $text] != 2 * $size} {
        Fail WRAP badvalue "wrap: $label must be a dictionary without duplicate keys"
    }
    return [dict create {*}$text]
}

proc ::machteld::_wrap_manifest {path} {
    if {[file isfile $path] && [file size $path] > 1048576} { Fail WRAP badvalue "wrap: manifest exceeds 1 MiB" }
    set snapshot [_wrap_snapshot $path]
    if {[dict get $snapshot bytes] > 1048576} { Fail WRAP badvalue "wrap: manifest exceeds 1 MiB" }
    if {[catch {
        set channel [open $path rb]
        try { set bytes [read $channel 1048577] } finally { close $channel }
        set text [encoding convertfrom -profile strict utf-8 $bytes]
    } message]} { Fail WRAP badvalue "wrap: cannot read UTF-8 manifest: $message" }
    if {[string length $bytes] > 1048576 || [hash sum sha256 $bytes] ne [dict get $snapshot sha256]} {
        Fail WRAP badvalue "wrap: manifest changed while being read"
    }
    # Accept the UTF-8 signature emitted by common Windows editors. Its bytes
    # remain part of the source snapshot; only dictionary parsing ignores it.
    if {[string index $text 0] eq "\ufeff"} { set text [string range $text 1 end] }
    set data [_wrap_data_dict $text manifest]
    foreach key [dict keys $data] {
        if {$key ni {schema files metadata}} { Fail WRAP badvalue "wrap: unknown manifest key $key" }
    }
    if {![dict exists $data schema] || [dict get $data schema] ne "1" || ![dict exists $data files]} {
        Fail WRAP badvalue "wrap: manifest requires schema 1 and an explicit files list"
    }
    if {[catch {llength [dict get $data files]} count] || $count < 1 || $count > 10000} {
        Fail WRAP badvalue "wrap: manifest files must list between 1 and 10000 files"
    }
    set metadata {}
    if {[dict exists $data metadata]} { set metadata [_wrap_data_dict [dict get $data metadata] metadata] }
    foreach key [dict keys $metadata] {
        if {$key ni {name version description author publisher copyright icon}} {
            Fail WRAP badvalue "wrap: unknown application metadata key $key"
        }
    }
    return [dict create files [dict get $data files] metadata $metadata snapshot $snapshot]
}

proc ::machteld::_wrap_tree_files {root {relative ""} {cacheName ""}} {
    if {$cacheName eq ""} { set cache {} } else { upvar 1 $cacheName cache }
    set directory [file join $root $relative]
    _wrap_no_links $directory cache
    set files {}
    foreach path [_children $directory] {
        set name [_wrap_relative [string map {\\ /} [file join $relative [file tail $path]]]]
        switch -- [file type $path] {
            directory { lappend files {*}[_wrap_tree_files $root $name cache] }
            file { lappend files $name }
            default { Fail WRAP badvalue "wrap: input contains an unsupported path type: $path" }
        }
    }
    return [lsort $files]
}

# Directory enumeration is shared only within this one inventory pass. Every
# final source recheck gets a fresh cache; file identities and bytes are never
# cached across snapshots. Large same-directory manifests remain linear.
proc ::machteld::_wrap_actual_relative {root relative cacheName} {
    upvar 1 $cacheName cache
    set current $root; set actual {}
    foreach requested [split $relative /] {
        if {![dict exists $cache children $current]} {
            if {![file isdirectory $current]} { Fail WRAP notfound "wrap: selected parent is not a directory: $current" }
            _wrap_no_links $current cache
            set names {}
            foreach path [_children $current] { dict set names [string tolower [file tail $path]] $path }
            dict set cache children $current $names
        }
        set key [string tolower $requested]
        if {![dict exists $cache children $current $key]} { Fail WRAP notfound "wrap: selected asset component does not exist: $requested" }
        set current [dict get $cache children $current $key]
        lappend actual [file tail $current]
    }
    return [list $current [join $actual /]]
}

proc ::machteld::_wrap_inventory {root selected canonicalRoot} {
    set records {}; set folded {}; set cache {}
    foreach name $selected {
        set name [_wrap_relative $name]
        lassign [_wrap_actual_relative $root $name cache] path actual
        set actual [string map {\\ /} $actual]
        set key [string tolower $actual]
        if {[dict exists $folded $key]} { Fail WRAP badvalue "wrap: duplicate or case-colliding selected asset: $name" }
        dict set folded $key 1
        dict set records $actual [_wrap_snapshot $path $canonicalRoot cache]
    }
    set sorted {}
    foreach name [lsort [dict keys $records]] { dict set sorted $name [dict get $records $name] }
    return $sorted
}

proc ::machteld::_wrap_copy_assets {records destination} {
    file mkdir $destination
    dict for {name snapshot} $records {
        set target [file join $destination {*}[split $name /]]
        file mkdir [file dirname $target]
        file copy [dict get $snapshot path] $target
        if {[file size $target] != [dict get $snapshot bytes] ||
                [hash file sha256 $target] ne [dict get $snapshot sha256]} {
            Fail WRAP badvalue "wrap: selected asset changed while being staged: $name"
        }
    }
}

proc ::machteld::_wrap_verify_inputs {sourceRoot sourceIdentity selected records wholeTree manifestSnapshot iconSnapshot} {
    _wrap_no_links $sourceRoot
    if {[_canon_key [canon $sourceRoot]] ne $sourceIdentity} {
        Fail WRAP badvalue "wrap: input directory was replaced while packaging"
    }
    if {$wholeTree} { set selected [_wrap_tree_files $sourceRoot] }
    set current [_wrap_inventory $sourceRoot $selected [dict get [canon $sourceRoot] path]]
    if {[dict keys $current] ne [dict keys $records]} { Fail WRAP badvalue "wrap: selected file inventory changed while packaging" }
    dict for {name snapshot} $records {
        if {![_wrap_same_snapshot $snapshot [dict get $current $name]]} {
            Fail WRAP badvalue "wrap: selected asset changed while packaging: $name"
        }
    }
    foreach snapshot [list $manifestSnapshot $iconSnapshot] {
        if {$snapshot ne "" && ![_wrap_same_snapshot $snapshot [_wrap_snapshot [dict get $snapshot path]]]} {
            Fail WRAP badvalue "wrap: manifest or icon changed while packaging"
        }
    }
}

proc ::machteld::_wrap_archive_inventory {root} {
    set inventory {}
    foreach {path relative} [_zip_entries $root] {
        dict set inventory $relative [dict create bytes [file size $path] sha256 [hash file sha256 $path]]
    }
    return $inventory
}

proc ::machteld::_wrap_verify_candidate {candidate inventory} {
    set mount "machteld-wrap-[binary encode hex [hash random 16]]"
    zipfs mount $candidate $mount
    try {
        set actual [_wrap_archive_inventory //zipfs:/$mount]
        if {[lsort [dict keys $actual]] ne [lsort [dict keys $inventory]]} {
            Fail WRAP badvalue "wrap: candidate archive inventory differs from staging"
        }
        dict for {name expected} $inventory {
            if {[dict get $actual $name] ne $expected} {
                Fail WRAP badvalue "wrap: candidate archive differs from staging: $name"
            }
        }
    } finally { zipfs unmount $mount }
}

proc ::machteld::wrap {args} {
    set gui 0; set withDocs 0; set out ""; set input ""; set entry ""; set entrySet 0
    set manifest ""; set manifestSet 0; set plan 0
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        switch -- $a {
            --gui        { set gui 1 }
            --console    { set gui 0 }
            --with-docs  { set withDocs 1 }
            --plan       { set plan 1 }
            --entry - --manifest - -o {
                if {$i + 1 >= [llength $args]} { Fail WRAP usage "wrap: $a needs a value" }
                set v [lindex $args [incr i]]
                switch -- $a {
                    --entry { set entry $v; set entrySet 1 }
                    --manifest { set manifest $v; set manifestSet 1 }
                    -o { set out $v }
                }
            }
            default {
                if {[string match -* $a]} {
                    Fail WRAP usage "wrap: unknown option \"$a\""
                } elseif {$input eq ""} {
                    set input $a
                } else {
                    Fail WRAP usage "wrap: unexpected argument \"$a\""
                }
            }
        }
    }
    if {$input eq "" || $out eq ""} {
        Fail WRAP usage "usage: wrap input -o out.exe ?--entry path? ?--manifest file? ?--plan? ?--gui|--console? ?--with-docs?"
    }
    if {![file exists $input]} { Fail WRAP notfound "wrap: input \"$input\" does not exist" }
    set single [expr {![file isdirectory $input]}]
    if {$single && $entrySet} { Fail WRAP usage "wrap: --entry applies only to a directory" }
    if {$single && $manifestSet} { Fail WRAP usage "wrap: --manifest applies only to a directory" }
    _wrap_no_links $input
    if {$single} {
        if {![file isfile $input]} { Fail WRAP badvalue "wrap: input must be a file or directory" }
        set sourceRoot [file dirname [file normalize $input]]
        lassign [_actual_relative $sourceRoot [file tail $input]] entryPath actualEntry
        set archiveEntry [string map {\\ /} [file join app [file tail $entryPath]]]
    } else {
        set sourceRoot [file normalize $input]
        if {!$entrySet} { set entry main.tcl }
        set entry [_wrap_relative $entry]
        lassign [::machteld::_actual_relative $sourceRoot $entry] entryPath actualEntry
        set archiveEntry [string map {\\ /} [file join app {*}[file split $actualEntry]]]
    }
    if {![file isfile $entryPath]} { Fail WRAP notfound "wrap: entry \"$entryPath\" is not a file" }
    if {[catch {canon $entryPath} entryCanon]} {
        Fail WRAP badvalue "wrap: entry cannot be resolved: $entryCanon"
    }
    if {!$single} {
        if {[catch {canon $sourceRoot} sourceCanon]} {
            Fail WRAP badvalue "wrap: input directory cannot be resolved: $sourceCanon"
        }
        if {![_inside [dict get $sourceCanon path] [dict get $entryCanon path]]} {
            Fail WRAP badvalue "wrap: --entry must resolve inside the input directory"
        }
        if {!$manifestSet && [catch {links $sourceRoot} survey]} {
            Fail WRAP oserror "wrap: cannot inspect input directory: $survey"
        }
        if {!$manifestSet && ([llength [dict get $survey errors]] || [llength [dict get $survey links]])} {
            Fail WRAP badvalue "wrap: input directory contains an unreadable path or name surrogate"
        }
    }
    set sourceCanon [canon $sourceRoot]
    set manifestSnapshot {}; set iconSnapshot {}; set nativeMetadata {}; set metadata {}
    if {$manifestSet} {
        if {$manifest eq ""} { Fail WRAP badvalue "wrap: --manifest requires a file path" }
        _wrap_no_links $manifest
        set manifest [file normalize $manifest]
        set specification [_wrap_manifest $manifest]
        set manifestSnapshot [dict get $specification snapshot]
        set selected [dict get $specification files]
        set metadata [dict get $specification metadata]
    } elseif {$single} { set selected [list [file tail $entryPath]]
    } else { set selected [_wrap_tree_files $sourceRoot] }
    set records [_wrap_inventory $sourceRoot $selected [dict get $sourceCanon path]]
    set entryRelative [string range $archiveEntry 4 end]
    if {![dict exists $records $entryRelative]} { Fail WRAP badvalue "wrap: selected entry must be explicitly listed in manifest files" }
    set selected [dict keys $records]

    set out [file normalize $out]
    if {[file isdirectory $out]} { Fail WRAP badvalue "wrap: output \"$out\" is a directory" }
    set outParent [file dirname $out]
    if {![file isdirectory $outParent]} {
        Fail WRAP notfound "wrap: output directory \"$outParent\" does not exist"
    }
    if {[catch {canon $outParent} parentCanon]} {
        Fail WRAP badvalue "wrap: output directory cannot be resolved: $parentCanon"
    }
    if {!$single && [_inside [dict get $sourceCanon path] [dict get $parentCanon path]]} {
        Fail WRAP badvalue "wrap: output cannot be inside the input directory"
    }
    if {[file exists $out]} {
        if {[catch {canon $out} outCanon]} {
            Fail WRAP badvalue "wrap: existing output cannot be resolved: $outCanon"
        }
        if {[_canon_key $entryCanon] eq [_canon_key $outCanon]} {
            Fail WRAP badvalue "wrap: output cannot overwrite its input entry"
        }
        if {!$single && [_inside [dict get $sourceCanon path] [dict get $outCanon path]]} {
            Fail WRAP badvalue "wrap: output cannot be inside the input directory"
        }
        if {![catch {canon [info nameofexecutable]} hostCanon] &&
                [_canon_key $hostCanon] eq [_canon_key $outCanon]} {
            Fail WRAP badvalue "wrap: output cannot overwrite the running host"
        }
    }

    if {$metadata ne ""} {
        foreach key {name version} {
            if {![dict exists $metadata $key] || [dict get $metadata $key] eq ""} {
                Fail WRAP badvalue "wrap: application metadata requires name and version"
            }
        }
        if {[info commands ::machteld::ValidateIdentity] eq "" || [info commands ::machteld::StampIdentity] eq ""} {
            Fail WRAP unsupported "wrap: this host lacks application identity support"
        }
        set nativeMetadata $metadata
        dict set nativeMetadata internal_name [file rootname [file tail $out]]
        dict set nativeMetadata original_filename [file tail $out]
        if {[dict exists $metadata icon] && [dict get $metadata icon] ne ""} {
            set icon [dict get $metadata icon]
            if {[file pathtype $icon] eq "relative"} { set icon [file join [file dirname $manifest] $icon] }
            _wrap_no_links $icon
            set icon [file normalize $icon]
            if {[file isfile $icon] && [file size $icon] > 16777216} { Fail WRAP badvalue "wrap: icon exceeds 16 MiB" }
            set iconSnapshot [_wrap_snapshot $icon]
            dict set nativeMetadata icon $icon
        }
        set nativeMetadata [::machteld::ValidateIdentity $nativeMetadata]
        set metadata $nativeMetadata
        dict set metadata icon [expr {$iconSnapshot eq "" ? {} : [dict create \
            bytes [dict get $iconSnapshot bytes] sha256 [dict get $iconSnapshot sha256]]}]
    }
    if {[info exists outCanon]} {
        foreach snapshot [list $manifestSnapshot $iconSnapshot] {
            if {$snapshot ne "" && [_canon_key $outCanon] eq [dict get $snapshot identity]} {
                Fail WRAP badvalue "wrap: output cannot overwrite its manifest or icon input"
            }
        }
    }
    set files {}
    dict for {name snapshot} $records {
        dict set files $name [dict create bytes [dict get $snapshot bytes] sha256 [dict get $snapshot sha256]]
    }
    set appInfo [dict create schema 1 entry $archiveEntry host [expr {$gui ? "gui" : "console"}] \
        with_docs $withDocs metadata $metadata runtime [dict create name Machteld version [version] \
        author {Vincent Vercauteren}] files $files]

    if {[info commands ::machteld::EntryCheck] eq "" ||
            [info commands ::machteld::Publish] eq ""} {
        Fail WRAP unsupported "wrap: this host lacks packaging support"
    }
    if {[info commands ::machteld::PayloadRoot] eq "" ||
            [catch {::machteld::PayloadRoot} root]} {
        Fail WRAP unsupported "wrap: the embedded runtime root is unavailable"
    }
    if {![file isdirectory [file join $root tcl_library]] ||
            ![file isdirectory [file join $root tcl9]] ||
            ![file isdirectory [file join $root tk_library]] ||
            ![file isdirectory [file join $root licenses]] ||
            ![file isdirectory [file join $root basekit]]} {
        Fail WRAP unsupported "wrap: this executable carries no wrapper basekits"
    }
    set bare [file join $root basekit [expr {$gui ? {gui.exe} : {console.exe}}]]
    if {![file isfile $bare]} { Fail WRAP notfound "wrap: basekit not embedded: $bare" }
    # Documentation is a packaging option, not a runtime dependency. Only an
    # explicit opt-in needs the corpus or pays for its integrity validation.
    if {$withDocs} {
        if {[info commands ::machteld::DocsPackFiles] eq ""} {
            Fail WRAP unsupported "wrap: embedded reference validation is unavailable"
        }
        if {[catch {::machteld::DocsPackFiles} referenceError]} {
            Fail WRAP unsupported "wrap: embedded reference pack is unavailable or invalid: $referenceError"
        }
    }
    if {[catch {::machteld::EntryCheck $entryPath} checked opts]} {
        set code [expr {[dict exists $opts -errorcode] ? [dict get $opts -errorcode] : {}}]
        if {[lrange $code 0 1] eq {MACHTELD ENTRY}} { Fail WRAP [lindex $code 2] $checked }
        return -options $opts $checked
    }
    if {$plan} {
        _wrap_verify_inputs $sourceRoot [_canon_key $sourceCanon] $selected $records \
            [expr {!$single && !$manifestSet}] $manifestSnapshot $iconSnapshot
        return $appInfo
    }

    lassign [_new_workdir $outParent] work workKey
    try {
        set stage [file join $work stage]
        file mkdir $stage
        ::machteld::_copy_tree [file join $root tcl_library] [file join $stage tcl_library]
        ::machteld::_copy_tree [file join $root tcl9]        [file join $stage tcl9]
        ::machteld::_copy_tree [file join $root tk_library]  [file join $stage tk_library]
        ::machteld::_copy_tree [file join $root licenses]    [file join $stage licenses]
        if {$withDocs} {
            ::machteld::_copy_tree [file join $root reference] [file join $stage reference]
        }
        file copy [file join $root machteld.tcl] [file join $stage machteld.tcl]
        # Runtime provenance is independent of application assets and the
        # optional reference corpus. Older released hosts have no such record.
        if {[file isfile [file join $root build-info.dict]]} {
            file copy [file join $root build-info.dict] [file join $stage build-info.dict]
        }
        set app [file join $stage app]
        _wrap_copy_assets $records $app
        set stagedEntry [file join $app {*}[split $entryRelative /]]
        if {[catch {::machteld::EntryCheck $stagedEntry} checked opts]} {
            set code [expr {[dict exists $opts -errorcode] ? [dict get $opts -errorcode] : {}}]
            if {[lrange $code 0 1] eq {MACHTELD ENTRY}} {
                Fail WRAP [lindex $code 2] $checked
            }
            return -options $opts $checked
        }
        ::machteld::_write_launcher [file join $stage main.tcl] $archiveEntry
        set channel [open [file join $stage app-info.dict] {WRONLY CREAT EXCL}]
        try {
            fconfigure $channel -encoding utf-8 -translation lf
            puts $channel $appInfo
        } finally { close $channel }

        set tmpbare [file join $work bare.exe]
        file copy $bare $tmpbare
        if {$nativeMetadata ne ""} {
            if {$iconSnapshot ne ""} {
                set stagedIcon [file join $work identity.ico]
                file copy [dict get $iconSnapshot path] $stagedIcon
                if {[file size $stagedIcon] != [dict get $iconSnapshot bytes] ||
                        [hash file sha256 $stagedIcon] ne [dict get $iconSnapshot sha256]} {
                    Fail WRAP badvalue "wrap: icon changed while being staged"
                }
                dict set nativeMetadata icon $stagedIcon
            }
            ::machteld::StampIdentity $tmpbare $nativeMetadata
        }
        set candidate [file join $work candidate.exe]
        set stagedApp [_wrap_archive_inventory $app]
        if {[lsort [dict keys $stagedApp]] ne [lsort [dict keys $files]]} {
            Fail WRAP badvalue "wrap: staged application inventory changed before packaging"
        }
        dict for {name expected} $files {
            if {[dict get $stagedApp $name] ne $expected} {
                Fail WRAP badvalue "wrap: staged application bytes changed before packaging: $name"
            }
        }
        set stagedInventory [_wrap_archive_inventory $stage]
        zipfs lmkimg $candidate [::machteld::_zip_entries $stage] {} $tmpbare
        _wrap_verify_candidate $candidate $stagedInventory
        _wrap_verify_inputs $sourceRoot [_canon_key $sourceCanon] $selected $records \
            [expr {!$single && !$manifestSet}] $manifestSnapshot $iconSnapshot
        ::machteld::Publish $candidate $out
    } on error {msg opts} {
        set code [expr {[dict exists $opts -errorcode] ? [dict get $opts -errorcode] : {}}]
        if {[lindex $code 0] eq "MACHTELD"} { return -options $opts $msg }
        Fail WRAP oserror "wrap: $msg"
    } finally {
        # Best-effort cleanup.  The identity check avoids deleting an obviously
        # replaced path; publication safety does not depend on cleanup success.
        if {![catch {canon $work} finalWork] && [_canon_key $finalWork] eq $workKey} {
            catch {file delete -force $work}
        }
    }
    return $out
}

::machteld::MetaDefine wrap [dict create kind tcl args args domain WRAP \
    codes {badvalue notfound optin oserror unsupported usage} options {--console --entry --gui --manifest --plan --with-docs -o} \
    doc machteld/command/wrap]

# Expose the palette as bare verbs: unqualified run / child / pty / wait / scope
# / detach / store resolve to ::machteld::* -- so the REPL and scripts read like
# a shell script, the ergonomic point of the design. This uses the global
# namespace's command-resolution path, so Tcl's own commands (found first) are
# never shadowed and nothing is copied.
namespace eval :: { namespace path [concat [namespace path] ::machteld] }

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
    puts "machteld [::machteld::version] - compact Windows machine-control runtime (Tcl [info patchlevel])"
    set ::tcl_prompt1 {puts -nonewline "machteld % "; flush stdout}
    puts -nonewline "machteld % "
    flush stdout
}
