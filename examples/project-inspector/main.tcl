package require machteld
set here [file dirname [file normalize [info script]]]
source [file join $here launch.tcl]
::inspector::main $here $argv
