# machteld

*A single-exe personal Tcl/Tk toolkit for Windows 11. You write Tcl; the power is in C.*

machteld is one signed Windows executable (Win 11 23H2+) that does two things:

- **A workspace front door.** `mt <name>` turns a name into something runnable under a controlled environment — a builtin verb, or a tool the workspace curates — with **no system-`PATH` fallback**, so what runs is what the workspace vendored. It records every one in a [SQLite journal](docs/journal.md). A script is named too: `mt tcl app.tcl`.
- **A machine-control primitive library** — in its REPL, in any script it runs, and in anything it starts: kernel-grade process supervision (born-in-job launch, whole-tree kill, die-with-parent, resource caps, timeouts, live capture/streaming), interactive **ConPTY** steering (`pty` / `expect`), live file events (`watch`), a machine-wide process view (`mtps`), JSON (`json`), and a statically-linked **SQLite** (`store`). All in C, in-process, no DLLs.

Built to be as legible to agents as to humans — *no AI inside; the agent is an external mind.*
It carries **its own spec inside it**: `help` serves the documentation bundle and `manifest`
answers with the real surface — verbs, options, result shapes and error codes — derived from the
source rather than maintained beside it, so it cannot describe a binary it is not.

```tcl
set w [watch start $dir -recursive]
wait -any [child start -- build.cmd] $w      ;# the build finished, or a file changed
dict get [manifest] watch subcommands        ;# what this exe can actually do
```

**No applications ship inside it.** Five did — `changes`, `tasks`, `sums`, `life`, `lifelab` —
first as standalone exes stamped by a `wrap` verb, then briefly as scripts riding in the exe's own
zipfs. Both arrangements were removed on 2026-08-10: a front door resolves names and supervises
what it starts, and hosting the applications as well made it two things at once.

They earned their keep on the way out, and what they taught is what remains. `changes` and `tasks`
were written first and then named the C capability they needed, which is how `watch` and `mtps`
came to exist. `sums` proved the opposite direction — that this exe can spawn **copies of itself**
as a pool of persistent workers, with no tclsh and no worker script on disk. `life` and `lifelab`
were the stress experiment that found the cap-enforcement and timeout defects the supervision layer
had been hiding. The palette and [the log](docs/log.md) keep the findings; git keeps the programs.

**Concept & design docs:** [`docs/`](docs/) — an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog) knowledge bundle. Start at [`docs/index.md`](docs/index.md).

Licensed under Apache-2.0.
