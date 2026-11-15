# Module 10: Checkpoints, Backup & Restore

**Time:** 2 h · **Scripts:** none (hands-on)

## Objectives
- Use standard and production checkpoints correctly, and manage AVHDX chains
- Export, import and copy VMs
- Back up and restore VMs with Windows Server Backup, and understand how enterprise backup integrates (RCT, VSS)
- Design a VM backup strategy

## Concepts

### Checkpoints
| | **Production** (default) | Standard |
|---|---|---|
| Mechanism | VSS (Windows) / file-system freeze (Linux) in the guest | Saves memory and device state |
| On restore | VM boots as if after a clean shutdown | VM resumes exactly where it was |
| App-consistent | Yes | No (unsafe for DCs, SQL, Exchange) |

Checkpoints create **.avhdx** differencing files. Every write goes to the newest one. Long chains hurt performance and fill volumes. **Checkpoints are not backups**: they live on the same storage as the VM. Deleting a checkpoint **merges** it online.

### Export / import
- **Export** (online since 2012 R2): a full copy of config, disks and checkpoints
- **Import** modes: *Register in place* (use files where they are), *Restore* (copy to default paths, keep the ID), *Copy* (new unique ID, which is what you want for cloning)
- `Compare-VM` produces an incompatibility report, for example a switch name that doesn't exist on the target host

### Backup integration
- Hyper-V VSS writer, plus **Resilient Change Tracking (RCT, .rct/.mrt files)** since 2016. Backup products (Veeam, Commvault, Rubrik, DPM/MABS, Azure Backup) read only changed blocks.
- Cluster-aware: backup snapshots CSV VMs through the CSV writer
- 3-2-1 rule: 3 copies, 2 media, 1 offsite or immutable (ransomware)

## Exercises
Use HV03 (standalone) for these unless stated otherwise.

**1. Standard vs production.** On the physical host, take a production checkpoint of MGMT01, create a file on its desktop, and apply the checkpoint. Then repeat with a standard checkpoint while Notepad is open. Describe the difference.
<details><summary>Solution</summary>

```powershell
Set-VM MGMT01 -CheckpointType ProductionOnly; Checkpoint-VM MGMT01 -SnapshotName P1
# create file, then
Restore-VMCheckpoint -VMName MGMT01 -Name P1 -Confirm:$false   # VM is off afterwards, then boots clean
Set-VM MGMT01 -CheckpointType Standard; Checkpoint-VM MGMT01 -SnapshotName S1
Restore-VMCheckpoint -VMName MGMT01 -Name S1 -Confirm:$false   # resumes with Notepad open
Set-VM MGMT01 -CheckpointType Production
Get-VMCheckpoint MGMT01 | Remove-VMCheckpoint
```
</details>

**2. AVHDX chain.** Take three checkpoints of a test VM, inspect the chain with `Get-VHD`, then delete the middle one and watch the merge.
<details><summary>Solution</summary>

`Get-VMHardDiskDrive VM | Get-VHD | fl Path, ParentPath`, and follow ParentPath up the chain. `Remove-VMCheckpoint -VMName VM -Name CP2`. The `Status` column of `Get-VM` shows "Merging".
</details>

**3. Export and import as a copy.** Export DC01 to `D:\HVLab\Exports` (online), then import it as a new VM with a new ID, *without* starting it. Why must you never start it on the lab network?
<details><summary>Solution</summary>

```powershell
Export-VM -Name DC01 -Path D:\HVLab\Exports
$cfg = Get-ChildItem D:\HVLab\Exports\DC01\'Virtual Machines' -Filter *.vmcx | select -First 1
$report = Compare-VM -Path $cfg.FullName -Copy -GenerateNewId -VirtualMachinePath D:\HVLab\VMs\DC01-Clone -VhdDestinationPath D:\HVLab\VMs\DC01-Clone
$report.Incompatibilities
$clone = Import-VM -CompatibilityReport $report
Rename-VM -VM $clone -NewName DC01-CLONE
Set-VM -VM $clone -Notes 'clone - delete me'     # keep it out of the lab power/checkpoint scripts
```
A clone of a DC has the same name, SID and AD database. Starting it on the same network causes conflicts. (VM-GenerationID handles restore safety, but cloning a DC is a separate, supported process involving `DCCloneConfig.xml`.) Delete the clone afterwards. Keep the export folder: validation checks for it.
</details>

**4. Windows Server Backup of a VM.** Install WSB on HV03, add a 30 GB VHDX as a backup target, back up a running VM, delete the VM, and restore it.
<details><summary>Solution</summary>

```powershell
# physical host: add a backup disk to HV03
New-VHD -Path D:\HVLab\VMs\HV03\HV03-Backup.vhdx -SizeBytes 30GB -Dynamic
Add-VMHardDiskDrive -VMName HV03 -Path D:\HVLab\VMs\HV03\HV03-Backup.vhdx
# HV03
Install-WindowsFeature Windows-Server-Backup
Get-Disk | ? PartitionStyle -eq RAW | Initialize-Disk -PassThru | New-Partition -DriveLetter B -UseMaximumSize | Format-Volume -FileSystem NTFS -Confirm:$false
wbadmin start backup -backupTarget:B: -hyperv:STGTEST -quiet
Remove-VM STGTEST -Force
wbadmin get versions -backupTarget:B:
wbadmin start recovery -version:<ver> -itemType:hyperv -items:STGTEST -backupTarget:B: -quiet
```
</details>

**5. Design task.** Write a one-page backup plan for HVCLU01: RPO/RTO per VM class, backup frequency, retention, offsite/immutable copy, how restores are tested, and how Replica (Module 09) complements it. Compare yours with the sample in [design-decisions.md](../reference/design-decisions.md#backup).

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 10
```

## Review questions
1. Why is a production checkpoint safe for a domain controller and a standard checkpoint not?
2. What are RCT files for?
3. Which import mode do you use to clone a VM?
4. Why aren't checkpoints backups?
