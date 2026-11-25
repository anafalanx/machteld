---
id: machteld/command/lock
type: command
title: lock
summary: Try to take exclusive ownership of a shared resource using a persistent Windows coordination file.
commands: lock, lock try, lock release
---

# lock

## Synopsis

```tcl
lock try path
lock release token
```

## Arguments and options

Choose one dedicated coordination file for every participant that shares a
resource. Its parent directory must already exist. A relative path resolves
from the caller's working directory.

## Results

`try` returns an opaque token on acquisition or an empty string on lock
contention. `release` consumes the token and returns an empty string.

## Errors

The error-code prefix is `MACHTELD LOCK`. Codes are `badvalue`, `nohandle`,
`oserror`, and `usage`. An unopened path or filesystem error raises an error.

## Lifetime and timeouts

A contending caller returns immediately. Opening the path is synchronous.
Locks are released by explicit release, interpreter deletion, or process exit.
After abrupt process termination Windows may need a short interval for cleanup.

## Examples

```tcl
set token [lock try [file join $appDirectory updater.lock]]
if {$token eq ""} { return }
try {
    installPendingUpdate
} finally {
    lock release $token
}
```

## Constraints

Use a writable, ordinary file on a native filesystem that supports Windows
byte-range locking. `try` creates an absent file and preserves its contents
when it exists. Leave this file in place across releases. Only its first byte
is locked, including when the file is empty. Every participant must use the
same file to coordinate access to any other application data. A token belongs
to its creating interpreter and is suitable for one release.

## Subcommands

<a id="try"></a>
### try

#### Synopsis

`lock try path`

#### Arguments and options

Pass a coordination file in an existing directory controlled by the application.

#### Results

A token means this caller acquired ownership. An empty string means the byte
range is already locked, including when the caller holds another token for it.

#### Errors

`badvalue` covers an empty path, embedded NUL, invalid Unicode or virtual
filesystem path. `oserror` includes missing parents, open failures, file-sharing
errors and unsupported locking. Invalid argument counts raise `usage`.

#### Lifetime and timeouts

This call never waits for the current lock holder. The handle has no
inheritance and denies delete sharing while held.

#### Examples

`set token [lock try [file join $state profile.lock]]`

#### Constraints

Use an ordinary coordination file. Application code determines whether to show
a busy status or schedule a retry.

#### See also

`machteld/command/lock#release`.

<a id="release"></a>
### release

#### Synopsis

`lock release token`

#### Arguments and options

Pass the token previously acquired in this interpreter.

#### Results

Returns an empty string and leaves the coordination file in place.

#### Errors

An unknown, foreign or already released token raises `nohandle`. A Windows
cleanup error raises `oserror`. The token is consumed once cleanup begins.

#### Lifetime and timeouts

Releases the kernel lock and closes its handle in the same call.

#### Examples

`lock release $token`

#### Constraints

Use `try ... finally` when the protected work can raise an error.

#### See also

`machteld/command/lock#try`.

## See also

`machteld/command/canon`, `machteld/command/store`.
