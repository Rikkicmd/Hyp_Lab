# Module 11: Storage Spaces Direct (Hyper-Converged Track)

**Time:** 2 h · **Script:** `12-New-S2DCluster.ps1` · **Optional / alternative to Modules 06-07 storage**

> This track **replaces** the iSCSI cluster on HV01/HV02. Save a checkpoint first so you can go back:
> `.\Invoke-LabCheckpoint.ps1 -Action Save -Name Before-S2D`

## Objectives
- Understand hyper-converged infrastructure (HCI) and how S2D differs from SAN-based clusters
- Build an S2D cluster, pool and resilient volumes
- Explore resiliency types, the cache, and repair behaviour

## Concepts

### What S2D is
Each node contributes **local disks**. S2D pools them across nodes over the network (SMB 3, ideally RDMA) into one **storage pool**, and carves **virtual disks** (volumes) with mirror or parity resiliency formatted as **CSVFS_ReFS**. This is the storage foundation of Azure Local (formerly Azure Stack HCI) and Windows Server Datacenter HCI.

### Resiliency
| Type | Min nodes | Efficiency | Survives |
|---|---|---|---|
| Two-way mirror | 2 | 50% | 1 failure |
| **Nested two-way mirror** (2-node) | 2 | 25% | 1 node **plus** 1 disk on the other node |
| Three-way mirror | 3 | 33% | 2 failures |
| Dual parity | 4 | 50-80% | 2 failures |
| Mirror-accelerated parity | 4 | Mixed | 2 failures |

### Cache
With mixed media (NVMe + SSD or SSD + HDD) the fastest disks become the cache automatically. With all-flash of one type there is no cache, which is why the lab uses `-CacheState Disabled`.

### Requirements (production)
Datacenter edition, certified hardware (Azure Local catalog), 10 GbE+ with RDMA (iWARP or RoCE with DCB), HBA passthrough (no RAID), and a witness (cloud or file share) for 2-node clusters.

## Build
```powershell
.\Invoke-LabCheckpoint.ps1 -Action Save -Name Before-S2D
.\12-New-S2DCluster.ps1 -ReplaceIscsiCluster
.\10-New-ClusterWorkloads.ps1 -CsvName S2DVol01
```

## Exercises

**1. Explore the pool.** List physical disks with media type and usage, the pool, virtual disks, and the storage tiers S2D created.
<details><summary>Solution</summary>

```powershell
Get-PhysicalDisk | ft FriendlyName, SerialNumber, MediaType, CanPool, Usage, Size
Get-StoragePool S2D* | fl; Get-VirtualDisk | ft FriendlyName, ResiliencySettingName, NumberOfDataCopies, FootprintOnPool
Get-StorageTier | ft FriendlyName, ResiliencySettingName, MediaType
```
</details>

**2. Media type.** The VHDX-backed disks show `Unspecified`. Mark them all as SSD and observe the tiers.
<details><summary>Solution</summary>

`Get-StoragePool S2D* | Get-PhysicalDisk | Set-PhysicalDisk -MediaType SSD`. Real hardware reports its media type itself.
</details>

**3. Nested resiliency volume.** Create a 20 GB nested two-way mirror volume (the recommended 2-node resiliency).
<details><summary>Solution</summary>

```powershell
New-StorageTier -StoragePoolFriendlyName S2D* -FriendlyName NestedMirror -ResiliencySettingName Mirror -MediaType SSD -NumberOfDataCopies 4
New-Volume -StoragePoolFriendlyName S2D* -FriendlyName Nested01 -StorageTierFriendlyNames NestedMirror -StorageTierSizes 20GB -FileSystem CSVFS_ReFS
```
</details>

**4. Disk failure and repair.** On the physical host, remove one S2D VHDX from HV02 while VMs run. Watch the storage jobs, then put it back.
<details><summary>Solution</summary>

```powershell
# physical host
$d = Get-VMHardDiskDrive HV02 | ? Path -like '*S2D1*'; Remove-VMHardDiskDrive $d
# HV01
Get-PhysicalDisk | ? OperationalStatus -ne OK; Get-VirtualDisk | ft FriendlyName, OperationalStatus, HealthStatus
Get-StorageJob
# physical host
Add-VMHardDiskDrive -VMName HV02 -ControllerType SCSI -Path $d.Path
```
Volumes go Degraded/Incomplete, then repair automatically once the disk returns.
</details>

**5. Node maintenance in S2D.** Put HV02 in storage maintenance mode properly before rebooting it.
<details><summary>Solution</summary>

```powershell
Suspend-ClusterNode HV02 -Drain -Wait
Get-StorageFaultDomain -Type StorageScaleUnit | ? FriendlyName -eq HV02 | Enable-StorageMaintenanceMode
# reboot HV02 ...
Get-StorageFaultDomain -Type StorageScaleUnit | ? FriendlyName -eq HV02 | Disable-StorageMaintenanceMode
Resume-ClusterNode HV02 -Failback Immediate
Get-StorageJob    # wait for resync before touching the next node
```
</details>

**6. Return to the iSCSI design.** `.\Invoke-LabCheckpoint.ps1 -Action Restore -Name Before-S2D`. The restored VMs no longer reference the S2D disks, so delete the orphaned `HV0x-S2D*.vhdx` files from `D:\HVLab\VMs\HV01` and `HV02` to reclaim space.

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 11
```

## Review questions
1. Why does S2D use ReFS for CSVs?
2. Which resiliency would you choose for a 2-node cluster, and why?
3. What is the most important step before rebooting an S2D node?
4. What network technology is strongly recommended for S2D, and why?
