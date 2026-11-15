#Requires -Version 5.1
<#
.SYNOPSIS
    Module 16 - Tears the whole lab down: VMs, disks, switches, NAT, and (optionally) the golden images.
.DESCRIPTION
    Only touches objects the lab created: VMs whose Notes start with "HVLAB", switches named HVLAB-*,
    the NAT named in LabConfig, and folders under LabRoot. Prompts before deleting unless -Force.
.PARAMETER KeepImages
    Keep <LabRoot>\Images so the next build skips script 03 (saves ~20 minutes).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([switch]$KeepImages, [switch]$Force)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
if ($Force) { $ConfirmPreference = 'None' }

$vms = Get-VM | Where-Object { $_.Notes -like 'HVLAB*' }
Write-LabLog "Lab VMs found: $(($vms.Name) -join ', ')"
if (-not $PSCmdlet.ShouldProcess("$($vms.Count) VMs, HVLAB switches, NAT and $($cfg.LabRoot)", 'Permanently delete')) { return }

foreach ($vm in $vms) {
    if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
    Get-VMCheckpoint -VM $vm | Remove-VMCheckpoint -ErrorAction SilentlyContinue
    $disks = (Get-VMHardDiskDrive -VM $vm).Path
    Remove-VM -VM $vm -Force
    foreach ($d in $disks) { if ($d -and (Test-Path $d)) { Remove-Item $d -Force } }
    Write-LabLog "Removed VM $($vm.Name)" -Level Ok
}

Get-NetNat -Name $cfg.Network.Mgmt.NatName -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false
Get-VMSwitch | Where-Object Name -like 'HVLAB-*' | Remove-VMSwitch -Force
Write-LabLog 'Removed lab switches and NAT' -Level Ok

foreach ($sub in 'VMs', 'Disks', 'Unattend', 'Exports', 'Templates') {
    $p = Join-Path $cfg.LabRoot $sub
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}
if (-not $KeepImages) {
    $img = Join-Path $cfg.LabRoot 'Images'
    Get-ChildItem $img -Filter *.vhdx -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
    if (Test-Path $img) { Remove-Item $img -Recurse -Force }
}
Write-LabLog 'Lab removed. Logs kept in Logs\. Remove LabRoot manually if you are done for good.' -Level Ok
