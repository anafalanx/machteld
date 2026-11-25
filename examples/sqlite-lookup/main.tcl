package require machteld 22-
set entry [file normalize [info script]]
source -encoding utf-8 [file join [file dirname $entry] lookup.tcl]
::lookup::main $entry $argv
