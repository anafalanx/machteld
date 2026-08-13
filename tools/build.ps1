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
$outputFull = [IO.Path]::GetFullPath($Output)
$outputParent = [IO.Path]::GetDirectoryName($outputFull)
if (-not $outputParent) { throw "output has no parent directory: $outputFull" }
[IO.Directory]::CreateDirectory($outputParent) | Out-Null

# The final package and every linker intermediate get invocation-owned names.
# The package candidate is beside the requested output, so publication is one
# same-volume rename even when -Output is named like one of the bare hosts.
do {
    $buildId = [Guid]::NewGuid().ToString('n')
    $candidateLeaf = ".machteld-build-$buildId.exe"
    $workLeaf = ".machteld-build-$buildId.work"
    $candidate = Join-Path $outputParent $candidateLeaf
    $buildRoot = Join-Path $outputParent $workLeaf
} while ((Test-Path -LiteralPath $candidate) -or
         (Test-Path -LiteralPath $buildRoot))

$workReady = $false
$candidateReady = $false
$reference = Join-Path $buildRoot 'reference'
$priorReferenceRoot = $env:MACHTELD_REFERENCE_ROOT
$priorBuildRoot = $env:MACHTELD_BUILD_ROOT
try {
    New-Item -ItemType Directory -Path $buildRoot | Out-Null
    $buildRootItem = Get-Item -LiteralPath $buildRoot -Force
    if (($buildRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "invocation build directory must not be a reparse point: $buildRoot"
    }
    $workReady = $true
    $env:MACHTELD_REFERENCE_ROOT = $reference
    $env:MACHTELD_BUILD_ROOT = $buildRoot

    # The generator publishes into the absent reference path inside this
    # invocation's work directory.
    & (Join-Path $PSScriptRoot 'generate-reference.ps1') `
        -CacheRoot $CacheRoot -Output $reference -Tclsh $tclsh
    if ($LASTEXITCODE) { throw "reference generation failed with exit code $LASTEXITCODE" }
    & $tclsh (Join-Path $PSScriptRoot 'build.tcl') $candidate
    if ($LASTEXITCODE) { throw "build failed with exit code $LASTEXITCODE" }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "build produced no publication candidate: $candidate"
    }
    $candidateItem = Get-Item -LiteralPath $candidate -Force
    if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "build candidate must not be a reparse point: $candidate"
    }
    $candidateReady = $true

    # This helper has no delete/rename fallback: MoveFileExW with replacement
    # and write-through flags is the sole release-name publication operation.
    & (Join-Path $PSScriptRoot 'publish-output.ps1') `
        -Candidate $candidate -Output $outputFull
} finally {
    if ($null -eq $priorReferenceRoot) {
        Remove-Item Env:\MACHTELD_REFERENCE_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MACHTELD_REFERENCE_ROOT = $priorReferenceRoot
    }
    if ($null -eq $priorBuildRoot) {
        Remove-Item Env:\MACHTELD_BUILD_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MACHTELD_BUILD_ROOT = $priorBuildRoot
    }

    # Delete only paths that this invocation both named and successfully
    # populated. An unexpected path or reparse point is left untouched.
    if ($candidateReady -and
            (Split-Path -Leaf $candidate) -ceq $candidateLeaf -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($candidate)),
                [IO.Path]::GetFullPath($outputParent)) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $cleanupCandidate = Get-Item -LiteralPath $candidate -Force
        if (($cleanupCandidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        }
    }
    if ($workReady -and (Split-Path -Leaf $buildRoot) -ceq $workLeaf -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($buildRoot)),
                [IO.Path]::GetFullPath($outputParent)) -and
            (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        $cleanupRoot = Get-Item -LiteralPath $buildRoot -Force
        if (($cleanupRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
