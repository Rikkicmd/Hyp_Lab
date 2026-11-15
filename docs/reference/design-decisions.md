# Design Decisions: Lab vs Production

Why the lab is built the way it is, and what you would do differently on real hardware. Use this as a reference for the Module 16 design document.

## Compute
| Decision | Lab | Production | Why |
|---|---|---|---|
| Host OS | WS2025 Core (nested) | WS2025 Datacenter Core (or Azure Local) | Datacenter gives unlimited Windows VM rights, S2D, Storage Replica, SDN, Shielded VMs |
| Cluster size | 2 nodes | 2-16 nodes (64 max). 3+ preferred for maintenance headroom. | N+1 capacity. Patching one node out of two leaves no redundancy. |
| Memory | 12 GB static per node | 256 GB-2 TB per node, sized for N+1 | |
| CPU | 4 vCPU | 2 sockets, high core count. Watch Windows Server per-core licensing. | |

## Networking
| Decision | Lab | Production |
|---|---|---|
| Physical design | Internal + private vSwitches on one host | 2+ x 25 GbE per host, SET, converged vNICs or dedicated storage NICs |
| Mgmt / Cluster / LM / Storage | Separate switches/subnets | VLANs per traffic class over SET, QoS (DCB for RDMA) |
| Live migration | Compression over the Cluster network | SMB + SMB Direct on 25 GbE+ RDMA, or Compression on 10 GbE |
| Jumbo frames | Not configured | 9014 on storage/LM, end to end |
| Internet | WinNAT on host | Proxy/firewall. Hosts often have no direct Internet. |

## Storage
| Decision | Lab | Production |
|---|---|---|
| Model | iSCSI Target Server (software) or S2D track | Enterprise SAN (FC/iSCSI) **or** S2D/Azure Local on validated hardware |
| Paths | 1 (exercise adds 2) | 2+ physical paths, separate switches/fabrics |
| CSV filesystem | NTFS on SAN, ReFS on S2D | Same |
| Witness | Disk witness (iSCSI), file share witness (S2D) | Disk witness with SAN. Cloud witness for S2D/stretched. |

## Availability and DR
| Decision | Lab | Production |
|---|---|---|
| HA | Failover cluster | Same, plus guest clustering / app-level HA (SQL AG, DAG) for tier-1 apps |
| DR | Hyper-V Replica to HV03 | Replica or ASR to a secondary site/Azure, Storage Replica for stretch clusters. Regular DR tests. |
| DCs | 1 DC (VM) | 2+ DCs per site, at least one outside the cluster it serves |

## Backup
A sample answer for the Module 10 design task:

| Tier | Examples | RPO | RTO | Method |
|---|---|---|---|---|
| 1 | ERP DB, file server | 15 min (Replica 30 s) | 1 h | Hourly app-consistent backups with log backup + Hyper-V Replica |
| 2 | App servers, web | 24 h | 4 h | Nightly VM backup (RCT incremental) |
| 3 | Test/dev | 7 days | 2 days | Weekly |

- 30 daily, 12 monthly, 7 yearly retention. One copy immutable or offsite (object lock, tape, or a cloud vault).
- **Monthly restore tests** of one VM per tier into an isolated network. Documented.
- Replica protects against site loss. Backup protects against corruption, deletion and ransomware. You need both.
- Back up DCs with system-state-aware backup. Never restore DCs from checkpoints in production.

## Management and security
| Decision | Lab | Production |
|---|---|---|
| Admin access | MGMT01 jump box, shared Administrator | PAW, tiered admin model, MFA, LAPS, JEA for operators, no shared accounts |
| Tools | RSAT + WAC (+ optional SCVMM) | WAC/Azure Arc for most. SCVMM for large multi-cluster fabrics. |
| Host security | Defaults + exercises | Security baseline GPO, VBS/HVCI, Credential Guard, Secure Boot, TPM 2.0, Defender for Servers |
| Patching | Manual / CAU exercise | CAU self-updating with maintenance windows, firmware via vendor tools |
| Passwords | Published, weak | Vaulted, rotated, gMSAs for services |
