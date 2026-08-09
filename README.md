# machteld

*A single-exe personal Tcl/Tk toolkit for Windows 11. You write Tcl; the power — and the packaging — is in C.*

machteld is one signed Windows executable (Win 11 23H2+) that does two things:

- **A tool factory.** `wrap` a pure-Tcl/Tk program into its own standalone, signable exe — console **or** GUI, with **zero compiler**. Both subsystem basekits and the Tcl/Tk libraries ride inside `machteld.exe`, so no toolchain or Tcl runtime is needed to build a tool or to run one.
- **A machine-control primitive library** — bundled into every tool it builds, and into its own REPL: kernel-grade process supervision (born-in-job launch, whole-tree kill, die-with-parent, resource caps, timeouts, live capture/streaming), interactive **ConPTY** steering (`pty` / `expect`), live file events (`watch`), a machine-wide process view (`ps`), a live cockpit over the running session (`mt`), JSON (`json`), and a statically-linked **SQLite** (`store`). All in C, in-process, no DLLs.

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

Two tools built with it ship alongside, each one exe with no install: **`changes`**, a live view
of what is changing in a directory tree, and **`tasks`**, a task manager — the process list,
live and sortable, with End Task. Both exist as much to prove the factory as to be used: each
was written first and then named the C capability it needed, which is how `watch` and `ps`
came to be built.

**Concept & design docs:** [`docs/`](docs/) — an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog) knowledge bundle. Start at [`docs/index.md`](docs/index.md).

Licensed under Apache-2.0.
