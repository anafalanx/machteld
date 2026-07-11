proc iban_check {n} {
    set remainder [expr {$n % 97}]
    return [expr {98 - (($remainder * 100) % 97)}]
}
