#Requires -Version 5.1
<#
.SYNOPSIS
    Module 03 - Deploys every lab VM from the golden images using differencing disks and an injected unattend.xml.
.DESCRIPTION
    For each VM in LabConfig.psd1:
      1. Creates a differencing disk whose parent is the read-only golden image
      2. Mounts it offline and drops Windows\Panther\unattend.xml (computer name, password, locale, skip OOBE)
      3. Creates a Generation 2 VM: Secure Boot, dynamic or static memory, named vNICs (Device Naming)
      4. Nested Hyper-V hosts: static memory, ExposeVirtualizationExtensions, MAC address spoofing
      5. Boots it, waits for PowerShell Direct, then renames guest NICs and sets static IPs
.PARAMETER Name
    Deploy only these VMs.
.PARAMETER IncludeOptional
    Also deploy OptionalVMs (HGS01).
#>
[CmdletBinding()]
param([string[]]$Name, [switch]$IncludeOptional)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig

$defs = Get-LabVMDefinition -IncludeOptional:$IncludeOptional
if ($Name) { $defs = $defs | Where-Object { $_.Name -in $Name } }

function New-LabUnattendXml {
    param([string]$ComputerName)
    $adminPwd = [System.Security.SecurityElement]::Escape($cfg.AdminPassword)
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>$($cfg.TimeZone)</TimeZone>
      <RegisteredOwner>HVLAB</RegisteredOwner>
      <RegisteredOrganization>HVLAB Training</RegisteredOrganization>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAuthentication>1</UserAuthentication>
    </component>
    <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active><Group>@FirewallAPI.dll,-28752</Group><Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$($cfg.InputLocale)</InputLocale><SystemLocale>$($cfg.InputLocale)</SystemLocale>
      <UILanguage>$($cfg.InputLocale)</UILanguage><UserLocale>$($cfg.InputLocale)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>$adminPwd</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

foreach ($d in $defs) {
    if (Get-VM -Name $d.Name -ErrorAction SilentlyContinue) { Write-LabLog "VM $($d.Name) already exists, skipping create."; continue }

    $parent = Join-Path $cfg.LabRoot "Images\WS2025-$($d.Edition).vhdx"
    if (-not (Test-Path $parent)) { throw "Golden image $parent missing. Run 03-New-GoldenImage.ps1." }

    $vmDir = Join-Path $cfg.LabRoot "VMs\$($d.Name)"
    $osVhd = Join-Path $vmDir "$($d.Name)-OS.vhdx"
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    Write-LabLog "[$($d.Name)] Differencing disk -> $parent" -Level Step
    New-VHD -Path $osVhd -ParentPath $parent -Differencing | Out-Null

    # Offline servicing: inject unattend.xml into the child disk before first boot
    $mounted = Mount-VHD -Path $osVhd -PassThru | Get-Disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 10GB }
    try {
        if (-not $mounted.DriveLetter -or $mounted.DriveLetter -eq [char]0) { $mounted | Add-PartitionAccessPath -AssignDriveLetter; $mounted = $mounted | Get-Partition }
        $panther = "$($mounted.DriveLetter):\Windows\Panther"
        New-Item -ItemType Directory -Path $panther -Force | Out-Null
        New-LabUnattendXml -ComputerName $d.Name | Set-Content -Path "$panther\unattend.xml" -Encoding UTF8
        Copy-Item "$panther\unattend.xml" (Join-Path $cfg.LabRoot "Unattend\$($d.Name).xml") -Force
    } finally { Dismount-VHD -Path $osVhd }

    Write-LabLog "[$($d.Name)] Creating Gen 2 VM ($($d.CPU) vCPU, $([int]($d.MemStartup/1GB)) GB, $(if($d.Dynamic){'dynamic'}else{'static'}) memory)" -Level Step
    $firstNet = $cfg.Network[$d.Nics[0].Net].Switch
    $vm = New-VM -Name $d.Name -Generation 2 -MemoryStartupBytes $d.MemStartup -VHDPath $osVhd -Path (Join-Path $cfg.LabRoot 'VMs') -SwitchName $firstNet
    Set-VMProcessor -VM $vm -Count $d.CPU
    if ($d.Dynamic) { Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $d.MemMin -MaximumBytes $d.MemMax -StartupBytes $d.MemStartup }
    else            { Set-VMMemory -VM $vm -DynamicMemoryEnabled $false }
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice (Get-VMHardDiskDrive -VM $vm | Select-Object -First 1)
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Production -AutomaticStopAction ShutDown -AutomaticStartAction Nothing -Notes "HVLAB role: $($d.Role)"
    Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface'

    # vNICs: rename the first, add the rest; Device Naming exposes the vNIC name inside the guest
    Get-VMNetworkAdapter -VM $vm | Rename-VMNetworkAdapter -NewName $d.Nics[0].Net
    for ($i = 1; $i -lt $d.Nics.Count; $i++) {
        Add-VMNetworkAdapter -VM $vm -Name $d.Nics[$i].Net -SwitchName $cfg.Network[$d.Nics[$i].Net].Switch
    }
    Get-VMNetworkAdapter -VM $vm | Set-VMNetworkAdapter -DeviceNaming On

    if ($d['Nested']) {
        Set-VMProcessor -VM $vm -ExposeVirtualizationExtensions $true
        # Nested guests send frames with their own MACs through the host's vNIC
        Get-VMNetworkAdapter -VM $vm | Set-VMNetworkAdapter -MacAddressSpoofing On
    }

    if ($d['DataDisks']) {
        $n = 0
        foreach ($size in $d.DataDisks) {
            $n++
            $dataVhd = Join-Path $vmDir "$($d.Name)-Data$n.vhdx"
            New-VHD -Path $dataVhd -SizeBytes $size -Dynamic | Out-Null
            Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -Path $dataVhd
        }
    }

    Start-VM -VM $vm
}

# ---- Guest network configuration via PowerShell Direct ----
foreach ($d in $defs) {
    Wait-LabVM -VMName $d.Name
    $nicPlan = foreach ($nic in $d.Nics) {
        $n = $cfg.Network[$nic.Net]
        @{
            Name    = $nic.Net
            IP      = '{0}.{1}' -f $n.Prefix, $nic.IP
            Length  = $n.Length
            Gateway = if ($nic.Net -eq 'Mgmt') { $n.Gateway } else { $null }
            Dns     = if ($nic.Net -eq 'Mgmt') { $cfg.Network.DnsServer } else { $null }
        }
    }
    Invoke-LabCommand -VMName $d.Name -Activity 'Configure NICs, ICMP, WinRM' -ArgumentList (, $nicPlan) -ScriptBlock {
        param($plan)
        foreach ($p in $plan) {
            $adapter = Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' |
                Where-Object { $_.DisplayValue -eq $p.Name } | ForEach-Object { Get-NetAdapter -Name $_.Name }
            if (-not $adapter) { Write-Warning "No adapter named $($p.Name)"; continue }
            if ($adapter.Name -ne $p.Name) { Rename-NetAdapter -Name $adapter.Name -NewName $p.Name }
            Set-NetIPInterface -InterfaceAlias $p.Name -Dhcp Disabled
            Get-NetIPAddress -InterfaceAlias $p.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
            $ipArgs = @{ InterfaceAlias = $p.Name; IPAddress = $p.IP; PrefixLength = $p.Length }
            if ($p.Gateway) { $ipArgs.DefaultGateway = $p.Gateway }
            New-NetIPAddress @ipArgs | Out-Null
            if ($p.Dns) { Set-DnsClientServerAddress -InterfaceAlias $p.Name -ServerAddresses $p.Dns }
            else { Set-DnsClient -InterfaceAlias $p.Name -RegisterThisConnectionsAddress $false }
        }
        Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue
        Set-NetConnectionProfile -InterfaceAlias 'Mgmt' -NetworkCategory Private -ErrorAction SilentlyContinue
        Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    }
}

Get-VM | Where-Object Name -in $defs.Name | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime, Generation -AutoSize
Write-LabLog 'VMs deployed. Next: 05-Initialize-DomainController.ps1' -Level Ok
