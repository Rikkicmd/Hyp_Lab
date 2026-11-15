#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the build scripts in order. Use it for a hands-off build, or run the numbered scripts one at a time
    while following the modules (recommended the first time, so you learn what each step does).
.PARAMETER From / To
    Stage numbers to run (inclusive). Default 0..11 = the full core lab with iSCSI cluster and Replica.
.PARAMETER WithOSWorkloads
    Passes -WithOS to stage 10 (real Windows guests inside the cluster, needs ~2 GB more RAM on each node).
.EXAMPLE
    .\Deploy-Lab.ps1                    # full core build
    .\Deploy-Lab.ps1 -From 5 -To 9      # resume after a failure in stage 5
    .\Deploy-Lab.ps1 -From 13 -To 13    # management tools only
#>
[CmdletBinding()]
param([int]$From = 0, [int]$To = 11, [switch]$WithOSWorkloads)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin

$stages = [ordered]@{
    0  = @{ Script = '00-Test-HostReadiness.ps1';        Args = @{} }
    1  = @{ Script = '01-Install-HostPrereqs.ps1';       Args = @{} }
    2  = @{ Script = '02-New-LabNetwork.ps1';            Args = @{} }
    3  = @{ Script = '03-New-GoldenImage.ps1';           Args = @{} }
    4  = @{ Script = '04-New-LabVMs.ps1';                Args = @{} }
    5  = @{ Script = '05-Initialize-DomainController.ps1'; Args = @{} }
    6  = @{ Script = '06-Join-LabDomain.ps1';            Args = @{} }
    7  = @{ Script = '07-Install-NestedHyperV.ps1';      Args = @{} }
    8  = @{ Script = '08-New-IscsiStorage.ps1';          Args = @{} }
    9  = @{ Script = '09-New-LabCluster.ps1';            Args = @{} }
    10 = @{ Script = '10-New-ClusterWorkloads.ps1';      Args = @{ WithOS = [bool]$WithOSWorkloads } }
    11 = @{ Script = '11-Enable-HyperVReplica.ps1';      Args = @{} }
    12 = @{ Script = '12-New-S2DCluster.ps1';            Args = @{ ReplaceIscsiCluster = $true } }
    13 = @{ Script = '13-Install-ManagementTools.ps1';   Args = @{} }
    14 = @{ Script = '14-New-HostGuardian.ps1';          Args = @{} }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($k in $stages.Keys) {
    if ($k -lt $From -or $k -gt $To) { continue }
    $s = $stages[$k]
    if ($k -eq 14 -and -not (Get-VM -Name HGS01 -ErrorAction SilentlyContinue)) {
        & "$PSScriptRoot\04-New-LabVMs.ps1" -IncludeOptional -Name HGS01
    }
    Write-LabLog "===== Stage $k : $($s.Script) =====" -Level Step
    $a = $s.Args
    & (Join-Path $PSScriptRoot $s.Script) @a
    if ($k -eq 1 -and -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        Write-LabLog "Host is rebooting to finish Hyper-V. Afterwards run: .\Deploy-Lab.ps1 -From 1 -To $To" -Level Warn
        return
    }
    if ($k -eq 0) {
        Write-LabLog 'Review the readiness table above. Continuing in 10 seconds (Ctrl+C to stop)...'
        Start-Sleep 10
    }
    if ($k -eq 6)  { Write-LabLog 'Tip: .\Invoke-LabCheckpoint.ps1 -Action Save -Name Baseline-Domain' }
    if ($k -eq 10) { Write-LabLog 'Tip: .\Invoke-LabCheckpoint.ps1 -Action Save -Name Baseline-Cluster' }
}
Write-LabLog ("Stages $From-$To finished in {0:hh\:mm\:ss}. Validate with ..\validation\Test-LabModule.ps1 -All" -f $sw.Elapsed) -Level Ok
