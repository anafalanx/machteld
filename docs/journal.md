---
type: design
title: The journal
description: What the front door records about every process it starts, and the SQLite schema that holds it.
tags: [machteld, journal, sqlite, front-door, design]
timestamp: 2026-08-10
---

# The journal

A front door sees every process the workspace starts. Nothing else does — a shell records the
line you typed, not what it resolved to, how long it took, or whether it was killed. That record
is what makes a live view of the development environment possible at all, so it is worth keeping
properly rather than as an afterthought.

## There is no prior art here, and that is worth stating

`z` has `ledger` and `logs`, and **neither is an activity log**:

- **`ledger`** is a payload bill-of-materials — every tool and runtime with its SHA256, size,
  entrypoints and restore instructions. It exists so `verify`, `mirror` and `restore` can prove the
  workspace is what it claims to be. It says what is *installed*, never what was *run*.
- **`logs` / `follow`** tail the text logs a `mirror` run writes. The kinds are `robocopy`,
  `preflight`, `postflight` and `links` — all artefacts of one long operation.

So z never records what it executed. This is not a strangler step with behaviour to match; it is
new, and the design below owes nothing to an existing one. Where z has a word for something, this
avoids reusing it: `ledger` stays z's bill-of-materials, and machteld's record is the **journal**.

## Why SQLite, decided on measurements rather than taste

SQLite is already statically linked into the exe, so it is **zero new dependency** against an
[ecosystem policy](ecosystem-policy.md) of vendor-and-freeze. LMDB would be the first new C
dependency, and it is a memory-mapped B-tree tuned for read-heavy random access — the wrong shape
for an append-mostly record, and a poor trade for a query surface it does not have.

The performance objection does not survive contact with the numbers already in
[parallelism](parallel.md): **fsync was the ceiling, never the engine.** `store put` moved from
118/sec to **16,129/sec** on `journal_mode=WAL` + `synchronous=NORMAL`. A front door produces one
row per process it starts, and starting a process costs ~44 ms — so the write rate is three orders
of magnitude below what one connection sustains. An append-only file is faster still (105,263
writes/sec measured) and then leaves the query layer to be written by hand.

And the queries are the point. "What is running right now", "what did this project run in the last
hour", "which tool fails most" are relational questions with a relational answer.

## The one hard constraint: every invocation is a separate process

`mt rg …` starts a new `mt.exe`. So the journal is **multi-writer by construction** — not an
occasional case to handle but the normal one. That is settled by the same measurement:
`journal_mode=WAL` with `busy_timeout`, under which 6 concurrent writers × 200 puts gave
**1200 succeeded, 0 failed**, where before five of six had died on open.

```sql
PRAGMA journal_mode = WAL;      -- readers never block the writer
PRAGMA synchronous  = NORMAL;   -- the 72x; still crash-safe, loses at most the last commit
PRAGMA busy_timeout = 5000;     -- concurrent front doors wait rather than fail
```

## The schema

One table, because the fact being recorded is one thing: a process ran.

```sql
CREATE TABLE IF NOT EXISTS run (
    id       INTEGER PRIMARY KEY,
    session  TEXT    NOT NULL,   -- one mt.exe invocation; ties a command to what it spawned
    parent   INTEGER,            -- run.id that started this one; NULL at the top
    started  INTEGER NOT NULL,   -- unix milliseconds
    ended    INTEGER,            -- NULL while it is still running
    ms       INTEGER,            -- ended - started, written once so ordering costs nothing
    name     TEXT    NOT NULL,   -- the name that was ASKED for: "rg"
    kind     TEXT    NOT NULL,   -- builtin | tool | script | child
    exe      TEXT    NOT NULL,   -- what it resolved to
    argv     TEXT    NOT NULL,   -- JSON array, as actually spawned (pre and arg0 applied)
    cwd      TEXT    NOT NULL,
    project  TEXT,               -- MT_PROJECT_NAME, or NULL outside a project
    pid      INTEGER,
    status   TEXT,               -- running | ok | error | timeout | killed | lost
    exit     INTEGER
);

CREATE INDEX IF NOT EXISTS run_started ON run(started DESC);
CREATE INDEX IF NOT EXISTS run_project ON run(project, started DESC);
CREATE INDEX IF NOT EXISTS run_name    ON run(name, started DESC);
CREATE INDEX IF NOT EXISTS run_live    ON run(ended) WHERE ended IS NULL;
```

Four indices and no more: the INSERT sits on the critical path of every command, and an index that
serves no question is a tax on every row. Each of these answers one the live view actually asks —
newest first, by project, by tool, and what is running now.

**`name` and `exe` are both kept, and they are different facts.** `name` is what was asked for and
is what a human groups by; `exe` is what the manifest resolved it to on that day. Keeping both is
how "this used to work" becomes answerable after a runtime is upgraded underneath you.

### What is deliberately not recorded

- **The environment.** It is large, mostly constant, and *reconstructible*: `front env <name>`
  recomputes it from the manifest. Storing a copy per row would multiply the database for a fact
  already derivable.
- **Output.** Capturing every byte every tool ever wrote is a different feature with a different
  cost. `run` already returns output to whoever asked for it; the journal records that a thing ran,
  not what it said.

## The two-write problem, and reconciling against the machine

A row is INSERTed at spawn with `status='running'` and UPDATEd when the process ends. If machteld
itself dies in between — killed, crashed, machine powered off — the row is left claiming to be
running forever. Hoping that does not happen is not a design.

machteld can do better than hope, because it can **ask the machine**: `mtps info <pid>` says
whether that pid exists and, crucially, **when it started**. So an unfinished row is reconciled:

- pid exists **and** its start time matches the row's → genuinely still running.
- otherwise → `status='lost'`, with `ended` unknown rather than invented.

The start-time comparison is what makes this sound: pids are recycled, and without it a long-dead
row would be resurrected by whatever process later inherited its number. This is a real use for the
`started` field `mtps` returns, and it is the kind of answer only a front door that also enumerates
processes can give.

## Rules it inherits from the rest of the palette

- **A journal write never breaks the command it is recording.** Same bargain `log` already makes: a
  failure increments a counter that `journal stats` reports, and the run proceeds. A tool must not
  fail because bookkeeping did.
- **No workspace, no journal.** If there is no `MT_HOME`, the front door still resolves and runs;
  the journal is simply off. Recording is a service, not a precondition.
- **Retention is bounded and stated.** Rows older than 30 days are pruned, at most once per
  session, on the `started` index. An unbounded log on a daily-use front door is a slow leak.

The file lives at `$MT_HOME/mt.db` — one database, beside the workspace it describes.

## Surface

```tcl
journal live                       ;# what is running now, reconciled against the machine
journal recent ?n?                 ;# the last n, newest first
journal find -name rg -project els -since 1h -failed
journal prune ?-keep 30d?
journal stats                      ;# counts by tool and status; write failures
```

Recording happens inside `front run`, so nothing has to remember to call it. It is nonetheless
reachable from a script — an agent that shells out to something machteld did not start can record
that it did, and appear in the same view as everything else.

## What this is for

The GUI in [the front-door plan](front-door.md) is a query away once this exists: what is running,
what just failed, what this project has been doing. Building the record first and the window second
is the right order — a live view over a record is a display, while a live view with no record is a
second source of truth.
