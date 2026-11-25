package require machteld

fconfigure stdout -translation binary -buffering full
switch -- [lindex $argv 0] {
    burst {
        # Short lines stress the record quota independently of the byte quota.
        for {set i 0} {$i < 3000} {incr i} {
            puts stdout [encoding convertto utf-8 "entry $i 雪"]
        }
    }
    interrupted {
        for {set i 0} {$i < 3000} {incr i} { puts stdout "old $i" }
        flush stdout
        after 30000
    }
    replacement { puts stdout replacement }
    partial { puts -nonewline stdout unfinished }
    invalid { puts stdout [binary format H* ff] }
    failed { puts stderr "worker diagnostic"; exit 7 }
    default { error "unknown job test mode" }
}
