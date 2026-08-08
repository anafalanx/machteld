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

The brake, stated as plainly as the goal: **machteld is a toolkit that ends in shipped tools.**
A stretch that adds ten powers and no tool has failed, however elegant the powers.

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
system, it belongs to a different project — and this workspace has two of those already.

**4. Prelude first; C only for what Tcl cannot reach.** The existing split is the rule:
supervision, ConPTY and SQLite are C because they are kernel and library surface; everything
expressible in Tcl stays in Tcl, where it is readable, patchable and testable in the shipped
exe. A power that works in the prelude does not get rewritten in C for speed without a
measurement that says so.

**5. Domains build out in this order: `watch`, `svc`, `reg`, then `evt`/`net`.** Our own C for
each; **TWAPI stays a quarry** and is opened only for WMI/COM, only when a verb demands it
([ecosystem policy](ecosystem-policy.md)). `watch` comes first because the first real tool
needs it and because file events are the smallest of the four.

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
standard does not drop for later domains. `nagelfar` becomes the lint gate for tool Tcl when
the first tool exists to gate.

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
| **Named-capture matches → dict** | prelude | ARE lacks named groups, so a pattern rewriter extracts names, runs plain `regexp -inline`, and zips the result. Deletes group-position counting when parsing tool output. |
| **Signature-derived CLI** | prelude | A wrapped tool's entry declares its parameters once and gets argv parsing *and* `--help` from them. Fits the [tool factory](packaging.md) exactly. |
| **Shapes** (`where`-constrained validation) | prelude | Declare a dict's shape once, check it at every boundary; composes with the manifest. |
| **An object layer over TclOO** (roles, attribute defaults, `before`/`after`/`around`) | prelude | The Moose idea, on the object system Tcl already ships. Admitted only if a tool wants it — rule 3 applies hardest here. |

**Refused, on rule 2**, so they are not relitigated: junctions and any autothreading operator;
implicit-lambda stars; user-defined operators (every program becomes its own dialect); multiple
dispatch (turns a wrong call into "no candidate matched"); anything requiring a second
evaluation phase or mutable grammar.

## Open, needing a decision

- **Tcl version pin.** The build targets **9.0.3**; the workspace also carries 9.0.4. One
  should be chosen deliberately rather than by inertia.
- **Which candidate first**, and whether the object layer is in scope at all this stretch.
- **The name.** *machteld* is still marked provisional in [the roadmap](roadmap.md).
