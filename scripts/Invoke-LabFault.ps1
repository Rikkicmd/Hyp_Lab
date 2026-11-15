#Requires -Version 5.1
<#
.SYNOPSIS
    Module 15 - Break/fix trainer. Injects a realistic Hyper-V fault for you to diagnose, or reverts it.
.DESCRIPTION
    Run with -List to see scenarios. Run with -Scenario <name> to break the lab; the script prints only
    the SYMPTOM a user would report. Diagnose with the tools from Modules 02-14, fix it yourself, then
    check with ..\validation\Test-LabModule.ps1. If you are stuck, -Hint shows a hint and -Repair
    puts it back the way the scripts built it.

    Take a checkpoint first:  .\Invoke-LabCheckpoint.ps1 -Action Save -Name Before-Faults
.EXAMPLE
    .\Invoke-LabFault.ps1 -List
    .\Invoke-LabFault.ps1 -Scenario DnsMisconfig
    .\Invoke-LabFault.ps1 -Scenario DnsMisconfig -Hint
    .\Invoke-LabFault.ps1 -Scenario DnsMisconfig -Repair
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [ValidateSet('DnsMisconfig', 'IscsiPathDown', 'TimeSkew', 'MigrationDisabled', 'ClusterNetworkRole',
                 'ReplicaFirewall', 'WrongVlan', 'MemoryOvercommit', 'NestedVirtOff', 'StaleCheckpoints', 'Random')]
    [string]$Scenario,
    [Parameter(ParameterSetName = 'Run')][switch]$Repair,
    [Parameter(ParameterSetName = 'Run')][switch]$Hint
)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig

function Set-LabShellMemory {
    # Runs from the physical host: find SHELL01's owner, stop the role, change memory on the owner, start it again
    param([switch]$Overcommit)
    $owner = Invoke-LabCommand -VMName HV01 -Domain -Activity 'Stop SHELL01 role' -ScriptBlock {
        $g = Get-ClusterGroup -Name SHELL01; Stop-ClusterGroup SHELL01 | Out-Null; $g.OwnerNode.Name
    }
    Invoke-LabCommand -VMName $owner -Domain -Activity 'Change SHELL01 memory' -ArgumentList $Overcommit.IsPresent -ScriptBlock {
        param($over)
        if ($over) { Set-VMMemory -VMName SHELL01 -DynamicMemoryEnabled $false -StartupBytes 10GB }
        else { Set-VMMemory -VMName SHELL01 -DynamicMemoryEnabled $true -StartupBytes 512MB -MinimumBytes 256MB -MaximumBytes 1GB }
    }
    Invoke-LabCommand -VMName HV01 -Domain -Activity 'Start SHELL01 role' -ScriptBlock { Start-ClusterGroup SHELL01 -ErrorAction SilentlyContinue | Out-Null }
}

$S = [ordered]@{
    DnsMisconfig = @{
        Symptom = 'HV02 shows "The trust relationship..." / cluster validation warnings, and Live Migration to HV02 fails with Kerberos errors.'
        Hint    = 'Compare Get-DnsClientServerAddress on HV01 and HV02. Can HV02 resolve dc01.hvlab.internal?'
        Break   = { Invoke-LabCommand -VMName HV02 -Domain -ScriptBlock { Set-DnsClientServerAddress -InterfaceAlias 'vEthernet (Mgmt)' -ServerAddresses '10.10.0.99' } }
        Fix     = { Invoke-LabCommand -VMName HV02 -Domain -ScriptBlock { Set-DnsClientServerAddress -InterfaceAlias 'vEthernet (Mgmt)' -ServerAddresses '10.10.0.10'; Clear-DnsClientCache } }
    }
    IscsiPathDown = @{
        Symptom = 'CSV01 shows "Redirected Access" or a node lost the disk; VM I/O on HV02 is slow.'
        Hint    = 'Get-ClusterSharedVolumeState; Get-IscsiSession on each node; Get-NetAdapter on HV02.'
        Break   = { Invoke-LabCommand -VMName HV02 -Domain -ScriptBlock { Disable-NetAdapter -Name 'Storage' -Confirm:$false } }
        Fix     = { Invoke-LabCommand -VMName HV02 -Domain -ScriptBlock { Enable-NetAdapter -Name 'Storage'; Start-Sleep 10; Update-HostStorageCache } }
    }
    TimeSkew = @{
        Symptom = 'Logons to HV03 fail intermittently, replication from the cluster to HV03 is in a Critical state.'
        Hint    = 'Kerberos tolerates 5 minutes of clock skew. Check w32tm /query /status and the Time Synchronization integration service.'
        Break   = {
            Disable-VMIntegrationService -VMName HV03 -Name 'Time Synchronization'
            Invoke-LabCommand -VMName HV03 -Domain -ScriptBlock { Stop-Service w32time; Set-Service w32time -StartupType Disabled; Set-Date (Get-Date).AddMinutes(17) | Out-Null }
        }
        Fix     = {
            Invoke-LabCommand -VMName HV03 -Domain -ScriptBlock { Set-Service w32time -StartupType Automatic; Start-Service w32time; w32tm /resync /force | Out-Null }
            Enable-VMIntegrationService -VMName HV03 -Name 'Time Synchronization'
        }
    }
    MigrationDisabled = @{
        Symptom = 'Shared-nothing live migration from the cluster to HV03 fails: "The virtual machine migration operation failed at migration source/destination".'
        Hint    = 'Get-VMHost | Select VirtualMachineMigration* on BOTH ends. Event log: Hyper-V-VMMS.'
        Break   = { Invoke-LabCommand -VMName HV03 -Domain -ScriptBlock { Disable-VMMigration } }
        Fix     = { Invoke-LabCommand -VMName HV03 -Domain -ScriptBlock { Enable-VMMigration } }
    }
    ClusterNetworkRole = @{
        Symptom = 'Live migrations between HV01 and HV02 fail or fall back to the management network and are slow.'
        Hint    = 'Get-ClusterNetwork | ft Name, Role, Address and the MigrationExcludeNetworks parameter of the Virtual Machine resource type.'
        Break   = { Invoke-LabCommand -VMName HV01 -Domain -ScriptBlock { (Get-ClusterNetwork -Name 'Cluster').Role = 'None' } }
        Fix     = { Invoke-LabCommand -VMName HV01 -Domain -ScriptBlock { (Get-ClusterNetwork -Name 'Cluster').Role = 'Cluster' } }
    }
    ReplicaFirewall = @{
        Symptom = 'Hyper-V Replica health is Critical: "Hyper-V cannot connect to the specified Replica server".'
        Hint    = 'Test-NetConnection hv03 -Port 80 from the primary. Which inbound rule does Replica need?'
        Break   = { Invoke-LabCommand -VMName HV03 -Domain -ScriptBlock { Disable-NetFirewallRule -DisplayName 'Hyper-V Replica HTTP Listener (TCP-In)' } }
        Fix     = { Invoke-LabCommand -VMName HV03 -Domain -ScriptBlock { Enable-NetFirewallRule -DisplayName 'Hyper-V Replica HTTP Listener (TCP-In)' } }
    }
    WrongVlan = @{
        Symptom = 'MGMT01 has lost all network connectivity, but the VM is running and its NIC shows "Connected".'
        Hint    = 'Look at the VM network adapter settings on the physical host, not inside the guest. Get-VMNetworkAdapterVlan.'
        Break   = { Set-VMNetworkAdapterVlan -VMName MGMT01 -Access -VlanId 99 }
        Fix     = { Set-VMNetworkAdapterVlan -VMName MGMT01 -Untagged }
    }
    MemoryOvercommit = @{
        Symptom = 'Draining HV01 for maintenance fails: some roles cannot move to HV02.'
        Hint    = 'Compare each clustered VM''s startup memory with Get-VMHost (MemoryCapacity) / Get-Counter "\Hyper-V Dynamic Memory Balancer(*)\Available Memory" on HV02.'
        Break   = { Set-LabShellMemory -Overcommit }
        Fix     = { Set-LabShellMemory }
    }
    NestedVirtOff = @{
        Symptom = 'After a maintenance reboot, HV03 cannot start any VM: "Hyper-V is not running" / hypervisor not present.'
        Hint    = 'Hyper-V inside a VM needs something configured on the PARENT host. Get-VMProcessor HV03 | fl *'
        Break   = { Stop-VM HV03 -Force; Set-VMProcessor -VMName HV03 -ExposeVirtualizationExtensions $false; Start-VM HV03 }
        Fix     = { Stop-VM HV03 -Force; Set-VMProcessor -VMName HV03 -ExposeVirtualizationExtensions $true; Start-VM HV03 }
    }
    StaleCheckpoints = @{
        Symptom = 'STOR01 disk usage on the host keeps growing and storage latency has increased.'
        Hint    = 'Get-VMCheckpoint; Get-VMHardDiskDrive STOR01 | Get-VHD (look at the path extension and ParentPath).'
        Break   = { 1..3 | ForEach-Object { Checkpoint-VM -Name STOR01 -SnapshotName "Forgotten-$_" } }
        Fix     = { Get-VMCheckpoint -VMName STOR01 | Where-Object Name -like 'Forgotten-*' | Remove-VMCheckpoint }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'List') {
    $S.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Scenario = $_.Key; Symptom = $_.Value.Symptom } } | Format-Table -Wrap -AutoSize
    return
}

$stateFile = Join-Path $cfg.LabRoot 'Logs\active-fault.txt'
if ($Scenario -eq 'Random') {
    if ($Repair -or $Hint) {
        if (-not (Test-Path $stateFile)) { throw 'No random fault recorded.' }
        $Scenario = Get-Content $stateFile
    } else { $Scenario = ($S.Keys | Get-Random) }
}
$sc = $S[$Scenario]

if ($Hint)   { Write-Host "HINT: $($sc.Hint)" -ForegroundColor Yellow; return }
if ($Repair) {
    & $sc.Fix
    Remove-Item $stateFile -ErrorAction SilentlyContinue
    Write-LabLog "Reverted fault $Scenario" -Level Ok
    return
}

& $sc.Break
Set-Content -Path $stateFile -Value $Scenario
Write-LabLog "Fault injected (scenario recorded in Logs\active-fault.txt)." -Level Warn
Write-Host "`nTICKET: $($sc.Symptom)`n" -ForegroundColor Magenta
