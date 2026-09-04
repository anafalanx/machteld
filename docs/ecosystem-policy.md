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

Current choices:

- Tcl/Tk 9.0.4 are part of every full and wrapped host, including their script
  libraries and distribution notices.
- Tcl's static core incorporates its bundled zlib 1.3.2 and LibTomMath 1.3.0;
  their exact upstream notices are pinned and shipped in every host.
- The public-domain SQLite amalgamation is statically linked behind `store`.
- MIT-licensed yyjson 0.12.0 is statically linked behind the JSON reader and
  its notice is carried in every host.
- Windows process, ConPTY, directory, watch, HTTP, and crypto integration is
  implemented against the operating-system APIs behind the Machteld palette.
- The JSON implementation is gated against JSONTestSuite; the corpus is a test
  dependency, not runtime payload.
- Tcllib modules may be cherry-picked only when a command requires one.
- TWAPI is a source quarry for difficult COM/WMI work, not a public foundation.
- TclTLS and Expect are unnecessary here: WinHTTP and ConPTY own those jobs.

An upstream library's vocabulary never becomes Machteld's contract. The palette
is the compatibility boundary, and wrapped tools receive the same pinned runtime.
