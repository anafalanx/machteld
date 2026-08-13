[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CacheRoot,
    [Parameter(Mandatory)][string]$Tclsh
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Generator = Join-Path $RepoRoot 'tools\generate-reference.ps1'
$PowerShell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$StrictUtf8 = New-Object Text.UTF8Encoding($false, $true)
$Work = Join-Path ([IO.Path]::GetTempPath()) "machteld reference determinism $PID"
$First = Join-Path $Work 'first pack'
$Second = Join-Path $Work 'second pack'

function Fail([string]$Message) { throw "reference generator test: $Message" }
function Relative-Files([string]$Root) {
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    [string[]]$paths = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        $_.FullName.Substring($prefix.Length).Replace('\', '/')
    })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    return $paths
}
function Generate([string]$Output) {
    & $PowerShell51 -NoProfile -ExecutionPolicy Bypass -File $Generator `
        -CacheRoot $CacheRoot -Output $Output -Tclsh $Tclsh
    if ($LASTEXITCODE) { Fail "generator failed with exit code $LASTEXITCODE" }
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
try {
    $header = [IO.File]::ReadAllText((Join-Path $RepoRoot 'src\machteld.h'))
    $prelude = [IO.File]::ReadAllText((Join-Path $RepoRoot 'tcl\machteld.tcl'))
    if ($header -notmatch '(?m)^#define\s+MACHTELD_VERSION\s+"([0-9]+\.[0-9]+\.[0-9]+)"\s*$') {
        Fail 'native canonical version is absent'
    }
    $runtimeVersion = $Matches[1]
    if ($prelude -notmatch '(?m)^\s*variable\s+version\s+([0-9]+\.[0-9]+\.[0-9]+)\s*$' -or
            $Matches[1] -ne $runtimeVersion -or
            $prelude -notmatch '(?m)^\s*puts\s+\$channel\s+\{package require machteld ([0-9]+\.[0-9]+\.[0-9]+)\}\s*$' -or
            $Matches[1] -ne $runtimeVersion) {
        Fail 'C, Tcl package, and wrapped-launcher versions disagree'
    }
    # The space-bearing parent exercises converter argv handling as well as
    # same-parent immutable publication under Windows PowerShell 5.1.
    Generate $First
    Generate $Second

    $firstFiles = @(Relative-Files $First)
    $secondFiles = @(Relative-Files $Second)
    if ([string]::Join("`n", $firstFiles) -cne [string]::Join("`n", $secondFiles)) {
        Fail 'two runs produced different file inventories'
    }
    foreach ($relative in $firstFiles) {
        $one = (Get-FileHash -LiteralPath (Join-Path $First $relative.Replace('/', '\')) -Algorithm SHA256).Hash
        $two = (Get-FileHash -LiteralPath (Join-Path $Second $relative.Replace('/', '\')) -Algorithm SHA256).Hash
        if ($one -cne $two) { Fail "two runs differ byte-for-byte at $relative" }
    }

    foreach ($required in @('catalog.dict','catalog.json','search.dict','manifest.sha256',
            'schema.json','START-HERE.md','AGENTS.md','markdown/tcl/command/dict.md',
            'markdown/tk/command/bind.md','source/tcl/doc/dict.n','source/tk/doc/bind.n',
            'html/TclCmd/dict.html','html/TkCmd/bind.html')) {
        if (-not (Test-Path -LiteralPath (Join-Path $First $required.Replace('/', '\')) -PathType Leaf)) {
            Fail "required reference path is absent: $required"
        }
    }

    # Windows PowerShell 5.1 Get-Content otherwise assumes the active ANSI code
    # page and silently corrupts non-ASCII titles and summaries.
    $catalog = [IO.File]::ReadAllText((Join-Path $First 'catalog.json'), $StrictUtf8) | ConvertFrom-Json
    if ($catalog.schema -ne 1 -or $catalog.products.tcl.manual_pages -ne 249 -or
            $catalog.products.tk.manual_pages -ne 177 -or
            $catalog.products.tcl.documents -ne 250 -or $catalog.products.tk.documents -ne 178) {
        Fail 'catalog product/manual counts do not preserve the 249/177 core-manual contract'
    }
    $documentNames = @($catalog.documents.PSObject.Properties.Name)
    foreach ($id in @('tcl/command/dict','tcl/command/http','tcl/c-api/crtobjcmd',
            'tk/command/bind','machteld/agent','machteld/license','tcl/license','tk/license')) {
        if ($id -cnotin $documentNames) { Fail "catalog document is absent: $id" }
    }
    foreach ($id in $documentNames) {
        if ($id -cne $id.ToLowerInvariant()) { Fail "canonical ID is not lowercase: $id" }
        # Tcl's core C API legitimately includes tcl/c-api/thread.  Reject
        # auto-discovered extension packages without conflating that page
        # with the separately distributed Thread package.
        if ($id -match '/(?:tdbc|sqlite3|itcl|tclx|tktable)(?:/|$)' -or
                ($id -match '/thread(?:/|$)' -and $id -cne 'tcl/c-api/thread')) {
            Fail "unshipped extension was auto-discovered into the core catalog: $id"
        }
    }

    $inventory = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in $catalog.inventory.PSObject.Properties.Name) { [void]$inventory.Add($path) }
    $represented = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($document in $catalog.documents.PSObject.Properties.Value) {
        foreach ($format in $document.formats.PSObject.Properties.Value) {
            if (-not $inventory.Contains([string]$format.path)) {
                Fail "representation is outside inventory: $($format.path)"
            }
            [void]$represented.Add([string]$format.path)
        }
    }
    $auxiliary = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in @($catalog.auxiliary)) {
        if (-not $inventory.Contains($path) -or $represented.Contains($path) -or
                -not $auxiliary.Add($path)) { Fail "invalid auxiliary partition path: $path" }
    }
    if ($represented.Count + $auxiliary.Count -ne $inventory.Count) {
        Fail 'document representations and auxiliary paths do not exactly partition inventory'
    }

    $dictMarkdown = [IO.File]::ReadAllText((Join-Path $First 'markdown\tcl\command\dict.md'), $StrictUtf8)
    $fileSystemMarkdown = [IO.File]::ReadAllText((Join-Path $First 'markdown\tcl\c-api\filesystem.md'), $StrictUtf8)
    $canvasMarkdown = [IO.File]::ReadAllText((Join-Path $First 'markdown\tk\command\canvas.md'), $StrictUtf8)
    $colorsMarkdown = [IO.File]::ReadAllText((Join-Path $First 'markdown\tk\command\colors.md'), $StrictUtf8)
    if ($dictMarkdown -notmatch '(?m)^## NAME\s*$' -or $dictMarkdown -notmatch '(?m)^## SYNOPSIS\s*$') {
        Fail 'normalized dict page lost canonical headings/synopsis'
    }
    if ($fileSystemMarkdown -notmatch '(?m)^```c\s*$' -or
            $fileSystemMarkdown -notmatch '(?i)Copyright.*Vincent Darley') {
        Fail 'normalized C API page lost C fencing or its upstream per-page notice'
    }
    if ($colorsMarkdown -notmatch '(?m)^\| .+ \|\s*$') { Fail 'normalized Tk colors page lost table structure' }
    foreach ($sample in @($dictMarkdown,$fileSystemMarkdown,$canvasMarkdown,$colorsMarkdown)) {
        if ($sample -match '<\/?(?:b|i|dl|dt|dd|table|tr|td|font|pre|p|br)\b') {
            Fail 'normalized representative page leaked upstream HTML markup'
        }
    }

    $manifestPath = Join-Path $First 'manifest.sha256'
    $rows = @([IO.File]::ReadAllLines($manifestPath))
    if ($rows[0] -cne '# machteld reference pack v1; SHA-256 consistency manifest (self excluded)') {
        Fail 'manifest header is not canonical'
    }
    $manifestFiles = @($firstFiles | Where-Object { $_ -cne 'manifest.sha256' })
    if ($rows.Count -ne $manifestFiles.Count + 1) { Fail 'manifest does not cover the exact file set' }
    for ($i = 0; $i -lt $manifestFiles.Count; $i++) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $First $manifestFiles[$i].Replace('/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($rows[$i + 1] -cne "$hash  $($manifestFiles[$i])") {
            Fail "manifest mismatch at $($manifestFiles[$i])"
        }
    }

    Write-Host "REFERENCE GENERATOR TEST PASSED ($($firstFiles.Count) byte-identical files, Tcl 249 / Tk 177)"
} finally {
    if ([IO.Path]::GetFileName($Work) -eq "machteld reference determinism $PID" -and
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Work)) -eq
                [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
