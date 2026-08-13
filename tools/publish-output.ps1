[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Output
)

$ErrorActionPreference = 'Stop'

$candidateFull = [IO.Path]::GetFullPath($Candidate)
$outputFull = [IO.Path]::GetFullPath($Output)
$candidateParent = [IO.Path]::GetDirectoryName($candidateFull)
$outputParent = [IO.Path]::GetDirectoryName($outputFull)
$candidateLeaf = [IO.Path]::GetFileName($candidateFull)

if (-not [StringComparer]::OrdinalIgnoreCase.Equals($candidateParent, $outputParent)) {
    throw 'publication candidate must be beside the requested output'
}
if ([StringComparer]::OrdinalIgnoreCase.Equals($candidateFull, $outputFull)) {
    throw 'publication candidate and requested output must be different paths'
}
if ($candidateLeaf -notmatch '^\.machteld-build-[0-9a-f]{32}\.exe$') {
    throw "publication candidate is not an invocation-owned Machteld build path: $candidateLeaf"
}
if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) {
    throw "publication candidate is not a file: $candidateFull"
}
$candidateItem = Get-Item -LiteralPath $candidateFull -Force
if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "publication candidate must not be a reparse point: $candidateFull"
}
if (Test-Path -LiteralPath $outputFull -PathType Container) {
    throw "requested output is a directory: $outputFull"
}

if (-not ('Machteld.Tools.NativeFilePublication' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

namespace Machteld.Tools
{
    public static class NativeFilePublication
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveFileExW(
            string existingFileName, string newFileName, uint flags);
    }
}
'@
}

# MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH. There is deliberately no
# managed delete/rename fallback: one same-directory kernel operation either
# creates/replaces the requested name or leaves both names untouched.
$moveFileReplaceExisting = [uint32]0x1
$moveFileWriteThrough = [uint32]0x8
$flags = $moveFileReplaceExisting -bor $moveFileWriteThrough
if (-not [Machteld.Tools.NativeFilePublication]::MoveFileExW(
        $candidateFull, $outputFull, $flags)) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw [ComponentModel.Win32Exception]::new(
        $code, "atomic publication failed for $outputFull")
}

Write-Host "published $outputFull"
