# Shared byte-level hashing for bootstrap provenance and incremental stages.
# No cache-by-mtime: toolchain changes with preserved timestamps are detected.
if (-not ('MachteldContentHash' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
public static class MachteldContentHash {
    static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    public static string Text(string text) {
        using (var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Utf8.GetBytes(text))).Replace("-", "").ToLowerInvariant();
    }
    static void Plain(string path) {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("cache input must not be a reparse point: " + path);
    }
    public static string FileHash(string path) {
        if (!File.Exists(path)) return "missing";
        Plain(path);
        using (var sha=SHA256.Create()) using (var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read))
            return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
    }
    static void Walk(string root, string relative, StringBuilder material) {
        string directory=Path.Combine(root,relative); Plain(directory);
        string[] entries=Directory.GetFileSystemEntries(directory); Array.Sort(entries,StringComparer.Ordinal);
        foreach (string path in entries) {
            Plain(path);
            string name=relative.Length==0 ? Path.GetFileName(path) : relative+"/"+Path.GetFileName(path);
            bool dir=Directory.Exists(path);
            material.Append(dir ? "D\0" : "F\0").Append(name).Append('\0');
            if (dir) Walk(root,name,material); else material.Append(FileHash(path)).Append('\0');
        }
    }
    public static string Tree(string path) {
        if (!Directory.Exists(path)) return "missing";
        var material=new StringBuilder(); Walk(path,"",material); return Text(material.ToString());
    }
    static void Files(string root, string relative, string pattern, StringBuilder material) {
        string directory=Path.Combine(root,relative);
        material.Append(relative).Append('\0').Append(pattern).Append('\0');
        if (!Directory.Exists(directory)) { material.Append("missing\0"); return; }
        Plain(directory);
        string[] files=Directory.GetFiles(directory,pattern); Array.Sort(files,StringComparer.Ordinal);
        foreach (string file in files) material.Append(Path.GetFileName(file)).Append('\0').Append(FileHash(file)).Append('\0');
    }
    public static string Toolchain(string root) {
        root=Path.GetFullPath(root);
        var material=new StringBuilder("machteld-toolchain-v1\0"); material.Append(root).Append('\0');
        // C headers, compiler support, target utilities, CRT and import/static
        // libraries. Exclude unrelated Python/Tcl/etc installed in ucrt64/lib.
        foreach (string part in new string[]{"ucrt64/include","ucrt64/lib/gcc","ucrt64/libexec/gcc","ucrt64/x86_64-w64-mingw32","usr/bin"})
            material.Append(part).Append('\0').Append(Tree(Path.Combine(root,part))).Append('\0');
        Files(root,"ucrt64/lib","*",material);
        Files(root,"ucrt64/bin","*.dll",material);
        foreach (string name in new string[]{"gcc","cpp","as","ld","ar","ranlib","strip","windres","mingw32-make"})
            material.Append(name).Append('\0').Append(FileHash(Path.Combine(root,"ucrt64/bin/"+name+".exe"))).Append('\0');
        return Text(material.ToString());
    }
}
'@
}
