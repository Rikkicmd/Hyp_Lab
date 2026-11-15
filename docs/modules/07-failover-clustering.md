# Module 07: Hyper-V Failover Clustering

**Time:** 3 h · **Scripts:** `09-New-LabCluster.ps1`, `10-New-ClusterWorkloads.ps1`

## Objectives
- Validate hardware and configuration with Test-Cluster and read the report
- Create a cluster and configure quorum, CSV and cluster networks
- Make VMs highly available and control placement (priority, preferred owners, anti-affinity)
- Patch a cluster with Cluster-Aware Updating and run node maintenance

## Concepts

### Quorum
A cluster stays up while a **majority of votes** is online. Votes come from nodes plus one witness.
| Nodes | Witness? | Can lose |
|---|---|---|
| 2 | **Required** (disk, file share, cloud, or USB on Azure Local) | 1 node *or* the witness |
| 3 | Recommended | 1 node (2 with a witness and dynamic quorum) |
| 4+ | Recommended | n/2 - 1 |

**Dynamic quorum** and **dynamic witness** (on by default) adjust votes as nodes leave, so the cluster can survive down to the "last man standing". Witness choice: disk witness with a SAN, cloud witness (Azure Storage) or file share witness otherwise.

### Cluster Shared Volumes (CSV)
All nodes read and write the same NTFS/ReFS volume at `C:\ClusterStorage\<name>`. One node is the **coordinator** (metadata owner). Others do direct I/O. When a node loses its storage path, I/O becomes **redirected** over SMB through the coordinator: still up, but slower. Watch for it with `Get-ClusterSharedVolumeState`.

### Cluster networks
| Role | Value | Use |
|---|---|---|
| None | 0 | Not used by the cluster (iSCSI) |
| Cluster | 1 | Heartbeat, CSV, live migration |
| ClusterAndClient | 3 | Management, client access, also heartbeat |

### Placement controls
- **Priority:** High/Medium/Low/No Auto Start. Determines start order and who gets resources first
- **Preferred owners / possible owners**
- **AntiAffinityClassNames:** keep DCs, SQL AG replicas or web farm members apart
- **VM start ordering (Server 2016+):** sets and dependencies (`New-ClusterGroupSet`)
- **Node fairness / VM load balancing:** automatic rebalancing by memory and CPU

### Patching
**Cluster-Aware Updating (CAU)** drains a node, patches it, reboots, resumes it and fails back, then moves to the next node. Self-updating mode adds a CAU clustered role that runs on a schedule.

## Build
```powershell
.\09-New-LabCluster.ps1
.\10-New-ClusterWorkloads.ps1            # add -WithOS for real Windows guests WEB01/APP01
.\Invoke-LabCheckpoint.ps1 -Action Save -Name Baseline-Cluster
```
Read the validation report: copy `C:\Windows\Cluster\Reports\HVLAB-Validation.htm` from HV01 (or open it from MGMT01 at `\\HV01\C$\Windows\Cluster\Reports`). Expect warnings about single network paths, and possibly unsigned drivers or storage. Know which warnings matter.

<details><summary>Manual equivalent</summary>

```powershell
Test-Cluster -Node HV01,HV02
New-Cluster -Name HVCLU01 -Node HV01,HV02 -StaticAddress 10.10.0.50 -NoStorage
Get-ClusterAvailableDisk | Add-ClusterDisk
Set-ClusterQuorum -DiskWitness 'Cluster Disk 1'
Add-ClusterSharedVolume -Name 'Cluster Disk 2'
(Get-ClusterNetwork 'Cluster Network 2').Role = 'None'
Add-ClusterVirtualMachineRole -VMName SHELL01
```
GUI: Failover Cluster Manager on MGMT01 > Validate Configuration > Create Cluster.
</details>

## Exercises

**1. Read the cluster.** List nodes, networks with roles, quorum configuration, CSV owner, and clustered VMs with owner and priority.
<details><summary>Solution</summary>

```powershell
Get-ClusterNode; Get-ClusterNetwork | ft Name, Role, Address; Get-ClusterQuorum | fl *
Get-ClusterSharedVolume | ft Name, OwnerNode, State
Get-ClusterGroup | ? GroupType -eq VirtualMachine | ft Name, OwnerNode, State, Priority
```
</details>

**2. Unplanned failover.** Note which node owns SHELL01, then **turn off** that node from the physical host (`Stop-VM HV02 -TurnOff`). Time how long SHELL01 takes to come back on the other node. Then start the node again.
<details><summary>Solution</summary>

`Get-ClusterGroup SHELL01`, then `Stop-VM <owner> -TurnOff`. Watch from the surviving node with `Get-ClusterGroup SHELL01` and `Get-ClusterLog -TimeSpan 5`. With default heartbeat settings, VMs restart on the survivor within about 10-60 s (they *restart*, which is not live migration). The VM's resiliency period (`ResiliencyDefaultPeriod`, 240 s) applies to transient failures, but a node that is powered off is detected quickly. Start the node again with `Start-VM`.
</details>

**3. Quorum math.** With the witness online, stop the cluster service on HV02. Is the cluster still up? Now also take the witness disk offline. Explain using dynamic quorum and the witness vote.
<details><summary>Solution</summary>

HV01 plus the witness is 2 of 3 votes, so the cluster is up. With dynamic witness, after HV02 leaves the witness vote is adjusted. Taking the witness offline as well leaves HV01 as the last node with a dynamic vote, and it usually survives. Check `(Get-ClusterNode).DynamicWeight` and `(Get-Cluster).WitnessDynamicWeight`. Restore everything with `Start-ClusterNode HV02` and `Start-ClusterResource 'Witness Disk'`.
</details>

**4. Anti-affinity.** (Needs `-WithOS`.) Try to move APP01 onto the node running WEB01 with a *failover* (`Move-ClusterGroup`). What does the cluster do during automatic placement?
<details><summary>Solution</summary>

Anti-affinity is a *soft* rule. A manual move is honoured, but on failover or load balancing the cluster avoids placing them together if it can. Server 2016+ also has hard anti-affinity via `(Get-Cluster).ClusterEnforcedAntiAffinity = 1`.
</details>

**5. Node maintenance.** Drain HV01 (pause with roles drained), confirm all VMs moved by live migration, then resume with failback.
<details><summary>Solution</summary>

`Suspend-ClusterNode HV01 -Drain -Wait`, then `Get-ClusterGroup`, then `Resume-ClusterNode HV01 -Failback Immediate`.
</details>

**6. Cluster-Aware Updating.** Add the CAU clustered role (self-updating) with a monthly schedule, and run a preview scan.
<details><summary>Solution</summary>

```powershell
Install-WindowsFeature RSAT-Clustering-PowerShell   # already present
Add-CauClusterRole -ClusterName HVCLU01 -DaysOfWeek Tuesday -WeeksOfMonth 3 -EnableFirewallRules -Force
Invoke-CauScan -ClusterName HVCLU01 -CauPluginName Microsoft.WindowsUpdatePlugin -Verbose
```
</details>

**7. Cluster log.** Generate the cluster log for the last 15 minutes and find the failover from exercise 2.
<details><summary>Solution</summary>

`Get-ClusterLog -Destination C:\Temp -TimeSpan 15 -UseLocalTime`, then search for `RCM` and `Offline` entries for SHELL01.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 7
```

## Review questions
1. Why does a two-node cluster always need a witness?
2. What causes CSV redirected access, and how do you detect it?
3. What's the difference between preferred owners and anti-affinity?
4. Describe what CAU does to each node.
5. Which validation warnings would you accept in production, and which would you never accept?
