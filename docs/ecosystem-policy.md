---
type: policy
title: Ecosystem policy
description: Vendor-and-freeze everything; own the snapshot; TWAPI is a quarry, not a foundation.
tags: [machteld, ecosystem, twapi, vendoring, tcl-extensions]
timestamp: 2026-07-07
---

# Ecosystem policy

Everything is **vendored and frozen** into the one exe, so upstream abandonment is a non-issue — you own the snapshot. The gate is not *"is it maintained"* but **"can I own this snapshot?"** (small, comprehensible C ≫ giant sprawl), plus **"does it work on Tcl 9?"** Everything hides behind the palette, so a library's idioms never leak to the surface. **A library is admitted only when a palette verb demands it.**

- **TWAPI** — *quarry.* Hand-roll the easy Win32 (`svc`/`reg`/`evt`/`net`) ourselves in C; borrow TWAPI only for the brutal WMI/COM layer, and only if a verb demands it.
- **Adopted:**
  - **critcl** — inline-C-in-Tcl; a dev accelerant for writing our own C verbs, not shipped.
  - **Tcllib** — cherry-pick single pure-Tcl modules only; never vendor wholesale.
  - **JSONTestSuite** — vendored as a *test corpus*, not a library: ~300 conformance cases the hand-rolled `json` verb is gated on. The pattern to prefer generally — when correctness is the worry, vendor the suite, not the implementation.
- **Deferred:** tDOM (when Windows XML actually appears).
- **Dropped (2026-08-08):** **nagelfar**. Adopted on paper as a lint gate for agent-written Tcl and never wired to anything; the agent study found models write correct Tcl unaided, so the gate was buying little against a real ongoing cost — another snapshot to own, and a way for `wrap` to say no. Reconsiderable if tool code ever starts failing in ways a checker would have caught.
- **Parked as models:** tkcon (→ the M4 chrome console), Wapp (if the cockpit ever goes web).
- **Rejected:** Expect (Unix-tty — we build our own on ConPTY), TclTLS (prefer a WinHTTP wrapper, no OpenSSL).
