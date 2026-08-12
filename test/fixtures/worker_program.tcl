package require machteld

worker on echo {text} { return $text }
worker on big {bytes} { return [string repeat x $bytes] }
worker on noise {bytes} {
    puts stderr [string repeat diagnostic $bytes]
    return ok
}
worker on digest {path {algorithm sha256}} { hash file $algorithm $path }
worker on coded {} { hash sum no-such-algorithm value }
worker on plain {} { error "plain worker error" }
worker on die {} { exit 9 }
worker serve
