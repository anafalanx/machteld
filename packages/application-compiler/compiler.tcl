package require Tcl 9.0
namespace eval ::appcompiler {}

proc ::appcompiler::diagnostic {code node message} {
    set where [dict create]
    foreach key {module line column} {
        dict set where $key [dict get $node $key]
    }
    foreach key {endLine endColumn} {
        if {[dict exists $node $key]} {dict set where $key [dict get $node $key]}
    }
    return [dict create code $code node $where message $message]
}

proc ::appcompiler::formatDiagnostic {diagnostic} {
    set where [dict get $diagnostic node]
    return [format {%s:%d:%d [%s] %s} [dict get $where module] \
        [dict get $where line] [dict get $where column] \
        [dict get $diagnostic code] [dict get $diagnostic message]]
}

proc ::appcompiler::fail {code node message} {
    set diagnostic [diagnostic $code $node $message]
    return -code error -errorcode [list APPCOMPILER DIAGNOSTIC $code] \
        -diagnostic $diagnostic [formatDiagnostic $diagnostic]
}

# Module names are logical identifiers supplied by the caller, independent
# of filenames. Treat source as data throughout checking and generation.
proc ::appcompiler::analyze {sources} {
    set modules [dict create]
    set unavailable [dict create]
    set spelling [dict create]
    set diagnostics {}
    dict for {module source} $sources {
        if {![regexp {^[A-Za-z_][A-Za-z_0-9]*$} $module]} {
            lappend diagnostics [diagnostic MODULE_NAME \
                [dict create module $module line 1 column 1] \
                "invalid module name [list $module]"]
            continue
        }
        set key [string tolower $module]
        if {[dict exists $spelling $key]} {
            lappend diagnostics [diagnostic MODULE_CASE_COLLISION \
                [dict create module $module line 1 column 1] \
                "module names [list [dict get $spelling $key]] and [list $module] differ only by case"]
            dict set unavailable $module 1
            continue
        }
        dict set spelling $key $module
        try {
            dict set modules $module [parseModule $module $source]
        } trap {APPCOMPILER DIAGNOSTIC} {message options} {
            lappend diagnostics [dict get $options -diagnostic]
            dict set unavailable $module 1
        }
    }
    # Known but unparsed imports cannot justify unknown-export diagnostics.
    # Check other declarations, including independent functions in their callers.
    set facts {}
    lappend diagnostics {*}[checkDiagnostics $modules $unavailable facts]
    return [dict create modules $modules diagnostics $diagnostics facts $facts]
}

proc ::appcompiler::check {sources} {
    return [dict get [analyze $sources] diagnostics]
}

proc ::appcompiler::emitChecked {analysis targetNamespace} {
    if {![regexp {^::[A-Za-z_][A-Za-z_0-9]*(::[A-Za-z_][A-Za-z_0-9]*)*$} $targetNamespace]} {
        return -code error -errorcode {APPCOMPILER CONFIG NAMESPACE} \
            "expected an absolute application namespace, got [list $targetNamespace]"
    }
    set diagnostics [dict get $analysis diagnostics]
    if {[llength $diagnostics]} {
        set lines [lmap item $diagnostics {formatDiagnostic $item}]
        return -code error -errorcode {APPCOMPILER CHECK} \
            -diagnostics $diagnostics [join $lines \n]
    }
    set artifact [emitModules [dict get $analysis modules] $targetNamespace [dict get $analysis facts]]
    variable hostDefinitions
    dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $hostDefinitions]
    return $artifact
}

proc ::appcompiler::compile {sources {targetNamespace ::application}} {
    return [emitChecked [analyze $sources] $targetNamespace]
}

# Produce a complete Machteld Tcl entry without running the application.
# The selected entry may be private to its module.
proc ::appcompiler::application {sources entryModule {entryFunction main}} {
    set analysis [analyze $sources]
    set modules [dict get $analysis modules]
    if {![llength [dict get $analysis diagnostics]]} {
        set location [dict create module $entryModule line 1 column 1]
        set found 0
        foreach fn [dict getdef $modules $entryModule functions {}] {
            if {[dict get $fn name] ne $entryFunction} {continue}
            set found 1
            set location $fn
            set parameters [dict get $fn params]
            if {[llength $parameters] != 1 || [dict get [lindex $parameters 0] type] ne "list<text>" \
                    || [dict get $fn result] ne "result<unit,problem>"} {
                dict lappend analysis diagnostics [diagnostic ENTRY_TYPE $location \
                    "entry requires one list<text> parameter and a result<unit,problem> return"]
            }
            break
        }
        if {!$found} {
            dict lappend analysis diagnostics [diagnostic ENTRY_NAME $location \
                "unknown application entry [list $entryModule $entryFunction]"]
        }
    }
    set artifact [emitChecked $analysis ::application]
    set entry ::application::${entryModule}::${entryFunction}
    set dispatch [list ::application::@rt::launch $entry [dict get $artifact sourceMap]]
    set script "package require machteld\n[dict get $artifact script]\n"
    append script "::exit \[$dispatch \$::argv\]\n"
    dict set artifact script $script
    return $artifact
}

source -encoding utf-8 [file join [file dirname [info script]] types.tcl]
source -encoding utf-8 [file join [file dirname [info script]] parser.tcl]
source -encoding utf-8 [file join [file dirname [info script]] check.tcl]
source -encoding utf-8 [file join [file dirname [info script]] emit.tcl]
apply {{dir} {
    set ch [open [file join $dir host.tcl] rb]
    try {
        set ::appcompiler::hostDefinitions [encoding convertfrom -profile strict utf-8 [read $ch]]
    } finally {
        close $ch
    }
}} [file dirname [info script]]
package provide application-compiler 0.1
