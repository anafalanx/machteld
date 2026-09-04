---
id: machteld/command/store
type: command
title: store
summary: Use a binary-safe key/value store backed by the statically linked SQLite library.
commands: store, store open, store put, store get, store keys, store del, store close, store version
---

# store

## Synopsis

```tcl
store open ?path?
store put key value
store get key
store keys
store del key
store close
store version
```

## Arguments and options

`open` without `path` uses an in-memory database; a nonempty path creates or
opens a durable database. Keys are Tcl text. A bytearray value is stored exactly;
other values use their UTF-8 string representation. There are no options.

## Results

`get` always returns a bytearray. `keys` returns all keys in SQLite text order.
`del` returns `1` if it removed a row and `0` otherwise. `version` returns the
linked SQLite version. `open`, `put`, and `close` return empty.

## Errors

Raised codes are `STORE badvalue`, `STORE notfound`, `STORE notopen`, and
`STORE sqlite`, plus Tcl wrong-arity errors. `notfound` is specific to a missing
key; operations before open report `notopen`.

## Lifetime and timeouts

One store connection exists per interpreter. A later `open` closes the previous
connection first. Both in-memory and file stores configure a five-second SQLite
busy timeout. `close` is idempotent; interpreter teardown closes any connection.

## Examples

```tcl
store open C:/state/tool.sqlite
try {
    store put checkpoint $bytes
    set restored [store get checkpoint]
} finally {
    store close
}
```

## Constraints

This is intentionally not an SQL escape hatch. Machteld owns a table named
`kv(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID`; do not treat the database
schema as an extension API. Independent processes can share a file subject to
normal SQLite locking.

## Subcommands

<a id="open"></a>
### open

#### Synopsis

`store open ?path?`

#### Arguments and options

No path means `:memory:`. A path must be nonempty and contain no NUL.

#### Results

Returns empty after opening and ensuring the key/value table exists.

#### Errors

Invalid path reports `badvalue`; SQLite open/schema failures report `sqlite`.

#### Lifetime and timeouts

Replaces any existing connection and installs a five-second busy timeout.

#### Examples

`store open state.sqlite`

#### Constraints

Opening another database discards an in-memory store and closes the old file.

#### See also

`machteld/command/store#close`.

<a id="put"></a>
### put

#### Synopsis

`store put key value`

#### Arguments and options

Creates or replaces one key. Bytearrays preserve exact bytes.

#### Results

Returns empty.

#### Errors

Requires an open store; SQLite binding/write failures report `sqlite`.

#### Lifetime and timeouts

One autocommit statement, subject to the connection busy timeout.

#### Examples

`store put image $binaryImage`

#### Constraints

The API has no multi-operation transaction surface.

#### See also

`machteld/command/store#get`.

<a id="get"></a>
### get

#### Synopsis

`store get key`

#### Arguments and options

Takes one text key.

#### Results

Returns the stored bytes as a bytearray.

#### Errors

Missing key reports `STORE notfound`; no connection reports `notopen`.

#### Lifetime and timeouts

One read statement; no retained cursor.

#### Examples

`binary encode base64 [store get image]`

#### Constraints

Text originally put is returned as bytes; decode it according to the program's
own format.

#### See also

`machteld/command/store#put`.

<a id="keys"></a>
### keys

#### Synopsis

`store keys`

#### Arguments and options

No arguments.

#### Results

Returns every key ordered by SQLite's text ordering.

#### Errors

Requires an open store and can report `STORE sqlite`.

#### Lifetime and timeouts

Materializes the complete key list before return.

#### Examples

`foreach key [store keys] { puts $key }`

#### Constraints

There is no prefix/range pagination; large keyspaces are returned in full.

#### See also

`machteld/command/store#get`.

<a id="del"></a>
### del

#### Synopsis

`store del key`

#### Arguments and options

Takes one text key.

#### Results

Returns `1` when removed and `0` when absent.

#### Errors

Requires an open store and can report `STORE sqlite`.

#### Lifetime and timeouts

One autocommit delete statement.

#### Examples

`if {[store del obsolete]} { puts removed }`

#### Constraints

Absence is not an error for deletion.

#### See also

`machteld/command/store#get`.

<a id="close"></a>
### close

#### Synopsis

`store close`

#### Arguments and options

No arguments.

#### Results

Returns empty, including when no store is open.

#### Errors

SQLite close failure reports `STORE sqlite`.

#### Lifetime and timeouts

Releases the connection; subsequent data operations report `notopen`.

#### Examples

`try { ... } finally { store close }`

#### Constraints

An in-memory database cannot be recovered after close.

#### See also

`machteld/command/store#open`.

<a id="version"></a>
### version

#### Synopsis

`store version`

#### Arguments and options

No arguments; a store need not be open.

#### Results

Returns `sqlite3_libversion()` text for the statically linked SQLite library.

#### Errors

Only wrong arity is expected.

#### Lifetime and timeouts

Pure constant query.

#### Examples

`puts "SQLite [store version]"`

#### Constraints

This identifies the library, not a database file format revision.

#### See also

`machteld/command/version`.

## See also

`machteld/command/json`, `machteld/guide/contract`.
