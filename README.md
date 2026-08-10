# machteld

*A single-exe personal Tcl/Tk toolkit for Windows 11. You write Tcl; the power — and the packaging — is in C.*

machteld is one signed Windows executable (Win 11 23H2+) that does two things:

- **A workspace front door.** `mt <name>` turns a name into something runnable under a controlled environment — a builtin verb, one of the tools it ships, or one the workspace curates — with **no system-`PATH` fallback**, so what runs is what the workspace vendored. It records every one in a [SQLite journal](docs/journal.md).
- **A machine-control primitive library** — in every tool it runs, and in its own REPL: kernel-grade process supervision (born-in-job launch, whole-tree kill, die-with-parent, resource caps, timeouts, live capture/streaming), interactive **ConPTY** steering (`pty` / `expect`), live file events (`watch`), a machine-wide process view (`mtps`), JSON (`json`), and a statically-linked **SQLite** (`store`). All in C, in-process, no DLLs.

Built to be as legible to agents as to humans — *no AI inside; the agent is an external mind.*
Every tool it stamps carries **its own spec inside it**: `help` serves the documentation bundle
and `manifest` answers with the real surface — verbs, options, result shapes and error codes —
derived from the source rather than maintained beside it, so it cannot describe a binary it is
not.

```tcl
set w [watch start $dir -recursive]
wait -any [child start -- build.cmd] $w      ;# the build finished, or a file changed
dict get [manifest] watch subcommands        ;# what this exe can actually do
```

Three tools built with it ship alongside, each one exe with no install: **`changes`**, a live view
of what is changing in a directory tree; **`tasks`**, a task manager — the process list, live and
sortable, with End Task; and **`sums`**, which hashes a tree using **copies of itself** as worker
processes. They exist as much to prove the factory as to be used. The first two were written
first and then named the C capability they needed, which is how `watch` and `mtps` came to be
built; `sums` proves the other direction — that a shipped tool can spawn itself as a pool of
persistent workers, with no tclsh and no worker script on disk.

**Concept & design docs:** [`docs/`](docs/) — an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog) knowledge bundle. Start at [`docs/index.md`](docs/index.md).

Licensed under Apache-2.0.
