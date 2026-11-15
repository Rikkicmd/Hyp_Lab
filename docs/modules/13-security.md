# Module 13: Hyper-V Security

**Time:** 2 h · **Script:** `14-New-HostGuardian.ps1` (optional, needs HGS01)

## Objectives
- Harden Hyper-V hosts and the management plane
- Use Secure Boot, vTPM and encryption for VMs
- Understand guarded fabric, HGS and Shielded VMs
- Delegate safely with Just Enough Administration (JEA)

## Concepts

### Threat model
Whoever controls the **host** controls every VM: they can copy VHDX files, attach debuggers, read memory. So you protect the host and management plane first, and protect VMs from the fabric admin where needed.

### Host hardening checklist
- Server Core, dedicated role, separate admin accounts, PAW/jump host (MGMT01)
- Hosts in their own OU with a security baseline GPO (Microsoft Security Compliance Toolkit)
- **VBS + HVCI** (memory integrity), Credential Guard, Secure Boot, TPM 2.0
- Management network isolated. Firewall allows WinRM/WMI only from management subnets.
- Live migration and SMB traffic encrypted or isolated (`Set-SmbServerConfiguration -EncryptData`, `Set-VMHost -VirtualMachineMigrationPerformanceOption SMB` with SMB encryption)
- Patch with CAU. Monitor with Defender for Servers / Microsoft Sentinel.

### VM-level protection
| Feature | Protects against | Needs |
|---|---|---|
| Secure Boot | Bootkits, unsigned boot loaders | Gen 2 |
| **vTPM** | Lets the guest use BitLocker, Credential Guard, Windows 11 requirements | Key protector (local or HGS) |
| Encrypt state and migration traffic | Theft of saved state / LM traffic | vTPM |
| **Shielded VM** | Fabric admins: no console, no debugging, encrypted disks/state, runs only on healthy guarded hosts | HGS + guarded hosts + shielding data |

### Guarded fabric and HGS
- **HGS** (own forest, usually a 3-node cluster) provides **attestation** (is this host healthy and authorized?) and **key protection** (releases VM keys only to healthy hosts).
- Attestation modes: **TPM-trusted** (measures boot and code-integrity policy, strongest) or **host key** (a key pair per host, simpler). AD mode is deprecated.
- Microsoft has positioned guarded fabric as a mature/maintenance-mode feature in recent releases. Confirm current support before you design new deployments, but the concepts (attestation, key release, confidential VMs) carry over directly to Azure confidential computing.

> **Nested lab caveat:** HGS deployment and host registration work in the lab, but nested guarded hosts may report attestation failures because nested VMs lack IOMMU and full VBS. That is expected. The hands-on encryption work uses vTPM with a local key protector.

### JEA
A constrained PowerShell endpoint that runs as a virtual admin account but only exposes the cmdlets and parameters you allow. This is the standard way to give operators "restart VMs but nothing else".

## Build (optional HGS)
```powershell
.\04-New-LabVMs.ps1 -IncludeOptional -Name HGS01
.\14-New-HostGuardian.ps1
```
Without HGS01, still do exercises 1, 2, 4 and 5.

## Exercises

**1. vTPM without HGS.** Create a Gen 2 VM on HV03 with a local key protector and vTPM, and enable encryption of state and migration traffic. Then try to live-migrate it to the cluster. What happens and why?
<details><summary>Solution</summary>

```powershell
New-VM -Name TPMTEST -Generation 2 -MemoryStartupBytes 512MB -NewVHDPath C:\VMs\Disks\TPMTEST.vhdx -NewVHDSizeBytes 10GB
Set-VMKeyProtector -VMName TPMTEST -NewLocalKeyProtector
Enable-VMTPM -VMName TPMTEST
Set-VMSecurity -VMName TPMTEST -EncryptStateAndVmMigrationTraffic $true
```
The migration fails to start the VM on the destination: the local key protector uses the "UntrustedGuardian" certificates *of HV03*. Export the `UntrustedGuardian` certificates from HV03 (`Shielded VM Local Certificates` store, with private keys) and import them on the destination to make it work. This is exactly the problem HGS solves at scale.
</details>

**2. JEA endpoint for operators.** On HV01, create a JEA endpoint `HVOperator` that lets `HVLAB\HV-Operators` run only `Get-VM`, `Start-VM`, `Stop-VM`, `Restart-VM` and `Get-ClusterGroup`.
<details><summary>Solution</summary>

```powershell
$mod = 'C:\Program Files\WindowsPowerShell\Modules\HVLabJEA'
New-Item -ItemType Directory "$mod\RoleCapabilities" -Force
New-ModuleManifest "$mod\HVLabJEA.psd1"
New-PSRoleCapabilityFile -Path "$mod\RoleCapabilities\VMOperator.psrc" -VisibleCmdlets 'Get-VM','Start-VM','Stop-VM','Restart-VM','Get-ClusterGroup'
New-PSSessionConfigurationFile -Path C:\Temp\HVOperator.pssc -SessionType RestrictedRemoteServer -RunAsVirtualAccount -RoleDefinitions @{ 'HVLAB\HV-Operators' = @{ RoleCapabilities = 'VMOperator' } }
Register-PSSessionConfiguration -Name HVOperator -Path C:\Temp\HVOperator.pssc -Force
# test from MGMT01 as hvop:
Enter-PSSession HV01 -ConfigurationName HVOperator ; Get-Command
```
</details>

**3. (HGS) Inspect attestation.** On HGS01 list registered host keys and the attestation policies. On HV01 show the client status and explain any `AttestationSubstatus` flags.
<details><summary>Solution</summary>

HGS01: `Get-HgsAttestationHostKey; Get-HgsAttestationPolicy`. HV01: `Get-HgsClientConfiguration`. In nested labs you will often see substatus values like `IommuMissing` or `VirtualSecureModeNotRunning`, which match the caveat above.
</details>

**4. Secure Boot template.** Create a Gen 2 VM for Linux and pick the correct Secure Boot template. What happens with the Windows template?
<details><summary>Solution</summary>

`Set-VMFirmware -VMName LNX -SecureBootTemplate MicrosoftUEFICertificateAuthority`. With `MicrosoftWindows`, most Linux shim loaders fail to boot with "image's hash and certificate are not allowed".
</details>

**5. Restrict management to the management subnet.** On HV03, scope the WinRM firewall rules to 10.10.0.0/24 only.
<details><summary>Solution</summary>

`Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' | Set-NetFirewallRule -RemoteAddress 10.10.0.0/24`
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 13
```

## Review questions
1. Why is the Hyper-V host the most important asset to protect?
2. Compare TPM-trusted and host-key attestation.
3. What does a Shielded VM prevent a fabric admin from doing?
4. Why did the vTPM VM fail to start after migration, and how does HGS fix that?
5. What does JEA's RunAsVirtualAccount mean?
