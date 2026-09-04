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

    $licenseHashes = [ordered]@{
        'Tcl-9.0.4.txt' = 'C0A69A2BFD757361EC7E6143973B103C90409316B49E9C88DB26AD6388E79F16'
        'Tk-9.0.4.txt'  = '2CDE822B93CA16AE535C954B7DFE658B4AD10DF2A193628D1B358F1765E8B198'
        'zlib-1.3.2.txt' = 'E32FF4E00D9D94930537635291DA39E7E612703334BF6FDE8C7F1686FE8A45A2'
        'LibTomMath-1.3.0.txt' = '2FA64B163659F41965C9815882A8296D3D03FF546B76153E11445F9BDECF955A'
        'yyjson-0.12.0.txt' = '45E384D3D52C73CBA3A64D6E6C25D47CD738CD8A55C30629E3201046EDA62947'
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
    $reference = Join-Path $Work 'reference'
    $referenceMarkdown = Join-Path $reference 'markdown\machteld'
    New-Item -ItemType Directory -Force -Path $referenceMarkdown | Out-Null
    foreach ($name in @('catalog.dict', 'catalog.json', 'search.dict', 'manifest.sha256', 'schema.json',
            'START-HERE.md', 'AGENTS.md')) {
        [IO.File]::WriteAllText((Join-Path $reference $name), "fixture $name`n",
            [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $referenceMarkdown 'agent.md'),
        "# Fixture agent reference`n", [Text.UTF8Encoding]::new($false))
    $licenses = Join-Path $RepoRoot 'licenses'
    $apacheLicense = Join-Path $RepoRoot 'LICENSE'
    $sentinel = [Text.Encoding]::ASCII.GetBytes('prior-release')
    $existingOut = Join-Path $Work ".machteld-build-$([Guid]::NewGuid().ToString('n')).exe"
    [IO.File]::WriteAllBytes($existingOut, $sentinel)

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--reference', $reference, '--out', $existingOut)
    Check 'packaging refuses to replace an existing output' `
        ($result.Exit -ne 0 -and $result.Text -match 'output already exists' -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($existingOut)) -eq
            'prior-release') $result.Text
    Check 'existing-output refusal creates no work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force |
            Where-Object Name -Like '.machteld-package-*'))

    $out = Join-Path $Work ".machteld-build-$([Guid]::NewGuid().ToString('n')).exe"

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', (Join-Path $Work 'missing.tcl'),
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--reference', $reference, '--out', $out)
    Check 'failed packaging does not publish a partial output' `
        ($result.Exit -ne 0 -and -not (Test-Path -LiteralPath $out)) $result.Text
    Check 'failed packaging removes only its unique work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--reference', $reference, '--out', $out)
    Check 'packaging refuses a missing Tcl module tree' `
        ($result.Exit -ne 0 -and $result.Text -match 'Tcl module tree not found' -and
         -not (Test-Path -LiteralPath $out)) $result.Text
    Check 'missing-module failure cleans its unique work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))

    New-Item -ItemType Directory -Force -Path $tclModules | Out-Null
    [IO.File]::WriteAllText((Join-Path $tclModules 'msgcat-1.7.1.tm'), 'package provide msgcat 1.7.1')

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', (Join-Path $Work 'missing-licenses'),
        '--apache-license', $apacheLicense, '--reference', $reference, '--out', $out)
    Check 'packaging refuses missing distribution notices' `
        ($result.Exit -ne 0 -and $result.Text -match 'license notice directory not found' -and
         -not (Test-Path -LiteralPath $out)) $result.Text

    foreach ($missingNotice in $licenseHashes.Keys) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($missingNotice)
        $incompleteLicenses = Join-Path $Work "incomplete-licenses-$stem"
        New-Item -ItemType Directory -Force -Path $incompleteLicenses | Out-Null
        foreach ($notice in $licenseHashes.Keys) {
            if ($notice -cne $missingNotice) {
                Copy-Item -LiteralPath (Join-Path $licenses $notice) `
                    -Destination $incompleteLicenses
            }
        }
        $missingOut = Join-Path $Work ".machteld-build-$([Guid]::NewGuid().ToString('n')).exe"
        $result = Invoke-Package @(
            '--prefix', $prefix, '--prelude', $prelude,
            '--wrapper', $Tclsh, '--licenses', $incompleteLicenses,
            '--apache-license', $apacheLicense, '--reference', $reference,
            '--out', $missingOut)
        Check "packaging refuses a missing $missingNotice notice" `
            ($result.Exit -ne 0 -and
             $result.Text -match ([regex]::Escape("required license notice not found: $missingNotice")) -and
             -not (Test-Path -LiteralPath $missingOut)) $result.Text
    }

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', (Join-Path $Work 'missing-apache.txt'),
        '--reference', $reference, '--out', $out)
    Check 'packaging refuses a missing Apache license' `
        ($result.Exit -ne 0 -and $result.Text -match 'Apache 2.0 license not found' -and
         -not (Test-Path -LiteralPath $out)) $result.Text

    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense,
        '--reference', (Join-Path $Work 'missing-reference'), '--out', $out)
    Check 'packaging refuses a missing reference pack' `
        ($result.Exit -ne 0 -and $result.Text -match 'reference pack directory not found' -and
         -not (Test-Path -LiteralPath $out)) $result.Text

    $incompleteReference = Join-Path $Work 'incomplete-reference'
    New-Item -ItemType Directory -Force -Path $incompleteReference | Out-Null
    [IO.File]::WriteAllText((Join-Path $incompleteReference 'catalog.dict'), 'fixture')
    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense,
        '--reference', $incompleteReference, '--out', $out)
    Check 'packaging refuses an incomplete reference pack' `
        ($result.Exit -ne 0 -and $result.Text -match 'reference pack is incomplete' -and
         -not (Test-Path -LiteralPath $out)) $result.Text

    $catalogJson = Join-Path $reference 'catalog.json'
    Remove-Item -LiteralPath $catalogJson -Force
    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense,
        '--reference', $reference, '--out', $out)
    [IO.File]::WriteAllText($catalogJson, "fixture catalog.json`n",
        [Text.UTF8Encoding]::new($false))
    Check 'packaging refuses a reference pack without its agent JSON catalog' `
        ($result.Exit -ne 0 -and
         $result.Text -match 'reference pack is incomplete: catalog.json' -and
         -not (Test-Path -LiteralPath $out)) $result.Text

    $packagingLicenses = Join-Path $Work 'licenses-with-untracked-sentinel'
    New-Item -ItemType Directory -Force -Path $packagingLicenses | Out-Null
    foreach ($notice in $licenseHashes.Keys) {
        Copy-Item -LiteralPath (Join-Path $licenses $notice) `
            -Destination $packagingLicenses
    }
    [IO.File]::WriteAllText((Join-Path $packagingLicenses 'UNTRACKED-SENTINEL.txt'),
        'must not enter the package', [Text.UTF8Encoding]::new($false))
    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $packagingLicenses,
        '--apache-license', $apacheLicense, '--reference', $reference, '--out', $out)
    Check 'successful packaging publishes only after lmkimg succeeds' `
        ($result.Exit -eq 0 -and (Get-Item -LiteralPath $out).Length -gt 1MB -and
         [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($out), 0, 2) -eq 'MZ') $result.Text
    Check 'successful package is not marked temporary' `
        (((Get-Item -LiteralPath $out).Attributes -band
          [IO.FileAttributes]::Temporary) -eq 0)
    Check 'successful packaging leaves no staging or candidate paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))
    $validator = Join-Path $Work 'validate-package.tcl'
    [IO.File]::WriteAllText($validator, @'
if {[llength $argv] != 4} { error "usage: validate-package.tcl IMAGE APACHE-LICENSE LICENSES REFERENCE" }
proc read_binary {path} {
    set channel [open $path rb]
    try { return [read $channel] } finally { close $channel }
}
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
        licenses/zlib-1.3.2.txt
        licenses/LibTomMath-1.3.0.txt
        licenses/yyjson-0.12.0.txt
        reference/catalog.dict
        reference/catalog.json
        reference/search.dict
        reference/manifest.sha256
        reference/schema.json
        reference/START-HERE.md
        reference/AGENTS.md
        reference/markdown/machteld/agent.md
    } {
        set path [file join //zipfs:/$mount {*}[file split $relative]]
        if {![file isfile $path]} { error "packaged runtime file is missing: $relative" }
    }
    set embeddedApache [read_binary //zipfs:/$mount/licenses/Apache-2.0.txt]
    set sourceApache [read_binary [lindex $argv 1]]
    if {$embeddedApache ne $sourceApache} {
        error "packaged Apache license is not the tracked LICENSE"
    }
    if {[file exists //zipfs:/$mount/licenses/UNTRACKED-SENTINEL.txt]} {
        error "packaging copied a notice outside its explicit allowlist"
    }
    foreach notice {
        Tcl-9.0.4.txt Tk-9.0.4.txt zlib-1.3.2.txt LibTomMath-1.3.0.txt
        yyjson-0.12.0.txt
    } {
        set embedded [read_binary [file join //zipfs:/$mount/licenses $notice]]
        set source [read_binary [file join [lindex $argv 2] $notice]]
        if {$embedded ne $source} {
            error "packaging changed license bytes: $notice"
        }
    }
    foreach relative {
        catalog.dict catalog.json search.dict manifest.sha256 schema.json START-HERE.md
        AGENTS.md markdown/machteld/agent.md
    } {
        set embedded [read_binary [file join //zipfs:/$mount/reference {*}[file split $relative]]]
        set source [read_binary [file join [lindex $argv 3] {*}[file split $relative]]]
        if {$embedded ne $source} {
            error "packaging changed reference bytes: $relative"
        }
    }
} finally {
    zipfs unmount $mount
}
'@, [Text.UTF8Encoding]::new($false))
    & $Tclsh $validator $out $apacheLicense $licenses $reference
    $validatorExit = $LASTEXITCODE
    Check 'packaged image carries complete runtime and byte-identical reference payloads' `
        ($validatorExit -eq 0) "validator exit $validatorExit"

    $packagedHash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
    $result = Invoke-Package @(
        '--prefix', $prefix, '--prelude', $prelude,
        '--wrapper', $Tclsh, '--licenses', $licenses,
        '--apache-license', $apacheLicense, '--reference', $reference, '--out', $out)
    Check 'a packaged candidate cannot be reused or replaced' `
        ($result.Exit -ne 0 -and $result.Text -match 'output already exists' -and
         (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -eq $packagedHash) $result.Text
    Check 'existing-candidate refusal leaves no unique work paths' `
        (-not (Get-ChildItem -LiteralPath $Work -Force | Where-Object Name -Like '.machteld-package-*'))

    try {
        & (Join-Path $RepoRoot 'test\build_publication_test.ps1')
        Check 'native build-publication tests pass' $true
    } catch {
        Check 'native build-publication tests pass' $false $_.Exception.Message
    }
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Failures) { throw "$Failures package parser test(s) failed" }
Write-Host 'ALL PACKAGE PARSER TESTS PASSED'
