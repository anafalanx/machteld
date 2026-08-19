[CmdletBinding()]
param(
    [string]$CacheRoot,
    [string]$MsysRoot,
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $CacheRoot) { $CacheRoot = Join-Path $RepoRoot '.cache\deps' }
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
$LockPath = Join-Path $PSScriptRoot 'dependencies.lock.json'
$Lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
$PatchPaths = @($Lock.patches | ForEach-Object {
    if (-not $_.file -or [IO.Path]::IsPathRooted($_.file) -or $_.file -match '(^|[/\\])\.\.([/\\]|$)') {
        throw "invalid dependency patch path: $($_.file)"
    }
    Join-Path $PSScriptRoot ($_.file.Replace('/', '\'))
})
$StateInputs = @($LockPath, $PSCommandPath, (Join-Path $PSScriptRoot 'bootstrap-deps.sh')) + $PatchPaths
$StateMaterial = foreach ($path in $StateInputs) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "missing bootstrap input: $path" }
    "{0} {1}" -f ([IO.Path]::GetFileName($path)),
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$StateBytes = [Text.Encoding]::UTF8.GetBytes(($StateMaterial -join "`n"))
$StateHasher = [Security.Cryptography.SHA256]::Create()
try {
    $StateHash = ([BitConverter]::ToString($StateHasher.ComputeHash($StateBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $StateHasher.Dispose()
}
$Prefix = Join-Path $CacheRoot 'prefix'
$SourceRoot = Join-Path $CacheRoot 'src'
$Downloads = Join-Path $CacheRoot 'downloads'
$StatePath = Join-Path $CacheRoot 'lock.sha256'
$ArtifactManifestPath = Join-Path $CacheRoot 'artifacts.sha256'

function Assert-UnderCache([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $base = $CacheRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing path outside dependency cache: $resolved"
    }
}

function Resolve-MsysRoot {
    if ($MsysRoot) { return [IO.Path]::GetFullPath($MsysRoot) }
    if ($env:MSYS2_ROOT) { return [IO.Path]::GetFullPath($env:MSYS2_ROOT) }
    if (Test-Path -LiteralPath 'C:\msys64\usr\bin\bash.exe') { return 'C:\msys64' }
    throw 'MSYS2 root not found; pass -MsysRoot or set MSYS2_ROOT'
}

function Assert-Hash([string]$Path, [string]$Expected, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "missing $Label`: $Path" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label SHA-256 mismatch: expected $Expected, got $actual ($Path)"
    }
}

function Apply-PinnedUnifiedPatch(
    [string]$PatchPath,
    [string]$TargetPath,
    [string]$ExpectedTarget
) {
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $patchText = [IO.File]::ReadAllText($PatchPath, $utf8).Replace("`r`n", "`n")
    $sourceText = [IO.File]::ReadAllText($TargetPath, $utf8).Replace("`r`n", "`n")
    $patchLines = $patchText.Split("`n")
    $sourceLines = $sourceText.Split("`n")
    $oldHeader = "--- a/$ExpectedTarget"
    $newHeader = "+++ b/$ExpectedTarget"
    if (($patchLines -notcontains $oldHeader) -or ($patchLines -notcontains $newHeader)) {
        throw "patch headers do not name the locked target: $ExpectedTarget"
    }

    $result = [Collections.Generic.List[string]]::new()
    $sourceIndex = 0
    $patchIndex = 0
    $hunks = 0
    while ($patchIndex -lt $patchLines.Length) {
        $header = [regex]::Match(
            $patchLines[$patchIndex],
            '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@'
        )
        if (-not $header.Success) { $patchIndex++; continue }

        $hunks++
        $oldStart = [int]$header.Groups[1].Value
        $oldExpected = if ($header.Groups[2].Success) {
            [int]$header.Groups[2].Value
        } else { 1 }
        $newExpected = if ($header.Groups[4].Success) {
            [int]$header.Groups[4].Value
        } else { 1 }
        $hunkSourceIndex = $oldStart - 1
        if ($hunkSourceIndex -lt $sourceIndex -or $hunkSourceIndex -gt $sourceLines.Length) {
            throw "patch hunk has invalid source position: $($patchLines[$patchIndex])"
        }
        while ($sourceIndex -lt $hunkSourceIndex) {
            $result.Add($sourceLines[$sourceIndex++])
        }

        $oldSeen = 0
        $newSeen = 0
        $patchIndex++
        while ($patchIndex -lt $patchLines.Length -and
                $patchLines[$patchIndex] -notmatch '^@@ ') {
            $line = $patchLines[$patchIndex]
            if ($line.StartsWith(' ')) {
                $expected = $line.Substring(1)
                if ($sourceIndex -ge $sourceLines.Length -or
                        $sourceLines[$sourceIndex] -cne $expected) {
                    throw "patch context mismatch at source line $($sourceIndex + 1)"
                }
                $result.Add($expected)
                $sourceIndex++
                $oldSeen++
                $newSeen++
            } elseif ($line.StartsWith('-')) {
                $expected = $line.Substring(1)
                if ($sourceIndex -ge $sourceLines.Length -or
                        $sourceLines[$sourceIndex] -cne $expected) {
                    throw "patch removal mismatch at source line $($sourceIndex + 1)"
                }
                $sourceIndex++
                $oldSeen++
            } elseif ($line.StartsWith('+')) {
                $result.Add($line.Substring(1))
                $newSeen++
            } elseif ($line -eq '\ No newline at end of file') {
                # All locked Machteld patches and targets end with LF. The
                # marker is accepted only so malformed input fails by hash.
            } elseif ($line.Length -ne 0) {
                throw "invalid unified patch line: $line"
            } else {
                break
            }
            $patchIndex++
        }
        if ($oldSeen -ne $oldExpected -or $newSeen -ne $newExpected) {
            throw "patch hunk count mismatch: expected -$oldExpected +$newExpected, got -$oldSeen +$newSeen"
        }
    }
    if ($hunks -eq 0) { throw 'patch contains no unified-diff hunks' }
    while ($sourceIndex -lt $sourceLines.Length) {
        $result.Add($sourceLines[$sourceIndex++])
    }
    [IO.File]::WriteAllText($TargetPath, ($result -join "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-CacheRelativePath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    Assert-UnderCache $resolved
    $relative = $resolved.Substring($CacheRoot.TrimEnd('\').Length).TrimStart('\')
    return $relative.Replace('\', '/')
}

function Get-ArtifactManifestLines {
    # Hash every file in compiler header and packaged script-library trees, in
    # addition to the exact static binaries/libraries and SQLite amalgamation
    # consumed by build.tcl/package.tcl. -Force includes hidden entries.
    $trees = @(
        (Join-Path $Prefix 'include'),
        (Join-Path $Prefix 'lib\tcl9'),
        (Join-Path $Prefix 'lib\tcl9.0'),
        (Join-Path $Prefix 'lib\tk9.0'),
        (Join-Path $CacheRoot 'lua')
    )
    $files = @(
        (Join-Path $Prefix 'bin\tclsh90s.exe'),
        (Join-Path $Prefix 'bin\wish90s.exe'),
        (Join-Path $Prefix 'lib\libtcl90.a'),
        (Join-Path $Prefix 'lib\libtcl9tk90.a'),
        (Join-Path $Prefix 'lib\libtclstub.a'),
        (Join-Path $CacheRoot 'sqlite\sqlite3.c'),
        (Join-Path $CacheRoot 'sqlite\sqlite3.h')
    )

    [string[]]$relativePaths = @()
    foreach ($tree in $trees) {
        if (-not (Test-Path -LiteralPath $tree -PathType Container)) {
            throw "dependency cache is missing artifact tree: $tree"
        }
        $treeFiles = @(Get-ChildItem -LiteralPath $tree -Recurse -Force -File)
        if ($treeFiles.Count -eq 0) {
            throw "dependency artifact tree is empty: $tree"
        }
        foreach ($file in $treeFiles) {
            $relativePaths += Get-CacheRelativePath $file.FullName
        }
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "dependency cache is missing artifact: $file"
        }
        $relativePaths += Get-CacheRelativePath $file
    }

    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $previous = $null
    $lines = @('# machteld dependency artifacts v1')
    foreach ($relative in $relativePaths) {
        if ($relative -match "[`r`n]") {
            throw "dependency artifact path contains a newline: $relative"
        }
        if ($null -ne $previous -and $relative -eq $previous) {
            throw "duplicate dependency artifact path: $relative"
        }
        $fullPath = Join-Path $CacheRoot $relative.Replace('/', '\')
        $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$hash  $relative"
        $previous = $relative
    }
    return $lines
}

function Write-ArtifactManifest {
    $candidate = Join-Path $CacheRoot ('.artifacts-' + [Guid]::NewGuid().ToString('n') + '.tmp')
    Assert-UnderCache $candidate
    try {
        $text = ((Get-ArtifactManifestLines) -join "`n") + "`n"
        [IO.File]::WriteAllText($candidate, $text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $candidate -Destination $ArtifactManifestPath -Force
    } finally {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ArtifactManifest {
    if (-not (Test-Path -LiteralPath $ArtifactManifestPath -PathType Leaf)) {
        throw "dependency artifact manifest is missing: $ArtifactManifestPath"
    }
    $expected = ((Get-ArtifactManifestLines) -join "`n") + "`n"
    $actual = [IO.File]::ReadAllText($ArtifactManifestPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    if ($actual -ne $expected) {
        throw "dependency artifact manifest mismatch: $ArtifactManifestPath"
    }
}

function Get-Archive($Entry) {
    New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
    $target = Join-Path $Downloads $Entry.file
    if (Test-Path -LiteralPath $target) {
        try { Assert-Hash $target $Entry.sha256 $Entry.id; return $target }
        catch { Remove-Item -LiteralPath $target -Force }
    }
    $partial = "$target.partial"
    Assert-UnderCache $partial
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Host "download $($Entry.id) $($Entry.version)"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fL --retry 2 --retry-all-errors --output $partial $Entry.url
        if ($LASTEXITCODE) { throw "download failed for $($Entry.id) with exit code $LASTEXITCODE" }
    } else {
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 -Uri $Entry.url -OutFile $partial
    }
    Assert-Hash $partial $Entry.sha256 $Entry.id
    Move-Item -LiteralPath $partial -Destination $target
    return $target
}

function Find-One([string[]]$Candidates, [string]$Label) {
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "dependency prefix has no $Label; tried: $($Candidates -join ', ')"
}

$MsysRoot = Resolve-MsysRoot
$Gcc = Join-Path $MsysRoot 'ucrt64\bin\gcc.exe'
$Strip = Join-Path $MsysRoot 'ucrt64\bin\strip.exe'
$Make = Join-Path $MsysRoot 'ucrt64\bin\mingw32-make.exe'
$Zip = Join-Path $MsysRoot 'usr\bin\zip.exe'
$Bash = Join-Path $MsysRoot 'usr\bin\bash.exe'
Assert-Hash $Gcc $Lock.toolchain.gccSha256 'GCC'
Assert-Hash $Strip $Lock.toolchain.stripSha256 'strip'
Assert-Hash $Make $Lock.toolchain.makeSha256 'mingw32-make'
Assert-Hash $Zip $Lock.toolchain.zipSha256 'zip'
if (-not (Test-Path -LiteralPath $Bash)) { throw "missing MSYS2 bash: $Bash" }
$gccVersion = (& $Gcc -dumpfullversion).Trim()
if ($gccVersion -ne $Lock.toolchain.gccVersion) {
    throw "GCC version mismatch: expected $($Lock.toolchain.gccVersion), got $gccVersion"
}
$makeVersion = (& $Make --version | Select-Object -First 1)
if ($makeVersion -notmatch ('GNU Make ' + [regex]::Escape(($Lock.toolchain.makePackageVersion -split '-')[0]) + '($|\s)')) {
    throw "make version mismatch: expected $($Lock.toolchain.makePackageVersion), got $makeVersion"
}
$zipVersion = (& $Zip -v | Select-Object -First 2) -join ' '
if ($zipVersion -notmatch 'This is Zip 3\.0') {
    throw "zip version mismatch: expected $($Lock.toolchain.zipPackageVersion), got $zipVersion"
}

$stateMatches = (Test-Path -LiteralPath $StatePath) -and
    ((Get-Content -LiteralPath $StatePath -Raw).Trim() -eq $StateHash)
if ($VerifyOnly) {
    if (-not $stateMatches) { throw 'dependency cache is absent or stale; run tools/bootstrap.ps1' }
    Assert-ArtifactManifest
    Write-Host "dependency cache verified ($StateHash)"
    return
}
if ($stateMatches) {
    try {
        Assert-ArtifactManifest
        Write-Host "dependency cache already current ($StateHash)"
        return
    } catch {
        Write-Warning "dependency cache content verification failed; rebuilding: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $CacheRoot, $SourceRoot, $Prefix | Out-Null

# A stale or interrupted cache is never configured in place. Preserve only the
# downloaded archives, whose hashes are rechecked by Get-Archive, and rebuild
# every derived tree from a known-empty directory.
foreach ($derived in @($Prefix, $SourceRoot, (Join-Path $CacheRoot 'sqlite'),
                       (Join-Path $CacheRoot 'lua'))) {
    Assert-UnderCache $derived
    if (Test-Path -LiteralPath $derived) {
        Get-ChildItem -LiteralPath $derived -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch {} }
        [IO.Directory]::Delete($derived, $true)
    }
    New-Item -ItemType Directory -Force -Path $derived | Out-Null
}
Remove-Item -LiteralPath $StatePath, $ArtifactManifestPath -Force -ErrorAction SilentlyContinue

$entry = $Lock.archives | Where-Object id -eq 'tcltk'
$archive = Get-Archive $entry
$tkEntry = $Lock.archives | Where-Object id -eq 'tk'
$tkArchive = Get-Archive $tkEntry
$extract = Join-Path $SourceRoot 'tcltk-9.0.4'
$tclConfigure = Join-Path $extract 'tcl9.0.4\win\configure'
$tkConfigure = Join-Path $extract 'tk9.0.4\win\configure'
if (-not ((Test-Path -LiteralPath $tclConfigure) -and (Test-Path -LiteralPath $tkConfigure))) {
    $extractTemp = Join-Path $SourceRoot ('.tcltk-extract-' + [Guid]::NewGuid().ToString('n'))
    Assert-UnderCache $extractTemp
    New-Item -ItemType Directory -Force -Path $extractTemp | Out-Null
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $extractTemp
        Expand-Archive -LiteralPath $tkArchive -DestinationPath $extractTemp
        if (-not ((Test-Path -LiteralPath (Join-Path $extractTemp 'tcl9.0.4\win\configure')) -and
                  (Test-Path -LiteralPath (Join-Path $extractTemp 'tk9.0.4\win\configure')))) {
            throw 'Tcl/Tk archives are incomplete after extraction'
        }
        Move-Item -LiteralPath $extractTemp -Destination $extract
    } finally {
        if (Test-Path -LiteralPath $extractTemp) {
            [IO.Directory]::Delete($extractTemp, $true)
        }
    }
}

$tclPatchEntries = @($Lock.patches | Where-Object id -eq 'tcl-windows-acl-normalize')
if ($tclPatchEntries.Count -ne 1) {
    throw 'dependency lock must contain exactly one tcl-windows-acl-normalize patch'
}
$tclPatch = $tclPatchEntries[0]
$tclPatchPath = Join-Path $PSScriptRoot ($tclPatch.file.Replace('/', '\'))
$tclPatchTarget = Join-Path $extract ($tclPatch.target.Replace('/', '\'))
Assert-Hash $tclPatchPath $tclPatch.sha256 $tclPatch.id
Assert-Hash $tclPatchTarget $tclPatch.beforeSha256 "$($tclPatch.id) input"
Apply-PinnedUnifiedPatch $tclPatchPath $tclPatchTarget $tclPatch.target
Assert-Hash $tclPatchTarget $tclPatch.afterSha256 "$($tclPatch.id) output"

$cygpath = Join-Path $MsysRoot 'usr\bin\cygpath.exe'
$sourceUnix = (& $cygpath -u $extract).Trim()
$prefixUnix = (& $cygpath -u $Prefix).Trim()
$scriptUnix = (& $cygpath -u (Join-Path $PSScriptRoot 'bootstrap-deps.sh')).Trim()
& $Bash -lc "'$scriptUnix' '$sourceUnix' '$prefixUnix' '$Jobs'"
if ($LASTEXITCODE) { throw "Tcl/Tk build failed with exit code $LASTEXITCODE" }

$sqliteEntry = $Lock.archives | Where-Object id -eq 'sqlite'
$sqliteArchive = Get-Archive $sqliteEntry
$sqliteExtract = Join-Path $SourceRoot 'sqlite-3.51.0'
if (-not (Test-Path -LiteralPath (Join-Path $sqliteExtract 'sqlite3.c'))) {
    Assert-UnderCache $sqliteExtract
    Remove-Item -LiteralPath $sqliteExtract -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $sqliteExtract | Out-Null
    Expand-Archive -LiteralPath $sqliteArchive -DestinationPath $sqliteExtract
    $sqliteC = Get-ChildItem -LiteralPath $sqliteExtract -Recurse -Filter sqlite3.c | Select-Object -First 1
    if (-not $sqliteC) { throw 'SQLite archive contains no sqlite3.c' }
    $sqliteDir = $sqliteC.Directory.FullName
    New-Item -ItemType Directory -Force -Path (Join-Path $CacheRoot 'sqlite') | Out-Null
    Copy-Item -LiteralPath (Join-Path $sqliteDir 'sqlite3.c'), (Join-Path $sqliteDir 'sqlite3.h') -Destination (Join-Path $CacheRoot 'sqlite') -Force
}

# Lua 5.5 ships as .tar.gz; Windows' in-box bsdtar extracts it (present by
# contract since Windows 10 1803, and the build floor is far above that).
$luaEntry = $Lock.archives | Where-Object id -eq 'lua'
$luaArchive = Get-Archive $luaEntry
$luaStage = Join-Path $CacheRoot 'lua'
if (-not (Test-Path -LiteralPath (Join-Path $luaStage 'lua.h'))) {
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
        throw 'in-box tar.exe not found; cannot extract the Lua archive'
    }
    $luaExtract = Join-Path $SourceRoot ('.lua-extract-' + [Guid]::NewGuid().ToString('n'))
    Assert-UnderCache $luaExtract
    New-Item -ItemType Directory -Force -Path $luaExtract | Out-Null
    try {
        & $tar -xzf $luaArchive -C $luaExtract
        if ($LASTEXITCODE) { throw "tar extraction failed with exit code $LASTEXITCODE" }
        $luaSrc = Join-Path $luaExtract ('lua-' + $luaEntry.version + '\src')
        if (-not (Test-Path -LiteralPath (Join-Path $luaSrc 'lua.h'))) {
            throw 'Lua archive contains no src/lua.h after extraction'
        }
        New-Item -ItemType Directory -Force -Path $luaStage | Out-Null
        # The interpreter sources only: the standalone frontends (lua.c, luac.c)
        # never enter the build, so they never enter the cache either.
        Get-ChildItem -LiteralPath $luaSrc -File |
            Where-Object { $_.Extension -in @('.c', '.h') -and
                           $_.Name -notin @('lua.c', 'luac.c') } |
            Copy-Item -Destination $luaStage -Force
    } finally {
        if (Test-Path -LiteralPath $luaExtract) {
            [IO.Directory]::Delete($luaExtract, $true)
        }
    }
}

Write-ArtifactManifest
[IO.File]::WriteAllText($StatePath, "$StateHash`n", [Text.UTF8Encoding]::new($false))
Write-Host "dependency cache ready ($StateHash)"
