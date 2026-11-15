#Requires -Version 5.1
<#
.SYNOPSIS
    Saves, restores, lists or removes a lab-wide checkpoint so you can reset after an exercise.
.DESCRIPTION
    Nested Hyper-V hosts do not support saved state / live checkpoints while they run VMs, so this script
    powers the lab down in order (Invoke-LabPower.ps1), takes STANDARD checkpoints of the powered-off VMs
    with the same name, and powers it back up. Restoring does the same in reverse.

    Recommended checkpoints:
      Baseline-Domain   after script 06
      Baseline-Cluster  after script 10
      Before-S2D        before script 12
.EXAMPLE
    .\Invoke-LabCheckpoint.ps1 -Action Save -Name Baseline-Cluster
    .\Invoke-LabCheckpoint.ps1 -Action Restore -Name Baseline-Cluster
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Save', 'Restore', 'List', 'Remove')][string]$Action,
    [string]$Name,
    [switch]$NoStart
)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$vms = Get-VM | Where-Object { $_.Notes -like 'HVLAB*' }

if ($Action -eq 'List') {
    Get-VMCheckpoint -VM $vms | Sort-Object CreationTime | Format-Table VMName, Name, CheckpointType, CreationTime -AutoSize
    return
}
if (-not $Name) { throw "-Name is required for $Action." }

switch ($Action) {
    'Save' {
        & "$PSScriptRoot\Invoke-LabPower.ps1" -State Off
        foreach ($vm in $vms) {
            Set-VM -VM $vm -CheckpointType Standard
            Checkpoint-VM -VM $vm -SnapshotName $Name
            Set-VM -VM $vm -CheckpointType Production
            Write-LabLog "Checkpoint '$Name' taken for $($vm.Name)" -Level Ok
        }
    }
    'Restore' {
        if (-not $PSCmdlet.ShouldProcess('all lab VMs', "Restore checkpoint $Name (current state is lost)")) { return }
        & "$PSScriptRoot\Invoke-LabPower.ps1" -State Off
        foreach ($vm in $vms) {
            $cp = Get-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
            if ($cp) { Restore-VMCheckpoint -VMSnapshot $cp -Confirm:$false; Write-LabLog "Restored $($vm.Name) to '$Name'" -Level Ok }
            else { Write-LabLog "$($vm.Name) has no checkpoint '$Name' (VM created later?)" -Level Warn }
        }
    }
    'Remove' {
        foreach ($vm in $vms) { Get-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue | Remove-VMCheckpoint }
        Write-LabLog "Removed checkpoint '$Name'. The AVHDX files merge in the background (watch Get-VM | Select Name, Status)." -Level Ok
        return
    }
}
if (-not $NoStart) { & "$PSScriptRoot\Invoke-LabPower.ps1" -State On }
