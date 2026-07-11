proc run_probe {helper mode payload} {
    set result [run -timeout 200ms -- $helper $mode $payload]
    set status [dict get $result status]

    if {$status eq "timeout"} {
        return [list timeout -1 "" ""]
    }

    return [list \
        $status \
        [dict get $result exit] \
        [dict get $result out] \
        [dict get $result err]]
}
