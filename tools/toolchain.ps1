# tools/toolchain.ps1 -- locate the MSYS2 root the dependency lock describes.
#
# Dot-sourced by bootstrap.ps1, build.ps1, and test.ps1 so the three scripts
# search in one order: an explicit -MsysRoot, MSYS2_ROOT, Z_MSYS2, the
# conventional C:\msys64, then the estate layout beside the repository that
# tools/dev.tcl also knows. The lock verifies the toolchain by hash afterwards,
# so a wrong guess fails loudly rather than building with a stranger's compiler.

function Resolve-MachteldMsysRoot([string]$Requested, [string]$RepoRoot) {
    if ($Requested) { return [IO.Path]::GetFullPath($Requested) }
    if ($env:MSYS2_ROOT) { return [IO.Path]::GetFullPath($env:MSYS2_ROOT) }
    if ($env:Z_MSYS2) { return [IO.Path]::GetFullPath($env:Z_MSYS2) }
    if (Test-Path -LiteralPath 'C:\msys64\usr\bin\bash.exe') { return 'C:\msys64' }
    $estate = Join-Path (Split-Path -Parent $RepoRoot) '.z\r\msys2'
    if (Test-Path -LiteralPath (Join-Path $estate 'usr\bin\bash.exe')) {
        return [IO.Path]::GetFullPath($estate)
    }
    throw 'MSYS2 root not found; pass -MsysRoot or set MSYS2_ROOT'
}
