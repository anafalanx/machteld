[CmdletBinding()]
param(
    [string]$Output,
    [string]$CacheRoot,
    [string]$MsysRoot,
    [switch]$SkipBootstrap
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Output) { $Output = Join-Path $RepoRoot 'out\machteld.exe' }
if (-not $CacheRoot) { $CacheRoot = Join-Path $RepoRoot '.cache\deps' }
if (-not $MsysRoot) {
    if ($env:MSYS2_ROOT) { $MsysRoot = $env:MSYS2_ROOT }
    elseif (Test-Path -LiteralPath 'C:\msys64\usr\bin\bash.exe') { $MsysRoot = 'C:\msys64' }
}
if (-not $MsysRoot) { throw 'MSYS2 root not found; pass -MsysRoot or set MSYS2_ROOT' }

$bootstrap = Join-Path $PSScriptRoot 'bootstrap.ps1'
$bootstrapArgs = @{ CacheRoot = $CacheRoot; MsysRoot = $MsysRoot }
if ($SkipBootstrap) { $bootstrapArgs.VerifyOnly = $true }
& $bootstrap @bootstrapArgs
if ($LASTEXITCODE) { throw "dependency bootstrap failed with exit code $LASTEXITCODE" }

$prefix = Join-Path $CacheRoot 'prefix'
$tclsh = @((Join-Path $prefix 'bin\tclsh90s.exe'), (Join-Path $prefix 'bin\tclsh90.exe')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $tclsh) { throw "dependency prefix has no static tclsh: $prefix" }

$env:MACHTELD_DEPS_ROOT = [IO.Path]::GetFullPath($CacheRoot)
$env:MACHTELD_GCC = Join-Path $MsysRoot 'ucrt64\bin\gcc.exe'
$env:MACHTELD_STRIP = Join-Path $MsysRoot 'ucrt64\bin\strip.exe'
& $tclsh (Join-Path $PSScriptRoot 'build.tcl') ([IO.Path]::GetFullPath($Output))
if ($LASTEXITCODE) { throw "build failed with exit code $LASTEXITCODE" }
