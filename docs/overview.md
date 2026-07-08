---
type: overview
title: What machteld is
description: A single-exe Windows 11 machine-control language — Tcl on the surface, C at the metal.
tags: [machteld, overview, tcl, windows]
timestamp: 2026-07-07
---

# What machteld is

A single signed Windows executable (Win 11 23H2+) that is a **machine-control command language**. Inside one exe: a C host, a statically-linked Tcl/Tk 9, and an appended zipfs. You write **Tcl**; the power — kernel-grade process control and Windows machine access — is added in **C** and exposed as a command palette. *Reach the metal; don't invent a language.*

It is **drang in spirit** — the same crown-jewel process supervision — without a bespoke language, because Tcl was built for exactly this role: the **Tool Command Language**, an embeddable command surface extended in C. Its long-awaited consumer has arrived: the machine (see [the bet](/rationale.md)).

## Audience & posture

- **For me first, product-shaped, audience later.** The obligations of an audience (docs, stability, AV/SmartScreen friction) are earned second.
- **Dogfood surface = machine control** — supervising processes, driving interactive CLIs, poking at services/registry/state on your own box. **Not** project/build tooling (that is the Go + Deno workbench).
- **Agents are the primary consumers — as a *quality bar*, not an AI feature.** This posture is enforced by [the creed](/creed.md).
