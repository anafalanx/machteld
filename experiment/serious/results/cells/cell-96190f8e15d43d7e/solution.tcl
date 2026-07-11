proc iban_check {n} {
    return [expr {98 - (($n * 100) % 97)}]
}
