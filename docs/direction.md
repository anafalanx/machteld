---
type: policy
title: Direction — the rules for this stretch
description: The goal machteld is being built toward now, the eight rules that govern how it grows, and the candidate powers awaiting decision.
tags: [machteld, direction, rules, goals, superset]
timestamp: 2026-08-08
---

# Direction — the rules for this stretch

Decided 2026-08-08, after a full state study. [The creed](creed.md) is permanent; this is the
operating policy for the current stretch, and it can be revised when the goal changes.

## The goal

**Harden the platform, and grow machteld into a superset of Tcl** — more power at the palette,
without becoming a language project. The machine-control domains build out proactively rather
than on demand, and powers from other languages (Raku, Moose, and their kin) are fair game
where they can be had for a page of Tcl or a small C verb.

The brake, stated as plainly as the goal: **don't go overboard on capability.** A power may be
added because you *know* a tool will want it — foresight is allowed, and waiting for the tool
to exist first would be its own kind of waste — but the palette is a means, and a stretch that
never reaches a tool has drifted. Judgement, not a gate.

## The rules

**1. Extend by commands, never by grammar.** This is [creed](creed.md) 7 made operational, and
it is what lets "superset" and "vanilla Tcl" both be true. Tcl's own control structures are
commands, so a superset built from commands and ensembles is *idiomatic*, not a mutation. The
test is exact: **any Tcl program still means what it meant.** No new syntax, no operator
invention, no parser hooks, no `unknown` tricks that change how ordinary code resolves. A
model's Tcl fluency must keep transferring 1:1 — only the palette is new, and the palette is in
the box (`help`).

**2. A borrowed power is admitted on its semantics, never its pedigree or its spelling.** Adopt
what is **one regular mechanism**; refuse what is **silently wrong** or **unpredictable**, no
matter how famous. A feature that makes an existing program mean something different is
refused outright. Where a name collides with Tcl's, rename — spelling is cheap.

**3. One page, or it is out.** A borrowed power must pay for itself in roughly one page of
prelude Tcl or one small C verb. If it needs a subsystem, a second evaluation phase, or a type
system, it belongs to a different project — and this workspace has two of those already. This
is the rule that keeps "superset" from becoming a second language.

**4. Prelude first; C only for what Tcl cannot reach.** The existing split is the rule:
supervision, ConPTY and SQLite are C because they are kernel and library surface; everything
expressible in Tcl stays in Tcl, where it is readable, patchable and testable in the shipped
exe. A power that works in the prelude does not get rewritten in C for speed without a
measurement that says so.

**5. `watch` first; every domain after it is built on demand.** Our own C for each; **TWAPI
stays a quarry** and is opened only for WMI/COM, only when a verb demands it
([ecosystem policy](ecosystem-policy.md)). `watch` comes first because the first real tool
needs it and because file events are the smallest of the set. `reg`, `svc`, `evt` and the
`net`/`host`/`user`/`wmi` group are all wanted and none are scheduled — each gets built when a
tool reaches for it, which is also when its dict shape stops being a guess.

**6. Everything answers as a dict, fails with an errorcode, and describes itself.** The
[contract](contract.md) holds for every new verb without exception — and **the manifest gets
built** in this stretch, because [creed](creed.md) 4 is the one principle currently carried by
hand. Once the manifest exists, the docs test stops comparing prose to code and starts
comparing the runtime's own self-description to both.

**7. Shipped shape is frozen; growth is additive.** A verb's name, options, result dict and
error codes do not change after they ship. Getting the shape right before shipping is
therefore part of the work, not a later pass — see rule 8.

**8. A verb is not built until it is tested and documented in the same commit.** Every new verb
lands with cases in the suite and its entry in [the palette](palette.md); the doc-accuracy test
must cover it. Adversarial cases are part of "tested" for anything touching processes,
handles or the filesystem — the execution core's invariants were established that way and the
standard does not drop for later domains.

**Cross-project rule.** X and drang are paused. **Findings cross over; code does not.** Their
measured facts about this substrate are free to use — and cost nothing to check — but machteld
stays one C+Tcl codebase with no imported machinery.

## Candidate powers — verified feasible, awaiting decision

Probed on the built exe, 2026-08-08: TclOO 1.3.1 and `coroutine` are present; Tcl's ARE has
**no named captures**; the uplevel-plus-cleanup shape that phasers need preserves return
options correctly.

| Candidate | Lands in | Note |
|---|---|---|
| **Phasers** (`LEAVE` / `KEEP` / `UNDO`) | prelude | Generalizes `scope`, which is already this idea for one resource. The orchestration case wants it constantly: start a child and you must kill it. Shape verified. |
| **Lazy sequences** (`gather`/`take`) | prelude | Tcl coroutines make this natural; bounds memory over a long child's output and makes "stop early" cheap. |
| **Signature-derived CLI** | prelude | A wrapped tool's entry declares its parameters once and gets argv parsing *and* `--help` from them. Fits the [tool factory](packaging.md) exactly. |
| **Shapes** (`where`-constrained validation) | prelude | Declare a dict's shape once, check it at every boundary; composes with the manifest. |

**Refused, on rule 2**, so they are not relitigated: junctions and any autothreading operator;
implicit-lambda stars; user-defined operators (every program becomes its own dialect); multiple
dispatch (turns a wrong call into "no candidate matched"); anything requiring a second
evaluation phase or mutable grammar.

**Settled out, 2026-08-08.** *Named-capture matches* — **we settle for Tcl's regexes as they
are.** ARE has no named groups, and a rewriter that translates `(?<name>…)` into numbered
groups would be a private regex dialect living inside the palette: patterns that work in
machteld and nowhere else, which is rule 1's failure mode wearing a library's clothes. Group
positions are Tcl's answer and they are a fine one. *An object layer over TclOO* — deferred
past this stretch, not refused; TclOO is there when a tool wants it.

## Ratified, 2026-08-08

The whole surface was put back on the table and taken decision by decision. What follows is
the contract; **it is frozen from here** and grows only by addition (rule 7, now literal).

### The built palette — ratified as-is

`run` / `child` / `wait` / `scope` / `detach` · `pty` / `expect` / `vtstrip` · `store` ·
`wrap` / `help` / `version`. No changes; the shapes they have today are the shapes they keep.

### The conventions — ratified as-is

- **`run`'s failure split stands.** Structural problems throw (`{MACHTELD RUN notfound}`); the
  child's own outcome — exit code, timeout, kill — is data in the result dict. Bad shape
  aborts, bad data is a value.
- **Durations keep rejecting bare numbers.** `-timeout 100` is an error, forever. One or two
  characters per call site buys a whole class of thousand-fold mistakes never happening.
- **Bare verbs stay on the global namespace path.** Scripts read like shell, which is the
  ergonomic point; Tcl's own commands still resolve first.

### The self-description machinery

- **The manifest is built first, before `watch`** — the mechanism before the instances, so
  every new verb declares itself once instead of being retrofitted N times later.
- **Error codes become a closed, documented, tested registry.** Every `{MACHTELD DOMAIN code}`
  is enumerated in one place and a test fails if C can throw a code the registry does not
  name. This is what makes trap-by-code safe to rely on, which is the entire point of
  structured errors.
- These two converge on one mechanism: a verb declares its options **and** its error codes in
  the manifest, and the completeness test walks the manifest rather than a hand-kept list.
  Creed 4 and creed 5, satisfied by the same machinery.

### `json` — the one real gap in the contract

The contract says everything is a dict and dicts are JSON-isomorphic; Tcl 9 core has no JSON;
agents speak JSON. So it is built — **in C, hand-rolled straight into `Tcl_Obj`**, no
intermediate DOM. yyjson is read as a *teacher* for the edges it gets right (surrogate pairs,
number precision, escapes) but not vendored: the ecosystem policy's gate is "can I own this
snapshot", and the guarantee comes from vendoring **[JSONTestSuite](https://github.com/nst/JSONTestSuite)**
as a gate rather than trusting someone else's parser. A depth limit is explicit, not implied.

The mapping is the hard part, not the parsing, because Tcl has no type tags:

- **Lossy by default, exact with a shape.** `null` → `""`, `true` → `1`, `false` → `0`,
  documented precisely. Pass a shape and decode/encode become exact — which is why `json` and
  **shapes** are one design, not two.
- **On encode, ambiguity resolves to array.** A Tcl value that is both a valid list and a valid
  dict — `{}` above all — emits `[]`; `-dict` or a shape forces an object. The ambiguity is
  real and unavoidable (a two-element list *is* a one-key dict), so it is answered once, in the
  open, rather than guessed per call.
- **Surface is `encode` / `decode`.** Two operations, whole documents; Tcl's own `dict get`
  walks the result.

### `watch` — the shape

- **Handle + blocking read**: `set w [watch start $dir]`, `watch read $w -timeout 5s`. Mirrors
  `child start` / `wait` exactly, so the palette has one lifetime model and needs no event loop.
- **One multiplexer.** A watch handle is waitable by the existing `wait`, so
  `wait -any $child $watch` works — creed 6's orthogonality actually cashed in, and a tool can
  block on "either the build finishes or a file changed" without polling.
- **Coalesced by default, `-raw` on request.** One editor save is one event; the unfiltered
  stream stays reachable for anything that needs it.

### Prelude powers — in, when the tool reaches them

**Signature-derived CLI** and **shapes** are both admitted. They land at the moment the viewer
wants them, not before — powers stay tied to a use, which is what rule 5 protects.

### The name

**machteld, ratified.** No longer provisional. *Drang in toom houden* — the meaning fits, the
docs are written around it, and the cost of the question only rises.

## The stretch, and what 0.3.0 is

**Manifest → `watch` (+ `wait` multiplexing) → the change-viewer**, pulling in `json`,
signature-CLI and shapes at the moment the tool reaches for them.

The first tool is the **live change-viewer**: a running list of paths as they change, click one
to see its current contents — the roadmap's own choice, needing only `watch` plus file reads,
so it proves the verb without dragging in a diff engine.

**0.3.0 ships when the tool ships.** Rule 5, made literal: a version is cut when the palette
has reached a tool, not when the palette merely grew.

The remaining domains — `reg`, `svc`, `evt`, and the `net`/`host`/`user`/`wmi` group — are all
wanted and none are scheduled. They get built **after the first tool, on demand**: that is also
when you learn what each one's dict should look like.
