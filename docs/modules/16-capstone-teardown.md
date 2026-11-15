# Module 16: Capstone & Teardown

**Time:** 4-8 h · **Script:** `99-Remove-Lab.ps1`

## Capstone brief

*Contoso Manufacturing* (a fictional company) is moving 25 servers off ageing hardware. You are the virtualization engineer. Using **only the lab** (the physical host and the scripts as building blocks, but your own design decisions), deliver the following.

### Requirements
1. **Design document** (1-3 pages): host count and sizing with N+1, networking (traffic classes, VLANs, SET), storage choice (SAN vs S2D) with justification, quorum, DR, backup, management and security. Use [design-decisions.md](../reference/design-decisions.md) as a reference, not a template.
2. **Build:** from a clean teardown, rebuild the environment **with at least three changes** from the default lab, for example:
   - a third cluster node (HV03 joins HVCLU01, and Replica goes to a new HV04, or skip Replica)
   - a file share witness on DC01 instead of a disk witness
   - a second CSV, with balanced ownership across nodes
   - live migration using SMB as the performance option
   - converged host vNICs on VLANs instead of separate private switches
   - VMs deployed from your Sysprepped template (Module 03) instead of the WIM image
3. **Operate:** run a CAU scan, drain each node in turn, do a test failover of a replicated VM, and take a backup and restore of one VM.
4. **Prove it:** run `Test-LabModule.ps1 -All` and explain any expected FAILs that come from your design changes. Then let a partner run `Invoke-LabFault.ps1 -Scenario Random` on your lab twice, and fix both faults within 30 minutes each.

### Assessment rubric
| Area | Pass | Distinction |
|---|---|---|
| Design | N+1 sizing correct, quorum correct | Trade-offs explicitly argued (cost/risk) |
| Build | Repeatable, scripted changes committed to `LabConfig.psd1`/scripts | Idempotent changes, validation extended for new checks |
| Operate | All four operations succeed | Documented runbooks for each |
| Troubleshoot | Both faults fixed | Root cause and prevention written up |

## Teardown

```powershell
.\Invoke-LabPower.ps1 -State Off            # optional, the remove script turns VMs off anyway
.\99-Remove-Lab.ps1 -KeepImages             # keep golden images for a fast rebuild
.\99-Remove-Lab.ps1                         # remove everything, including images
```

The script only deletes VMs whose Notes start with `HVLAB`, the `HVLAB-*` switches, the HVLAB NAT, and folders under `LabRoot`. Check afterwards:
```powershell
Get-VM; Get-VMSwitch; Get-NetNat
```
To remove Hyper-V from the host entirely: `Uninstall-WindowsFeature Hyper-V -Restart`.

## Where to go next
- **Azure Local (Azure Stack HCI)** evaluation in nested VMs, the next step after Module 11
- **AZ-800/AZ-801** (Windows Server Hybrid Administrator) exam objectives map closely to Modules 02-10 and 13
- **SCVMM** end to end (Module 12 optional path), then **Azure Arc** for hybrid management
- Automate your capstone with **DSC** or **Ansible** (`microsoft.ad` and `ansible.windows` collections)
