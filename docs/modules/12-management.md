# Module 12: Management Tooling

**Time:** 2 h (plus 2 h for the optional SCVMM section) · **Script:** `13-Install-ManagementTools.ps1`

## Objectives
- Manage Server Core hosts remotely with RSAT, Hyper-V Manager, Failover Cluster Manager and PowerShell
- Deploy and use Windows Admin Center for hosts and clusters
- Understand System Center Virtual Machine Manager's role, and optionally deploy it
- Script fleet operations with PowerShell remoting

## Concepts

### The toolset
| Tool | Scope | Use it for |
|---|---|---|
| **PowerShell** (Hyper-V, FailoverClusters, Storage modules) | Everything | Automation, bulk changes, the source of truth |
| Hyper-V Manager | Per host | Quick VM tasks, console, settings |
| Failover Cluster Manager | Per cluster | Roles, networks, storage, validation |
| **Windows Admin Center** | Hosts, clusters, HCI, VMs (browser) | Modern GUI for Server Core. Free. Azure hybrid integration. |
| **SCVMM** | Whole fabric (many clusters) | Templates, library, logical networks, RBAC/tenants, bare-metal host deployment |
| Azure Arc | Hybrid | Policy, monitoring, updates from Azure |

Remote management model: **you never log on to a host.** MGMT01 (a Privileged Access Workstation in production) holds the tools, and hosts accept WinRM/WMI from it.

### SCVMM concepts (for interviews, even if you skip the install)
- **Fabric:** host groups, hosts and clusters, storage providers (SMI-S), logical networks, network sites, VM networks, IP pools, logical switches with uplink port profiles
- **Library:** VHDX, ISOs, scripts. **Templates** = hardware profile + guest OS profile + VHDX. **Service templates** = multi-tier apps.
- **Cloud and RBAC:** private clouds with quotas, delegated admins, tenant administrators
- **Bare-metal deployment:** PXE plus WDS to build new Hyper-V hosts automatically
- Requires SQL Server, an AD service account and DKM container, and about 8-16 GB RAM

## Build
```powershell
.\13-Install-ManagementTools.ps1
# then: vmconnect localhost MGMT01 (Enhanced Session), sign in as HVLAB\hvadmin
```
Open Hyper-V Manager and connect to HV01, HV02 and HV03. Open Failover Cluster Manager and connect to HVCLU01. Open Edge at `https://mgmt01.hvlab.internal` (accept the self-signed certificate warning).

## Exercises

**1. Windows Admin Center: add resources.** Add HV01, HV02, HV03 and the cluster HVCLU01. Use "Manage as" with `HVLAB\hvadmin`.
<details><summary>Solution</summary>

All connections > Add > Server (hv01.hvlab.internal...) and Add > Server cluster (hvclu01.hvlab.internal). If the cluster connection asks for CredSSP, accept it in the lab, or rely on the KCD set by script 07.
</details>

**2. Create a VM from WAC** on the cluster (512 MB, Gen 2, no OS, on CSV01) and make it highly available in the wizard. Live-migrate it from WAC.
<details><summary>Solution</summary>

Cluster > Virtual machines > Add > New. Choose the path `C:\ClusterStorage\CSV01`. After creation: Manage > Move > Live migration.
</details>

**3. PowerShell remoting at scale.** From MGMT01, in one command, collect host name, VM count, memory free and Hyper-V version from all three hosts into a table.
<details><summary>Solution</summary>

```powershell
Invoke-Command -ComputerName HV01,HV02,HV03 -ScriptBlock {
  [pscustomobject]@{ Host=$env:COMPUTERNAME; VMs=(Get-VM).Count
    FreeGB=[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,1)
    Version=(Get-VMHostSupportedVersion -Default).Version }
} | ft Host, VMs, FreeGB, Version
```
</details>

**4. Remote console.** Connect to SHELL01's console from MGMT01 without RDP.
<details><summary>Solution</summary>

`vmconnect.exe HV01 SHELL01` (use the current owner), Hyper-V Manager > Connect, or WAC > VM > Connect.
</details>

**5. Optional: SCVMM 2025 evaluation.** Build a VMM server on a new VM and bring HVCLU01 under management.
<details><summary>Guided outline</summary>

1. On the physical host: `.\04-New-LabVMs.ps1` after adding a `VMM01` entry (Desktop, 4 vCPU, 8 GB static, IP .60) to `LabConfig.psd1`, then `.\06-Join-LabDomain.ps1 -Name VMM01`.
2. Download the **SQL Server 2022 Developer/Evaluation** and **SCVMM 2025 Evaluation** media through the NAT from Microsoft's Evaluation Center.
3. Create `HVLAB\svc-vmm` and a DKM container `CN=VMMDKM,DC=hvlab,DC=internal`. Make svc-vmm a local admin on VMM01 and the hosts.
4. Install the Windows ADK (Deployment Tools + WinPE), then SQL (default instance), then VMM Management Server + Console.
5. In the VMM console: Fabric > Add Resources > Hyper-V Hosts and Clusters > Windows Server computers in a trusted domain > `HVCLU01`, using a Run As account.
6. Create a logical network "HVLAB-Mgmt" (10.10.0.0/24) with an IP pool, a VM network, and a library share. Create a VM template from `Templates\WS2025-Custom-Full.vhdx` (Module 03), then deploy a VM to the cluster from it.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 12
```

## Review questions
1. Why use a dedicated management workstation instead of the hosts' consoles?
2. What does WAC need to manage a cluster without CredSSP?
3. Name four SCVMM fabric objects and what they represent.
4. When does an organization outgrow Hyper-V Manager + FCM + WAC?
