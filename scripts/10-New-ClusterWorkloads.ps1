#Requires -Version 5.1
<#
.SYNOPSIS
    Module 07/08 - Creates highly available workload VMs inside the nested cluster.
.DESCRIPTION
    Always creates two lightweight "shell" VMs (no OS, 512 MB, they PXE-loop forever) that are perfect for
    practising live migration, quick migration, failover and drain without burning RAM.

    With -WithOS, also copies the Server Core golden image into CSV01 (Copy-VMFile over VMBus) and builds
    WEB01 and APP01 as real Windows guests from differencing disks, with an anti-affinity rule so they
    land on different nodes.
#>
[CmdletBinding()]
param([switch]$WithOS, [string]$CsvName = 'CSV01')

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$first = $cfg.Cluster.Nodes[0]
$csv = "C:\ClusterStorage\$CsvName"

if ($WithOS) {
    $parent = Join-Path $cfg.LabRoot 'Images\WS2025-Core.vhdx'
    $unattendSrc = Join-Path $cfg.LabRoot 'Unattend\STOR01.xml'   # any generated unattend; computer name gets replaced in-guest
    Write-LabLog "Copying $parent into ${first}:$csv\Images (Copy-VMFile over VMBus, a few minutes)" -Level Step
    Copy-VMFile -Name $first -SourcePath $parent -DestinationPath "$csv\Images\WS2025-Core.vhdx" -FileSource Host -CreateFullPath -Force
    Copy-VMFile -Name $first -SourcePath $unattendSrc -DestinationPath "$csv\Images\unattend-template.xml" -FileSource Host -CreateFullPath -Force
}

Invoke-LabCommand -VMName $first -Domain -Activity 'Create HA workload VMs on CSV01' -ArgumentList $csv, $WithOS.IsPresent -ScriptBlock {
    param($csvPath, $withOS)
    $vms = @(
        @{ Name = 'SHELL01'; Mem = 512MB; OS = $false; Priority = 1000 },  # Low
        @{ Name = 'SHELL02'; Mem = 512MB; OS = $false; Priority = 1000 }
    )
    if ($withOS) {
        $vms += @{ Name = 'WEB01'; Mem = 1GB; OS = $true; Priority = 3000; AntiAffinity = 'FrontEnd' }   # High
        $vms += @{ Name = 'APP01'; Mem = 1GB; OS = $true; Priority = 2000; AntiAffinity = 'FrontEnd' }   # Medium
        Set-ItemProperty "$csvPath\Images\WS2025-Core.vhdx" -Name IsReadOnly -Value $true
    }
    foreach ($v in $vms) {
        if (Get-VM -Name $v.Name -ErrorAction SilentlyContinue) { continue }
        $dir = Join-Path $csvPath "VMs\$($v.Name)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $vhd = Join-Path $dir "$($v.Name).vhdx"
        if ($v.OS) {
            New-VHD -Path $vhd -ParentPath "$csvPath\Images\WS2025-Core.vhdx" -Differencing | Out-Null
            $part = Mount-VHD -Path $vhd -PassThru | Get-Disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 10GB }
            if (-not $part.DriveLetter -or $part.DriveLetter -eq [char]0) { $part | Add-PartitionAccessPath -AssignDriveLetter; $part = $part | Get-Partition }
            $xml = (Get-Content "$csvPath\Images\unattend-template.xml" -Raw) -replace '<ComputerName>[^<]+</ComputerName>', "<ComputerName>$($v.Name)</ComputerName>"
            New-Item -ItemType Directory "$($part.DriveLetter):\Windows\Panther" -Force | Out-Null
            Set-Content "$($part.DriveLetter):\Windows\Panther\unattend.xml" -Value $xml -Encoding UTF8
            Dismount-VHD -Path $vhd
        } else {
            New-VHD -Path $vhd -SizeBytes 20GB -Dynamic | Out-Null
        }
        $vm = New-VM -Name $v.Name -Generation 2 -MemoryStartupBytes $v.Mem -VHDPath $vhd -Path (Join-Path $csvPath 'VMs') -SwitchName 'SETswitch'
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes 256MB -MaximumBytes ($v.Mem * 2)
        Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Production
        Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
        $grp = Add-ClusterVirtualMachineRole -VMName $v.Name
        $grp.Priority = $v.Priority
        if ($v.ContainsKey('AntiAffinity')) {
            $names = New-Object System.Collections.Specialized.StringCollection
            [void]$names.Add($v.AntiAffinity)
            $grp.AntiAffinityClassNames = $names
        }
        Start-ClusterGroup -Name $v.Name | Out-Null
    }
    Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine' | Format-Table Name, OwnerNode, State, Priority
}
Write-LabLog 'Workloads created. Practise Module 08 (Live/Storage migration), then run 11-Enable-HyperVReplica.ps1' -Level Ok
