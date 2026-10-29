---
type: proposal
title: Console control ownership
description: A console verb that lets an inherited child own Ctrl-C, and no window for captured children.
tags: [machteld, process, console, windows]
---

# Console control ownership

Two related gaps in the execution model, both about the console a launch
does or does not get. Written up here with working code so the slice can be
taken whole into a release; neither is committed to a version yet.

## The Ctrl-C gap

`run -inherit` hands the child the host's own console, which is the point:
the child reads and writes the terminal directly. Windows then delivers
`CTRL_C_EVENT` to every process attached to that console. The host's
default handler exits the host, and because supervised children are born
into the host's kill-on-close root job, the child tree dies with it. The
child never gets to decide what Ctrl-C means, so an editor, a REPL, or a
build that traps interrupts cannot be run through a machteld program the
way it can be run from a shell.

A front door that dispatches to arbitrary tools needs the opposite
contract: the parent ignores console interrupts, the console-sharing child
receives them and decides, and the parent then reports whatever exit code
the child produced. That is what Go's `signal.Ignore(os.Interrupt)` gives a
program of the same shape.

Proposed surface, deliberately a plain switch with a readable state and no
callback machinery:

```tcl
console ctrl ignore     ;# SetConsoleCtrlHandler(NULL, TRUE)
console ctrl default    ;# SetConsoleCtrlHandler(NULL, FALSE)
console ctrl            ;# the mode in force
```

Only `CTRL_C_EVENT` is affected; Ctrl-Break and window-close keep their
default handling, which matches the narrow behaviour being replaced.

## The stray-window gap

`wj_launch` passes no creation flag that suppresses a console. When the
host itself has no console — a hidden shell, a service, an editor's tool
runner — every captured `run` or `child start` of a console program
allocates a **new visible console window** for the child's lifetime. A
program that launches many short children makes windows blink across the
screen, once observed as several hundred empty terminals during a harness
run.

The fix is `CREATE_NO_WINDOW` for launches whose stdio is a pipe or `NUL`
(captured `run`, `child start`, `detach`); the child still gets a console
object, just no window. `-inherit` must keep passing no flag so an
interactive child stays attached to the parent's console, and the ConPTY
path must not be touched. `CREATE_NO_WINDOW` may not be combined with
`DETACHED_PROCESS` or `CREATE_NEW_CONSOLE`, so the detach path needs a
look rather than a blind flag.

## What is here

- `console.c.txt` — the verb, built and gated in a since-abandoned
  experiment where the namespace was `::mt`. Port the namespace back to
  `::machteld` and the error root to `MACHTELD`.
- `reference-page-draft.md.txt` — the command page, same namespace caveat,
  with the eight mandatory sections and the `ctrl` subcommand anchor.
- `integration.diff` — the appinit registration, the `manifest_spec.tcl`
  entry, the index mention, and the process-lane tests from that
  experiment. Its last hunk also fixes a test that called the process
  fixture's `ok` mode without its required payload argument.
- `upstream-attempt.diff` — an unfinished, ungated attempt at both gaps in
  this repository, including the `CREATE_NO_WINDOW` work. A sketch, not
  reviewed code.

## Why it is written down rather than done

The consumer is the `x` front door, which wraps machteld and dispatches a
workspace's tools. It already calls `console ctrl` when the running runtime
provides it and documents the gap when it does not, so it gains the
behaviour the day a release carries the verb, with no coordination.
