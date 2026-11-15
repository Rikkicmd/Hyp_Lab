# Module 04: Infrastructure Services (AD DS, DNS, DHCP)

**Time:** 1.5 h · **Scripts:** `05-Initialize-DomainController.ps1`, `06-Join-LabDomain.ps1`

## Objectives
- Deploy a forest/domain designed to support a Hyper-V fabric
- Configure DNS (forwarders, reverse zones, scavenging) and DHCP correctly
- Organize computer and user objects for delegation and Group Policy
- Know the virtualization-specific rules for virtual domain controllers

## Concepts

### What Hyper-V needs from AD and DNS
| Feature | Dependency |
|---|---|
| Failover clustering | Cluster Name Object (CNO) and VCOs in AD; DNS A records |
| Live migration (Kerberos) | Computer accounts, SPNs, constrained delegation |
| Hyper-V Replica (Kerberos) | Name resolution and authentication between sites |
| WAC / SCVMM | Kerberos, gMSA, SPNs |

Rule of thumb: **every cluster needs a DC it can reach without depending on itself.** If your only DCs run as VMs on the cluster they authenticate, a full cold start can deadlock. (Server 2012+ clusters can start without AD, but plan for it anyway.) In production, run at least one DC on separate hardware or another cluster, and use anti-affinity to split virtual DCs.

### Virtual DC rules
- Since Server 2012, **VM-GenerationID** protects virtual DCs from USN rollback when they are restored from a checkpoint. Even so, don't use checkpoints as DC backups. Use system-state backup.
- Keep DC VMs on their own host or use anti-affinity. Set `AutomaticStartAction` to Start with **no delay**, and give other VMs a delay.
- Time: the PDC emulator syncs to external NTP. Other DCs and members follow the domain hierarchy.

### OU design for a fabric
```
hvlab.internal
├─ Hyper-V Hosts       GPO: host hardening, firewall, WinRM, CredSSP off, Defender exclusions
├─ Lab Servers         GPO: member server baseline
├─ Service Accounts    svc-backup, gMSAs
├─ Lab Users           hvadmin, hvop, student
└─ Lab Groups          HV-Admins, HV-Operators, Cluster-Admins
```
Pre-staging computer objects and delegating "Create Computer objects" on the hosts' OU to the CNO is the standard approach when cluster admins are not Domain Admins.

### DHCP on a fabric
Production hosts use **static IPs**. DHCP in the lab serves throwaway and L2 guest VMs. Authorization in AD stops rogue DHCP servers from starting. Options 003 (router), 006 (DNS) and 015 (domain).

## Build
```powershell
.\05-Initialize-DomainController.ps1
.\06-Join-LabDomain.ps1
.\Invoke-LabCheckpoint.ps1 -Action Save -Name Baseline-Domain      # recommended save point
```

<details><summary>Manual equivalent (on DC01)</summary>

```powershell
Install-WindowsFeature AD-Domain-Services, DNS, DHCP -IncludeManagementTools
Install-ADDSForest -DomainName hvlab.internal -DomainNetbiosName HVLAB -ForestMode Win2025 -DomainMode Win2025 -InstallDns
Add-DnsServerPrimaryZone -NetworkId 10.10.0.0/24 -ReplicationScope Forest
Set-DnsServerForwarder 10.10.0.1
Add-DhcpServerInDC -DnsName dc01.hvlab.internal -IPAddress 10.10.0.10
Add-DhcpServerv4Scope -Name HVLAB-Clients -StartRange 10.10.0.100 -EndRange 10.10.0.199 -SubnetMask 255.255.255.0
Set-DhcpServerv4OptionValue -ScopeId 10.10.0.0 -Router 10.10.0.1 -DnsServer 10.10.0.10 -DnsDomain hvlab.internal
```
</details>

## Exercises

**1. DNS health.** From HV01, confirm the SRV records that domain members use to find a DC, and run `dcdiag` on DC01.
<details><summary>Solution</summary>

`Resolve-DnsName _ldap._tcp.dc._msdcs.hvlab.internal -Type SRV` on HV01. `dcdiag /test:dns /v` on DC01.
</details>

**2. Time hierarchy.** Configure DC01 (PDC) to sync from `time.windows.com`, and confirm HV01 syncs from DC01.
<details><summary>Solution</summary>

DC01: `w32tm /config /manualpeerlist:time.windows.com,0x8 /syncfromflags:manual /reliable:yes /update; Restart-Service w32time`. HV01: `w32tm /query /source` should return `DC01.hvlab.internal`.
</details>

**3. Pre-stage a cluster computer account** for a future cluster `HVCLU02` in `OU=Hyper-V Hosts`, disabled, and grant `HV01$` full control. Why is it disabled?
<details><summary>Solution</summary>

```powershell
New-ADComputer -Name HVCLU02 -Path 'OU=Hyper-V Hosts,DC=hvlab,DC=internal' -Enabled $false
$acl = Get-Acl 'AD:CN=HVCLU02,OU=Hyper-V Hosts,DC=hvlab,DC=internal'
$sid = (Get-ADComputer HV01).SID
$acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $sid,'GenericAll','Allow'))
Set-Acl -AclObject $acl 'AD:CN=HVCLU02,OU=Hyper-V Hosts,DC=hvlab,DC=internal'
```
Disabled tells the cluster wizard the CNO is pre-staged and unused. The cluster enables it when it is created.
</details>

**4. GPO for hosts.** Create a GPO linked to `OU=Hyper-V Hosts` that enables the Windows Remote Management firewall rules and sets the power plan to High Performance.
<details><summary>Solution</summary>

From MGMT01 (after Module 12) in GPMC, or: `New-GPO -Name 'HV Host Baseline' | New-GPLink -Target 'OU=Hyper-V Hosts,DC=hvlab,DC=internal'`. Then edit: Computer Config > Policies > Windows Settings > Security > Windows Defender Firewall, and Admin Templates > System > Power Management > Select an active power plan.
</details>

**5. DHCP reservation.** Reserve 10.10.0.150 for a test VM's MAC address and check that the lease is issued.
<details><summary>Solution</summary>

`Add-DhcpServerv4Reservation -ScopeId 10.10.0.0 -IPAddress 10.10.0.150 -ClientId <MAC with dashes> -Name TEST01`. Then `Get-DhcpServerv4Lease -ScopeId 10.10.0.0`.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 4
```

## Review questions
1. Why is a cluster that hosts all of its own DCs risky, and how do you mitigate it?
2. What protects a virtual DC from USN rollback?
3. What is a CNO, and why might you pre-stage it?
4. Why do Hyper-V hosts use static IPs?
