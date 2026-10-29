[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$path = Join-Path $PSScriptRoot 'reference_generator_test.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'reference generator test does not parse' }
# Exercise the actual orchestration with a command stub, never a conversion.
foreach ($name in @('Fail','Generate','Select-StageCache','Check-ReferenceStages')) {
    $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name}, $false)
    if ($null -eq $definition) { throw "missing production function $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$calls = New-Object Collections.Generic.List[object]
$nextExit = 0
function Invoke-ReferenceCommandStub {
    $script:calls.Add([string[]]$args)
    $global:LASTEXITCODE = $script:nextExit
}
function Argument([string[]]$Call, [string]$Name) {
    $index = [Array]::IndexOf($Call, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Call.Count) { return $null }
    return $Call[$index + 1]
}
$checks = 0
function Check([bool]$Pass, [string]$Label) {
    if (-not $Pass) { throw "FAIL $Label" }; $script:checks++; Write-Host "ok $Label"
}
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$leaf = 'machteld-reference-orchestration-' + [Guid]::NewGuid().ToString('n')
$Work = Join-Path $parent $leaf
[IO.Directory]::CreateDirectory($Work) | Out-Null
try {
    $PowerShell51 = 'Invoke-ReferenceCommandStub'
    $Generator = Join-Path $RepoRoot 'tools\generate-reference.ps1'
    $CacheRoot = Join-Path $Work 'external deps'
    $Tclsh = Join-Path $CacheRoot 'tclsh.exe'
    $First = Join-Path $Work 'first pack'
    $Second = Join-Path $Work 'second pack'
    $KeepWork = $false
    $PrimeStageCache = ''

    # Evaluate the driver's actual selection and cold-pass call sites. This
    # catches accidentally dropping StageCache from its first Generate call.
    $selection = $ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$StageCache'}, $false)
    if ($null -eq $selection) { throw 'missing production stage-cache selection' }
    . ([scriptblock]::Create($selection.Extent.Text))
    Check ($StageCache -ceq (Join-Path $Work 'stage cache') -and -not (Test-Path -LiteralPath $StageCache)) 'default cache is an initially absent child of the invocation work directory'
    $PrimeStageCache = Join-Path $Work 'explicit stages'
    . ([scriptblock]::Create($selection.Extent.Text))
    Check ($StageCache -ceq [IO.Path]::GetFullPath($PrimeStageCache)) 'explicit PrimeStageCache path is preserved'
    [IO.Directory]::CreateDirectory($PrimeStageCache) | Out-Null
    $failure = ''
    try { Select-StageCache $PrimeStageCache $Work | Out-Null } catch { $failure = $_.Exception.Message }
    Check ($failure -match 'requires an absent path') 'an existing explicit cache cannot make the first pass warm'
    $StageCache = Select-StageCache '' $Work

    $generations = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Generate'}, $false))
    Check ($generations.Count -eq 2) 'full gate has exactly two cold generation call sites'
    foreach ($generation in $generations) { . ([scriptblock]::Create($generation.Extent.Text)) }
    Check ($calls.Count -eq 2 -and (Argument $calls[0] '-Output') -ceq $First -and
        (Argument $calls[0] '-StageCache') -ceq $StageCache) 'first cold pass primes the selected empty cache'
    Check ((Argument $calls[1] '-Output') -ceq $Second -and $calls[1] -cnotcontains '-StageCache') 'second cold pass is always independent and uncached'
    Check ((Argument $calls[0] '-CacheRoot') -ceq $CacheRoot -and (Argument $calls[1] '-Tclsh') -ceq $Tclsh) 'cold passes preserve external dependency and Tcl identities'

    $stageCall = $ast.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Check-ReferenceStages'}, $false)
    if ($null -eq $stageCall) { throw 'missing production stage integration call' }
    . ([scriptblock]::Create($stageCall.Extent.Text))
    Check ($calls.Count -eq 3 -and (Argument $calls[2] '-File') -ceq (Join-Path $RepoRoot 'test\reference_stage_integration_test.ps1') -and
        (Argument $calls[2] '-First') -ceq $First -and (Argument $calls[2] '-StageCache') -ceq $StageCache) 'full gate runs warm/authored integration against its first cold pack and cache'
    Check ($calls[2] -cnotcontains '-Warm' -and $calls[2] -cnotcontains '-KeepWork') 'ordinary full gate generates its own warm pack and cleans up test work'
    $manifestCheck = $ast.Find({param($node) $node -is [Management.Automation.Language.ForStatementAst] -and
        $node.Extent.Text.Contains('manifest mismatch at')}, $false)
    Check ($null -ne $manifestCheck -and $stageCall.Extent.StartOffset -gt $manifestCheck.Extent.EndOffset) 'stage integration runs after independent cold fidelity/manifest checks'

    $KeepWork = $true
    Check-ReferenceStages $First $StageCache
    Check ($calls[3] -ccontains '-KeepWork') 'explicit KeepWork also preserves stage integration evidence'
    $nextExit = 23
    $failure = ''
    try { Generate $Second } catch { $failure = $_.Exception.Message }
    Check ($failure -match 'generator failed with exit code 23') 'cold generator child failure fails the gate'
    $failure = ''
    try { Check-ReferenceStages $First $StageCache } catch { $failure = $_.Exception.Message }
    Check ($failure -match 'reference stage integration failed with exit code 23') 'stage integration child failure fails the gate'
    Write-Host "REFERENCE ORCHESTRATION TEST PASSED ($checks checks; no conversions)"
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Work)) -ceq $parent -and
        [IO.Path]::GetFileName($Work) -ceq $leaf) { Remove-Item -LiteralPath $Work -Recurse -Force }
}
