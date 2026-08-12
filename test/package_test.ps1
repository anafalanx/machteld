[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tclsh
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$PackageScript = Join-Path $RepoRoot 'tools\package.tcl'
$Work = Join-Path ([IO.Path]::GetTempPath()) "machteld-package-test-$PID"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Failures = 0

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "ok   $Name"; return }
    $script:Failures++
    Write-Host "FAIL $Name $Detail"
}
function Invoke-Package([string[]]$Arguments) {
    $stdout = Join-Path $Work "stdout-$([Guid]::NewGuid().ToString('n')).txt"
    $stderr = Join-Path $Work "stderr-$([Guid]::NewGuid().ToString('n')).txt"
    $process = Start-Process -FilePath $Tclsh -ArgumentList (@($PackageScript) + $Arguments) `
        -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
    [pscustomobject]@{
        Exit = $process.ExitCode
        Text = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) +
               (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
    }
}

try {
    $result = Invoke-Package @('--unknown', 'value')
    Check 'package parser rejects unknown options' `
        ($result.Exit -ne 0 -and $result.Text -match 'unknown option') $result.Text
    $result = Invoke-Package @('--prefix')
    Check 'package parser rejects missing option values' `
        ($result.Exit -ne 0 -and $result.Text -match 'needs a value') $result.Text

    $licenseHashes = @{
        'Tcl-9.0.4.txt' = 'C0A69A2BFD757361EC7E6143973B103C90409316B49E9C88DB26AD6388E79F16'
        'Tk-9.0.4.txt'  = '2CDE822B93CA16AE535C954B7DFE658B4AD10DF2A193628D1B358F1765E8B198'
    }
    foreach ($notice in $licenseHashes.Keys) {
        $path = Join-Path $RepoRoot "licenses\$notice"
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Check "tracked $notice notice is verbatim" ($actual -eq $licenseHashes[$notice]) $actual
    }

    $prefix = Join-Path $Work 'prefix'
    $tclLibrary = Join-Path $prefix 'lib\tcl9.0'
    $tclModules = Join-Path $prefix 'lib\tcl9\9.0'
    $tkLibrary = Join-Path $prefix 'lib\tk9.0'
    $encodingLibrary = Join-Path $tclLibrary 'encoding'
    $messageLibrary = Join-Path $tclLibrary 'msgs'
    $timezoneLibrary = Join-Path $tclLibrary 'tzdata\Europe'
    New-Item -ItemType Directory -Force -Path `
        $tclLibrary, $encodingLibrary, $messageLibrary, $timezoneLibrary, $tkLibrary | Out-Null
    [IO.File]::WriteAllText((Join-Path $tclLibrary 'init.tcl'), 'set ::fixture_tcl 1')
    foreach ($name in @('clock.tcl', 'package.tcl', 'tm.tcl', 'tclIndex')) {
        [IO.File]::WriteAllText((Join-Path $tclLibrary $name), "# fixture $name")
    }
    [IO.File]::WriteAllText((Join-Path $encodingLibrary 'cp1252.enc'), 'fixture encoding')
    [IO.File]::WriteAllText((Join-Path $messageLibrary 'nl.msg'), 'fixture catalog')
    [IO.File]::WriteAllText((Join-Path $timezoneLibrary 'Brussels'), 'fixture timezone')
    [IO.File]::WriteAllText((Join-Path $tkLibrary 'tk.tcl'), 'set ::fixture_tk 1')
    $prelude = Join-Path $Work 'machteld.tcl'
    [IO.File]::WriteAllText($prelude, 'set ::fixture_prelude 1')
    $licenses = Join-Path $RepoRoot 'licenses'
    $apacheLicense = Join-Path $RepoRoot 'LICENSE'
    $out = Join-Path $Work 'published.exe'
    $sentinel = [Text.Encoding]::ASCII.GetBytes('prior-release')
    [IO.File]::WriteAllBytes($out, $sentinel)

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', (Join-Path $Work 'missing.tcl'),
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--out', $out)
    Check 'failed packaging preserves the prior output' `
        ($result.Exit -ne 0 -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out)) -eq 'prior-release') $result.Text
    Check 'failed packaging removes only its unique work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--out', $out)
    Check 'packaging refuses a missing Tcl module tree' `
        ($result.Exit -ne 0 -and $result.Text -match 'Tcl module tree not found' -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out)) -eq 'prior-release') $result.Text
    Check 'missing-module failure cleans its unique work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))

    New-Item -ItemType Directory -Force -Path $tclModules | Out-Null
    [IO.File]::WriteAllText((Join-Path $tclModules 'msgcat-1.7.1.tm'), 'package provide msgcat 1.7.1')

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', (Join-Path $Work 'missing-licenses'),
        '--apache-license', $apacheLicense, '--out', $out)
    Check 'packaging refuses missing distribution notices' `
        ($result.Exit -ne 0 -and $result.Text -match 'license notice directory not found' -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out)) -eq 'prior-release') $result.Text

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', (Join-Path $Work 'missing-apache.txt'), '--out', $out)
    Check 'packaging refuses a missing Apache license' `
        ($result.Exit -ne 0 -and $result.Text -match 'Apache 2.0 license not found' -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out)) -eq 'prior-release') $result.Text

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--out', $out)
    Check 'successful packaging publishes only after lmkimg succeeds' `
        ($result.Exit -eq 0 -and (Get-Item -LiteralPath $out).Length -gt 1MB -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out), 0, 2) -eq 'MZ') $result.Text
    Check 'successful packaging leaves no staging or candidate paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))
    $validator = Join-Path $Work 'validate-package.tcl'
    [IO.File]::WriteAllText($validator, @'
if {[llength $argv] != 2} { error "usage: validate-package.tcl IMAGE APACHE-LICENSE" }
set mount package-test-[pid]
zipfs mount [lindex $argv 0] $mount
try {
    foreach relative {
        tcl_library/init.tcl
        tcl_library/clock.tcl
        tcl_library/package.tcl
        tcl_library/tm.tcl
        tcl_library/tclIndex
        tcl_library/encoding/cp1252.enc
        tcl_library/msgs/nl.msg
        tcl_library/tzdata/Europe/Brussels
        tcl9/9.0/msgcat-1.7.1.tm
        tk_library/tk.tcl
        licenses/Apache-2.0.txt
        licenses/Tcl-9.0.4.txt
        licenses/Tk-9.0.4.txt
    } {
        set path [file join //zipfs:/$mount {*}[file split $relative]]
        if {![file isfile $path]} { error "packaged runtime file is missing: $relative" }
    }
    set channel [open //zipfs:/$mount/licenses/Apache-2.0.txt rb]
    set embeddedApache [read $channel]
    close $channel
    set channel [open [lindex $argv 1] rb]
    set sourceApache [read $channel]
    close $channel
    if {$embeddedApache ne $sourceApache} {
        error "packaged Apache license is not the tracked LICENSE"
    }
} finally {
    zipfs unmount $mount
}
'@, [Text.UTF8Encoding]::new($false))
    & $Tclsh $validator $out $apacheLicense
    $validatorExit = $LASTEXITCODE
    Check 'packaged image carries the complete Tcl runtime layout' `
        ($validatorExit -eq 0) "validator exit $validatorExit"

    [IO.File]::WriteAllBytes($out, $sentinel)
    $locked = [IO.File]::Open($out, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    try {
        $result = Invoke-Package @(
            '--prefix', $prefix, '--prelude', $prelude,
            '--wrapper', $Tclsh, '--licenses', $licenses,
            '--apache-license', $apacheLicense, '--out', $out)
    } finally {
        $locked.Dispose()
    }
    Check 'publication failure preserves the prior output' `
        ($result.Exit -ne 0 -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out)) -eq 'prior-release') $result.Text
    Check 'publication failure removes its unique work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Failures) { throw "$Failures package parser test(s) failed" }
Write-Host 'ALL PACKAGE PARSER TESTS PASSED'
