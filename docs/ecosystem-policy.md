---
type: policy
title: Ecosystem policy
description: Rules for dependencies embedded in the runtime.
tags: [machteld, dependencies, vendoring]
---

# Ecosystem policy

Runtime dependencies are pinned by hash, built into a verified local prefix,
statically linked where practical, and shipped in the executable. The admission
test is not popularity; it is whether the dependency works with Tcl 9 and
supports a public capability that cannot be supplied more clearly in-house.

Implemented and pinned dependencies (see `tools/dependencies.lock.json`):

- Tcl/Tk 9.0.4 are part of every full and wrapped host, including their script
  libraries and distribution notices.
- Tcl's static core incorporates its bundled zlib 1.3.2 and LibTomMath 1.3.0;
  their exact upstream notices are pinned and shipped in every host.
- The public-domain SQLite 3.53.4 amalgamation is statically linked behind
  `store`, a key/value interface rather than a general SQL command.
- MIT-licensed yyjson 0.12.0 is statically linked behind JSON decoding and typed
  values, including their writer; its notice is carried in every host. The
  plain-mode emitter remains authored Machteld code.
- Windows process, ConPTY, directory, watch, HTTP, and crypto integration is
  implemented against the operating-system APIs behind the Machteld palette.
- The JSON implementation is gated against JSONTestSuite; the corpus is a test
  dependency, not runtime payload.

Admission policy, not additional bundled capabilities:

- Tcllib modules may be selected only for a concrete need; this is not a promise
  that `package require` will find the Tcllib distribution.
- TWAPI is not bundled and there is no built-in COM/WMI integration.
- TclTLS and Expect are not bundled. WinHTTP and Machteld's ConPTY commands
  cover the current palette's HTTP and terminal needs, but are not compatible
  replacements for those packages' APIs.

An upstream library's vocabulary never becomes Machteld's contract. The palette
is the compatibility boundary, and wrapped tools receive the same pinned runtime.
The selected application may bring additional explicitly deployed dependencies;
the [external libraries guide](extensions.md) separates those from the built-ins.
