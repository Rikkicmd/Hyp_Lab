# Module 06: Shared Storage with iSCSI & MPIO

**Time:** 1.5 h · **Script:** `08-New-IscsiStorage.ps1`

## Objectives
- Understand Hyper-V storage options for clusters
- Deploy an iSCSI target with LUN masking on a dedicated storage network
- Configure MPIO and persistent initiator sessions
- Prepare LUNs for clustering

## Concepts

### Cluster storage options
| Option | Notes |
|---|---|
| **FC SAN** | Classic enterprise. Zoning and LUN masking, MPIO with vendor DSM. |
| **iSCSI SAN** | Same model over Ethernet. Dedicated NICs/VLANs, jumbo frames, no NIC teaming for iSCSI (use MPIO instead). |
| **SMB 3 (Scale-Out File Server / NAS)** | VMs on `\\sofs\share`. Continuous availability, SMB Multichannel/Direct. |
| **Storage Spaces Direct** | Hyper-converged, local disks (Module 11). |

**Never team NICs for iSCSI.** MPIO gives path failover and load balancing at the storage layer, and teaming underneath it confuses path management.

### iSCSI vocabulary
- **Target:** the storage-side endpoint (STOR01), identified by an IQN. It presents LUNs.
- **Initiator:** the host side (HV01/HV02). Its IQN or IP is used for **masking** (who can see which LUNs).
- **Portal:** IP:3260 the initiator connects to.
- **Session/connection:** one per path. Two NICs means two sessions, which MPIO combines into one disk.

### MPIO policies
| Policy | Behaviour |
|---|---|
| Round Robin (RR) | All paths active (lab default) |
| Least Queue Depth | Common best choice for arrays |
| Failover Only | Active/passive |

Real arrays usually ship a vendor DSM or recommend specific MSDSM settings. Follow the vendor guidance.

### LUN design for Hyper-V clusters
- 1 small LUN (1 GB) for the **disk witness**
- 1+ large LUNs for **CSVs**. A few large CSVs are easier to run than many small ones. Balance CSV ownership across nodes.
- Format NTFS with a 64 KB allocation unit for SAN-backed CSVs. Use ReFS for S2D.

## Build
```powershell
.\08-New-IscsiStorage.ps1
Invoke-Command -VMName STOR01 -Credential HVLAB\Administrator { Get-IscsiServerTarget | fl; Get-IscsiVirtualDisk | ft Path, Size, Status }
Invoke-Command -VMName HV01 -Credential HVLAB\Administrator { Get-IscsiSession; mpclaim -s -d; Get-Disk | ? BusType -eq iSCSI }
```

<details><summary>Manual equivalent</summary>

STOR01:
```powershell
Install-WindowsFeature FS-iSCSITarget-Server
New-IscsiServerTarget -TargetName HVCLU01-Target -InitiatorIds 'IPAddress:10.10.20.11','IPAddress:10.10.20.12'
New-IscsiVirtualDisk -Path E:\iSCSI\CSV01.vhdx -SizeBytes 120GB
Add-IscsiVirtualDiskTargetMapping -TargetName HVCLU01-Target -Path E:\iSCSI\CSV01.vhdx
```
HV01/HV02:
```powershell
Install-WindowsFeature Multipath-IO; Enable-MSDSMAutomaticClaim -BusType iSCSI; Restart-Computer
Set-Service MSiSCSI -StartupType Automatic; Start-Service MSiSCSI
New-IscsiTargetPortal -TargetPortalAddress 10.10.20.30 -InitiatorPortalAddress 10.10.20.11
Get-IscsiTarget | Connect-IscsiTarget -IsPersistent $true -IsMultipathEnabled $true -InitiatorPortalAddress 10.10.20.11 -TargetPortalAddress 10.10.20.30
```
GUI: `iscsicpl.exe` (works on Core) and `mpiocpl.exe`.
</details>

## Exercises

**1. LUN masking.** Show that HV03 cannot see the cluster LUNs even if it connects to STOR01's portal. (Give HV03 a storage NIC first.)
<details><summary>Solution</summary>

Physical host: `Add-VMNetworkAdapter -VMName HV03 -Name Storage -SwitchName HVLAB-Storage`. Give it 10.10.20.13 inside HV03, then `New-IscsiTargetPortal -TargetPortalAddress 10.10.20.30`. `Get-IscsiTarget` is empty or the login fails because HV03's IP isn't in the target's InitiatorIds. Masking works.
</details>

**2. Add a second path (MPIO).** Give HV01 a second storage NIC (10.10.20.21) and connect a second session through it. Confirm that MPIO shows 2 paths per LUN, then pull one path (`Disable-NetAdapter`) while a VM runs.
<details><summary>Solution</summary>

```powershell
# physical host
Add-VMNetworkAdapter -VMName HV01 -Name Storage2 -SwitchName HVLAB-Storage
Set-VMNetworkAdapter -VMName HV01 -Name Storage2 -DeviceNaming On
# STOR01: allow the new initiator IP
Set-IscsiServerTarget -TargetName HVCLU01-Target -InitiatorIds 'IPAddress:10.10.20.11','IPAddress:10.10.20.12','IPAddress:10.10.20.21'
# HV01
$n = (Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' | ? DisplayValue -eq 'Storage2').Name
Rename-NetAdapter $n Storage2; New-NetIPAddress -InterfaceAlias Storage2 -IPAddress 10.10.20.21 -PrefixLength 24
Connect-IscsiTarget -NodeAddress (Get-IscsiTarget).NodeAddress -TargetPortalAddress 10.10.20.30 -InitiatorPortalAddress 10.10.20.21 -IsPersistent $true -IsMultipathEnabled $true
mpclaim -s -d <disk#>      # shows 2 paths
```
</details>

**3. Restrict the target's listening portals** to the storage network only, and confirm with `netstat -ano | findstr 3260` on STOR01.
<details><summary>Solution</summary>

`Set-IscsiTargetServerSetting -IP 10.10.0.30 -Enable $false`. After that, 3260 only listens on 10.10.20.30.
</details>

**4. CHAP.** Enable one-way CHAP on the target and reconnect HV02 with credentials.
<details><summary>Solution</summary>

STOR01: `Set-IscsiServerTarget -TargetName HVCLU01-Target -EnableChap $true -Chap (Get-Credential)` (the secret must be 12-16 characters). HV02: disconnect, then `Connect-IscsiTarget ... -AuthenticationType ONEWAYCHAP -ChapUsername user -ChapSecret 'secret12chars'`.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 6
```

## Review questions
1. Why does iSCSI use MPIO rather than NIC teaming?
2. What is the difference between LUN masking and zoning?
3. Why use a small dedicated LUN for the witness?
4. Which MPIO policy would you choose for an active/active array, and why?
