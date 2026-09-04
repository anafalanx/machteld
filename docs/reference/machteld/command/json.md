---
id: machteld/command/json
type: command
title: json
summary: Decode and encode JSON values, plainly or with real JSON types.
commands: json, json decode, json encode, json value, json type, json unwrap, json get, json exists
---

# json

## Synopsis

```tcl
json decode ?-typed? ?-maxbytes N? text
json encode ?-dict|-list? ?-plain? ?--? value
json value string TEXT | number LITERAL | boolean BOOL | null
json value array LIST | object DICT
json type VALUE
json unwrap VALUE
json get VALUE ?key|index ...?
json exists VALUE key|index ...
```

## Arguments and options

Plain `decode` accepts exactly one complete JSON value. `-typed` returns an
opaque typed value carrying real JSON identity, with strict decoding.
`-maxbytes` (typed only) sets the input byte limit, whose default is 16 MiB
and hard cap is 64 MiB. `encode` uses a Tcl object's internal
dict/list representation when available; `-dict` or `-list` forces the outer
container interpretation and they are mutually exclusive; `-plain` refuses
typed values by name - it is the wire paths' guard. `--` ends option parsing
so an option-shaped scalar can be encoded.

## Results

Plain decode maps JSON objects to dicts, arrays to lists, booleans to
integers, null to the empty string, strings to Tcl strings, and preserves
number spelling; duplicate object keys keep the last value. Typed decode
returns one opaque typed value. Encode returns one compact JSON text and
recognizes typed values at every nesting level.

## Errors

Raised codes are `JSON absent`, `JSON depth`, `JSON limit`, `JSON parse`,
`JSON strict`, `JSON type`, and `JSON usage`. Tcl conversion errors can
occur when a forced dict/list value is malformed.

## Lifetime and timeouts

All operations are synchronous and have no timeout. A typed value holds its
document alive for the handle's lifetime.

## Examples

```tcl
set value [json decode {{"name":"machteld","jobs":4}}]
set wire [json encode -dict [dict create ok 1 result $value]]
set req [json value object [dict create \
    id [json value number 7] flatten [json value boolean true]]]
set envelope [json decode -typed $frame]
if {[json exists $envelope sessionId]} {
    set sid [json unwrap [json get $envelope sessionId]]
}
```

## Constraints

Maximum nesting depth is 512. In PLAIN mode null, empty string, and false do
not all round-trip distinctly through ordinary Tcl scalar values, and a
scalar whose text is exactly a JSON number literal encodes as a number - the
typed mode exists for programs that need more. An escaped unpaired UTF-16
surrogate is a parse error in both modes. Typed constructors accept typed
values and nested plain dict/list containers, and refuse plain scalar leaves
by name; `json value number` validates the exact JSON number grammar
fail-closed. A typed handle that has been through a string operation is a
plain string again and refuses at its next construction - build wire-bound
trees as typed containers, construct late, hold the handle. Stringification,
`store`, and worker/pool/pmap JSON-lines transport do not preserve the type.

## Subcommands

<a id="decode"></a>
### decode

#### Synopsis

`json decode ?-typed? ?-maxbytes N? text`

#### Arguments and options

The entire string must contain one JSON value plus optional JSON whitespace.
`-typed` returns an opaque typed value under strict decoding; `-maxbytes`
(typed only) sets a positive byte limit. The default is 16 MiB and the hard
cap is 64 MiB.

#### Results

Plain: Tcl dict/list/scalar values retaining JSON container identity. Typed:
one opaque typed value answering `json type`, `unwrap`, `get`, `exists`.

#### Errors

Malformed or trailing content reports `JSON parse`; excessive nesting reports
`JSON depth`; a typed decode with duplicate object members reports
`JSON strict`; input past the byte limit reports `JSON limit`.

#### Lifetime and timeouts

Pure synchronous parsing.

#### Examples

`set rows [json decode {[]}]`

#### Constraints

In plain mode duplicate object names resolve last-wins; typed mode refuses
them at every nesting level.

#### See also

`machteld/command/worker#serve`.

<a id="encode"></a>
### encode

#### Synopsis

`json encode ?-dict|-list? ?-plain? ?--? value`

#### Arguments and options

Force only the outer container. `-plain` refuses typed values by name; worker
and pool protocol paths encode with it. `--` is necessary for a
literal such as `-dict` that must be data.

#### Results

Returns compact valid JSON. Typed values anywhere in the tree are written
with their real JSON types.

#### Errors

Conflicting force options or extra values report `JSON usage`; nesting beyond
512 reports `JSON depth`; a typed value under `-plain` reports `JSON type`.

#### Lifetime and timeouts

Pure synchronous serialization.

#### Examples

`json encode -list [list one two three]`

#### Constraints

Plain Tcl values do not encode a distinct JSON-null marker; `json value null`
does.

#### See also

`machteld/command/http#post`.

<a id="value"></a>
### value

#### Synopsis

`json value string TEXT | number LITERAL | boolean BOOL | null |
array LIST | object DICT`

#### Arguments and options

One kind, one value (`null` takes none). `array` reads its argument as a
list, `object` as a dict; their elements must be typed values or nested
plain containers - a plain scalar leaf refuses.

#### Results

An opaque typed value.

#### Errors

A non-grammar `number` literal, a plain scalar leaf, or a shimmered handle
reports `JSON type`; a malformed `boolean` is a Tcl boolean error.

#### Lifetime and timeouts

Synchronous; the value holds its document until the handle is released.

#### Examples

`json value object [dict create ok [json value boolean true]]`

#### Constraints

`number` validates the exact JSON number grammar fail-closed and preserves
spelling verbatim. Containers copy their typed leaves at construction; later
changes to a source handle never affect a built container.

#### See also

`machteld/command/json#encode`.

<a id="type"></a>
### type

#### Synopsis

`json type VALUE`

#### Arguments and options

Exactly one typed value.

#### Results

One of `string`, `number`, `boolean`, `null`, `array`, `object`.

#### Errors

A value that is not typed reports `JSON type`.

#### Lifetime and timeouts

Pure synchronous inspection.

#### Examples

`json type [json value null]`

#### Constraints

Raw-preserved numbers answer `number`; there is no separate raw tag.

#### See also

`machteld/command/json#get`.

<a id="unwrap"></a>
### unwrap

#### Synopsis

`json unwrap VALUE`

#### Arguments and options

Exactly one typed value.

#### Results

The plain-mode Tcl mapping of the typed subtree - the documented exit from
typed to plain, with plain's ambiguities.

#### Errors

A value that is not typed reports `JSON type`; nesting beyond 512 reports
`JSON depth`.

#### Lifetime and timeouts

Pure synchronous conversion.

#### Examples

`json unwrap [json get $envelope id]`

#### Constraints

Unwrapping re-enters plain mode's collapses: booleans become integers, null
becomes the empty string.

#### See also

`machteld/command/json#decode`.

<a id="get"></a>
### get

#### Synopsis

`json get VALUE ?key|index ...?`

#### Arguments and options

Each step is an object key or a 0-based array index.

#### Results

The typed child at the path (sharing the parent's document).

#### Errors

A missing member reports `JSON absent`; a step into a non-container reports
`JSON type`.

#### Lifetime and timeouts

Pure synchronous traversal; the child keeps the whole document alive.

#### Examples

`json unwrap [json get $envelope result ok]`

#### Constraints

Array indices are 0-based, matching Tcl list indexing.

#### See also

`machteld/command/json#exists`.

<a id="exists"></a>
### exists

#### Synopsis

`json exists VALUE key|index ...`

#### Arguments and options

At least one path step, each an object key or a 0-based array index.

#### Results

`1` when the path resolves, `0` otherwise - including through
non-containers.

#### Errors

A value that is not typed reports `JSON type`.

#### Lifetime and timeouts

Pure synchronous traversal.

#### Examples

`json exists $envelope sessionId`

#### Constraints

Probing never raises for absence; only a non-typed VALUE argument raises.

#### See also

`machteld/command/json#get`.

## See also

`machteld/command/http`, `machteld/command/worker`.
