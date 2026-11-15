# Module 00: Orientation

**Time:** 30 min · **Scripts:** none

## Objectives
- Understand what the lab simulates and why each machine exists
- Know how to work in the lab safely: checkpoints, validation, reset
- Learn the conventions used in every module

## Why this design

The lab mirrors the most common production Hyper-V architecture in mid-size organizations:

| Production component | Lab equivalent | Why it matters |
|---|---|---|
| Active Directory + DNS | DC01 | Clustering, live migration (Kerberos), Replica and WAC all depend on AD and DNS. Most real Hyper-V outages trace back to DNS, time, or AD. |
| SAN (FC/iSCSI array) | STOR01 iSCSI Target Server | Teaches LUN presentation, masking, MPIO, and dedicated storage networks without hardware. |
| 2+ node Hyper-V cluster | HV01 + HV02 = HVCLU01 | The standard unit of high availability for VMs. |
| DR site host | HV03 | Hyper-V Replica target and shared-nothing migration partner. |
| Admin workstation / jump box | MGMT01 | Production hosts are Server Core and are managed remotely, never by logging on to them. |
| Guarded fabric | HGS01 (optional) | Shielded VMs / attestation concepts. |
| Hyper-converged alternative | Module 11 S2D track | The other dominant design: local disks pooled with Storage Spaces Direct. |

Hosts run **Server Core** on purpose, because that is Microsoft's recommendation for Hyper-V hosts (smaller attack surface, fewer patches). You manage them from MGMT01 or the physical host.

## Nested virtualization in one paragraph

HV01-HV03 are VMs that themselves run Hyper-V. The physical host exposes the CPU's virtualization extensions to them (`Set-VMProcessor -ExposeVirtualizationExtensions $true`). The VMs *inside* them (SHELL01, WEB01...) are "L2" guests. Nested virtualization is supported for test and training, not for production workloads. Some things behave differently from bare metal: no dynamic memory on the nested hosts, no live migration of the nested hosts themselves, and limited VBS/IOMMU. The modules point these differences out where they matter.

## How every module is laid out

1. **Objectives**
2. **Concepts**: the theory and the industry practice, short and opinionated
3. **Build**: the script that builds this part, plus the equivalent manual/GUI steps so you understand what it did
4. **Exercises**: hands-on tasks. Solutions are hidden in collapsible blocks. Try first.
5. **Validate**: `..\validation\Test-LabModule.ps1 -Module N`. Checks tagged `[Exercise]` pass only after you have done the exercise.
6. **Review questions**: interview-style questions

## Working safely

```powershell
# Save points (the lab powers down in order, takes standard checkpoints, powers up)
.\Invoke-LabCheckpoint.ps1 -Action Save    -Name Baseline-Cluster
.\Invoke-LabCheckpoint.ps1 -Action Restore -Name Baseline-Cluster
.\Invoke-LabCheckpoint.ps1 -Action List

# Shut down / start the whole lab in dependency order (DC first up, last down)
.\Invoke-LabPower.ps1 -State Off
.\Invoke-LabPower.ps1 -State On
```

The lab runs on internal and private switches only. Its only route out is NAT through the host, so it cannot hand out DHCP leases or register DNS on your real network.

## Connecting to lab machines

| From | How |
|---|---|
| Physical host, no network needed | `Enter-PSSession -VMName HV01 -Credential HVLAB\Administrator` (PowerShell Direct over VMBus) |
| Physical host, console | `vmconnect localhost MGMT01` (Enhanced Session works for MGMT01) |
| MGMT01 | `Enter-PSSession HV01`, Hyper-V Manager, Failover Cluster Manager, `https://mgmt01.hvlab.internal` (WAC) |
| RDP from host | `mstsc /v:10.10.0.20` (the host has a leg on 10.10.0.0/24) |

## Suggested schedules

- **Bootcamp (5 days):** Day 1: M00-M03 · Day 2: M04-M06 · Day 3: M07-M09 · Day 4: M10-M13 · Day 5: M14-M16
- **Evenings (3-4 weeks):** one module per session, checkpoint at the end of each
- **Certification-style prep:** focus on M02, M03, M05, M07, M08, M09, M10 and the review questions

## Review questions
1. Why are the Hyper-V hosts Server Core, and how do you administer them?
2. Which three infrastructure services, if broken, take down live migration?
3. Why is the storage network a *private* switch while management is *internal*?
