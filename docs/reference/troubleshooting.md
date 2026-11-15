# Lab Build Troubleshooting

Problems you may hit while **building** the lab, as opposed to the training faults in Module 15. Every script logs to `<LabRoot>\Logs\lab.log`.

| Symptom | Likely cause | Fix |
|---|---|---|
| `00` reports VT-x/SLAT FAIL | Virtualization disabled in UEFI, or VBS/Device Guard owns it on a client OS | Enable Intel VT-x / AMD SVM in firmware. On Windows 11, Hyper-V and VBS coexist fine once the role is installed. |
| `03`: "Image ... not found on media" | Edition names differ by ISO language or version | Copy the exact `ImageName` from the table the script prints into `LabConfig.psd1` |
| `03`: `bcdboot failed` | ESP not formatted or no drive letters left | Free a drive letter. Re-run with `-Force`. |
| `04`: VM boots to "No operating system was loaded" / PXE | Boot order, or the Secure Boot template doesn't match | `Get-VMFirmware V`. The script sets the first boot device to the VHD. For Linux, use the UEFI CA template. |
| `04`: hangs at "Waiting for X to answer PowerShell Direct" | Still in OOBE (unattend not applied), or the password doesn't meet complexity rules | `vmconnect localhost X` to look. Check `C:\Windows\Panther\setupact.log` in the guest. Keep `AdminPassword` complex. |
| `04`: no adapter named Storage/Cluster | Device Naming off or the guest driver isn't ready yet | Re-run `04` for that VM (`-Name X`). It skips creation and redoes the NIC setup. |
| `05`: `Install-ADDSForest` fails on ForestMode | The ISO is older than Server 2025 | Change `Win2025` to `WinThreshold` in script 05 |
| `06`: Add-Computer "domain could not be contacted" | Member's DNS doesn't point to DC01, or DC01 is still booting | `Get-DnsClientServerAddress` in the guest. Re-run `06`. |
| `07`: Hyper-V install says the processor lacks virtualization | ExposeVirtualizationExtensions off, or the VM was running when it was set | Stop the VM, `Set-VMProcessor -ExposeVirtualizationExtensions $true`, start it |
| `07`: PowerShell Direct drops while creating SETswitch | Normal: the network briefly re-plumbs | The script continues. Re-run if it errored. It's idempotent. |
| `08`: no iSCSI disks on nodes | Storage NIC IPs differ from the target's InitiatorIds | `Get-IscsiServerTarget \| fl InitiatorIds` on STOR01 vs `Get-NetIPAddress -InterfaceAlias Storage` |
| `09`: Test-Cluster storage failures | iSCSI persistent reservations need both nodes connected | Fix `08` first. Disks must be visible on both nodes. |
| `09` or `12`: "Access is denied" / double-hop errors | The PowerShell Direct session can't delegate credentials to the other node | Run the failing block from MGMT01 logged on as `HVLAB\Administrator`, or `Enter-PSSession -VMName HV01` and run it interactively |
| `10 -WithOS`: Copy-VMFile fails | Guest Service Interface disabled or the destination folder is missing | `Enable-VMIntegrationService HV01 -Name 'Guest Service Interface'`. `-CreateFullPath` is already set. |
| `11`: Replica "cannot connect" | Firewall rule off, or DNS for HV03 | `Test-NetConnection hv03 -Port 80` from the primary |
| `13`: WAC download fails | No Internet through NAT, or the URL changed | Download the installer on the host and `Copy-VMFile` it to `MGMT01:C:\Temp\WindowsAdminCenter.exe`, then re-run |
| Everything slow | Disk I/O (HDD) or RAM pressure on the host | NVMe strongly recommended. Close other apps. Skip HV03 and HGS01 on 48 GB hosts. |
| Evaluation expired (180 days) | | `slmgr /rearm` in each guest (up to 5 times), or rebuild: the scripts make that cheap |

## Useful commands
```powershell
Get-Content D:\HVLab\Logs\lab.log -Tail 50
Get-VM | ft Name, State, Status, Uptime, MemoryAssigned
Get-WinEvent -LogName Microsoft-Windows-Hyper-V-VMMS-Admin -MaxEvents 30 | ft TimeCreated, Id, Message -Wrap
vmconnect localhost HV01
```
