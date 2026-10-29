[CmdletBinding()]
param([string]$CacheRoot, [string]$MsysRoot, [string]$Output)

# Headless, isolated native diagnostics. Never rebuilds the runtime/reference
# corpus, installs tools, changes dependency recipes, or modifies global state.
# Results and invocation-owned binaries are retained beneath out/ for inspection.
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $CacheRoot) { $CacheRoot = Join-Path $RepoRoot '.cache\deps' }
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
. (Join-Path $PSScriptRoot 'toolchain.ps1')
$MsysRoot = Resolve-MachteldMsysRoot $MsysRoot $RepoRoot
if (-not $Output) { $Output = Join-Path $RepoRoot ('out\native-analysis-' + [Guid]::NewGuid().ToString('n')) }
$Output = [IO.Path]::GetFullPath($Output)
# Never merge a diagnostics run with an existing directory or user output.
if (Test-Path -LiteralPath $Output) { throw "analysis output must be absent: $Output" }
New-Item -ItemType Directory -Path $Output | Out-Null
$Utf8 = [Text.UTF8Encoding]::new($false)
$gcc = Join-Path $MsysRoot 'ucrt64\bin\gcc.exe'
$tclsh = Join-Path $CacheRoot 'prefix\bin\tclsh90s.exe'
$canary = Join-Path $RepoRoot 'test\fixtures\native_analysis_canary.c'
$Runs = [Collections.Generic.List[object]]::new()
$Capabilities = [ordered]@{}
$Report = [ordered]@{
    schema = 1; status = 'running'; started_utc = [DateTime]::UtcNow.ToString('o')
    compiler = $gcc; compiler_sha256 = ''; source_sha256 = [ordered]@{}
    dependency_instrumentation = 'Tcl/Tk and SQLite archives are not instrumented; yyjson is instrumented with the JSON harness.'
    instrumented_scope = @('command-line quoting and allocation failures', 'UTF-8/UTF-16 conversion and Windows argv round trips', 'JSON reader/emitter/typed-tree ownership with yyjson', 'filesystem length/capacity boundaries', 'SQLite result cleanup and HTTP header-key ownership', 'hash token sequence exhaustion')
    limits = @('GCC analyzer is heuristic, not a proof.', 'Undefined-behavior traps do not detect all heap errors, leaks, or Win32 HANDLE misuse.', 'The Tk fixture exercises the real index formatter, not GUI rendering or a multi-gigabyte text widget.')
    capabilities = $Capabilities; runs = $Runs
}
$PriorPath = $env:PATH
$PriorWerror = $env:MACHTELD_WERROR
$PriorUbsan = $env:UBSAN_OPTIONS
$PriorAsan = $env:ASAN_OPTIONS

function Quote-Argument([string]$Value) {
    # Windows CommandLineToArgvW/CRT quoting, including trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-Native([string]$Name, [string]$Program, [string[]]$Arguments, [int]$TimeoutSeconds = 180) {
    Write-Host "native-analysis: $Name"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Program
    $start.Arguments = (@($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $start.WorkingDirectory = $RepoRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $Utf8
    $start.StandardErrorEncoding = $Utf8
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw "cannot start $Name" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # GCC launches cc1/as/ld; terminate only this still-live invocation
            # and its descendants, never all processes with a matching name.
            $stop = [Diagnostics.ProcessStartInfo]::new()
            $stop.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $stop.Arguments = '/PID ' + $process.Id + ' /T /F'
            $stop.UseShellExecute = $false; $stop.CreateNoWindow = $true
            $stop.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $stop.RedirectStandardOutput = $true; $stop.RedirectStandardError = $true
            $killer = [Diagnostics.Process]::Start($stop)
            try {
                $killOut = $killer.StandardOutput.ReadToEndAsync()
                $killErr = $killer.StandardError.ReadToEndAsync()
                if (-not $killer.WaitForExit(15000)) { throw "$Name timeout cleanup did not finish" }
                [IO.File]::WriteAllText((Join-Path $Output 'timeout-cleanup.log'),
                    ($killOut.GetAwaiter().GetResult() + $killErr.GetAwaiter().GetResult()), $Utf8)
                if (-not $process.WaitForExit(5000)) { throw "$Name timeout cleanup did not stop the owned process tree" }
            } finally { $killer.Dispose() }
            throw "$Name exceeded ${TimeoutSeconds}s"
        }
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $log = '{0:d3}-{1}.log' -f ($Runs.Count + 1), ($Name -replace '[^a-zA-Z0-9-]', '-')
        [IO.File]::WriteAllText((Join-Path $Output $log), $text, $Utf8)
        $result = [pscustomobject]@{ name = $Name; program = $Program; arguments = $Arguments; exit = $process.ExitCode; seconds = $timer.Elapsed.TotalSeconds; log = $log; text = $text }
        $Runs.Add([pscustomobject]@{ name = $Name; program = $Program; arguments = $Arguments; exit = $process.ExitCode; seconds = $timer.Elapsed.TotalSeconds; log = $log })
        return $result
    } finally { $process.Dispose() }
}
function Require-Ok($Result) {
    if ($Result.exit -ne 0) { throw "$($Result.name) failed ($($Result.exit)); see $(Join-Path $Output $Result.log)" }
}
function Compile([string]$Name, [string[]]$Arguments) {
    $result = Invoke-Native $Name $gcc $Arguments
    Require-Ok $result
}
function Run([string]$Name, [string]$Program, [string[]]$Arguments = @()) {
    $result = Invoke-Native $Name $Program $Arguments
    Require-Ok $result
    if ($result.text.Trim()) {
        $lines = @($result.text.TrimEnd() -split '\r?\n')
        if ($lines.Count -gt 8) { Write-Host "Detailed output: $(Join-Path $Output $result.log)" }
        Write-Host (($lines | Select-Object -Last 8) -join "`n")
    }
}

try {
    $env:PATH = (Join-Path $MsysRoot 'ucrt64\bin') + [IO.Path]::PathSeparator + $PriorPath
    $env:MACHTELD_WERROR = '1'
    $env:UBSAN_OPTIONS = 'halt_on_error=1:print_stacktrace=1'
    $env:ASAN_OPTIONS = 'halt_on_error=1:detect_leaks=0'
    # Hash verification only: this cannot download or rebuild dependencies.
    & (Join-Path $PSScriptRoot 'bootstrap.ps1') -CacheRoot $CacheRoot -MsysRoot $MsysRoot -VerifyOnly
    if ($LASTEXITCODE) { throw 'dependency verification failed' }
    $Report.compiler_sha256 = (Get-FileHash -LiteralPath $gcc -Algorithm SHA256).Hash.ToLowerInvariant()
    $version = Invoke-Native 'compiler-version' $gcc @('--version')
    Require-Ok $version
    $Report['compiler_version'] = $version.text.Trim()
    $configuration = Invoke-Native 'build-configuration' $tclsh @((Join-Path $PSScriptRoot 'native-analysis-config.tcl'), $CacheRoot)
    Require-Ok $configuration
    $flags = @(); $libraries = @(); $paths = @{}
    foreach ($line in ($configuration.text -split '\r?\n')) {
        if (-not $line) { continue }
        if ($line -notmatch '^(\S+) (.*)$') { throw "invalid build configuration: $line" }
        switch ($Matches[1]) {
            flag { $flags += $Matches[2] }
            library { $libraries += $Matches[2] }
            default { $paths[$Matches[1]] = $Matches[2] }
        }
    }
    $inputs = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.c') +
        @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.h')
    foreach ($relative in @('tools\native-analysis.ps1','tools\native-analysis-config.tcl','tools\buildlib.tcl',
        'test\cmdline_test.c','test\cmdline_alloc_test.c','test\wintext_test.c','test\hash_boundary_test.c',
        'test\json_test.tcl','test\native_adversarial_test.tcl','test\fixtures\native_analysis_canary.c',
        'test\fixtures\native_analysis_driver.c','test\fixtures\native_boundary_driver.c','test\fixtures\tk_index_format_test.c')) {
        $inputs += Get-Item -LiteralPath (Join-Path $RepoRoot $relative)
    }
    foreach ($file in $inputs) {
        $relative = $file.FullName.Substring($RepoRoot.Length + 1).Replace('\','/')
        $Report.source_sha256[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    # A negative canary must produce the specific diagnostic, not merely fail.
    $analysisCanary = Invoke-Native 'analyzer-negative-canary' $gcc @('-std=c23','-O0','-fanalyzer','-Werror=analyzer-use-after-free','-DANALYZER_CANARY','-c',$canary,'-o',(Join-Path $Output 'analyzer-canary.o'))
    if ($analysisCanary.exit -eq 0 -or $analysisCanary.text -notmatch 'analyzer-use-after-free') {
        throw 'GCC analyzer did not detect the required use-after-free canary'
    }
    $Capabilities['gcc_analyzer'] = 'supported; negative use-after-free canary detected'
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.c' | Sort-Object Name) {
        Compile ('analyzer-' + $file.BaseName) ($flags + @('-O0','-fanalyzer','-fdiagnostics-path-format=separate-events','-c',$file.FullName,'-o',(Join-Path $Output ($file.BaseName + '.analysis.o'))))
    }

    foreach ($mode in @('address','undefined')) {
        $exe = Join-Path $Output ($mode + '-canary.exe')
        $probe = Invoke-Native ($mode + '-capability') $gcc @('-std=c23','-O1',('-fsanitize=' + $mode),'-fno-sanitize-recover=all',$canary,'-o',$exe)
        if ($probe.exit -ne 0) {
            if ($probe.text -notmatch 'cannot find -l(asan|ubsan)|unsupported|unrecognized') { throw "unexpected sanitizer capability failure: $($probe.text)" }
            $Capabilities[$mode] = [ordered]@{status='unsupported'; reason=$probe.text.Trim(); log=$probe.log}
            Write-Host "UNSUPPORTED: $mode sanitizer runtime (see $($probe.log))"
            continue
        }
        Run ($mode + '-clean-canary') $exe
        $fault = if ($mode -eq 'address') { 'heap' } else { 'overflow' }
        $bad = Invoke-Native ($mode + '-negative-canary') $exe @($fault) 15
        if ($bad.exit -eq 0 -or $bad.text -notmatch 'AddressSanitizer|runtime error') { throw "$mode sanitizer did not diagnose its negative canary" }
        $Capabilities[$mode] = [ordered]@{status='supported'; canary=$bad.log}
    }
    $trap = @('-fsanitize=undefined','-fsanitize-undefined-trap-on-error')
    $trapExe = Join-Path $Output 'trap-canary.exe'
    Compile 'trap-capability' (@('-std=c23','-O1') + $trap + @($canary,'-o',$trapExe))
    Run 'trap-clean-canary' $trapExe
    foreach ($fault in @('overflow','bounds')) {
        $bad = Invoke-Native ('trap-negative-' + $fault) $trapExe @($fault) 15
        if ($bad.exit -ne -1073741795) { throw "undefined trap $fault did not yield STATUS_ILLEGAL_INSTRUCTION: $($bad.exit)" }
    }
    $Capabilities['undefined_trap'] = 'supported; signed-overflow and array-bounds negative canaries trapped'

    # Trap instrumentation covers authored native code and yyjson. The static
    # Tcl/Tk dependency is intentionally not rebuilt or claimed as instrumented.
    $testFlags = @('-std=c23','-O1','-g','-Wall','-Wextra','-Werror','-DSTATIC_BUILD=1',('-I' + $paths.include),('-I' + (Join-Path $RepoRoot 'src'))) + $trap
    $cmdline = Join-Path $Output 'cmdline-trap.exe'
    Compile 'instrument-commandline' ($testFlags + @((Join-Path $RepoRoot 'test\cmdline_test.c'),(Join-Path $RepoRoot 'src\winjob_cmdline.c'),'-static-libgcc','-o',$cmdline))
    Run 'instrumented-commandline' $cmdline
    $allocation = Join-Path $Output 'cmdline-allocation-trap.exe'
    Compile 'instrument-commandline-allocation-failures' ($testFlags + @((Join-Path $RepoRoot 'test\cmdline_alloc_test.c'),'-static-libgcc','-o',$allocation))
    Run 'instrumented-commandline-allocation-failures' $allocation
    $wintext = Join-Path $Output 'wintext-trap.exe'
    Compile 'instrument-unicode' ($testFlags + @((Join-Path $RepoRoot 'test\wintext_test.c'),(Join-Path $RepoRoot 'src\wintext.c'),(Join-Path $RepoRoot 'src\winjob_cmdline.c'),'-static-libgcc','-lshell32','-o',$wintext))
    Run 'instrumented-unicode' $wintext
    $json = Join-Path $Output 'json-trap.exe'
    Compile 'instrument-json' ($testFlags + @('-municode',('-I' + $paths.yyjson),(Join-Path $RepoRoot 'test\fixtures\native_analysis_driver.c'),(Join-Path $RepoRoot 'src\json.c'),(Join-Path $RepoRoot 'src\wintext.c'),(Join-Path $paths.yyjson 'yyjson.c'),$paths.tcllib,'-static-libgcc') + $libraries + @('-o',$json))
    Run 'instrumented-json-corpus' $json @((Join-Path $RepoRoot 'test\json_test.tcl'))
    Run 'instrumented-json-adversarial' $json @((Join-Path $RepoRoot 'test\native_adversarial_test.tcl'),'--json-only')

    $sqliteObject = Join-Path $Output 'sqlite-boundary.o'
    Compile 'boundary-sqlite-dependency-uninstrumented' @('-O0','-w','-DSQLITE_THREADSAFE=1','-DSQLITE_OMIT_LOAD_EXTENSION','-DSQLITE_DQS=0','-DSQLITE_OMIT_DEPRECATED','-DSQLITE_OMIT_SHARED_CACHE','-c',(Join-Path $paths.sqlite 'sqlite3.c'),'-o',$sqliteObject)
    $boundary = Join-Path $Output 'native-boundary-trap.exe'
    Compile 'instrument-native-boundaries' ($testFlags + @(('-I' + $paths.sqlite),(Join-Path $RepoRoot 'test\fixtures\native_boundary_driver.c'),(Join-Path $RepoRoot 'src\wintext.c'),$sqliteObject,$paths.tcllib,'-static-libgcc') + $libraries + @('-o',$boundary))
    Run 'instrumented-native-boundaries' $boundary
    $hashBoundary = Join-Path $Output 'hash-boundary-trap.exe'
    Compile 'instrument-hash-sequence-boundary' ($testFlags + @((Join-Path $RepoRoot 'test\hash_boundary_test.c'),$paths.tcllib,'-static-libgcc') + $libraries + @('-o',$hashBoundary))
    Run 'instrumented-hash-sequence-boundary' $hashBoundary

    # The linked archive is the same Tk used by production, not a hand-copied
    # snprintf expression. Only the synthetic tree's line lookup is replaced.
    $tkRoots = @(Get-ChildItem -Path (Join-Path $CacheRoot 'src\tcltk-*\tk*') -Directory)
    if ($tkRoots.Count -ne 1) { throw 'expected exactly one pinned Tk source directory' }
    $tkRoot = $tkRoots[0].FullName
    $tk = Join-Path $Output 'tk-index-format.exe'
    $tkIncludes = @('generic','win','xlib') | ForEach-Object { '-I' + (Join-Path $tkRoot $_) }
    Compile 'tk-real-index-formatter' (@('-std=c23','-O2','-DSTATIC_BUILD=1',('-I' + $paths.include)) + $tkIncludes + @((Join-Path $RepoRoot 'test\fixtures\tk_index_format_test.c'),$paths.tklib,$paths.tcllib,$paths.tclstub,'-Wl,--wrap=TkBTreeLinesTo','-static-libgcc') + $libraries + @('-o',$tk))
    Run 'tk-large-index-headless' $tk
    $Capabilities['tk_large_index'] = 'real pinned TkTextPrintIndex passed 0, 2^31, 2^32+17, INT64_MAX without Tk_Init/windows'

    # Distinguish compiler output-path support from Unicode runtime deployment.
    $ascii = Join-Path $Output 'ASCII output with spaces'
    $unicode = Join-Path $Output ('output-' + [char]0x4e16 + [char]0x754c)
    New-Item -ItemType Directory -Path $ascii,$unicode | Out-Null
    $asciiExe = Join-Path $ascii 'canary.exe'
    Compile 'ascii-spaces-output' @('-std=c23',$canary,'-o',$asciiExe)
    Run 'ascii-spaces-execution' $asciiExe
    $unicodeResults = [ordered]@{}
    foreach ($stage in @('assembler','linker')) {
        $target = Join-Path $unicode $(if ($stage -eq 'assembler') { 'canary.o' } else { 'canary.exe' })
        $arguments = @('-std=c23',$canary,'-o',$target)
        if ($stage -eq 'assembler') { $arguments = @('-c') + $arguments }
        $probe = Invoke-Native ('unicode-output-' + $stage) $gcc $arguments
        if ($probe.exit -ne 0 -and $probe.text -notmatch 'can.t create|cannot open output file') { throw "unexpected Unicode output failure: $($probe.text)" }
        $unicodeResults[$stage] = [ordered]@{status=$(if ($probe.exit -eq 0) {'supported'} else {'unsupported'}); log=$probe.log; detail=$probe.text.Trim()}
    }
    $deployed = Join-Path $unicode 'deployed-canary.exe'
    Copy-Item -LiteralPath $asciiExe -Destination $deployed
    Run 'unicode-deployed-execution' $deployed
    $Capabilities['unicode_native_output'] = $unicodeResults
    foreach ($entry in $Report.source_sha256.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        $after = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($after -cne $entry.Value) { throw "source changed during native analysis: $($entry.Key); rerun on a stable checkout" }
    }
    $Report['source_inputs_unchanged'] = $true
    $Report.status = 'passed'
} catch {
    $Report.status = 'failed'
    $Report['error'] = $_.Exception.Message
    throw
} finally {
    $Report['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $Output 'report.json'), ($Report | ConvertTo-Json -Depth 12), $Utf8)
    $env:PATH = $PriorPath
    $env:MACHTELD_WERROR = $PriorWerror
    $env:UBSAN_OPTIONS = $PriorUbsan
    $env:ASAN_OPTIONS = $PriorAsan
    Write-Host "Native analysis report: $(Join-Path $Output 'report.json')"
}
