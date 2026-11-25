if {![interp issafe]} {
    package ifneeded machteld::sqlite 1.0 [list source -encoding utf-8 [file join $dir sqlite.tcl]]
}
