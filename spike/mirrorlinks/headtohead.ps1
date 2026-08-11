# The link-count probe, C against Tcl, INTERLEAVED.
#
# Sequential blocks were useless here: the Tcl arm measured 54.7 us/file in one
# run and 86.0 us/file in the next, a 57% drift, which is larger than the
# difference between any two arms. Interleaving each round and reporting the
# MEDIAN is the only design that survives that -- whatever the machine is doing
# is then shared by every arm in the same round rather than landing on one.
#
#   powershell -File headtohead.ps1 <listfile> [rounds]

param([string]$List, [int]$Rounds = 7)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mt   = "C:\dev\_machteld\build\machteld.exe"
$arms = @(
    @{ name = "C  access=0 +reparse "; run = { & "$here\hazard.exe" $List list 1 none } },
    @{ name = "C  access=GENERIC_READ"; run = { & "$here\hazard.exe" $List list 1 read noreparse } },
    @{ name = "Tcl file stat        "; run = { & $mt tcl "$here\arm_stat_tcl.tcl" $List 1 } }
)
$acc = @{}
foreach ($a in $arms) { $acc[$a.name] = @() }

for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($a in $arms) {
        $out = & $a.run
        # every arm prints "... : <ms> ms  <us> us/file ..."
        if ($out -join " " -match '([0-9]+\.[0-9]+)\s+us/file') {
            $acc[$a.name] += [double]$Matches[1]
        }
    }
    Write-Output ("round $r done")
}

Write-Output ""
Write-Output "us/file over $Rounds interleaved rounds:"
foreach ($a in $arms) {
    $v = $acc[$a.name] | Sort-Object
    if ($v.Count -eq 0) { Write-Output ("  {0} : no samples" -f $a.name); continue }
    $med = $v[[int]([math]::Floor($v.Count / 2))]
    Write-Output ("  {0} : median {1,7:N1}   min {2,7:N1}   max {3,7:N1}   n={4}" -f `
        $a.name, $med, $v[0], $v[$v.Count - 1], $v.Count)
}
