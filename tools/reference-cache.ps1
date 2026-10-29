# Optional development-only conversion cache. Each generation is immutable;
# manifests are inert JSON and hits require exact output inventory and hashes.
# The caller holds the shared development build lock. Release generation never
# supplies StageCache and therefore reconstructs all stages independently.

function Reference-StageKey([string]$Kind, [string[]]$Files, [string]$Extra = '') {
    $rows = New-Object Collections.Generic.List[string]
    $rows.Add("reference-stage-v2`0$Kind`0$Extra")
    $rootPrefix = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
    $inputs = New-Object 'Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($file in $Files) {
        $full = [IO.Path]::GetFullPath($file)
        # Repository-relative logical names make an identical fixture checkout
        # share conversion results without dropping filenames from the key.
        $relative = if ($full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $full.Substring($rootPrefix.Length).Replace('\','/')
        } else { '' }
        # A dependency cache may happen to live below the original checkout.
        # Keep external Tcl/archive identities external in a copied fixture too.
        $logical = if ($relative -cmatch '^(tools|docs)/') {
            'repo/' + $relative
        } else { 'external/' + $full.Replace('\','/') }
        $inputs.Add($logical, $full)
    }
    foreach ($entry in $inputs.GetEnumerator()) { $rows.Add("$($entry.Key)`0$(Get-Sha256 $entry.Value)") }
    return Get-BytesSha256 $script:Utf8NoBom.GetBytes([string]::Join("`n", $rows))
}

function Assert-ReferenceCachePath([string]$Path) {
    $probe = [IO.Path]::GetFullPath($Path)
    while ($probe) {
        if (([IO.Directory]::Exists($probe) -or [IO.File]::Exists($probe)) -and
            ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "reference cache path traverses a reparse point: $probe"
        }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
}

function Reference-StageInventory([string]$Root) {
    $result = [ordered]@{}
    $rootItem = Get-Item -LiteralPath $Root -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reference cache root is a reparse point' }
    # Inspect directories before recursing, so a junction is never traversed.
    $pending = New-Object Collections.Generic.Queue[string]
    $pending.Enqueue($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reference cache contains a reparse point' }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
            else {
                $relative = $item.FullName.Substring($Root.Length).TrimStart('\').Replace('\','/')
                $result[$relative] = Get-Sha256 $item.FullName
            }
        }
    }
    return $result
}

function Read-ReferenceStage([string]$Kind, [string]$Key, [string]$Destination) {
    if (-not $StageCache) { return $null }
    $record = Join-Path $StageCache "$Kind-$Key.json"
    try {
        Assert-ReferenceCachePath $StageCache
        if (-not [IO.File]::Exists($record) -or (Get-Item -LiteralPath $record).Length -gt 4MB) { return $null }
        $entry = [MachteldReferenceData]::Ordered((Read-Utf8Strict $record | ConvertFrom-Json))
        if ($entry.schema -ne 1 -or $entry.key -cne $Key -or $entry.generation -cnotmatch '^stage-[0-9a-f]{32}$') { return $null }
        $stage = Join-Path $StageCache $entry.generation
        $actual = Reference-StageInventory $stage
        if ($actual.Count -ne $entry.inventory.Count) { return $null }
        foreach ($path in $actual.Keys) {
            if (-not $entry.inventory.Contains($path) -or $actual[$path] -cne $entry.inventory[$path]) { return $null }
        }
        $statePath = Join-Path $stage 'state.json'
        if (-not [IO.File]::Exists($statePath) -or (Get-Item -LiteralPath $statePath).Length -gt 16MB) { return $null }
        $state = [MachteldReferenceData]::Ordered((Read-Utf8Strict $statePath | ConvertFrom-Json))
        foreach ($path in $actual.Keys) {
            if ($path -eq 'state.json') { continue }
            Copy-Bytes (Join-Path $stage $path) (Join-Path $Destination $path)
        }
        return $state
    } catch { Write-Host "reference: $Kind cache rejected ($($_.Exception.Message))"; return $null }
}

function Write-ReferenceStage([string]$Kind, [string]$Key, [string]$Source, $State) {
    if (-not $StageCache) { return }
    Assert-ReferenceCachePath $StageCache
    [IO.Directory]::CreateDirectory($StageCache) | Out-Null
    $generation = 'stage-' + [Guid]::NewGuid().ToString('n')
    $stage = Join-Path $StageCache $generation
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    # Copy only files belonging to these stage records. Upstream auxiliary HTML
    # and source includes are part of that conversion as well.
    $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($document in $State.documents.Values) {
        foreach ($format in $document.formats.Values) { [void]$paths.Add($format.path) }
    }
    if ($Kind -eq 'upstream') {
        foreach ($dir in @('html','source')) {
            foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Source $dir) -Recurse -File) {
                [void]$paths.Add($file.FullName.Substring($Source.Length).TrimStart('\').Replace('\','/'))
            }
        }
    }
    foreach ($path in $paths) { Copy-Bytes (Join-Path $Source $path) (Join-Path $stage $path) }
    Write-Utf8Lf (Join-Path $stage 'state.json') (Convert-JsonDeterministic $State)
    $entry = [ordered]@{schema=1;key=$Key;generation=$generation;inventory=(Reference-StageInventory $stage)}
    $record = Join-Path $StageCache "$Kind-$Key.json"
    $temporary = Join-Path $StageCache ('.record-' + [Guid]::NewGuid().ToString('n'))
    Write-Utf8Lf $temporary (Convert-JsonDeterministic $entry)
    # Keep old generations recoverable; only the tiny verified pointer changes.
    [MachteldReferenceData]::PublishRecord($temporary, $record)
}
