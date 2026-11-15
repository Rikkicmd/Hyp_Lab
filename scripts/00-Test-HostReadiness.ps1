#Requires -Version 5.1
<#
.SYNOPSIS
    Module 01 - Checks that the physical host can run the full lab.
.DESCRIPTION
    Read-only. Checks OS, CPU virtualization + SLAT, RAM, disk, ISO, and
    whether Hyper-V is already installed. Prints a PASS/WARN/FAIL table.
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($Check, $Status, $Detail) { $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }) }

# OS
$os = Get-CimInstance Win32_OperatingSystem
$isServer = $os.ProductType -ne 1
Add-Result 'Operating system' ($(if ($os.BuildNumber -ge 26100) { 'PASS' } elseif ($os.BuildNumber -ge 17763) { 'WARN' } else { 'FAIL' })) "$($os.Caption) build $($os.BuildNumber)"
if (-not $isServer) { Add-Result 'Server SKU' 'WARN' 'Client Hyper-V works for most modules, but NAT/feature names differ and clustering of the HOST is not possible.' }

# CPU
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
Add-Result 'CPU cores' ($(if ($cores -ge 8) { 'PASS' } elseif ($cores -ge 4) { 'WARN' } else { 'FAIL' })) "$cores physical cores ($($cpu.Name.Trim()))"

$hvPresent = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if ($hvPresent) {
    Add-Result 'Virtualization/SLAT' 'PASS' 'A hypervisor is already running (Hyper-V enabled), so VT-x/AMD-V and SLAT are available.'
} else {
    $vtx  = $cpu.VirtualizationFirmwareEnabled
    $slat = $cpu.SecondLevelAddressTranslationExtensions
    Add-Result 'VT-x / AMD-V in firmware' ($(if ($vtx) { 'PASS' } else { 'FAIL' })) 'Enable Intel VT-x / AMD-V (SVM) in BIOS/UEFI if FAIL.'
    Add-Result 'SLAT (EPT/RVI)' ($(if ($slat) { 'PASS' } else { 'FAIL' })) 'Required by Hyper-V.'
}

# RAM
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$need = ($cfg.VMs | ForEach-Object { $_.MemStartup } | Measure-Object -Sum).Sum / 1GB
Add-Result 'Physical RAM' ($(if ($ramGB -ge ($need + 8)) { 'PASS' } elseif ($ramGB -ge $need) { 'WARN' } else { 'FAIL' })) "$ramGB GB installed; core lab startup memory = $need GB + ~8 GB host reserve"

# Disk
$drive = Split-Path -Qualifier $cfg.LabRoot
$vol = Get-Volume -DriveLetter $drive.TrimEnd(':') -ErrorAction SilentlyContinue
if ($vol) {
    $freeGB = [math]::Round($vol.SizeRemaining / 1GB)
    Add-Result "Free space on $drive" ($(if ($freeGB -ge 400) { 'PASS' } elseif ($freeGB -ge 250) { 'WARN' } else { 'FAIL' })) "$freeGB GB free (400 GB recommended, SSD/NVMe strongly recommended)"
    Add-Result "Filesystem on $drive" ($(if ($vol.FileSystem -in 'NTFS', 'ReFS') { 'PASS' } else { 'FAIL' })) $vol.FileSystem
} else {
    Add-Result "Lab drive $drive" 'FAIL' "Drive for LabRoot ($($cfg.LabRoot)) not found. Edit LabConfig.psd1."
}

# ISO
Add-Result 'Windows Server ISO' ($(if (Test-Path $cfg.IsoPath) { 'PASS' } else { 'FAIL' })) $cfg.IsoPath

# Hyper-V feature
$hvFeature = if ($isServer) { (Get-WindowsFeature -Name Hyper-V).InstallState } else { (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State }
Add-Result 'Hyper-V role' ($(if ("$hvFeature" -in 'Installed', 'Enabled') { 'PASS' } else { 'WARN' })) "State: $hvFeature (01-Install-HostPrereqs.ps1 installs it)"

# Pending reboot
$pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Add-Result 'Pending reboot' ($(if ($pending) { 'WARN' } else { 'PASS' })) $(if ($pending) { 'Reboot before continuing.' } else { 'None' })

$results | Format-Table -AutoSize
$fails = @($results | Where-Object Status -eq 'FAIL').Count
if ($fails) { Write-LabLog "$fails check(s) failed. Fix them before running 01-Install-HostPrereqs.ps1." -Level Error }
else { Write-LabLog 'Host is ready for the lab.' -Level Ok }
