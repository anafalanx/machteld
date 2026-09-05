---
id: machteld/command/hash
type: command
title: hash
summary: Hash values and files, compute HMACs, stream digests, and obtain system random bytes.
commands: hash, hash sum, hash file, hash hmac, hash start, hash update, hash final, hash list, hash algorithms, hash random
---

# hash

## Synopsis

```tcl
hash sum algorithm data ?-binary?
hash file algorithm path ?-binary?
hash hmac algorithm key data ?-binary?
hash start algorithm
hash update token data
hash final token ?-binary?
hash list
hash algorithms
hash random count
```

## Arguments and options

`algorithm` is one of `md5`, `sha1`, `sha256`, `sha384`, or `sha512`.
`-binary` selects a bytearray digest instead of lowercase hexadecimal. String
values are hashed as their Tcl bytes; bytearray values remain byte-for-byte.
`count` for random data is 1 through 1,048,576.

## Results

Digest operations return hexadecimal text by default or a bytearray with
`-binary`. `start` returns `hash#...`; `update` returns empty and `final`
consumes the token. `list` returns live context tokens, `algorithms` returns the
closed algorithm list, and `random` returns a bytearray.

## Errors

Raised codes are `HASH badvalue`, `HASH nohandle`, `HASH notfound`,
`HASH oserror`, and `HASH usage`, plus Tcl wrong-arity errors. Unknown
algorithms are `badvalue`; missing files are `notfound`.

## Lifetime and timeouts

One-shot operations retain no state. Incremental contexts live until `final` or
interpreter teardown. There is no timeout; file hashing reads synchronously in
64 KiB chunks.

## Examples

```tcl
set digest [hash file sha256 C:/images/disk.iso]
set h [hash start sha256]
hash update $h $part1
hash update $h $part2
set digest [hash final $h]
set nonce [hash random 32]
```

## Constraints

The implementation uses Windows CNG. MD5 and SHA-1 are available for
interoperability, not recommended for collision resistance. `random` uses the
system-preferred cryptographic generator.

## Subcommands

<a id="sum"></a>
### sum

#### Synopsis

`hash sum algorithm data ?-binary?`

#### Arguments and options

Hashes one in-memory value; `-binary` changes only result representation.

#### Results

Returns the completed digest.

#### Errors

Invalid algorithm/input size or CNG failure uses the `HASH` codes above.

#### Lifetime and timeouts

One synchronous operation with no retained context.

#### Examples

`hash sum sha256 "hello"`

#### Constraints

One update is limited by the Windows CNG input-length interface.

#### See also

`machteld/command/hash#start`.

<a id="file"></a>
### file

#### Synopsis

`hash file algorithm path ?-binary?`

#### Arguments and options

Reads the Tcl VFS path in binary mode, including zipfs paths.

#### Results

Returns a digest without loading the whole file into memory.

#### Errors

Missing paths report `HASH notfound`; open/read/close failures report `oserror`.

#### Lifetime and timeouts

The file channel and hash provider close before return.

#### Examples

`set checksum [hash file sha512 $archive]`

#### Constraints

The file can change while it is read; the result then describes bytes observed
during that read, not an atomic snapshot.

#### See also

`machteld/command/canon`.

<a id="hmac"></a>
### hmac

#### Synopsis

`hash hmac algorithm key data ?-binary?`

The `key` follows the same rule as `data`: a bytearray is used byte for byte,
any other value as its UTF-8 string representation, so a hex-spelled key
string is not the key `binary decode hex` produces.

#### Arguments and options

`key` and `data` are byte-preserving Tcl values. `-binary` selects output form.

#### Results

Returns the HMAC digest.

#### Errors

Invalid algorithm/size and CNG failures use `HASH badvalue` or `oserror`.

#### Lifetime and timeouts

One synchronous operation; provider state is destroyed before return.

#### Examples

`hash hmac sha256 $secret $message -binary`

#### Constraints

There is no incremental HMAC surface.

#### See also

`machteld/command/hash#sum`.

<a id="start"></a>
### start

#### Synopsis

`hash start algorithm`

#### Arguments and options

Takes one supported algorithm and no options.

#### Results

Returns a new incremental context token.

#### Errors

Unknown algorithms and allocation/provider failures use `badvalue`/`oserror`.

#### Lifetime and timeouts

The token owns native CNG state until `final` or interpreter teardown.

#### Examples

`set h [hash start sha384]`

#### Constraints

The token belongs only to its creating interpreter.

#### See also

`machteld/command/hash#update`.

<a id="update"></a>
### update

#### Synopsis

`hash update token data`

#### Arguments and options

Appends one byte/string value to the digest stream.

#### Results

Returns empty.

#### Errors

Stale tokens report `HASH nohandle`; input or CNG failures use documented codes.

#### Lifetime and timeouts

The token remains live for more updates.

#### Examples

`foreach chunk $chunks { hash update $h $chunk }`

#### Constraints

Updates are ordered and cannot be rolled back or cloned.

#### See also

`machteld/command/hash#final`.

<a id="final"></a>
### final

#### Synopsis

`hash final token ?-binary?`

#### Arguments and options

`-binary` selects bytearray output.

#### Results

Returns the completed digest.

#### Errors

Stale tokens report `nohandle`; finalization failures report `oserror`.

#### Lifetime and timeouts

Consumes and invalidates the token even when native finalization fails.

#### Examples

`set digest [hash final $h -binary]`

#### Constraints

A context cannot be finalized twice.

#### See also

`machteld/command/hash#start`.

<a id="list"></a>
### list

#### Synopsis

`hash list`

#### Arguments and options

No arguments.

#### Results

Returns live incremental context tokens.

#### Errors

Only wrong arity is expected.

#### Lifetime and timeouts

Non-consuming.

#### Examples

`puts [hash list]`

#### Constraints

Ordering is unspecified.

#### See also

`machteld/command/hash#final`.

<a id="algorithms"></a>
### algorithms

#### Synopsis

`hash algorithms`

#### Arguments and options

No arguments.

#### Results

Returns `md5 sha1 sha256 sha384 sha512`.

#### Errors

Only wrong arity is expected.

#### Lifetime and timeouts

Pure constant query.

#### Examples

`if {"sha256" in [hash algorithms]} { ... }`

#### Constraints

The list is deliberately closed for this release.

#### See also

`machteld/command/manifest`.

<a id="random"></a>
### random

#### Synopsis

`hash random count`

#### Arguments and options

`count` is an integer from 1 to 1,048,576 inclusive.

#### Results

Returns exactly `count` cryptographically random bytes.

#### Errors

Bad counts report `HASH badvalue`; generator failure reports `oserror`.

#### Lifetime and timeouts

No persistent generator state is exposed.

#### Examples

`set token [binary encode hex [hash random 32]]`

#### Constraints

Do not substitute Tcl `rand()` where unpredictability matters.

#### See also

`machteld/command/hash#sum`.

## See also

`machteld/command/store`, `machteld/command/http`.
