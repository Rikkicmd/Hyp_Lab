# Module 01: Host Preparation & Nested Virtualization

**Time:** 1 h · **Scripts:** `00-Test-HostReadiness.ps1`, `01-Install-HostPrereqs.ps1`

## Objectives
- Verify hardware and firmware requirements for Hyper-V
- Install the Hyper-V role and management tools the supported way
- Apply production host baseline settings
- Understand what nested virtualization needs from the parent host

## Concepts

### Hardware requirements
| Requirement | Why |
|---|---|
| 64-bit CPU with **SLAT** (Intel EPT / AMD RVI) | Mandatory since Server 2016: memory virtualization performance |
| **VT-x / AMD-V** enabled in UEFI | The hypervisor needs hardware virtualization |
| **DEP** (NX/XD bit) | Required by the hypervisor |
| TPM 2.0 + UEFI Secure Boot | Needed for host VBS/HVCI, guarded hosts, Credential Guard |
| ECC RAM, redundant NICs, HBA/RAID | Production expectations, not lab requirements |

`systeminfo` shows "Hyper-V Requirements" before the role is installed. After the role is installed it reports "A hypervisor has been detected".

### Root partition vs. guests
Once Hyper-V is installed, Windows itself becomes the **root (parent) partition** running on top of the hypervisor. Rules that follow from this:
- Don't install other roles on a Hyper-V host (no DC, no file server, no SQL). Keep it dedicated.
- Reserve memory for the root: roughly 2-4 GB plus about 1 GB per 10-20 VMs.
- Antivirus on the host **must** exclude VM files and processes, otherwise you get corrupted VHDX files and failed starts. The script applies Microsoft's documented exclusions.

### Host settings that matter
| Setting | Lab value | Production guidance |
|---|---|---|
| Default VM / VHD path | `D:\HVLab\VMs`, `D:\HVLab\Disks` | Never the OS volume. Use dedicated storage or CSV. |
| NUMA spanning | On | Turn off for latency-sensitive workloads that fit within one NUMA node |
| Enhanced Session Mode | On | Off on production servers (the host's console should not be used) |
| Power plan | n/a | High Performance on physical hosts |
| Host updates | n/a | Cluster-Aware Updating (Module 07) |

### Nested virtualization checklist
For a VM to run Hyper-V inside it, on the **parent** host:
1. VM version 8.0+ and the VM is **off** when you change the setting
2. `Set-VMProcessor -VMName X -ExposeVirtualizationExtensions $true`
3. **Static memory** (dynamic memory and runtime resize are not supported for nested hosts)
4. Networking for L2 guests: `Set-VMNetworkAdapter -MacAddressSpoofing On` *or* NAT inside the nested host
5. Inside the VM: install the Hyper-V role as on a physical server

## Build

```powershell
.\00-Test-HostReadiness.ps1
.\01-Install-HostPrereqs.ps1      # reboots once; run it again after reboot to apply host defaults
```

<details><summary>What the script does, step by step (manual equivalent)</summary>

```powershell
Install-WindowsFeature Hyper-V, Hyper-V-PowerShell, Hyper-V-Tools, RSAT-Clustering-PowerShell -IncludeManagementTools -Restart
# after reboot
Set-VMHost -VirtualMachinePath D:\HVLab\VMs -VirtualHardDiskPath D:\HVLab\Disks -EnableEnhancedSessionMode $true
Add-MpPreference -ExclusionExtension vhd,vhdx,avhd,avhdx,vsv,iso,rct,mrt,vmcx,vmrs,vmgs
Add-MpPreference -ExclusionProcess vmms.exe,vmwp.exe,vmcompute.exe
```
GUI path: Server Manager > Add Roles and Features > Hyper-V. The wizard also offers to create a virtual switch and set migration options. We skip that and do it deliberately in Modules 02 and 05.
</details>

## Exercises

**1. Read the hypervisor's view of the host.** Find logical processor count, total memory, and whether NUMA spanning is on.
<details><summary>Solution</summary>

```powershell
Get-VMHost | Format-List LogicalProcessorCount, MemoryCapacity, NumaSpanningEnabled
Get-VMHostNumaNode
```
</details>

**2. Check whether this host can run nested virtualization**, then explain why `Get-VMProcessor -VMName HV01` would show `ExposeVirtualizationExtensions : True` after Module 03.
<details><summary>Solution</summary>

`Get-CimInstance Win32_Processor | Select Name, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions` shows hardware support (blank once a hypervisor is running). Script 04 sets the flag on HV01-HV03 before first boot because it can only be changed while the VM is off.
</details>

**3. Defender exclusions.** List the exclusions and say which file extension, if scanned, would most likely break a running VM.
<details><summary>Solution</summary>

`Get-MpPreference | Select -Expand ExclusionExtension`. The answer is `.vhdx` / `.avhdx` (active disks), and `.vmrs` (runtime state).
</details>

**4. Stretch: Hyper-V scheduler type.** Find which hypervisor scheduler the host uses (classic, core, or root) and why core is the default since Server 2019.
<details><summary>Solution</summary>

`Get-WinEvent -FilterHashtable @{ProviderName='Microsoft-Windows-Hyper-V-Hypervisor'; Id=2} -MaxEvents 1`. The core scheduler mitigates side-channel attacks by never letting two VMs share a physical core's SMT threads. Change it with `bcdedit /set hypervisorschedulertype core|classic|root`.
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 1
```

## Review questions
1. Which CPU feature became mandatory for Hyper-V in Windows Server 2016?
2. Name three VM file types that antivirus must exclude, and the processes.
3. Why shouldn't a Hyper-V host also be a domain controller?
4. List the requirements for running Hyper-V inside a VM.
