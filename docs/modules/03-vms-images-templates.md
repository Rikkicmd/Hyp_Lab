# Module 03: VMs, Golden Images & Templates

**Time:** 3 h (much of it waiting on image builds) · **Scripts:** `03-New-GoldenImage.ps1`, `04-New-LabVMs.ps1`

## Objectives
- Choose VM generation, configuration version, memory and processor settings correctly
- Understand VHDX formats and when to use fixed, dynamic and differencing disks
- Build golden images two ways: from the WIM, and with Sysprep
- Automate first boot with unattend.xml and configure guests over PowerShell Direct

## Concepts

### Generation 1 vs Generation 2
| | Gen 1 | **Gen 2 (default choice)** |
|---|---|---|
| Firmware | BIOS | UEFI with Secure Boot |
| Boot disk | IDE | SCSI (hot-add data disks on SCSI for both) |
| Max boot disk | 2 TB (MBR) | 64 TB (GPT) |
| vTPM, Shielded VM, Credential Guard | No | Yes |
| Legacy NIC / PXE | Legacy adapter | Synthetic adapter PXE |
| Use when | Old 32-bit OSes, imported legacy appliances | Everything modern |

Generation **cannot be changed** after creation. Secure Boot template: `MicrosoftWindows` for Windows, `MicrosoftUEFICertificateAuthority` for most Linux.

### Disks
| Type | Pros | Cons | Use |
|---|---|---|---|
| Fixed VHDX | Predictable performance, no fragmentation | Full size allocated up front | Historically SQL/Exchange. Since 2016 dynamic is close in performance. |
| **Dynamic VHDX** | Thin, fast to create | Can overcommit storage | General default |
| **Differencing** | Instant clone from a parent, tiny | Parent must never change; chain adds I/O | Labs, VDI, test. Not for long-lived production servers. |
| Pass-through | Raw disk | No checkpoints, no live storage migration | Avoid (legacy) |
| Shared VHDX / **VHD Set (.vhds)** | Guest clustering | Needs CSV/SOFS | Guest failover clusters |

VHDX advantages over VHD: 64 TB, 4K sector alignment, corruption-resilient metadata log, online resize.

### Memory
- **Dynamic memory:** Startup, Minimum, Maximum, Buffer %, Weight. Good for most server roles. Not for nested hosts, and use with care for SQL/Exchange (vendor guidance).
- **Runtime resize:** change static memory while the VM runs (Gen 2, Windows 2016+ guests).
- **NUMA:** large VMs should respect host NUMA topology (`Get-VMHostNumaNode`).

### Golden image strategies
1. **From install.wim** (what script 03 does): the WIM in Microsoft media is already generalized. Apply it to a GPT VHDX with `Expand-WindowsImage`, then `bcdboot`. Repeatable, no VM needed. This is the technique behind Convert-WindowsImage, AutomatedLab and MDT's VHD deployment.
2. **Sysprep "reference VM"**: install, patch, customize, `sysprep /generalize /oobe /shutdown /mode:vm`, keep the VHDX. This is how most organizations bake patched templates. (`/mode:vm` skips hardware re-detection when the image will only ever run on Hyper-V.)
3. **SCVMM VM templates / library**: wraps option 2 with profiles and customization (see Module 12).

Either way, **mark the parent read-only** and never boot it again after children exist.

### First-boot automation
- `unattend.xml` in `\Windows\Panther\` on the child disk is picked up on first boot (specialize + oobeSystem passes): computer name, admin password, locale, skip OOBE.
- After boot, **PowerShell Direct** (`Invoke-Command -VMName`) configures the guest over VMBus with no network needed.
- **Device Naming** (`Set-VMNetworkAdapter -DeviceNaming On`) shows the vNIC name inside the guest, so scripts can match "Storage" to the right adapter reliably.

### Integration services
Heartbeat, Shutdown, Time Sync, Data Exchange (KVP), VSS (backup), Guest Service Interface (`Copy-VMFile`). Windows guests get updates through Windows Update. **Domain controllers:** keep Time Sync *enabled* for boot-time correction, but make the PDC emulator sync from an external NTP source (`w32tm /config /manualpeerlist:... /syncfromflags:manual /reliable:yes`).

## Build
```powershell
.\03-New-GoldenImage.ps1         # ~20-40 min, builds WS2025-Desktop.vhdx and WS2025-Core.vhdx
.\04-New-LabVMs.ps1              # creates DC01, MGMT01, STOR01, HV01, HV02, HV03 and sets IPs
Get-VM | ft Name, State, Generation, Version, MemoryAssigned
Get-VMHardDiskDrive -VMName DC01 | Get-VHD | fl Path, VhdType, ParentPath, FileSize, Size
```
If `03` cannot find the image name, it prints the indexes on your ISO. Copy the exact name into `LabConfig.psd1`.

## Exercises

**1. Inspect a differencing chain.** How much space does DC01's OS disk really use compared with its parent? What happens if you write-enable and boot the parent?
<details><summary>Solution</summary>

`Get-VHD` on the child shows `FileSize` in MB versus GB for the parent. Booting or modifying the parent changes its blocks under every child. Children then fail to open with a "parent disk modified" ID mismatch error, or worse, silently corrupt. That's why script 03 sets the parent read-only.
</details>

**2. Build a Sysprepped template the classic way.** Create `TPL-WS2025` from the Desktop parent, customize it (install the `Telnet-Client` feature and create `C:\Tools`), generalize it, and keep its disk as `Templates\WS2025-Custom.vhdx`.
<details><summary>Solution</summary>

```powershell
$p = 'D:\HVLab\Templates\WS2025-Custom.vhdx'
New-VHD -Path $p -ParentPath D:\HVLab\Images\WS2025-Desktop.vhdx -Differencing
New-VM -Name TPL-WS2025 -Generation 2 -MemoryStartupBytes 2GB -VHDPath $p -SwitchName HVLAB-Mgmt
Start-VM TPL-WS2025; vmconnect localhost TPL-WS2025   # finish OOBE manually, then:
# inside the VM:
Install-WindowsFeature Telnet-Client; mkdir C:\Tools
& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /mode:vm
# on host, after it shuts down:
Remove-VM TPL-WS2025 -Force
Convert-VHD -Path $p -DestinationPath D:\HVLab\Templates\WS2025-Custom-Full.vhdx -VHDType Dynamic   # merge into a standalone template
```
`Convert-VHD` flattens the chain so the template no longer depends on the parent. Validation looks for any `.vhdx` in `Templates\`.
</details>

**3. Change memory live.** DC01 uses dynamic memory. Raise its maximum to 6 GB while it runs. Then try to change HV01's memory while it runs. What happens and why?
<details><summary>Solution</summary>

`Set-VMMemory DC01 -MaximumBytes 6GB` works online (raising the maximum is allowed). HV01 is a nested host. Runtime memory resize isn't supported with virtualization extensions exposed, so you must shut it down first.
</details>

**4. Gen 1 vs Gen 2.** Create a Gen 1 VM and a Gen 2 VM with no disks. Compare `Get-VMFirmware`/`Get-VMBios`, the controllers, and the boot order. Remove them afterwards.
<details><summary>Solution</summary>

Gen 1: `Get-VMBios` works and shows IDE plus a legacy NIC option. Gen 2: `Get-VMFirmware` shows SecureBoot and a SCSI controller, and Get-VMBios errors.
</details>

**5. Copy a file into a guest without networking.**
<details><summary>Solution</summary>

`Copy-VMFile -Name STOR01 -SourcePath C:\Windows\notepad.exe -DestinationPath C:\Temp\notepad.exe -FileSource Host -CreateFullPath` (needs the Guest Service Interface integration service, which script 04 enables).
</details>

**6. Expand a disk online.** Add 20 GB to STOR01's data disk while it runs and extend the volume inside the guest.
<details><summary>Solution</summary>

```powershell
$d = Get-VMHardDiskDrive STOR01 | Where Path -like '*Data1*'; Resize-VHD -Path $d.Path -SizeBytes 220GB
Invoke-Command -VMName STOR01 -Credential HVLAB\Administrator { Update-HostStorageCache; $max=(Get-PartitionSupportedSize -DriveLetter E).SizeMax; Resize-Partition -DriveLetter E -Size $max }
```
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 3
```

## Review questions
1. Give three reasons to choose Gen 2.
2. When is a differencing disk inappropriate?
3. What does `sysprep /mode:vm` change?
4. How does PowerShell Direct reach a VM with no network?
5. Why are dynamic memory and nested virtualization incompatible?
