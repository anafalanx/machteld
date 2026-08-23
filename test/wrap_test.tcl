# Wrap/basekit acceptance suite. Run through the packaged host.

package require machteld

set HERE [file dirname [file normalize [info script]]]
set TOOL [file join $HERE hello_tool]
set WORK [file join $env(TEMP) machteld-wrap-test-[pid]]
file delete -force $WORK
file mkdir $WORK
set fails 0
proc check {name condition} {
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc slurp {path} {
    set channel [open $path r]
    set value [read $channel]
    close $channel
    return $value
}
proc wait_for_file {path {milliseconds 10000}} {
    set deadline [expr {[clock milliseconds] + $milliseconds}]
    while {[clock milliseconds] < $deadline} {
        if {[file exists $path] && [file size $path] > 0} { return 1 }
        after 50
    }
    return 0
}
proc carries_runtime_notices {image} {
    set mount "notice-[pid]-[clock clicks]"
    if {[catch {zipfs mount $image $mount}]} { return 0 }
    try {
        foreach notice {Apache-2.0.txt Tcl-9.0.4.txt Tk-9.0.4.txt} {
            set expected [file join //zipfs:/app/licenses $notice]
            set embedded [file join //zipfs:/$mount/licenses $notice]
            if {![file isfile $expected] || ![file isfile $embedded]} { return 0 }
            foreach {variable path} [list expectedText $expected embeddedText $embedded] {
                set channel [open $path r]
                fconfigure $channel -encoding utf-8
                set $variable [read $channel]
                close $channel
            }
            if {$expectedText ne $embeddedText} { return 0 }
        }
    } finally {
        catch {zipfs unmount $mount}
    }
    return 1
}
proc carries_reference_pack {image} {
    set mount "reference-[pid]-[clock clicks]"
    if {[catch {zipfs mount $image $mount}]} { return 0 }
    try {
        set root [file join //zipfs:/$mount reference]
        foreach relative {catalog.dict START-HERE.md AGENTS.md schema.json} {
            set path [file join $root $relative]
            if {![file isfile $path] || [file size $path] == 0} { return 0 }
        }
        foreach choices {
            {markdown/tcl/command/dict.md markdown/tcl/command/dict.txt}
            {source/tcl/doc/dict.n}
            {html/TclCmd/dict.html}
            {markdown/tk/command/bind.md markdown/tk/command/bind.txt}
            {source/tk/doc/bind.n}
            {html/TkCmd/bind.html}
            {markdown/machteld/command/run.md}
        } {
            set found 0
            foreach relative $choices {
                if {[file isfile [file join $root $relative]]} { set found 1; break }
            }
            if {!$found} { return 0 }
        }
    } finally {
        catch {zipfs unmount $mount}
    }
    return 1
}

set console [file join $WORK wrapped-console.exe]
wrap $TOOL -o $console --console
check "wrap produces a console executable" [file executable $console]
check "wrapped console needs no sidecar DLL" [expr {
    ![llength [glob -nocomplain -directory $WORK *.dll]]}]
check "wrapped console carries exact runtime license notices" \
    [carries_runtime_notices $console]
check "wrapped console carries the complete reference pack" \
    [carries_reference_pack $console]
set marker [file join $WORK _hello_ran.txt]
set result [run -- $console --help payload]
check "wrapped console receives its own --help argument" [expr {
    [dict get $result status] eq "ok" && [wait_for_file $marker]}]
set text [expr {[file exists $marker] ? [slurp $marker] : ""}]
check "wrapped console loads package 0.14.0" [string match *version:0.14.0* $text]
check "wrapped console owns --help/--version spelling" [string match *argv:--help\ payload* $text]
check "wrapped console carries native process API" [string match *run:yes* $text]
check "wrapped console carries static binary store" [string match *store:yes* $text]
check "wrapped console carries Tcl modules and timezone data" [expr {
    [string match *runtime:msgcat:1.7.1\ modules:embedded\ cp1252:80\ clock:*1970* $text] &&
    ![string match *runtime:error:* $text]}]

# Ordinary application switches remain application-owned. Only the explicitly
# namespaced escape bypasses the wrapped entry and queries its embedded runtime.
file delete -force $marker
set result [run -- $console --docs application-owned]
check "wrapped console leaves ordinary --docs to its application" [expr {
    [dict get $result status] eq "ok" && [wait_for_file $marker] &&
    [string match *argv:--docs\ application-owned* [slurp $marker]]}]
file delete -force $marker
set result [run -- $console --machteld-docs status --json]
check "wrapped console exposes the namespaced documentation escape" [expr {
    [dict get $result status] eq "ok" &&
    [string match *\"ok\":true* [dict get $result out]] &&
    [string match *\"result\"* [dict get $result out]] &&
    [string match *\"schema\"* [dict get $result out]] &&
    [string match *9.0.4* [dict get $result out]] &&
    ![file exists $marker]}]
set result [run -- $console --machteld-docs get no-such-product/no-such-page --json]
set failure_json "[dict get $result out][dict get $result err]"
check "wrapped console emits a JSON failure envelope and nonzero exit" [expr {
    [dict get $result status] eq "error" && [dict get $result exit] == 1 &&
    [string match *\"ok\":false* $failure_json] &&
    [string match *\"error\"* $failure_json] &&
    [string match -nocase *notfound* $failure_json] && ![file exists $marker]}]

# Application files are namespaced below archive-root app/, so nested entries
# retain their own script-relative assets and may use runtime-looking names.
set nested [file join $WORK nested-tool]
file mkdir [file join $nested src] [file join $nested docs] \
    [file join $nested basekit] [file join $nested tcl_library] \
    [file join $nested main.tcl] [file join $nested empty-directory]
set channel [open [file join $nested src sibling.txt] w]
puts -nonewline $channel NESTED-ASSET
close $channel
foreach relative {docs/app.txt basekit/app.txt tcl_library/app.txt main.tcl/app.txt} {
    set channel [open [file join $nested {*}[file split $relative]] w]
    puts -nonewline $channel "APP-NAME:$relative"
    close $channel
}
set channel [open [file join $nested src main.tcl] w]
puts $channel {package require machteld 0.14.0}
puts $channel {set f [open [file join [file dirname [info script]] sibling.txt] r]}
puts $channel {puts [read $f]}
puts $channel {close $f}
puts $channel {puts "ARGV0-MATCH:[expr {$argv0 eq [info script]}]"}
puts $channel {set root [file dirname [file dirname [info script]]]}
puts $channel {foreach relative {docs/app.txt basekit/app.txt tcl_library/app.txt main.tcl/app.txt} {set f [open [file join $root {*}[file split $relative]] r]; puts [read $f]; close $f}}
close $channel
set nested_exe [file join $WORK nested-console.exe]
wrap $nested -o $nested_exe --entry src/main.tcl --console
set result [run -- $nested_exe]
check "nested wrap entry reads a sibling asset via info script" [expr {
    [dict get $result status] eq "ok" &&
    [string match *NESTED-ASSET* [dict get $result out]]}]
check "nested wrapped entry sees argv0 equal to info script" [expr {
    [string match *ARGV0-MATCH:1* [dict get $result out]]}]
foreach relative {docs/app.txt basekit/app.txt tcl_library/app.txt main.tcl/app.txt} {
    check "application may contain runtime-looking $relative" [expr {
        [string match *APP-NAME:$relative* [dict get $result out]]}]
}
check "wrap rejects a volume-relative entry" [expr {
    [catch {wrap $nested -o [file join $WORK invalid-volume.exe] \
        --entry C:src/main.tcl --console} message options] &&
    [dict get $options -errorcode] eq {MACHTELD WRAP badvalue}}]

# Windows can represent some Unicode names that Tcl considers equal under
# case folding (K and Kelvin sign). Refuse the ambiguous portable tree before
# staging; a wrapped zipfs must never change which sibling a spelling names.
set collision [file join $WORK collision-tool]
file copy -force $TOOL $collision
set ascii_name [file join $collision K.txt]
set folded_name [file join $collision "[format %c 0x212a].txt"]
set channel [open $ascii_name w]
puts -nonewline $channel ascii
close $channel
set channel [open $folded_name w]
puts -nonewline $channel folded
close $channel
check "collision fixture has two representable sibling names" [expr {
    [file exists $ascii_name] && [file exists $folded_name] &&
    [llength [glob -nocomplain -directory $collision *.txt]] == 2}]
check "wrap rejects case-insensitive sibling-name collisions" [expr {
    [catch {wrap $collision -o [file join $WORK collision.exe] --console} message options] &&
    [dict get $options -errorcode] eq {MACHTELD WRAP badvalue}}]

# Repackaging does not waive entry validation: mutate a private copy after the
# first successful wrap and assert the invalid entry is rejected by wrap.
set invalid [file join $WORK invalid-tool]
file copy -force $TOOL $invalid
set channel [open [file join $invalid main.tcl] w]
puts $channel {puts SHOULD-NOT-WRAP}
close $channel
check "wrap revalidates an entry before packaging" [expr {
    [catch {wrap $invalid -o [file join $WORK invalid.exe] --console} message options] &&
    [lrange [dict get $options -errorcode] 0 1] eq {MACHTELD WRAP}}]

# GUI selftest performs the same package/store work without opening a window.
set gui [file join $WORK wrapped-gui.exe]
wrap $TOOL -o $gui --gui
check "wrap produces a GUI executable" [file executable $gui]
check "wrapped GUI needs no sidecar DLL" [expr {
    ![llength [glob -nocomplain -directory $WORK *.dll]]}]
check "wrapped GUI carries exact runtime license notices" \
    [carries_runtime_notices $gui]
check "wrapped GUI carries the complete reference pack" \
    [carries_reference_pack $gui]
file delete -force $marker [file join $WORK _hello_store.db]
set hostile_tcl [file join $WORK hostile-tcl]
set hostile_tk [file join $WORK hostile-tk]
file mkdir $hostile_tcl $hostile_tk
set tcl_poison [file join $WORK tcl-poison-ran.txt]
set tk_poison [file join $WORK tk-poison-ran.txt]
foreach {script poison} [list \
        [file join $hostile_tcl init.tcl] $tcl_poison \
        [file join $hostile_tk tk.tcl] $tk_poison] {
    set channel [open $script w]
    puts $channel [format {set f [open {%s} w]} [string map {\\ /} $poison]]
    puts $channel {puts $f poisoned}
    puts $channel {close $f}
    close $channel
}
set ::env(MACHTELD_WRAP_GUI_SELFTEST) 1
set gui_args {-name machteld-fixture -display {} -geometry 80x24+0+0 -sync -use {} -visual truecolor}
set gui_child [child start -env [list \
    MACHTELD_WRAP_GUI_SELFTEST 1 \
    TCL_LIBRARY $hostile_tcl \
    TK_LIBRARY $hostile_tk] -- $gui {*}$gui_args]
check "wrapped GUI starts under ordinary supervision" [string match child#* $gui_child]
check "wrapped GUI writes its selftest marker" [wait_for_file $marker]
set gui_result [child wait $gui_child -timeout 5s]
check "wrapped GUI selftest exits cleanly" [expr {
    [dict get $gui_result status] eq "ok" && [dict get $gui_result exit] == 0}]
child close $gui_child
set text [expr {[file exists $marker] ? [slurp $marker] : ""}]
check "wrapped GUI loads package 0.14.0" [string match *version:0.14.0* $text]
regexp -line {^argc:(.*)$} $text _ observed_argc
regexp -line {^argv:(.*)$} $text _ observed_argv
check "wrapped GUI preserves exact original argc" [expr {
    [info exists observed_argc] && $observed_argc == [llength $gui_args]}]
check "wrapped GUI preserves every Tk-looking argv item" [expr {
    [info exists observed_argv] && $observed_argv eq $gui_args}]
check "wrapped GUI pins embedded Tcl library" [string match *tcl_library://zipfs:/app/tcl_library* $text]
check "wrapped GUI pins embedded Tk library" [string match *tk_library://zipfs:/app/tk_library* $text]
check "wrapped GUI ignores hostile Tcl/Tk library scripts" [expr {
    ![file exists $tcl_poison] && ![file exists $tk_poison]}]
check "wrapped GUI carries static binary store" [string match *store:yes* $text]
check "wrapped GUI carries Tcl modules and timezone data" [expr {
    [string match *runtime:msgcat:1.7.1\ modules:embedded\ cp1252:80\ clock:*1970* $text] &&
    ![string match *runtime:error:* $text]}]
unset ::env(MACHTELD_WRAP_GUI_SELFTEST)

# Ordinary GUI application switches remain application-owned, just as they do
# in a console wrapper.  Only the namespaced first argument selects the runtime
# documentation route.
file delete -force $marker [file join $WORK _hello_store.db]
set gui_owned_child [child start -env [list MACHTELD_WRAP_GUI_SELFTEST 1] -- \
    $gui --docs application-owned]
set gui_owned_result [child wait $gui_owned_child -timeout 5s]
child close $gui_owned_child
set gui_owned_text [expr {[file exists $marker] ? [slurp $marker] : ""}]
check "wrapped GUI leaves ordinary --docs to its application" [expr {
    [dict get $gui_owned_result status] eq "ok" &&
    [dict get $gui_owned_result exit] == 0 &&
    [string match *argv:--docs\ application-owned* $gui_owned_text]}]

# A GUI documentation query is headless and writes explicitly because the GUI
# subsystem has no standard output channel.  Omitting the required output is a
# closed failure and still must not evaluate the application entry.
file delete -force $marker [file join $WORK _hello_store.db]
set gui_no_output_child [child start -- $gui --machteld-docs status --json]
set gui_no_output_result [child wait $gui_no_output_child -timeout 5s]
child close $gui_no_output_child
check "wrapped GUI documentation requires explicit output" [expr {
    [dict get $gui_no_output_result status] eq "error" &&
    [dict get $gui_no_output_result exit] == 1 && ![file exists $marker]}]

set gui_docs [file join $WORK gui-reference-status.json]
set gui_child [child start -- $gui --machteld-docs status --json --output $gui_docs]
set gui_result [child wait $gui_child -timeout 5s]
child close $gui_child
set gui_docs_text [expr {[file exists $gui_docs] ? [slurp $gui_docs] : ""}]
check "wrapped GUI exposes a headless documentation escape" [expr {
    [dict get $gui_result status] eq "ok" && [dict get $gui_result exit] == 0 &&
    [string match *\"ok\":true* $gui_docs_text] &&
    [string match *\"result\"* $gui_docs_text] &&
    [string match *\"schema\"* $gui_docs_text] &&
    [string match *9.0.4* $gui_docs_text] && ![file exists $marker]}]

file delete -force $WORK
if {$fails} {
    puts stderr "$fails wrap test(s) failed"
    exit 1
}
puts "ALL WRAP TESTS PASSED"
