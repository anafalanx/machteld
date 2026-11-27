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
            set parsed [parseModule $module $source diagnostics]
            if {$parsed eq {}} {
                dict set unavailable $module 1
            } else {
                dict set modules $module $parsed
            }
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

proc ::appcompiler::emitChecked {analysis targetNamespace {toolRoot {}}} {
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
    # The runtime uses one source map for entry faults, Tcl exports and
    # secondary exceptions captured before a scoped cleanup can unwind.
    dict append artifact script \n [list ::proc ${targetNamespace}::@rt::sourceMap {} \
        [list ::return [dict get $artifact sourceMap]]]
    variable hostDefinitions
    variable decimalDefinitions
    dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $hostDefinitions]
    dict append artifact script \n [eventBridge $targetNamespace $targetNamespace]
    dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt::decimal $decimalDefinitions]
    if {[dict getdef $analysis resolved usesProcess 0]} {
        variable processDefinitions
        set runtime ${targetNamespace}::@rt
        dict append artifact script \n [list ::namespace eval $runtime $processDefinitions]
        dict append artifact script \n [list ::unset -nocomplain ${runtime}::toolDirectory]
        if {$toolRoot eq "@startup"} {
            # The archive's public, native argv0 is set before main.tcl runs.
            # Capture it before an application can change cwd or argv0.
            dict append artifact script \n [format {if {[file pathtype $::argv0] eq "absolute"} {::set %s [::file dirname $::argv0]}} \
                [list ${runtime}::toolDirectory]]
        } elseif {$toolRoot ne ""} {
            dict append artifact script \n [list ::set ${runtime}::toolDirectory $toolRoot]
        }
    }
    if {[dict getdef $analysis resolved usesWorkers 0]} {
        variable workerDefinitions
        set rt ${targetNamespace}::@rt
        dict append artifact script \n [list ::namespace eval $rt $workerDefinitions]
        set table {}
        set messages {}
        dict for {module functions} [dict get $analysis resolved functions] {
            dict for {name fn} $functions {
                if {[dict get $fn kind] ne "worker"} continue
                set request [dict get [lindex [dict get $fn params] 0] type]
                set reply [dict get $fn result]
                dict set table $module.$name [list ${targetNamespace}::${module}::${name} $request $reply [emitLocation $fn]]
                dict set messages $request 1
                dict set messages $reply 1
            }
        }
        dict append artifact script \n [list ::set ${rt}::workerTable $table]
        dict append artifact script \n [list ::set ${rt}::workerMessageTypes $messages]
    }
    if {[dict getdef $analysis resolved usesTk 0]} {
        variable widgetsDefinitions
        dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $widgetsDefinitions]
        dict append artifact script \n [tkBridge $targetNamespace $targetNamespace]
    }
    if {[dict getdef $analysis resolved usesTemporal 0]} {
        variable temporalDefinitions
        dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $temporalDefinitions]
    }
    if {[dict getdef $analysis resolved usesZone 0]} {
        variable zoneDefinitions
        dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $zoneDefinitions]
    }
    if {[dict getdef $analysis resolved usesSql 0]} {
        variable sqlDefinitions
        dict append artifact script \n [list ::namespace eval ${targetNamespace}::@rt $sqlDefinitions]
    }
    return $artifact
}

proc ::appcompiler::tkBridge {public implementation} {
    set script [list ::namespace eval ${public}::@tk {}]
    foreach {name helper} {canvas_path tkCanvasPath attach_items tkTagItems} {
        append script \n [list ::interp alias {} ${public}::@tk::$name {} ${implementation}::@rt::$helper]
    }
    return $script
}

proc ::appcompiler::eventBridge {public implementation} {
    set public ${public}::@events
    set script [list ::namespace eval $public {}]
    foreach {name helper} {on_fault onFault last_fault lastFault} {
        append script \n [list ::interp alias {} ${public}::$name {} ${implementation}::@rt::$helper]
    }
    return $script
}

proc ::appcompiler::compile {sources {targetNamespace ::application}} {
    return [emitChecked [analyze $sources] $targetNamespace]
}

proc ::appcompiler::analyzeApplication {sources entryModule entryFunction} {
    set analysis [analyze $sources]
    if {![llength [dict get $analysis diagnostics]]} {
        set location [dict create module $entryModule line 1 column 1]
        set fn [dict getdef $analysis resolved functions $entryModule $entryFunction {}]
        if {$fn ne {}} {
            set parameters [dict get $fn params]
            if {[dict get $fn kind] eq "worker" || [llength [dict getdef $fn typeParams {}]] ||
                    [llength $parameters] != 1 || [dict get [lindex $parameters 0] type] ne "list<text>" \
                    || [dict get $fn result] ne "result<unit,problem>"} {
                dict lappend analysis diagnostics [diagnostic ENTRY_TYPE $fn \
                    "entry requires a concrete function with one list<text> parameter and a result<unit,problem> return"]
            }
        } else {
            dict lappend analysis diagnostics [diagnostic ENTRY_NAME $location \
                "unknown application entry [list $entryModule $entryFunction]"]
        }
    }
    return $analysis
}

proc ::appcompiler::applicationPrelude {minApi packageDirs} {
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
    return $script
}

# Produce a complete Machteld Tcl entry without running the application.
proc ::appcompiler::workerPrelude {implementation} {
    set rt ${implementation}::@rt
    set lines [list [list ::namespace eval ::application {}] \
        [list ::interp alias {} ::application::workers {} ${rt}::workerControl]]
    lappend lines [format {if {$::argv eq "--machteld-typed-worker-v1"} {%s; ::exit 0}} [list ${rt}::workerServe]]
    return [join $lines \n]
}

# The selected entry may be private to its module.
proc ::appcompiler::application {sources entryModule {entryFunction main} {minApi {}} {packageDirs {}} {toolRoot @startup}} {
    set analysis [analyzeApplication $sources $entryModule $entryFunction]
    set artifact [emitChecked $analysis ::application $toolRoot]
    set entry ::application::${entryModule}::${entryFunction}
    set dispatch [list ::application::@rt::launch $entry]
    set script [applicationPrelude $minApi $packageDirs]
    append script "[dict get $artifact script]\n"
    if {[dict getdef $analysis resolved usesWorkers 0]} {
        append script [workerPrelude ::application] \n
        set dispatch [list ::application::@rt::workerMain {*}$dispatch]
    }
    append script [format {::exit [%s [::application::@rt::sourceMap] $::argv]} $dispatch] \n
    dict set artifact script $script
    dict set artifact modules [dict get $analysis modules]
    return $artifact
}

# A Tcl entry owns its interpreter and event loop. Only exported functions
# get public Tcl commands. Typed-to-typed calls stay inside the implementation.
proc ::appcompiler::tclApplication {sources entryPath minApi packageDirs {toolRoot @startup}} {
    set analysis [analyze $sources]
    set implementation ::machteld::compiledApplication
    set artifact [emitChecked $analysis $implementation $toolRoot]
    set script [applicationPrelude $minApi $packageDirs]
    if {[dict size $sources]} {
        append script [dict get $artifact script] \n
        set rt ${implementation}::@rt
        append script [eventBridge ::application $implementation] \n
        if {[dict getdef $analysis resolved usesWorkers 0]} {
            append script [workerPrelude $implementation] \n
        }
        if {[dict getdef $analysis resolved usesTk 0]} {
            append script [tkBridge ::application $implementation] \n
        }
        dict for {module functions} [dict get $analysis resolved functions] {
            set public ::application::${module}
            append script [list ::namespace eval $public {}] \n
            dict for {name function} $functions {
                if {![dict get $function exported] || [dict get $function kind] eq "worker"} continue
                set command [list ::tailcall ${rt}::callExport ${implementation}::${module}::${name} [emitLocation $function]]
                set formals {}
                if {[llength [dict getdef $function typeParams {}]]} {
                    lappend formals typeArguments
                    append command { $typeArguments}
                }
                foreach param [dict get $function params] {
                    set local [emitLocalName [dict get $param name]]
                    lappend formals $local
                    append command " \$$local"
                }
                append script [list ::proc ${public}::${name} $formals $command] \n
                append script [list ::namespace eval $public [list ::namespace export $name]] \n
            }
        }
    }
    # Loose projects supply an absolute path. A packed startup script
    # resolves the original entry within its own verified archive.
    append script [format {::source -encoding utf-8 [::file join [::file dirname [::info script]] %s]} [list $entryPath]] \n
    dict set artifact script $script
    dict set artifact modules [dict get $analysis modules]
    return $artifact
}

namespace eval ::appcompiler {
    variable compilerDirectory [file dirname [file normalize [info script]]]
    set modules {types.tcl parser.tcl check.tcl emit.tcl examples.tcl project.tcl project_pack.tcl reference.tcl}
    variable compilerFiles [list pkgIndex.tcl compiler.tcl driver.tcl README.md host.tcl decimal.tcl sql.tcl temporal.tcl zone.tcl process.tcl worker.tcl widgets.tcl {*}$modules]
    foreach module $modules {
        source -encoding utf-8 [file join $compilerDirectory $module]
    }
    unset module modules
    foreach name {host decimal sql temporal zone process worker widgets} {
        set ch [open [file join $compilerDirectory $name.tcl] rb]
        try {
            set ${name}Definitions [encoding convertfrom -profile strict utf-8 [read $ch]]
        } finally {close $ch}
    }
    unset name ch
    namespace eval decimal $decimalDefinitions
}
package provide application-compiler 0.1
