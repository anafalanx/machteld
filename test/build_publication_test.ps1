[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$PublishScript = Join-Path $RepoRoot 'tools\publish-output.ps1'
$WorkLeaf = "machteld-publication-test-$PID-$([Guid]::NewGuid().ToString('n'))"
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$Work = Join-Path $TempRoot $WorkLeaf
New-Item -ItemType Directory -Path $Work | Out-Null
$Failures = 0

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "ok   $Name"; return }
    $script:Failures++
    Write-Host "FAIL $Name $Detail"
}
function New-Candidate([string]$Text, [string]$Parent = $Work) {
    $path = Join-Path $Parent ".machteld-build-$([Guid]::NewGuid().ToString('n')).exe"
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    return $path
}
function Read-Text([string]$Path) {
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}
function Invoke-Publication([string]$Candidate, [string]$Output) {
    try {
        & $PublishScript -Candidate $Candidate -Output $Output *> $null
        return [pscustomobject]@{ Ok = $true; Error = '' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

try {
    $output = Join-Path $Work 'released.exe'
    $candidate = New-Candidate 'first release'
    $result = Invoke-Publication $candidate $output
    Check 'native publication creates an absent output' `
        ($result.Ok -and -not (Test-Path -LiteralPath $candidate) -and
         (Read-Text $output) -eq 'first release') $result.Error

    $candidate = New-Candidate 'replacement release'
    $result = Invoke-Publication $candidate $output
    Check 'native publication atomically replaces an existing output' `
        ($result.Ok -and -not (Test-Path -LiteralPath $candidate) -and
         (Read-Text $output) -eq 'replacement release') $result.Error

    $candidate = New-Candidate 'locked replacement'
    $locked = [IO.File]::Open($output, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::None)
    try {
        $result = Invoke-Publication $candidate $output
    } finally {
        $locked.Dispose()
    }
    Check 'locked-output publication reports an error' (-not $result.Ok) $result.Error
    Check 'locked-output failure preserves both complete files' `
        ((Read-Text $output) -eq 'replacement release' -and
         (Read-Text $candidate) -eq 'locked replacement')
    Remove-Item -LiteralPath $candidate -Force

    $otherParent = Join-Path $Work 'other'
    New-Item -ItemType Directory -Path $otherParent | Out-Null
    $candidate = New-Candidate 'wrong parent' $otherParent
    $result = Invoke-Publication $candidate $output
    Check 'cross-directory publication is rejected before the native call' `
        (-not $result.Ok -and (Read-Text $output) -eq 'replacement release' -and
         (Read-Text $candidate) -eq 'wrong parent') $result.Error
    Remove-Item -LiteralPath $candidate -Force

    $unowned = Join-Path $Work 'ordinary-candidate.exe'
    [IO.File]::WriteAllText($unowned, 'unowned', [Text.UTF8Encoding]::new($false))
    $result = Invoke-Publication $unowned $output
    Check 'non-owned candidate names are rejected without deleting either file' `
        (-not $result.Ok -and (Read-Text $output) -eq 'replacement release' -and
         (Read-Text $unowned) -eq 'unowned') $result.Error
    Remove-Item -LiteralPath $unowned -Force

    # This basename used to collide with build.tcl's fixed linker output. Run
    # several publication cycles and verify that only the requested name lasts.
    $collisionOutput = Join-Path $Work 'machteld-bare.exe'
    [IO.File]::WriteAllText($collisionOutput, 'prior bare',
        [Text.UTF8Encoding]::new($false))
    foreach ($generation in 1..4) {
        $candidate = New-Candidate "generation $generation"
        $result = Invoke-Publication $candidate $collisionOutput
        Check "repeated build publication $generation succeeds" `
            ($result.Ok -and (Read-Text $collisionOutput) -eq "generation $generation") `
            $result.Error
    }
    Check 'repeated publications leave no candidate debris' `
        (-not (Get-ChildItem -LiteralPath $Work -Force |
            Where-Object Name -Like '.machteld-build-*'))

    $buildTcl = Get-Content -LiteralPath (Join-Path $RepoRoot 'tools\build.tcl') -Raw
    Check 'linker intermediates are isolated from every requested output name' `
        ($buildTcl.Contains('set bare [file join $BUILDROOT machteld-bare.exe]') -and
         $buildTcl.Contains('set bareGui [file join $BUILDROOT machteld-bare-gui.exe]') -and
         -not $buildTcl.Contains('[file join $OUTDIR machteld-bare.exe]'))

    $packageTcl = Get-Content -LiteralPath (Join-Path $RepoRoot 'tools\package.tcl') -Raw
    Check 'package publication is a non-replacing same-directory rename' `
        ($packageTcl.Contains('file rename $outputCandidate $OUT') -and
         -not $packageTcl.Contains('file rename -force $outputCandidate $OUT'))
} finally {
    if ((Split-Path -Leaf $Work) -ceq $WorkLeaf -and
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Work)) -eq
                $TempRoot) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Failures) { throw "$Failures build publication test(s) failed" }
Write-Host 'ALL BUILD PUBLICATION TESTS PASSED'
