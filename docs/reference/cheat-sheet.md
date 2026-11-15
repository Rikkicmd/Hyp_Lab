# Hyper-V PowerShell Cheat Sheet

## Host
```powershell
Get-VMHost | fl *                                   # host config
Set-VMHost -VirtualMachinePath X -VirtualHardDiskPath Y
Get-VMHostSupportedVersion                          # VM config versions this host supports
Get-VMHostNumaNode
bcdedit /enum | findstr hypervisor                  # hypervisorlaunchtype / scheduler
```

## VMs
```powershell
New-VM -Name V -Generation 2 -MemoryStartupBytes 2GB -NewVHDPath C:\VMs\V.vhdx -NewVHDSizeBytes 60GB -SwitchName S
Set-VM V -ProcessorCount 4 -AutomaticCheckpointsEnabled $false -CheckpointType Production
Set-VMMemory V -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes 8GB -Buffer 20
Set-VMProcessor V -ExposeVirtualizationExtensions $true -CompatibilityForMigrationEnabled $true
Set-VMFirmware V -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Update-VMVersion V                                  # upgrade config version (one-way)
Get-VMIntegrationService V; Enable-VMIntegrationService V -Name 'Guest Service Interface'
Copy-VMFile V -SourcePath a -DestinationPath b -FileSource Host -CreateFullPath
Enter-PSSession -VMName V -Credential DOMAIN\User   # PowerShell Direct
Measure-VM V                                        # after Enable-VMResourceMetering
```

## Disks
```powershell
New-VHD -Path p.vhdx -SizeBytes 100GB -Dynamic         # -Fixed | -Differencing -ParentPath
Get-VHD p.vhdx | fl VhdType, ParentPath, FileSize, Size, FragmentationPercentage
Resize-VHD p.vhdx -SizeBytes 200GB; Optimize-VHD p.vhdx -Mode Full
Convert-VHD a.vhdx -DestinationPath b.vhdx -VHDType Fixed   # also flattens differencing chains
Merge-VHD child.avhdx -DestinationPath parent.vhdx
Add-VMHardDiskDrive V -ControllerType SCSI -Path d.vhdx
```

## Networking
```powershell
New-VMSwitch -Name SET -NetAdapterName N1,N2 -EnableEmbeddedTeaming $true -AllowManagementOS $true -MinimumBandwidthMode Weight
Add-VMNetworkAdapter -ManagementOS -Name LM -SwitchName SET
Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName LM -Access -VlanId 30
Set-VMNetworkAdapterVlan -VMName V -Trunk -AllowedVlanIdList 10-20 -NativeVlanId 0
Set-VMNetworkAdapter -VMName V -MacAddressSpoofing On -DhcpGuard On -RouterGuard On -DeviceNaming On
Set-VMNetworkAdapter -VMName V -MaximumBandwidth 1GB -MinimumBandwidthWeight 10
New-NetNat -Name NAT -InternalIPInterfaceAddressPrefix 10.0.0.0/24
```

## Checkpoints, export, import
```powershell
Checkpoint-VM V -SnapshotName X; Get-VMCheckpoint V; Restore-VMCheckpoint -VMName V -Name X; Remove-VMCheckpoint -VMName V -Name X
Export-VM V -Path E:\Export
Compare-VM -Path cfg.vmcx -Copy -GenerateNewId | % Incompatibilities
Import-VM -Path cfg.vmcx -Copy -GenerateNewId -VirtualMachinePath X -VhdDestinationPath Y
```

## Migration
```powershell
Enable-VMMigration; Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos -VirtualMachineMigrationPerformanceOption Compression
Add-VMMigrationNetwork 10.10.30.0/24
Move-VM V -DestinationHost H2 -IncludeStorage -DestinationStoragePath C:\VMs\V   # shared nothing
Move-VMStorage V -DestinationStoragePath D:\VMs\V
Move-ClusterVirtualMachineRole V -Node H2 -MigrationType Live
```

## Cluster
```powershell
Test-Cluster -Node H1,H2; New-Cluster -Name C -Node H1,H2 -StaticAddress IP -NoStorage
Get-ClusterNode; Get-ClusterNetwork | ft Name, Role, Address; Get-ClusterQuorum
Set-ClusterQuorum -DiskWitness 'Cluster Disk 1' | -FileShareWitness \\srv\share | -CloudWitness -AccountName a -AccessKey k
Get-ClusterAvailableDisk | Add-ClusterDisk; Add-ClusterSharedVolume 'Cluster Disk 2'
Get-ClusterSharedVolumeState                         # redirected I/O?
Add-ClusterVirtualMachineRole -VMName V
Suspend-ClusterNode H1 -Drain -Wait; Resume-ClusterNode H1 -Failback Immediate
Get-ClusterLog -Destination C:\Temp -TimeSpan 15 -UseLocalTime
(Get-ClusterGroup V).AntiAffinityClassNames = 'DCs'
Add-CauClusterRole -ClusterName C -DaysOfWeek Tuesday -WeeksOfMonth 3 -EnableFirewallRules
```

## Replica
```powershell
Set-VMReplicationServer -ReplicationEnabled $true -AllowedAuthenticationType Kerberos -ReplicationAllowedFromAnyServer $true -DefaultStorageLocation D:\Replica
Enable-VMReplication V -ReplicaServerName R -ReplicaServerPort 80 -AuthenticationType Kerberos -ReplicationFrequencySec 300 -RecoveryHistory 4
Start-VMInitialReplication V; Measure-VMReplication V; Get-VMReplication
Start-VMFailover V -AsTest; Stop-VMFailover V                     # test (on replica)
Start-VMFailover V -Prepare (primary) ; Start-VMFailover V ; Set-VMReplication V -Reverse ; Complete-VMFailover V
```

## iSCSI / MPIO
```powershell
New-IscsiServerTarget T -InitiatorIds 'IPAddress:x'; New-IscsiVirtualDisk p.vhdx -SizeBytes 100GB; Add-IscsiVirtualDiskTargetMapping T p.vhdx
New-IscsiTargetPortal -TargetPortalAddress IP; Connect-IscsiTarget -NodeAddress IQN -IsPersistent $true -IsMultipathEnabled $true
Enable-MSDSMAutomaticClaim -BusType iSCSI; Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy LQD; mpclaim -s -d
```

## S2D
```powershell
Enable-ClusterStorageSpacesDirect; Get-StoragePool S2D*; Get-PhysicalDisk; Get-StorageJob
New-Volume -FriendlyName V1 -FileSystem CSVFS_ReFS -StoragePoolFriendlyName S2D* -Size 1TB -ResiliencySettingName Mirror
Get-StorageFaultDomain -Type StorageScaleUnit | ? FriendlyName -eq H1 | Enable-StorageMaintenanceMode
```

## Security
```powershell
Set-VMKeyProtector V -NewLocalKeyProtector; Enable-VMTPM V; Set-VMSecurity V -EncryptStateAndVmMigrationTraffic $true
Get-HgsClientConfiguration; Get-HgsAttestationHostKey
```
