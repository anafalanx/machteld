package require -exact machteld 30

# Historical single-case entry point. The release gate runs the full corpus.
set argv {sqlite-profile archive}
source -encoding utf-8 [file join [file dirname [info script]] application_corpus_test.tcl]
