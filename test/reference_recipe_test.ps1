[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$leaf = 'machteld-reference-recipe-' + [Guid]::NewGuid().ToString('n')
$work = Join-Path $parent $leaf
$toolDir = Join-Path $work tools
$utf8 = New-Object Text.UTF8Encoding($false)
$checks = 0
function Expect-Failure([string]$Pattern, [string]$Label) {
    $failure = ''
    try { & $script:generator -CacheRoot $script:work -Output (Join-Path $script:work output) }
    catch { $failure = $_.Exception.Message }
    if ($failure -notmatch $Pattern) { throw "$Label failed: $failure" }
    $script:checks++; Write-Host "ok $Label"
}
[IO.Directory]::CreateDirectory($toolDir) | Out-Null
try {
    foreach ($name in @('generate-reference.ps1','reference-data.cs','reference-cache.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "tools\$name") -Destination (Join-Path $toolDir $name)
    }
    $generator = Join-Path $toolDir 'generate-reference.ps1'
    $original = [IO.File]::ReadAllText($generator)
    $data = Join-Path $toolDir 'reference-data.cs'
    $dataOriginal = [IO.File]::ReadAllText($data)
    $cache = Join-Path $toolDir 'reference-cache.ps1'
    $cacheOriginal = [IO.File]::ReadAllText($cache)
    Expect-Failure 'dependency lock missing' 'fresh loaded recipes pass before intentional absent-lock stop'
    Expect-Failure 'dependency lock missing' 'unchanged helper may be reused in the same PowerShell session'
    [IO.File]::AppendAllText($data, "`n// changed source identity`n", $utf8)
    Expect-Failure 'fresh PowerShell process' 'changed C# source cannot relabel an already loaded type'
    [IO.File]::WriteAllText($data, $dataOriginal, $utf8)
    $marker = "Assert-ReferenceRecipes`nif (-not [IO.File]::Exists(`$LockPath))"
    # Normalize only fixture newlines so the inserted mutation has one exact
    # production call site; the executing AST still captures the entire fixture.
    $normalized = $original.Replace("`r`n","`n")
    if (-not $normalized.Contains($marker)) { throw 'recipe guard call-site fixture drift' }
    $mutate = '[IO.File]::AppendAllText($PSCommandPath, "`n# edited after parsing`n")' + "`n"
    [IO.File]::WriteAllText($generator, $normalized.Replace($marker,$mutate+$marker),$utf8)
    Expect-Failure 'loaded generator recipe changed' 'running main script is checked against its parsed source'
    $mutate = '[IO.File]::AppendAllText((Join-Path $PSScriptRoot ''reference-cache.ps1''), "`n# edited after loading`n")' + "`n"
    [IO.File]::WriteAllText($generator, $normalized.Replace($marker,$mutate+$marker),$utf8)
    Expect-Failure 'loaded generator recipe changed' 'loaded PowerShell helper is checked before cache keys'
    [IO.File]::WriteAllText($generator,$original,$utf8)
    [IO.File]::WriteAllText($cache,$cacheOriginal,$utf8)
    Remove-Variable -Name MachteldReferenceDataSourceIdentity -Scope Global
    Expect-Failure 'fresh PowerShell process' 'unidentified preloaded helper fails closed'
    Write-Host "REFERENCE RECIPE TEST PASSED ($checks checks)"
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ceq $parent -and
        [IO.Path]::GetFileName($work) -ceq $leaf) { Remove-Item -LiteralPath $work -Recurse -Force }
}
