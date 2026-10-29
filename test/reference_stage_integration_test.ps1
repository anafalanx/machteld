[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$First,
    [Parameter(Mandatory)][string]$StageCache,
    [Parameter(Mandatory)][string]$CacheRoot,
    [Parameter(Mandatory)][string]$Tclsh,
    [string]$Warm,
    [string]$WarmLog,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Generator = Join-Path $RepoRoot 'tools\generate-reference.ps1'
$PowerShell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$First = [IO.Path]::GetFullPath($First)
$StageCache = [IO.Path]::GetFullPath($StageCache)
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$leaf = 'machteld reference stages ' + [Guid]::NewGuid().ToString('n')
$work = Join-Path $parent $leaf
$utf8 = New-Object Text.UTF8Encoding($false)
$checks = 0
function Check([bool]$Pass,[string]$Label) {
    if (-not $Pass) { throw "FAIL $Label" }; $script:checks++; Write-Host "ok $Label"
}
function Inventory([string]$Root) {
    $result = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\').Replace('\','/')
        $result[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $result
}
function Generate([string]$Script,[string]$Output) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $PowerShell51 -NoProfile -ExecutionPolicy Bypass -File $Script -CacheRoot $CacheRoot -Tclsh $Tclsh -StageCache $StageCache -Output $Output 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    $transcript = [string]::Join("`n",@($lines | ForEach-Object { $_.ToString() }))
    Write-Host $transcript
    if ($code) { throw "stage generation failed ($code)" }
    return [pscustomobject]@{Seconds=$timer.Elapsed.TotalSeconds;Transcript=$transcript}
}
[IO.Directory]::CreateDirectory($work) | Out-Null
Write-Host "Reference stage integration work: $work"
try {
    $firstInventory = Inventory $First
    if ($Warm) {
        $Warm = [IO.Path]::GetFullPath($Warm)
        if (-not $WarmLog) { throw '-Warm requires its generator log via -WarmLog' }
        $transcript = [IO.File]::ReadAllText([IO.Path]::GetFullPath($WarmLog))
        if ($transcript -notmatch 'assembly/validation [0-9,.]+s; total ([0-9,.]+)s') { throw 'warm generation timing absent from log' }
        $warmRun = [pscustomobject]@{Seconds=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture);Transcript=$transcript}
        Write-Host "Comparing existing production warm pack: $Warm"
    } else {
        $Warm = Join-Path $work warm
        $warmRun = Generate $Generator $Warm
    }
    Check ($warmRun.Transcript -match 'upstream cache hit' -and $warmRun.Transcript -match 'authored cache hit') 'unchanged generation reuses both conversion stages'
    $warmInventory = Inventory $Warm
    Check ($warmInventory.Count -eq $firstInventory.Count) 'warm and cold inventories have identical size'
    foreach ($entry in $firstInventory.GetEnumerator()) {
        if (-not $warmInventory.Contains($entry.Key) -or $warmInventory[$entry.Key] -cne $entry.Value) { throw "warm output differs: $($entry.Key)" }
    }
    Check $true "warm generation matches all $($firstInventory.Count) cold output bytes"

    # Use a private copied checkout: the real docs stay frozen for the build.
    $fixture = Join-Path $work fixture
    foreach ($directory in @('tools','src','tcl','licenses')) { [IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $RepoRoot docs) -Destination (Join-Path $fixture docs) -Recurse
    foreach ($relative in @('tools\generate-reference.ps1','tools\reference-data.cs','tools\reference-cache.ps1','tools\dependencies.lock.json',
        'src\machteld.h','tcl\machteld.tcl','LICENSE','licenses\Tcl-9.0.4.txt','licenses\Tk-9.0.4.txt')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination (Join-Path $fixture $relative)
    }
    $helpRelative = 'docs\reference\machteld\command\help.md'
    $originalHelpHash = (Get-FileHash -LiteralPath (Join-Path $RepoRoot $helpRelative) -Algorithm SHA256).Hash
    $marker = 'Reference-stage integration authored edit.'
    [IO.File]::AppendAllText((Join-Path $fixture $helpRelative), "`n$marker`n", $utf8)
    $changed = Join-Path $work changed
    $changedRun = Generate (Join-Path $fixture 'tools\generate-reference.ps1') $changed
    Check ($changedRun.Transcript -match 'upstream cache hit' -and $changedRun.Transcript -match 'authored converted') 'actual authored edit reuses upstream and reconverts only authored pages'
    $changedInventory = Inventory $changed
    Check ($changedInventory.Count -eq $firstInventory.Count) 'authored edit preserves the complete file inventory'
    $differences = @()
    foreach ($entry in $firstInventory.GetEnumerator()) {
        if (-not $changedInventory.Contains($entry.Key)) { throw "authored edit dropped $($entry.Key)" }
        if ($changedInventory[$entry.Key] -cne $entry.Value) { $differences += $entry.Key }
    }
    $expected = @('catalog.dict','catalog.json','manifest.sha256','markdown/machteld/command/help.md','search.dict') | Sort-Object
    Check ((($differences | Sort-Object) -join '|') -ceq ($expected -join '|')) 'only the edited page and assembled indexes/manifest change'
    Check ([IO.File]::ReadAllText((Join-Path $changed 'markdown\machteld\command\help.md')).Contains($marker)) 'authored edit appears in generated content'
    Check ((Get-FileHash -LiteralPath (Join-Path $RepoRoot $helpRelative) -Algorithm SHA256).Hash -ceq $originalHelpHash) 'real source documentation remains unchanged'
    Write-Host ("REFERENCE STAGE INTEGRATION TEST PASSED ({0} checks, {1} byte-identical files; warm {2:n2}s, authored edit {3:n2}s)" -f $checks,$firstInventory.Count,$warmRun.Seconds,$changedRun.Seconds)
} finally {
    if (-not $KeepWork -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ceq $parent -and
        [IO.Path]::GetFileName($work) -ceq $leaf) { Remove-Item -LiteralPath $work -Recurse -Force }
}
