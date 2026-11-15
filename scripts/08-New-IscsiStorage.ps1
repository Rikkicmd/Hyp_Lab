#Requires -Version 5.1
<#
.SYNOPSIS
    Module 06 - Builds a software SAN: iSCSI Target Server on STOR01, MPIO initiators on HV01/HV02.
.DESCRIPTION
    STOR01  : data disk -> E:\iSCSI, iSCSI Target Server role, one target with two LUNs (CSV + witness),
              access restricted to the cluster nodes' storage-network IPs
    HV01/02 : MPIO with automatic iSCSI claim (round robin), persistent sessions bound to the storage NIC
    HV01    : initializes and formats the LUNs so the cluster can claim them in script 09
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$c = $cfg.Cluster
$nodes = $c.Nodes
$targetIP = Get-LabIP -VMName STOR01 -Net Storage
$initiatorIds = @($nodes | ForEach-Object { 'IPAddress:' + (Get-LabIP -VMName $_ -Net Storage) })

Invoke-LabCommand -VMName STOR01 -Domain -Activity 'Prepare data disk and iSCSI Target Server' `
    -ArgumentList $c.IscsiTarget, $initiatorIds, $c.CsvLunSize, $c.WitnessSize, $targetIP -ScriptBlock {
    param($targetName, $ids, $csvSize, $witnessSize, $portalIP)
    $raw = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
    if ($raw) {
        $raw | Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter E -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'iSCSI' -AllocationUnitSize 65536 -Confirm:$false | Out-Null
    }
    New-Item -ItemType Directory -Path 'E:\iSCSI' -Force | Out-Null
    if ((Get-WindowsFeature FS-iSCSITarget-Server).InstallState -ne 'Installed') {
        Install-WindowsFeature FS-iSCSITarget-Server -IncludeManagementTools | Out-Null
    }
    if (-not (Get-IscsiServerTarget -TargetName $targetName -ErrorAction SilentlyContinue)) {
        New-IscsiServerTarget -TargetName $targetName -InitiatorIds $ids | Out-Null
    }
    $luns = @(
        @{ Path = 'E:\iSCSI\CSV01.vhdx';    Size = $csvSize },
        @{ Path = 'E:\iSCSI\Witness.vhdx'; Size = $witnessSize }
    )
    foreach ($l in $luns) {
        if (-not (Test-Path $l.Path)) { New-IscsiVirtualDisk -Path $l.Path -SizeBytes $l.Size | Out-Null }
        Add-IscsiVirtualDiskTargetMapping -TargetName $targetName -Path $l.Path -ErrorAction SilentlyContinue
    }
    # Listen only on the storage network, like a real array's dedicated iSCSI ports
    try {
        (Get-IscsiTargetServerSetting).Portals |
            Where-Object { $_.IPEndpoint.AddressFamily -eq 'InterNetwork' -and $_.IPEndpoint.Address.ToString() -ne $portalIP } |
            ForEach-Object { Set-IscsiTargetServerSetting -IP $_.IPEndpoint.Address.ToString() -Enable $false }
    } catch { Write-Warning "Could not restrict iSCSI portals: $_ (not fatal; restrict them in Module 06 exercise 3)" }
    Get-IscsiServerTarget | Select-Object TargetName, Status, InitiatorIds, LunMappings
}

# MPIO claim needs a reboot before sessions are connected
foreach ($n in $nodes) {
    $reboot = Invoke-LabCommand -VMName $n -Domain -Activity 'Enable MPIO automatic claim for iSCSI' -ScriptBlock {
        Set-Service MSiSCSI -StartupType Automatic; Start-Service MSiSCSI
        $claimed = (Get-MSDSMAutomaticClaimSettings)['iSCSI']
        if (-not $claimed) {
            Enable-MSDSMAutomaticClaim -BusType iSCSI
            Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR
            Set-MPIOSetting -NewPathVerificationState Enabled -NewDiskTimeout 60
            return $true
        }
        $false
    }
    if ($reboot) { Restart-LabVM -VMName $n -Domain }
}

foreach ($n in $nodes) {
    $initiatorIP = Get-LabIP -VMName $n -Net Storage
    Invoke-LabCommand -VMName $n -Domain -Activity "Connect iSCSI target $targetIP from $initiatorIP" -ArgumentList $targetIP, $initiatorIP -ScriptBlock {
        param($portal, $local)
        if (-not (Get-IscsiTargetPortal | Where-Object TargetPortalAddress -eq $portal)) {
            New-IscsiTargetPortal -TargetPortalAddress $portal -InitiatorPortalAddress $local | Out-Null
        }
        Get-IscsiTarget | Where-Object { -not $_.IsConnected } | ForEach-Object {
            Connect-IscsiTarget -NodeAddress $_.NodeAddress -TargetPortalAddress $portal -InitiatorPortalAddress $local -IsPersistent $true -IsMultipathEnabled $true | Out-Null
        }
        Update-HostStorageCache
        Get-IscsiSession | Select-Object TargetNodeAddress, IsConnected, IsPersistent, InitiatorPortalAddress
    }
}

Invoke-LabCommand -VMName $nodes[0] -Domain -Activity 'Initialize and format shared LUNs' -ScriptBlock {
    $iscsi = Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' -and $_.PartitionStyle -eq 'RAW' } | Sort-Object Size
    foreach ($d in $iscsi) {
        $label = if ($d.Size -lt 5GB) { 'Witness' } else { 'CSV01' }
        Set-Disk -Number $d.Number -IsOffline $false
        Initialize-Disk -Number $d.Number -PartitionStyle GPT
        New-Partition -DiskNumber $d.Number -UseMaximumSize | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null
    }
    Get-Disk | Where-Object BusType -eq 'iSCSI' | Select-Object Number, FriendlyName, Size, PartitionStyle, OperationalStatus
}
Write-LabLog 'Shared storage ready. Next: 09-New-LabCluster.ps1' -Level Ok
