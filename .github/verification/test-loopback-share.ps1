# Run on the ephemeral Windows worker from the tested candidate's checkout.
$ErrorActionPreference = 'Stop'
$shareName = 'MachteldTest_{0}_{1}$' -f $env:GITHUB_RUN_ID, $env:GITHUB_RUN_ATTEMPT
$directory = Join-Path $env:RUNNER_TEMP ('machteld-share-' + [guid]::NewGuid().ToString('N'))
$unc = '\\localhost\' + $shareName
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$shareCreated = $false

New-Item -Path $directory -ItemType Directory | Out-Null
try {
    $acl = Get-Acl -LiteralPath $directory
    $access = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.SetAccessRule($access)
    Set-Acl -LiteralPath $directory -AclObject $acl
    foreach ($service in 'LanmanWorkstation', 'LanmanServer') {
        if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    }
    New-SmbShare -Name $shareName -Path $directory -FullAccess $identity -CachingMode None | Out-Null
    $shareCreated = $true

    # Open and write through the UNC redirector, then verify the local backing file.
    $marker = 'loopback-probe.txt'
    [IO.File]::WriteAllText((Join-Path $unc $marker), $shareName)
    if ([IO.File]::ReadAllText((Join-Path $directory $marker)) -cne $shareName) {
        throw "Loopback SMB write did not reach the new share's backing directory"
    }
    Get-SmbConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.ShareName -eq $shareName } |
        Select-Object ServerName, ShareName, Dialect | Format-Table | Out-Host
    Remove-Item -LiteralPath (Join-Path $unc $marker)

    $publication = Join-Path $unc 'shared archives 雪'
    New-Item -Path $publication -ItemType Directory | Out-Null
    Write-Host "Testing publication and child launches through $publication"
    & .\out\machteld.exe test/app_launch_test.tcl $publication
    if ($LASTEXITCODE -ne 0) { throw "UNC generation test exited with $LASTEXITCODE" }
} finally {
    if ($shareCreated) { Remove-SmbShare -Name $shareName -Force -Confirm:$false }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
