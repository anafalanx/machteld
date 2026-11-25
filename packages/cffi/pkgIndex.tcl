if {![interp issafe]} {
    package ifneeded cffi 2.0.3 {load {} Cffi}
}
