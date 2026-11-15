# Module 08: VM Mobility (Live, Quick, Storage & Shared-Nothing Migration)

**Time:** 1.5 h · **Prerequisite:** Module 07 workloads running

## Objectives
- Know every Hyper-V move type and its requirements
- Perform each move with PowerShell and with GUI tools
- Diagnose failed migrations and processor compatibility problems

## Concepts

| Move | What moves | Downtime | Requirements |
|---|---|---|---|
| **Live migration (clustered)** | Memory and state, storage stays on CSV | None (sub-second stun) | Cluster, LM network |
| **Quick migration** | Saves state, moves, resumes | Seconds to minutes | Cluster. Fallback when live migration isn't possible. |
| **Storage live migration** | VHDX and config files, VM stays on its host | None | Any host |
| **Shared-nothing live migration** | Memory, state *and* storage between non-clustered hosts | None | Kerberos/KCD or CredSSP, network between hosts |
| **Export/Import** | Files offline | Yes | Anything (Module 10) |

### Live migration steps
1. Connection and authentication; destination creates a shell VM
2. Memory pages copied while the VM runs; dirty pages re-copied in iterations
3. Brief pause: last pages and device state copied
4. Storage handles moved (CSV), VM resumes on the destination, ARP updated

### Processor compatibility
Live migration between different CPU generations requires `Set-VMProcessor -CompatibilityForMigrationEnabled $true` (VM off). Server 2025 adds **dynamic processor compatibility**: the cluster computes the common CPU feature set of its nodes, instead of the old fixed minimal set.

## Exercises

**1. Live-migrate a clustered VM** and measure the downtime: run a continuous ping to WEB01 (with `-WithOS`) from MGMT01. Without `-WithOS`, just time the move.
<details><summary>Solution</summary>

```powershell
Move-ClusterVirtualMachineRole -Name SHELL01 -Node HV02 -MigrationType Live
Measure-Command { Move-ClusterVirtualMachineRole -Name SHELL01 -Node HV01 }
# MGMT01: ping -t 10.10.0.<WEB01 DHCP address>   (expect 0-1 lost packets)
```
</details>

**2. Quick migration.** Move SHELL02 with quick migration and compare the time and VM state transitions with exercise 1.
<details><summary>Solution</summary>

`Move-ClusterVirtualMachineRole -Name SHELL02 -Node HV02 -MigrationType Quick`. The state goes Running > Saving > Saved > Starting > Running.
</details>

**3. Storage live migration.** On HV03, create a VM on `C:\VMs`, start it, and move only its storage to `C:\VMs-Moved` while it runs.
<details><summary>Solution</summary>

```powershell
New-VM -Name STGTEST -Generation 2 -MemoryStartupBytes 512MB -NewVHDPath C:\VMs\Disks\STGTEST.vhdx -NewVHDSizeBytes 10GB -SwitchName SETswitch
Start-VM STGTEST
Move-VMStorage -VMName STGTEST -DestinationStoragePath C:\VMs-Moved
Get-VMHardDiskDrive STGTEST | select Path
```
</details>

**4. Shared-nothing live migration from the cluster to HV03.** Move SHELL02 out of the cluster to HV03, VM and storage, while it runs. Start the move **from MGMT01** to exercise Kerberos constrained delegation.
<details><summary>Solution</summary>

A clustered VM must first be removed from the cluster (the VM stays, only the role is removed):
```powershell
# on HV01 / MGMT01
Remove-ClusterGroup -Name SHELL02 -RemoveResources -Force -Cluster HVCLU01
$owner = (Get-VM -ComputerName HV01,HV02 -Name SHELL02).ComputerName
Move-VM -ComputerName $owner -Name SHELL02 -DestinationHost HV03 -IncludeStorage -DestinationStoragePath C:\VMs\SHELL02
```
If it fails with "No credentials are available in the security package", constrained delegation is missing (Module 05). Move it back the same way, then `Add-ClusterVirtualMachineRole -VMName SHELL02` on the owner.
</details>

**5. Processor compatibility.** Enable processor compatibility on SHELL01 (it must be off). Explain when you need it.
<details><summary>Solution</summary>

`Stop-ClusterGroup SHELL01; Set-VMProcessor SHELL01 -CompatibilityForMigrationEnabled $true; Start-ClusterGroup SHELL01`. You need it when cluster or migration partners have different CPU generations from the same vendor. Migrating between Intel and AMD is never possible live.
</details>

**6. Simultaneous migrations.** Set the maximum simultaneous live migrations to 1 on both nodes, drain HV01, and watch the VMs queue.
<details><summary>Solution</summary>

`Set-VMHost -MaximumVirtualMachineMigrations 1` on both nodes, then `Suspend-ClusterNode HV01 -Drain`. Failover Cluster Manager shows "Live Migration Queued". Revert to 2.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 8
```

## Review questions
1. What happens during the "brownout"/stun phase of a live migration?
2. Why must you remove a VM from the cluster before a shared-nothing move?
3. When is quick migration still used?
4. What does dynamic processor compatibility improve in Server 2025?
