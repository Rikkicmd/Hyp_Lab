#Requires -Version 5.1
<#
.SYNOPSIS
    Module 09 - Configures Hyper-V Replica: HVCLU01 (via Replica Broker) -> HV03 (standalone DR host).
.DESCRIPTION
    - HV03: replica server, Kerberos over HTTP/80, firewall listener rule, default storage path
    - HVCLU01: Hyper-V Replica Broker cluster role so replication follows VMs between nodes
    - Enables replication for SHELL01 (and WEB01 if it exists): 30 s frequency, 4 recovery points, initial copy over network
#>
[CmdletBinding()]
param([string[]]$VMName = @('SHELL01', 'WEB01'))

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$r = $cfg.Replica
$fqdn = $cfg.Domain.FQDN
$first = $cfg.Cluster.Nodes[0]

Invoke-LabCommand -VMName $r.Server -Domain -Activity 'Enable replica server' -ArgumentList $r.Port, $r.StoragePath -ScriptBlock {
    param($port, $path)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Set-VMReplicationServer -ReplicationEnabled $true -AllowedAuthenticationType Kerberos -KerberosAuthenticationPort $port `
        -ReplicationAllowedFromAnyServer $true -DefaultStorageLocation $path
    Enable-NetFirewallRule -DisplayName 'Hyper-V Replica HTTP Listener (TCP-In)'
    Get-VMReplicationServer | Format-List ReplicationEnabled, AllowedAuthenticationType, KerberosAuthenticationPort, DefaultStorageLocation
}

Invoke-LabCommand -VMName $first -Domain -Activity 'Create Hyper-V Replica Broker role' -ArgumentList $r.BrokerName, $r.BrokerIP, $r.Port, $r.StoragePath -ScriptBlock {
    param($broker, $ip, $port, $path)
    if (-not (Get-ClusterGroup -Name $broker -ErrorAction SilentlyContinue)) {
        Add-ClusterServerRole -Name $broker -StaticAddress $ip | Out-Null
        Add-ClusterResource -Name "Virtual Machine Replication Broker $broker" -Type 'Virtual Machine Replication Broker' -Group $broker | Out-Null
        Add-ClusterResourceDependency "Virtual Machine Replication Broker $broker" $broker | Out-Null
        Start-ClusterGroup $broker | Out-Null
    }
    # The broker also lets the cluster RECEIVE replicas (needed for reverse replication after failover)
    Set-VMReplicationServer -ReplicationEnabled $true -AllowedAuthenticationType Kerberos -KerberosAuthenticationPort $port `
        -ReplicationAllowedFromAnyServer $true -DefaultStorageLocation "C:\ClusterStorage\CSV01\Replica"
}
Invoke-LabCommand -VMName $cfg.Cluster.Nodes -Domain -Activity 'Open replica listener on cluster nodes' -ScriptBlock {
    Enable-NetFirewallRule -DisplayName 'Hyper-V Replica HTTP Listener (TCP-In)'
}

foreach ($vm in $VMName) {
    $owner = Invoke-LabCommand -VMName $first -Domain -Activity "Find owner of $vm" -ArgumentList $vm -ScriptBlock {
        param($n); $g = Get-ClusterGroup -Name $n -ErrorAction SilentlyContinue; if ($g) { $g.OwnerNode.Name }
    }
    if (-not $owner) { Write-LabLog "$vm not found in cluster, skipping." -Level Warn; continue }
    Invoke-LabCommand -VMName $owner -Domain -Activity "Enable replication of $vm to $($r.Server)" -ArgumentList $vm, "$($r.Server).$fqdn", $r.Port -ScriptBlock {
        param($n, $replica, $port)
        if ((Get-VM $n).ReplicationState -ne 'Disabled') { return }
        Enable-VMReplication -VMName $n -ReplicaServerName $replica -ReplicaServerPort $port -AuthenticationType Kerberos `
            -ReplicationFrequencySec 30 -RecoveryHistory 4 -VSSSnapshotFrequencyHour 1 -CompressionEnabled $true
        Start-VMInitialReplication -VMName $n
        Get-VMReplication -VMName $n | Format-List Name, State, Health, Mode, FrequencySec, PrimaryServer, ReplicaServer
    }
}
Write-LabLog 'Replication enabled. Follow Module 09 for test failover / planned failover / reverse replication.' -Level Ok
