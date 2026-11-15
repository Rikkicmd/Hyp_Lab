#Requires -Version 5.1
<#
.SYNOPSIS
    Module 01 - Installs Hyper-V and management tools on the physical host and applies lab defaults.
.DESCRIPTION
    - Installs Hyper-V role + PowerShell module + Hyper-V Manager (Server) or Microsoft-Hyper-V-All (client)
    - Installs Failover Clustering / RSAT tools so the host can manage the nested cluster
    - Creates the lab folder structure
    - Sets host defaults: VM/VHD paths, Enhanced Session Mode, NUMA spanning
    Reboots when the role is first installed. Re-run after reboot; it is idempotent.
#>
[CmdletBinding()]
param([switch]$NoRestart)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1

# Folder layout
$folders = 'VMs', 'Disks', 'Images', 'Logs', 'Unattend', 'Exports', 'Templates'
foreach ($f in $folders) {
    $p = Join-Path $cfg.LabRoot $f
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null; Write-LabLog "Created $p" }
}

$restart = $false
if ($isServer) {
    $features = 'Hyper-V', 'Hyper-V-PowerShell', 'Hyper-V-Tools', 'RSAT-Clustering-PowerShell', 'RSAT-Clustering-Mgmt',
                'RSAT-AD-PowerShell', 'RSAT-DNS-Server', 'RSAT-DHCP'
    $missing = Get-WindowsFeature -Name $features | Where-Object InstallState -ne 'Installed'
    if ($missing) {
        Write-LabLog "Installing: $($missing.Name -join ', ')" -Level Step
        $r = Install-WindowsFeature -Name $missing.Name -IncludeManagementTools
        if ($r.RestartNeeded -eq 'Yes') { $restart = $true }
    }
} else {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State
    if ($state -ne 'Enabled') {
        Write-LabLog 'Enabling Microsoft-Hyper-V-All (client OS)' -Level Step
        $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
        if ($r.RestartNeeded) { $restart = $true }
    }
    Write-LabLog 'Client OS: install RSAT (Settings > Optional features) for cluster/AD tools.' -Level Warn
}

if ($restart) {
    Write-LabLog 'Hyper-V installed. A reboot is required; re-run this script afterwards to finish host defaults.' -Level Warn
    if (-not $NoRestart) { Restart-Computer -Force }
    return
}

# Host defaults (only possible once the hypervisor is running)
Write-LabLog 'Applying Hyper-V host defaults' -Level Step
Set-VMHost -VirtualMachinePath (Join-Path $cfg.LabRoot 'VMs') `
           -VirtualHardDiskPath (Join-Path $cfg.LabRoot 'Disks') `
           -EnableEnhancedSessionMode $true `
           -NumaSpanningEnabled $true

# Make sure the Hyper-V services are running
Get-Service vmms, vmcompute -ErrorAction SilentlyContinue | Where-Object Status -ne 'Running' | Start-Service

# Exclude lab paths from Defender real-time scanning: Microsoft's documented recommendation for Hyper-V hosts
if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
    Add-MpPreference -ExclusionPath $cfg.LabRoot -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionExtension 'vhd', 'vhdx', 'avhd', 'avhdx', 'vsv', 'iso', 'rct', 'mrt', 'vmcx', 'vmrs', 'vmgs' -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess 'vmms.exe', 'vmwp.exe', 'vmcompute.exe' -ErrorAction SilentlyContinue
    Write-LabLog 'Added Defender exclusions for Hyper-V files and processes.'
}

Get-VMHost | Format-List ComputerName, LogicalProcessorCount, MemoryCapacity, VirtualMachinePath, VirtualHardDiskPath, EnableEnhancedSessionMode, NumaSpanningEnabled
Write-LabLog 'Host prerequisites complete. Next: 02-New-LabNetwork.ps1' -Level Ok
