---
id: machteld/command/cli
type: command
title: cli
summary: Parse a tool's command line and generate usage from one declarative Tcl dict.
commands: cli, cli parse, cli usage, cli duration
---

# cli

## Synopsis

```tcl
cli parse argv spec
cli usage spec ?name?
cli duration value
```

## Arguments and options

`spec` is a dict from declared name to an attribute dict. Names beginning `--`
are program options; other names are positional in declaration order. Attributes
are the closed set `type`, `default`, `min`, `max`, `choices`, `help`, and
`required`. Types are `string` (default), `int`, and `flag`. `min`/`max` require
`int`; positional flags are invalid. The parser always reserves `--help`.

## Results

`parse` returns a dict keyed by option name without its leading `--`, plus
positionals and always `help` (`0` or `1`). An absent entry uses its declared
default; without one, a flag is `0` and another value is empty. `usage` returns
formatted text. `duration` returns integer milliseconds.

## Errors

Raised codes are `CLI badvalue` for an invalid author specification and
`CLI usage` for a bad invocation or command line. A parse usage message includes
generated usage text. The command never prints or exits.

## Lifetime and timeouts

All subcommands are pure synchronous transformations. `duration` parses a value;
it does not wait.

## Examples

```tcl
set spec {
    --jobs {type int default 4 min 1 max 64 help "parallel workers"}
    --all  {type flag help "include hidden entries"}
    path   {type string required 1 help "input path"}
}
set options [cli parse $argv $spec]
if {[dict get $options help]} { puts [cli usage $spec mytool]; exit }
```

## Constraints

Options use double hyphens because they belong to the generated program, while
Machteld palette options use one. There is no option abbreviation, bundling, or
repeat/variadic positional declaration. `--` ends option parsing.

## Subcommands

<a id="parse"></a>
### parse

#### Synopsis

`cli parse argv spec`

#### Arguments and options

`argv` is a Tcl list. Flags take no value; other options take the next word.
Positionals bind in spec insertion order. `required` may apply to options or
positionals. `--help` waives missing required values but not malformed supplied
values or unexpected extras.

#### Results

Returns one normalized result dict and never performs I/O.

#### Errors

Invalid spec is `CLI badvalue`; unknown/missing/mistyped input is `CLI usage`.

#### Lifetime and timeouts

Pure parse with no retained state.

#### Examples

`set opts [cli parse $argv $spec]`

#### Constraints

`--name` and positional `name` cannot coexist because both map to one dict key.

#### See also

`machteld/command/cli#usage`.

<a id="usage"></a>
### usage

#### Synopsis

`cli usage spec ?name?`

#### Arguments and options

`name` defaults to the executable's root name. Help, defaults, ranges, and
choices are rendered from the validated specification.

#### Results

Returns multiline usage text including the implicit `--help` option.

#### Errors

An invalid specification reports `CLI badvalue`.

#### Lifetime and timeouts

Pure formatting.

#### Examples

`puts [cli usage $spec analyzer]`

#### Constraints

Formatting is stable for humans but should not be parsed as structured metadata;
retain the original Tcl spec for tooling.

#### See also

`machteld/command/cli#parse`.

<a id="duration"></a>
### duration

#### Synopsis

`cli duration value`

#### Arguments and options

Accepts digits followed by exactly `ms`, `s`, `m`, or `h`. The converted value
must be from `0` through `4294967294` milliseconds; `4294967295` is Win32's
reserved infinite-wait sentinel and is not a finite duration.

#### Results

Returns integer milliseconds.

#### Errors

Malformed/out-of-range input reports `CLI badvalue`; wrong arity is `CLI usage`.

#### Lifetime and timeouts

Parses only; does not sleep.

#### Examples

`set milliseconds [cli duration 2m]`

#### Constraints

No sign, decimal point, whitespace, bare number, or value above
`4294967294ms` is accepted.

#### See also

`machteld/guide/contract`.

## See also

`machteld/command/log`, `machteld/guide/contract`.
