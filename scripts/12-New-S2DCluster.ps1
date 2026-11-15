#Requires -Version 5.1
<#
.SYNOPSIS
    Module 11 (alternative storage track) - Rebuilds HV01/HV02 as a two-node Storage Spaces Direct (HCI) cluster.
.DESCRIPTION
    S2D and SAN/iSCSI cluster storage do not mix on one cluster, so this track REPLACES the iSCSI cluster.
    Take a lab checkpoint first (Save-LabCheckpoint.ps1 -Name 'Before-S2D') so you can return to the iSCSI design.

      1. (with -ReplaceIscsiCluster) removes workloads, destroys HVCLU01 and disconnects iSCSI
      2. Hot-adds 4 x 64 GB data VHDX files to each node (SCSI)
      3. Creates the cluster again with a file share witness on DC01 (2-node clusters always need a witness)
      4. Enable-ClusterS2D, then a two-way mirror CSVFS_ReFS volume
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([switch]$ReplaceIscsiCluster)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$c = $cfg.Cluster
$nodes = $c.Nodes
$first = $nodes[0]

$hasCluster = Invoke-LabCommand -VMName $first -Domain -Activity 'Check for existing cluster' -ScriptBlock { [bool](Get-Cluster -ErrorAction SilentlyContinue) }
if ($hasCluster) {
    if (-not $ReplaceIscsiCluster) { throw 'A cluster already exists. Re-run with -ReplaceIscsiCluster to tear it down (checkpoint the lab first).' }
    if (-not $PSCmdlet.ShouldProcess($c.Name, 'Destroy iSCSI-based cluster and its VMs')) { return }
    Invoke-LabCommand -VMName $first -Domain -Activity 'Destroy iSCSI cluster' -ScriptBlock {
        Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine' | ForEach-Object {
            Stop-ClusterGroup $_.Name -ErrorAction SilentlyContinue | Out-Null
            Remove-ClusterGroup $_.Name -RemoveResources -Force
        }
        Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VMReplicaBroker' } | Remove-ClusterGroup -RemoveResources -Force -ErrorAction SilentlyContinue
        Remove-Cluster -Force -CleanupAD
    }
    Invoke-LabCommand -VMName $nodes -Domain -Activity 'Disconnect iSCSI' -ScriptBlock {
        Get-IscsiTarget | Where-Object IsConnected | Disconnect-IscsiTarget -Confirm:$false
        Get-IscsiTargetPortal | Remove-IscsiTargetPortal -Confirm:$false
        Clear-ClusterNode -Force -ErrorAction SilentlyContinue
    }
}

foreach ($n in $nodes) {
    $vmDir = Join-Path $cfg.LabRoot "VMs\$n"
    for ($i = 1; $i -le $cfg.S2D.DisksPerNode; $i++) {
        $p = Join-Path $vmDir "$n-S2D$i.vhdx"
        if (-not (Test-Path $p)) {
            New-VHD -Path $p -SizeBytes $cfg.S2D.DiskSize -Dynamic | Out-Null
            Add-VMHardDiskDrive -VMName $n -ControllerType SCSI -Path $p   # hot-add to a running Gen 2 VM
            Write-LabLog "Added $p to $n"
        }
    }
}

Invoke-LabCommand -VMName DC01 -Domain -Activity 'Create file share witness' -ArgumentList $cfg.Domain.NetBIOS, $c.Name -ScriptBlock {
    param($nb, $clu)
    New-Item -ItemType Directory -Path 'C:\Witness' -Force | Out-Null
    if (-not (Get-SmbShare -Name 'Witness' -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name 'Witness' -Path 'C:\Witness' -FullAccess "$nb\Domain Admins", "$nb\Domain Computers" | Out-Null
    }
}

# Wipe leftover partitions on non-boot, non-iSCSI disks so S2D can claim them
Invoke-LabCommand -VMName $nodes -Domain -Activity 'Clean data disks for S2D' -ScriptBlock {
    Update-HostStorageCache
    Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.BusType -ne 'iSCSI' -and $_.PartitionStyle -ne 'RAW' } |
        ForEach-Object { Set-Disk -Number $_.Number -IsOffline $false; Clear-Disk -Number $_.Number -RemoveData -RemoveOEM -Confirm:$false }
}

$args1 = @($c.Name, $c.IP, $nodes, "\\DC01.$($cfg.Domain.FQDN)\Witness")
Invoke-LabCommand -VMName $first -Domain -Activity 'Create cluster and enable Storage Spaces Direct' -ArgumentList $args1 -ScriptBlock {
    param($name, $ip, $nodeList, $witness)
    Test-Cluster -Node $nodeList -Include 'Storage Spaces Direct', 'Inventory', 'Network', 'System Configuration' -ReportName 'C:\Windows\Cluster\Reports\HVLAB-S2D-Validation' | Out-Null
    New-Cluster -Name $name -Node $nodeList -StaticAddress $ip -NoStorage | Out-Null
    Start-Sleep 15
    Set-ClusterQuorum -FileShareWitness $witness | Out-Null
    Enable-ClusterStorageSpacesDirect -CacheState Disabled -Confirm:$false | Out-Null   # all disks same type: no cache tier
    New-Volume -FriendlyName 'S2DVol01' -FileSystem CSVFS_ReFS -StoragePoolFriendlyName 'S2D*' -Size 100GB -ResiliencySettingName Mirror | Out-Null
    Get-StoragePool -FriendlyName 'S2D*' | Format-Table FriendlyName, HealthStatus, Size, AllocatedSize
    Get-VirtualDisk | Format-Table FriendlyName, ResiliencySettingName, NumberOfDataCopies, HealthStatus, Size
    Get-ClusterSharedVolume | Format-Table Name, State, OwnerNode
}
Write-LabLog 'S2D cluster ready. VMs go in C:\ClusterStorage\S2DVol01. Run 10-New-ClusterWorkloads.ps1 -CsvName S2DVol01 to place workloads on it.' -Level Ok
