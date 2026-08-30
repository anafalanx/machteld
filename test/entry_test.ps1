[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Machteld,
    [Parameter(Mandatory)][string]$ProcessFixture,
    [string]$Bare
)

$ErrorActionPreference = 'Stop'
$Machteld = [IO.Path]::GetFullPath($Machteld)
$ProcessFixture = [IO.Path]::GetFullPath($ProcessFixture)
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Work = Join-Path ([IO.Path]::GetTempPath()) "machteld-entry-test-$PID"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Failures = 0

# The expected version is DERIVED from the canonical source, never written here:
# the 0.15.0 sweep found five hardcoded 0.14.0 expectations in this file, which
# is the exact failure mode the estate's derive-don't-maintain rule names. The
# regex matches generate-reference.ps1's canonical check.
$headerText = Get-Content (Join-Path $Root 'src/machteld.h') -Raw
if ($headerText -notmatch '(?m)^#define\s+MACHTELD_VERSION\s+"([0-9]+\.[0-9]+\.[0-9]+)"\s*$') {
    throw 'src/machteld.h has no canonical MACHTELD_VERSION'
}
$MachteldVersion = $Matches[1]
$MachteldVersionRe = [regex]::Escape($MachteldVersion)

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "ok   $Name"; return }
    $script:Failures++
    Write-Host "FAIL $Name $Detail"
}
function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Wait-ForFile([string]$Path, [int]$Milliseconds = 5000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $Milliseconds) {
        if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
            (Get-Item -LiteralPath $Path).Length -gt 0) { return $true }
        Start-Sleep -Milliseconds 25
    }
    return $false
}
function Wait-ForProcessGone([int]$ProcessId, [int]$Milliseconds = 5000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $Milliseconds) {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 25
    }
    return $false
}
function ConvertTo-NativeArgument([AllowEmptyString()][string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$quoted.Append(('\' * (2 * $slashes + 1)))
            [void]$quoted.Append('"')
        } else {
            if ($slashes) { [void]$quoted.Append(('\' * $slashes)) }
            [void]$quoted.Append($character)
        }
        $slashes = 0
    }
    if ($slashes) { [void]$quoted.Append(('\' * (2 * $slashes))) }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}
function Invoke-Host(
    [string[]]$Arguments,
    [string]$WorkingDirectory = '',
    [string]$Executable = $Machteld
) {
    $stdout = Join-Path $Work "stdout-$([Guid]::NewGuid().ToString('n')).txt"
    $stderr = Join-Path $Work "stderr-$([Guid]::NewGuid().ToString('n')).txt"
    $argumentLine = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start = @{
        FilePath = $Executable
        ArgumentList = $argumentLine
        Wait = $true
        PassThru = $true
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
        WindowStyle = 'Hidden'
    }
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @start
    [pscustomobject]@{
        Exit = $process.ExitCode
        Out = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
        Err = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
    }
}

try {
    # Tcl ticket d40d8db3: an exact descendant can be opened while a parent
    # directory cannot be enumerated. Tcl 9.0.4 used to drop one component
    # while normalizing the executable path, preventing standalone zipfs
    # startup. Exercise the actual packaged host and wrap route under that ACL.
    $aclRoot = Join-Path $Work 'acl-normalize'
    $aclBlocked = Join-Path $aclRoot 'profilecomponent'
    $aclChild = Join-Path $aclBlocked 'app'
    $aclHost = Join-Path $aclChild 'machteld.exe'
    New-Item -ItemType Directory -Path $aclChild | Out-Null
    Copy-Item -LiteralPath $Machteld -Destination $aclHost
    $aclOriginalSddl = $null
    $aclChanged = $false
    try {
        $acl = Get-Acl -LiteralPath $aclBlocked
        $aclOriginalSddl = $acl.Sddl
        $denyList = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.AccessControl.FileSystemRights]::ListDirectory,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny
        )
        [void]$acl.AddAccessRule($denyList)
        Set-Acl -LiteralPath $aclBlocked -AclObject $acl
        $aclChanged = $true

        $directOpen = $false
        try {
            $stream = [IO.File]::Open(
                $aclHost,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            )
            $stream.Dispose()
            $directOpen = $true
        } catch {}
        $enumerationDenied = $false
        try {
            [void][IO.Directory]::GetFileSystemEntries($aclBlocked)
        } catch [UnauthorizedAccessException] {
            $enumerationDenied = $true
        }
        Check 'ACL regression fixture permits exact open but denies parent enumeration' `
            ($directOpen -and $enumerationDenied)

        $result = Invoke-Host -Arguments @('--version') -Executable $aclHost
        Check 'standalone zipfs starts below an ACL-denied parent' `
            ($result.Exit -eq 0 -and $result.Out -match $MachteldVersionRe) `
            ($result.Err + $result.Out)

        $aclProgram = Join-Path $Work 'acl-entry.tcl'
        Write-Utf8 $aclProgram @'
package require machteld
set normalized [file normalize [info nameofexecutable]]
puts "ACL-ENTRY:[file exists $normalized]:[version]"
'@
        $result = Invoke-Host -Arguments @($aclProgram) -Executable $aclHost
        Check 'direct entry runs below an ACL-denied parent without losing a path component' `
            ($result.Exit -eq 0 -and $result.Out -match ("ACL-ENTRY:1:" + $MachteldVersionRe)) `
            ($result.Err + $result.Out)

        $aclWrapped = Join-Path $Work 'acl-wrapped.exe'
        $result = Invoke-Host -Arguments @(
            'wrap', $aclProgram, '-o', $aclWrapped, '--console'
        ) -Executable $aclHost
        Check 'wrap runs from a host below an ACL-denied parent' `
            ($result.Exit -eq 0 -and (Test-Path -LiteralPath $aclWrapped -PathType Leaf)) `
            ($result.Err + $result.Out)
    } finally {
        if ($aclChanged) {
            $restoredAcl = [Security.AccessControl.DirectorySecurity]::new()
            $restoredAcl.SetSecurityDescriptorSddlForm($aclOriginalSddl)
            Set-Acl -LiteralPath $aclBlocked -AclObject $restoredAcl
        }
    }

    $accepted = Join-Path $Work 'accepted.program'
    Write-Utf8 $accepted @'
#!/usr/bin/env machteld
# Leading comments and blank lines are allowed.

package require machteld
puts "ENTRY-OK:$argv"
puts "ENTRY-PATH:[expr {$argv0 eq [info script]}]"
puts "ENTRY-ARGC:$argc"
puts "ENTRY-LAST:[lindex $argv end]"
'@
    $result = Invoke-Host @($accepted, 'one', 'two words')
    Check 'direct invocation accepts arbitrary extension and literal opt-in' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-OK:one' -and $result.Out -match 'two words') $result.Err
    Check 'direct invocation preserves argv0 and info script identity' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-PATH:1') ($result.Err + $result.Out)
    Check 'direct invocation preserves a spaced argument as one item' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-ARGC:2' -and
         $result.Out -match 'ENTRY-LAST:two words') ($result.Err + $result.Out)

    $exitProgram = Join-Path $Work 'exit-seven.tcl'
    Write-Utf8 $exitProgram "package require machteld`nexit 7`n"
    $result = Invoke-Host @($exitProgram)
    Check 'direct opted-in exit status survives process cleanup' `
        ($result.Exit -eq 7) ($result.Err + $result.Out)

    # A hard host termination bypasses Tcl exit handlers. Every supervised
    # launch must still die with the host, including a descendant that outlived
    # its direct parent, while an explicit detach remains outside those jobs.
    $crashChildPid = Join-Path $Work 'crash-child.pid'
    $crashDescendantPid = Join-Path $Work 'crash-descendant.pid'
    $crashDetachResult = Join-Path $Work 'crash-detach.result'
    $crashDetachedMarker = Join-Path $Work 'crash-detached.marker'
    $crashReady = Join-Path $Work 'crash.ready'
    $crashProgram = Join-Path $Work 'crash-cleanup.tcl'
    $crashTemplate = @'
package require machteld
child start -env [list MACHTELD_TEST_PIDFILE {@@CHILD_PID@@}] -- {@@FIXTURE@@} hang 30000
child start -- {@@FIXTURE@@} descendant-parent 30000 {@@DESCENDANT_PID@@}
set deadline [expr {[clock milliseconds] + 5000}]
while {[clock milliseconds] < $deadline &&
       (![file exists {@@CHILD_PID@@}] || ![file exists {@@DESCENDANT_PID@@}])} {
    after 10
}
if {[catch {
    detach -- {@@FIXTURE@@} daemon-marker {@@DETACHED_MARKER@@} 1800
} detached options]} {
    set detachResult "denied:[dict get $options -errorcode]"
} else {
    set detachResult "ok:$detached"
}
set channel [open {@@DETACH_RESULT@@} w]
puts $channel $detachResult
close $channel
set channel [open {@@READY@@} w]
puts $channel ready
close $channel
vwait ::machteld_crash_fixture_forever
'@
    $crashScript = $crashTemplate.Replace('@@FIXTURE@@', $ProcessFixture.Replace('\', '/'))
    $crashScript = $crashScript.Replace('@@CHILD_PID@@', $crashChildPid.Replace('\', '/'))
    $crashScript = $crashScript.Replace('@@DESCENDANT_PID@@', $crashDescendantPid.Replace('\', '/'))
    $crashScript = $crashScript.Replace('@@DETACH_RESULT@@', $crashDetachResult.Replace('\', '/'))
    $crashScript = $crashScript.Replace('@@DETACHED_MARKER@@', $crashDetachedMarker.Replace('\', '/'))
    $crashScript = $crashScript.Replace('@@READY@@', $crashReady.Replace('\', '/'))
    Write-Utf8 $crashProgram $crashScript
    $crashStdout = Join-Path $Work 'crash-host-stdout.txt'
    $crashStderr = Join-Path $Work 'crash-host-stderr.txt'
    $crashArgument = ConvertTo-NativeArgument $crashProgram
    $crashHost = Start-Process -FilePath $Machteld -ArgumentList $crashArgument -PassThru `
        -RedirectStandardOutput $crashStdout -RedirectStandardError $crashStderr -WindowStyle Hidden
    $childProcessId = $null
    $descendantProcessId = $null
    $detachedProcessId = $null
    $detachSucceeded = $false
    $detachDenied = $false
    try {
        $crashStarted = Wait-ForFile $crashReady
        if ($crashStarted -and (Wait-ForFile $crashChildPid 1000) -and
            (Wait-ForFile $crashDescendantPid 1000) -and (Wait-ForFile $crashDetachResult 1000)) {
            $childProcessId = [int][IO.File]::ReadAllText($crashChildPid)
            $descendantProcessId = [int][IO.File]::ReadAllText($crashDescendantPid)
        } else {
            $crashStarted = $false
        }
        Check 'host-crash cleanup fixture starts its supervised processes' $crashStarted `
            ((Get-Content $crashStderr -Raw -ErrorAction SilentlyContinue) +
             (Get-Content $crashStdout -Raw -ErrorAction SilentlyContinue))
        if ($crashStarted) {
            $detachResult = [IO.File]::ReadAllText($crashDetachResult).Trim()
            $detachSucceeded = $detachResult -match '^ok:([0-9]+)$'
            if ($detachSucceeded) { $detachedProcessId = [int]$Matches[1] }
            $detachDenied = $detachResult -eq 'denied:MACHTELD DETACH launch'
            Check 'crash fixture detach either escapes or reports exact strict denial' `
                ($detachSucceeded -or $detachDenied) $detachResult
            Check 'supervised child is alive before host termination' `
                ($null -ne (Get-Process -Id $childProcessId -ErrorAction SilentlyContinue))
            Check 'supervised descendant is alive before host termination' `
                ($null -ne (Get-Process -Id $descendantProcessId -ErrorAction SilentlyContinue))
            if ($detachSucceeded) {
                Check 'detached work is still pending before host termination' `
                    (-not (Test-Path -LiteralPath $crashDetachedMarker) -and
                     $null -ne (Get-Process -Id $detachedProcessId -ErrorAction SilentlyContinue))
            }
        }
        Stop-Process -Id $crashHost.Id -Force -ErrorAction SilentlyContinue
        $crashHost.WaitForExit()
        if ($crashStarted) {
            Check 'forced host termination kills its supervised child' `
                (Wait-ForProcessGone $childProcessId)
            Check 'forced host termination kills the supervised descendant tree' `
                (Wait-ForProcessGone $descendantProcessId)
            if ($detachSucceeded) {
                $detachedCompleted = Wait-ForFile $crashDetachedMarker 5000
                $detachedMarkerPid = if ($detachedCompleted) {
                    [int][IO.File]::ReadAllText($crashDetachedMarker)
                } else { -1 }
                Check 'detached work survives forced host termination' `
                    ($detachedCompleted -and $detachedMarkerPid -eq $detachedProcessId)
            } elseif ($detachDenied) {
                Start-Sleep -Milliseconds 2200
                Check 'strictly denied detach never runs user code' `
                    (-not (Test-Path -LiteralPath $crashDetachedMarker))
            }
        }
    } finally {
        if (-not $crashHost.HasExited) { Stop-Process -Id $crashHost.Id -Force -ErrorAction SilentlyContinue }
        foreach ($processId in @($childProcessId, $descendantProcessId, $detachedProcessId)) {
            if ($null -ne $processId) {
                $candidate = Get-Process -Id $processId -ErrorAction SilentlyContinue
                $candidatePath = try { $candidate.MainModule.FileName } catch { $null }
                if ($null -ne $candidatePath -and
                    [IO.Path]::GetFullPath($candidatePath).Equals(
                        $ProcessFixture, [StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -InputObject $candidate -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    $bomProgram = Join-Path $Work 'bom-crlf.tcl'
    $bomBytes = [Collections.Generic.List[byte]]::new()
    $bomBytes.AddRange([byte[]](0xEF, 0xBB, 0xBF))
    $bomBytes.AddRange([Text.Encoding]::UTF8.GetBytes(
        "package require machteld`r`nputs ENTRY-BOM-OK`r`n"))
    [IO.File]::WriteAllBytes($bomProgram, $bomBytes.ToArray())
    $result = Invoke-Host @($bomProgram)
    Check 'captured startup accepts a UTF-8 BOM and CRLF' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-BOM-OK') ($result.Err + $result.Out)

    $returnProgram = Join-Path $Work 'top-level-return.tcl'
    Write-Utf8 $returnProgram "package require machteld`nputs ENTRY-RETURN-OK`nreturn`nputs SHOULD-NOT-RUN`n"
    $result = Invoke-Host @($returnProgram)
    Check 'captured startup gives top-level return normal sourced-file semantics' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-RETURN-OK' -and
         $result.Out -notmatch 'SHOULD-NOT-RUN') ($result.Err + $result.Out)

    $ctrlZProgram = Join-Path $Work 'control-z.tcl'
    $ctrlZBytes = [Collections.Generic.List[byte]]::new()
    $ctrlZBytes.AddRange([Text.Encoding]::UTF8.GetBytes(
        "package require machteld`nputs ENTRY-CTRLZ-OK`n"))
    $ctrlZBytes.Add(0x1A)
    $ctrlZBytes.AddRange([Text.Encoding]::UTF8.GetBytes("puts SHOULD-NOT-RUN-AFTER-EOF`n"))
    [IO.File]::WriteAllBytes($ctrlZProgram, $ctrlZBytes.ToArray())
    $result = Invoke-Host @($ctrlZProgram)
    Check 'captured startup ignores the DOS end-of-file tail' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-CTRLZ-OK' -and
         $result.Out -notmatch 'SHOULD-NOT-RUN-AFTER-EOF') ($result.Err + $result.Out)

    $movable = Join-Path $Work 'movable'
    $moved = Join-Path $Work 'movable-after-start'
    New-Item -ItemType Directory -Path $movable | Out-Null
    $moveProgram = Join-Path $movable 'main.tcl'
    $movedTcl = $moved.Replace('\', '/')
    Write-Utf8 $moveProgram "package require machteld`nfile rename [file dirname [info script]] {$movedTcl}`nputs ENTRY-RENAME-OK`n"
    $result = Invoke-Host @($moveProgram)
    Check 'direct entry does not retain locks on its file or parent tree' `
        ($result.Exit -eq 0 -and $result.Out -match 'ENTRY-RENAME-OK' -and
         (Test-Path -LiteralPath (Join-Path $moved 'main.tcl') -PathType Leaf)) `
        ($result.Err + $result.Out)

    # Loading Tk installs a main loop that starts after the selected program
    # has completed. Its first callback must not inherit the program's temporary
    # `info script` context.
    $postStartMarker = Join-Path $Work 'post-start-info-script.txt'
    $postStartMarkerTcl = $postStartMarker.Replace('\', '/')
    $postStartProgram = Join-Path $Work 'post-start.tcl'
    Write-Utf8 $postStartProgram @"
package require machteld
package require Tk
wm withdraw .
proc entry_post_start {} {
    set channel [open {$postStartMarkerTcl} w]
    puts -nonewline `$channel [info script]
    close `$channel
    destroy .
}
after 0 entry_post_start
"@
    $result = Invoke-Host @($postStartProgram)
    $postStartContext = if (Test-Path -LiteralPath $postStartMarker -PathType Leaf) {
        [IO.File]::ReadAllText($postStartMarker)
    } else { $null }
    Check 'post-start callbacks see an empty info script context' `
        ($result.Exit -eq 0 -and $null -ne $postStartContext -and
         $postStartContext.Length -eq 0) ($result.Err + $result.Out)

    $literalWrap = Join-Path $Work 'wrap'
    Write-Utf8 $literalWrap "package require machteld`nputs ENTRY-LITERAL-WRAP`n"
    $wrapStdout = Join-Path $Work 'literal-wrap-stdout.txt'
    $wrapStderr = Join-Path $Work 'literal-wrap-stderr.txt'
    $wrapProcess = Start-Process -FilePath $Machteld -ArgumentList @('wrap') `
        -WorkingDirectory $Work -Wait -PassThru -RedirectStandardOutput $wrapStdout `
        -RedirectStandardError $wrapStderr -WindowStyle Hidden
    $wrapText = (Get-Content -LiteralPath $wrapStdout -Raw -ErrorAction SilentlyContinue) +
                (Get-Content -LiteralPath $wrapStderr -Raw -ErrorAction SilentlyContinue)
    Check 'an existing startup file literally named wrap wins over host convenience dispatch' `
        ($wrapProcess.ExitCode -eq 0 -and $wrapText -match 'ENTRY-LITERAL-WRAP') $wrapText

    $notFound = Join-Path $Work 'does-not-exist.tcl'
    $result = Invoke-Host @($notFound)
    Check 'direct invocation reports a missing startup with status one' `
        ($result.Exit -eq 1 -and ($result.Err + $result.Out).Length -gt 0) `
        ($result.Err + $result.Out)

    $missing = Join-Path $Work 'missing-opt-in.tcl'
    Write-Utf8 $missing "puts SHOULD-NOT-RUN`n"
    $result = Invoke-Host @($missing)
    Check 'direct invocation refuses a program without opt-in' `
        ($result.Exit -eq 1 -and ($result.Err + $result.Out) -match 'package require machteld') $result.Err

    $substituted = Join-Path $Work 'substituted.tcl'
    Write-Utf8 $substituted "set p machteld`npackage require `$p`nputs SHOULD-NOT-RUN`n"
    $result = Invoke-Host @($substituted)
    Check 'direct invocation refuses substituted opt-in' `
        ($result.Exit -eq 1 -and ($result.Err + $result.Out) -match 'package require machteld') $result.Err

    $encodingMarker = Join-Path $Work 'encoding-ran.txt'
    $encodingProgram = Join-Path $Work 'encoding-program.tcl'
    $encodingMarkerTcl = $encodingMarker.Replace('\', '/')
    Write-Utf8 $encodingProgram "package require machteld`nset f [open {$encodingMarkerTcl} w]`nputs `$f ran`nclose `$f`n"
    $result = Invoke-Host @('-encoding', 'utf-8', $encodingProgram)
    Check 'direct invocation rejects Tcl_Main -encoding before entry eval' `
        ($result.Exit -eq 1 -and -not (Test-Path -LiteralPath $encodingMarker)) ($result.Err + $result.Out)

    $hostileTcl = Join-Path $Work 'hostile-tcl'
    $hostileTk = Join-Path $Work 'hostile-tk'
    New-Item -ItemType Directory -Force -Path $hostileTcl, $hostileTk | Out-Null
    $tclPoison = Join-Path $Work 'tcl-poison-ran.txt'
    $tkPoison = Join-Path $Work 'tk-poison-ran.txt'
    Write-Utf8 (Join-Path $hostileTcl 'init.tcl') `
        "set f [open {$($tclPoison.Replace('\', '/'))} w]`nputs `$f poisoned`nclose `$f`n"
    Write-Utf8 (Join-Path $hostileTk 'tk.tcl') `
        "set f [open {$($tkPoison.Replace('\', '/'))} w]`nputs `$f poisoned`nclose `$f`n"
    $libraryProgram = Join-Path $Work 'library-program.tcl'
    Write-Utf8 $libraryProgram @'
package require machteld
puts "TCL-LIB:$::tcl_library"
puts "TK-LIB:$::tk_library"
'@
    $priorTclLibrary = [Environment]::GetEnvironmentVariable('TCL_LIBRARY', 'Process')
    $priorTkLibrary = [Environment]::GetEnvironmentVariable('TK_LIBRARY', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('TCL_LIBRARY', $hostileTcl, 'Process')
        [Environment]::SetEnvironmentVariable('TK_LIBRARY', $hostileTk, 'Process')
        $result = Invoke-Host @($libraryProgram)
    } finally {
        [Environment]::SetEnvironmentVariable('TCL_LIBRARY', $priorTclLibrary, 'Process')
        [Environment]::SetEnvironmentVariable('TK_LIBRARY', $priorTkLibrary, 'Process')
    }
    Check 'host ignores hostile TCL_LIBRARY and pins embedded Tcl scripts' `
        ($result.Exit -eq 0 -and $result.Out -match 'TCL-LIB://zipfs:/app/tcl_library' -and
         -not (Test-Path -LiteralPath $tclPoison)) ($result.Err + $result.Out)
    Check 'host ignores hostile TK_LIBRARY and pins embedded Tk scripts' `
        ($result.Exit -eq 0 -and $result.Out -match 'TK-LIB://zipfs:/app/tk_library' -and
         -not (Test-Path -LiteralPath $tkPoison)) ($result.Err + $result.Out)

    $stdin = Join-Path $Work 'stdin.txt'
    Write-Utf8 $stdin "puts SHOULD-NOT-RUN`n"
    $stdout = Join-Path $Work 'stdin-stdout.txt'
    $stderr = Join-Path $Work 'stdin-stderr.txt'
    $process = Start-Process -FilePath $Machteld -ArgumentList @('-') -Wait -PassThru `
        -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
    Check 'stdin programs are refused with status one' ($process.ExitCode -eq 1) `
        (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)

    $stdinMarker = Join-Path $Work 'stdin-ran.txt'
    Write-Utf8 $stdin "set f [open {$($stdinMarker.Replace('\', '/'))} w]`nputs `$f ran`nclose `$f`n"
    $stdout = Join-Path $Work 'stdin-noarg-stdout.txt'
    $stderr = Join-Path $Work 'stdin-noarg-stderr.txt'
    $process = Start-Process -FilePath $Machteld -Wait -PassThru `
        -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
    Check 'redirected stdin without a startup file exits without eval' `
        ($process.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $stdinMarker)) `
        ((Get-Content $stderr -Raw -ErrorAction SilentlyContinue) +
         (Get-Content $stdout -Raw -ErrorAction SilentlyContinue))

    $help = Invoke-Host @('--help')
    Check '--help is a host mode' ($help.Exit -eq 0 -and $help.Out.Length -gt 0) $help.Err
    Check '--help identifies the complete Machteld, Tcl, and Tk reference' `
        ($help.Out -match '(?i)complete offline reference' -and
         $help.Out -match ("Machteld " + $MachteldVersionRe) -and
         $help.Out -match 'Tcl 9\.0\.4' -and $help.Out -match 'Tk 9\.0\.4' -and
         $help.Out -match '(?i)--docs' -and $help.Out -match '(?i)search') `
        ($help.Err + $help.Out)
    $version = Invoke-Host @('--version')
    Check '--version is a host mode' ($version.Exit -eq 0 -and $version.Out -match $MachteldVersionRe) $version.Err

    $docsStatus = Invoke-Host @('--docs', 'status', '--json')
    $statusObject = $null
    if ($docsStatus.Exit -eq 0) {
        try { $statusObject = $docsStatus.Out | ConvertFrom-Json } catch {}
    }
    Check '--docs exposes a machine-readable host route' `
        ($docsStatus.Exit -eq 0 -and $null -ne $statusObject -and
         $statusObject.ok -eq 1 -and $null -ne $statusObject.result) `
        ($docsStatus.Err + $docsStatus.Out)
    Check 'embedded reference status names exact runtime versions' `
        ($null -ne $statusObject -and $statusObject.ok -eq 1 -and
         $docsStatus.Out -match $MachteldVersionRe -and
         $docsStatus.Out -match '9\.0\.4' -and $docsStatus.Out -match '(?i)sha256') `
        ($docsStatus.Err + $docsStatus.Out)

    $docsBootstrap = Invoke-Host @('--docs')
    Check '--docs with no operation returns the agent documentation bootstrap' `
        ($docsBootstrap.Exit -eq 0 -and
         $docsBootstrap.Out -match '(?m)^# Agent documentation bootstrap' -and
         $docsBootstrap.Out -match '(?i)complete, exact-version offline references' -and
         $docsBootstrap.Out -match 'Tcl 9\.0\.4' -and $docsBootstrap.Out -match 'Tk 9\.0\.4' -and
         $docsBootstrap.Out -match 'docs status' -and $docsBootstrap.Out -match 'docs get' -and
         $docsBootstrap.Out -match 'docs search' -and $docsBootstrap.Out -match 'docs extract') `
        ($docsBootstrap.Err + $docsBootstrap.Out)

    $docsStatusFile = Join-Path $Work 'reference-status.json'
    $docsOutput = Invoke-Host @('--docs', 'status', '--json', '--output', $docsStatusFile)
    $outputObject = $null
    if ($docsOutput.Exit -eq 0 -and (Test-Path -LiteralPath $docsStatusFile -PathType Leaf)) {
        try { $outputObject = Get-Content -LiteralPath $docsStatusFile -Raw | ConvertFrom-Json } catch {}
    }
    Check '--docs writes its JSON envelope to an explicit output file' `
        ($docsOutput.Exit -eq 0 -and $null -ne $outputObject -and
         $outputObject.ok -eq 1 -and $null -ne $outputObject.result) `
        ($docsOutput.Err + $docsOutput.Out)

    $docsGet = Invoke-Host @('docs', 'get', 'tcl/command/dict',
        '--section', 'synopsis', '--limit', '4096', '--json')
    $getObject = $null
    if ($docsGet.Exit -eq 0) {
        try { $getObject = $docsGet.Out | ConvertFrom-Json } catch {}
    }
    Check 'docs convenience route retrieves a bounded Tcl reference section' `
        ($docsGet.Exit -eq 0 -and $null -ne $getObject -and
         $getObject.ok -eq 1 -and $null -ne $getObject.result -and
         $docsGet.Out -match 'tcl/command/dict' -and $docsGet.Out -match '(?i)synopsis') `
        ($docsGet.Err + $docsGet.Out)

    $routeDirectory = Join-Path $Work 'route-directory-shadow'
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $routeDirectory 'docs'), (Join-Path $routeDirectory 'wrap') | Out-Null
    $directoryDocs = Invoke-Host -Arguments @('docs', 'status', '--json') `
        -WorkingDirectory $routeDirectory
    $directoryObject = $null
    if ($directoryDocs.Exit -eq 0) {
        try { $directoryObject = $directoryDocs.Out | ConvertFrom-Json } catch {}
    }
    Check 'a same-name directory does not hide the docs convenience route' `
        ($directoryDocs.Exit -eq 0 -and $null -ne $directoryObject -and
         $directoryObject.ok -eq 1 -and $null -ne $directoryObject.result) `
        ($directoryDocs.Err + $directoryDocs.Out)

    $directoryWrap = Invoke-Host -Arguments @('wrap') -WorkingDirectory $routeDirectory
    Check 'a same-name directory does not hide the wrap convenience route' `
        ($directoryWrap.Exit -eq 1 -and
         ($directoryWrap.Err + $directoryWrap.Out) -match '(?i)wrap' -and
         ($directoryWrap.Err + $directoryWrap.Out) -notmatch '(?i)regular file|startup program') `
        ($directoryWrap.Err + $directoryWrap.Out)

    $docsUnknown = Invoke-Host @('--docs', 'get', 'no-such-product/no-such-page', '--json')
    $unknownObject = $null
    try { $unknownObject = ($docsUnknown.Err + $docsUnknown.Out) | ConvertFrom-Json } catch {}
    Check 'docs host route fails closed for an unknown page' `
        ($docsUnknown.Exit -eq 1 -and $null -ne $unknownObject -and
         $unknownObject.ok -eq 0 -and
         ($docsUnknown.Err + $docsUnknown.Out) -match '(?i)not found|notfound') `
        ($docsUnknown.Err + $docsUnknown.Out)

    $docsProgram = Join-Path $Work 'docs'
    Write-Utf8 $docsProgram "package require machteld`nputs REAL-DOCS-PROGRAM`n"
    $realDocs = Invoke-Host -Arguments @('docs') -WorkingDirectory $Work
    Check 'a real opted-in file named docs wins over the convenience route' `
        ($realDocs.Exit -eq 0 -and $realDocs.Out -match 'REAL-DOCS-PROGRAM') `
        ($realDocs.Err + $realDocs.Out)
    $reservedDocs = Invoke-Host -Arguments @('--docs', 'status', '--json') `
        -WorkingDirectory $Work
    $reservedObject = $null
    if ($reservedDocs.Exit -eq 0) {
        try { $reservedObject = $reservedDocs.Out | ConvertFrom-Json } catch {}
    }
    Check 'the reserved --docs route wins even beside a real file named docs' `
        ($reservedDocs.Exit -eq 0 -and $null -ne $reservedObject -and
         $reservedObject.ok -eq 1 -and $null -ne $reservedObject.result -and
         $reservedDocs.Out -notmatch 'REAL-DOCS-PROGRAM') `
        ($reservedDocs.Err + $reservedDocs.Out)

    if ($Bare) {
        $Bare = [IO.Path]::GetFullPath($Bare)
        $stdout = Join-Path $Work 'bare-stdout.txt'
        $stderr = Join-Path $Work 'bare-stderr.txt'
        $process = Start-Process -FilePath $Bare -ArgumentList @('--version') -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
        $text = (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) +
                (Get-Content $stdout -Raw -ErrorAction SilentlyContinue)
        Check 'bare host refuses to run without its packaged payload' `
            ($process.ExitCode -eq 1 -and $text -match 'payload') $text
    }
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Failures) { throw "$Failures entry test(s) failed" }
Write-Host 'ALL ENTRY TESTS PASSED'
