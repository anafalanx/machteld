package require machteld 30-
package require sqlite3

namespace eval ::machteld::sqlite {}

proc ::machteld::sqlite::VerifyIntegrity {db} {
    if {[catch {$db eval {PRAGMA integrity_check}} report] || $report ne {ok}} {
        return -code error -errorcode {MACHTELD SQLITE verify} "backup integrity check failed: $report"
    }
}

proc ::machteld::sqlite::backup {connection destination} {
    set connection [uplevel 1 [list namespace which -command $connection]]
    if {$connection eq ""} {
        return -code error -errorcode {MACHTELD SQLITE connection} "expected an open SQLite connection"
    }
    if {$destination eq "" || [regexp {[\u0000\ud800-\udfff]} $destination] ||
        [lindex [file system $destination] 0] ne "native"} {
        return -code error -errorcode {MACHTELD SQLITE path} "expected a native destination file path"
    }
    set destination [file normalize $destination]
    set parent [file dirname $destination]
    if {[file exists $destination]} {
        return -code error -errorcode {MACHTELD SQLITE exists} "backup destination already exists"
    }
    set nonce [binary encode hex [::machteld::hash random 16]]
    set staged [file join $parent ".machteld-sqlite-$nonce.db"]
    set reserved [open $staged {WRONLY CREAT EXCL BINARY} 0600]
    set verifier [namespace current]::verify_$nonce
    try {
        close $reserved
        $connection backup $staged
        # A source in WAL mode can give the destination a WAL-mode header.
        # Convert it to a self-contained database, then independently reopen
        # it read-only for the actual integrity check.
        sqlite3 $verifier $staged -create 0
        try {
            if {[$verifier onecolumn {PRAGMA journal_mode=DELETE}] ne "delete"} {
                return -code error -errorcode {MACHTELD SQLITE verify} "backup requires external journal files"
            }
            # SQLite 3.53.4 does not retain CHECK expressions when parsing a
            # read-only B-tree. A table definition containing that keyword
            # therefore needs a check here as well. A quoted name or comment
            # containing it only causes an extra verification pass.
            if {[$verifier onecolumn {SELECT EXISTS(
                    SELECT 1 FROM sqlite_schema WHERE type='table' AND instr(lower(sql),'check')>0
                )}]} {
                $verifier eval {PRAGMA query_only=ON}
                VerifyIntegrity $verifier
            }
        } finally {$verifier close}
        sqlite3 $verifier $staged -readonly 1 -create 0
        try {
            VerifyIntegrity $verifier
        } finally {$verifier close}
        try {
            return [::machteld::Publish $staged $destination -createonly]
        } trap {MACHTELD PUBLISH} {message options} {
            dict set options -errorcode [lreplace [dict get $options -errorcode] 1 1 SQLITE]
            return -options $options $message
        }
    } finally {
        foreach suffix {{} -wal -shm -journal} {file delete -- $staged$suffix}
    }
}

package provide machteld::sqlite 1.0
