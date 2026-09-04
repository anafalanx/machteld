[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Machteld,
    [string]$CacheRoot
)

$ErrorActionPreference = 'Stop'
$Machteld = [IO.Path]::GetFullPath($Machteld)
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($CacheRoot) { $CacheRoot = [IO.Path]::GetFullPath($CacheRoot) }
$WorkLeaf = "machteld-version-resource-test-$PID-$([Guid]::NewGuid().ToString('n'))"
$Work = Join-Path ([IO.Path]::GetTempPath()) $WorkLeaf
$Failures = 0

if (-not ('MachteldVersionResource' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MachteldVersionResource
{
    [DllImport("version.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileVersionInfoSizeW(string fileName, out uint handle);

    [DllImport("version.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileVersionInfoW(
        string fileName, uint handle, uint length, byte[] data);

    [DllImport("version.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool VerQueryValueW(
        IntPtr block, string subBlock, out IntPtr value, out uint length);

    public static string QueryString(string fileName, string name)
    {
        uint ignored;
        uint size = GetFileVersionInfoSizeW(fileName, out ignored);
        if (size == 0)
            return null;

        byte[] data = new byte[size];
        if (!GetFileVersionInfoW(fileName, 0, size, data))
            return null;

        GCHandle pinned = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            IntPtr value;
            uint length;
            string query = @"\StringFileInfo\040904B0\" + name;
            if (!VerQueryValueW(pinned.AddrOfPinnedObject(), query, out value, out length) ||
                    value == IntPtr.Zero || length == 0)
                return null;
            return Marshal.PtrToStringUni(value, checked((int)length - 1));
        }
        finally
        {
            pinned.Free();
        }
    }
}
'@
}

$header = [IO.File]::ReadAllText((Join-Path $RepoRoot 'src\machteld.h'))
if ($header -notmatch '(?m)^#define\s+MACHTELD_VERSION\s+"([0-9]+)\.([0-9]+)(?:\.([0-9]+))?"\s*$') {
    throw 'src/machteld.h has no canonical MACHTELD_VERSION'
}
$Version = $Matches[1] + '.' + $Matches[2]
$numeric = @([int]$Matches[1], [int]$Matches[2], 0, 0)
if ($Matches[3]) {
    $Version += '.' + $Matches[3]
    $numeric[2] = [int]$Matches[3]
}

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "ok   $Name"; return }
    $script:Failures++
    Write-Host "FAIL $Name $Detail"
}

function Check-VersionResource(
    [string]$Label,
    [string]$Path,
    [string]$Description,
    [string]$InternalName,
    [string]$OriginalFilename
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Check "$Label exists" $false $Path
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    Check "$Label is not marked as a temporary file" `
        (($item.Attributes -band [IO.FileAttributes]::Temporary) -eq 0) `
        $item.Attributes
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    Check "$Label string versions are exact" `
        ($info.FileVersion -ceq $Version -and $info.ProductVersion -ceq $Version) `
        "file={$($info.FileVersion)} product={$($info.ProductVersion)}"
    Check "$Label numeric versions are padded deterministically" `
        ($info.FileMajorPart -eq $numeric[0] -and
         $info.FileMinorPart -eq $numeric[1] -and
         $info.FileBuildPart -eq $numeric[2] -and
         $info.FilePrivatePart -eq $numeric[3] -and
         $info.ProductMajorPart -eq $numeric[0] -and
         $info.ProductMinorPart -eq $numeric[1] -and
         $info.ProductBuildPart -eq $numeric[2] -and
         $info.ProductPrivatePart -eq $numeric[3]) `
        "file=$($info.FileMajorPart),$($info.FileMinorPart),$($info.FileBuildPart),$($info.FilePrivatePart) product=$($info.ProductMajorPart),$($info.ProductMinorPart),$($info.ProductBuildPart),$($info.ProductPrivatePart)"
    Check "$Label publisher identity is present" `
        ($info.CompanyName -ceq 'Vincent Vercauteren' -and
         $info.LegalCopyright -ceq 'Copyright 2026 Vincent Vercauteren' -and
         $info.ProductName -ceq 'Machteld') `
        "company={$($info.CompanyName)} copyright={$($info.LegalCopyright)} product={$($info.ProductName)}"
    $author = [MachteldVersionResource]::QueryString($Path, 'Author')
    Check "$Label custom author identity is present" `
        ($author -ceq 'Vincent Vercauteren') "author={$author}"
    Check "$Label host identity is present" `
        ($info.FileDescription -ceq $Description -and
         $info.InternalName -ceq $InternalName -and
         $info.OriginalFilename -ceq $OriginalFilename) `
        "description={$($info.FileDescription)} internal={$($info.InternalName)} original={$($info.OriginalFilename)}"
    Check "$Label carries release rather than development flags" `
        (-not $info.IsDebug -and -not $info.IsPatched -and
         -not $info.IsPreRelease -and -not $info.IsPrivateBuild -and
         -not $info.IsSpecialBuild)
}

function Find-EmbeddedBuildPaths([string]$Path) {
    $needles = [Collections.Generic.List[string]]::new()
    foreach ($root in @($RepoRoot, $CacheRoot)) {
        if (-not $root) { continue }
        $normalized = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $needles.Add($normalized)
        $needles.Add($normalized.Replace('\', '/'))
    }
    $needles.Add('/.cache/')
    $needles.Add('\.cache\')

    $bytes = [IO.File]::ReadAllBytes($Path)
    $singleByte = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $utf16Even = [Text.Encoding]::Unicode.GetString($bytes)
    $utf16Odd = if ($bytes.Length -gt 1) {
        [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    } else { '' }
    $found = [Collections.Generic.List[string]]::new()
    foreach ($needle in $needles) {
        if ($singleByte.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $utf16Even.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $utf16Odd.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $found.Add($needle)
        }
    }
    return @($found | Select-Object -Unique)
}

New-Item -ItemType Directory -Path $Work | Out-Null
try {
    Check-VersionResource 'full executable' $Machteld `
        'Machteld machine-control runtime' 'machteld' 'machteld.exe'
    $embeddedBuildPaths = @(Find-EmbeddedBuildPaths $Machteld)
    Check 'full executable carries no repository or dependency-cache path' `
        ($embeddedBuildPaths.Count -eq 0) ($embeddedBuildPaths -join ', ')

    $entry = Join-Path $Work 'main.tcl'
    [IO.File]::WriteAllText($entry, "package require machteld`nexit 0`n",
        [Text.UTF8Encoding]::new($false))
    $console = Join-Path $Work 'wrapped-console.exe'
    $gui = Join-Path $Work 'wrapped-gui.exe'

    & $Machteld wrap $entry -o $console --console
    Check 'console metadata fixture wraps successfully' `
        ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $console -PathType Leaf))
    if (Test-Path -LiteralPath $console -PathType Leaf) {
        Check-VersionResource 'wrapped console' $console `
            'Machteld machine-control runtime' 'machteld' 'machteld.exe'
        $consoleBuildPaths = @(Find-EmbeddedBuildPaths $console)
        Check 'wrapped console carries no repository or dependency-cache path' `
            ($consoleBuildPaths.Count -eq 0) ($consoleBuildPaths -join ', ')
    }

    & $Machteld wrap $entry -o $gui --gui
    Check 'GUI metadata fixture wraps successfully' `
        ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $gui -PathType Leaf))
    if (Test-Path -LiteralPath $gui -PathType Leaf) {
        Check-VersionResource 'wrapped GUI' $gui `
            'Machteld GUI application host' 'machteld-gui' 'machteld-gui.exe'
        $guiBuildPaths = @(Find-EmbeddedBuildPaths $gui)
        Check 'wrapped GUI carries no repository or dependency-cache path' `
            ($guiBuildPaths.Count -eq 0) ($guiBuildPaths -join ', ')
    }
} finally {
    if ((Split-Path -Leaf $Work) -ceq $WorkLeaf -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Work)),
                [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) -and
            (Test-Path -LiteralPath $Work -PathType Container)) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Failures) { throw "$Failures VERSIONINFO test(s) failed" }
Write-Host 'ALL VERSIONINFO TESTS PASSED'
