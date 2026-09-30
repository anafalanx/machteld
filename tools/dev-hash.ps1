param([switch]$LibraryOnly, [int]$OwnerProcessId = 0)
# A private line protocol for devcache.tcl. SHA-256 is supplied by .NET, not by
# the executable being rebuilt. One process handles the entire invocation.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toolchain-fingerprint.ps1')
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
public static class MachteldDevCache {
    static readonly Dictionary<string, FileStream> Locks = new Dictionary<string, FileStream>(StringComparer.OrdinalIgnoreCase);
    public static void WatchOwner(int id) {
        Process owner=Process.GetProcessById(id);
        var watcher=new Thread(delegate() { try { owner.WaitForExit(); } finally { Environment.Exit(0); } });
        watcher.IsBackground=true; watcher.Start();
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    static extern bool MoveFileExW(string from, string to, uint flags);
    static void Plain(string path) {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("cache input must not be a reparse point: " + path);
    }
    public static void Publish(string candidate, string output) {
        candidate=Path.GetFullPath(candidate); output=Path.GetFullPath(output);
        if (!String.Equals(Path.GetDirectoryName(candidate), Path.GetDirectoryName(output), StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(candidate).StartsWith(".machteld-cache-", StringComparison.Ordinal) ||
            String.Equals(candidate,output,StringComparison.OrdinalIgnoreCase))
            throw new IOException("invalid cache publication pair");
        Plain(candidate);
        if (!MoveFileExW(candidate,output,9)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void Lock(string path) { path=Path.GetFullPath(path); Locks.Add(path, new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)); }
    public static void Unlock(string path) { path=Path.GetFullPath(path); Locks[path].Dispose(); Locks.Remove(path); }
    static void CheckTree(string path) {
        Plain(path);
        if (Directory.Exists(path)) foreach (string child in Directory.GetFileSystemEntries(path)) CheckTree(child);
    }
    public static void Clean(string root) {
        root=Path.GetFullPath(root); Plain(root);
        string lockPath=Path.Combine(root,"build.lock");
        if (!Locks.ContainsKey(lockPath)) throw new IOException("cache clean requires the build lock");
        string[] entries=Directory.GetFileSystemEntries(root);
        // Validate the entire deletion set before removing anything. Never
        // traverse a junction/symlink, and retain the live lock's directory.
        foreach (string path in entries) {
            if (String.Equals(path,lockPath,StringComparison.OrdinalIgnoreCase)) continue;
            if (!Path.GetFullPath(path).StartsWith(root.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))
                throw new IOException("cache clean target escaped its root");
            CheckTree(path);
        }
        foreach (string path in entries) {
            if (String.Equals(path,lockPath,StringComparison.OrdinalIgnoreCase)) continue;
            if (Directory.Exists(path)) Directory.Delete(path,true); else File.Delete(path);
        }
    }
}
'@
if ($LibraryOnly) { return }
if ($OwnerProcessId -gt 0) { [MachteldDevCache]::WatchOwner($OwnerProcessId) }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
while ($null -ne ($line = [Console]::ReadLine())) {
    try {
        $words = $line.Split([char]9)
        if ($words[0] -eq 'quit') { [Console]::WriteLine("ok`tbye"); break }
        $arg = if ($words.Length -gt 1) { $utf8.GetString([Convert]::FromBase64String($words[1])) } else { '' }
        $result = switch -Exact ($words[0]) {
            'file' { [MachteldContentHash]::FileHash($arg) }
            'tree' { [MachteldContentHash]::Tree($arg) }
            'text' { [MachteldContentHash]::Text($arg) }
            'toolchain' { [MachteldContentHash]::Toolchain($arg) }
            'lock' { [MachteldDevCache]::Lock($arg); 'locked' }
            'unlock' { [MachteldDevCache]::Unlock($arg); 'unlocked' }
            'clean' { [MachteldDevCache]::Clean($arg); 'cleaned' }
            'publish' {
                $output = $utf8.GetString([Convert]::FromBase64String($words[2]))
                [MachteldDevCache]::Publish($arg, $output); 'published'
            }
            default { throw 'unknown cache helper operation' }
        }
        [Console]::WriteLine("ok`t$result")
    } catch {
        [Console]::WriteLine("error`t" + [Convert]::ToBase64String($utf8.GetBytes($_.Exception.Message)))
    }
}
