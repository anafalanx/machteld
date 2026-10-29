[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
if (-not ('MachteldReferenceData' -as [type])) { Add-Type -Path (Join-Path $RepoRoot 'tools\reference-data.cs') }
. (Join-Path $RepoRoot 'tools\reference-cache.ps1')
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Read-Utf8Strict([string]$Path) { return [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false,$true))) }
function Write-Utf8Lf([string]$Path,[string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}
function Copy-Bytes([string]$Source,[string]$Destination) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    [IO.File]::Copy($Source,$Destination,$true)
}
function Convert-JsonDeterministic($Value) { return [MachteldReferenceData]::Json($Value)+"`n" }
$checks = 0
function Check([bool]$Pass,[string]$Message) {
    if (-not $Pass) { throw "FAIL $Message" }; $script:checks++; Write-Host "ok $Message"
}
$workLeaf = 'machteld-reference-cache-' + [Guid]::NewGuid().ToString('n')
$workParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work = Join-Path $workParent $workLeaf
[IO.Directory]::CreateDirectory($work) | Out-Null
try {
    $StageCache = Join-Path $work 'cache'
    $source = Join-Path $work 'source'
    $dest = Join-Path $work 'destination'
    $input = Join-Path $work 'input.txt'
    $authored = Join-Path $work 'authored.txt'
    Write-Utf8Lf $input upstream
    Write-Utf8Lf $authored first
    Write-Utf8Lf (Join-Path $source 'markdown\fixture.md') 'fixture text'
    $state = [ordered]@{documents=[ordered]@{fixture=[ordered]@{formats=[ordered]@{markdown=[ordered]@{path='markdown/fixture.md'}}}};aliases=[ordered]@{};fragments=[ordered]@{}}
    $key = Reference-StageKey authored @($input) '0.21'
    Check ($null -eq (Read-ReferenceStage authored $key $dest)) 'cold stage is a miss'
    Write-ReferenceStage authored $key $source $state
    $hit = Read-ReferenceStage authored $key $dest
    Check ($null -ne $hit) 'completed stage is reusable'
    Check ((Read-Utf8Strict (Join-Path $dest 'markdown\fixture.md')) -ceq 'fixture text') 'cached bytes are copied exactly'
    Check ((Convert-JsonDeterministic $hit) -ceq (Convert-JsonDeterministic $state)) 'cached metadata retains ordered inert data'
    $mtime = (Get-Item -LiteralPath $input).LastWriteTimeUtc
    Write-Utf8Lf $input UPSTREAM
    (Get-Item -LiteralPath $input).LastWriteTimeUtc = $mtime
    Check ((Reference-StageKey authored @($input) '0.21') -cne $key) 'same-size same-time input edit misses'
    Write-Utf8Lf $input upstream
    $upKey = Reference-StageKey upstream @($input)
    $authKey = Reference-StageKey authored @($input,$authored)
    Check ((Reference-StageKey authored @($authored,$input)) -ceq $authKey) 'stage key uses ordinal input ordering'
    $savedRoot = $RepoRoot
    try {
        $oneRoot = Join-Path $work 'one-repo'
        $twoRoot = Join-Path $work 'two-repo'
        $oneRecipe = Join-Path $oneRoot 'tools\recipe.ps1'
        $twoRecipe = Join-Path $twoRoot 'tools\recipe.ps1'
        $dependency = Join-Path $oneRoot '.cache\deps\tclsh.exe'
        Write-Utf8Lf $oneRecipe same-recipe
        Write-Utf8Lf $twoRecipe same-recipe
        Write-Utf8Lf $dependency same-pinned-tool
        $RepoRoot = $oneRoot
        $oneKey = Reference-StageKey upstream @($oneRecipe,$dependency)
        $RepoRoot = $twoRoot
        Check ((Reference-StageKey upstream @($twoRecipe,$dependency)) -ceq $oneKey) 'copied repository shares recipe key with the original external dependency cache'
        Write-Utf8Lf $twoRecipe changed-recipe
        Check ((Reference-StageKey upstream @($twoRecipe,$dependency)) -cne $oneKey) 'copied repository recipe edits still invalidate upstream conversion'
    } finally { $RepoRoot = $savedRoot }
    Write-Utf8Lf $authored second
    Check ((Reference-StageKey upstream @($input)) -ceq $upKey) 'authored edit preserves upstream conversion key'
    Check ((Reference-StageKey authored @($input,$authored)) -cne $authKey) 'authored edit invalidates authored stage'
    $record = Join-Path $StageCache "authored-$key.json"
    $entry = Read-Utf8Strict $record | ConvertFrom-Json
    $stage = Join-Path $StageCache $entry.generation
    $bytesBefore = Read-Utf8Strict $record
    $badState = [ordered]@{documents=[ordered]@{fixture=[ordered]@{formats=[ordered]@{markdown=[ordered]@{path='missing.md'}}}}}
    $failed = $false
    try { Write-ReferenceStage authored $key $source $badState } catch { $failed=$true }
    Check $failed 'failed stage generation is reported'
    Check ((Read-Utf8Strict $record) -ceq $bytesBefore) 'failed generation preserves prior pointer'
    Check ($null -ne (Read-ReferenceStage authored $key $dest)) 'prior valid generation survives failure'
    Write-Utf8Lf (Join-Path $stage 'markdown\fixture.md') 'corrupt text'
    Check ($null -eq (Read-ReferenceStage authored $key $dest)) 'modified cached output is rejected'
    Write-ReferenceStage authored $key $source $state
    Check ($null -ne (Read-ReferenceStage authored $key $dest)) 'replacement generation recovers corruption'
    $entry = Read-Utf8Strict $record | ConvertFrom-Json
    $stage = Join-Path $StageCache $entry.generation
    Write-Utf8Lf (Join-Path $stage 'unexpected.txt') extra
    Check ($null -eq (Read-ReferenceStage authored $key $dest)) 'extra cached file invalidates exact inventory'
    Write-Utf8Lf $record '{bad json'
    Check ($null -eq (Read-ReferenceStage authored $key $dest)) 'malformed pointer is a cache miss'
    $realCache = $StageCache
    $junction = Join-Path $work 'cache-junction'
    try {
        New-Item -ItemType Junction -Path $junction -Target $realCache | Out-Null
        $StageCache = $junction
        Check ($null -eq (Read-ReferenceStage authored $key $dest)) 'cache ancestor junction is refused on read'
        $failed = $false
        try { Write-ReferenceStage authored $key $source $state } catch { $failed=$true }
        Check $failed 'cache ancestor junction is refused on write'
    } finally {
        $StageCache = $realCache
        if ((Test-Path -LiteralPath $junction) -and
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($junction)) -ceq $work) {
            # Remove only the link, never recurse through its target.
            [IO.Directory]::Delete($junction)
        }
    }
    Write-Host "REFERENCE CACHE TEST PASSED ($checks checks)"
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ceq $workParent -and
        [IO.Path]::GetFileName($work) -ceq $workLeaf) { Remove-Item -LiteralPath $work -Recurse -Force }
}
