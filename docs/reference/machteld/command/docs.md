---
id: machteld/command/docs
type: command
title: docs
summary: Query, search, inspect, and safely extract the complete reference embedded in the executable.
commands: docs, docs status, docs schema, docs verify, docs list, docs get, docs outline, docs search, docs extract
---

# docs

`docs` is the stable agent-oriented interface to the exact Machteld, Tcl 9, and
Tk 9 reference corpus carried by the running executable. It never consults the
network or a machine-wide documentation installation.

## Synopsis

```tcl
docs status
docs schema
docs verify
docs list ?-scope scope? ?-type type? ?-offset n? ?-limit n?
docs get id ?-section slug? ?-format markdown|html|source? \
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
`--output FILE` atomically writes that same envelope or human result; GUI hosts
require output except for extraction.

## Arguments and options

- Stable `id` values are namespace-like paths such as `machteld/command/run`,
  `tcl/command/dict`, and `tk/command/bind`. A fragment such as
  `machteld/command/child#wait` selects a subcommand/section. Alias lookup
  lowercases, trims, and collapses whitespace; a canonical ID always wins.
  The compact bootstrap/index IDs are `machteld/agent` and `machteld/index`;
  each product also has a stable two-part `product/license` ID.
- `-scope` is the exact product `machteld`, `tcl`, or `tk`; empty or `all` means
  unfiltered. `-type` matches an exact catalog type such as `command`, `guide`,
  `c-api`, or `application`; empty or `all` is unfiltered.
- For `list` and `search`, `-offset` defaults to `0`; `-limit` defaults to `50`
  and is from `1` through `200` records.
- Search terms contain at least two characters after normalization. Use `get`
  for an exact short command name or stable ID.
- `-section slug` selects one indexed H2/H3 section. `outline` discovers valid
  section slugs.
- `-format` selects `markdown` (default), `html`, or verbatim upstream `source`.
  A representation not carried for that document reports `DOCS unsupported`.
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
- `extract`: normalized output `path`, `files`, `bytes`, and `corpus_sha256`.

`next` is the next offset or empty when complete. Corpus and page SHA-256 values
identify the packaged provenance and detect inconsistency; they are not a
separately authenticated signature.

## Errors

Raised codes are `DOCS ambiguous`, `DOCS badvalue`, `DOCS corrupt`,
`DOCS exists`, `DOCS notfound`, `DOCS oserror`, `DOCS unsupported`, and
`DOCS usage`.
`ambiguous` identifies an alias with multiple exact candidates; its message
lists the canonical IDs so callers can choose rather than accept a guess.
`unsupported` also covers requesting a representation that document does not
carry.
`corrupt` means packaged catalog/content/hash invariants failed; results are not
silently returned from a mismatched corpus.

## Lifetime and timeouts

Status, schema, verify, list, get, outline, and search read the immutable
self-mounted zipfs payload and retain no handles. Search is local and bounded.
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

# Inspect upstream Tcl source notation where required.
set source [docs get tcl/command/dict -format source]

# Export once for rg, indexing, or offline audit.
set exported [docs extract C:/work/machteld-reference]
```

## Constraints

Normalized Markdown is the default agent representation; source pages preserve
upstream Tcl/Tk manpage syntax and may be roff. Search ranks the packaged
corpus, not external tutorials or later language releases. Query the executable
first instead of relying on web memory: it knows the exact API and Tcl/Tk
versions it actually runs.

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

Validates packaged state locally and retains nothing.

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

Returns `schema 1`, `catalog_schema 1`, command/subcommand grammar, identifier
rules, pagination rules, supported content representations and host output
formats, and the structured `{MACHTELD DOCS code}` error pattern.

#### Errors

Missing or malformed packaged API metadata reports `unsupported` or `corrupt`.

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

Validates the strict full-pack manifest and exact file set, then recomputes
cataloged representation hashes, byte sizes, and corpus identity. It returns
`ok 1`, document/file/byte counts, and `corpus_sha256`.

#### Errors

Any missing, mismatched, or malformed content reports `DOCS corrupt`.

#### Lifetime and timeouts

Reads the complete local corpus synchronously and retains nothing.

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

`docs get id ?-section slug? ?-format markdown|html|source? ?-offset n?
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

One local read with no retained state.

#### Examples

`dict get [docs get tcl/command/dict -section synopsis -all 1] text`

#### Constraints

Different representations have different hashes and byte counts. Follow
`next` until empty unless `-all` was intentionally requested.

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

`query` is text; filters and pagination match `list`. Every normalized search
term must contain at least two characters. Exact shorter names belong in `get`.

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

Returns published path, file/byte counts, and corpus hash.

#### Errors

Unsafe/existing target reports `exists` or `badvalue`; staging/publish failures
report `oserror`; damaged source reports `corrupt`.

#### Lifetime and timeouts

Stages under a random sibling name, verifies the complete tree, then publishes
it with one same-volume rename.

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
