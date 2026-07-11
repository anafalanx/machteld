# `run_probe` native process fixture

This fixture is an experiment-owned Windows executable used to test process
launch, argument preservation, stream capture, nonzero exit handling, and
timeouts without depending on either comparison arm's language runtime.

## Frozen interface

Invoke it as:

```text
process_fixture.exe MODE PAYLOAD
```

- `ok` writes the UTF-8 encoding of `PAYLOAD` to stdout, writes `E:` followed
  by the same UTF-8 bytes to stderr, and exits 0.
- `fail` writes the same two streams and exits 7.
- Every valid invocation writes its decimal process ID, without a newline, to
  the path named by `MACHTELD_PROBE_PIDFILE`, then flushes and closes that file.
  This lets the checker require a launch in completed cases rather than accept
  a wholly manufactured result. `hang` then emits no output, sleeps for 5000 ms, and exits 0
  if it has not been terminated.

The success and failure streams have no implicit newline. Output uses Win32
`WriteFile`, not a locale-sensitive CRT text stream, and arguments enter through
`wmain`; therefore a valid Windows Unicode command-line payload is encoded as
UTF-8 independently of the active console code page.

Invalid invocation exits 64. A missing or unwritable PID file exits 65, a
Unicode conversion failure exits 66, and an output failure exits 67. These are
fixture diagnostics, not experiment outcomes.

## Source and build

The entire fixture source is `process_fixture.c`. Build from this directory
with `build.cmd`, which invokes:

```text
C:\dev\z.exe gcc -std=c23 -Os -s -municode -DUNICODE -D_UNICODE -Wall -Wextra -Werror -Wl,--no-insert-timestamp process_fixture.c -o process_fixture.exe
```

The linker timestamp is disabled so repeated builds from identical source and
toolchain inputs produce the same executable bytes.

Toolchain recorded for this build:

- GCC 16.1.0, `gcc.exe (Rev5, Built by MSYS2 project)`
- target: `x86_64-w64-mingw32`
- compiler provisioned by `C:\dev\z.exe gcc`
- `C:\dev\z.exe` SHA-256:
  `fca7317e91cbb33bb202a82e52fad3f9dc04003a4bfb993488be91620a605763`
- resolved `gcc.exe` SHA-256:
  `f96a3bdb1d3a3967b309d75c7413399391e857b5be4cb17162572ed66f6772a0`
- resolved `ld.exe` SHA-256:
  `3b40b4869289cfde4d3e5da81f7da36227fb203f0dde178d77bbe5d439bf905e`

Build-input and artifact SHA-256 values:

- `process_fixture.c`:
  `0a35808cb0e6c669ec62b36efcfc2523d2a12dcbeac1bb7873374216a351f8ac`
- `build.cmd`:
  `ebc76f96e030adc78ee59bb6157991c3b6c9396b6c57beaf3ed560006647dec3`
- `process_fixture.exe` (19,456 bytes):
  `5fc03aae68145054d73ff94a51b508c2678ffccf3322fb4f1625518e439f6823`

Two consecutive final builds produced the recorded executable hash. Direct
checks cover exact UTF-8 bytes (including
spaces, quotes, backslashes, BMP and supplementary characters), exits 0 and
7, empty-output hang behavior, and exact PID-file contents in every mode.
