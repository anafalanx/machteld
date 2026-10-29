[CmdletBinding()]
param(
    [ValidateSet('fast','integration','packaging','native-validation','reference-generator','release')]
    [string[]]$Group = @('fast'),
    [string]$Machteld,
    [string]$CacheRoot,
    [string]$MsysRoot,
    [switch]$PublicTls,
    [switch]$InteractiveGui,
    [switch]$InteractivePty
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Machteld) { $Machteld = Join-Path $RepoRoot 'out\machteld.exe' }
if (-not $CacheRoot) { $CacheRoot = Join-Path $RepoRoot '.cache\deps' }
$Machteld = [IO.Path]::GetFullPath($Machteld)
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
$tclsh = Join-Path $CacheRoot 'prefix\bin\tclsh90s.exe'
$total = [Diagnostics.Stopwatch]::StartNew()
if (($PublicTls -or $InteractivePty) -and
    $Group -notcontains 'integration' -and $Group -notcontains 'release') {
    throw '-PublicTls and -InteractivePty require the integration or release group'
}

# No ordinary group rebuilds the runtime or regenerates documentation.
# Release is deliberately explicit and reconstructs before the full gate.
if ($Group -contains 'release') {
    if ($Group.Count -ne 1) { throw 'release must be selected alone' }
    & (Join-Path $PSScriptRoot 'build.ps1') -Output $Machteld -CacheRoot $CacheRoot -MsysRoot $MsysRoot
    if ($LASTEXITCODE) { throw "release build failed: $LASTEXITCODE" }
    $Group = @('fast','integration','packaging','native-validation','reference-generator')
}
$needsRuntime = $InteractiveGui -or @($Group | Where-Object { $_ -in @('fast','integration','packaging','native-validation') }).Count -gt 0
Write-Host "Source checkout: $RepoRoot; selected groups: $($Group -join ', ')"
if ($needsRuntime) {
    if (-not (Test-Path -LiteralPath $Machteld -PathType Leaf)) {
        throw "Executable missing: $Machteld. Build explicitly with tools/dev.tcl build."
    }
    $before = (Get-FileHash -LiteralPath $Machteld -Algorithm SHA256).Hash
    Write-Host "Testing existing executable: $Machteld"
    Write-Host "SHA-256: $before"
    & $Machteld --version
    if ($LASTEXITCODE) { throw 'cannot identify executable version' }
}

function Run-Checked([string]$Name, [string]$Program, [string[]]$Arguments) {
    Write-Host "`n== $Name =="
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $Program @Arguments
    if ($LASTEXITCODE) { throw "$Name failed with exit code $LASTEXITCODE" }
    Write-Host ('PASS {0} ({1:n2}s)' -f $Name, $timer.Elapsed.TotalSeconds)
}
function Runtime-Test([string]$Name, [string[]]$Extra = @()) {
    Run-Checked $Name $Machteld (@((Join-Path $RepoRoot "test\${Name}_test.tcl")) + $Extra)
}
function Tcl-Test([string]$Relative, [string[]]$Extra = @()) {
    Run-Checked $Relative $tclsh (@((Join-Path $RepoRoot $Relative)) + $Extra)
}
function Script-Test([string]$Relative, [string[]]$Extra = @()) {
    # A dedicated PS5 process also makes native exit status unambiguous.
    $prior = $env:PSModulePath
    try {
        Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue
        Run-Checked $Relative powershell.exe (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot $Relative)) + $Extra)
    } finally { $env:PSModulePath = $prior }
}
function Set-MachteldTestEnvironment([bool]$Tls, [bool]$Pty, [bool]$Gui = $false, [string]$CompilerBin = '') {
    $prior = @{}
    $prior['PATH'] = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    foreach ($name in @('MACHTELD_TEST_PUBLIC_TLS','MACHTELD_TEST_PTY_IO','MACHTELD_WRAP_GUI_INTERACTIVE',
            'MACHTELD_TEST_WORKER_SOURCE','MACHTELD_TEST_PIDFILE')) {
        $prior[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if ($Tls) { $env:MACHTELD_TEST_PUBLIC_TLS = '1' }
    if ($Pty) { $env:MACHTELD_TEST_PTY_IO = '1' }
    if ($Gui) { $env:MACHTELD_WRAP_GUI_INTERACTIVE = '1' }
    if ($CompilerBin) { $env:PATH = $CompilerBin + [IO.Path]::PathSeparator + $prior['PATH'] }
    return $prior
}
function Restore-MachteldTestEnvironment([hashtable]$Prior) {
    foreach ($entry in $Prior.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}
function Invoke-MachteldTestEnvironment([bool]$Tls, [bool]$Pty, [bool]$Gui, [string]$CompilerBin, [scriptblock]$Action) {
    $prior = Set-MachteldTestEnvironment $Tls $Pty $Gui $CompilerBin
    try { & $Action } finally { Restore-MachteldTestEnvironment $prior }
}

$OutputDir = Join-Path $RepoRoot 'out\test'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$compilerBin = ''
if ($Group -contains 'integration' -or $Group -contains 'packaging' -or $Group -contains 'native-validation') {
    . (Join-Path $PSScriptRoot 'toolchain.ps1')
    $MsysRoot = Resolve-MachteldMsysRoot $MsysRoot $RepoRoot
    $gcc = Join-Path $MsysRoot 'ucrt64\bin\gcc.exe'
    $compilerBin = Join-Path $MsysRoot 'ucrt64\bin'
    $processFixture = Join-Path $OutputDir 'process_fixture.exe'
}
# Interactive/network acceptance is opt-in to this invocation, not inherited
# from the shell that happens to launch an ordinary background test group.
# Fixture source overlays and PID-file destinations must not be inherited
# either: the suite tests the candidate's embedded code and owns its outputs.
# Individual tests may deliberately set their own scoped fixture variables.
Invoke-MachteldTestEnvironment ([bool]$PublicTls) ([bool]$InteractivePty) ([bool]$InteractiveGui) $compilerBin {
    if ($compilerBin) {
        Run-Checked 'process fixture' $gcc @('-std=c23','-O2','-Wall','-Wextra','-Werror','-municode',
            (Join-Path $RepoRoot 'test\fixtures\process_fixture.c'),'-o',$processFixture)
    }
    foreach ($selection in $Group) {
        Write-Host "`nTEST GROUP: $selection"
        switch ($selection) {
            fast {
                Tcl-Test 'tools\check_reference.tcl'
                Tcl-Test 'tools\check_version.tcl'
                Tcl-Test 'test\check_version_test.tcl'
                Tcl-Test 'test\build_identity_test.tcl'
                Script-Test 'tools\reference_serializer_smoke.ps1' @('-Tclsh',$tclsh)
                Script-Test 'test\test_groups_test.ps1'
                Runtime-Test filesystem
                Runtime-Test runtime
                Runtime-Test protocol
                Runtime-Test gui_model
                Runtime-Test reference
                Runtime-Test documentation_examples
                Runtime-Test json
                Runtime-Test native_adversarial
                Runtime-Test native_filesystem
            }
            integration {
                $httpFixture = Join-Path $OutputDir 'http_fixture.exe'
                Run-Checked 'HTTP fixture' $gcc @('-std=c23','-O2','-Wall','-Wextra','-Werror','-municode',
                    (Join-Path $RepoRoot 'test\fixtures\http_fixture.c'),'-lws2_32','-o',$httpFixture)
                $sqlite = Join-Path $CacheRoot 'sqlite'
                $sqliteObject = Join-Path $OutputDir 'sqlite3-test.o'
                Run-Checked 'SQLite fixture object' $gcc @('-O2','-w','-DSQLITE_THREADSAFE=1','-DSQLITE_OMIT_LOAD_EXTENSION','-c',
                    (Join-Path $sqlite 'sqlite3.c'),'-o',$sqliteObject)
                $lockFixture = Join-Path $OutputDir 'sqlite_lock_fixture.exe'
                Run-Checked 'SQLite lock fixture' $gcc @('-std=c23','-O2','-Wall','-Wextra','-Werror','-municode',
                    (Join-Path $RepoRoot 'test\fixtures\sqlite_lock_fixture.c'),'-I',$sqlite,$sqliteObject,'-o',$lockFixture)
                $cmdline = Join-Path $OutputDir 'cmdline_test.exe'
                Run-Checked 'command-line fixture' $gcc @('-std=c23','-O2','-Wall','-Wextra','-Werror','-I',(Join-Path $RepoRoot 'src'),
                    (Join-Path $RepoRoot 'test\cmdline_test.c'),(Join-Path $RepoRoot 'src\winjob_cmdline.c'),'-o',$cmdline)
                Run-Checked 'command-line golden vectors' $cmdline @()
                Tcl-Test 'test\dev_cache_test.tcl'
                Script-Test 'test\reference_cache_test.ps1'
                Script-Test 'test\reference_recipe_test.ps1'
                Script-Test 'test\reference_orchestration_test.ps1'
                Runtime-Test process @($processFixture)
                Runtime-Test store @($lockFixture)
                Runtime-Test native @($httpFixture,$processFixture)
                Runtime-Test streaming_bounds @($processFixture)
            }
            packaging {
                Tcl-Test 'test\build_identity_test.tcl' @($Machteld)
                $bareLeaf = '.machteld-entry-basekit-' + [Guid]::NewGuid().ToString('n') + '.exe'
                $bareHost = Join-Path $OutputDir $bareLeaf
                try {
                    Tcl-Test 'test\extract_basekit.tcl' @($Machteld,$bareHost)
                    Script-Test 'test\entry_test.ps1' @('-Machteld',$Machteld,'-ProcessFixture',$processFixture,'-Bare',$bareHost)
                } finally {
                    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($bareHost)) -eq $OutputDir -and
                        [IO.Path]::GetFileName($bareHost) -ceq $bareLeaf) { Remove-Item -LiteralPath $bareHost -Force -ErrorAction SilentlyContinue }
                }
                Script-Test 'test\package_test.ps1' @('-Tclsh',$tclsh)
                Script-Test 'test\version_resource_test.ps1' @('-Machteld',$Machteld,'-CacheRoot',$CacheRoot)
                Runtime-Test wrap
                Runtime-Test documentation_examples @('--packaging')
                Runtime-Test wrap_inventory
                Script-Test 'test\app_identity_test.ps1' @('-Machteld',$Machteld)
                Runtime-Test examples_package @($MsysRoot,(Join-Path $CacheRoot 'prefix'))
            }
            native-validation {
                $nativeProbe = Join-Path $OutputDir 'native_probe.dll'
                Run-Checked 'native telemetry fixture' $gcc @('-std=c23','-O2','-Wall','-Wextra','-Werror',
                    '-shared','-DUSE_TCL_STUBS','-I',(Join-Path $CacheRoot 'prefix\include'),
                    (Join-Path $RepoRoot 'test\fixtures\native_probe.c'),
                    (Join-Path $CacheRoot 'prefix\lib\libtclstub.a'),'-lpsapi','-o',$nativeProbe)
                Runtime-Test native_adversarial
                Runtime-Test native_filesystem
                Runtime-Test native_lifecycle @($nativeProbe,$processFixture)
                Runtime-Test native_scaling @($nativeProbe,$processFixture)
                Script-Test 'tools\native-analysis.ps1' @('-CacheRoot',$CacheRoot,'-MsysRoot',$MsysRoot)
            }
            reference-generator {
                Script-Test 'test\reference_generator_test.ps1' @('-CacheRoot',$CacheRoot,'-Tclsh',$tclsh)
            }
        }
    }
    if ($InteractiveGui) { Runtime-Test gui_widget }
}
if ($needsRuntime) {
    $after = (Get-FileHash -LiteralPath $Machteld -Algorithm SHA256).Hash
    if ($before -cne $after) { throw 'tested executable changed during the test run' }
    Write-Host "Verified tested executable remained SHA-256 $after"
}
Write-Host ('ALL SELECTED TEST GROUPS PASSED ({0:n2}s)' -f $total.Elapsed.TotalSeconds)
