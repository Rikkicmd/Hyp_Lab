#Requires -Version 5.1
<#
.SYNOPSIS
    Module 07 - Validates and creates the two-node Hyper-V failover cluster HVCLU01.
.DESCRIPTION
    - Test-Cluster (saves the validation report to C:\Windows\Cluster\Reports on HV01)
    - New-Cluster with a static IP on the management network, no automatic storage
    - Disk witness on the 1 GB LUN, CSV on the large LUN (C:\ClusterStorage\CSV01)
    - Cluster networks renamed and given roles: Mgmt=ClusterAndClient, Cluster=Cluster only, Storage=None
    - Live migration restricted to the Cluster network, CSV block cache enabled
#>
[CmdletBinding()]
param([switch]$SkipValidation)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$c = $cfg.Cluster
$net = $cfg.Network
$first = $c.Nodes[0]

$args1 = @($c.Name, $c.IP, $c.Nodes, $SkipValidation.IsPresent,
           "$($net.Mgmt.Prefix).0", "$($net.Storage.Prefix).0", "$($net.Cluster.Prefix).0")

Invoke-LabCommand -VMName $first -Domain -Activity "Validate and create cluster $($c.Name)" -ArgumentList $args1 -ScriptBlock {
    param($name, $ip, $nodes, $skip, $mgmtNet, $storNet, $cluNet)

    if (-not (Get-Cluster -Name $name -ErrorAction SilentlyContinue)) {
        if (-not $skip) {
            $report = Test-Cluster -Node $nodes -Include 'Inventory', 'Network', 'System Configuration', 'Storage', 'Hyper-V Configuration' -ReportName "C:\Windows\Cluster\Reports\HVLAB-Validation"
            Write-Output "Validation report: $($report.FullName)"
        }
        New-Cluster -Name $name -Node $nodes -StaticAddress $ip -NoStorage | Out-Null
        Start-Sleep 15
    }

    # Networks
    foreach ($cn in Get-ClusterNetwork) {
        switch ($cn.Address) {
            $mgmtNet { $cn.Name = 'Mgmt';    $cn.Role = 'ClusterAndClient' }
            $cluNet  { $cn.Name = 'Cluster'; $cn.Role = 'Cluster' }
            $storNet { $cn.Name = 'Storage'; $cn.Role = 'None' }   # iSCSI traffic must never carry cluster traffic
        }
    }
    # Live migration only over the Cluster network
    $exclude = (Get-ClusterNetwork | Where-Object Name -ne 'Cluster').Id -join ';'
    Get-ClusterResourceType -Name 'Virtual Machine' | Set-ClusterParameter -Name MigrationExcludeNetworks -Value $exclude

    # Storage: Get-ClusterAvailableDisk reports each LUN's size, so the 1 GB LUN becomes the witness
    $wName = $null; $cName = $null
    foreach ($a in (Get-ClusterAvailableDisk | Sort-Object Size)) {
        $r = $a | Add-ClusterDisk
        if ($a.Size -lt 5GB) { $wName = $r.Name } else { $cName = $r.Name }
    }
    if (-not $wName) { $wName = (Get-ClusterQuorum).QuorumResource.Name }   # re-run: already configured
    if (-not $wName) { throw 'No witness LUN found. Check iSCSI sessions on both nodes (Module 06).' }

    if ((Get-ClusterQuorum).QuorumResource.Name -ne $wName) { Set-ClusterQuorum -DiskWitness $wName | Out-Null }
    if ($wName -ne 'Witness Disk') { (Get-ClusterResource $wName).Name = 'Witness Disk' }
    if ($cName -and -not (Get-ClusterSharedVolume -ErrorAction SilentlyContinue)) {
        Add-ClusterSharedVolume -Name $cName | Out-Null
        (Get-ClusterSharedVolume -Name $cName).Name = 'CSV01'
        Start-Sleep 5
        $mp = (Get-ClusterSharedVolume -Name 'CSV01').SharedVolumeInfo.FriendlyVolumeName
        if ($mp -and (Split-Path $mp -Leaf) -ne 'CSV01') { Rename-Item -Path $mp -NewName 'CSV01' }
    }
    (Get-Cluster).BlockCacheSize = 512   # MB of RAM for CSV read cache

    Get-Cluster | Format-List Name, Domain, BlockCacheSize
    Get-ClusterNode | Format-Table Name, State
    Get-ClusterNetwork | Format-Table Name, Address, Role
    Get-ClusterQuorum | Format-List QuorumResource, QuorumType
    Get-ClusterSharedVolume | Format-Table Name, State, OwnerNode
}

# Point both nodes' default VM storage at the CSV so new VMs are highly-available-ready
Invoke-LabCommand -VMName $c.Nodes -Domain -Activity 'Default VM paths -> CSV01' -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\ClusterStorage\CSV01\VMs', 'C:\ClusterStorage\CSV01\Disks' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-VMHost -VirtualMachinePath 'C:\ClusterStorage\CSV01\VMs' -VirtualHardDiskPath 'C:\ClusterStorage\CSV01\Disks'
}

Write-LabLog "Cluster $($c.Name) is up at $($c.IP). Next: 10-New-ClusterWorkloads.ps1" -Level Ok
