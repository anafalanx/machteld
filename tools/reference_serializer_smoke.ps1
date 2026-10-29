[CmdletBinding()]
param([Parameter(Mandatory)][string]$Tclsh)

$ErrorActionPreference = 'Stop'
if (-not ('MachteldReferenceData' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'reference-data.cs') }
$Utf8 = [Text.UTF8Encoding]::new($false)
$Work = Join-Path ([IO.Path]::GetTempPath()) "machteld-reference-serializer-smoke-$PID"

function Tcl-Word([string]$Value) {
    if (-not $Value.Length) { return '{}' }
    $b=[Text.StringBuilder]::new()
    foreach($c in $Value.ToCharArray()){
        $code=[int][char]$c
        switch($code){
            8{[void]$b.Append('\b')} 9{[void]$b.Append('\t')} 10{[void]$b.Append('\n')}
            11{[void]$b.Append('\v')} 12{[void]$b.Append('\f')} 13{[void]$b.Append('\r')}
            32{[void]$b.Append('\ ')} 34{[void]$b.Append('\"')} 36{[void]$b.Append('\$')}
            59{[void]$b.Append('\;')} 91{[void]$b.Append('\[')} 92{[void]$b.Append('\\')}
            93{[void]$b.Append('\]')} 123{[void]$b.Append('\{')} 125{[void]$b.Append('\}')}
            default{if($code-lt32-or$code-eq127-or[char]::IsWhiteSpace($c)){[void]$b.Append(('\u{0:x4}'-f$code))}else{[void]$b.Append($c)}}
        }
    }
    return $b.ToString()
}

[IO.Directory]::CreateDirectory($Work)|Out-Null
try{
    $unicode='na'+[char]0x00ef+'ve '+[char]0x03a9
    $fixture=@('',"a b","a`t b","a`n b","a`v b","a`f b","a`r b",("a"+[char]1+"b"),
        ("a"+[char]127+"b"),'00123','true',$unicode,'braces { and } brackets [ and ] dollars $ semicolon ; backslash \')
    # Compare the established encoder with production over every UTF-16 unit.
    $allChars = -join ([char[]](0..65535))
    if ((Tcl-Word $allChars) -cne [MachteldReferenceData]::Word($allChars)) {
        throw 'fast Tcl escaping differs from the established byte encoding'
    }
    $nested = [ordered]@{keys=@('a b','00123'); empty=@(); truth=$true; zero=[int64]0; nil=$null}
    $json = [MachteldReferenceData]::Json($nested)
    if ($json -cne '{"keys":["a b","00123"],"empty":[],"truth":true,"zero":0,"nil":null}') { throw 'JSON shape/types changed' }
    $roundTrip = [MachteldReferenceData]::Ordered(($json | ConvertFrom-Json))
    if ([MachteldReferenceData]::Json($roundTrip) -cne $json -or
        [MachteldReferenceData]::Tcl($roundTrip) -cne [MachteldReferenceData]::Tcl($nested)) { throw 'stage-state round trip changed bytes' }
    $list=[MachteldReferenceData]::Tcl($fixture)
    $listPath=Join-Path $Work 'fixture.list';[IO.File]::WriteAllText($listPath,$list+"`n",$Utf8)
    $scriptPath=Join-Path $Work 'smoke.tcl'
    $script=@'
set ch [open [lindex $argv 0] r]; fconfigure $ch -encoding utf-8 -translation lf
set actual [string trimright [read $ch] \n]; close $ch
set expected [list {} "a b" "a\t b" "a\n b" "a\v b" "a\f b" "a\r b" \
    "a\u0001b" "a\u007fb" {00123} {true} "na\u00efve \u03a9"]
lappend expected [join [list {braces { and } brackets [ and ] dollars $ semicolon ; backslash} \\] { }]
if {[llength $actual] != [llength $expected]} {error {shape mismatch}}
foreach a $actual e $expected {if {$a ne $e} {error "value mismatch: <$a> != <$e>"}}
puts SERIALIZER-SMOKE-OK
'@
    [IO.File]::WriteAllText($scriptPath,$script,$Utf8)
    & $Tclsh $scriptPath $listPath
    if($LASTEXITCODE){throw "serializer Tcl smoke failed with exit code $LASTEXITCODE"}
}finally{
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
