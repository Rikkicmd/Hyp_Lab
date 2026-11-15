# Module 09: Hyper-V Replica & Disaster Recovery

**Time:** 2 h · **Script:** `11-Enable-HyperVReplica.ps1`

## Objectives
- Configure replica servers and the Hyper-V Replica Broker for clusters
- Enable replication with suitable frequency, recovery history and app-consistent snapshots
- Run test, planned and unplanned failovers, and reverse replication
- Know where Replica fits next to backup, Azure Site Recovery and Storage Replica

## Concepts

### Hyper-V Replica
- Asynchronous, host-based replication of VMs to another host or cluster. No shared storage, works over WAN.
- **Frequency:** 30 s, 5 min, or 15 min. **Recovery points:** up to 24 hourly, plus optional app-consistent (VSS) snapshots.
- **Extended replication:** primary > replica > third site (chain).
- **Authentication:** Kerberos over HTTP (80) inside a domain. Certificates over HTTPS (443) across domains or for workgroups.
- **Replica Broker:** a cluster role that gives the cluster one replication endpoint, so replication follows VMs between nodes.

### Failover types
| Type | Run from | Data loss | Primary state | Use |
|---|---|---|---|---|
| **Test failover** | Replica | None (the primary keeps running) | Running | DR drills. Creates a `- Test` VM on an isolated network. |
| **Planned failover** | Primary first, then replica | None | Must be **off** | Datacenter moves, scheduled DR |
| **Unplanned (failover)** | Replica | Up to the last replication cycle | Down or lost | A real disaster |

After a planned or unplanned failover, use **reverse replication** to protect the VM back to the original site, then fail back the same way.

### Where it fits
| Technology | Level | RPO | Notes |
|---|---|---|---|
| Hyper-V Replica | VM | 30 s - 15 min | Built in, free |
| Storage Replica | Volume | 0 (sync) or async | Datacenter edition, stretch clusters |
| Azure Site Recovery | VM | about 30 s | Orchestrated DR to Azure |
| Backup | VM/app | Hours | Still required: replication copies corruption and ransomware too |

## Build
```powershell
.\11-Enable-HyperVReplica.ps1
Invoke-Command -VMName HV03 -Credential HVLAB\Administrator { Get-VMReplication | ft Name, State, Health, Mode, PrimaryServer }
Invoke-Command -VMName HV01 -Credential HVLAB\Administrator { Measure-VMReplication | ft }
```

## Exercises

**1. Replication health.** Show replication statistics for SHELL01 (average size, last replication time, errors) on the primary.
<details><summary>Solution</summary>

On the owner node: `Measure-VMReplication -VMName SHELL01 | fl *`. Or in Hyper-V Manager: right-click the VM > Replication > View Replication Health.
</details>

**2. Test failover.** Run a test failover of SHELL01 on HV03. Confirm the test VM exists and that its network adapter is disconnected, then stop the test.
<details><summary>Solution</summary>

```powershell
# HV03
Start-VMFailover -VMName SHELL01 -AsTest
Get-VM 'SHELL01 - Test'
Get-VMNetworkAdapter 'SHELL01 - Test'   # not connected unless you set a test failover network
Stop-VMFailover -VMName SHELL01
```
</details>

**3. Planned failover** to the DR host, then reverse replication.
<details><summary>Solution</summary>

```powershell
# On the cluster: shut down the primary
Stop-ClusterGroup SHELL01
# primary node (owner)
Start-VMFailover -VMName SHELL01 -Prepare
# HV03
Start-VMFailover -VMName SHELL01
Set-VMReplication -VMName SHELL01 -Reverse -ReplicaServerName HVCLU01-RB.hvlab.internal
Start-VM SHELL01
Complete-VMFailover -VMName SHELL01
```
The cluster now receives replicas through the broker. To fail back, repeat in the other direction and re-enable the VM as a cluster role if needed.
</details>

**4. Unplanned failover.** Simulate losing the site: turn off SHELL01's owner node from the physical host *and* stop the cluster from failing it over (stop the cluster group first). Fail over on HV03 to an older recovery point.
<details><summary>Solution</summary>

```powershell
# HV03
Get-VMSnapshot -VMName SHELL01 -SnapshotType Replica
Start-VMFailover -VMName SHELL01 -VMRecoverySnapshot (Get-VMSnapshot SHELL01 -SnapshotType Replica | select -First 1)
Start-VM SHELL01
Complete-VMFailover -VMName SHELL01      # commits; recovery points are discarded
```
</details>

**5. Certificate-based replication (stretch).** Create a self-signed certificate chain so a workgroup host could replicate over HTTPS 443. List the certificate requirements.
<details><summary>Solution</summary>

Requirements: Server Authentication **and** Client Authentication EKUs, a subject name matching the host FQDN (or the broker's CAP name), a trusted chain on both sides, and a reachable revocation check (or disable it with the `DisableCertRevocationCheck` registry value in labs). `New-SelfSignedCertificate -DnsName hv03.hvlab.internal -CertStoreLocation Cert:\LocalMachine\My -KeyUsage DigitalSignature,KeyEncipherment -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2')`. Then `Set-VMReplicationServer -AllowedAuthenticationType Certificate -CertificateThumbprint <thumb> -CertificateAuthenticationPort 443`.
</details>

**6. Resynchronization.** Pause replication of SHELL01 for 10 minutes and resume it. When does Hyper-V need a full **resync**?
<details><summary>Solution</summary>

`Suspend-VMReplication SHELL01`, wait, then `Resume-VMReplication SHELL01`. A resync is needed when the change log (HRL) can't be applied: the log grows beyond 50% of the VHD, the replica's state is inconsistent, or after some unplanned failures. Run it with `Resume-VMReplication -Resynchronize`. Schedule it off-hours because it reads the whole disk.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 9
```

## Review questions
1. Why does a cluster need a Replica Broker?
2. Compare planned and unplanned failover for data loss and prerequisites.
3. Why doesn't Hyper-V Replica replace backups?
4. What ports and authentication modes does Replica use?
