package require Tcl 9.0
namespace eval ::appcompiler {}

proc ::appcompiler::diagnosticSpan {node} {
    set line [dict get $node line]
    set column [dict get $node column]
    return [dict create module [dict get $node module] line $line column $column \
        endLine [dict getdef $node endLine $line] endColumn [dict getdef $node endColumn $column]]
}

proc ::appcompiler::diagnostic {code node message} {
    return [dict create code $code node [diagnosticSpan $node] message $message]
}

proc ::appcompiler::formatDiagnostic {diagnostic} {
    set where [diagnosticSpan [dict get $diagnostic node]]
    return [format {%s:%d:%d..%d:%d [%s] %s} [dict get $where module] \
        [dict get $where line] [dict get $where column] \
        [dict get $where endLine] [dict get $where endColumn] \
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
    set resolved {}
    lappend diagnostics {*}[checkDiagnostics $modules $unavailable facts resolved]
    return [dict create modules $modules diagnostics $diagnostics facts $facts resolved $resolved]
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
    set artifact [emitModules [dict get $analysis modules] $targetNamespace [dict get $analysis facts] \
        [dict get $analysis resolved]]
    variable hostDefinitions
    variable decimalDefinitions
    dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $hostDefinitions]
    dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt::decimal $decimalDefinitions]
    return $artifact
}

proc ::appcompiler::compile {sources {targetNamespace ::application}} {
    return [emitChecked [analyze $sources] $targetNamespace]
}

# Produce a complete Machteld Tcl entry without running the application.
# The selected entry may be private to its module.
proc ::appcompiler::application {sources entryModule {entryFunction main} {minApi {}} {packageDirs {}}} {
    set analysis [analyze $sources]
    if {![llength [dict get $analysis diagnostics]]} {
        set location [dict create module $entryModule line 1 column 1]
        set fn [dict getdef $analysis resolved functions $entryModule $entryFunction {}]
        if {$fn ne {}} {
            set parameters [dict get $fn params]
            if {[llength $parameters] != 1 || [dict get [lindex $parameters 0] type] ne "list<text>" \
                    || [dict get $fn result] ne "result<unit,problem>"} {
                dict lappend analysis diagnostics [diagnostic ENTRY_TYPE $fn \
                    "entry requires one list<text> parameter and a result<unit,problem> return"]
            }
        } else {
            dict lappend analysis diagnostics [diagnostic ENTRY_NAME $location \
                "unknown application entry [list $entryModule $entryFunction]"]
        }
    }
    set artifact [emitChecked $analysis ::application]
    set entry ::application::${entryModule}::${entryFunction}
    set dispatch [list ::application::@rt::launch $entry [dict get $artifact sourceMap]]
    set requirement [list package require machteld]
    if {$minApi ne {}} {
        if {[catch {package vcompare $minApi $minApi}]} {
            return -code error -errorcode {APPCOMPILER CONFIG VERSION} "invalid minimum Machteld API [list $minApi]"
        }
        lappend requirement "$minApi-"
    }
    set script "$requirement\n"
    # Tcl reads a package index on demand. Embedded paths resolve beside the
    # generated entry; the source driver supplies absolute project paths.
    foreach path [lreverse $packageDirs] {
        append script [format {set ::auto_path [linsert $::auto_path 0 [file join [file dirname [info script]] %s]]} [list $path]] \n
    }
    append script "[dict get $artifact script]\n"
    append script "::exit \[$dispatch \$::argv\]\n"
    dict set artifact script $script
    return $artifact
}

namespace eval ::appcompiler {
    variable compilerDirectory [file dirname [file normalize [info script]]]
    set modules {types.tcl parser.tcl check.tcl emit.tcl project.tcl project_pack.tcl}
    variable compilerFiles [list pkgIndex.tcl compiler.tcl host.tcl decimal.tcl {*}$modules]
    foreach module $modules {
        source -encoding utf-8 [file join $compilerDirectory $module]
    }
    unset module modules
    foreach name {host decimal} {
        set ch [open [file join $compilerDirectory $name.tcl] rb]
        try {
            set ${name}Definitions [encoding convertfrom -profile strict utf-8 [read $ch]]
        } finally {close $ch}
    }
    unset name ch
    namespace eval decimal $decimalDefinitions
}
package provide application-compiler 0.1
