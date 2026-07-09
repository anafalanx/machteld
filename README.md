# machteld

*A single-exe personal Tcl/Tk toolkit for Windows 11. You write Tcl; the power — and the packaging — is in C. Working name (provisional).*

machteld is one signed Windows executable (Win 11 23H2+) that does two things:

- **A tool factory.** `wrap` a pure-Tcl/Tk program into its own standalone, signable exe — console **or** GUI, with **zero compiler**. Both subsystem basekits and the Tcl/Tk libraries ride inside `machteld.exe`, so no toolchain or Tcl runtime is needed to build a tool or to run one.
- **A machine-control primitive library** — bundled into every tool it builds, and into its own REPL: kernel-grade process supervision (born-in-job launch, whole-tree kill, die-with-parent, resource caps, timeouts, live capture/streaming), interactive **ConPTY** steering (`pty` / `expect`), and a statically-linked **SQLite** (`store`). All in C, in-process, no DLLs.

Built to be as legible to agents as to humans — *no AI inside; the agent is an external mind.*

**Concept & design docs:** [`docs/`](docs/) — an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog) knowledge bundle. Start at [`docs/index.md`](docs/index.md).

Licensed under Apache-2.0.
