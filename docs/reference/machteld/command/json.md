---
id: machteld/command/json
type: command
title: json
summary: Decode and encode bounded JSON values without external packages.
commands: json, json decode, json encode
---

# json

## Synopsis

```tcl
json decode text
json encode ?-dict|-list? ?--? value
```

## Arguments and options

`decode` accepts exactly one complete JSON value. `encode` uses Tcl object's
internal dict/list representation when available; `-dict` or `-list` forces the
outer container interpretation and they are mutually exclusive. `--` ends
option parsing so an option-shaped scalar can be encoded.

## Results

Decode maps JSON objects to dicts, arrays to lists, booleans to integers, null
to the empty string, strings to Tcl strings, and preserves number spelling.
Duplicate object keys keep the last value. Encode returns one compact JSON text.

## Errors

Raised codes are `JSON depth`, `JSON parse`, and `JSON usage`. Tcl conversion
errors can occur when a forced dict/list value is malformed.

## Lifetime and timeouts

Both operations are synchronous, retain no state, and have no timeout.

## Examples

```tcl
set value [json decode {{"name":"machteld","jobs":4}}]
set wire [json encode -dict [dict create ok 1 result $value]]
set literal [json encode -- -dict]
```

## Constraints

Maximum nesting depth is 512. Null, empty string, and false do not all
round-trip distinctly through ordinary Tcl scalar values. A scalar whose text
is exactly a JSON number literal encodes as a number. An escaped unpaired UTF-16
surrogate decodes as U+FFFD.

## Subcommands

<a id="decode"></a>
### decode

#### Synopsis

`json decode text`

#### Arguments and options

The entire string must contain one JSON value plus optional JSON whitespace.

#### Results

Returns Tcl dict/list/scalar values while retaining JSON container identity.

#### Errors

Malformed or trailing content reports `JSON parse`; excessive nesting reports
`JSON depth`.

#### Lifetime and timeouts

Pure synchronous parsing.

#### Examples

`set rows [json decode {[]}]`

#### Constraints

Duplicate object names resolve last-wins.

#### See also

`machteld/command/worker#serve`.

<a id="encode"></a>
### encode

#### Synopsis

`json encode ?-dict|-list? ?--? value`

#### Arguments and options

Force only the outer container. `--` is necessary for a literal such as
`-dict` that must be data.

#### Results

Returns compact valid JSON.

#### Errors

Conflicting force options or extra values report `JSON usage`; nesting beyond
512 reports `JSON depth`.

#### Lifetime and timeouts

Pure synchronous serialization.

#### Examples

`json encode -list [list one two three]`

#### Constraints

Tcl values do not encode a distinct JSON-null marker.

#### See also

`machteld/command/http#post`.

## See also

`machteld/command/http`, `machteld/command/worker`.
