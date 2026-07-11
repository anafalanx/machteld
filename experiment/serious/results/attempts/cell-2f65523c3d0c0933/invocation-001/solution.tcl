proc iban_check {n} {
    set r [expr {$n % 97}]
    return [expr {98 - (($r * 100) % 97)}]
}
