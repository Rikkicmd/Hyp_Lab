# Module 15: Troubleshooting (Break/Fix)

**Time:** 3 h+ · **Script:** `Invoke-LabFault.ps1`

## Objectives
- Apply a repeatable troubleshooting method to Hyper-V incidents
- Diagnose ten realistic faults using only symptoms, the way tickets arrive in real life
- Build a personal runbook

## Method
1. **Scope:** one VM, one host, one cluster, or everything? What changed?
2. **Layer:** work bottom-up. Physical/virtual network > name resolution > time > authentication > storage > cluster > Hyper-V > guest.
3. **Evidence:** event logs (Module 14 list), `Get-ClusterLog`, `Test-Cluster`, `Test-NetConnection`, `Resolve-DnsName`, `w32tm`, `Get-VM | fl *`
4. **Hypothesis, then test:** change one thing at a time
5. **Fix, verify, document:** run `Test-LabModule.ps1` and write a runbook entry (symptom > cause > fix > prevention)

## How to run a scenario
```powershell
.\Invoke-LabCheckpoint.ps1 -Action Save -Name Before-Faults   # once
.\Invoke-LabFault.ps1 -List
.\Invoke-LabFault.ps1 -Scenario Random                        # or pick one by name
# ...diagnose and fix it yourself...
..\validation\Test-LabModule.ps1 -All
.\Invoke-LabFault.ps1 -Scenario Random -Hint                  # if stuck
.\Invoke-LabFault.ps1 -Scenario Random -Repair                # revert
```

## Scenarios

| # | Scenario | Ticket text (what the user reports) |
|---|---|---|
| 1 | DnsMisconfig | Trust relationship / Kerberos errors on HV02, live migration to HV02 fails |
| 2 | IscsiPathDown | CSV01 in redirected access, slow VM I/O on HV02 |
| 3 | TimeSkew | Intermittent logon failures on HV03, replication Critical |
| 4 | MigrationDisabled | Shared-nothing migration to HV03 fails |
| 5 | ClusterNetworkRole | Live migrations between nodes fail or are slow |
| 6 | ReplicaFirewall | Replica health Critical, cannot connect to Replica server |
| 7 | WrongVlan | MGMT01 offline although its NIC shows Connected |
| 8 | MemoryOvercommit | Drain of HV01 fails, roles can't move |
| 9 | NestedVirtOff | HV03 can't start any VM after a reboot |
| 10 | StaleCheckpoints | Host disk usage growing, storage latency up |

## Instructor answer key
<details><summary>1. DnsMisconfig</summary>

**Cause:** HV02's DNS server is set to a non-existent 10.10.0.99. **Find it:** `Resolve-DnsName dc01` fails on HV02. `Get-DnsClientServerAddress`. **Fix:** set DNS back to 10.10.0.10, `Clear-DnsClientCache`, `Test-ComputerSecureChannel -Repair` if needed. **Prevent:** GPO/DSC for DNS settings, monitoring of DNS resolution from hosts.
</details>
<details><summary>2. IscsiPathDown</summary>

**Cause:** HV02's storage NIC is disabled. HV02 loses direct access, and CSV I/O redirects over SMB through the coordinator. **Find it:** `Get-ClusterSharedVolumeState` shows `FileSystemRedirected`/`BlockRedirected`. `Get-IscsiSession` on HV02 shows nothing connected. FailoverClustering event 5120/5142. **Fix:** enable the NIC, sessions reconnect (persistent). **Prevent:** MPIO with 2+ physical paths.
</details>
<details><summary>3. TimeSkew</summary>

**Cause:** HV03 clock is 17 minutes ahead, time service off, and the Hyper-V time-sync IC disabled. Kerberos allows 5 minutes of skew. **Find it:** `w32tm /stripchart /computer:dc01 /samples:3`, Kerberos errors in System log (KRB_AP_ERR_SKEW). **Fix:** start w32time, `w32tm /resync`, re-enable the IC. **Prevent:** domain time hierarchy, monitoring of time offset.
</details>
<details><summary>4. MigrationDisabled</summary>

**Cause:** incoming/outgoing live migration disabled on HV03. **Find it:** `Get-VMHost HV03 | select VirtualMachineMigrationEnabled`, and the Hyper-V-VMMS Admin log on both ends. **Fix:** `Enable-VMMigration`, and check the networks with `Get-VMMigrationNetwork`.
</details>
<details><summary>5. ClusterNetworkRole</summary>

**Cause:** the Cluster network's role was set to None, so live migration, which is restricted to that network by `MigrationExcludeNetworks`, has no usable network. **Find it:** `Get-ClusterNetwork | ft Name, Role`. **Fix:** set Role back to `Cluster`.
</details>
<details><summary>6. ReplicaFirewall</summary>

**Cause:** inbound rule "Hyper-V Replica HTTP Listener (TCP-In)" disabled on HV03. **Find it:** `Test-NetConnection hv03 -Port 80` fails from the primary. Replica health is Critical, with connection errors in the Hyper-V-VMMS Admin log on the primary. **Fix:** enable the rule, then `Resume-VMReplication`.
</details>
<details><summary>7. WrongVlan</summary>

**Cause:** MGMT01's vNIC is tagged with VLAN 99 on the parent host. The guest sees a link, but nothing else is on VLAN 99. **Find it:** `Get-VMNetworkAdapterVlan -VMName MGMT01` on the host. **Fix:** `Set-VMNetworkAdapterVlan -VMName MGMT01 -Untagged`. **Lesson:** a "connected" adapter in the guest proves nothing about the vSwitch port configuration.
</details>
<details><summary>8. MemoryOvercommit</summary>

**Cause:** SHELL01 was changed to 10 GB static memory, more than the other node can supply. **Find it:** cluster event 1205/1069, `Get-VMMemory SHELL01`, available memory on the target. **Fix:** right-size and use dynamic memory. **Prevent:** N+1 capacity checks (Module 14).
</details>
<details><summary>9. NestedVirtOff</summary>

**Cause:** virtualization extensions are no longer exposed to HV03, so the hypervisor can't start inside it. **Find it:** `Get-VMProcessor HV03 | select ExposeVirtualizationExtensions` on the physical host. Inside HV03, `Get-CimInstance Win32_ComputerSystem | select HypervisorPresent` is False. **Fix:** stop the VM, re-enable the setting, start it. In real life the equivalent is VT-x disabled in BIOS after a firmware update or reset.
</details>
<details><summary>10. StaleCheckpoints</summary>

**Cause:** three forgotten checkpoints on STOR01, so all writes go to AVHDX files. **Find it:** `Get-VMCheckpoint STOR01`. `Get-VMHardDiskDrive STOR01 | Get-VHD` shows `.avhdx` paths. **Fix:** `Remove-VMCheckpoint`, then monitor the merge. **Prevent:** report checkpoints older than 7 days (a classic scheduled script).
</details>

## Write your own fault
Add a new entry to the `$S` table in `Invoke-LabFault.ps1` with `Symptom`, `Hint`, `Break` and `Fix` scriptblocks. Ideas: delete the cluster CNO's DNS record, fill CSV01 to 99%, remove `cifs/` delegation, a VM disconnected from its switch, the iSCSI target service stopped, a VM with a mounted ISO that only exists on one node (breaks failover).

## Review questions
1. Name the bottom-up layers you check before blaming Hyper-V.
2. Which three event logs do you open first for a failed live migration?
3. How do you tell a VLAN problem from a guest firewall problem?
