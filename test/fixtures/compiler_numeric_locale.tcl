namespace eval ::compilerNumericLocale {}

# Exercise the calling thread only. Restore its original numeric locale and
# its original choice of thread-local or process-wide locale on every exit.
proc ::compilerNumericLocale::withDecimalComma {body} {
    package require cffi
    set crt [cffi::Wrapper new ucrtbase.dll]
    try {
        $crt function _configthreadlocale int {mode int}
        $crt function setlocale string {category int locale {string nullifempty}}
        set previousMode [_configthreadlocale 1]
        try {
            set previousLocale [setlocale 4 {}]
            try {
                set selected [setlocale 4 de-DE]
                set probe [expr {[string length $selected] + 0.5}]
                if {$selected eq {} || [string first , [format %.1f $probe]] < 0} {
                    error "decimal-comma locale was not active on the test thread"
                }
                uplevel 1 $body
            } finally {setlocale 4 $previousLocale}
        } finally {_configthreadlocale $previousMode}
    } finally {
        foreach name {setlocale _configthreadlocale} {
            if {[llength [info commands [namespace current]::$name]]} {rename [namespace current]::$name {}}
        }
        $crt destroy
    }
}
