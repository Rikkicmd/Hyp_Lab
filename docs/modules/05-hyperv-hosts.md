# Module 05: Building Production-Style Hyper-V Hosts

**Time:** 2 h · **Script:** `07-Install-NestedHyperV.ps1`

## Objectives
- Install and baseline Hyper-V hosts on Server Core
- Build SET switches with converged host vNICs and QoS
- Configure live migration correctly (authentication, performance option, networks)
- Set up Kerberos constrained delegation and least-privilege RBAC

## Concepts

### Host build checklist (production)
1. Firmware: virtualization, SR-IOV, IOMMU and Secure Boot on; latest BIOS, NIC and HBA firmware
2. Server Core, joined to the domain, in the hosts' OU
3. Roles: Hyper-V, Failover-Clustering, Multipath-IO (SAN), Data-Center-Bridging (RDMA)
4. Networking: SET switch, host vNICs per traffic class, VLANs, jumbo frames on storage
5. Paths: VMs on CSV/SMB, never on C:
6. Live migration: Kerberos, a dedicated network, compression or SMB (with RDMA)
7. Patching: Cluster-Aware Updating. Security baseline: Microsoft Security Compliance Toolkit

### Live migration options
| Setting | Choices | Guidance |
|---|---|---|
| Authentication | **CredSSP** / **Kerberos** | CredSSP needs you logged on to the *source* host. Kerberos needs constrained delegation and works remotely. Production uses Kerberos. |
| Performance | TCP/IP · **Compression** · **SMB** | Compression is the default and best below about 10 GbE. SMB with SMB Direct (RDMA) is best on 25 GbE and up. |
| Simultaneous | default 2 | Increase on fast networks |
| Networks | Any / specific subnets | Always restrict to a dedicated LM network |

For **clustered** VMs, the cluster's network list for live migration (`MigrationExcludeNetworks`) applies instead of the host setting.

### Kerberos constrained delegation (KCD)
When you start a migration from MGMT01, MGMT01 authenticates to HV01, and HV01 must authenticate *onward* to HV02 on your behalf. That's a double hop. KCD on each host's computer account allows delegation to exactly two services on the other hosts:
- `Microsoft Virtual System Migration Service/<host>`
- `cifs/<host>` (needed to move storage over SMB)

Script 07 sets this, along with "use any authentication protocol" (protocol transition), which WAC needs.

### RBAC on hosts
| Group | Rights |
|---|---|
| Local Administrators (HV-Admins) | Everything |
| **Hyper-V Administrators** (HV-Operators) | Full Hyper-V control without OS admin |
| JEA endpoint (Module 13) | Only the cmdlets you allow, for example Start-VM and Stop-VM |

## Build
```powershell
.\07-Install-NestedHyperV.ps1
Enter-PSSession -VMName HV01 -Credential HVLAB\Administrator
Get-VMSwitch SETswitch | fl Name, EmbeddedTeamingEnabled, BandwidthReservationMode
Get-VMSwitchTeam SETswitch | fl
Get-VMNetworkAdapter -ManagementOS
Get-VMHost | fl VirtualMachineMigration*, UseAnyNetworkForMigration
Get-VMMigrationNetwork
```

## Exercises

**1. Add a team member to SET.** Add a second Mgmt vNIC to HV03 on the physical host (on `HVLAB-Mgmt`, MAC spoofing on), then add it to HV03's SET team inside the guest. Set the load-balancing algorithm to HyperVPort.
<details><summary>Solution</summary>

```powershell
# physical host
Add-VMNetworkAdapter -VMName HV03 -Name Mgmt2 -SwitchName HVLAB-Mgmt
Set-VMNetworkAdapter -VMName HV03 -Name Mgmt2 -MacAddressSpoofing On -DeviceNaming On
# HV03
$n = (Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' | ? DisplayValue -eq 'Mgmt2').Name
Rename-NetAdapter $n -NewName Mgmt2
Add-VMSwitchTeamMember -VMSwitchName SETswitch -NetAdapterName Mgmt2
Set-VMSwitchTeam -Name SETswitch -LoadBalancingAlgorithm HyperVPort
Get-VMSwitchTeam SETswitch
```
</details>

**2. Converged host vNICs.** On HV03, add a host vNIC `LM` on the SET switch with VLAN 30 and a minimum bandwidth weight of 30. Why won't it pass traffic in this lab, and what would you change on a physical switch?
<details><summary>Solution</summary>

```powershell
Add-VMNetworkAdapter -ManagementOS -Name LM -SwitchName SETswitch
Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName LM -Access -VlanId 30
Set-VMNetworkAdapter -ManagementOS -Name LM -MinimumBandwidthWeight 30
```
HV03's uplink is a vNIC on an untagged port of the parent's internal switch. Tagged frames are dropped unless the parent adapter is in trunk mode: `Set-VMNetworkAdapterVlan -VMName HV03 -VMNetworkAdapterName Mgmt -Trunk -AllowedVlanIdList 30 -NativeVlanId 0`. On a physical switch, the port must be a trunk that allows VLAN 30. Remove the LM vNIC afterwards.
</details>

**3. CredSSP vs Kerberos.** Switch HV03 to CredSSP, then try `Move-VM` from MGMT01 to HV03 and explain the error. Switch back.
<details><summary>Solution</summary>

`Set-VMHost -VirtualMachineMigrationAuthenticationType CredSSP` on both ends. A remote-initiated move fails because CredSSP only works when you are logged on to the source host interactively (or have configured CredSSP delegation). Revert with `Kerberos`.
</details>

**4. Least privilege.** Log on to MGMT01 as `HVLAB\hvop`. Show that `hvop` can manage VMs on HV03 with Hyper-V Manager, but can't change the host firewall.
<details><summary>Solution</summary>

`Get-VM -ComputerName HV03` works (Hyper-V Administrators). `Invoke-Command HV03 { Set-NetFirewallProfile -Enabled False }` fails with access denied (not a local admin, so no WinRM admin session).
</details>

**5. Inspect KCD.** Show the delegation entries on HV01's computer account, and explain what breaks if `cifs/HV02` is removed.
<details><summary>Solution</summary>

`Get-ADComputer HV01 -Properties msDS-AllowedToDelegateTo | select -Expand msDS-AllowedToDelegateTo`. Without `cifs/HV02`, live migrations with storage (shared-nothing / storage move) between them fail when started remotely. Plain live migration of clustered VMs on CSV still works.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 5
```

## Review questions
1. Why is Kerberos preferred over CredSSP for live migration?
2. Which two SPN classes go into constrained delegation for Hyper-V hosts?
3. When would you pick SMB as the live migration performance option?
4. What does SET replace, and what limits does it have?
