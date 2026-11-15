#Requires -Version 5.1
<#
.SYNOPSIS
    Module 02 - Builds the lab's virtual networks on the physical host.
.DESCRIPTION
    HVLAB-Mgmt     Internal switch + host vNIC 10.10.0.1 + WinNAT  -> VMs reach the Internet, your LAN is untouched
    HVLAB-Storage  Private switch (iSCSI, 10.10.20.0/24)            -> host cannot see it, just like an isolated storage fabric
    HVLAB-Cluster  Private switch (heartbeat + live migration)      -> 10.10.30.0/24
    Idempotent: existing objects are left alone.
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$net = $cfg.Network

foreach ($key in 'Mgmt', 'Storage', 'Cluster') {
    $n = $net[$key]
    if (-not (Get-VMSwitch -Name $n.Switch -ErrorAction SilentlyContinue)) {
        Write-LabLog "Creating $($n.Type) switch $($n.Switch)" -Level Step
        New-VMSwitch -Name $n.Switch -SwitchType $n.Type -Notes "HVLAB $key network $($n.Prefix).0/$($n.Length)" | Out-Null
    } else { Write-LabLog "Switch $($n.Switch) already exists" }
}

# Host vNIC on the internal switch becomes the VMs' default gateway
$m = $net.Mgmt
$ifAlias = "vEthernet ($($m.Switch))"
$existing = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
if (-not ($existing | Where-Object IPAddress -eq $m.Gateway)) {
    Write-LabLog "Assigning $($m.Gateway)/$($m.Length) to $ifAlias" -Level Step
    $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $m.Gateway -PrefixLength $m.Length | Out-Null
}

# WinNAT for outbound Internet (Windows Update, downloads, WAC extensions)
$natPrefix = "$($m.Prefix).0/$($m.Length)"
$nat = Get-NetNat -ErrorAction SilentlyContinue
if ($nat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $natPrefix }) {
    Write-LabLog "NAT for $natPrefix already exists"
} elseif ($nat) {
    Write-LabLog "Another NetNat exists ($($nat.Name)). Windows supports only one; remove it or add $natPrefix manually." -Level Warn
} else {
    Write-LabLog "Creating NAT $($m.NatName) for $natPrefix" -Level Step
    New-NetNat -Name $m.NatName -InternalIPInterfaceAddressPrefix $natPrefix | Out-Null
}

Get-VMSwitch | Where-Object Name -like 'HVLAB-*' | Format-Table Name, SwitchType, Notes -AutoSize
Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix -AutoSize
Write-LabLog 'Lab networking complete. Next: 03-New-GoldenImage.ps1' -Level Ok
