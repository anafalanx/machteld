[CmdletBinding()]
param([Parameter(Mandatory)][string]$Machteld)

# Headless Windows-resource and wrapped-identity gate. GUI wrappers are read as
# data only; this script never launches a GUI executable or displays a window.
$ErrorActionPreference = 'Stop'
$Machteld = [IO.Path]::GetFullPath($Machteld)
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$WorkLeaf = "machteld-app-identity-$PID-$([Guid]::NewGuid().ToString('n'))"
$Work = Join-Path ([IO.Path]::GetTempPath()) $WorkLeaf
$Failures = 0
$Checks = 0
$Utf8 = [Text.UTF8Encoding]::new($false)

if (-not ('MachteldAppIdentityNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class MachteldAppIdentityNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr FindResourceExW(IntPtr module, IntPtr type, IntPtr name, ushort language);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr LockResource(IntPtr resource);
    [DllImport("version.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFileVersionInfoSizeW(string path, out uint handle);
    [DllImport("version.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetFileVersionInfoW(string path, uint handle, uint length, byte[] data);
    [DllImport("version.dll", CharSet=CharSet.Unicode)]
    static extern bool VerQueryValueW(IntPtr block, string key, out IntPtr value, out uint length);
    public static byte[] Resource(string path, int type, int name, ushort language) {
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr entry = FindResourceExW(module, new IntPtr(type), new IntPtr(name), language);
            if (entry == IntPtr.Zero) return null;
            uint size = SizeofResource(module, entry);
            IntPtr loaded = LoadResource(module, entry);
            IntPtr data = LockResource(loaded);
            if (data == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] bytes = new byte[checked((int)size)];
            Marshal.Copy(data, bytes, 0, bytes.Length);
            return bytes;
        } finally { FreeLibrary(module); }
    }
    public static string String(string path, string key) {
        uint ignored;
        uint size = GetFileVersionInfoSizeW(path, out ignored);
        if (size == 0) return null;
        byte[] bytes = new byte[size];
        if (!GetFileVersionInfoW(path, 0, size, bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
        GCHandle pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try {
            IntPtr text; uint length;
            if (!VerQueryValueW(pin.AddrOfPinnedObject(), @"\StringFileInfo\040904B0\" + key, out text, out length) || length == 0)
                return null;
            return Marshal.PtrToStringUni(text, checked((int)length - 1));
        } finally { pin.Free(); }
    }
}
'@
}

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    $script:Checks++
    if ($Condition) { Write-Host "ok   $Name" } else { $script:Failures++; Write-Host "FAIL $Name $Detail" }
}
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $Utf8) }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Hex-Bytes([string]$Hex) {
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$bytes
}
function Resource-Text([string]$Path, [int]$Type, [int]$Id, [int]$Language) {
    $bytes = [MachteldAppIdentityNative]::Resource($Path, $Type, $Id, $Language)
    if ($null -eq $bytes) { return '' }
    return [Convert]::ToBase64String($bytes)
}
function Invoke-Runtime([string[]]$Arguments) {
    $savedPreference = $ErrorActionPreference
    $savedEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        [Console]::OutputEncoding = $Utf8
        $text = (& $Machteld @Arguments 2>&1 | Out-String)
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $text }
    } finally {
        [Console]::OutputEncoding = $savedEncoding
        $ErrorActionPreference = $savedPreference
    }
}
function Write-Manifest([string]$Metadata) {
    Write-Utf8 $Manifest "schema 1 files {main.tcl} metadata {$Metadata}`n"
}
function Assert-Refused([string]$Label, [string[]]$Arguments, [string]$Protected) {
    $before = Hash $Protected
    $result = Invoke-Runtime $Arguments
    Check "$Label refuses invalid wrapping" ($result.Exit -ne 0) $result.Text
    Check "$Label preserves the existing file byte-for-byte" ((Hash $Protected) -ceq $before)
}

$hostHash = Hash $Machteld
New-Item -ItemType Directory -Path $Work | Out-Null
try {
    $Probe = Join-Path $Work 'inspect.tcl'
    Write-Utf8 $Probe @'
package require machteld
proc read_bytes {path} {
    set ch [open $path rb]
    try { return [read $ch] } finally { close $ch }
}
proc optional_file {root name} {
    set path [file join $root $name]
    if {![file isfile $path]} { return "" }
    return [binary encode base64 -maxlen 0 [read_bytes $path]]
}
if {[lindex $argv 0] eq "extract"} {
    set root [::machteld::PayloadRoot]
    set destination [lindex $argv 1]
    file mkdir $destination
    foreach kind {console gui} { file copy [file join $root basekit $kind.exe] [file join $destination $kind.exe] }
    puts [json encode -dict [dict create build_info [optional_file $root build-info.dict] runtime_version [version]]]
} else {
    zipfs mount [lindex $argv 1] identity_inspect
    set root //zipfs:/identity_inspect
    try {
        set info [encoding convertfrom utf-8 [read_bytes [file join $root app-info.dict]]]
        set metadata [dict get $info metadata]
        set result [dict create build_info [optional_file $root build-info.dict] \
            schema [dict get $info schema] entry [dict get $info entry] host [dict get $info host] \
            runtime_name [dict get $info runtime name] runtime_version [dict get $info runtime version] \
            runtime_author [dict get $info runtime author] \
            files [dict keys [dict get $info files]] app_main [hash file sha256 [file join $root app main.tcl]] \
            payload_icon [file exists [file join $root app icon.ico]] \
            has_reference [file exists [file join $root reference]] \
            metadata_icon [dict get $metadata icon]]
        foreach field {name description version author publisher copyright internal_name original_filename} {
            dict set result $field [dict get $metadata $field]
        }
        if {[dict get $metadata icon] ne ""} {
            dict set result icon_hash [dict get $metadata icon sha256]
            dict set result icon_bytes [dict get $metadata icon bytes]
        }
        puts [json encode -dict $result]
    } finally { zipfs unmount identity_inspect }
}
'@
    $Bare = Join-Path $Work 'bare'
    $extracted = Invoke-Runtime @($Probe, 'extract', $Bare)
    if ($extracted.Exit) { throw "cannot extract embedded basekits: $($extracted.Text)" }
    $runtime = $extracted.Text | ConvertFrom-Json
    $NativeWork = Join-Path $Work 'native'
    $native = Invoke-Runtime @((Join-Path $PSScriptRoot 'identity_native_test.tcl'),
        (Join-Path $Bare 'console.exe'), (Join-Path $Bare 'gui.exe'), $NativeWork)
    Write-Host $native.Text.TrimEnd()
    Check 'private native validation suite passes against packaged executable' ($native.Exit -eq 0) $native.Text
    if ($native.Exit) { throw 'private identity suite failed' }

    $Omega = [string][char]0x03a9
    $Rocket = [char]::ConvertFromUtf32(0x1f680)
    foreach ($kind in @('console', 'gui')) {
        $bareHost = Join-Path $Bare "$kind.exe"
        $nativeHost = Join-Path $NativeWork "$kind-$Omega.exe"
        Check "$kind native stamping preserves unrelated Windows manifest bytes" `
            ((Resource-Text $nativeHost 24 1 0) -ceq (Resource-Text $bareHost 24 1 0) -and
             (Resource-Text $bareHost 24 1 0) -ne '')
        Check "$kind repeated icon replacement removes stale image IDs" `
            ($null -ne [MachteldAppIdentityNative]::Resource($nativeHost, 3, 1, 0x409) -and
             $null -eq [MachteldAppIdentityNative]::Resource($nativeHost, 3, 2, 0x409))
    }

    $App = Join-Path $Work 'app'
    New-Item -ItemType Directory -Path $App | Out-Null
    $Entry = Join-Path $App 'main.tcl'
    Write-Utf8 $Entry "package require machteld`nputs APP-IDENTITY-OK`n"
    $Manifest = Join-Path $Work 'payload.dict'
    $Icon = Join-Path $Work 'icon.ico'
    Copy-Item -LiteralPath (Join-Path $NativeWork 'valid-multiple.ico') -Destination $Icon
    $AppName = "Project desk $Omega $Rocket"
    $Description = "Administration $Omega $Rocket"
    $Author = "App Author $Omega"
    $Publisher = "App Publisher $Omega"
    $Copyright = "Copyright 2026 App Author $Omega"
    $custom = "name {$AppName} version 7.8 description {$Description} author {$Author} publisher {$Publisher} copyright {$Copyright} icon icon.ico"
    Write-Manifest $custom
    foreach ($kind in @('console', 'gui')) {
        $target = Join-Path $Work "custom-$kind-$Omega.exe"
        $arguments = @('wrap', $App, '--manifest', $Manifest, '-o', $target, "--$kind")
        $planned = Invoke-Runtime ($arguments + '--plan')
        Check "$kind identity plan validates without creating output" `
            ($planned.Exit -eq 0 -and -not (Test-Path -LiteralPath $target)) $planned.Text
        $result = Invoke-Runtime $arguments
        Check "$kind custom identity wraps successfully" ($result.Exit -eq 0 -and (Test-Path -LiteralPath $target)) $result.Text
        if ($result.Exit) { continue }
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($target)
        Check "$kind Windows properties preserve Unicode name and description" `
            ($version.ProductName -ceq $AppName -and $version.FileDescription -ceq $Description)
        Check "$kind application versions are independent from runtime version" `
            ($version.FileVersion -ceq '7.8' -and $version.ProductVersion -ceq '7.8' -and
             $version.FileMajorPart -eq 7 -and $version.FileMinorPart -eq 8 -and
             $version.FileBuildPart -eq 0 -and $version.FilePrivatePart -eq 0)
        Check "$kind explicit authorship appears exactly in Windows properties" `
            ($version.CompanyName -ceq $Publisher -and $version.LegalCopyright -ceq $Copyright -and
             [MachteldAppIdentityNative]::String($target, 'Author') -ceq $Author)
        Check "$kind application filenames describe the output, not Machteld" `
            ($version.InternalName -ceq [IO.Path]::GetFileNameWithoutExtension($target) -and
             $version.OriginalFilename -ceq [IO.Path]::GetFileName($target))
        Check "$kind Windows properties label runtime identity separately" `
            ([MachteldAppIdentityNative]::String($target, 'MachteldRuntimeVersion') -ceq $runtime.runtime_version -and
             [MachteldAppIdentityNative]::String($target, 'MachteldRuntimeAuthor') -ceq 'Vincent Vercauteren')
        $bareHost = Join-Path $Bare "$kind.exe"
        Check "$kind wrapped identity preserves the Windows manifest resource" `
            ((Resource-Text $target 24 1 0) -ceq (Resource-Text $bareHost 24 1 0))
        $group = [MachteldAppIdentityNative]::Resource($target, 14, 1, 0x409)
        Check "$kind custom multi-image icon has the expected resource group" `
            ($null -ne $group -and $group.Length -eq 34 -and [BitConverter]::ToUInt16($group, 4) -eq 2)
        $iconFile = [IO.File]::ReadAllBytes($Icon)
        for ($index = 0; $index -lt 2; $index++) {
            $size = [BitConverter]::ToUInt32($iconFile, 6 + 16 * $index + 8)
            $offset = [BitConverter]::ToUInt32($iconFile, 6 + 16 * $index + 12)
            $expected = [Convert]::ToBase64String($iconFile, $offset, $size)
            Check "$kind icon image $index retains exact PNG/DIB bytes" `
                ((Resource-Text $target 3 ($index + 1) 0x409) -ceq $expected)
        }
        $inspected = Invoke-Runtime @($Probe, 'inspect', $target)
        Check "$kind stamped executable retains a readable application ZIP" ($inspected.Exit -eq 0) $inspected.Text
        if ($inspected.Exit -eq 0) {
            $payload = $inspected.Text | ConvertFrom-Json
            Check "$kind application identity record matches Windows identity" `
                ($payload.name -ceq $AppName -and $payload.description -ceq $Description -and
                 $payload.version -ceq '7.8' -and $payload.author -ceq $Author -and
                 $payload.publisher -ceq $Publisher -and $payload.copyright -ceq $Copyright)
            Check "$kind runtime provenance remains separate and byte-identical" `
                ($payload.runtime_name -ceq 'Machteld' -and $payload.runtime_version -ceq $runtime.runtime_version -and
                 $payload.runtime_author -ceq 'Vincent Vercauteren' -and $payload.build_info -ceq $runtime.build_info)
            Check "$kind exact selected payload and icon provenance survive stamping" `
                ($payload.schema -eq 1 -and $payload.entry -ceq 'app/main.tcl' -and $payload.host -ceq $kind -and
                 $payload.files -ceq 'main.tcl' -and $payload.app_main -ceq (Hash $Entry) -and
                 $payload.payload_icon -eq 0 -and $payload.has_reference -eq 0 -and
                 $payload.icon_hash -ceq (Hash $Icon) -and $payload.icon_bytes -eq $iconFile.Length)
        }
        if ($kind -eq 'console') {
            $ran = (& $target | Out-String)
            Check 'custom console application still executes its own entry' `
                ($LASTEXITCODE -eq 0 -and $ran.Trim() -ceq 'APP-IDENTITY-OK') $ran
        }
    }

    $minimal = Join-Path $Work 'minimal.exe'
    Write-Manifest 'name {Unattributed app} version 1.2.3.4'
    $result = Invoke-Runtime @('wrap', $App, '--manifest', $Manifest, '-o', $minimal)
    Check 'minimal explicit metadata wraps without inventing ownership' ($result.Exit -eq 0) $result.Text
    if ($result.Exit -eq 0) {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($minimal)
        Check 'omitted description defaults to app name and all ownership remains blank' `
            ($version.FileDescription -ceq 'Unattributed app' -and $version.CompanyName -ceq '' -and
             $version.LegalCopyright -ceq '' -and [MachteldAppIdentityNative]::String($minimal, 'Author') -ceq '')
        Check 'four-part application version is exact in text and numeric tuple' `
            ($version.FileVersion -ceq '1.2.3.4' -and $version.FileMajorPart -eq 1 -and
             $version.FileMinorPart -eq 2 -and $version.FileBuildPart -eq 3 -and $version.FilePrivatePart -eq 4)
    }
    $ManifestParent = $Manifest
    $Nested = Join-Path $Work 'manifests'
    New-Item -ItemType Directory -Path $Nested | Out-Null
    foreach ($iconPath in @('../icon.ico', $Icon.Replace('\', '/'))) {
        $Manifest = Join-Path $Nested 'payload.dict'
        Write-Manifest "name {Icon path app} version 1 icon {$iconPath}"
        $pathOutput = Join-Path $Work 'icon-path.exe'
        $result = Invoke-Runtime @('wrap', $App, '--manifest', $Manifest, '-o', $pathOutput)
        Check 'explicit parent-relative or absolute icon path resolves from manifest' `
            ($result.Exit -eq 0 -and $null -ne [MachteldAppIdentityNative]::Resource($pathOutput, 14, 1, 0x409)) $result.Text
    }
    $Manifest = $ManifestParent
    Write-Manifest $custom
    $EmptyPath = Join-Path $Work 'empty-tool-path'
    New-Item -ItemType Directory -Path $EmptyPath | Out-Null
    $savedPath = $env:PATH
    try {
        $env:PATH = $EmptyPath
        $compilerFree = Join-Path $Work 'compiler-free.exe'
        $result = Invoke-Runtime @('wrap', $App, '--manifest', $Manifest, '-o', $compilerFree)
    } finally { $env:PATH = $savedPath }
    Check 'custom identity and icon wrap with no compiler or helper on PATH' `
        ($result.Exit -eq 0 -and (Test-Path -LiteralPath $compilerFree) -and
         [Diagnostics.FileVersionInfo]::GetVersionInfo($compilerFree).ProductName -ceq $AppName -and
         $null -ne [MachteldAppIdentityNative]::Resource($compilerFree, 14, 1, 0x409)) $result.Text
    $protected = Join-Path $Work 'protected.exe'
    [IO.File]::WriteAllBytes($protected, (Hex-Bytes '00112233445566778899aabbccddeeff'))
    foreach ($invalid in @('name Demo', 'version 1', 'name Demo version 65536', 'name Demo version 1.2.3.4.5',
            "name Demo version 1 description {$([char]0x0085)}", "name {$([string]::new('x', 1025))} version 1", 'name Demo version 1 unknown nope')) {
        Write-Manifest $invalid
        Assert-Refused 'invalid metadata' @('wrap', $App, '--manifest', $Manifest, '-o', $protected) $protected
    }
    Write-Manifest 'name Demo version 1 icon broken.ico'
    $broken = Join-Path $Work 'broken.ico'
    [IO.File]::WriteAllBytes($broken, (Hex-Bytes '000001000100'))
    Assert-Refused 'malformed icon' @('wrap', $App, '--manifest', $Manifest, '-o', $protected) $protected
    Assert-Refused 'malformed icon plan' @('wrap', $App, '--manifest', $Manifest, '-o', $protected, '--plan') $protected
    Write-Manifest $custom
    Assert-Refused 'output equal to icon' @('wrap', $App, '--manifest', $Manifest, '-o', $Icon) $Icon
    $iconAlias = Join-Path $Work 'icon-hardlink.exe'
    New-Item -ItemType HardLink -Path $iconAlias -Target $Icon | Out-Null
    Assert-Refused 'output hardlinked to icon' @('wrap', $App, '--manifest', $Manifest, '-o', $iconAlias) $Icon
    Check 'identity tests never mutate the tested Machteld executable' ((Hash $Machteld) -ceq $hostHash)
} finally {
    if ((Split-Path -Leaf $Work) -ceq $WorkLeaf -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Work)),
                [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) -and
            (Test-Path -LiteralPath $Work -PathType Container)) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($Failures) { throw "$Failures of $Checks app identity checks failed" }
Write-Host "ALL $Checks APP IDENTITY CHECKS PASSED"
