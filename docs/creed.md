---
type: principles
title: The creed
description: The seven design principles every machteld decision is tested against.
tags: [machteld, principles, design]
timestamp: 2026-07-07
---

# The creed

The rubric against which every design decision is tested.

1. **No AI inside.** No embedded model, no "ask-AI" verb, no LLM dependency. Deterministic hands; the agent is an external mind. Unplug every model and it is still an excellent powertool.
2. **Machine-legible == human-legible.** One axis. A choice that helps agents but hurts the human, or the five-year-old script, is wrong.
3. **Determinism over cleverness.** Same command, same result. No hidden state, no locale/env surprises.
4. **The palette describes itself.** Every verb, option, and error is discoverable at runtime as structured data. Docs are generated *from* the truth, not maintained beside it. (See [the contract](/contract.md).)
5. **Errors are part of the contract.** Coded, structured, actionable.
6. **Orthogonal, frozen, additive-only.** One way to do each thing; the surface only grows, never breaks.
7. **Vanilla Tcl, extended in C.** We add commands, never mutate the language — so a model's Tcl fluency transfers 1:1 and only the (in-context) palette is new.

The anti-bandwagon summary: *design for the machine as your most exacting reader; put no machine inside.* Why this works is [the bet](/rationale.md).
