[CmdletBinding()]
param(
    [string]$Machteld,
    [string]$CacheRoot,
    [string]$MsysRoot,
    [switch]$SkipBuild,
    [switch]$PublicTls,
    [switch]$InteractivePty
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Machteld) { $Machteld = Join-Path $RepoRoot 'out\machteld.exe' }
if (-not $CacheRoot) { $CacheRoot = Join-Path $RepoRoot '.cache\deps' }
if (-not $MsysRoot) {
    if ($env:MSYS2_ROOT) { $MsysRoot = $env:MSYS2_ROOT }
    elseif (Test-Path -LiteralPath 'C:\msys64\usr\bin\bash.exe') { $MsysRoot = 'C:\msys64' }
}
if (-not $MsysRoot) { throw 'MSYS2 root not found; pass -MsysRoot or set MSYS2_ROOT' }

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Output $Machteld -CacheRoot $CacheRoot -MsysRoot $MsysRoot
    if ($LASTEXITCODE) { throw "build failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath $Machteld -PathType Leaf)) {
    throw "Machteld executable not found: $Machteld"
}

$OutputDir = Join-Path $RepoRoot 'out\test'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$gcc = Join-Path $MsysRoot 'ucrt64\bin\gcc.exe'
$env:PATH = "$(Join-Path $MsysRoot 'ucrt64\bin');$env:PATH"
$sqlite = Join-Path $CacheRoot 'sqlite'
$tclsh = Join-Path $CacheRoot 'prefix\bin\tclsh90s.exe'

function Compile-Fixture([string]$Source, [string]$Output, [string[]]$Extra = @()) {
    Write-Host "fixture $([IO.Path]::GetFileName($Source))"
    & $gcc -std=c23 -O2 -Wall -Wextra -Werror -municode $Source @Extra -o $Output
    if ($LASTEXITCODE) { throw "fixture compile failed: $Source" }
}
function Run-Test([string]$Name, [string[]]$Arguments) {
    Write-Host "`n== $Name =="
    & $Machteld @Arguments
    if ($LASTEXITCODE) { throw "$Name failed with exit code $LASTEXITCODE" }
}

$processFixture = Join-Path $OutputDir 'process_fixture.exe'
Compile-Fixture (Join-Path $RepoRoot 'test\fixtures\process_fixture.c') $processFixture

$httpFixture = Join-Path $OutputDir 'http_fixture.exe'
Compile-Fixture (Join-Path $RepoRoot 'test\fixtures\http_fixture.c') $httpFixture @('-lws2_32')

$lockFixture = Join-Path $OutputDir 'sqlite_lock_fixture.exe'
$sqliteObject = Join-Path $OutputDir 'sqlite3-test.o'
& $gcc -O2 -w -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c `
    (Join-Path $sqlite 'sqlite3.c') -o $sqliteObject
if ($LASTEXITCODE) { throw 'SQLite test object compile failed' }
Compile-Fixture (Join-Path $RepoRoot 'test\fixtures\sqlite_lock_fixture.c') $lockFixture `
    @('-I', $sqlite, $sqliteObject)

$cmdline = Join-Path $OutputDir 'cmdline_test.exe'
& $gcc -std=c23 -O2 -Wall -Wextra -Werror `
    '-I' (Join-Path $RepoRoot 'src') `
    (Join-Path $RepoRoot 'test\cmdline_test.c') (Join-Path $RepoRoot 'src\winjob_cmdline.c') -o $cmdline
if ($LASTEXITCODE) { throw 'cmdline fixture compile failed' }
& $cmdline
if ($LASTEXITCODE) { throw "cmdline golden vectors failed with exit code $LASTEXITCODE" }

$bareLeaf = ".machteld-entry-basekit-$PID-$([Guid]::NewGuid().ToString('n')).exe"
$bareHost = Join-Path $OutputDir $bareLeaf
$bareOwned = $false
try {
    & $tclsh (Join-Path $RepoRoot 'test\extract_basekit.tcl') $Machteld $bareHost
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $bareHost -PathType Leaf)) {
        throw "console basekit extraction failed with exit code $LASTEXITCODE"
    }
    $bareOwned = $true
    & (Join-Path $RepoRoot 'test\entry_test.ps1') `
        -Machteld $Machteld -ProcessFixture $processFixture -Bare $bareHost
    if ($LASTEXITCODE) { throw "entry tests failed with exit code $LASTEXITCODE" }
} finally {
    if ($bareOwned -and (Split-Path -Leaf $bareHost) -ceq $bareLeaf -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($bareHost)),
                [IO.Path]::GetFullPath($OutputDir)) -and
            (Test-Path -LiteralPath $bareHost -PathType Leaf)) {
        Remove-Item -LiteralPath $bareHost -Force -ErrorAction SilentlyContinue
    }
}
& (Join-Path $RepoRoot 'test\package_test.ps1') -Tclsh $tclsh
if ($LASTEXITCODE) { throw "package parser tests failed with exit code $LASTEXITCODE" }
& (Join-Path $RepoRoot 'test\reference_generator_test.ps1') -CacheRoot $CacheRoot -Tclsh $tclsh
if ($LASTEXITCODE) { throw "reference generator tests failed with exit code $LASTEXITCODE" }
& $tclsh (Join-Path $RepoRoot 'tools\check_reference.tcl')
if ($LASTEXITCODE) { throw "reference coverage checks failed with exit code $LASTEXITCODE" }

if ($PublicTls) { $env:MACHTELD_TEST_PUBLIC_TLS = '1' }
if ($InteractivePty) { $env:MACHTELD_TEST_PTY_IO = '1' }
try {
    Run-Test 'process' @((Join-Path $RepoRoot 'test\process_test.tcl'), $processFixture)
    Run-Test 'store' @((Join-Path $RepoRoot 'test\store_test.tcl'), $lockFixture)
    Run-Test 'macht' @((Join-Path $RepoRoot 'test\macht_test.tcl'))
    Run-Test 'csv' @((Join-Path $RepoRoot 'test\csv_test.tcl'))
    Run-Test 'native' @((Join-Path $RepoRoot 'test\native_test.tcl'), $httpFixture, $processFixture)
    Run-Test 'filesystem' @((Join-Path $RepoRoot 'test\filesystem_test.tcl'))
    Run-Test 'runtime services' @((Join-Path $RepoRoot 'test\runtime_test.tcl'))
    Run-Test 'embedded reference' @((Join-Path $RepoRoot 'test\reference_test.tcl'))
    Run-Test 'JSONTestSuite' @((Join-Path $RepoRoot 'test\json_test.tcl'))
    Run-Test 'wrap/basekits' @((Join-Path $RepoRoot 'test\wrap_test.tcl'))
} finally {
    if ($PublicTls) { Remove-Item Env:MACHTELD_TEST_PUBLIC_TLS -ErrorAction SilentlyContinue }
    if ($InteractivePty) { Remove-Item Env:MACHTELD_TEST_PTY_IO -ErrorAction SilentlyContinue }
}

Write-Host "`nALL TEST LANES PASSED"
