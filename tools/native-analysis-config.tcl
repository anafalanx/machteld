# Machine-readable argv lines from the real build recipe. Do not duplicate the
# authored flags, system-library list, or dependency layout in a second build.
source [file join [file dirname [info script]] buildlib.tcl]
if {[llength $argv] != 1} { error {usage: native-analysis-config.tcl CACHE_ROOT} }
set paths [::machteld::build::paths [file normalize [lindex $argv 0]]]
foreach flag [::machteld::build::common_flags $paths] { puts "flag $flag" }
foreach flag $::machteld::build::SYSLIBS { puts "library $flag" }
foreach key {include sqlite yyjson tcllib tklib tclstub} {
    puts "$key [dict get $paths $key]"
}
