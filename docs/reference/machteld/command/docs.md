---
id: machteld/command/docs
type: command
title: docs
summary: Query, search, inspect, and safely extract the complete reference embedded in the executable.
commands: docs, docs status, docs schema, docs verify, docs list, docs get, docs outline, docs search, docs extract
---

# docs

`docs` is the stable agent-oriented interface to the Machteld, Tcl 9, Tk 9
and cffi reference corpus carried by the running executable. It never consults the
network or a machine-wide documentation installation.

The reference resides in the shared runtime. A script or archive can query
it without carrying another copy.

## Synopsis

```tcl
docs status
docs schema
docs verify
docs list ?-scope scope? ?-type type? ?-offset n? ?-limit n?
docs get id ?-section slug? ?-format markdown? \
    ?-offset n? ?-limit n? ?-all boolean?
docs outline id
docs search query ?-scope scope? ?-type type? ?-offset n? ?-limit n?
docs extract directory
```

The distribution host also exposes these operations before entry evaluation:

```text
machteld.exe --docs status --json
machteld.exe --docs get tcl/command/dict --section examples --json
machteld.exe --docs search "channel binary encoding" --limit 10 --json
machteld.exe --docs extract C:\reference
```

Host options use double hyphens. `--json` always emits a stable envelope:
successful replies are `{ok true result ...}` and failures are
`{ok false error {domain DOCS code ... message ...}}`, rendered as JSON objects.
`--output FILE` atomically writes the same JSON envelope or human-readable result to a file.

Put the host option before an application name. Arguments following the
archive name are passed to its entry.

## Arguments and options

- Stable `id` values are namespace-like paths such as `machteld/command/run`,
  `tcl/command/dict`, and `tk/command/bind`. A fragment such as
  `machteld/command/child#wait` selects a subcommand/section. Alias lookup
  lowercases, trims, and collapses whitespace; a canonical ID always wins.
  The compact bootstrap/index IDs are `machteld/agent` and `machteld/index`;
  each product also has a stable two-part `product/license` ID.
- `-scope` is the exact product `machteld`, `tcl`, `tk` or `cffi`. Empty or `all` means
  unfiltered. `-type` matches an exact catalog type such as `command`, `package`, `guide`,
  `c-api`, or `application`; empty or `all` is unfiltered.
- For `list` and `search`, `-offset` defaults to `0`; `-limit` defaults to `50`
  and is from `1` through `200` records.
- Search accepts up to 64 words and matches token prefixes. Exact aliases rank first.
  Use `get` to retrieve an exact short command name or stable ID.
- `-section slug` selects one indexed H2/H3 section. `outline` discovers valid
  section slugs.
- Schema 2 returns Markdown. The former `html` and `source` formats report `DOCS unsupported`.
- Get offset defaults to 0 characters and limit to 32,768, with a maximum of
  1,048,576 and a minimum of 1. `-all 1` forbids offset/limit and retrieves the
  complete selected content intentionally. Booleans are strictly `0` or `1`.
- `get` pages text by character offset and limit by default so one request never
  silently dumps an enormous page. Follow `next`, request a section, or use
  explicit `-all` when the complete page is genuinely required.
- `extract` requires a nonexistent destination and never replaces an existing
  path. Do not concurrently mutate its output parent while extraction runs.

## Results

All Tcl subcommands return dicts.

- `status`: `schema`, `generator`, `machteld`, `root`, `corpus_sha256`, `products`,
  `documents`, `aliases`, `fragments`, and `formats`. Each product reports
  `version`, total catalog `documents`, and non-license `manual_pages`.
- `list`/`search`: `items`, `total`, `offset`, `limit`, `returned`, `truncated`,
  and `next`. Each item includes `id`, `product`, `version`, `type`, `title`,
  `summary`, `names`, and `sections`.
- `schema`: documentation API/catalog schema, subcommand grammar, identifier and
  pagination rules, formats, and structured error-code shape.
- `verify`: `ok`, verified `documents`, `files`, `bytes`, and `corpus_sha256`.
- `get`: `id`, `requested_id`, `product`, `version`, `type`, `title`, `summary`,
  `names`, `format`, `section`, `path`, `sha256`, `bytes`, `text`, `total`,
  `returned`, `truncated`, and `next`.
- `outline`: exact `id`, `title`, and indexed `sections`.
- `extract` returns the normalized directory `path`, `files 1`, `bytes` and
  `corpus_sha256`. The directory contains exactly `reference.db`.

`next` is the next offset or empty when complete. Corpus and page SHA-256 values
identify the packaged provenance and detect inconsistency; they are not a
separately authenticated signature.

## Errors

Raised codes are `DOCS ambiguous`, `DOCS badvalue`, `DOCS corrupt`,
`DOCS exists`, `DOCS notfound`, `DOCS oserror`, `DOCS unsupported`, and
`DOCS usage`.
`ambiguous` identifies an alias with multiple exact candidates; its message
lists the canonical IDs so callers can choose rather than accept a guess.
`unsupported` covers requesting a representation that a document does not carry. It does
not mean the runtime's commands or its license notices were omitted.
`corrupt` means packaged catalog/content/hash invariants failed; results are not
silently returned from a mismatched corpus.

## Lifetime and timeouts

Schema returns local API metadata without needing the reference pack. Status,
verify, list, get, outline, and search open an in-memory, read-only SQLite database
on first use. Each interpreter owns its connection. Search uses the embedded FTS5 index.
Extraction stages a complete randomly named sibling directory and publishes it
by same-volume rename, so an incomplete tree is never presented as success.
Cleanup after an interrupted extraction is best effort. There is no network or
timeout option.

## Examples

```tcl
# Discover exact versions and integrity.
set state [docs status]

# Prefer exact IDs, then retrieve only the section needed.
set matches [docs search {process lifetime deadline} -scope machteld -limit 5]
set page [docs get machteld/command/child -section lifetime-and-timeouts]
puts [dict get $page text]

# Export exactly one page as Markdown.
# Run from a shell: machteld.exe docs get tcl/command/dict --all 1 --output dict.md

# Export the searchable database and look up a license from its Markdown rows.
set exported [docs extract C:/work/machteld-reference]
package require sqlite3
sqlite3 corpus [file join [dict get $exported path] reference.db] -readonly 1 -create 0
try {
    puts [corpus onecolumn {SELECT body FROM page WHERE id = 'machteld/license'}]
    set query {worker}
    puts [corpus eval {
        SELECT p.id FROM search JOIN page AS p ON p.rowid = search.rowid
        WHERE search MATCH $query AND p.product = 'machteld'
        ORDER BY bm25(search), p.id LIMIT 5
    }]
} finally {corpus close}
```

## Constraints

Each page is stored once as Markdown. The extracted `reference.db` includes the
pinned Tcl, Tk and cffi manuals, section offsets, aliases, and source-specific
attributions in the `notice` table. The build cache retains the original archives.
Package-version equality alone is insufficient when comparing artifacts:
different builds can share one version. Record artifact and corpus hashes, plus
the development build identity when present, not only `version`, when comparing
references. A corpus hash identifies documentation bytes, not a signature or
proof that two native executables are identical. The older signed release's own
reference describes that release, not this one.

## Subcommands

<a id="status"></a>
### status

#### Synopsis

`docs status`

#### Arguments and options

Takes no arguments.

#### Results

Returns schema/runtime versions, corpus identity, per-product inventories,
counts, and available formats.

#### Errors

Missing/damaged catalog reports `unsupported` or `corrupt`.

#### Lifetime and timeouts

The first call opens the reference database. Later calls reuse that interpreter's read-only connection.

#### Examples

`dict get [docs status] products`

#### Constraints

Use returned versions and hash when reporting provenance.

#### See also

`machteld/command/version`.

<a id="list"></a>
### list

#### Synopsis

`docs list ?-scope scope? ?-type type? ?-offset n? ?-limit n?`

#### Arguments and options

Filters are exact; offset is nonnegative and record limit is 1 through 200.

#### Results

Returns a bounded catalog page and pagination facts.

#### Errors

Invalid scope/type/range/options report `DOCS badvalue` or `usage`.

#### Lifetime and timeouts

Immediate catalog query.

#### Examples

`docs list -scope tcl -type command -limit 25`

#### Constraints

Follow `next` until empty rather than assuming one page is the corpus.

#### See also

`machteld/command/docs#search`.

<a id="schema"></a>
### schema

#### Synopsis

`docs schema`

#### Arguments and options

Takes no arguments.

#### Results

Returns `schema 2`, `catalog_schema 2`, command/subcommand grammar, identifier
rules, pagination rules, supported content representations and host output
formats, and the structured `{MACHTELD DOCS code}` error pattern.

#### Errors

Malformed calls report `DOCS usage`. This query does not require the reference
pack and remains available when content cannot be read.

#### Lifetime and timeouts

Pure local metadata query.

#### Examples

`dict get [docs schema] subcommands`

#### Constraints

Agents should inspect this instead of inferring a response schema from prose.

#### See also

`machteld/command/docs#status`.

<a id="verify"></a>
### verify

#### Synopsis

`docs verify`

#### Arguments and options

Takes no arguments.

#### Results

Recomputes the SHA-256 of `reference.db`, compares it with the embedded
digest, and runs SQLite integrity and foreign-key checks. It returns `ok 1`,
`documents`, `files 1`, `bytes` and `corpus_sha256`.

#### Errors

An omitted reference pack reports `DOCS unsupported`. Missing, mismatched, or
malformed content within a reference pack reports `DOCS corrupt`.

#### Lifetime and timeouts

Reads the database synchronously and reuses its read-only connection.

#### Examples

`if {![dict get [docs verify] ok]} { error "unreachable" }`

#### Constraints

Verification is deliberately more expensive than `status`; use it for audit or
diagnosis, not before every page lookup.

#### See also

`machteld/command/docs#status`.

<a id="get"></a>
### get

#### Synopsis

`docs get id ?-section slug? ?-format markdown? ?-offset n?
?-limit n? ?-all 0|1?`

#### Arguments and options

Exact IDs and aliases are accepted. An ID fragment selects a section; do not
combine contradictory fragment and `-section` selectors. Content is sliced by
Unicode characters after section selection. Defaults are offset 0 and limit
32,768; limit is 1 through 1,048,576. `-all 1` is the explicit unbounded
retrieval choice and cannot be combined with offset/limit.

#### Results

Returns metadata, hash, byte count, requested text, and pagination facts in one
dict.

#### Errors

Unknown ID/section is `notfound`; a non-unique alias is `ambiguous`; unavailable
representation is `unsupported`; hash/content mismatch is `corrupt`.

#### Lifetime and timeouts

Reads from the interpreter's reference connection.

#### Examples

`dict get [docs get tcl/command/dict -section synopsis -all 1] text`

#### Constraints

The page hash and byte count describe the complete Markdown page. Follow
`next` to read successive character ranges.

#### See also

`machteld/command/docs#outline`.

<a id="outline"></a>
### outline

#### Synopsis

`docs outline id`

#### Arguments and options

Takes one exact ID or alias.

#### Results

Returns canonical ID, title, and available section slugs/headings.

#### Errors

Unknown document reports `DOCS notfound`.

#### Lifetime and timeouts

Catalog-only query.

#### Examples

`docs outline machteld/command/child`

#### Constraints

Section slugs are document-local; request them with the canonical ID.

#### See also

`machteld/command/docs#get`.

<a id="search"></a>
### search

#### Synopsis

`docs search query ?-scope scope? ?-type type? ?-offset n? ?-limit n?`

#### Arguments and options

`query` accepts up to 4,096 Tcl characters containing 1 through 64 alphanumeric
terms. Each term matches a token prefix. All terms must match. Filters and
pagination follow `list`.

#### Results

Returns ranked bounded summary items and pagination facts.

#### Errors

Empty/invalid query or filters report `badvalue`; malformed syntax is `usage`.

#### Lifetime and timeouts

Searches the small embedded index synchronously, without network access.

#### Examples

`docs search {job object descendant timeout} -scope machteld -limit 10`

#### Constraints

Use an exact ID with `get` after discovery; search ordering is relevance, not a
stable document enumeration.

#### See also

`machteld/command/docs#list`.

<a id="extract"></a>
### extract

#### Synopsis

`docs extract directory`

#### Arguments and options

The destination must not exist and its parent directory must already exist.
There are no options.

#### Results

Returns the new directory path, `files 1`, the database byte count and its SHA-256.

#### Errors

An existing destination reports `exists`, a missing parent reports `notfound`,
and an unsafe path reports `badvalue`. Staging or publication failures report
`oserror`. Damaged source data reports `corrupt`.

#### Lifetime and timeouts

Stages `reference.db` in a sibling directory, verifies its bytes and publishes
the directory with one same-volume rename.

#### Examples

`docs extract C:/reference`

#### Constraints

Extraction never deletes or replaces the destination. Do not concurrently
replace or mutate entries in the destination's parent while it runs; abandoned
staging cleanup is best effort.

#### See also

`machteld/agent`.

## See also

`machteld/command/help`, `machteld/command/manifest`, `machteld/agent`.
