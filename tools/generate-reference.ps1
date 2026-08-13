[CmdletBinding()]
param(
    [string]$CacheRoot,
    [string]$Output,
    [string]$Tclsh,
    [switch]$KeepWork
)

# Build the complete, offline reference carried by machteld.  Inputs are the
# hash-pinned source archives, not the mutable dependency source checkout.
# Every output byte is deterministic and every inventory decision is explicit.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $CacheRoot) { $CacheRoot = Join-Path $RepoRoot '.cache\deps' }
if (-not $Output) { $Output = Join-Path $RepoRoot 'out\reference' }
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
$Output = [IO.Path]::GetFullPath($Output)
$LockPath = Join-Path $PSScriptRoot 'dependencies.lock.json'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$GeneratorVersion = 'machteld-reference-v1'

function Fail([string]$Message) { throw "generate-reference: $Message" }

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Read-Utf8Strict([string]$Path) {
    $strict = New-Object Text.UTF8Encoding($false, $true)
    try { return $strict.GetString([IO.File]::ReadAllBytes($Path)) }
    catch { Fail "not valid UTF-8: $Path" }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-Archive([string]$Path, [string]$Expected, [string]$Name) {
    if (-not [IO.File]::Exists($Path)) { Fail "missing pinned $Name archive: $Path" }
    $actual = Get-Sha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        Fail "$Name archive SHA-256 mismatch: expected $Expected, got $actual"
    }
}

function Assert-NoSurrogates([string]$Text, [string]$Label) {
    # Tcl's string offsets count Unicode characters while .NET indexes UTF-16
    # code units.  The upstream corpus currently contains no non-BMP text.  A
    # future occurrence fails closed instead of publishing divergent offsets.
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ([char]::IsSurrogate($Text[$i])) {
            Fail "$Label contains non-BMP text; section offset encoding must be upgraded"
        }
    }
}

function Copy-Bytes([string]$Source, [string]$Destination) {
    $parent = [IO.Path]::GetDirectoryName($Destination)
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllBytes($Destination, [IO.File]::ReadAllBytes($Source))
}

function Normalize-SlashPath([string]$Path) {
    $value = $Path.Replace('\', '/')
    if ($value -eq '' -or $value.StartsWith('/') -or $value.EndsWith('/') -or
            $value.Contains(':') -or $value -match '[\x00-\x1f\x7f]' -or
            $value -match '(^|/)\.\.?(/|$)' -or $value.Contains('//')) {
        Fail "unsafe logical reference path: $Path"
    }
    return $value
}

function Resolve-LogicalPath([string]$BaseFile, [string]$Relative) {
    $parts = New-Object Collections.Generic.List[string]
    $baseParts = $BaseFile.Replace('\', '/').Split('/')
    for ($i = 0; $i -lt $baseParts.Length - 1; $i++) {
        if ($baseParts[$i]) { $parts.Add($baseParts[$i]) }
    }
    foreach ($part in $Relative.Replace('\', '/').Split('/')) {
        if ($part -eq '' -or $part -eq '.') { continue }
        if ($part -eq '..') {
            if ($parts.Count -eq 0) { Fail "relative link escapes HTML root: $BaseFile -> $Relative" }
            $parts.RemoveAt($parts.Count - 1)
        } else { $parts.Add($part) }
    }
    return [string]::Join('/', $parts.ToArray())
}

function Slug([string]$Text) {
    $text = [Net.WebUtility]::HtmlDecode($Text).ToLowerInvariant()
    $builder = New-Object Text.StringBuilder
    $dash = $false
    foreach ($c in $text.ToCharArray()) {
        if ([char]::IsLetterOrDigit($c)) {
            [void]$builder.Append($c); $dash = $false
        } elseif (-not $dash -and $builder.Length -gt 0) {
            [void]$builder.Append('-'); $dash = $true
        }
    }
    return $builder.ToString().Trim('-')
}

function Normalize-Search([string]$Text) {
    # Keep the contract to lowercase + collapsed whitespace. The pinned corpus
    # is gated below against known .NET/Tcl BMP case/whitespace divergences;
    # do not add normalization forms that the embedded resolver cannot apply.
    $text = $Text.ToLowerInvariant()
    return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

function Sort-Ordinal([object[]]$Values, [scriptblock]$Key = { param($x) [string]$x }) {
    $items = @($Values)
    [Array]::Sort($items, [Comparison[object]]{
        param($a,$b)
        return [StringComparer]::Ordinal.Compare((& $Key $a), (& $Key $b))
    })
    return $items
}

function Strip-Markdown([string]$Text) {
    $text = $Text -replace '<a id="[^"]+"></a>', ' '
    $text = $text -replace '!\[([^\]]*)\]\([^)]*\)', '$1'
    $text = $text -replace '\[([^\]]+)\]\([^)]*\)', '$1'
    $text = $text -replace '[`*_#>|]', ' '
    return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

function Rewrite-AuthoredLinks([string]$Text, [string]$SourceKind) {
    return [regex]::Replace($Text, '\[([^\]]+)\]\(([^)]+)\)', {
        param($m)
        $label=$m.Groups[1].Value;$target=$m.Groups[2].Value
        if($target -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $target.StartsWith('#')){return $m.Value}
        $parts=$target.Split('#',2);$path=$parts[0];$fragment=if($parts.Count-eq2){'#'+$parts[1]}else{''}
        if($SourceKind -eq 'guide'){
            if($path -match '^reference/machteld/(index|agent)\.md$'){$stable="machteld/$($Matches[1])"}
            elseif($path -match '^reference/machteld/command/([a-z0-9-]+)\.md$'){$stable="machteld/command/$($Matches[1])"}
            elseif($path -match '^([a-z0-9-]+)\.md$'){$stable="machteld/guide/$($Matches[1])"}
            else{Fail "unsupported authored guide link target $target"}
        }else{
            if($path -match '^command/([a-z0-9-]+)\.md$'){$stable="machteld/command/$($Matches[1])"}
            elseif($path -match '^(index|agent)\.md$'){$stable="machteld/$($Matches[1])"}
            else{Fail "unsupported authored reference link target $target"}
        }
        return "[$label]($stable$fragment)"
    })
}

function Tcl-Word([string]$Value) {
    if ($Value.Length -eq 0) { return '{}' }
    $b = New-Object Text.StringBuilder
    foreach ($c in $Value.ToCharArray()) {
        $code=[int][char]$c
        switch ($code) {
            8  { [void]$b.Append('\b'); continue }
            9  { [void]$b.Append('\t'); continue }
            10 { [void]$b.Append('\n'); continue }
            11 { [void]$b.Append('\v'); continue }
            12 { [void]$b.Append('\f'); continue }
            13 { [void]$b.Append('\r'); continue }
            32 { [void]$b.Append('\ '); continue }
            34 { [void]$b.Append('\"'); continue }
            36 { [void]$b.Append('\$'); continue }
            59 { [void]$b.Append('\;'); continue }
            91 { [void]$b.Append('\['); continue }
            92 { [void]$b.Append('\\'); continue }
            93 { [void]$b.Append('\]'); continue }
            123 { [void]$b.Append('\{'); continue }
            125 { [void]$b.Append('\}'); continue }
            default {
                if($code-lt32-or$code-eq127-or[char]::IsWhiteSpace($c)){
                    [void]$b.Append(('\u{0:x4}'-f$code))
                }else{[void]$b.Append($c)}
            }
        }
    }
    return $b.ToString()
}

function Dictionary-Keys([Collections.IDictionary]$Value) {
    $keys = New-Object Collections.Generic.List[object]
    foreach ($entry in $Value.GetEnumerator()) { $keys.Add($entry.Key) }
    return $keys.ToArray()
}

function Tcl-Data($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [Collections.IDictionary]) {
        $words = New-Object Collections.Generic.List[string]
        foreach ($entry in $Value.GetEnumerator()) {
            $words.Add((Tcl-Word ([string]$entry.Key)))
            $words.Add((Tcl-Word (Tcl-Data $entry.Value)))
        }
        return [string]::Join(' ', $words.ToArray())
    }
    if (($Value -is [Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $words = New-Object Collections.Generic.List[string]
        foreach ($item in $Value) { $words.Add((Tcl-Word (Tcl-Data $item))) }
        return [string]::Join(' ', $words.ToArray())
    }
    if ($Value -is [bool]) { if ($Value) { return '1' } else { return '0' } }
    return [string]$Value
}

function Convert-JsonDeterministic($Value) {
    function Json-String([string]$s) {
        $b=New-Object Text.StringBuilder;[void]$b.Append('"')
        foreach($c in $s.ToCharArray()){
            switch([int][char]$c){
                8 {[void]$b.Append('\b')} 9 {[void]$b.Append('\t')} 10 {[void]$b.Append('\n')}
                12 {[void]$b.Append('\f')} 13 {[void]$b.Append('\r')} 34 {[void]$b.Append('\"')}
                92 {[void]$b.Append('\\')}
                default {if([int][char]$c-lt32){[void]$b.Append(('\u{0:x4}'-f[int][char]$c))}else{[void]$b.Append($c)}}
            }
        }
        [void]$b.Append('"');return $b.ToString()
    }
    function Json-Value($v){
        if($null-eq$v){return 'null'}
        if($v-is[Collections.IDictionary]){$parts=New-Object Collections.Generic.List[string];foreach($entry in $v.GetEnumerator()){$parts.Add((Json-String ([string]$entry.Key))+':'+(Json-Value $entry.Value))};return '{'+[string]::Join(',',$parts.ToArray())+'}'}
        if(($v-is[Collections.IEnumerable])-and-not($v-is[string])){$parts=New-Object Collections.Generic.List[string];foreach($x in $v){$parts.Add((Json-Value $x))};return '['+[string]::Join(',',$parts.ToArray())+']'}
        if($v-is[bool]){if($v){return 'true'}else{return 'false'}}
        if($v-is[byte]-or$v-is[int16]-or$v-is[int32]-or$v-is[int64]-or$v-is[uint16]-or$v-is[uint32]-or$v-is[uint64]){return $v.ToString([Globalization.CultureInfo]::InvariantCulture)}
        return Json-String ([string]$v)
    }
    return (Json-Value $Value)+"`n"
}

# OrderedDictionary exposes adapter properties such as Keys, but a data entry
# named "keys" shadows that property in Windows PowerShell 5.1.  The store
# reference has exactly that valid section slug.  This pre-smoke keeps both
# deterministic serializers on the IDictionary enumerator rather than the
# collision-prone PowerShell member adapter.
$DictionaryKeySmoke = [ordered]@{synopsis='one';keys='two';results='three'}
if ([string]::Join('|', @(Dictionary-Keys $DictionaryKeySmoke)) -cne 'synopsis|keys|results' -or
        (Tcl-Data $DictionaryKeySmoke) -cne 'synopsis one keys two results three' -or
        (Convert-JsonDeterministic $DictionaryKeySmoke) -cne "{`"synopsis`":`"one`",`"keys`":`"two`",`"results`":`"three`"}`n") {
    Fail 'ordered-dictionary key enumeration lost a data entry named keys'
}

function Add-Unique([Collections.IDictionary]$Map, [string]$Key, [string]$Value) {
    if (-not $Map.Contains($Key)) { $Map[$Key] = New-Object Collections.Generic.List[string] }
    if (-not $Map[$Key].Contains($Value)) { $Map[$Key].Add($Value) }
}

function Extract-ControlledSources([string]$Archive, [string]$RootName,
        [string]$Product, [string]$Destination, [bool]$WithTools) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $docEntries = @($zip.Entries | Where-Object {
            $_.FullName -match ('^' + [regex]::Escape($RootName) + '/doc/[A-Za-z0-9_][A-Za-z0-9_.-]*\.(?:1|3|n)$')
        })
        $expected = if ($Product -eq 'tcl') { 249 } else { 177 }
        if ($docEntries.Count -ne $expected) {
            Fail "$Product archive core manual inventory is $($docEntries.Count), expected $expected"
        }
        $wanted = New-Object Collections.Generic.List[object]
        foreach ($entry in $docEntries) { $wanted.Add($entry) }
        foreach ($relative in @('doc/man.macros', 'doc/license.terms', 'README.md')) {
            $name = "$RootName/$relative"
            $matches = @($zip.Entries | Where-Object FullName -eq $name)
            if ($matches.Count -ne 1) { Fail "$Product archive lacks exactly one $name" }
            $wanted.Add($matches[0])
        }
        $header = if ($Product -eq 'tcl') { 'generic/tcl.h' } else { 'generic/tk.h' }
        $headerName = "$RootName/$header"
        $headerEntries = @($zip.Entries | Where-Object FullName -eq $headerName)
        if ($headerEntries.Count -ne 1) { Fail "$Product archive lacks $headerName" }
        $wanted.Add($headerEntries[0])
        if ($WithTools) {
            foreach ($relative in @('tools/tcltk-man2html.tcl', 'tools/tcltk-man2html-utils.tcl')) {
                $name = "$RootName/$relative"
                $matches = @($zip.Entries | Where-Object FullName -eq $name)
                if ($matches.Count -ne 1) { Fail "Tcl archive lacks $name" }
                $wanted.Add($matches[0])
            }
        }
        foreach ($entry in $wanted) {
            $relative = $entry.FullName.Substring($RootName.Length + 1)
            if($relative.Contains('\') -or $relative.Contains(':') -or $relative -match '(^|/)\.\.?(/|$)'){
                Fail "$Product archive has unsafe whitelisted path $relative"
            }
            $target = Join-Path (Join-Path $Destination $RootName) $relative.Replace('/', '\')
            $targetFull=[IO.Path]::GetFullPath($target);$extractRoot=[IO.Path]::GetFullPath((Join-Path $Destination $RootName)).TrimEnd('\')+'\'
            if(-not$targetFull.StartsWith($extractRoot,[StringComparison]::OrdinalIgnoreCase)){Fail "$Product archive path escapes controlled stage: $relative"}
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            $input = $entry.Open()
            try {
                $output = [IO.File]::Create($target)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $zip.Dispose() }
    if ([IO.Directory]::Exists((Join-Path $Destination "$RootName\pkgs"))) {
        Fail "$Product controlled source unexpectedly contains extension packages"
    }
}

$EntityNames = @{}
foreach ($name in @('Aacute','Acirc','acute','AElig','Agrave','amp','Aring','Atilde','Auml',
        'brvbar','Ccedil','cedil','cent','copy','curren','deg','die','divide','Eacute','Ecirc',
        'Egrave','ETH','Euml','euro','frac12','frac14','frac34','gt','Iacute','Icirc','iexcl',
        'Igrave','iquest','Iuml','laquo','ldquo','lt','macr','mdash','micro','middot','minus',
        'nbsp','ndash','not','Ntilde','Oacute','ocirc','Ograve','ordf','ordm','Oslash','Otilde',
        'Ouml','para','plusmn','pound','prime','quot','raquo','rarr','rdquo','reg','sect','sup1',
        'sup2','sup3','szlig','THORN','times','Uacute','Ucirc','Ugrave','Uuml','Yacute','yen','yuml')) {
    $decoded = if($name -eq 'die'){[string][char]0x00a8}else{[Net.WebUtility]::HtmlDecode("&$name;")}
    if ($decoded -eq "&$name;") { Fail "runtime cannot decode expected HTML entity &$name;" }
    $EntityNames[$name] = $decoded
}

function Decode-Html([string]$Text, [string]$Label) {
    $b = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $Text.Length;) {
        if ($Text[$i] -ne '&') { [void]$b.Append($Text[$i]); $i++; continue }
        $semi = $Text.IndexOf(';', $i + 1)
        if ($semi -lt 0 -or $semi - $i -gt 20) { Fail "$Label contains malformed HTML entity" }
        $name = $Text.Substring($i + 1, $semi - $i - 1)
        if ($name -match '^#([0-9]+)$') { $code = [Convert]::ToInt32($Matches[1], 10) }
        elseif ($name -match '^#x([0-9A-Fa-f]+)$') { $code = [Convert]::ToInt32($Matches[1], 16) }
        elseif ($script:EntityNames.ContainsKey($name)) {
            [void]$b.Append($script:EntityNames[$name]); $i = $semi + 1; continue
        } else { Fail "$Label contains unknown HTML entity &$name;" }
        if ($code -lt 0 -or $code -gt 0x10ffff -or ($code -ge 0xd800 -and $code -le 0xdfff)) {
            Fail "$Label contains invalid numeric HTML entity &$name;"
        }
        [void]$b.Append([char]::ConvertFromUtf32($code)); $i = $semi + 1
    }
    return $b.ToString()
}

$AllowedTags = @{}
foreach ($tag in @('a','b','body','br','dd','div','dl','dt','font','h2','h3','h4','head',
        'html','i','li','link','meta','ol','p','pre','small','table','td','title','tr','tt','ul')) {
    $AllowedTags[$tag] = $true
}

function Parse-HtmlTag([string]$Raw, [string]$Label, [int]$Start, [int]$End) {
    $inner = $Raw.Substring(1, $Raw.Length - 2).Trim()
    if ($inner -match '^!DOCTYPE\s+html$') {
        return [pscustomobject]@{ Kind='doctype'; Name='doctype'; Closing=$false; SelfClosing=$true;
            Attr=[ordered]@{}; Start=$Start; End=$End; Raw=$Raw }
    }
    if ($inner.StartsWith('!--')) { Fail "$Label contains unsupported HTML comment" }
    $closing = $false
    if ($inner.StartsWith('/')) { $closing = $true; $inner = $inner.Substring(1).TrimStart() }
    $self = $false
    if ($inner.EndsWith('/')) { $self = $true; $inner = $inner.Substring(0, $inner.Length - 1).TrimEnd() }
    $i = 0
    while ($i -lt $inner.Length -and ([char]::IsLetterOrDigit($inner[$i]) -or $inner[$i] -eq ':')) { $i++ }
    if ($i -eq 0) { Fail "$Label contains malformed tag $Raw" }
    $name = $inner.Substring(0, $i).ToLowerInvariant()
    if (-not $script:AllowedTags.ContainsKey($name)) { Fail "$Label contains unknown tag <$name>" }
    $attrs = [ordered]@{}
    while ($i -lt $inner.Length) {
        while ($i -lt $inner.Length -and [char]::IsWhiteSpace($inner[$i])) { $i++ }
        if ($i -ge $inner.Length) { break }
        $begin = $i
        while ($i -lt $inner.Length -and ([char]::IsLetterOrDigit($inner[$i]) -or
                $inner[$i] -eq '-' -or $inner[$i] -eq ':' -or $inner[$i] -eq '_')) { $i++ }
        if ($begin -eq $i) { Fail "$Label contains malformed attribute in $Raw" }
        $key = $inner.Substring($begin, $i - $begin).ToLowerInvariant()
        while ($i -lt $inner.Length -and [char]::IsWhiteSpace($inner[$i])) { $i++ }
        $value = ''
        if ($i -lt $inner.Length -and $inner[$i] -eq '=') {
            $i++
            while ($i -lt $inner.Length -and [char]::IsWhiteSpace($inner[$i])) { $i++ }
            if ($i -ge $inner.Length) { Fail "$Label has missing value for attribute $key" }
            if ($inner[$i] -eq '"' -or $inner[$i] -eq "'") {
                $quote = $inner[$i]; $i++; $begin = $i
                while ($i -lt $inner.Length -and $inner[$i] -ne $quote) { $i++ }
                if ($i -ge $inner.Length) { Fail "$Label has unterminated attribute $key" }
                $value = $inner.Substring($begin, $i - $begin); $i++
            } else {
                $begin = $i
                while ($i -lt $inner.Length -and -not [char]::IsWhiteSpace($inner[$i])) { $i++ }
                $value = $inner.Substring($begin, $i - $begin)
            }
        }
        if ($attrs.Contains($key)) { Fail "$Label repeats HTML attribute $key" }
        $attrs[$key] = Decode-Html $value "$Label attribute $key"
    }
    return [pscustomobject]@{ Kind='tag'; Name=$name; Closing=$closing; SelfClosing=$self;
        Attr=$attrs; Start=$Start; End=$End; Raw=$Raw }
}

function Get-HtmlTokens([string]$Html, [string]$Label) {
    Assert-NoSurrogates $Html $Label
    $tokens = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $Html.Length;) {
        if ($Html[$i] -ne '<') {
            $next = $Html.IndexOf('<', $i)
            if ($next -lt 0) { $next = $Html.Length }
            $raw = $Html.Substring($i, $next - $i)
            if ($raw.Length) {
                $tokens.Add([pscustomobject]@{Kind='text'; Text=(Decode-Html $raw $Label);
                    Start=$i; End=$next})
            }
            $i = $next; continue
        }
        $quote = [char]0; $j = $i + 1
        for (; $j -lt $Html.Length; $j++) {
            $c = $Html[$j]
            if ($quote -ne [char]0) { if ($c -eq $quote) { $quote = [char]0 }; continue }
            if ($c -eq '"' -or $c -eq "'") { $quote = $c; continue }
            if ($c -eq '>') { break }
        }
        if ($j -ge $Html.Length) { Fail "$Label has unterminated HTML tag" }
        $raw = $Html.Substring($i, $j - $i + 1)
        $tokens.Add((Parse-HtmlTag $raw $Label $i ($j + 1)))
        $i = $j + 1
    }
    return $tokens.ToArray()
}

function Token-PlainText([object[]]$Tokens, [int]$Start, [int]$End) {
    $b = New-Object Text.StringBuilder
    for ($i = $Start; $i -lt $End; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -eq 'text') { [void]$b.Append($t.Text) }
        elseif ($t.Kind -eq 'tag' -and -not $t.Closing -and $t.Name -in @('br','p','dd','dt','li')) {
            [void]$b.Append(' ')
        }
    }
    return ([regex]::Replace($b.ToString(), '\s+', ' ')).Trim()
}

function Inspect-HtmlPage([string]$Html, [string]$Label) {
    $tokens = @(Get-HtmlTokens $Html $Label)
    $anchors = [ordered]@{}
    $sections = New-Object Collections.Generic.List[object]
    $usedSlugs = @{}
    $contentToken = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t.Kind -ne 'tag' -or $t.Closing -or $t.Name -notin @('h3','h4')) { continue }
        $close = $i + 1
        while ($close -lt $tokens.Count -and -not ($tokens[$close].Kind -eq 'tag' -and
                $tokens[$close].Closing -and $tokens[$close].Name -eq $t.Name)) { $close++ }
        if ($close -ge $tokens.Count) { Fail "$Label has unclosed <$($t.Name)>" }
        $anchor = $null
        for ($j = $i + 1; $j -lt $close; $j++) {
            $a = $tokens[$j]
            if ($a.Kind -eq 'tag' -and -not $a.Closing -and $a.Name -eq 'a' -and $a.Attr.Contains('name')) {
                $anchor = [string]$a.Attr['name']; break
            }
        }
        if ($anchor -notmatch '^M[0-9]+$') { continue }
        if ($contentToken -lt 0) { $contentToken = $i }
        $heading = Token-PlainText $tokens ($i + 1) $close
        $base = Slug $heading
        if (-not $base) { $base = $anchor.ToLowerInvariant() }
        $slug = $base; $suffix = 2
        while ($usedSlugs.ContainsKey($slug)) { $slug = "$base-$suffix"; $suffix++ }
        $usedSlugs[$slug] = $true
        $anchors[$anchor] = $slug
        $sections.Add([pscustomobject]@{Slug=$slug; Heading=$heading; Anchor=$anchor; Level=if($t.Name -eq 'h3'){2}else{3};
            HtmlStart=$t.Start; TokenStart=$i; TokenEnd=$close})
    }
    if ($contentToken -lt 0 -or $sections.Count -lt 2 -or $sections[0].Heading -ne 'NAME') {
        Fail "$Label has no canonical NAME section (tokens=$($tokens.Count), sections=$($sections.Count), headings=$([string]::Join('|', @($sections | ForEach-Object Heading))))"
    }
    # Inline converter anchors are not independently ranged sections.  Map
    # them to their containing heading so every rewritten link resolves to a
    # catalogued section instead of inventing an unbounded fragment.
    for ($i = $contentToken; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t.Kind -ne 'tag' -or $t.Closing -or $t.Name -ne 'a' -or -not $t.Attr.Contains('name')) { continue }
        $name = [string]$t.Attr['name']
        if ($name -notmatch '^M[0-9]+$' -or $anchors.Contains($name)) { continue }
        $containing = $null
        foreach ($section in $sections) {
            if ($section.TokenStart -le $i) { $containing = $section } else { break }
        }
        if ($null -eq $containing) { Fail "$Label has an inline anchor before its first section" }
        $anchors[$name] = $containing.Slug
    }
    $nameSection = $sections[0]
    $next = $sections[1]
    $nameText = Token-PlainText $tokens ($nameSection.TokenEnd + 1) $next.TokenStart
    $parts = [regex]::Split($nameText, '\s+[\u2013\u2014-]\s+', 2)
    if ($parts.Count -ne 2) { Fail "$Label NAME section has no name/summary separator: $nameText" }
    $names = @($parts[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) { Fail "$Label NAME section has no names" }
    $copyright = ''
    for ($i = $contentToken; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t.Kind -eq 'tag' -and -not $t.Closing -and $t.Name -eq 'div' -and
                $t.Attr.Contains('class') -and $t.Attr['class'] -eq 'copy') {
            $close = $i + 1
            while ($close -lt $tokens.Count -and -not ($tokens[$close].Kind -eq 'tag' -and
                    $tokens[$close].Closing -and $tokens[$close].Name -eq 'div')) { $close++ }
            $copyright = Token-PlainText $tokens ($i + 1) $close; break
        }
    }
    return [pscustomobject]@{ Tokens=$tokens; Anchors=$anchors; Sections=$sections.ToArray();
        ContentToken=$contentToken; Names=$names; Summary=$parts[1].Trim(); Copyright=$copyright }
}

function Escape-MarkdownText([string]$Text) {
    # Converter prose rarely contains Markdown punctuation in syntactic roles;
    # escape only characters that could manufacture links or emphasis.
    return $Text.Replace('\', '\\').Replace('[', '\[').Replace(']', '\]')
}

function Convert-HtmlPage([string]$Html, [string]$HtmlRelative,
        [string]$Id, $Inspection, [Collections.IDictionary]$HtmlToId,
        [Collections.IDictionary]$PageAnchors) {
    $tokens = $Inspection.Tokens
    $b = New-Object Text.StringBuilder
    $title = [string]$Inspection.Names[0]
    [void]$b.Append("# $title`n`n")
    [void]$b.Append("_Upstream $($Id.Split('/')[0].ToUpperInvariant()) 9.0.4 reference; normalized from the official manual source._`n`n")
    $inPre = $false; $skipDepth = 0; $started = $false
    $inline = New-Object Collections.Generic.Stack[string]
    $links = New-Object Collections.Generic.Stack[object]
    $anchorModes = New-Object 'Collections.Generic.Stack[bool]'
    $lists = New-Object Collections.Generic.Stack[string]
    $table = $null; $row = $null; $cell = $null
    $headingDepth = 0
    $pendingBullet = ''

    function Append-Local([string]$s) { [void]$b.Append($s) }
    function Append-InlineLocal([string]$s) {
        if ($null -ne $cell) { [void]$cell.Append($s) } else { [void]$b.Append($s) }
    }
    function Flush-PendingBulletLocal([string]$text) {
        if (-not $pendingBullet) { return $text }
        if ($text -notmatch '^\s*(\S.*)$') { return '' }
        Append-InlineLocal ($pendingBullet + $Matches[1])
        Set-Variable -Name pendingBullet -Value '' -Scope 1
        return ''
    }
    function Flush-PendingBulletMarkupLocal {
        if(-not$pendingBullet){return}
        Append-InlineLocal $pendingBullet
        Set-Variable -Name pendingBullet -Value '' -Scope 1
    }
    function Cell-BreakLocal([int]$count = 1) {
        if ($null -eq $cell) { Break-Local $count; return }
        if($cell.Length-and-not[char]::IsWhiteSpace($cell[$cell.Length-1])){[void]$cell.Append(' ')}
    }
    function Break-Local([int]$count = 1) {
        if ($b.Length -eq 0) { return }
        while ($b.Length -gt 0 -and $b[$b.Length - 1] -eq ' ') { $b.Length-- }
        $present = 0
        for ($j = $b.Length - 1; $j -ge 0 -and $present -lt $count -and
                $b[$j] -eq "`n"; $j--) { $present++ }
        while ($present -lt $count) { [void]$b.Append("`n"); $present++ }
    }
    function Stable-Link([string]$href) {
        if ($href -match '^[A-Za-z][A-Za-z0-9+.-]*:') { return $href }
        $pair = $href.Split('#', 2); $pathPart = $pair[0]
        $fragment = if ($pair.Count -eq 2) { $pair[1] } else { '' }
        if ($pathPart -eq '') { $targetPath = $HtmlRelative }
        else { $targetPath = Resolve-LogicalPath $HtmlRelative $pathPart }
        if (-not $HtmlToId.Contains($targetPath)) { return '' }
        $targetId = [string]$HtmlToId[$targetPath]
        if ($fragment -and $PageAnchors.Contains($targetId) -and $PageAnchors[$targetId].Contains($fragment)) {
            return "$targetId#$($PageAnchors[$targetId][$fragment])"
        }
        return $targetId
    }
    function Finish-CellLocal {
        if ($null -eq $cell) { return }
        if ($null -eq $row) { Fail "$HtmlRelative has a table cell outside a row" }
        $row.Add($cell.ToString())
        Set-Variable -Name cell -Value $null -Scope 1
    }
    function Finish-RowLocal {
        if ($null -eq $row) { return }
        if ($null -eq $table) { Fail "$HtmlRelative has a table row outside a table" }
        if ($null -ne $cell) {
            $row.Add($cell.ToString())
            Set-Variable -Name cell -Value $null -Scope 1
        }
        $table.Add($row.ToArray())
        Set-Variable -Name row -Value $null -Scope 1
    }

    for ($i = $Inspection.ContentToken; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t.Kind -eq 'text') {
            if (-not $started -or $skipDepth -gt 0) { continue }
            $text = $t.Text
            if($pendingBullet){$text=Flush-PendingBulletLocal $text;if(-not$text){continue}}
            if ($null -ne $cell) { [void]$cell.Append($text); continue }
            if ($inPre) { Append-Local $text }
            else { Append-Local (Escape-MarkdownText $text) }
            continue
        }
        if ($t.Kind -ne 'tag') { continue }
        if (-not $started) {
            if ($t -eq $tokens[$Inspection.ContentToken]) { $started = $true } else { continue }
        }
        $name = $t.Name
        if ($name -in @('head','title','h2')) {
            if (-not $t.Closing) { $skipDepth++ } else { $skipDepth-- }
            continue
        }
        if ($skipDepth -gt 0) { continue }
        if ($name -eq 'a') {
            if (-not $t.Closing) {
                if($pendingBullet-and$t.Attr.Contains('href')){Flush-PendingBulletMarkupLocal}
                $anchorName = if($t.Attr.Contains('name')){[string]$t.Attr['name']}else{''}
                if ($anchorName -and @($Inspection.Sections | Where-Object { $_.Anchor -eq $anchorName }).Count -and $headingDepth -eq 0) {
                    $slug = $Inspection.Anchors[[string]$t.Attr['name']]
                    if (-not $inPre) { Break-Local 2; Append-Local ('<a id="' + $slug + '"></a>' + "`n") }
                }
                # The converter wraps heading text in a named anchor without
                # href; that is an anchor element, not a Markdown link pair.
                $hasHref = $t.Attr.Contains('href')
                $anchorModes.Push($hasHref)
                if (-not $hasHref) { continue }
                $href = if($inPre){''}else{Stable-Link ([string]$t.Attr['href'])}
                $links.Push([pscustomobject]@{Href=$href; Start=$b.Length})
                if ($href) { Append-InlineLocal '[' }
            } else {
                if ($anchorModes.Count -eq 0) { Fail "$HtmlRelative closes an unopened anchor" }
                $hasHref = $anchorModes.Pop()
                if (-not $hasHref) { continue }
                if ($links.Count -eq 0) { Fail "$HtmlRelative closes an unopened link" }
                $link = $links.Pop()
                if ($link.Href) { Append-InlineLocal "]($($link.Href))" }
            }
            continue
        }
        if ($name -in @('b','i','tt','font','small')) {
            if(-not$t.Closing-and$pendingBullet){Flush-PendingBulletMarkupLocal}
            $mark = switch ($name) { 'b' {'**'} 'i' {'*'} 'tt' {'`'} default {''} }
            if (-not $t.Closing) { $inline.Push($mark); if ($mark -and -not $inPre) { Append-InlineLocal $mark } }
            else {
                if ($inline.Count -eq 0) { Fail "$HtmlRelative closes unopened <$name>" }
                $open = $inline.Pop(); if ($open -and -not $inPre) { Append-InlineLocal $open }
            }
            continue
        }
        if ($name -in @('h3','h4')) {
            if (-not $t.Closing) {
                Break-Local 2
                $sectionHere=$Inspection.Sections|Where-Object{$_.TokenStart-eq$i}|Select-Object -First 1
                if($sectionHere){Append-Local ('<a id="'+$sectionHere.Slug+'"></a>'+"`n")}
                $headingPrefix = if($name -eq 'h3'){'## '}else{'### '}
                Append-Local $headingPrefix
                $headingDepth++
            } else { $headingDepth--; Break-Local 2 }
            continue
        }
        if ($name -eq 'pre') {
            if (-not $t.Closing) {
                $fenceLanguage = if ($Id -like '*/c-api/*') { 'c' } elseif ($Id -like '*/application/*') { 'text' } else { 'tcl' }
                Break-Local 2; Append-Local ('```' + $fenceLanguage + "`n"); $inPre = $true
            }
            else { $inPre = $false; Break-Local 1; Append-Local '```'; Break-Local 2 }
            continue
        }
        if ($name -eq 'br') {
            Cell-BreakLocal 1
            continue
        }
        if ($name -eq 'p') {
            Cell-BreakLocal 2
            continue
        }
        if ($name -in @('ul','ol')) {
            if (-not $t.Closing) { $lists.Push($name); Cell-BreakLocal 1 }
            else { if($lists.Count){[void]$lists.Pop()}; Cell-BreakLocal 2 }
            continue
        }
        if ($name -eq 'li' -and -not $t.Closing) {
            Cell-BreakLocal 1; $indent = '  ' * [Math]::Max(0, $lists.Count - 1)
            $bullet = if ($lists.Count -and $lists.Peek() -eq 'ol') { '1. ' } else { '- ' }
            $pendingBullet="$indent$bullet"; continue
        }
        if ($name -in @('dl')) { if($t.Closing){Cell-BreakLocal 2}else{Cell-BreakLocal 1}; continue }
        if ($name -in @('dt','dd')) {
            if (-not $t.Closing) { Cell-BreakLocal 1; if($name -eq 'dt'){$pendingBullet='- '} }
            continue
        }
        if ($name -eq 'table') {
            if (-not $t.Closing) {
                if($null-ne$table-or$null-ne$row-or$null-ne$cell){Fail "$HtmlRelative nests tables or leaves table state open"}
                $table = New-Object Collections.Generic.List[object]; Break-Local 2
            }
            else {
                if ($null -eq $table) { Fail "$HtmlRelative closes unopened table" }
                Finish-RowLocal
                if ($table.Count) {
                    $width = ($table | ForEach-Object Count | Measure-Object -Maximum).Maximum
                    for ($ri=0; $ri -lt $table.Count; $ri++) {
                        $cells = @($table[$ri]); while($cells.Count -lt $width){$cells += ''}
                        Append-Local ('| ' + (($cells | ForEach-Object { ([regex]::Replace($_,'\s+',' ')).Trim().Replace('|','\|') }) -join ' | ') + ' |'); Break-Local 1
                        if ($ri -eq 0) { Append-Local ('| ' + ((1..$width | ForEach-Object {'---'}) -join ' | ') + ' |'); Break-Local 1 }
                    }
                }
                $table = $null; Break-Local 2
            }
            continue
        }
        if ($name -eq 'tr') {
            if (-not $t.Closing) {
                if($null-eq$table){Fail "$HtmlRelative opens a row outside a table"}
                Finish-RowLocal
                $row = New-Object Collections.Generic.List[string]
            }
            else { if($null-eq$table-or$null-eq$row){Fail "$HtmlRelative malformed table row"}; Finish-RowLocal }
            continue
        }
        if ($name -eq 'td') {
            if (-not $t.Closing) {
                if($null-eq$row){Fail "$HtmlRelative opens a cell outside a row"}
                Finish-CellLocal
                $cell = New-Object Text.StringBuilder
            }
            else { if($null-eq$row-or$null-eq$cell){Fail "$HtmlRelative malformed table cell"}; Finish-CellLocal }
            continue
        }
        if ($name -eq 'div') {
            if (-not $t.Closing -and $t.Attr.Contains('class') -and $t.Attr['class'] -eq 'copy') {
                Break-Local 2; Append-Local '> '
            } elseif ($t.Closing) { Break-Local 2 }
            continue
        }
        # Structural tags have no textual representation.
        if ($name -notin @('html','body','link','meta')) { Fail "$HtmlRelative has unhandled tag <$name>" }
    }
    if ($pendingBullet -or $inPre -or $links.Count -or $anchorModes.Count -or $inline.Count -or
            $null -ne $table -or $null -ne $row -or $null -ne $cell) {
        Fail "$HtmlRelative ended with unbalanced rendering state"
    }
    $markdown = $b.ToString().Replace("`r", '')
    $markdown = [regex]::Replace($markdown, "[ `t]+`n", "`n")
    $markdown = [regex]::Replace($markdown, "`n{3,}", "`n`n").Trim() + "`n"
    if ($markdown -match '<\/?(?:b|i|dl|dt|dd|table|tr|td|font|pre|p|br)\b') {
        Fail "$HtmlRelative leaked converter markup into Markdown"
    }
    if ($Inspection.Copyright) {
        $notice = Normalize-Search $Inspection.Copyright
        if ((Normalize-Search $markdown).IndexOf($notice, [StringComparison]::Ordinal) -lt 0) {
            # Some converter notice blocks use inline breaks/markup whose
            # punctuation can be separated by Markdown rendering. Preserve the
            # complete decoded upstream notice text explicitly and verbatim.
            $markdown = $markdown.TrimEnd() + "`n`n> " + $Inspection.Copyright + "`n"
        }
        if ((Normalize-Search $markdown).IndexOf($notice, [StringComparison]::Ordinal) -lt 0) {
            Fail "$HtmlRelative normalization lost per-page notice: $notice"
        }
    }
    return $markdown
}

function Get-MarkdownSections([string]$Text, [string]$Label) {
    Assert-NoSurrogates $Text $Label
    $found = New-Object Collections.Generic.List[object]
    $pendingAnchor = ''
    $pendingAnchorStart = -1
    $offset = 0
    $fence = ''
    foreach ($lineWithLf in [regex]::Matches($Text, '.*?(?:\n|$)')) {
        $chunk = $lineWithLf.Value
        if ($chunk -eq '') { continue }
        $line = $chunk.TrimEnd("`n")
        if($line-match'^\s*(`{3,}|~{3,})'){
            $marker=$Matches[1]
            if(-not$fence){$fence=$marker.Substring(0,1)}
            elseif($marker.StartsWith($fence)){$fence=''}
            $pendingAnchor='';$pendingAnchorStart=-1;$offset+=$chunk.Length;continue
        }
        if($fence){$offset+=$chunk.Length;continue}
        if ($line -match '^<a id="([a-z0-9][a-z0-9-]*)"></a>$') {
            $pendingAnchor = $Matches[1]
            $pendingAnchorStart = $offset
        }
        elseif ($line -match '^(#{2,3})\s+(.+?)\s*$') {
            $heading = Strip-Markdown $Matches[2]
            $slug = if ($pendingAnchor) { $pendingAnchor } else { Slug $heading }
            if (-not $slug) { Fail "$Label contains an unnameable heading" }
            if (@($found | Where-Object Slug -eq $slug).Count) { Fail "$Label repeats section slug $slug" }
            $start = if ($pendingAnchor) { $pendingAnchorStart } else { $offset }
            if ($start -lt 0) { $start = $offset }
            $found.Add([pscustomobject]@{Slug=$slug; Heading=$heading; Level=$Matches[1].Length; Start=$start; End=$Text.Length})
            $pendingAnchor = ''
            $pendingAnchorStart = -1
        } elseif ($line.Trim()) { $pendingAnchor = ''; $pendingAnchorStart = -1 }
        $offset += $chunk.Length
    }
    for ($i=0; $i -lt $found.Count; $i++) {
        for ($j=$i+1; $j -lt $found.Count; $j++) {
            if ($found[$j].Level -le $found[$i].Level) { $found[$i].End=$found[$j].Start; break }
        }
    }
    return $found.ToArray()
}

function Get-HtmlSections([string]$Text, $Inspection) {
    $out = New-Object Collections.Generic.List[object]
    foreach ($s in $Inspection.Sections) {
        $out.Add([pscustomobject]@{Slug=$s.Slug; Heading=$s.Heading; Level=$s.Level;
            Start=$s.HtmlStart; End=$Text.Length})
    }
    for($i=0;$i -lt $out.Count;$i++){
        for($j=$i+1;$j -lt $out.Count;$j++){
            if($out[$j].Level -le $out[$i].Level){$out[$i].End=$out[$j].Start;break}
        }
    }
    return $out.ToArray()
}

function Get-SourceSections([string]$Text, [string]$Label) {
    Assert-NoSurrogates $Text $Label
    $out = New-Object Collections.Generic.List[object]
    $used = @{}
    foreach($m in [regex]::Matches($Text, '(?m)^\.(SH|SS)\s+(?:"([^"]+)"|(\S.*))$')){
        $heading = if($m.Groups[2].Success){$m.Groups[2].Value}else{$m.Groups[3].Value.Trim()}
        $heading = $heading -replace '\\f[BRIP]', ''
        $base=Slug $heading;if(-not $base){continue};$slug=$base;$n=2
        while($used.ContainsKey($slug)){$slug="$base-$n";$n++};$used[$slug]=$true
        $out.Add([pscustomobject]@{Slug=$slug;Heading=$heading;Level=if($m.Groups[1].Value-eq'SH'){2}else{3};Start=$m.Index;End=$Text.Length})
    }
    for($i=0;$i-lt$out.Count;$i++){for($j=$i+1;$j-lt$out.Count;$j++){if($out[$j].Level-le$out[$i].Level){$out[$i].End=$out[$j].Start;break}}}
    return $out.ToArray()
}

function Get-FencedCodeBlocks([string]$Text, [string]$Label) {
    # Parse fences line by line. A single dot-all regex can start at one fence,
    # consume ordinary prose between blocks, and mistake a prose catalog link
    # for source code before eventually finding a later closing fence.
    Assert-NoSurrogates $Text $Label
    $blocks = New-Object Collections.Generic.List[object]
    $openMarker = ''
    $language = ''
    $content = $null
    foreach ($lineWithLf in [regex]::Matches($Text, '.*?(?:\n|$)')) {
        $chunk = $lineWithLf.Value
        if ($chunk -eq '') { continue }
        $line = $chunk.TrimEnd("`n").TrimEnd("`r")
        if (-not $openMarker) {
            if ($line -match '^(`{3,}|~{3,})(.*)$') {
                $openMarker = $Matches[1]
                $info = $Matches[2].Trim()
                $language = if ($info) { @($info -split '\s+', 2)[0].ToLowerInvariant() } else { '' }
                $content = New-Object Text.StringBuilder
            }
            continue
        }
        if ($line -match '^(`{3,}|~{3,})[ \t]*$') {
            $closeMarker = $Matches[1]
            if ($closeMarker[0] -eq $openMarker[0] -and $closeMarker.Length -ge $openMarker.Length) {
                $blocks.Add([pscustomobject]@{Language=$language;Content=$content.ToString()})
                $openMarker = ''
                $language = ''
                $content = $null
                continue
            }
        }
        [void]$content.Append($line)
        if ($chunk.EndsWith("`n")) { [void]$content.Append("`n") }
    }
    if ($openMarker) { Fail "$Label contains an unclosed $openMarker code fence" }
    return $blocks.ToArray()
}

# Focused pre-smoke for the cross-fence false-positive class: the catalog link
# is deliberately between two C blocks and must not be attributed to either.
$FenceScannerSmoke = @'
```c
Tcl_EvalEx(interp, script, -1, 0);
```

See [return](tcl/command/return).

```c
Tcl_SetReturnOptions(interp, options);
```
'@
$FenceScannerSmokeBlocks = @(Get-FencedCodeBlocks $FenceScannerSmoke 'internal fence-scanner smoke')
if ($FenceScannerSmokeBlocks.Count -ne 2 -or
        $FenceScannerSmokeBlocks[0].Language -cne 'c' -or
        $FenceScannerSmokeBlocks[0].Content -notmatch 'Tcl_EvalEx\(interp, script, -1, 0\);' -or
        @($FenceScannerSmokeBlocks | Where-Object { $_.Content -match '\]\((?:machteld|tcl|tk)/[^)]+\)' }).Count) {
    Fail 'internal fence scanner crossed a code-block boundary'
}
$FenceScannerBadSmoke = @'
```c
[return](tcl/command/return)
```
'@
$FenceScannerBadBlocks = @(Get-FencedCodeBlocks $FenceScannerBadSmoke 'internal bad-fence smoke')
if (-not @($FenceScannerBadBlocks | Where-Object {
            $_.Content -match '\]\((?:machteld|tcl|tk)/[^)]+\)'
        }).Count) {
    Fail 'internal fence scanner missed a catalog link inside source code'
}

function Sections-Dict([object[]]$Sections, [bool]$WithOffsets) {
    $d = [ordered]@{}
    foreach($s in $Sections){
        if($WithOffsets){$d[$s.Slug]=[ordered]@{start=[int]$s.Start;end=[int]$s.End}}
        else{$d[$s.Slug]=[string]$s.Heading}
    }
    return $d
}

function Format-Record([string]$Root, [string]$Relative, [object[]]$Sections) {
    $relative=Normalize-SlashPath $Relative;$path=Join-Path $Root $relative.Replace('/','\')
    if(-not[IO.File]::Exists($path)){Fail "format file missing: $relative"}
    $text=Read-Utf8Strict $path;Assert-NoSurrogates $text $relative
    return [ordered]@{path=$relative;sha256=(Get-Sha256 $path);bytes=[int64](Get-Item -LiteralPath $path).Length;characters=$text.Length;
        sections=(Sections-Dict $Sections $true)}
}

function Front-Matter([string]$Text,[string]$Label){
    $lines=$Text.Replace("`r",'').Split("`n");if($lines.Count-lt3-or$lines[0]-ne'---'){Fail "$Label has no front matter"}
    $d=[ordered]@{};$end=-1
    for($i=1;$i-lt$lines.Count;$i++){if($lines[$i]-eq'---'){$end=$i;break};if($lines[$i]-notmatch'^([a-z_]+):\s?(.*)$'){Fail "$Label has invalid front matter"};$d[$Matches[1]]=$Matches[2]}
    if($end-lt0){Fail "$Label has unterminated front matter"}
    foreach($key in @('id','type','title','summary','commands')){if(-not$d.Contains($key)){Fail "$Label front matter lacks $key"}}
    return $d
}

function Guide-Metadata([string]$Text,[string]$Label){
    $lines=$Text.Replace("`r",'').Split("`n")
    if($lines.Count-lt3-or$lines[0]-ne'---'){Fail "$Label has no guide front matter"}
    $metadata=[ordered]@{};$end=-1
    for($i=1;$i-lt$lines.Count;$i++){
        if($lines[$i]-eq'---'){$end=$i;break}
        if($lines[$i]-notmatch'^([a-z_]+):\s?(.*)$'){Fail "$Label has invalid guide front matter"}
        $metadata[$Matches[1]]=$Matches[2]
    }
    if($end-lt0){Fail "$Label has unterminated guide front matter"}
    foreach($key in @('type','title','description')){if(-not$metadata.Contains($key)){Fail "$Label guide front matter lacks $key"}}
    $body=[string]::Join("`n",@($lines[($end+1)..($lines.Count-1)]))
    return [pscustomobject]@{Metadata=$metadata;Body=$body}
}

function Add-Inventory([Collections.IDictionary]$Inventory,[string]$Root,[string]$Relative){
    $relative=Normalize-SlashPath $Relative
    if($Inventory.Contains($relative)){Fail "duplicate inventory path $relative"}
    $path=Join-Path $Root $relative.Replace('/','\')
    $Inventory[$relative]=[ordered]@{sha256=(Get-Sha256 $path);bytes=[int64](Get-Item -LiteralPath $path).Length}
}

function Corpus-Hash([Collections.IDictionary]$Inventory){
    $b=New-Object IO.MemoryStream
    try{
        foreach($path in @(Sort-Ordinal @(Dictionary-Keys $Inventory))){
            $piece="$path`0$($Inventory[$path].sha256)`0"
            $bytes=$script:Utf8NoBom.GetBytes($piece);$b.Write($bytes,0,$bytes.Length)
        }
        return Get-BytesSha256 $b.ToArray()
    }finally{$b.Dispose()}
}

if (-not [IO.File]::Exists($LockPath)) { Fail "dependency lock missing: $LockPath" }
$lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
$tclLock = $lock.archives | Where-Object id -eq 'tcltk'
$tkLock = $lock.archives | Where-Object id -eq 'tk'
if ($tclLock.version -ne '9.0.4' -or $tkLock.version -ne '9.0.4') { Fail 'reference generator requires pinned Tcl/Tk 9.0.4' }
$tclArchive = Join-Path $CacheRoot "downloads\$($tclLock.file)"
$tkArchive = Join-Path $CacheRoot "downloads\$($tkLock.file)"
Assert-Archive $tclArchive $tclLock.sha256 'Tcl'
Assert-Archive $tkArchive $tkLock.sha256 'Tk'
if (-not $Tclsh) {
    foreach($candidate in @((Join-Path $CacheRoot 'prefix\bin\tclsh90s.exe'),(Join-Path $CacheRoot 'prefix\bin\tclsh90.exe'))){
        if([IO.File]::Exists($candidate)){$Tclsh=$candidate;break}
    }
}
if (-not $Tclsh -or -not [IO.File]::Exists($Tclsh)) { Fail 'static Tcl 9 shell not found; pass -Tclsh' }

$headerText=Read-Utf8Strict (Join-Path $RepoRoot 'src\machteld.h')
if($headerText-notmatch'(?m)^#define\s+MACHTELD_VERSION\s+"([0-9]+\.[0-9]+\.[0-9]+)"\s*$'){Fail 'src/machteld.h has no canonical MACHTELD_VERSION'}
$MachteldVersion=$Matches[1]
$preludeText=Read-Utf8Strict (Join-Path $RepoRoot 'tcl\machteld.tcl')
if($preludeText-notmatch'(?m)^\s*variable\s+version\s+([0-9]+\.[0-9]+\.[0-9]+)\s*$'){Fail 'tcl/machteld.tcl has no canonical version variable'}
if($Matches[1]-ne$MachteldVersion){Fail "C/Tcl runtime version mismatch: $MachteldVersion vs $($Matches[1])"}
if($preludeText-notmatch'(?m)^\s*puts\s+\$channel\s+\{package require machteld ([0-9]+\.[0-9]+\.[0-9]+)\}\s*$'){
    Fail 'tcl/machteld.tcl launcher has no exact versioned package require literal'
}
if($Matches[1]-ne$MachteldVersion){Fail "C/Tcl/launcher version mismatch: $MachteldVersion vs $($Matches[1])"}

$parent=[IO.Path]::GetDirectoryName($Output);[IO.Directory]::CreateDirectory($parent)|Out-Null
$claim=[IO.Path]::Combine($parent,'.machteld-reference-'+[Guid]::NewGuid().ToString('n'))
$work="$claim.work";$candidate="$claim.output"
[IO.Directory]::CreateDirectory($work)|Out-Null
try{
    $source=Join-Path $work 'source-stage';[IO.Directory]::CreateDirectory($source)|Out-Null
    Extract-ControlledSources $tclArchive 'tcl9.0.4' 'tcl' $source $true
    Extract-ControlledSources $tkArchive 'tk9.0.4' 'tk' $source $false
    $htmlOut=Join-Path $work 'html'
    $stdout=Join-Path $work 'converter.stdout';$stderr=Join-Path $work 'converter.stderr'
    $converter=Join-Path $source 'tcl9.0.4\tools\tcltk-man2html.tcl'
    $converterArgs=@($converter,"--srcdir=$($source.Replace('\','/'))","--htmldir=$($htmlOut.Replace('\','/'))",'--useversion=9.0.4')
    # The call operator passes an argv array without Start-Process rejoining and
    # corrupting arguments that contain spaces (notably --srcdir/--htmldir).
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        # The official converter reports ordinary progress on stderr.  PS 5.1
        # otherwise promotes each native stderr line to a terminating error
        # before we can inspect the complete diagnostics and exit status.  We
        # capture records in memory because PS 5.1 native redirection rewrites
        # output as UTF-16; the persisted audit log is always explicit UTF-8/LF.
        $ErrorActionPreference = 'Continue'
        $nativeRecords = @(& $Tclsh @converterArgs 2>&1)
        $converterExit=$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    $converterOut=[string]::Join("`n", @($nativeRecords | ForEach-Object { $_.ToString() })) + "`n"
    Write-Utf8Lf $stdout $converterOut
    Write-Utf8Lf $stderr ''
    if($converterExit-ne0){Fail "upstream converter failed ($converterExit)`n$converterOut"}
    if($converterOut-match'(?i)warn|error|ignored|couldn.t'){
        Fail "upstream converter reported a diagnostic`n$converterOut"
    }
    if($converterOut-notmatch'(?m)^Rescanning 426 pages to build cross links and write out\s*$' -or $converterOut-notmatch'(?m)^Done\s*$'){
        Fail "upstream converter progress did not confirm all 426 pages"
    }
    foreach($spec in @(@('TclCmd',140),@('TclLib',108),@('TkCmd',89),@('TkLib',87))){
        $count=@(Get-ChildItem -LiteralPath (Join-Path $htmlOut $spec[0]) -Filter '*.html' -File | Where-Object { $_.BaseName -ne 'index' }).Count
        if($count -ne $spec[1]){Fail "converted $($spec[0]) inventory is $count, expected $($spec[1])"}
    }
    $appCount=@(Get-ChildItem -LiteralPath (Join-Path $htmlOut 'UserCmd') -Filter '*.html' -File | Where-Object { $_.BaseName -ne 'index' }).Count
    if($appCount -ne 2){Fail "converted application inventory is $appCount, expected 2"}

    [IO.Directory]::CreateDirectory($candidate)|Out-Null
    foreach($dir in @('markdown','source','html','licenses')){[IO.Directory]::CreateDirectory((Join-Path $candidate $dir))|Out-Null}
    # Preserve every official HTML artifact, including indexes, keyword pages,
    # and CSS, so cross-links remain useful after extraction.
    Copy-Item -Path (Join-Path $htmlOut '*') -Destination (Join-Path $candidate 'html') -Recurse -Force
    foreach($product in @('tcl','tk')){
        $rootName=if($product-eq'tcl'){'tcl9.0.4'}else{'tk9.0.4'}
        $doc=Join-Path $source "$rootName\doc"
        $dest=Join-Path $candidate "source\$product\doc";[IO.Directory]::CreateDirectory($dest)|Out-Null
        foreach($file in Get-ChildItem -LiteralPath $doc -File|Where-Object{$_.Extension-in@('.1','.3','.n','.macros','.terms')}){
            Copy-Bytes $file.FullName (Join-Path $dest $file.Name)
        }
    }

    $documents=[ordered]@{};$aliases=[ordered]@{};$fragments=[ordered]@{};$htmlToId=[ordered]@{};$pageAnchors=[ordered]@{}
    $pages=New-Object Collections.Generic.List[object]
    foreach($product in @('tcl','tk')){
        $doc=Join-Path $candidate "source\$product\doc"
        foreach($file in @(Sort-Ordinal @(Get-ChildItem -LiteralPath $doc -File|Where-Object{$_.Extension-in@('.1','.3','.n')}) {param($x)$x.Name})){
            $type=switch($file.Extension){'.n'{'command'}'.3'{'c-api'}'.1'{'application'}}
            $wing=switch("$product/$type"){'tcl/command'{'TclCmd'}'tcl/c-api'{'TclLib'}'tk/command'{'TkCmd'}'tk/c-api'{'TkLib'}default{'UserCmd'}}
            $base=$file.BaseName;$id="$product/$type/$($base.ToLowerInvariant())";$htmlRel="$wing/$base.html"
            if($documents.Contains($id)-or@($pages|Where-Object{$_.Id-eq$id}).Count){Fail "duplicate lowercased canonical ID $id"}
            $htmlPath=Join-Path $candidate "html\$($htmlRel.Replace('/','\'))"
            if(-not[IO.File]::Exists($htmlPath)){Fail "official converter omitted $htmlRel for $($file.Name)"}
            $html=Read-Utf8Strict $htmlPath;$inspect=Inspect-HtmlPage $html $htmlRel
            $htmlToId[$htmlRel]=$id;$pageAnchors[$id]=$inspect.Anchors
            $pages.Add([pscustomobject]@{Product=$product;Type=$type;Base=$base;Id=$id;Source=$file;
                HtmlRel=$htmlRel;Html=$html;Inspect=$inspect})
        }
    }
    if(@($pages | Where-Object { $_.Product -eq 'tcl' }).Count -ne 249 -or
            @($pages | Where-Object { $_.Product -eq 'tk' }).Count -ne 177){Fail 'internal page inventory drift'}

    foreach($page in $pages){
        $mdRel="markdown/$($page.Product)/$($page.Type)/$($page.Base.ToLowerInvariant()).md"
        $markdown=Convert-HtmlPage $page.Html $page.HtmlRel $page.Id $page.Inspect $htmlToId $pageAnchors
        Write-Utf8Lf (Join-Path $candidate $mdRel.Replace('/','\')) $markdown
        $mdSections=@(Get-MarkdownSections $markdown $mdRel);$htmlSections=@(Get-HtmlSections $page.Html $page.Inspect)
        $sourceText=Read-Utf8Strict $page.Source.FullName;$srcSections=@(Get-SourceSections $sourceText $page.Source.Name)
        $srcRel="source/$($page.Product)/doc/$($page.Source.Name)";$htmlRel="html/$($page.HtmlRel)"
        $sectionDict=Sections-Dict $mdSections $false
        $formats=[ordered]@{
            markdown=(Format-Record $candidate $mdRel $mdSections)
            html=(Format-Record $candidate $htmlRel $htmlSections)
            source=(Format-Record $candidate $srcRel $srcSections)
        }
        $names=@($page.Inspect.Names)
        $record=[ordered]@{id=$page.Id;product=$page.Product;version='9.0.4';type=$page.Type;
            title=$names[0];summary=$page.Inspect.Summary;names=$names;sections=$sectionDict;formats=$formats;
            path=$mdRel;raw_path=$srcRel;source_file=$page.Source.Name;content_sha256=$formats.markdown.sha256;
            source_sha256=$formats.source.sha256;bytes=$formats.markdown.bytes}
        $documents[$page.Id]=$record
        foreach($alias in @($page.Id,$page.Base)+$names+@("$($page.Product):$($names[0])","$($page.Product) $($names[0])")){
            Add-Unique $aliases (Normalize-Search $alias) $page.Id
        }
        foreach($anchorEntry in $page.Inspect.Anchors.GetEnumerator()){
            $old=[string]$anchorEntry.Key;$slug=[string]$anchorEntry.Value;$full="$($page.Id)#$slug"
            if(-not$fragments.Contains($full)){$fragments[$full]=[ordered]@{id=$page.Id;section=$slug}}
        }
    }

    # Authored command/index/agent pages.
    $authored=New-Object Collections.Generic.List[object]
    $authoredPaths = @(
        @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs\reference\machteld') -Filter '*.md' -File) +
        @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs\reference\machteld\command') -Filter '*.md' -File))
    foreach($path in @(Sort-Ordinal $authoredPaths {param($x)$x.FullName})){
        $text=Rewrite-AuthoredLinks (Read-Utf8Strict $path.FullName) 'reference';$fm=Front-Matter $text $path.FullName;$id=[string]$fm.id
        $relative=$id.Substring('machteld/'.Length);$mdRel="markdown/machteld/$relative.md"
        Write-Utf8Lf (Join-Path $candidate $mdRel.Replace('/','\')) $text
        $sections=@(Get-MarkdownSections $text $id);$formats=[ordered]@{markdown=(Format-Record $candidate $mdRel $sections)}
        $commands=@($fm.commands.Split(',')|ForEach-Object{$_.Trim()}|Where-Object{$_})
        $names=@(if($commands.Count){$commands}else{[string]$fm.title})
        $record=[ordered]@{id=$id;product='machteld';version=$MachteldVersion;type=[string]$fm.type;
            title=[string]$fm.title;summary=[string]$fm.summary;names=$names;sections=(Sections-Dict $sections $false);
            formats=$formats;path=$mdRel;raw_path='';source_file=$path.Name;content_sha256=$formats.markdown.sha256;
            source_sha256='';bytes=$formats.markdown.bytes}
        if($documents.Contains($id)){Fail "duplicate authored ID $id"};$documents[$id]=$record
        foreach($alias in @($id,[string]$fm.title)+$commands){Add-Unique $aliases (Normalize-Search $alias) $id}
        foreach($s in $sections){
            if($s.Slug-in@('synopsis','arguments-and-options','results','errors','lifetime-and-timeouts','examples','constraints','see-also')){continue}
            $full="$id#$($s.Slug)";if(-not$fragments.Contains($full)){$fragments[$full]=[ordered]@{id=$id;section=$s.Slug}}
        }
    }
    foreach($path in @(Sort-Ordinal @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs') -Filter '*.md' -File) {param($x)$x.Name})){
        $text=Rewrite-AuthoredLinks (Read-Utf8Strict $path.FullName) 'guide';$guide=Guide-Metadata $text $path.FullName;$base=$path.BaseName;$id="machteld/guide/$base";$mdRel="markdown/machteld/guide/$base.md"
        Write-Utf8Lf (Join-Path $candidate $mdRel.Replace('/','\')) $text
        $title=[string]$guide.Metadata.title;$summary=[string]$guide.Metadata.description
        $sections=@(Get-MarkdownSections $text $id);$formats=[ordered]@{markdown=(Format-Record $candidate $mdRel $sections)}
        $documents[$id]=[ordered]@{id=$id;product='machteld';version=$MachteldVersion;type='guide';title=$title;
            summary=$summary;names=@($title);sections=(Sections-Dict $sections $false);formats=$formats;path=$mdRel;raw_path='';
            source_file=$path.Name;content_sha256=$formats.markdown.sha256;source_sha256='';bytes=$formats.markdown.bytes}
        foreach($alias in @($id,$base,$title)){Add-Unique $aliases (Normalize-Search $alias) $id}
    }

    # A standalone extracted reference is itself a distribution.
    $licenseSpecs=@(
        @('machteld','Apache-2.0.txt',(Join-Path $RepoRoot 'LICENSE'),'Machteld Apache License 2.0'),
        @('tcl','Tcl-9.0.4.txt',(Join-Path $RepoRoot 'licenses\Tcl-9.0.4.txt'),'Tcl 9.0.4 license'),
        @('tk','Tk-9.0.4.txt',(Join-Path $RepoRoot 'licenses\Tk-9.0.4.txt'),'Tk 9.0.4 license'))
    foreach($spec in $licenseSpecs){
        $product=$spec[0];$rel="licenses/$($spec[1])";Copy-Bytes $spec[2] (Join-Path $candidate $rel.Replace('/','\'))
        $text=Read-Utf8Strict (Join-Path $candidate $rel.Replace('/','\'));Assert-NoSurrogates $text $rel
        $formats=[ordered]@{markdown=(Format-Record $candidate $rel @());source=(Format-Record $candidate $rel @())}
        $id="$product/license";$documents[$id]=[ordered]@{id=$id;product=$product;version=if($product-eq'machteld'){$MachteldVersion}else{'9.0.4'};
            type='license';title=$spec[3];summary="Verbatim distribution notice for $product.";names=@($spec[3]);sections=[ordered]@{};
            formats=$formats;path=$rel;raw_path=$rel;source_file=$spec[1];content_sha256=$formats.markdown.sha256;
            source_sha256=$formats.source.sha256;bytes=$formats.markdown.bytes}
        foreach($alias in @($id,"$product license",$spec[3])){Add-Unique $aliases (Normalize-Search $alias) $id}
    }

    $agentPath=Join-Path $candidate 'markdown\machteld\agent.md';$agentText=Read-Utf8Strict $agentPath
    $bootstrap=@'
# Machteld embedded reference: start here

This directory is the complete offline reference for the exact Machteld, Tcl,
and Tk versions that carried it.  The canonical query interface is `machteld
docs`; read `markdown/machteld/agent.md` for the compact agent workflow.

`tcl/application/tclsh` and `tk/application/wish` reproduce upstream shell
manuals.  They do not promise that Machteld's host accepts every tclsh or wish
option.  `machteld/command/docs`, the Machteld host help, and entry-contract
pages govern Machteld itself.

Corpus identity: see `catalog.dict`, `catalog.json`, and `manifest.sha256`.
Schema and response contracts: see `schema.json`.
'@
    Write-Utf8Lf (Join-Path $candidate 'START-HERE.md') $bootstrap
    Write-Utf8Lf (Join-Path $candidate 'AGENTS.md') ($bootstrap+"`n---`n`n"+$agentText)
    foreach($bootstrapName in @('START-HERE.md','AGENTS.md')){
        $bootstrapText=Read-Utf8Strict (Join-Path $candidate $bootstrapName)
        if($bootstrapText.Contains("`t")-or
                $bootstrapText-notmatch'`machteld\s+docs`'-or
                $bootstrapText-notmatch'`tcl/application/tclsh`'-or
                $bootstrapText-notmatch'`tk/application/wish`'-or
                $bootstrapText-notmatch'`machteld/command/docs`'){
            Fail "$bootstrapName lost literal Markdown code spans or contains a tab"
        }
    }

    $schema=[ordered]@{
        schema=1;title='Machteld embedded reference schema';generator=$GeneratorVersion
        catalog=[ordered]@{
            encoding='catalog.dict is inert canonical Tcl dict/list data; catalog.json is an equivalent JSON view'
            fields=@('aliases','auxiliary','corpus_sha256','documents','fragments','generator','inventory','machteld_version','products','schema','search')
            document='id, product, version, type, title, summary, names, sections, formats; each format has path, sha256, bytes, and character-offset sections'
            ids='Canonical IDs are lowercase. Ordinary pages use product/type/name; Tcl/Tk names are lowercased source basenames. The only special two-part IDs are machteld/agent, machteld/index, machteld/license, tcl/license, and tk/license. Original spelling remains in names, aliases, and representation paths. Lowercased collisions fail generation.'
            aliases='Unicode-lowercased, whitespace-collapsed keys map to ordered candidate ID lists; ambiguity is explicit and never silently resolved'
        }
        integrity=[ordered]@{
            meaning='consistency and provenance identity, not cryptographic authenticity; there is no separately trusted compiled root hash'
            corpus_sha256='SHA-256 of concatenated UTF-8 bytes path NUL lowercase-file-sha256 NUL for every ordinally sorted catalog inventory path'
            inventory_scope='all Markdown, HTML, source, license, bootstrap, and schema payload files; catalog/search/manifest files are excluded to avoid recursive hashes'
            manifest='manifest.sha256 hashes every pack file except itself, including catalog.dict, catalog.json, and search.dict'
        }
        formats=[ordered]@{markdown='normalized agent-readable Markdown';html='verbatim output of the pinned upstream converter';source='verbatim upstream roff/manual source'}
        docs_host=[ordered]@{
            routes=[ordered]@{full=@('docs ...','--docs ...');wrapped=@('--machteld-docs ...')}
            options=@('--json','--output FILE')
            gui='--output FILE required except for extract'
            operations=@('status','list','schema','verify','get','outline','search','extract')
            json_envelope=[ordered]@{success=[ordered]@{ok=$true;result='value'};
                failure=[ordered]@{ok=$false;error=[ordered]@{domain='DOCS';code='code';message='message'}}}
            pagination='list/search return total, offset, limit, returned, truncated, next, and items'
        }
    }
    Write-Utf8Lf (Join-Path $candidate 'schema.json') (Convert-JsonDeterministic $schema)

    # Validate all normalized catalog links after the complete ID/fragment set exists.
    foreach($documentEntry in $documents.GetEnumerator()){
        $record=$documentEntry.Value
        if(-not$record.formats.Contains('markdown')){continue};$mdPath=Join-Path $candidate $record.formats.markdown.path.Replace('/','\')
        if([IO.Path]::GetExtension($mdPath)-notin@('.md','.txt')){continue};$text=Read-Utf8Strict $mdPath
        foreach($match in [regex]::Matches($text,'\[[^\]]+\]\(([^)]+)\)')){
            $target=$match.Groups[1].Value
            if($target-match'^[A-Za-z][A-Za-z0-9+.-]*:'){continue}
            $parts=$target.Split('#',2);$base=$parts[0]
            if(-not$documents.Contains($base)){Fail "$($record.id) links to missing stable ID $target"}
            if($parts.Count-eq2-and-not$fragments.Contains($target)){Fail "$($record.id) links to missing stable fragment $target"}
        }
    }

    # Representative fidelity gates exercise prose, code, tables, C API, Tk
    # widgets, and large syntax/index pages.
    foreach($id in @('tcl/command/dict','tcl/command/chan','tcl/command/http','tcl/c-api/filesystem',
            'tk/command/text','tk/command/canvas','tk/command/keysyms')){
        if(-not$documents.Contains($id)){Fail "representative page absent: $id"}
        $r=$documents[$id];$md=Read-Utf8Strict (Join-Path $candidate $r.path.Replace('/','\'))
        if($md.Length-lt500-or$md-notmatch'(?m)^## (NAME|SYNOPSIS|DESCRIPTION)'){Fail "representative normalization too small or sectionless: $id"}
        if($md-match'<\/?(?:b|i|dl|dt|dd|table|tr|td|font)\b'){Fail "representative normalization leaked HTML: $id"}
        $expectedFence=if($r.type-eq'c-api'){'c'}elseif($r.type-eq'application'){'text'}else{'tcl'}
        $fencePattern='(?m)^'+[regex]::Escape('```'+$expectedFence)+'\s*$'
        if($md-match'(?m)^```'-and$md-notmatch$fencePattern){
            Fail "representative normalization has no $expectedFence language fence: $id"
        }
    }
    $dictRepresentative=Read-Utf8Strict (Join-Path $candidate 'markdown\tcl\command\dict.md')
    if($dictRepresentative-notmatch'(?m)^## NAME\s*$'-or$dictRepresentative-notmatch'(?m)^## SYNOPSIS\s*$'){
        Fail 'dict normalization lost canonical heading/synopsis structure'
    }
    $tableRepresentative=Read-Utf8Strict (Join-Path $candidate 'markdown\tk\command\colors.md')
    if($tableRepresentative-notmatch'(?m)^\| .+ \|\s*$') {Fail 'Tk colors normalization lost table structure'}
    foreach($guideId in @('machteld/guide/index','machteld/guide/overview')){
        if(-not$documents.Contains($guideId)){Fail "authored guide absent: $guideId"}
        if($documents[$guideId].summary-match'^\s*---'-or$documents[$guideId].summary-match'(?i)\btype:\s'){
            Fail "$guideId summary leaked YAML front matter"
        }
    }
    foreach($documentEntry in $documents.GetEnumerator()){
        $record=$documentEntry.Value
        if($record.product-notin@('tcl','tk')-or-not$record.formats.Contains('markdown')){continue}
        $md=Read-Utf8Strict (Join-Path $candidate $record.formats.markdown.path.Replace('/','\'))
        $structuralSections=@(Get-MarkdownSections $md "$($record.id) quality scan")
        foreach($section in $structuralSections){if(-not$section.Heading){Fail "$($record.id) normalization contains an empty heading"}}
        if($md-match'(?m)^\-\s*$'){Fail "$($record.id) normalization contains a dangling list marker"}
        $insideFence=$false
        foreach($line in $md.Replace("`r",'').Split("`n")){
            if($line-match'^\s*(`{3,}|~{3,})'){$insideFence=-not$insideFence;continue}
            if($insideFence-and$line-match'\[[^\]]+\]\((?:machteld|tcl|tk)/[^)]+\)'){
                Fail "$($record.id) normalization rewrote a source-code link inside a fence"
            }
        }
        if($insideFence){Fail "$($record.id) normalization left an unclosed code fence"}
    }
    $fenceSectionExpectations=[ordered]@{
        'tcl/command/split'=@('name','synopsis','description','examples','parsing-record-oriented-files','see-also','keywords')
        'tk/command/text'=@('name','synopsis','standard-options','widget-specific-options','description','indices','tags','marks','embedded-windows','embedded-images','the-selection','the-insertion-cursor','the-modified-flag','the-undo-mechanism','peer-widgets','asynchronous-update-of-line-heights','widget-command','bindings','known-issues','issues-concerning-chars-and-indices','performance-issues','known-bugs','see-also','keywords')
        'tcl/command/msgcat'=@('name','synopsis','description','commands','locale-specification','namespaces-and-message-catalogs','location-and-format-of-message-files','recommended-message-setup-for-packages','positional-codes-for-format-and-scan-commands','package-private-locale','changing-package-options','package-options','callback-invocation','object-oriented-programming','examples','credits','see-also','keywords')
    }
    foreach($id in @(Dictionary-Keys $fenceSectionExpectations)){
        $actual=@(Dictionary-Keys $documents[$id].sections)
        $expected=@($fenceSectionExpectations[$id])
        if([string]::Join("`n",$actual)-cne[string]::Join("`n",$expected)){
            Fail "$id outline contains fenced-code headings or lost semantic headings: $([string]::Join(',', $actual))"
        }
    }
    $cFenceRepresentative=Read-Utf8Strict (Join-Path $candidate 'markdown\tcl\c-api\adderrinfo.md')
    $cFenceBlocks=@(Get-FencedCodeBlocks $cFenceRepresentative 'tcl/c-api/adderrinfo fence fidelity')
    if(-not @($cFenceBlocks | Where-Object { $_.Language -ceq 'c' -and
                $_.Content -match 'Tcl_EvalEx\(interp, script, -1, 0\);' }).Count -or
            @($cFenceBlocks | Where-Object { $_.Content -match '\]\((?:machteld|tcl|tk)/[^)]+\)' }).Count){
        Fail 'C normalization corrupted a copyable Tcl_EvalEx source signature inside a fence'
    }
    $tclFenceRepresentative=Read-Utf8Strict (Join-Path $candidate 'markdown\tcl\command\split.md')
    $tclFenceBlocks=@(Get-FencedCodeBlocks $tclFenceRepresentative 'tcl/command/split fence fidelity')
    if(-not @($tclFenceBlocks | Where-Object { $_.Language -ceq 'tcl' -and
                $_.Content -match 'split\s+"comp\.lang\.tcl"\s+\.' }).Count -or
            @($tclFenceBlocks | Where-Object { $_.Content -match '\]\((?:machteld|tcl|tk)/[^)]+\)' }).Count){
        Fail 'Tcl normalization corrupted a copyable split command inside a fence'
    }
    $implicitTableExpectations=[ordered]@{
        'tcl/command/interp'='(?i)hidden command'
        'tcl/command/mathfunc'='(?i)function'
        'tcl/command/mathop'='(?i)operator'
        'tcl/c-api/filesystem'='(?s)## SEE ALSO.*\*\*\[cd\].*## KEYWORDS.*stat.*access'
        'tcl/c-api/setchanerr'='(?i)channel'
        'tk/command/bind'='(?i)event'
        'tk/command/canvas'='(?i)canvas'
        'tk/command/colors'='(?i)(?:alice blue|antique white)'
        'tk/command/event'='(?i)event'
        'tk/command/font'='(?i)font'
        'tk/command/palette'='(?i)palette'
        'tk/command/ttk_combobox'='(?i)combobox'
    }
    foreach($id in @(Dictionary-Keys $implicitTableExpectations)){
        if(-not$documents.Contains($id)){Fail "implicit-table representative page absent: $id"}
        $md=Read-Utf8Strict (Join-Path $candidate $documents[$id].formats.markdown.path.Replace('/','\'))
        if($md-notmatch'(?m)^\| .+ \|\s*$'-or$md-notmatch$implicitTableExpectations[$id]){
            Fail "$id normalization lost implicit table rows or trailing content"
        }
    }

    $inventory=[ordered]@{}
    foreach($file in @(Sort-Ordinal @(Get-ChildItem -LiteralPath $candidate -Recurse -File) {param($x)$x.FullName})){
        $rel=$file.FullName.Substring($candidate.Length).TrimStart('\').Replace('\','/')
        if($rel-in@('catalog.dict','catalog.json','search.dict','manifest.sha256')){continue}
        Add-Inventory $inventory $candidate $rel
    }
    $corpusHash=Corpus-Hash $inventory
    $represented = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($documentEntry in $documents.GetEnumerator()){
        $record=$documentEntry.Value
        foreach($formatEntry in $record.formats.GetEnumerator()){
            $format=$formatEntry.Value
            $path = Normalize-SlashPath ([string]$format.path)
            if(-not$inventory.Contains($path)){Fail "document representation is absent from inventory: $($record.id) -> $path"}
            [void]$represented.Add($path)
        }
    }
    $auxiliary = @(
        Sort-Ordinal @(Dictionary-Keys $inventory | Where-Object { -not $represented.Contains([string]$_) }))
    $auxiliarySeen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($path in $auxiliary){
        $canonical=Normalize-SlashPath ([string]$path)
        if($canonical-ne$path-or-not$inventory.Contains($path)-or-not$auxiliarySeen.Add($path)){
            Fail "invalid or duplicate auxiliary path: $path"
        }
        if($represented.Contains($path)){Fail "auxiliary path is also a document representation: $path"}
    }
    if($represented.Count+$auxiliarySeen.Count-ne$inventory.Count){
        Fail "document/auxiliary partition does not exactly cover inventory"
    }
    $productCounts=[ordered]@{}
    foreach($product in @('machteld','tcl','tk')){
        $catalogCount=@($documents.GetEnumerator() | ForEach-Object { $_.Value } |
            Where-Object { $_.product -eq $product }).Count
        $manualCount=@($documents.GetEnumerator() | ForEach-Object { $_.Value } |
            Where-Object { $_.product -eq $product -and $_.type -ne 'license' }).Count
        if(($product-eq'tcl'-and$manualCount-ne249)-or($product-eq'tk'-and$manualCount-ne177)){
            Fail "$product manual page count drifted to $manualCount"
        }
        $productCounts[$product]=[ordered]@{version=if($product -eq 'machteld'){$MachteldVersion}else{'9.0.4'};
            documents=$catalogCount;manual_pages=$manualCount}
    }
    $recordKeys=@('bytes','content_sha256','formats','id','names','path','product','raw_path','sections','source_file','source_sha256','summary','title','type','version')
    $formatKeys=@('bytes','characters','path','sections','sha256')
    foreach($id in @(Dictionary-Keys $documents)){
        $record=$documents[$id]
        if([string]::Join("`n",@(Sort-Ordinal @(Dictionary-Keys $record)))-cne[string]::Join("`n",$recordKeys)){
            Fail "$id document fields do not match catalog schema 1"
        }
        foreach($formatEntry in $record.formats.GetEnumerator()){
            $formatName=[string]$formatEntry.Key;$format=$formatEntry.Value
            if($formatName-notin@('markdown','html','source')-or
                    [string]::Join("`n",@(Sort-Ordinal @(Dictionary-Keys $format)))-cne[string]::Join("`n",$formatKeys)){
                Fail "$id $formatName format fields do not match catalog schema 1"
            }
            $priorStart=0
            foreach($sectionEntry in $format.sections.GetEnumerator()){
                $slug=[string]$sectionEntry.Key
                if(-not$record.sections.Contains($slug)){Fail "$id $formatName has undeclared section $slug"}
                $range=$sectionEntry.Value
                if([string]::Join("`n",@(Sort-Ordinal @(Dictionary-Keys $range)))-cne"end`nstart"){
                    Fail "$id $formatName section $slug has invalid range fields"
                }
                $start=[int64]$range.start;$end=[int64]$range.end
                if($start-lt0-or$end-lt$start-or$start-lt$priorStart-or$end-gt[int64]$format.characters){
                    Fail "$id $formatName section $slug has invalid character bounds"
                }
                $priorStart=$start
            }
        }
    }
    $searchDocs=[ordered]@{}
    foreach($id in @(Sort-Ordinal @(Dictionary-Keys $documents))){
        $r=$documents[$id];$text=Read-Utf8Strict (Join-Path $candidate $r.formats.markdown.path.Replace('/','\'))
        $searchText=$text
        if($r.id-like'machteld/guide/*'){$searchText=(Guide-Metadata $text $r.formats.markdown.path).Body}
        $priority=switch("$($r.product)/$($r.type)"){
            'machteld/command'{400}'tcl/command'{300}'tk/command'{250}'machteld/guide'{220}
            'machteld/index'{220}'tcl/application'{200}'tk/application'{200}
            'tcl/c-api'{100}'tk/c-api'{90}default{180}}
        if($priority-notin@(400,300,250,220,200,180,100,90)-or$priority-isnot[int]){
            Fail "$id search priority is not one canonical scalar integer: $priority"
        }
        $snippets=[ordered]@{};$display=[ordered]@{}
        foreach($sectionEntry in $r.sections.GetEnumerator()){
            $slug=[string]$sectionEntry.Key
            if(-not$r.formats.markdown.sections.Contains($slug)){continue};$span=$r.formats.markdown.sections[$slug]
            $piece=$text.Substring([int]$span.start,[int]$span.end-[int]$span.start);$plain=Strip-Markdown $piece
            if($plain.Length-gt240){$plain=$plain.Substring(0,240).Trim()+'...'}
            $display[$slug]=$plain;$snippets[$slug]=Normalize-Search $plain
        }
        $searchDocs[$id]=[ordered]@{priority=$priority;title=(Normalize-Search $r.title);
            aliases=(Normalize-Search ([string]::Join(' ',@($r.names))));summary=(Normalize-Search $r.summary);
            body=(Normalize-Search (Strip-Markdown $searchText));snippets=$snippets;display_snippets=$display}
    }
    $search=[ordered]@{schema=1;normalization='unicode-lower-whitespace-v1';documents=$searchDocs}
    Write-Utf8Lf (Join-Path $candidate 'search.dict') ((Tcl-Data $search)+"`n")

    $searchFacts=[ordered]@{path='search.dict';sha256=(Get-Sha256 (Join-Path $candidate 'search.dict'));
        bytes=[int64](Get-Item -LiteralPath (Join-Path $candidate 'search.dict')).Length}
    $catalog=[ordered]@{aliases=$aliases;auxiliary=$auxiliary;corpus_sha256=$corpusHash;documents=$documents;
        fragments=$fragments;generator=$GeneratorVersion;inventory=$inventory;machteld_version=$MachteldVersion;
        products=$productCounts;schema=1;search=$searchFacts}
    Write-Utf8Lf (Join-Path $candidate 'catalog.dict') ((Tcl-Data $catalog)+"`n")
    Write-Utf8Lf (Join-Path $candidate 'catalog.json') (Convert-JsonDeterministic $catalog)

    $manifestLines=New-Object Collections.Generic.List[string]
    $manifestLines.Add('# machteld reference pack v1; SHA-256 consistency manifest (self excluded)')
    foreach($file in @(Sort-Ordinal @(Get-ChildItem -LiteralPath $candidate -Recurse -File) {param($x)$x.FullName})){
        $rel=$file.FullName.Substring($candidate.Length).TrimStart('\').Replace('\','/')
        if($rel-eq'manifest.sha256'){continue};$manifestLines.Add("$(Get-Sha256 $file.FullName)  $rel")
    }
    Write-Utf8Lf (Join-Path $candidate 'manifest.sha256') ([string]::Join("`n",$manifestLines.ToArray())+"`n")
    $manifestText=Read-Utf8Strict (Join-Path $candidate 'manifest.sha256')
    $manifestRows=@($manifestText.Replace("`r",'').Split("`n") | Where-Object { $_ })
    if($manifestRows.Count-ne$manifestLines.Count-or$manifestRows[0]-ne$manifestLines[0]){Fail 'manifest shape changed while writing'}
    $expectedFiles=@(Sort-Ordinal @(Get-ChildItem -LiteralPath $candidate -Recurse -File |
        Where-Object { $_.Name -ne 'manifest.sha256' }) {param($x)$x.FullName})
    if($manifestRows.Count-1-ne$expectedFiles.Count){Fail 'manifest does not cover the exact regular-file set'}
    for($i=0;$i-lt$expectedFiles.Count;$i++){
        $rel=Normalize-SlashPath ($expectedFiles[$i].FullName.Substring($candidate.Length).TrimStart('\').Replace('\','/'))
        $expected="$(Get-Sha256 $expectedFiles[$i].FullName)  $rel"
        if($manifestRows[$i+1]-cne$expected-or$manifestRows[$i+1]-notmatch'^[0-9a-f]{64}  [^\s].*$'){
            Fail "manifest row mismatch for $rel"
        }
    }

    # Validate inert catalog/search parsing in the exact Tcl runtime used by the build.
    $validator=Join-Path $work 'validate.tcl'
    $serializerFixturePath=Join-Path $work 'serializer-fixture.list'
    $unicodeFixture='na'+[char]0x00ef+'ve '+[char]0x03a9
    $serializerFixture=@('',"a b","a`t b","a`n b","a`v b","a`f b","a`r b",
        ("a"+[char]1+"b"),("a"+[char]127+"b"),'00123','true',$unicodeFixture,
        'braces { and } brackets [ and ] dollars $ semicolon ; backslash \')
    Write-Utf8Lf $serializerFixturePath ((Tcl-Data $serializerFixture)+"`n")
    Write-Utf8Lf $validator @'
if {[llength $argv] != 2} {error {usage: validate.tcl REFERENCE SERIALIZER-FIXTURE}}
set root [lindex $argv 0]
proc read_utf8 {path} {
    set ch [open $path r]
    fconfigure $ch -encoding utf-8 -translation lf
    try {return [read $ch]} finally {close $ch}
}
proc normalize {value} {
    return [string trim [regsub -all {\s+} [string tolower $value] { }]]
}
foreach name {catalog.dict search.dict} {
    set value [read_utf8 [file join $root $name]]
    if {[catch {dict size $value} message]} {error "$name is not inert dict data: $message"}
    if {[dict get $value schema] != 1} {error "$name schema is not 1"}
}
set c [read_utf8 [file join $root catalog.dict]]
set search [read_utf8 [file join $root search.dict]]
if {[dict size [dict get $c documents]] < 400} {error {catalog is unexpectedly small}}
if {![dict exists $c documents tcl/command/dict formats markdown]} {error {dict page is absent}}
dict for {alias candidates} [dict get $c aliases] {
    if {$alias ne [normalize $alias]} {error "Tcl normalization disagrees for alias: $alias"}
}
dict for {id fields} [dict get $search documents] {
    if {[lsort [dict keys $fields]] ne {aliases body display_snippets priority snippets summary title}} {
        error "search record fields disagree for $id"
    }
    set priority [dict get $fields priority]
    if {![string is integer -strict $priority] || $priority ni {400 300 250 220 200 180 100 90}} {
        error "search priority is not one canonical scalar integer for $id: $priority"
    }
    foreach field {title aliases summary body} {
        set value [dict get $fields $field]
        if {$value ne [normalize $value]} {error "Tcl normalization disagrees for $id $field"}
    }
    dict for {slug value} [dict get $fields snippets] {
        if {$value ne [normalize $value]} {error "Tcl normalization disagrees for $id snippet $slug"}
    }
}
# Serializer round-trip covers every Tcl list separator/control class plus
# numeric-looking and Unicode values independently of the production corpus.
set fixture [list {} "a b" "a\t b" "a\n b" "a\v b" "a\f b" "a\r b" \
    "a\u0001b" "a\u007fb" {00123} {true} "na\u00efve \u03a9"]
lappend fixture [join [list {braces { and } brackets [ and ] dollars $ semicolon ; backslash} \\] { }]
set encoded [string trimright [read_utf8 [lindex $argv 1]] \n]
if {[llength $encoded] != [llength $fixture]} {error {serializer fixture list shape changed}}
foreach actual $encoded expected $fixture {
    if {$actual ne $expected} {error {serializer fixture failed to round-trip}}
}
'@
    & $Tclsh $validator $candidate $serializerFixturePath
    if($LASTEXITCODE){Fail "Tcl rejected generated inert indexes (exit $LASTEXITCODE)"}

    # A generated pack is immutable. Requiring an absent destination gives a
    # single same-parent rename publication boundary and never deletes or
    # replaces a path that another process might own. Build.ps1 supplies a
    # unique derived directory per invocation; explicit callers choose a fresh
    # destination (determinism tests use two destinations).
    if([IO.Directory]::Exists($Output) -or [IO.File]::Exists($Output)){
        Fail "output already exists; reference packs are immutable: $Output"
    }
    [IO.Directory]::Move($candidate,$Output)
    Write-Host "reference: $($documents.Count) catalog documents; Tcl 249, Tk 177; corpus $corpusHash"
}finally{
    if(-not$KeepWork){if([IO.Directory]::Exists($work)){[IO.Directory]::Delete($work,$true)};if([IO.Directory]::Exists($candidate)){[IO.Directory]::Delete($candidate,$true)}}
}
