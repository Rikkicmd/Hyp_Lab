#Requires -Version 5.1
<#
.SYNOPSIS
    Module 05 - Turns HV01, HV02 and HV03 into production-style Hyper-V hosts (nested).
.DESCRIPTION
    On each nested host:
      - Installs Hyper-V, Failover Clustering (HV01/HV02), Multipath I/O, and management tools
      - Creates a Switch Embedded Teaming (SET) external switch on the Mgmt NIC, management OS shares it
      - Sets default VM/VHD paths, live migration (Kerberos, compression, dedicated cluster subnet)
      - Grants HV-Operators the "Hyper-V Administrators" local group (least privilege)
    On DC01:
      - Configures Kerberos constrained delegation so hosts can live-migrate (shared nothing) and
        access each other's SMB shares when you manage them remotely from MGMT01
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$hosts = @(Get-LabVMDefinition | Where-Object Role -eq 'HyperV' | ForEach-Object Name)
$clusterNodes = $cfg.Cluster.Nodes
$clusterSubnet = "$($cfg.Network.Cluster.Prefix).0/$($cfg.Network.Cluster.Length)"

# Sanity check from the physical host: nested virtualization must be exposed BEFORE the role is installed
foreach ($h in $hosts) {
    if (-not (Get-VMProcessor -VMName $h).ExposeVirtualizationExtensions) {
        throw "$h does not expose virtualization extensions. Stop-VM $h; Set-VMProcessor -VMName $h -ExposeVirtualizationExtensions `$true"
    }
}

foreach ($h in $hosts) {
    $features = @('Hyper-V', 'Hyper-V-PowerShell', 'Multipath-IO', 'RSAT-Hyper-V-Tools')
    if ($h -in $clusterNodes) { $features += 'Failover-Clustering', 'RSAT-Clustering-PowerShell' }
    $needsReboot = Invoke-LabCommand -VMName $h -Domain -Activity "Install $($features -join ', ')" -ArgumentList (, $features) -ScriptBlock {
        param($f)
        $r = Install-WindowsFeature -Name $f -IncludeManagementTools
        $r.RestartNeeded -eq 'Yes'
    }
    if ($needsReboot) { Restart-LabVM -VMName $h -Domain }
}

foreach ($h in $hosts) {
    Invoke-LabCommand -VMName $h -Domain -Activity 'Create SET switch, host defaults, live migration' -ArgumentList $clusterSubnet, $cfg.Domain.NetBIOS -ScriptBlock {
        param($lmSubnet, $nb)
        New-Item -ItemType Directory -Path 'C:\VMs', 'C:\VMs\Disks' -Force | Out-Null

        if (-not (Get-VMSwitch -Name 'SETswitch' -ErrorAction SilentlyContinue)) {
            # SET is the modern replacement for LBFO teaming on Hyper-V hosts. One member here; add more in Module 05 exercises.
            # The Mgmt IP moves to the new host vNIC automatically. PowerShell Direct keeps working while it does.
            New-VMSwitch -Name 'SETswitch' -NetAdapterName 'Mgmt' -EnableEmbeddedTeaming $true -AllowManagementOS $true -MinimumBandwidthMode Weight | Out-Null
            Rename-VMNetworkAdapter -ManagementOS -Name 'SETswitch' -NewName 'Mgmt'
            Set-VMSwitch -Name 'SETswitch' -DefaultFlowMinimumBandwidthWeight 50
            Set-VMNetworkAdapter -ManagementOS -Name 'Mgmt' -MinimumBandwidthWeight 10
        }

        Set-VMHost -VirtualMachinePath 'C:\VMs' -VirtualHardDiskPath 'C:\VMs\Disks' -EnableEnhancedSessionMode $true
        Enable-VMMigration
        Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos `
                   -VirtualMachineMigrationPerformanceOption Compression `
                   -MaximumVirtualMachineMigrations 2 -MaximumStorageMigrations 2 `
                   -UseAnyNetworkForMigration $false
        if (Get-NetAdapter -Name 'Cluster' -ErrorAction SilentlyContinue) {
            Get-VMMigrationNetwork | Remove-VMMigrationNetwork -ErrorAction SilentlyContinue
            Add-VMMigrationNetwork -Subnet $lmSubnet -Priority 1
        } else {
            # Standalone host (HV03): migrate over management
            $mgmt = (Get-NetIPAddress -InterfaceAlias 'vEthernet (Mgmt)' -AddressFamily IPv4).IPAddress
            Add-VMMigrationNetwork -Subnet "$mgmt/32" -Priority 1 -ErrorAction SilentlyContinue
        }
        Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member "$nb\HV-Operators" -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup 'Hyper-V' -ErrorAction SilentlyContinue
    }
}

# Kerberos constrained delegation (Microsoft-documented requirement for remote-initiated live migration)
$fqdn = $cfg.Domain.FQDN
Invoke-LabCommand -VMName DC01 -Domain -Activity 'Configure constrained delegation between Hyper-V hosts' -ArgumentList $hosts, $fqdn -ScriptBlock {
    param($hvHosts, $domain)
    foreach ($src in $hvHosts) {
        $spns = foreach ($dst in $hvHosts | Where-Object { $_ -ne $src }) {
            "Microsoft Virtual System Migration Service/$dst", "Microsoft Virtual System Migration Service/$dst.$domain",
            "cifs/$dst", "cifs/$dst.$domain"
        }
        $comp = Get-ADComputer $src -Properties msDS-AllowedToDelegateTo
        $toAdd = $spns | Where-Object { $_ -notin $comp.'msDS-AllowedToDelegateTo' }
        if ($toAdd) { Set-ADComputer $src -Add @{ 'msDS-AllowedToDelegateTo' = [string[]]$toAdd } }
        # "Use any authentication protocol" (protocol transition) so delegation works from WAC/MGMT01 as well
        Set-ADAccountControl -Identity (Get-ADComputer $src) -TrustedToAuthForDelegation $true
    }
}

foreach ($h in $hosts) {
    Invoke-LabCommand -VMName $h -Domain -Activity 'Verify' -ScriptBlock {
        Get-VMHost | Select-Object ComputerName, VirtualMachineMigrationEnabled, VirtualMachineMigrationAuthenticationType, VirtualMachineMigrationPerformanceOption
        Get-VMSwitch | Select-Object Name, SwitchType, EmbeddedTeamingEnabled
    } | Format-List
}
Write-LabLog 'Nested Hyper-V hosts ready. Next: 08-New-IscsiStorage.ps1' -Level Ok
