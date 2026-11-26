---
id: machteld/command/wrap
type: command
title: wrap
summary: Build a standalone Windows console or GUI executable with its own file properties and icon.
commands: wrap
---

# wrap

## Synopsis

```tcl
wrap input -o output.exe ?--console|--gui? ?--plan?
wrap directory -o output.exe ?--entry relativePath? ?--manifest file? ?--console|--gui? ?--plan?
wrap archive.machteld -o output.exe ?--manifest app.dict? ?--console|--gui? ?--plan?
```

The full distribution executable accepts `machteld.exe wrap` with the same arguments.

## Arguments and options

Use an opted-in script, a dedicated directory with a root `main.tcl`, a project dictionary selecting the entry and files, or an existing verified `.machteld` archive. A project dictionary can supply explicit Windows branding. When wrapping a `.machteld` file, use `--manifest app.dict` to apply the same branding to the archived app. Its entry and file list must match the archive. The packager reads the scripts and assets from the archive, so the original source directory can be absent. `--console` is the default. Use `--gui` for a Windows GUI application. The resulting executable receives its own command-line arguments, including `--help` and `--docs`. The `--machteld-wrapped-generation` prefix is reserved for `app launch`.

Put the application's Windows properties in the project's optional `metadata` dictionary. Supply `name` and `version` together. Optional fields are `description`, `author`, `publisher`, `copyright` and `icon`. The version has one to four decimal components, each in the range 0–65535. The fixed Windows file and product version fields use four components. The output basename supplies the original filename in Windows Properties. `name` sets Product name, `description` sets File description, and `publisher` sets Company name. Without a `metadata` dictionary, the output filename stem supplies the name and description, the version is `0.0.0.0`, publisher text is empty, and Windows supplies its generic application icon.

A relative `icon` path resolves beside the project or explicit manifest. Windows stores the images in that `.ico` file as executable resources. Include the icon in `files` as well if the running Tcl application needs the original file. Tk uses the executable icon as the default for the app’s windows. A Tcl app can set a different window icon using `wm iconphoto` or `wm iconbitmap`.

## Results

Returns the absolute path to the published executable. `--plan` returns a Tcl dictionary with `schema`, `entry`, `host` (`console` or `gui`), `files`, `metadata`, `runtime` and `with_docs` (always `0`). It checks the selection without writing an executable. The result contains the app, its selected assets, Tcl/Tk, Machteld services and required license notices. The offline reference database stays in the full host. The app can supply its own help through its file inventory.

## Errors

Failures use `MACHTELD WRAP` error codes. `usage` identifies invalid options, `badvalue` covers invalid properties or icons, `notfound` identifies missing inputs, and `inventory` identifies inconsistent archive contents. Entry checks distinguish `optin`, `encoding`, `syntax` and `version`. `oserror` reports a filesystem or Windows failure, and `unsupported` means the host cannot build wrapped applications. The Beta 1 `--with-docs` switch is unsupported. Signing, certificate selection and timestamping are external to Machteld. The publisher text in Windows Properties is supplied by the app author.

## Lifetime and timeouts

Wrapping is synchronous. Let outstanding source edits finish before starting a build. The packager stages and verifies the candidate before publishing the output. A wrapped executable embeds the runtime used to build it. Rebuild and distribute the application to give its users an updated runtime.

## Examples

Save the following UTF-8 project dictionary as `app.dict`.

```tcl
schema 1
entry main.tcl
files {main.tcl lib/model.tcl assets/about.txt}
metadata {
    name {Field Notes}
    version 2.4.1
    description {Field Notes desktop application}
    publisher {North Workshop}
    copyright {Copyright North Workshop}
    icon artwork/field-notes.ico
}
```

```text
machteld.exe wrap app.dict -o FieldNotes.exe --gui --plan
machteld.exe wrap app.dict -o FieldNotes.exe --gui
```

## Constraints

Use the full `machteld.exe` to build applications and query the offline manuals. Use up to 1,024 UTF-16 code units for descriptive fields. An `.ico` file can contain 1–256 PNG or Windows bitmap images with dimensions of 1–256 pixels. The file size limit is 16 MiB. Choose an output outside a directory being packaged. Distribute the resulting executable on its own.

## See also

`machteld/guide/packaging`, `machteld/application/host`, `machteld/command/app`.
