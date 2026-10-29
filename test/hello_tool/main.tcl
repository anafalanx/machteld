#!/usr/bin/env machteld
# Wrapped console/GUI fixture. Its marker proves startup, argv ownership, and
# that the same static Machteld package (including SQLite/store) is present in
# both embedded basekits.
package require machteld

set marker [file join [file dirname [info nameofexecutable]] _hello_ran.txt]
set database [file join [file dirname [info nameofexecutable]] _hello_store.db]
set value [binary format H* 0001ff80410042]

set f [open $marker w]
puts $f "version:[package require machteld]"
puts $f "argc:$argc"
puts $f "argv:$argv"
puts $f "tcl_library:$::tcl_library"
puts $f "tk_library:$::tk_library"
puts $f "run:[expr {[llength [info commands ::machteld::run]] ? {yes} : {no}}]"
puts $f "docs-schema:[dict get [docs schema] schema]"
if {[catch {docs status} docs_result docs_options]} {
    puts $f "docs-errorcode:[dict get $docs_options -errorcode]"
} else {
    puts $f "docs-corpus:[dict get $docs_result corpus_sha256]"
}
if {[catch {help tcl/command/dict} help_result help_options]} {
    puts $f "help-errorcode:[dict get $help_options -errorcode]"
} else {
    puts $f "help-query:ok"
}
puts $f "help-banner:[list [help]]"
if {[catch {
    set msgcat_version [package require msgcat 1.7]
    set module_path [file normalize [file join [file dirname [info library]] tcl9 9.0]]
    set modules_embedded [expr {
        [string match {//zipfs:/*} $module_path] &&
        $module_path in [tcl::tm::path list]}]
    set clock_value [clock format 0 -locale nl_BE -timezone :Europe/Brussels]
    set cp1252_euro [binary encode hex [encoding convertto cp1252 \u20ac]]
} runtime_error]} {
    puts $f "runtime:error:$runtime_error"
} else {
    puts $f "runtime:msgcat:$msgcat_version modules:[expr {$modules_embedded ? {embedded} : {external}}] cp1252:$cp1252_euro clock:$clock_value"
}

set store_ok 0
if {![catch {
    store open $database
    store put binary $value
    store close
    store open $database
    set restored [store get binary]
    store close
    set store_ok [expr {[binary encode hex $restored] eq [binary encode hex $value]}]
} store_error]} {
    puts $f "store:[expr {$store_ok ? {yes} : {no}}]"
} else {
    puts $f "store:error:$store_error"
}

# Packaging checks must not take over the desktop. Actual widget/interaction
# coverage now lives in gui_widget_test.tcl; this optional fixture window is
# opened only when explicitly requested, never by routine wrapping tests.
if {![info exists env(MACHTELD_WRAP_GUI_INTERACTIVE)] ||
        $env(MACHTELD_WRAP_GUI_INTERACTIVE) ne "1" ||
        ([info exists env(MACHTELD_WRAP_GUI_SELFTEST)] && $env(MACHTELD_WRAP_GUI_SELFTEST) eq "1")} {
    set gui_result "not-requested"
} elseif {[catch {
    package require Tk
    wm title . "Machteld wrapped fixture"
    pack [label .label -text "Machteld wrapped fixture"]
    update
    destroy .
} gui_error]} {
    set gui_result "unavailable:$gui_error"
} else {
    set gui_result ok
}
puts $f "gui:$gui_result"
close $f
exit [expr {$store_ok ? 0 : 1}]
