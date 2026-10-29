[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\tools\test.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($path), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'test driver does not parse' }
# Execute only the actual production environment functions, not the driver.
foreach ($name in @('Set-MachteldTestEnvironment','Restore-MachteldTestEnvironment','Invoke-MachteldTestEnvironment')) {
    $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name}, $false)
    if ($null -eq $definition) { throw "missing production function $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$originalTls = $env:MACHTELD_TEST_PUBLIC_TLS
$originalPty = $env:MACHTELD_TEST_PTY_IO
$originalGui = $env:MACHTELD_WRAP_GUI_INTERACTIVE
$originalPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
$fixtureVariables = @('MACHTELD_TEST_WORKER_SOURCE','MACHTELD_TEST_PIDFILE')
$originalFixtureVariables = @{}
foreach ($name in $fixtureVariables) {
    $originalFixtureVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$checks = 0
function Check([bool]$Pass,[string]$Label) {
    if (-not $Pass) { throw "FAIL $Label" }; $script:checks++; Write-Host "ok $Label"
}
try {
    $env:MACHTELD_TEST_PUBLIC_TLS = '1'; $env:MACHTELD_TEST_PTY_IO = '1'
    $env:MACHTELD_WRAP_GUI_INTERACTIVE = '1'
    $saved = Set-MachteldTestEnvironment $false $false
    Check (-not $env:MACHTELD_TEST_PUBLIC_TLS -and -not $env:MACHTELD_TEST_PTY_IO) 'ordinary groups clear inherited interactive/network opt-ins'
    Check (-not $env:MACHTELD_WRAP_GUI_INTERACTIVE) 'ordinary packaging clears inherited visible-GUI opt-in'
    Restore-MachteldTestEnvironment $saved
    Check ($env:MACHTELD_TEST_PUBLIC_TLS -ceq '1' -and $env:MACHTELD_TEST_PTY_IO -ceq '1') 'original caller opt-ins are restored'
    Check ($env:MACHTELD_WRAP_GUI_INTERACTIVE -ceq '1') 'original caller GUI opt-in is restored'
    $saved = Set-MachteldTestEnvironment $true $false
    Check ($env:MACHTELD_TEST_PUBLIC_TLS -ceq '1' -and -not $env:MACHTELD_TEST_PTY_IO) 'TLS flag enables only the requested acceptance lane'
    Restore-MachteldTestEnvironment $saved
    $saved = Set-MachteldTestEnvironment $false $false $true
    Check ($env:MACHTELD_WRAP_GUI_INTERACTIVE -ceq '1' -and -not $env:MACHTELD_TEST_PUBLIC_TLS -and -not $env:MACHTELD_TEST_PTY_IO) 'GUI flag enables only the requested acceptance lane'
    Restore-MachteldTestEnvironment $saved
    $saved = Set-MachteldTestEnvironment $false $true
    Check (-not $env:MACHTELD_TEST_PUBLIC_TLS -and $env:MACHTELD_TEST_PTY_IO -ceq '1') 'PTY flag enables only the requested acceptance lane'
    Restore-MachteldTestEnvironment $saved
    Remove-Item Env:MACHTELD_TEST_PUBLIC_TLS, Env:MACHTELD_TEST_PTY_IO -ErrorAction SilentlyContinue
    $saved = Set-MachteldTestEnvironment $true $true
    Check ($env:MACHTELD_TEST_PUBLIC_TLS -ceq '1' -and $env:MACHTELD_TEST_PTY_IO -ceq '1') 'explicit flags may enable both acceptance lanes'
    Restore-MachteldTestEnvironment $saved
    Check (-not (Test-Path Env:MACHTELD_TEST_PUBLIC_TLS) -and -not (Test-Path Env:MACHTELD_TEST_PTY_IO)) 'initially absent flags remain absent after restoration'

    # These paths are inert sentinel values; do not create files or execute an
    # overlay. Exercise the production guard used by every test group instead.
    $fixtureSentinels = @{
        MACHTELD_TEST_WORKER_SOURCE = 'C:\machteld environment fixture\worker source.tcl'
        MACHTELD_TEST_PIDFILE = 'C:\machteld environment fixture\caller pid.txt'
    }
    foreach ($name in $fixtureVariables) {
        [Environment]::SetEnvironmentVariable($name, $fixtureSentinels[$name], 'Process')
    }
    Invoke-MachteldTestEnvironment $false $false $false '' {
        foreach ($name in $fixtureVariables) {
            Check ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process') -and
                -not (Test-Path -LiteralPath "Env:$name")) "ordinary groups clear inherited $name"
            [Environment]::SetEnvironmentVariable($name, 'test-owned override', 'Process')
        }
    }
    foreach ($name in $fixtureVariables) {
        Check ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq $fixtureSentinels[$name]) "successful scope restores caller $name exactly"
    }
    $fixtureFailed = $false
    try {
        Invoke-MachteldTestEnvironment $true $true $true '' {
            foreach ($name in $fixtureVariables) {
                Check ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process')) "acceptance opt-ins do not enable inherited $name"
                [Environment]::SetEnvironmentVariable($name, 'failing test-owned override', 'Process')
            }
            throw 'intentional fixture environment failure'
        }
    } catch {
        $fixtureFailed = $_.Exception.Message -ceq 'intentional fixture environment failure'
    }
    Check $fixtureFailed 'fixture failure propagates through the environment guard'
    foreach ($name in $fixtureVariables) {
        Check ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq $fixtureSentinels[$name]) "failed scope restores caller $name exactly"
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    foreach ($failAction in @($false, $true)) {
        $absentFailed = $false
        try {
            Invoke-MachteldTestEnvironment $false $false $false '' {
                foreach ($name in $fixtureVariables) {
                    Check ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process')) "initially absent $name stays absent inside scope (failure=$failAction)"
                    [Environment]::SetEnvironmentVariable($name, 'temporary test-owned override', 'Process')
                }
                if ($failAction) { throw 'intentional absent fixture failure' }
            }
        } catch {
            $absentFailed = $_.Exception.Message -ceq 'intentional absent fixture failure'
            if (-not $absentFailed) { throw }
        }
        Check ($absentFailed -eq $failAction) "initially absent fixture scope preserves completion (failure=$failAction)"
        foreach ($name in $fixtureVariables) {
            Check ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process') -and
                -not (Test-Path -LiteralPath "Env:$name")) "initially absent $name is removed again (failure=$failAction)"
        }
    }

    Invoke-MachteldTestEnvironment $false $false $false '' {
        Check ($env:PATH -ceq $originalPath) 'non-compiling groups leave PATH unchanged'
    }
    $compilerBin = 'C:\machteld environment fixture\bin'
    Invoke-MachteldTestEnvironment $false $false $false $compilerBin {
        Check ($env:PATH -ceq ($compilerBin + [IO.Path]::PathSeparator + $originalPath)) 'fixture compiler directory is prepended only within the test scope'
    }
    Check ($env:PATH -ceq $originalPath) 'successful fixture scope restores the caller PATH exactly'
    $failed = $false
    try {
        Invoke-MachteldTestEnvironment $true $true $true $compilerBin { throw 'intentional compiler failure' }
    } catch {
        $failed = $_.Exception.Message -ceq 'intentional compiler failure'
    }
    Check $failed 'fixture compiler failure propagates to the caller'
    Check ($env:PATH -ceq $originalPath) 'fixture compiler failure restores the caller PATH exactly'
    Check (-not $env:MACHTELD_TEST_PUBLIC_TLS -and -not $env:MACHTELD_TEST_PTY_IO -and $env:MACHTELD_WRAP_GUI_INTERACTIVE -ceq '1') 'fixture compiler failure restores all caller opt-ins'
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    Invoke-MachteldTestEnvironment $false $false $false $compilerBin {}
    Check ($null -eq [Environment]::GetEnvironmentVariable('PATH', 'Process')) 'an initially absent PATH stays absent after restoration'

    # The actual initial fixture invocation must remain inside the guarded scope.
    $invocation = $ast.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-MachteldTestEnvironment'}, $false)
    Check ($null -ne $invocation -and $invocation.Extent.Text.Contains("Run-Checked 'process fixture'")) 'the production fixture compilation uses the tested restoration scope'
    $driverText = $ast.Extent.Text
    Check ($driverText.Contains("'native-validation'")) 'native validation is an explicit selectable group'
    Check ($driverText.Contains("@('fast','integration','packaging','native-validation','reference-generator')")) 'release includes native validation'
    Check ($invocation.Extent.Text.Contains("Runtime-Test native_lifecycle") -and
        $invocation.Extent.Text.Contains("Runtime-Test native_scaling") -and
        $invocation.Extent.Text.Contains("tools\native-analysis.ps1")) 'guarded native validation includes lifetime, scaling and analysis'
    Write-Host "TEST GROUP ENVIRONMENT TEST PASSED ($checks checks)"
} finally {
    $env:MACHTELD_TEST_PUBLIC_TLS = $originalTls
    $env:MACHTELD_TEST_PTY_IO = $originalPty
    $env:MACHTELD_WRAP_GUI_INTERACTIVE = $originalGui
    [Environment]::SetEnvironmentVariable('PATH', $originalPath, 'Process')
    foreach ($entry in $originalFixtureVariables.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}
