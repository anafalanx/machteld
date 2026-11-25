if {![interp issafe]} {
    package ifneeded machteld::browser 1.0 [list source -encoding utf-8 [file join $dir browser.tcl]]
}
