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

**5. Build to find out. Speculation is allowed; unexamined accumulation is not.**
*Rewritten 2026-08-09; the demand-first version is retired.* It read "each domain gets built
when a tool reaches for it", and it produced good practical design — `watch` and `ps` both
arrived that way and both are better for it. It was also wrong often enough to matter. It
forbids exploring, and exploring is how you find out what a verb's dict should look like; it
also refuses the thing a personal toolkit is *for*. Twice it was softened and twice it bit
again, which is a rule failing rather than a user misreading it.

A power may now be built because it is interesting, because you expect to need it, or because
you want to see what it feels like. **What replaces the gate is not a lighter gate but a
different discipline: keep the cost of being wrong low.** Rules 3, 6 and 8 already do most of
that — one page, self-describing, tested and documented on arrival — so a speculative verb is
cheap to *keep*. What was missing is that it must also be cheap to *drop*, which rule 7 made
impossible by freezing a shape the moment it shipped. Hence the amendment there.

The one thing that does not relax: a verb built on spec is still a verb, so it arrives with its
tests, its docs, its error codes and its manifest entry like everything else. Exploration is not
a licence to ship something unfinished — it is a licence to ship something *unneeded*.

**Review, not permission.** A provisional verb still unused after a while is not a failure; it
is a question. Answer it deliberately — keep it, reshape it, or take it out — rather than letting
it sit and calling that a decision.

**The domains are unchanged in substance:** `reg`, `svc`, `evt` and the `net`/`host`/`user`/`wmi`
group are all wanted, our own C for each, and **TWAPI stays a quarry** opened only for WMI/COM
([ecosystem policy](ecosystem-policy.md)). They are simply no longer gated behind a tool asking
first. Building one to see what its dict wants to be is now a legitimate reason to build it.

**6. Everything answers as a dict, fails with an errorcode, and describes itself.** The
[contract](contract.md) holds for every new verb without exception — and **the manifest gets
built** in this stretch, because [creed](creed.md) 4 is the one principle currently carried by
hand. Once the manifest exists, the docs test stops comparing prose to code and starts
comparing the runtime's own self-description to both.

**7. Pre-1.0.0 nothing is frozen — that is what 0.x means. Finish what you start.**
*Rewritten 2026-08-09, replacing both the original and its first amendment.* The rule used to
say a verb's shape was fixed the moment it shipped; the amendment moved the freeze to first
*use* and invented a "provisional" category beside it. Both were machinery for a promise the
version number says is not being made. `0.3.0` already declares that the surface may change;
claiming a freeze on top of that asserted something stricter than the project actually offers,
and made every experiment permanent on arrival.

**The surface is settling, not settled.** [Creed](creed.md) 6 — *orthogonal, frozen,
additive-only* — is the promise **1.0.0** makes, and cutting 1.0.0 is precisely the act of
deciding this is a surface worth living with. Until then a name, an option, a dict key or a code
may change. Recorded when it does, because "not frozen" is not "not accountable": the manifest,
[the contract](contract.md) and the gates keep telling the truth about the shape whatever the
shape currently is.

**What binds instead, and binds hard: finish what you start.** The real hazard before 1.0.0 is
not a shape that changes — it is a drift of half-built things nobody will ever go back to. So
the discipline is disposal, not preservation. A verb is **finished** — tested, documented, errors
registered, in the manifest, and actually good at its job — or it is **out**. Something that
half-works stays only while there is a live intention to finish it. "Shelved with a known
defect" is a decision to revisit soon, not a resting state, and a shelf that accumulates is the
failure this rule exists to prevent.

This is the counterweight rule 5 needs. Permission to build on spec is safe only if unbuilding
is normal, and unbuilding is normal only if nothing was frozen on arrival.

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
the contract; it grows by addition, and under the rewritten rule 7 it is **settling rather than
frozen** until 1.0.0.

**One hole in "additive-only", found by measurement and recorded rather than papered over.**
`Tcl_GetIndexFromObj` runs with `flags = 0` at proc.c:709, proc.c:1068 and store.c:56, so
subcommands accept unique prefixes: `store k` resolves to `keys` and `child st` to `start`
today. Adding a subcommand that shares a prefix with an existing one therefore *breaks a
spelling that works* — an addition that is not additive. Two honest ways out (switch those
three sites to `TCL_EXACT` and declare abbreviation unsupported, or keep it and treat the
prefix space as part of the eventual 1.0.0 surface), and the choice belongs with the manifest work,
which is what will make the consequences visible. Until then: **new subcommands must not
shorten an existing one's unique prefix.**

### The built palette — ratified as-is

`run` / `child` / `wait` / `scope` / `detach` · `pty` / `expect` / `vtstrip` · `store` ·
`wrap` / `help` / `version`. No changes; the shapes they have today are the shapes they keep.

### The conventions — ratified as-is

- **`run`'s failure split stands.** Structural problems throw; the child's own outcome — exit
  code, timeout, kill — is data in the result dict. Bad shape aborts, bad data is a value. The
  codes are enumerated in [the contract](contract.md)'s registry, which a test holds to the C.

  *Corrected 2026-08-08, hours after this section was written:* the first draft cited
  `{MACHTELD RUN notfound}` for a missing program, taken from the docs without checking the
  source. The code actually threw `launch` from `run`, `child start` and `pty spawn`, and
  `notfound` only from `detach` — the same condition, the same message, two codes. Ratifying a
  documented claim without executing it is exactly the failure creed 4 exists to prevent, and
  it happened inside the act of freezing the surface. The C is fixed and the split is now
  uniform; `notfound` means an unresolvable program everywhere, and a dead handle — a genuinely
  different failure that used to share the code — is `nohandle`.
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
- ~~**On encode, ambiguity resolves to array.**~~ **Superseded at implementation, 2026-08-09,
  and the reason matters more than the change.** That rule assumed encode would decide structure
  by asking whether the *text* parses as a list. Building it showed what that costs: in Tcl every
  string containing a space parses as a list, so `hello world` would have encoded as
  `["hello","world"]` — the postcode rule one level up, and worse, because it corrupts ordinary
  prose rather than an unusual number. The first test to fail was exactly this.

  Encode now reads structure from **what the value is** — a dict object is an object, a list
  object is an array, anything else is a scalar — with `-dict` and `-list` to force an untyped
  value. The ambiguity the ratified rule was answering mostly *disappears*: `json decode` builds
  real dict and list objects, so a document round-trips byte-for-byte with no hint at all, and
  `dict create` / `list` do the same for one built by hand. The honest cost, documented in the
  contract: Tcl converts representations on demand, so calling `llength` on a plain string can
  leave it a list object and change how it encodes. Say `-dict` or `-list` when it matters.
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

## After 0.3.0 — `ps`, on demand (2026-08-09)

The second tool was a **task manager**, and it did exactly what rule 5 predicts a tool should do:
it named a capability that was missing. machteld could supervise processes it *started* and had
no view of one it had not — `child list` returns its own tokens and nothing else. So **`ps`**
(`list` / `info` / `kill ?-tree?`) was built to fit the tool, not speculated first.

Three shape decisions, each following an existing precedent rather than inventing one:

1. **`cpu` is cumulative milliseconds, not a percentage.** A rate needs two samples and a clock;
   putting it in the verb means hidden state and an answer that depends on when you last asked.
   The verb reports, the caller divides — the same reasoning that made `watch` coalesce per read
   rather than on a timer (creed 3).
2. **A process you cannot open is a row, not an error.** It keeps its snapshot fields, gets
   `access 0`, and every unreadable field is the **empty string** rather than `0` — so "denied"
   never reads as "using no memory". Half the processes on a non-elevated desktop are in this
   state; failing the listing over them would make the verb useless where it is needed.
3. **`ps kill -tree` is best-effort and says so.** It walks one snapshot. For a tree machteld
   started, `child kill` remains exact, because the job object holds the tree by identity rather
   than by pid. The palette documents the difference instead of blurring it.

`denied` joins the registry as the one code that reports a permission, confined to `ps` because
`ps` is the one verb that reaches outside machteld's own children.

## The cockpit — built, measured, removed (2026-08-09)

`mt` was a live window over the current session. It is **gone**, in the same day it arrived, and
the sequence is worth keeping because it is rule 7 working rather than rule 7 being ignored.

Measurement killed it: 8 refreshes per second idle, **0** while blocked in `child wait`
(2039 ms) or `watch read` (1504 ms). Those blocking calls are what supervision is made of, so the
window was live exactly when nothing was happening and frozen exactly when something was — and
while frozen it showed stale rows with no indication, the same defect fixed in `tasks` hours
earlier and reproduced here in another form.

It was shelved first, with the defect documented. That was the wrong call: "shelved with a known
defect" is how a drift of half-built things starts, which is precisely what rule 7 now forbids.
With no live intention to finish it, *finished or out* resolves to out. Removed the same day the
rule was written, so the first thing the rule touched was not exempted from it.

**What stays, because it was finished and is independently worth having:** `watch info` and
`pty info`. `child` already had `info`; the other two handle verbs returned bare tokens, so a
watch could not be attributed to a directory. Non-destructive observation is the right primitive
with or without a window on top of it.

**What was learned and is worth more than the window:** handle state is per-interpreter —
`proc_ctx` is allocated per interpreter and passed to each command as its client data, with no
global registry — so *any* cross-session monitor is impossible without machteld processes
publishing state. A read/write cockpit that owns its own event loop remains the only shape that
could work. `tcl/mt.tcl` is in the history at `98bc96e` if that is ever built.

## Shipping tools inside the exe — refused, with one exception that is not one (2026-08-09)

**Bundling wrapped GUI tools into `machteld.exe` is refused.** Argued three ways and attacked by
nine critics; every affirmative case failed. `argv[1]` is fully allocated by `Tcl_Main` — non-dash
is a script path, dash is the REPL — so every dispatch spelling either breaks a spelling that
works, which rule 2 already forbids, or depends on the working directory. The claimed benefits
have no receiver: nothing here is signed, nothing is on PATH, and the author wrote both tools
himself. Recorded so it is not relitigated.

**But the question was framed wrongly, and the correction matters more than the answer.** The
argument was about packaging *programs*; machteld already ships *code* — the prelude — and a third
of the palette is written in it. So the real question is not "may the exe contain tools" but
**"may the palette contain applications"**, which is a question about identity rather than
mechanics.

`mt` looked like it might settle that question and did not, because it never posed it: handle
state is per-interpreter, so a cockpit over the current session **cannot** be a separate exe — it
would enumerate its own children, which is nothing. It would have shipped as Tcl for lack of an
alternative rather than as a choice, and then it was removed anyway. The identity question stays
open for the first tool that could genuinely go either way.
