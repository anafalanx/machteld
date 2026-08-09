---
type: plan
title: The standard library
description: What machteld's scripting surface has, what it categorically lacks, and the order in which to close the gaps.
tags: [machteld, stdlib, plan]
timestamp: 2026-08-09
---

# The standard library

machteld's **palette** is 15 verbs of machine control. That half is not the problem — it is
already stronger than `subprocess`, `os/exec` or anything Deno ships. The other half is Tcl 9's
own library, which is excellent at strings, lists, dicts, `clock`, `file` and channels, and has
a small number of holes that are **categorical** rather than cosmetic.

**The asymmetry is the asset.** Process control is where machteld beats every comparable
runtime. The purpose of this plan is to remove the embarrassments, not to chase parity — nothing
here should be built by trading away depth in supervision for breadth nobody asked for.

## Where the gaps actually are

Assessed per [rule 5](direction.md): from the domain first, from what comparable standard
libraries settled on second, and from existing tools only as a tiebreak.

| Category | Python | Go | Deno | Tcl 9 + machteld |
|---|---|---|---|---|
| strings / text | `string`, `re`, `textwrap` | `strings`, `regexp`, `tabwriter` | `text`, `fmt` | ✅ / no wrap, no column alignment |
| collections | `collections`, `itertools` | `sort`, `container` | `collections` | ✅ |
| date & time | `datetime` | `time` | `datetime` | ✅ `clock` |
| math | `math`, `statistics`, `random` | `math`, `math/rand` | `random` | ✅ + bignums / weak random |
| files & paths | `pathlib`, `shutil`, `tempfile` | `os`, `path/filepath` | `fs`, `path` | ✅ incl. `file tempfile` / `tempdir` |
| encodings | `json`, `csv`, `base64` | `encoding/*` | `json`, `csv`, `toml`, `yaml` | `json`, base64 / **no csv, no config format** |
| compression | `zlib`, `zipfile`, `tarfile` | `compress`, `archive` | `tar` | ✅ `zlib`, `zipfs` |
| **crypto / hash** | `hashlib`, `hmac`, `secrets` | `crypto`, `hash` | `crypto` | ❌ **nothing** |
| networking | `socket`, `ssl`, `urllib` | `net`, `net/http`, `crypto/tls` | `http`, `net` | `socket`, `http` / **no TLS** |
| **CLI** | `argparse`, `shlex` | `flag` | `cli` | ❌ **nothing** |
| **logging** | `logging` | `log` | `log` | ❌ **nothing** |
| testing | `unittest` | `testing` | `assert` | ✅ `tcltest` |
| uuid / ids | `uuid` | — | `uuid`, `ulid` | ❌ |
| **process control** | `subprocess` | `os/exec` | — | ✅✅ **ahead of all three** |

Three categories are **empty** and present in every comparison runtime: crypto/hashing, CLI
parsing, logging. Those are the plan.

## What "fits the architecture" means here

Not a style preference — these are the properties that make a new verb indistinguishable from
one that was always there.

1. **Commands and ensembles, never syntax.** [Rule 1](direction.md). Any Tcl program still means
   what it meant.
2. **Dicts in, dicts out.** [The contract](contract.md) holds without exception.
3. **Stateful things get a token, with `info` and `close`** — the `child#N` / `pty#N` /
   `watch#N` lifetime, which the execution model already teaches. An incremental hash is
   stateful, so it is a token; a one-shot digest is a value, so it is not.
4. **Channels are the I/O abstraction.** Anything that streams reads or writes a Tcl channel
   rather than inventing a transport. `zlib push` is the core precedent.
5. **`{MACHTELD DOMAIN code}` on every failure**, reusing the existing code vocabulary
   (`usage`, `badvalue`, `notfound`, `nohandle`, `oserror`, `denied`) and adding a code only
   when it is genuinely a new kind of failure.
6. **Prelude first; C only for what Tcl cannot reach** ([rule 4](direction.md)). Two things here
   need C: the OS crypto provider and the OS HTTP stack. Everything else is Tcl.
7. **One page each** ([rule 3](direction.md)). A verb that needs a subsystem is a different
   project.
8. **Tested, documented, in the manifest, in the same commit** ([rule 8](direction.md)).
9. **Never shadow a Tcl core command.** All names below are verified free. `log` and `rand`
   exist as `expr` mathfuncs only — `expr {log(2)}` and `log info "..."` never meet.

### Two option conventions, on purpose

The palette uses Tcl's `-option value`; the **tools** it stamps use `--option`. That split is
correct and stays: `-timeout 5s` is an argument to a command, `--interval 500` is an argument to
a program, and the audiences differ. `cli` therefore parses `--option`, while every palette verb
keeps `-option`.

## Phase 0 — make the prelude a first-class citizen — ✅ **done 2026-08-09**

**Prerequisite, not housekeeping.** Everything in Phase 1–3 that is not C lands in the prelude,
and the prelude was the one part of machteld that did not hold itself to machteld's contract:

- **11 bare `return -code error`** with no `-errorcode` at all, in `wrap` and `help` — outside
  the error registry entirely, nothing to document and nothing a scan could find. Adding four or
  five more Tcl verbs would have made the uncoded error the *norm* rather than the exception.
- **The manifest's Tcl half stopped at** `kind tcl` plus `info args`: no domain, no codes, no
  options. That covered 6 of 15 verbs, and after this plan it would have covered roughly half the
  palette — so [creed](creed.md) 4 would have decayed in exact proportion to how much standard
  library got added.

So: code the prelude's errors, teach the manifest to describe Tcl verbs as fully as it describes
C ones, and gate both. Doing this after the fact means retrofitting five verbs instead of two.

**Done.** All eleven uncoded errors now raise through `Fail domain code msg`, the prelude's
mirror of the C's `mt_error`; `WRAP` and `HELP` joined the domain table and `timeout` and
`unsupported` the code registry. The manifest reads `info body` for a Tcl verb's domain, codes
and options, follows a shared helper told its caller's domain, and merges the facts of a Tcl
subcommand sitting behind a C verb — so `pty` now declares the `timeout` that `pty expect` really
raises. Both are gated, and both gates were broken on purpose to confirm they bite: injecting one
uncoded error fails the suite, and neutering the derivation fails nine checks rather than
silently passing.

## Phase 1 — the three empty categories

### `hash` — C, over CNG (`bcrypt.dll`)

Verified working against the toolchain: `sha256("abc")` returns `ba7816bf8f01cfea…`. No
vendoring, no OpenSSL — the provider is already on the machine.

```tcl
hash sha256 $data                  ;# hex digest of a value
hash sha256 -file big.iso          ;# streams; constant memory
hash hmac sha256 -key $k $data
hash random 32                     ;# cryptographically secure bytes

set h [hash start sha256]          ;# hash#1 -- stateful, so it is a token
hash update $h $chunk
hash final $h                      ;# digest, and the token is gone
hash list                          ;# open contexts, like child/pty/watch
```

Fixes `random` at the same time: today the only source is `expr {rand()}`, which is a PRNG and
not suitable for anything that needs to be unguessable.

### `cli` — Tcl

machteld is a **tool factory**, so every program it stamps needs argument parsing. A declarative
spec yields a dict, generates `--help`, and raises `{MACHTELD CLI usage}` on bad input.

```tcl
set opt [cli parse $argv {
    {--interval  int   2000  "refresh interval in milliseconds"}
    {--all       flag  0     "show everything, no filtering"}
    {--          arg   ""    "directory to watch"}
}]
dict get $opt interval
```

`cli help $spec` renders the usage block, so `--help` and the error text come from one
declaration rather than from prose somebody has to remember to update — the same reasoning that
made the manifest derived rather than hand-written.

### `log` — Tcl

Unattended execution is machteld's premise, and a `detach`'d daemon currently has nowhere to
write.

```tcl
log configure -level info -file app.log   ;# or -channel stderr
log info  "watching $dir"
log warn  "queue at 90%"
log error "cannot open $path"
```

Writes to a Tcl channel, so it composes with everything channels already do.

## Phase 2 — reach

### `fetch` — C, over WinHTTP

Verified: `GET https://example.com/` returns HTTP 200 with TLS through Schannel. Tcl's `http`
package loads but cannot do https, which in 2026 means it cannot fetch anything.

```tcl
fetch get $url                          ;# {status 200 headers {...} body {...}}
fetch get $url -timeout 10s -headers {Accept application/json}
fetch post $url -body $payload -type application/json
fetch download $url -to file.zip        ;# streams to disk
```

### `csv` — Tcl

Deliberately the same shape as `json`, because the shape is the point:

```tcl
csv decode $text ?-header?    ;# list of lists, or list of dicts with -header
csv encode $rows
```

The quoting rules are exactly what hand-rolled CSV gets wrong.

## Phase 3 — completeness

- **`uuid`** — v4 over `hash random`, three lines of Tcl once Phase 1 exists.
- **Text helpers** — wrapping and column alignment (`textwrap`, `text/tabwriter`, `fmt` all
  exist for a reason). Small, and genuinely used by every command-line tool.

## Deliberately not planned

- **Threads.** `Thread` does not load and should stay that way. machteld's parallelism is
  process-level — `child start` plus `wait -any` — which suits machine control better than
  shared memory, and threads underneath Tk are a known source of pain.
- **A config format.** TOML/YAML/INI are all defensible and none is obviously right here; `json`
  plus Tcl dicts cover most of it. Revisit when something concrete is being configured.
- **XML / HTML parsing.** Out of domain.
- **A `util` grab-bag.** [Rule 3](direction.md) is the filter: each verb earns its page or it
  does not go in.

## Sequencing

**One at a time, finished before the next** ([rule 7](direction.md)): tested, documented, errors
registered, in the manifest. The failure this plan is most exposed to is not picking the wrong
verb — it is having five of them half-built at once.

Phase 0 first, because it decides whether the rest arrives as first-class palette or as a pile
of prelude procs that nothing can describe.
