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
when a tool reaches for it", and it produced good practical design — `watch` and `mtps` both
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

**Review, not permission.** A verb still unused after a while is not a failure; it is a question.
Answer it deliberately — keep it, reshape it, or take it out — rather than letting it sit and
calling that a decision.

**Where the case for a capability comes from, in order.** *Added 2026-08-09, because the retired
demand-first rule kept being reconstructed in new costumes even after it was written out.* The
evidence for building something is, strongest first:

1. **The domain.** What does a Windows machine-control toolkit need in order to be one? This is
   the question that actually decides, and it does not depend on what happens to exist yet.
2. **What comparable standard libraries settled on.** Python, Go, Deno and PowerShell encode
   decades of accumulated evidence from millions of programs. A category present in all of them
   and absent here is a real hole; a category absent from all of them needs a specific argument.
3. **What already-built tools needed** — **a tiebreak at most, never the primary case.**

The third was doing all the work and it produced badly ranked answers. Ranking the standard
library from two Tk tools written the same afternoon put byte-formatting helpers second and
crypto — absent from machteld entirely, present in every comparable stdlib — fourth, because
neither tool happened to hash anything. Two programs of one genre cannot be a sample for what a
*standard* library needs; "standard" means serving programs nobody has written yet.

The failure mode this guards against is subtle and recurring: demand-first reasoning is
comfortable, feels rigorous, and reappears as "but what would use it?" long after the rule
requiring it is gone. That question is worth asking last, not first.

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
| **Signature-derived CLI** | prelude | A tool's entry declares its parameters once and gets argv parsing *and* `--help` from them. |
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
`help` / `version`. No changes; the shapes they have today are the shapes they keep. (`wrap` was
on this list and was retired on 2026-08-10 — see the reversal below. Ratifying a shape is not
freezing the verb; rule 7 says nothing is frozen pre-1.0.0.)

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

## After 0.3.0 — `mtps`, on demand (2026-08-09)

The second tool was a **task manager**, and it did exactly what rule 5 predicts a tool should do:
it named a capability that was missing. machteld could supervise processes it *started* and had
no view of one it had not — `child list` returns its own tokens and nothing else. So **`mtps`**
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
3. **`mtps kill -tree` is best-effort and says so.** It walks one snapshot. For a tree machteld
   started, `child kill` remains exact, because the job object holds the tree by identity rather
   than by pid. The palette documents the difference instead of blurring it.

`denied` joins the registry as the one code that reports a permission, confined to `mtps` because
`mtps` is the one verb that reaches outside machteld's own children.

## The store is not the parallelism mechanism (2026-08-09)

**Refused.** A store-backed work queue was built and measured properly first: WAL, a busy
timeout, and 
[38;5;8mUnknown command 'del'.[0m

[38;5;8mUse 'help' to see available commands.[0m returning its row count give an atomic claim with no new verb, and it
reached **12,500 claims/sec across 6 processes with every job claimed exactly once**. The numbers
were good.

It was turned down on what it would have made 

[38;5;69m ██████╗  ████████╗   ██████╗   ██████╗   ███████╗         ██████╗  ██╗       [0m
[38;5;69m██╗  [0m
[38;5;69m██╔════╝  ╚══██╔══╝  ██╔═══██╗  ██╔══██╗  ██╔════╝        ██╔════╝  ██║       [0m
[38;5;69m██║  [0m
[38;5;189m╚█████╗      ██║     ██║   ██║  ██████╔╝  █████╗          ██║       ██║       [0m
[38;5;189m██║  [0m
[38;5;153m ╚═══██╗     ██║     ██║   ██║  ██╔══██╗  ██╔══╝          ██║       ██║       [0m
[38;5;153m██║  [0m
[38;5;153m██████╔╝     ██║     ╚██████╔╝  ██║  ██║  ███████╗        ╚██████╗  ███████╗  [0m
[38;5;153m██║  [0m
[38;5;75m╚═════╝      ╚═╝      ╚═════╝   ╚═╝  ╚═╝  ╚══════╝         ╚═════╝  ╚══════╝  [0m
[38;5;75m╚═╝  [0m

[38;5;8mv22606.1401.13.0 - Preview[0m

Usage: [38;5;69mstore[0m [38;5;189m<command>[0m [38;5;8m[options][0m
       [38;5;69mstore[0m [38;5;51m--help[0m

Use '[38;5;69mstore[0m [38;5;189m<command>[0m [38;5;51m--help[0m' to get detailed help for any command.

[38;5;69mDiscovery Commands:[0m
[38;5;238m┌──────────────┬──────────────────────────────────────────┐[0m
[38;5;238m│[0m [38;5;189mcommand[0m      [38;5;238m│[0m [38;5;189mdescription[0m                              [38;5;238m│[0m
[38;5;238m├──────────────┼──────────────────────────────────────────┤[0m
[38;5;238m│[0m addons       [38;5;238m│[0m List add-ons for a game                  [38;5;238m│[0m
[38;5;238m│[0m browse-apps  [38;5;238m│[0m Browse ranked app lists                  [38;5;238m│[0m
[38;5;238m│[0m browse-games [38;5;238m│[0m Browse ranked game lists                 [38;5;238m│[0m
[38;5;238m│[0m extension    [38;5;238m│[0m Find apps that open specific file types  [38;5;238m│[0m
[38;5;238m│[0m protocol     [38;5;238m│[0m Find apps that handle custom URL schemes [38;5;238m│[0m
[38;5;238m│[0m publisher    [38;5;238m│[0m Find products from a publisher           [38;5;238m│[0m
[38;5;238m│[0m search       [38;5;238m│[0m Search for apps and games                [38;5;238m│[0m
[38;5;238m│[0m show         [38;5;238m│[0m Show product details and ratings         [38;5;238m│[0m
[38;5;238m│[0m similar      [38;5;238m│[0m Find similar products                    [38;5;238m│[0m
[38;5;238m└──────────────┴──────────────────────────────────────────┘[0m

[38;5;69mOperations Commands:[0m
[38;5;238m┌───────────┬─────────────────────────────────────────────┐[0m
[38;5;238m│[0m [38;5;189mcommand[0m   [38;5;238m│[0m [38;5;189mdescription[0m                                 [38;5;238m│[0m
[38;5;238m├───────────┼─────────────────────────────────────────────┤[0m
[38;5;238m│[0m install   [38;5;238m│[0m Install an app from the Store               [38;5;238m│[0m
[38;5;238m│[0m installed [38;5;238m│[0m List all installed apps                     [38;5;238m│[0m
[38;5;238m│[0m update    [38;5;238m│[0m Check updates for a specific app            [38;5;238m│[0m
[38;5;238m│[0m updates   [38;5;238m│[0m Check for updates across all installed apps [38;5;238m│[0m
[38;5;238m└───────────┴─────────────────────────────────────────────┘[0m

[38;5;69mHelper Commands:[0m
[38;5;238m┌─────────────────┬─────────────────────────────────┐[0m
[38;5;238m│[0m [38;5;189mcommand[0m         [38;5;238m│[0m [38;5;189mdescription[0m                     [38;5;238m│[0m
[38;5;238m├─────────────────┼─────────────────────────────────┤[0m
[38;5;238m│[0m app-categories  [38;5;238m│[0m List app categories             [38;5;238m│[0m
[38;5;238m│[0m game-categories [38;5;238m│[0m List game categories            [38;5;238m│[0m
[38;5;238m│[0m muid            [38;5;238m│[0m Get the Store device identifier [38;5;238m│[0m
[38;5;238m└─────────────────┴─────────────────────────────────┘[0m

[38;5;69mExamples:[0m
  [38;5;8mstore search "Microsoft Teams"[0m
  [38;5;8mstore show "Visual Studio Code"[0m
  [38;5;8mstore browse-apps top-free --category productivity[0m
  [38;5;8mstore browse-games top-paid --only-game-pass[0m
  [38;5;8mstore similar firefox[0m
  [38;5;8mstore updates[0m
  [38;5;8mstore install whatsapp[0m into. 

[38;5;69m ██████╗  ████████╗   ██████╗   ██████╗   ███████╗         ██████╗  ██╗       [0m
[38;5;69m██╗  [0m
[38;5;69m██╔════╝  ╚══██╔══╝  ██╔═══██╗  ██╔══██╗  ██╔════╝        ██╔════╝  ██║       [0m
[38;5;69m██║  [0m
[38;5;189m╚█████╗      ██║     ██║   ██║  ██████╔╝  █████╗          ██║       ██║       [0m
[38;5;189m██║  [0m
[38;5;153m ╚═══██╗     ██║     ██║   ██║  ██╔══██╗  ██╔══╝          ██║       ██║       [0m
[38;5;153m██║  [0m
[38;5;153m██████╔╝     ██║     ╚██████╔╝  ██║  ██║  ███████╗        ╚██████╗  ███████╗  [0m
[38;5;153m██║  [0m
[38;5;75m╚═════╝      ╚═╝      ╚═════╝   ╚═╝  ╚═╝  ╚══════╝         ╚═════╝  ╚══════╝  [0m
[38;5;75m╚═╝  [0m

[38;5;8mv22606.1401.13.0 - Preview[0m

Usage: [38;5;69mstore[0m [38;5;189m<command>[0m [38;5;8m[options][0m
       [38;5;69mstore[0m [38;5;51m--help[0m

Use '[38;5;69mstore[0m [38;5;189m<command>[0m [38;5;51m--help[0m' to get detailed help for any command.

[38;5;69mDiscovery Commands:[0m
[38;5;238m┌──────────────┬──────────────────────────────────────────┐[0m
[38;5;238m│[0m [38;5;189mcommand[0m      [38;5;238m│[0m [38;5;189mdescription[0m                              [38;5;238m│[0m
[38;5;238m├──────────────┼──────────────────────────────────────────┤[0m
[38;5;238m│[0m addons       [38;5;238m│[0m List add-ons for a game                  [38;5;238m│[0m
[38;5;238m│[0m browse-apps  [38;5;238m│[0m Browse ranked app lists                  [38;5;238m│[0m
[38;5;238m│[0m browse-games [38;5;238m│[0m Browse ranked game lists                 [38;5;238m│[0m
[38;5;238m│[0m extension    [38;5;238m│[0m Find apps that open specific file types  [38;5;238m│[0m
[38;5;238m│[0m protocol     [38;5;238m│[0m Find apps that handle custom URL schemes [38;5;238m│[0m
[38;5;238m│[0m publisher    [38;5;238m│[0m Find products from a publisher           [38;5;238m│[0m
[38;5;238m│[0m search       [38;5;238m│[0m Search for apps and games                [38;5;238m│[0m
[38;5;238m│[0m show         [38;5;238m│[0m Show product details and ratings         [38;5;238m│[0m
[38;5;238m│[0m similar      [38;5;238m│[0m Find similar products                    [38;5;238m│[0m
[38;5;238m└──────────────┴──────────────────────────────────────────┘[0m

[38;5;69mOperations Commands:[0m
[38;5;238m┌───────────┬─────────────────────────────────────────────┐[0m
[38;5;238m│[0m [38;5;189mcommand[0m   [38;5;238m│[0m [38;5;189mdescription[0m                                 [38;5;238m│[0m
[38;5;238m├───────────┼─────────────────────────────────────────────┤[0m
[38;5;238m│[0m install   [38;5;238m│[0m Install an app from the Store               [38;5;238m│[0m
[38;5;238m│[0m installed [38;5;238m│[0m List all installed apps                     [38;5;238m│[0m
[38;5;238m│[0m update    [38;5;238m│[0m Check updates for a specific app            [38;5;238m│[0m
[38;5;238m│[0m updates   [38;5;238m│[0m Check for updates across all installed apps [38;5;238m│[0m
[38;5;238m└───────────┴─────────────────────────────────────────────┘[0m

[38;5;69mHelper Commands:[0m
[38;5;238m┌─────────────────┬─────────────────────────────────┐[0m
[38;5;238m│[0m [38;5;189mcommand[0m         [38;5;238m│[0m [38;5;189mdescription[0m                     [38;5;238m│[0m
[38;5;238m├─────────────────┼─────────────────────────────────┤[0m
[38;5;238m│[0m app-categories  [38;5;238m│[0m List app categories             [38;5;238m│[0m
[38;5;238m│[0m game-categories [38;5;238m│[0m List game categories            [38;5;238m│[0m
[38;5;238m│[0m muid            [38;5;238m│[0m Get the Store device identifier [38;5;238m│[0m
[38;5;238m└─────────────────┴─────────────────────────────────┘[0m

[38;5;69mExamples:[0m
  [38;5;8mstore search "Microsoft Teams"[0m
  [38;5;8mstore show "Visual Studio Code"[0m
  [38;5;8mstore browse-apps top-free --category productivity[0m
  [38;5;8mstore browse-games top-paid --only-game-pass[0m
  [38;5;8mstore similar firefox[0m
  [38;5;8mstore updates[0m
  [38;5;8mstore install whatsapp[0m holds a tool's own key-value
state; a work queue is a different thing with different rules, and putting both in one file
behind one lock conflates them — [creed](creed.md) 6 asks for one way to do each thing, and this
was one thing doing two.

The durability question was the tell rather than the obstacle: a queue wants
, state a user keeps may want , and when one knob cannot serve both
defensible answers it is usually because two things are sharing one mechanism. Measured, recorded
in [parallel](parallel.md), reverted.

A durable cross-process queue, if ever wanted, arrives as **its own verb with its own file**.

Two findings outlive the refusal and are recorded in [parallel](parallel.md): **SQLite is a
coordination point, not a parallel data path** (throughput *falls* from 14,151 to 6,749 claims/sec
between 2 and 24 workers, because there is one writer at a time), and **a hot loop at a script's
top level runs 3.6× slower than the same loop in a proc** — which made the first parallelism
benchmark report a 0.79× slowdown when the machine was in fact overlapping 7.46×.

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

> **REVERSED, THEN REINSTATED — both on 2026-08-10.** The five tools moved into the exe at
> `//zipfs:/app/tool/<name>/main.tcl`, `mt sums .` ran one, and later the same day all five were
> deleted from the tree. **The original refusal stands, for a reason nobody argued at the time.**
>
> The reversal below is left in full rather than edited out, because the mistake is the useful
> part: every step of it was locally sound. The mechanical objection really had been answered, the
> receiver really had arrived, and the cost really had moved. What none of it examined was whether
> a front door should host applications *at all* — and the entry's own closing paragraph had
> already said that was the question. Answering a question the register told you not to ask is a
> failure mode worth recognising by name.

**The answer, given plainly: no.** A front door resolves names and supervises what it starts.
Hosting the applications as well makes it two things at once, and the second one grows without
limit — every program added is another name in the resolution order competing with the workspace's
own inventory, forever. `changes`, `tasks`, `sums`, `life` and `lifelab` are not *machteld*; they
are programs that were written to exercise machteld, and they did that job. They live in git
history, the palette they motivated is still here, and what they found is in [the log](log.md).

`mt.exe` ships: the Tcl/Tk libraries, the prelude, and its own docs. Nothing else.

**Bundling wrapped GUI tools into `machteld.exe` is refused.** Argued three ways and attacked by
nine critics; every affirmative case failed. `argv[1]` is fully allocated by `Tcl_Main` — non-dash
is a script path, dash is the REPL — so every dispatch spelling either breaks a spelling that
works, which rule 2 already forbids, or depends on the working directory. The claimed benefits
have no receiver: nothing here is signed, nothing is on PATH, and the author wrote both tools
himself. Recorded so it is not relitigated.

**What changed, point by point** *(the reversal's reasoning, kept as written)*. Not a change of mind
— a change of premises, two of them by building the thing the argument said could not be built:

- *"`argv[1]` is fully allocated."* It was, for a toolkit. It is not for a **front door**, whose
  entire job is turning a name into something runnable. `mt rg -n TODO .` was built in step 2 of
  [the front-door plan](front-door.md) and accepted on its own merits, and it broke no spelling
  that worked: a leading `-` still belongs to Tcl, and anything that *looks like* a path — a
  separator, or a `.tcl` extension — is still a script. Deliberately **not** "if the file exists",
  which is the working-directory dependence the refusal correctly feared.
- *"The claimed benefits have no receiver."* True then, and the receiver arrived: the exe **is**
  the workspace's front door now, so these are not unrelated GUI tools being bundled — they are
  the front door carrying its own, the way it already carries its prelude and its docs.
- *The cost moved the other way.* Keeping them out meant keeping `wrap`, which meant carrying two
  bare hosts inside the exe: 4.7 MB of payload and five 5.9 MB artefacts, to ship five files of
  Tcl. Retiring it took the exe from 10.2 MB to 6.0 MB.

The correction below turned out to be the load-bearing part — and the reversal cited it while
getting it backwards. It says the question is not "may the exe contain tools" but **"may the
palette contain applications"**, and then treated the front door's arrival as an answer. It was
not; it was a change of subject. The question is about identity, it was asked properly the next
time, and the answer was no.

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

## The first argument is a name — no shape test (2026-08-10)

**`mt app.tcl` no longer runs a script; `mt tcl app.tcl` does.** This reverses part of the dispatch
rule step 2 shipped and this document endorsed, so it is recorded here for the same reason the
entry above it is.

**What step 2 built.** `Tcl_Main` treats a non-dash first argument as a script path, which leaves
no unclaimed spelling for a tool name. Step 2 carved one out by asking what the argument *looks
like*: a path separator, or a `.tcl` extension, means a script; anything else is a name. It was
carefully **not** "does this file exist" — that would let a stray file in the working directory
change what `mt rg` means, which is a `PATH` fallback in different clothes — and it broke no
invocation anyone actually writes.

**Why it went anyway.** It was still a heuristic: a guess about which of two kinds of thing you
meant, made from spelling. Two things followed from that, and the second is the one that decided it:

- One case stayed genuinely ambiguous — a file named `changes`, no extension, standing beside a
  shipped tool named `changes`. Step 3 made that concrete rather than theoretical by putting five
  tools in the exe.
- **Rule 3 of the creed is *determinism over cleverness*,** and the dispatcher was the last place in
  the front door still guessing. A rule you can state in a sentence — *the first argument is a
  name* — is worth more than a rule with an exception list, in the one component every single
  invocation passes through.

**What it cost, stated plainly rather than minimised.** 71 call sites, changed once. And machteld
stops being drop-in wherever a `tclsh` is expected, because pointing an interpreter at a file is
the convention it just gave up. That was weighed: almost nothing here relied on it, and the front
door is no longer trying to be an interpreter.

**What keeps it honest.** `mt app.tcl` exits 127 and its second line names the new spelling, so the
old habit teaches rather than merely fails. `file exists` appears in that message and nowhere near
the decision — what `mt` runs still cannot depend on what happens to be in the working directory,
which was the property the original refusal existed to protect and which is *stronger* now, not
weaker.

## `wrap` comes back, and the front door pays 130 ms for it (2026-08-10)

**A receiver arrived, and it is the one the original refusal said did not exist.** The 2026-08-09
entry retired `wrap` partly on the grounds that "the claimed benefits have no receiver: nothing here
is signed, nothing is on PATH, and the author wrote both tools himself." That was true of *this*
workspace and false of the author's working life: at work, a small tool written in an afternoon has
to reach colleagues through a shared SMB folder, on machines with no Tcl, no Python and no install
rights. One self-contained exe on a share is the entire answer, and it is what `wrap` produces.

Both bare hosts are back inside `mt.exe`, console and GUI, so `wrap` needs no toolchain and no
workspace — the exe alone can stamp.

**What that costs, measured rather than assumed.** `mt version` — a builtin verb answered
in-process, so the timing is process start plus zipfs mount plus prelude source and nothing else:

| build | size | median of 40 |
|---|---|---|
| no basekits | 5.99 MB | 237–254 ms |
| both basekits | 10.21 MB | 362–378 ms |
| 4.6 MB × 2 of random data instead | 14.77 MB | 359 ms |

**+130 ms on every invocation.** Reproducible with the two builds interleaved, so it is not drift.
And **not** an antivirus reaction to executables nested inside an executable, which was the obvious
hypothesis: replacing them with incompressible random data costs the same despite a *larger* file,
so it is the size of the appended archive, and it behaves like a step rather than a slope.

I had predicted no measurable effect, on the reasoning that demand paging means an unread part of a
file is never read. That reasoning was sound and the conclusion was wrong, which is rule 5's entire
argument for building rather than reasoning about it.

**The cheap alternative was offered and declined, deliberately.** The basekits never need to travel
— `wrap` runs on the machine that has the workspace, and only its *output* goes on the share — so
putting them in `.mt/r/basekit/` would have kept the front door at 240 ms with no loss of
capability. It was refused in favour of **one file that can wrap anywhere**, which is a simplicity
worth 130 ms. Recorded with the number so the trade stays visible rather than becoming folklore.

**`wrap` is a capability, not an application**, and that is what distinguishes this from the five
tools deleted the same day. A verb hands the caller an exe of their own; an application would be an
exe machteld keeps. The front door still hosts nothing.

## Correction: the basekits cost ~13 ms, not 130 (2026-08-10)

The entry above reports a table putting the embedded basekits at **+130 ms per invocation**, and
decides to pay it. **The number is wrong and the decision is unaffected** — the true cost is about
**13 ms**, so the thing that was chosen is cheaper than it was chosen at.

The bad measurement compared `mt-nobasekit.exe`, a build made *before* `wrap` was restored, against
the current `machteld.exe`. Those two differ in their basekits and in their prelude, and the
prelude was where the cost really lived: `FrontResolve` was calling `manifest`, which derives the
palette's self-description at 316 ms a time. A same-session A/B of two hosts packaged from the
*same* prelude puts the basekits at ~13 ms, and two hosts with an *empty* prelude — 6.25 MB and
10.68 MB — answer in 22.6 ms and 22.3 ms, which is no difference at all.

**The withdrawn claim:** that a large appended archive slows startup as a step, and that the
archive's size rather than its contents was responsible. Neither is supported. The random-data
control that seemed to confirm it was measuring `manifest` too.

**The rule this earns**, because the mistake was not carelessness but a plausible-looking method:
**a cross-build A/B is not an A/B.** Two artefacts that differ in one *intended* way will differ in
others, and a measurement will attribute the entire gap to whichever difference you had in mind.
Vary one thing, from one source, in one session — and when a number is surprising, that is a reason
to isolate further rather than to write it down.

## `cdirs` does not become Tcl — measured, and refused (2026-08-11)

**The one command in [the front-door plan](front-door.md) that should not be rewritten in the
prelude.** `cdirs` walks every directory under `C:\` and writes the list; it is 426 lines of tuned
Go with reparse-point classification, depth limits, deduplication, flush intervals and GC tuning.
Step 4's premise is that z's commands are a page of Tcl each. This one is not.

**The measurement**, on `C:\dev` (a bounded subtree, warm cache, both walkers skipping directory
reparse points rather than descending them):

| | directories | time |
|---|---|---|
| `z cdirs --root C:\dev` | 21,765 | **1.5–1.75 s** |
| a Tcl walker over `glob -types d` | 20,979 (96% of them) | **12.2 s** |

**Seven to eight times slower at 96% coverage**, and closing that last 4% makes it slower still.
The prediction registered before running was 3–10×; the outcome is inside it, which is the least
interesting part.

**The interesting part is that the walker is still wrong, three attempts in.** Every failure was
silent — no error, no exception, just a different number:

- `glob -types d -directory $d *` misses the **HIDDEN ATTRIBUTE**, so every `.git` subtree
  vanished: 786 directories short.
- `glob ... -- * .*` matches dot-names **twice**, because `*` also matches them once the pattern
  list asks for them. Every dot-directory was queued and walked twice: 16,504 phantom entries, a
  77% overcount, and the walk *terminated normally*.
- Deduplicating by lowercased path fixed the overcount and lost the hidden directories again.
  Still 786 short, cause not established.

**Correction, 2026-08-11, measured while building the replacement.** The first bullet above used
to say `glob -types d *` "does not match dot-names on Windows". It does — on a controlled fixture
it returned `.dotname` and missed `hiddenattr`. The cause of the 786 is the **hidden attribute**,
and `.git` is `+h`; `-types {d hidden}` is not an addition but an *exclusive filter*, returning
the hidden entries **only**. `glob -- * .*` also returns `.` and `..`. Three separate misreadings
of one pattern language, and the entry above named the wrong one — which matters, because a
fixture built around dot-names alone reproduces none of it. The gates in `test/run_test.tcl` carry
a dot-name, a hidden dot-name and a hidden+system name as three separate subjects for exactly
this reason.

None of that was visible without diffing the full list against z's. A directory walker looks like
the simplest possible program and is not: on Windows it is reparse-point classification, dot-name
semantics, case-insensitive identity and cycle avoidance, and Tcl's `glob` hides the first three
behind a pattern language that answers differently than it reads.

**The decision: `cdirs` is not reimplemented in the prelude.** Two honest routes remain, and this
entry does not pick between them because nothing yet needs it to:

1. **A C verb.** [Rule 4](#) says C is for what Tcl cannot reach, and this is measurably that — a
   `FindFirstFileEx` walk with explicit reparse-tag handling would match Go's speed and settle the
   semantics in one place. It is the same argument that put `run`, `pty` and `watch` in C.
2. **It stays outside machteld.** `cdirs` writes a cache file nothing else in the front door reads.
   A workspace tool that happens to be a separate binary is not a failure of the plan.

What this does **not** license is the third route: writing it in Tcl anyway and accepting an
eight-times-slower, still-incorrect walk because the rest of step 4 went well.

### Resolved: route 1, as the palette verb `dirs` (2026-08-11)

**`src/dirs.c` is built, and it agrees with z exactly.** Measured in one session, same machine,
warm, full-list diff in both directions with multiplicity: on `C:\dev` z reports 21,794 lines and
`dirs` reports 21,794 paths, zero only-in-z, zero only-in-mt, zero duplicates on either side; on
`C:\dev\.z`, 12,813 against 12,813, same zeroes. Wall clock, in-process against a subprocess:
2.05 s against z's 2.66 s and 1.24 s against 1.64 s — **0.77× and 0.75×**, which is a ratio and
not a claim about either program, since z pays process creation and Go runtime init while `dirs`
pays for building a 21,794-element `Tcl_Obj` list. The point is the list, not the milliseconds:
the 12.2-second `glob` walk was refused for being *wrong*, and this one is not.

**One deliberate disagreement with z, and it is the reason the surrogate rule is written down.**
z refuses to descend anything carrying `FILE_ATTRIBUTE_REPARSE_POINT`. `dirs` refuses only *name
surrogates* — `tag & 0x20000000`, which a junction (`0xa0000003`) and a symlink (`0xa000000c`)
set and a OneDrive Files-On-Demand root (`0x9000701a`) does not. On the two trees above the two
rules coincide, because every directory reparse point there is a junction; under a cloud tree they
do not, and z's rule silently omits everything beneath it. Every reparse directory comes back as a
`links` row carrying its tag and what was done about it, so the choice can be audited instead of
believed.

**What did not get built, and why that is the entry's real content.** The specification this was
written from carried `-out FILE`, an `-onprogress` callback, `elapsed`, `maxpending` and a
`-links list|follow|skip` mode with canonicalisation, containment and volume+file-id identity
behind it. All of that is gone. [Rule 3](#) asks whether a proposal is one small C verb or a
subsystem, and [rule 4](#) says everything expressible in Tcl stays in Tcl: `-out` is three lines
of `open`/`puts` and would have made the principal result key silently empty whenever it was used;
`-onprogress` is a spinner, fixed at an interval no testable fixture reaches; `elapsed` is
`clock milliseconds` on either side of the call and makes the verb never twice the same; `follow`
is four more dispositions and a `seen` set with no receiver asking for it. What remains is
`dirs <root> ?-depth n? ?-prune patterns?` — the enumeration, the reparse classification, the
`\\?\` prefix and the emission order, which are the four things Tcl genuinely cannot reach.

**The front-door command was not built either, and that is route 2 standing.**
[front-door.md](front-door.md) had already struck `cdirs` off step 4 — "it wants a C verb **or**
it stays outside machteld" — and route 1 says "a C verb", not "and also port z's command line".
`mt cdirs` would also have had to default to `C:/`, where the surrogate rule above makes machteld
and z disagree by design, against a doctrine that says machteld earns each command by agreeing
with z on it first. The verb is here; the command stays z's until something asks for it.

### What review found in it, and what that says about the gates (2026-08-11)

**Four reviews of the shipped verb; the hard parts held and the accounting did not.** Path
arithmetic, handle discipline, the copy-not-pointer stack pop, 40,000 siblings, 300 levels, a
17,208-character path and a full-list diff against an independently written `FindFirstFileExW`
oracle all survived direct measurement. What did not survive is the part the file is *about*.

**Three defects, each of them a silence, and each in the mechanism built to prevent silence.**

- **A junction ROOT produced no `links` row.** The classification block is gated on `depth > 0`
  because the root is exempt from the *veto* — you named it, so you get it — which quietly made it
  exempt from being *described*, and the root's validation handle follows the reparse point so its
  tag reads 0. So `dirs <junction>` returned `root`, `paths`, `dirs`, empty `errors` **and empty
  `links`**: nothing anywhere in the answer said that every path in it is a second name for a tree
  living somewhere else. Both the source and [the palette](palette.md) promised "every reparse
  directory gets a row". 576 checks passed over it, because the gate for a junction root looked
  only at `paths` and `dirs`.
- **`dirs X/...` returned the parent's tree.** `GetFullPathNameW` trims trailing dots, `...`
  collapses to nothing, and the walk came back with six directories under the parent's own name,
  no error and no row. `X/trailspace ` and `X/traildot.` failed loudly with `notfound`, which was
  luck rather than design — the walker *creates and lists* all four names happily, so this was the
  verb's own output failing to round-trip, in the one spelling that was silent about it. Now
  refused with `badvalue` naming the `\\?\` spelling that works; `.` and `..` stay exempt.
- **Every error return leaked its three result `Tcl_Obj`s** — 144 bytes a call, exactly
  3 × `sizeof(Tcl_Obj)`, linear over 200,000 calls with no plateau, against a success path that
  plateaus at zero. `notfound` is what a directory that vanished between two walks answers, which
  is the ordinary failure for a walker, and the host is a long-lived front door.

**And the harder lesson: five of the gates could not fail.** Not "did not" — *could not*, and they
were found by patching the code rather than by reading it. `lsearch -glob $GOT $FXO*` can never
match anything the walker does, because every path is built lexically from the root's own prefix
and a link target is never resolved; the subject had to become the basename `*/ochild`, which
exists nowhere inside the tree. "maxdepth reports the deepest reached" used `>=`, so replacing the
whole computation with `9999` passed. "A trailing separator changes nothing" compared only counts,
and `dirs_join` suppresses a doubled separator independently — so disabling the entire
trailing-separator strip left every check green while the reported root came back `…/docs/`. (That
also retired a false claim in the source: the strip's comment said removing it would build
`\\?\C:\dev\\build` and fail every child with 123. It does not; the strip's real job is the
reported root.) And **the accounting invariant, the gate this verb's whole shape exists to serve,
skipped any probe the walker had listed** (`if {$absent in $GOT} continue`) — so over-listing, the
exact defect it was aimed at, emptied it. Measured against a build whose surrogate veto reads
`depth > 1` and whose open follows: all three junctions descended, the whole tree duplicated under
`linkup`, and the old gate reported **zero unaccounted**.

**"dirs lists nothing twice" is the one worth remembering**, because it was a real gate with a
starved fixture. The only defect in the shipped code that can produce a genuine duplicate is
converting names with `CP_ACP`, and under it every fixture name still mapped to something
distinct — `e9`, `???`, `?`, `??` — so the gate stayed silent and only the set-difference gate
fired. One extra directory named `\ue001` beside `\ue000` makes both collapse to `?`. Measured on
the same broken build: old fixture, **0 duplicates, gate silent**; new fixture, **1 duplicate,
gate fires**. A gate is only as good as the subject it is pointed at, and a fixture is a claim
about which defects are reachable.

**Method, since it is the transferable part.** Every gate changed here was proved by breaking the
code, watching the gate go red, and restoring: the surrogate veto at `depth > 1`, `CP_ACP` in
place of `CP_UTF8`, `maxdepth = 9999`, the trailing-separator strip disabled, and seven
independent reverts in one build — root classification, the leak, the component check, the
prefixed drive-root exemption, the post-normalisation prefix re-test and the UNC flag — which
produced eleven failures and not one false one. The block went from 76 checks to 102, and the
suite from 576 to 602. Behaviours that had **no** gate at all now have one: UNC roots, `C:/`,
`\\?\`-prefixed roots, the forward-slash spelling of that prefix, device-path and empty-root
refusal, a malformed `-prune` list, and `manifest dirs codes` — the last of which was added
because fixing the leak *broke* it. Folding free-and-raise into one helper moved the code literal
out of the argument position `genmanifest.tcl` reads, the build reported `codes=1` against a truth
of four, and all 600 checks still passed. Creed 4 is the palette describing itself; the generator
can be blinded by an ordinary refactor, so something has to notice. The fixture also stopped
leaking itself: its teardown removed junctions before `icacls /reset /t`, which had been following
`linkup` around the tree ~64 levels deep, and the on-entry wipe now collects every stale
`mt_dirs_*` rather than this run's own pid — a path that by construction can never be a killed
run's.

**What is fixed but cannot be gated, and is written down instead.** Six allocation-failure paths
used to drop directories with no row — a subtree vanishing under memory pressure while the verb
answered `TCL_OK` with a short, plausible list — and they now each raise a counted
`ERROR_NOT_ENOUGH_MEMORY` row, one per lost directory rather than one per parent, so the
cardinality the arithmetic needs is recoverable. None of it is reachable from a fixture, which is
precisely why it is written rather than argued about. The same applies to the two DFS reparse tags
added to the veto: they redirect into another namespace without setting the surrogate bit, and a
namespace pointing back at an ancestor is a cycle nothing here would bound — reasoned from the
tags' documented meaning and, unlike every other number in that file, **never observed on this
machine**, which the source says out loud.

## `front cdirs` is built, and it is the first command that must NOT agree with z (2026-08-11)

**A doctrine was overruled, and the entry above is where it was written down.** Hours earlier this
register said the front-door command "was not built either, and that is route 2 standing", giving
the reason in full: `mt cdirs` "would also have had to default to `C:/`, where the surrogate rule
above makes machteld and z disagree by design, against a doctrine that says machteld earns each
command by agreeing with z on it first." That doctrine had earned everything up to that point —
275 tool resolutions, 135 project commands, 5 verify problems and 29 scout lines, all agreeing
exactly — and it is overruled here on the grounds that **agreement was only ever a proxy for
correctness**, and this is the command where the proxy and the thing part company. Recorded rather
than quietly reversed, because "not frozen" is not "not accountable".

**The measurement that decides it**, taken on this machine, both walkers reading the same disk
minutes apart:

| under `C:/Users/anafa` | directories | wall (warm) |
|---|---|---|
| `dirs` / `mt cdirs` | **236,162** | 21.8 s |
| `z cdirs` | **112,018** | 13.3 s |
| only in `dirs` | **124,144** | every one of them under `C:/Users/anafa/OneDrive` |
| only in z | **0** | |

236,162 − 112,018 = 124,144, and only-in-z is 0, so those four numbers are one measurement.
**The version this replaced was not**: it published 236,150, 112,007 and 124,144, and
236,150 − 112,007 is 124,143. With no duplicates on either side and nothing only-in-z — both
asserted by the gate — those figures cannot all have come from one run, and for an entry whose
thesis is "measured rather than asserted" a table that fails its own arithmetic is the wrong error
to have. Both walks here are warm repeats after a discarded first run. The totals move between runs
because a home tree churns — 236,159, 236,169 and 236,162 are three real answers within an hour —
and the 124,144 did not move in any of them.

`C:/Users/anafa/OneDrive` carries reparse tag **`0x9000701a`** with **`surrogate = 0`**. z refuses
to descend ANY reparse point; `dirs` refuses only NAME SURROGATES (`tag & 0x20000000` — junction
`0xa0000003`, symlink `0xa000000c`). So z omits more than half the home tree, and these are real
local directories: Files-On-Demand virtualises file *contents*, not folders. The other eleven
reparse points under that root are junctions, where stopping is right.

**The defect is not that z stops. It is that z's report cannot tell you it mattered.** Its stats
line reads `12 links skipped` — one integer, naming none of the twelve, giving the eleven junctions
that hid a few hundred directories between them and the one that hid 124,144 exactly the same
weight. Counted, consequence invisible. That is the whole design brief for the command, and it is
why this one arrives with a report rather than a stats line:

> **A refusal the WALKER made is NAMED. A refusal the CALLER asked for is COUNTED. And the
> completeness verdict is on the first line, beside the count, so the count cannot be read alone.**

Named rather than counted, because the size of what lies behind a place the walk did not enter is
**not knowable without entering it** — that is the definition of not entering, not a gap in the
implementation. The number can therefore never be honestly reported, and offering one invites the
reader to take it for the magnitude of the loss. The one disclosure available is the place itself,
and it is affordable exactly where it matters: eleven such places in the whole home tree, two in
`C:/dev`. Counted rather than named for `-prune` and `-depth` because the caller already knows the
criterion, and because the verb offers integers there and not path lists.

**Three shape decisions, each following a rule rather than a taste.**

1. **One positional and four options, against z's twelve.** The root is a positional because that
   is how `dirs` spells its own subject ([rule 1](#) at the command layer). `--root` was considered
   as a seam alias and refused on a mechanical argument rather than an aesthetic one: the manifest
   derives `front`'s options from its literal `set opts {...}` line, so an alias must either be
   *declared* — making the palette assert an option that duplicates a positional — or undeclared,
   making the binary accept what the manifest denies. Both break [rule 6](#). The `-json`/`--json`
   concession is safe because those are two spellings of one option; a positional against an option
   is a different grammar.
2. **`-out`, `-stdout`, `elapsed` and the report live here, not in the verb** — and the register's
   own words are the argument. `-out` was cut from `dirs` because it "is three lines of
   `open`/`puts`" and "would have made the principal result key silently empty whenever it was
   used"; `elapsed` because "`clock milliseconds` on either side of the call is the same number"
   and "makes the verb never twice the same". A command's product *is* a file, so there is no
   result key to empty, and this is the caller with the two `clock milliseconds` calls, recording a
   run rather than returning a value that ought to be reproducible. Same rule, opposite verdict,
   one layer up: [rule 4](#) cuts both ways and that is the point of it.
3. **No `-cloud` / `-nocloud`, and it could not be built honestly anyway.** Skipping is a veto
   *inside* the walk and the verb exposes no hook for one, so a Tcl-side `-cloud` could only
   post-filter a list it had already paid the full 21 seconds to build — a shorter answer at full
   cost, wearing the appearance of a skip. That is precisely the class of silent misreport the
   command exists to end. `-prune OneDrive` does the real thing.

**Two defaults deliberately unlike z's, both of which would be silent if they were not gated.** The
default root is `MT_ROOT`, not `C:\`: the argument that decides is not scope but *checkability* —
under the workspace root the two front doors agree exactly (21,804 against 21,804 on `C:/dev`),
under `C:/` they disagree by design, and defaulting to the disagreeing root would make the
zero-argument form the one form that can never be validated against the incumbent. And the default
output is `$MT_HOME/cache/mt/dirs/<slug>.txt` rather than z's `cache/cdirs/c-drive-dirs.txt`:
during the transition `MT_HOME` **is** `.z`, the lists are forward-slashed where z's are
backslashed, and writing 2.1× as many lines into the file z's own cache readers open would be a
silent substitution. z's fixed filename is its own small lie — `z cdirs --root C:\dev` writes the
workspace into a file called `c-drive-dirs.txt` and overwrites the drive index — so the name is
derived from the normalised root here.

### The gate had to be re-pointed, and the oracle had to be fixed first

**`z cdirs --stdout` read back through `run` is a corrupt oracle, and it corrupts in the direction
that makes the superset gate PASS.** `src/proc.c` caps capture at 1 MiB (`size_t cap = 1u << 20`)
and truncates in silence. Measured while building the gate: on `%USERPROFILE% --max-depth 6` z
printed 16,817 lines and `run` returned **16,423** — exit 0, `truncated` set to `out`, and nobody
looking. The 394 lost lines came back as 394 extras attributable to nothing; at full depth the same
cap turned 112,007 z-lines into about ten thousand and reported a quarter of a million extras. **A
superset gate reading z through a pipe is strengthened by its own bug**, which is this project's
recurring failure — a gate that passes for a reason unrelated to its claim — in its purest form. z's
list is read from `--out FILE` now, and the line count is cross-checked against the count in z's own
stats line, so a short file is caught even though it comes off disk.

**The relation is a superset with a named cause, and it is asserted on two subjects because either
alone is satisfiable by a defect.** On `C:/dev` no non-surrogate reparse point exists, the two veto
rules coincide, and the lists must be **equal both ways** — that is the bound, and a walker that
descended junctions would satisfy every superset clause and fail only here. On the home tree: z ⊆
machteld; the excess **non-empty**, so a divergence gate that goes quiet when OneDrive is unmounted
says so rather than passing; every extra below a directory machteld itself classified
`surrogate 0, descended`; every shared path spelled identically, case included, since a
case-insensitive set comparison hides `CP_ACP`-class mangling; and no duplicates on either side.
Then, with a separate oracle, **every extra probed with Tcl's own `file isdirectory`** — a third
implementation asked one path at a time — because all of the set arithmetic above is equally
satisfied by a walker that *invents* paths.

**And the doc-accuracy scanner was nearly blind to this command, which is worth recording because
the fix was a decision not to widen it.** That gate filters option tokens with `^-[a-z]+$`, so
`--root`, `--out` and `--max-depth` are all invisible to it: spelled z's way, `cdirs` would have had
*no* coupling between its documented options and its declared table, and been green. Spelling the
options the verb's way keeps them inside the scanner's reach for free — a second, mechanical
argument for rule 1 on top of the readability one. Widening the regexp was measured (zero new drift
over all 41 doc blocks) and **refused anyway**: `--json` is accepted at the seam and deliberately
not declared, so a wider scanner would call a working documented example a typo — the
`front run -inherit` failure with its sign flipped. The blindness is gated instead: the suite fails
if any declared `front` option is a shape the scanner cannot see, and says what to do about it.

### And a defect the gates found in the artefact, not in the argument

**`json encode` cannot be relied on to render an EMPTY nested list as `[]`, and this shipped
before a gate caught it.** The encoder decides array-versus-object from a value's own internal
representation, which is the right rule and the one [the contract](contract.md) states — but an
empty list barely has a representation, and **Tcl's empty string is one shared object for the
whole interpreter**, so the answer depends on what an unrelated line did to that literal earlier
in the process. Measured in one build on one afternoon, from the same `[list]`: `[]`, `{}` and
`""`. `mt cdirs C:/dev` wrote a sidecar saying `"entered":{}` while `front cdirs` on the test
fixture, same binary, wrote `"entered":[]`. The contract's own escape hatch — *"say `-dict` or
`-list`"* — reaches only the **top level** of a document, and these keys are nested.

The fix is a fresh list object (`lrange` over a one-element list), which is the one form that is
stable. **The gate history is the more useful part**, because three of the four attempts at it
could not fail:

- The first gate asserted `refused` encodes as `[]` on a clean walk. Vacuous: the verdict
  computation calls `llength` on the same list two lines above, which shimmers it, so no mutation
  of the file could make it red. Proved by breaking it three ways and watching nothing happen.
- Its replacement decoded the JSON and checked `llength == 0` — which is 0 for `{}` and `[]`
  alike. It could not see the defect it was named after.
- A unit check on the helper stayed **green against a deliberately broken helper**, because the
  suite's own process happened to have left the shared literal list-shaped.
- What finally fires reads the **raw bytes a real run wrote in its own process**, on a subject
  with a non-empty `refused` beside an empty `entered` — the ordinary shape of a real walk, and
  the shape the all-empty subject hid.

**A gate is only as good as the subject it is pointed at**, which the `dirs` review already said;
this adds that a gate can also be defeated by *where it runs*, and that an in-process check of a
property the whole interpreter shares is not a check at all.

**The name is a transition spelling, and it is registered as one.** `cdirs` is z's abbreviation for
"**C:** dirs", so a command defaulting to the workspace carries a name that is mildly wrong in the
same way `c-drive-dirs.txt` is wrong when it holds `C:\dev`. It ships as `cdirs` because step 4's
premise is that these commands exist to be typed where z's were, and because the word is already in
the fingers. If it were being named today it would be `index` — `dirs` is taken by the verb, and a
promoted front-door command of that name would shadow it. Rule 7 makes the rename cheap when z is
gone.

## `cdirs` reviewed: the command built to end a silence had four of its own (2026-08-11)

**Three reviews of the entry above, and the useful result is not the count of defects but their
SHAPE: the command whose whole subject is "counted, consequence invisible" shipped four silences of
its own, each one the same failure translated into a new register.** That is worth the register
entry on its own — a doctrine does not protect the code that states it.

- **NAMED, MAGNITUDE INVISIBLE.** The indictment of z is that `12 links skipped` names none of the
  twelve. What `cdirs` printed was `entered  1 reparse directory ... C:/Users/anafa/OneDrive` — the
  place, and no number — while **124,144 of 236,162 lines, 52.6% of the whole answer, came from
  that one row**. The entry above justified the omission with its own sentence about `refused`
  ("not knowable without entering it"), which is exactly true there and exactly false here: the
  walk DID enter, the paths were in hand, and a prefix count is sub-second against a 22-second
  walk. Every `entered` row now carries `below`.
- **A COMPLETENESS CLAIM PRINTED UNCONDITIONALLY.** `Everything under it IS in the count above` was
  emitted on every run with an entered row, including `mt cdirs C:/Users/anafa -depth 3`, where
  ~124,000 directories under that row are absent. The report telling a reader the list is complete
  below a place where it is not, in the one direction the command exists to prevent, with **no gate
  reading the string** and the same sentence shipped in the palette as the documented design.
- **A DISCLOSURE THAT VANISHED WHEN YOU AIMED AT IT.** `dirs <the cloud root>` returned `links`
  EMPTY, because the root's tag is read through a handle and a cloud filter consumes its own
  reparse point on open — so `mt cdirs C:/Users/anafa/OneDrive`, the one invocation pointed
  straight at the divergence, said nothing about it, while naming the parent disclosed it. This is
  the **junction-root silence the verb was already fixed for once**, in a different spelling, and
  `dirs.c` had the measurement written at the top of the file the whole time. The fix follows that
  file's own rule — the handle VETOES and never AUTHORISES — so the parent's scan supplies the row
  and can only ever add one.
- **A NAME THAT ASSERTS A ROOT IT MAY NOT HOLD.** `FrontDirsSlug` promised "two different roots
  cannot collide" and squashed `[^a-z0-9]+` to `-` with a hash tail only above 64 characters, i.e.
  everywhere except where short roots collide. Measured against the real indices on this disk, two
  pairs were **already** colliding (`.codex/.tmp` vs `.codex/tmp`, `OneDrive/_LIVE` vs
  `OneDrive/live`), and any root ending in a non-ASCII component slugged to its PARENT — so
  `C:/Users/anafa/Ä` overwrote `c-users-anafa.txt`, the flagship artefact. That is **z's
  `c-drive-dirs.txt` defect reproduced in the proc written to fix it**, and the gate for it tested
  only the >64-character case, which is the branch where the guarantee holds. The slug is now
  checked by INVERSE: reconstruct the root from the name, and hash whenever that fails.

**And the same shape once more, in the publish step.** "A failed run must not destroy a good cache"
was written four lines above the only line that could break it: the old sidecar was DELETED before
the new list was renamed, so a publish that could not replace the list left the previous run's list
with no report. The suite's gate for that invariant used a `file mkdir` failure, which aborts
before ever reaching the publish block — **the one path that can destroy anything was the one path
with no gate on it.** Beside it, three refusals that were not: `-out <a directory>` reported
`[COMPLETE]`, named the directory as the list and orphaned the real list inside it as
`<dir>/<dir>.tmp`; a directory standing at `<name>.json` was recursively deleted; and an empty
value was read as an absence on all three surfaces, so `mt cdirs $r -depth $limit` with an empty
`$limit` became a full walk whose report did not record that a limit had been asked for — while
`dirs $r -depth {}` refuses the identical value.

### The gate history is again the more useful half

**Six gates could not fail, and every one was proved by breaking the code and watching nothing
happen.** The verdict's three-term conjunction had ONE subject setting `pruned` and `depthlimited`
*simultaneously*, so either term could be deleted with all checks green — on a build that then
printed `[COMPLETE]` above `9 directories at the -depth 1 limit`. The whole `entered` paragraph
could be deleted from the renderer, green. `[COMPLETE]` was never checked against a real run, only
`[PARTIAL]`. `maxdepth`, `elapsed` and `when` were published and read by nothing — `elapsed` being
the one thing this layer exists to add over the verb, by the argument in the entry above. And the
veto-constant scanner's `TAG_[A-Z0-9]+` **has no underscore in its class**, so a real fourth vetoed
tag added as `DIRS_TAG_WCI_1` and left undocumented was invisible to the gate whose stated purpose
is to catch exactly that — and every likely future tag is spelled that way
(`IO_REPARSE_TAG_MOUNT_POINT`, `WCI_1`, `CLOUD_1`). Its blindness is now gated the way CD14 gates
the doc scanner's: a loose count beside the strict one, failing with instructions.

**The agreement gate's own clause C was satisfiable by an ancestor.** `front_agree.tcl` accepted any
disclosed `entered` row as an explanation for an extra, so a report naming
`[file dirname $path]` — the walk root itself — made the clause unconditionally true and the file
went **fully green**, printing `all below 1 disclosed non-surrogate root(s)`; the summary gave the
COUNT of gates and never their paths, so a human could not tell either. Two mechanical answers: a
gate must lie strictly BELOW the walk root, and **z must have listed nothing under it** — which is
what "z stopped here" means, and is measured (z lists `C:/Users/anafa/OneDrive` and zero paths
below it). Both fire on the break that used to pass. The line now names the places, which is this
command's own doctrine applied to its gate. And the BOUND — the clause this file calls the one that
carries the whole claim — had no newborn exemption where both other branches have one, so a
directory created under the active `C:/dev` between the two walks failed the strongest gate
spuriously; proved reached by injecting one in the window between z finishing and machteld
starting, which now prints `1 path(s) created after z's walk began` instead of `OVER-LISTED`.

**Every fix here was proved by mutation**: fifteen breaks in one build produced 41 failures, each
attributable to its own named check, and two further builds broke `front_agree`'s clause C in the
two ways it now refuses. The suite went from 702 checks to 752. One thing the mutation run found
that no review did: the new `below` gate was written with a bare `dict get`, so the build without
`below` made it RAISE rather than fail, aborting the run and silently skipping two hundred checks —
**the `valof` lesson, met for the fifth time, in a gate written the same afternoon the lesson was
re-read.**

### What was NOT changed, and why

**`-prune OneDrive` losing the `entered` row is correct.** A pruned reparse directory is a refusal
the CALLER asked for; naming it would put one place in two accounts and break the arithmetic every
gate here rests on. What was wrong was the DOC, which claimed "the report says what was pruned"
(it says the count and the patterns) and offered `-prune OneDrive` as if it reproduced z. Measured
here: it hits **four** places, not one — the cloud root, `AppData/Local/OneDrive`,
`AppData/Local/Microsoft/OneDrive` and an Office asset folder called `onedrive` — giving 111,899
against z's 112,015, and it is not even a subset: it **drops 126 directories z lists**, 124 of them
an unrelated `AppData/Local/Microsoft/OneDrive` subtree. The stated "one honest limit" was the
under-match; the over-match is what actually fires here, and both are now written down — along with
the fact that **no option reproduces z's descent policy and none is planned**, which the docs never
said.

**`FrontClean` still pops `..` past the drive letter.** It answers "is this path WRITTEN underneath
that one" for 275 tool resolutions and one junctioned payload, and a filename is not the question
it was written for. `cdirs` refuses the result instead, so `-out` can no longer name a file only
the original working directory could open.

**Costs are relabelled rather than re-measured.** Every timing on this page and in the palette is a
WARM repeat; the OneDrive subtree is precisely the part not touched daily, so the cold cost of the
divergence is understated by these numbers. A cold first-of-the-day walk was observed at 52 s
during review and could not be reproduced here without dropping the file cache, so it is recorded
as an observation rather than published as a figure — the same convention `dirs.c` uses for its DFS
pair. And the cost that matters to a CONSUMER of the list is now named for the first time: 52.6% of
the emitted paths are inside a Files-On-Demand root, and 67 of the first 4,000 files sampled under
it carry `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`, so a backup or an indexer fed this list touches
content z's list never named and can trigger downloads. **"More complete" and "cheaper to consume"
are not the same property**, and the docs claimed the first while saying nothing about the second.

## `-arg0`: a refusal that outlived its reason (2026-08-11)

**`mt make` did not work, and the front door said so honestly.** The workspace vendors GNU Make as
`mingw32-make.exe` and its manifest entry carries `arg0: make`. The front door refused the whole
tool with `{MACHTELD FRONT unsupported}` rather than launch it under a name that would make
`$(MAKE)` — and therefore every recursive build — come back spelled wrong. That refusal was the
right call at the time: this stage exists to be compared against z, and a confident wrong
resolution is worse than one that names what is missing. `preFromRoot`, `pre` and `envFromRoot`
were closed the same way, one at a time.

**What made it wrong was time, not reasoning.** A refusal is a placeholder; left standing it
becomes a decision nobody made. A front door replacing z has to run what z runs, and `make` is not
an exotic corner — it is the tool a build reaches for first. The register's own test is whether a
refusal still names something *hard*. This one no longer did.

**The launcher never needed anything.** `wj_launch` has always handed `CreateProcessW` the
executable and the command line as **separate** arguments — `lpApplicationName` and
`lpCommandLine` — so which file runs and what it calls itself have been independent since M1. Only
a way to *say* so was missing. That is the second time this month a front-door gap turned out to be
a missing option over an already-correct mechanism (`-inherit` was the first), and it is worth
naming as a pattern: **when a capability looks expensive, check whether the layer below already has
it.** The whole of `-arg0` in C is one option, one field, and a nine-line `argv_with_arg0()`.

**Declared by the shared parser, therefore true of all four spawners.** `run`, `child start`,
`detach` and `pty spawn` take it, because all four spawn and the shared parser is the one place a
spawning option belongs. Putting it only on `run` would have made the palette lie about which verbs
launch processes, which is exactly the kind of per-verb divergence the contract exists to prevent.

**Applied after resolution, never before — and that ordering is the whole safety property.** The
program is found from `argv[0]` as written; only then is `argv[0]` replaced in the child's vector.
So `-arg0` renames and never redirects, and `run -arg0 bash -- no_such_program.exe` still fails
`notfound` rather than quietly running bash. A gate holds that ordering, because the failure mode
if it ever inverts is a `PATH` lookup for something the caller did not ask for — silent, plausible,
and the one thing this workspace refuses everywhere.

**Proved by the artefact, not by the option.** `mt make -C <dir> show` prints the same bytes as
`z make`, including Make's own `make:` prefix on its directory messages — which is observable proof
that `argv[0]` took, since that prefix *is* the name Make was called by. The suite's behaviour
checks use the workspace bash (`echo $0`) and are **skipped with a printed notice** if it is
absent, rather than passing vacuously; break-testing `argv_with_arg0()` into an unconditional
`return cargv` fails exactly one named check.

**The refusal list is now empty.** `preFromRoot`, `pre`, `envFromRoot`, `arg0` — every key the
workspace manifest uses is honoured. The `{MACHTELD FRONT unsupported}` path stays, and still
guards `status -deep`; what changed is that it no longer stands in front of a tool anyone runs.

## `ledger`: the first output that is a shared file, not a rendering (2026-08-11)

**Every command before this one could render its own shape.** `runtimes` prints a table aligned to
its widest value where z truncates aliases at eight; `verify` keeps its own counts footer because z
counts 21 built-ins machteld does not have; `cdirs` writes forward slashes and a different default
path *specifically so* nothing reading z's cache byte-wise will read machteld's. In every case the
substance had to agree and the presentation was ours.

`ledger` cannot work that way. Its product is `book/payloads.lock.json`, a git-tracked file in a
workspace **both front doors write**, and if the two disagree by a byte then whichever ran second
calls the other's output stale — permanently, in both directions, with the file in the repository
being wrong according to one of them at all times. So the standard here is not "agrees on the
facts" but **byte-for-byte identity with `json.MarshalIndent`**, which is a different and much
harder thing.

### Four Go behaviours no JSON writer would choose

**Struct declaration order.** Not alphabetical, not insertion order — the order the fields appear
in `type ledgerPayload struct`. `LedgerPayloadObj` is therefore written as one `lappend` per field
rather than looped over a table: that proc IS the struct transcribed, and a reader should be able
to hold the two side by side.

**HTML escaping, on by default.** `json.Marshal` escapes `<`, `>` and `&` unless you go through an
`Encoder` with `SetEscapeHTML(false)`. z calls `MarshalIndent`, so escaping is on, and a source URL
with a query string spells its ampersand `&`. **Not one of the workspace's 275 tools has a
query string in its source URL**, so the real workspace could never have revealed this and a
byte-diff against it would have passed. The suite's fixture carries `?a=1&b=2` for exactly that
reason, and breaking the escape fails three named checks.

**`omitempty` per field**, including the numeric ones: a zero `bytes` or `aliasCount` vanishes.

**`omitempty` on a struct does nothing**, because `encoding/json` has no notion of an empty struct.
`Restore` is tagged with it and is a struct, so **every** payload carries a `"restore": {}` it does
not need. This is the most visible Go-ism in the file and the easiest thing in the world to leave
out — and the golden fixture did not catch it until a payload with no manifest entry was added.

### The one deliberate difference, and the one deliberate non-difference

**`generatedBy` still says `z ledger refresh`.** It looks like a lie -- machteld wrote the file --
and it is the only defensible answer while both programs exist. The field names the FORMAT's
generator, and machteld is a second implementation of that command rather than a second format. The
alternative is a file that is permanently stale according to whichever tool did not write it last.

**The advice line is machteld's.** `check` says `run: mt ledger refresh` where z says
`run: z ledger refresh`. That is a sentence addressed to a person rather than a byte in a shared
file, and a front door replacing z must not answer a problem by telling you to go and run z. The
agreement test asserts both halves rather than tolerating a difference: every other line identical,
that one different in exactly that way.

### A verdict command that exits 0 is half a command

`mt verify` printed five workspace problems and exited **0**, so `mt verify && deploy` deployed on a
broken workspace. It had been that way since `verify` landed and no test asked, because the front
door had no way for a command to report an exit code at all — `FrontDispatch` exited 0 unless a
CHILD process had produced a code. `ledger check` has the same shape, which is what finally forced
the mechanism.

`FrontStatus` is deliberately **not** an error. `verify` finding problems and `check` finding a
stale file are both *successful* runs of commands that looked and reported; raising
`{MACHTELD FRONT ...}` would make a script `catch` a working command and print its verdict as a
failure message. The command returns its text, and separately says what the process should exit
with. Reset at the top of every `front` call, because one process can run several -- `front in
<project> verify` runs `verify` inside `in` -- and a stale 1 would sentence a later command that
succeeded.

### What the measurement said, and the lesson met a third time

`mt ledger check` is **1.43x z** -- ~3.9 s against ~2.8 s, interleaved, five runs each. The
accounting is complete and almost none of it is the port: ~1.26 s is `pacman -Q`, a subprocess both
pay; ~440 ms is assembly; the rest is SHA-256 over **973 MB across 55 files** at **598 MB/s**
against Go's hardware-accelerated implementation. That last difference is roughly the whole gap. It
is a `src/hash.c` question and it is recorded rather than fixed here, because a faster SHA-256 is a
change to a verb eleven other things depend on and does not belong inside a command port.

The optimisation that did land is worth recording for its shape. The first working version spent
**1.3 s of 3.5 s in `FrontClean`**, called **212,000 times over ~1,500 distinct strings**, because
containment is asked once per (payload, tool, candidate path) and both sides are cleaned every
time. Memoising it needs no invalidation key at all -- unlike `manifest`'s memo, which is keyed on
the command set -- because it is a purely lexical function of its argument and never touches the
disk. Same build, hashing stubbed out to keep its 900-1400 ms of variance out of the number:
**1,254 ms -> 426 ms, 2.82x**.

**And the first end-to-end A/B said the change made things SLOWER.** It did not: hashing variance
and a busier machine swamped an 810 ms effect, and z's own time had drifted from 2.4 s to 2.8 s
between the two measurements. That is the basekit error and the cold-cache error for the third
time, in the same project, by the same hand. The rule that keeps being relearned is narrow enough
to state: **an end-to-end number cannot measure a component smaller than its own variance** -- stub
out the noisy part, or measure the component directly.

### And the ledger was stale, about exactly the four tools this project already found

`z ledger check` has reported `stale book/payloads.lock.json` since 18 July. The diff is four
payloads: `EditPadPro8`, `RegexBuddy5`, `CSCSE5` and `FNSE3` -- the same four `t/` directories the
manifest never mentions, and the same four `mt` could not run until step 4 discovered that z's tool
inventory is the `t/` scan UNION the manifest rather than the manifest alone. Nothing here caused
it and nothing here is a defect: a ledger going stale is a record of the tree changing. It is worth
writing down only because the workspace's own bookkeeping had been quietly out of date about
precisely the tools this project had already caught it forgetting. **It is left stale**, because
refreshing it writes two git-tracked files in a repository this work does not own.

## mirror's inner loop: prototyped before the port, and the reservation is answered (2026-08-11)

**The question was whether to port `mirror` at all.** It is 4,527 lines, 43% of z, and its work
looked like the one shape this project should be suspicious of: per-file processing over large
trees, where Tcl's per-operation cost bites hardest. The stated reservation was that porting it
might end in a C program with a Tcl configuration language -- and if so, Go was the better host for
that C and mirror should stay in z permanently. The strangler pattern allows a permanent seam.

So it was measured first. Full experiment in `spike/mirrorlinks/`; predictions registered before the
arms ran, and all three held.

### Three things the prototype found, in order of how much they change the answer

**1. There is no byte-copying loop.** `z mirror` drives `robocopy /MIR`. The copying, the retrying
and the deletion of destination extras are Windows'. The premise of the reservation -- "file-by-file
copying with hashing and link handling" -- was simply wrong about what mirror does. What z does per
entry is two tree walks, and they are **374 of mirror's 4,527 lines**. The other 4,153 are options,
path resolution and pinning, run locks, state, artefact indexing, reports, the restore manifest and
rehearsal: glue, and glue is the half Tcl is for.

**2. Tcl is 3x Go on that walk, not 100x, and 99% of the walk is a system call neither language
chose.** Attributed over a fixed 2,000-file sample: the Tcl LOOP costs **0.3 us per entry** and any
single `file` command costs **~27 us**, the same figure whether it asks `exists`, `type`, `stat` or
`attributes`. The language is 1% of the cost. On one warm subtree where every arm completed, pure
Tcl is 6,283 ms against Go's 2,112 ms.

**3. Both of them are ~14x slower than they need to be, and machteld already has the fix.** z asks
Windows about one path at a time -- `GetFileAttributes` per entry on the source, plus `CreateFile` +
`GetFileInformationByHandle` per entry on the destination. `dirs.c` does not: one
`GetFileInformationByHandleEx(FileIdBothDirectoryRestartInfo)` per DIRECTORY returns every child's
attributes and, for a reparse point, its tag in `EaSize`. On 302,654 entries: **14,081 ms against
986 ms.**

And the marginal cost of classifying every one of the 280,794 FILES is **zero** -- 986 ms against a
1,013 ms baseline that discards them, the classifying build coming out marginally faster, which is
noise. `dirs.c:433` has been throwing away data it already paid to read. That line now carries a
comment saying so and pointing at the measurement.

### The cold cache, for the fourth time, caught before publication for the first

The pure-Tcl arm on the full tree was still running after **20 minutes** against C's 986 ms. The
obvious write-up was "Tcl is a thousand times slower here" and it would have been false. The process
showed **40 s of CPU in 16 minutes of wall clock** -- 3% CPU, blocked on I/O throughout -- and timing
first-touch against repeat-touch on the same 20,000 files gives **5,984 us against 46.5 us, 128x**.
The run was measuring a cold file cache. Warm, a Tcl `file` call and Go's `GetFileAttributes` are
indistinguishable at this resolution, because they are the same system call.

The three previous times -- the basekits, `scout`, the `FrontClean` memo -- the wrong number was
published first and corrected afterwards. What was different here is that the ratio was refused
until it could be ATTRIBUTED, and the 0.3 us loop measurement made "Tcl is slow" impossible to
believe. That is the generalisable form: **a ratio you cannot attribute is not a result.** It sits
beside the rule from the ledger entry -- an end-to-end number cannot measure a component smaller
than its own variance -- and the two together are most of what this project keeps relearning.

### DECIDED: mirror is ported, with the walk in C

Not because Tcl can carry the inner loop at 3x, though it can. Because the loop belongs in C that
**already exists**: a link scanner is `dirs.c` with the file filter removed and the reparse target
read for the handful of surrogates found -- two junctions in 302,654 entries, one `CreateFile` +
`FSCTL_GET_REPARSE_POINT` each. The port makes a scan z runs TWICE per mirror run 14x faster:
**28.2 s of z's own per-entry work becomes 2.0 s.** It is also more faithful in a way already
visible in the prototype -- pure Tcl reports `link` for both junctions and directory symlinks and
cannot separate them, and the C walk reads the tag.

**What is NOT decided here** is the destination hazard scan's hardlink check, which needs
`nNumberOfLinks` and therefore a handle per file -- the one piece of mirror that genuinely is a
per-file open. It was not prototyped. It should be, before that half is written, because it is the
only remaining place where the "C program with a Tcl config file" ending is still live.
