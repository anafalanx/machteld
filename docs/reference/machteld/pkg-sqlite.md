---
id: machteld/package/sqlite
type: package
title: Verified SQLite backups
summary: Create an independently verified snapshot of an open SQLite database at a new path.
commands: machteld::sqlite, ::machteld::sqlite::backup, sqlite backup, machteld::sqlite::backup
---

# Verified SQLite backups

## Usage

`package require machteld::sqlite 1.0` provides `::machteld::sqlite::backup connection destination`. Pass an open SQLite Tcl command and a native destination path whose parent exists. The result is the normalized path of the published database.

The command copies the live main database using SQLite's backup API into a private file beside the destination. It converts that copy to a self-contained rollback-journal database, then reopens it read-only and runs `PRAGMA integrity_check`. Schemas containing `CHECK` also receive an integrity check on the staging connection in query-only mode. Application-defined functions and collations used in verification must be available on a fresh connection.

## Errors and lifetime

One create-only Windows rename publishes the verified file. If the destination exists or another writer creates it first, its contents survive and the caller receives `MACHTELD SQLITE exists`. A failed verification raises `MACHTELD SQLITE verify`. Invalid connection names and paths can raise `connection` and `path` in the same error domain. SQLite and filesystem errors propagate. The helper closes its own connections and cleans up its staged files. The caller retains the original connection.

Backup runs synchronously with no operation-wide timeout. A GUI can run it on a separately opened worker connection. The application chooses when to back up, how long to retain files and which copy to restore.

## Example

```tcl
package require machteld::sqlite
sqlite3 backupSource $database -readonly 1 -create 0
try {
    set saved [::machteld::sqlite::backup backupSource $newDestination]
    puts $saved
} finally {backupSource close}
```

For typed numbered parameters, foreign-key enforcement, defensive mode, FTS5 and the plain connection API, use `machteld/package/sqlite3`.
