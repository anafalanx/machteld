package require machteld 22-

namespace eval ::publishTest {
    namespace path ::machteld
    proc check {label condition} {
        if {!$condition} { error "FAIL publish: $label" }
        puts "ok   publish: $label"
    }
    proc bytes {path} {
        set channel [open $path rb]
        try { read $channel } finally { close $channel }
    }
    proc code {script} {
        if {![catch {uplevel 1 $script} message options]} { return {} }
        return [dict get $options -errorcode]
    }
    proc run {} {
        set homeDir [file tempdir]
        try {
            set dest [file join $homeDir {résultat and 雪.txt}]
            set staged [file join $homeDir ready.tmp]
            set text "résumé\0雪\r\n"
            check "creates a UTF-8 file without newline conversion" [expr {
                [publish bytes $dest $text] eq $dest &&
                [bytes $dest] eq [encoding convertto utf-8 $text]}]
            set binary [binary decode hex 0080ff0d0a00]
            check "replaces text with exact binary bytes" [expr {
                [publish bytes $dest $binary] eq $dest && [bytes $dest] eq $binary}]
            check "empty content replaces an existing file" [expr {
                [publish bytes $dest {}] eq $dest && [file size $dest] == 0}]

            publish bytes $staged $binary
            check "moves a completed file to its destination" [expr {
                [publish file $dest $staged] eq $dest && ![file exists $staged] &&
                [bytes $dest] eq $binary}]
            check "same-identity or missing candidate leaves destination alone" [expr {
                [code {publish file $dest $dest}] eq {MACHTELD PUBLISH badvalue} &&
                [code {publish file $dest $staged}] eq {MACHTELD PUBLISH badvalue} &&
                [bytes $dest] eq $binary}]
            set directory [file join $homeDir subdir]
            file mkdir $directory
            check "failed replacement cleans up the private candidate" [expr {
                [code {publish bytes $directory failure}] eq {MACHTELD PUBLISH badvalue} &&
                [glob -nocomplain -directory $homeDir .machteld-save-*] eq {} &&
                [file isdirectory $directory]}]
            check "rejects missing arguments, unknown verbs and a NUL path" [expr {
                [code {publish bytes $dest}] eq {MACHTELD PUBLISH usage} &&
                [code {publish append $dest more}] eq {MACHTELD PUBLISH usage} &&
                [code {publish bytes "${dest}\0suffix" value}] eq {MACHTELD PUBLISH badvalue} &&
                [bytes $dest] eq $binary}]

            publish bytes $staged $text
            set reader [open $dest rb]
            try {
                check "a locked destination preserves both files on failed replacement" [expr {
                    [code {publish bytes $dest lost}] eq {MACHTELD PUBLISH oserror} &&
                    [code {publish file $dest $staged}] eq {MACHTELD PUBLISH oserror} &&
                    [read $reader] eq $binary &&
                    [bytes $staged] eq [encoding convertto utf-8 $text] &&
                    [glob -nocomplain -directory $homeDir .machteld-save-*] eq {}}]
            } finally { close $reader }
            check "both publishers succeed after the reader releases its handle" [expr {
                [publish file $dest $staged] eq $dest && ![file exists $staged] &&
                [bytes $dest] eq [encoding convertto utf-8 $text] &&
                [publish bytes $dest $binary] eq $dest && [bytes $dest] eq $binary}]

            # Windows recovery-path failures are difficult to induce deterministically.
            # Prove that the public command keeps a native diagnostic and its own domain.
            rename ::machteld::Publish ::publishTest::realPublish
            proc ::machteld::Publish {candidate path} {
                return -code error -errorcode {MACHTELD WRAP oserror} \
                    "replacement failed; prior destination remains at RECOVERY-PATH"
            }
            try {
                set failed [catch {publish bytes $dest $text} message options]
                check "forwards a recovery location and removes its candidate on error" [expr {
                    $failed && [dict get $options -errorcode] eq {MACHTELD PUBLISH oserror} &&
                    [string match *RECOVERY-PATH $message] && [bytes $dest] eq $binary &&
                    [glob -nocomplain -directory $homeDir .machteld-save-*] eq {}}]
            } finally {
                rename ::machteld::Publish {}
                rename ::publishTest::realPublish ::machteld::Publish
            }
        } finally { file delete -force -- $homeDir }
    }
}
::publishTest::run
