# Screenshots of the running lab

The diagrams in the main README are rendered from the HTML sources in [`docs/images/src`](../images/src). Re-render them with `node render.js` in that folder (needs Node.js and Playwright).

This folder holds **real screenshots taken from a working build**. They are captured on the first full build, because the lab has to run on a Windows Hyper-V host. Use the file names below so the README and modules can link to them.

## Capture list

| # | File name | Where / how | What it should show |
|---|---|---|---|
| 1 | `01-host-readiness.png` | Host, `.\00-Test-HostReadiness.ps1` | The PASS/WARN/FAIL table |
| 2 | `02-hyperv-manager-vms.png` | Host, Hyper-V Manager | DC01, MGMT01, STOR01, HV01-03 running |
| 3 | `03-virtual-switches.png` | Host, Virtual Switch Manager | HVLAB-Mgmt (internal), HVLAB-Storage and HVLAB-Cluster (private) |
| 4 | `04-differencing-disk.png` | Host, Inspect Disk on DC01's VHDX | Type Differencing, parent `WS2025-Core.vhdx` |
| 5 | `05-hv01-processor.png` | Host, `Get-VMProcessor HV01 \| fl *` | `ExposeVirtualizationExtensions : True` |
| 6 | `06-ad-users-computers.png` | MGMT01, ADUC | OUs: Hyper-V Hosts, Lab Servers, Lab Users… |
| 7 | `07-dhcp-scope.png` | MGMT01, DHCP console | HVLAB-Clients scope active with options |
| 8 | `08-iscsi-target.png` | MGMT01, Server Manager > File and Storage Services > iSCSI | Target with two LUNs and two initiators |
| 9 | `09-cluster-validation.png` | Report `HVLAB-Validation.htm` | Summary page |
| 10 | `10-fcm-nodes-networks.png` | MGMT01, Failover Cluster Manager | Nodes Up, networks Mgmt/Cluster/Storage with roles |
| 11 | `11-fcm-csv.png` | Failover Cluster Manager > Disks | CSV01 + Witness Disk |
| 12 | `12-fcm-roles.png` | Failover Cluster Manager > Roles | SHELL01/02 (WEB01/APP01) with owner nodes |
| 13 | `13-live-migration.png` | FCM during a live migration | "Live Migrating, xx%" status |
| 14 | `14-replica-health.png` | Hyper-V Manager on HV03, Replication Health | Health Normal |
| 15 | `15-wac-cluster.png` | MGMT01, Windows Admin Center | Cluster dashboard for HVCLU01 |
| 16 | `16-validation-results.png` | Host, `Test-LabModule.ps1 -All` | PASS/FAIL table |
| 17 | `17-fault-ticket.png` | Host, `Invoke-LabFault.ps1 -Scenario Random` | The magenta ticket text |

## Tips
- Take them at 100% DPI scaling and crop to the relevant window. Keep them under about 300 KB each (PNG).
- Blank out anything personal, such as the host name or user name, if the repository is public.
- To add one to the main README: `![Failover Cluster Manager](docs/screenshots/10-fcm-nodes-networks.png)`
