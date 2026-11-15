#Requires -Version 5.1
<#
.SYNOPSIS
    Starts or stops the whole lab in dependency order.
.DESCRIPTION
    Stop : cluster workloads -> HGS01 -> HV03 -> HV01/HV02 (cluster stopped cleanly) -> MGMT01 -> STOR01 -> DC01
    Start: DC01 -> STOR01 -> HV01/HV02 -> HV03 -> MGMT01 -> HGS01
    This is the same order you would use in a real datacenter power event: identity and storage first up, last down.
.EXAMPLE
    .\Invoke-LabPower.ps1 -State Off
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('On', 'Off')][string]$State)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$exists = { param($n) [bool](Get-VM -Name $n -ErrorAction SilentlyContinue) }
$nodes = $cfg.Cluster.Nodes

if ($State -eq 'Off') {
    $running = @($nodes | Where-Object { (& $exists $_) -and (Get-VM $_).State -eq 'Running' })
    if ($running) {
        try {
            Invoke-LabCommand -VMName $running[0] -Domain -Activity 'Shut down clustered VMs and stop cluster' -ScriptBlock {
                if (Get-Cluster -ErrorAction SilentlyContinue) {
                    Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine' | Stop-ClusterGroup -ErrorAction SilentlyContinue | Out-Null
                    Stop-Cluster -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { Write-LabLog "Could not stop cluster cleanly: $_" -Level Warn }
    }
    foreach ($n in @('HGS01', 'HV03') + $nodes + @('MGMT01', 'STOR01', 'DC01')) {
        if ((& $exists $n) -and (Get-VM $n).State -ne 'Off') {
            Write-LabLog "Shutting down $n" -Level Step
            Stop-VM -Name $n -Force   # -Force = guest shutdown without the "users logged on" prompt; falls back to turn-off after timeout
        }
    }
} else {
    foreach ($n in @('DC01', 'STOR01') + $nodes + @('HV03', 'MGMT01', 'HGS01')) {
        if ((& $exists $n) -and (Get-VM $n).State -ne 'Running') {
            Write-LabLog "Starting $n" -Level Step
            Start-VM -Name $n
            $cred = if ($n -eq 'HGS01') { New-Object PSCredential('HGS\Administrator', (ConvertTo-SecureString $cfg.AdminPassword -AsPlainText -Force)) }
                    else { Get-LabCredential -Domain }
            try { Wait-LabVM -VMName $n -Credential $cred -TimeoutMinutes 10 } catch { Wait-LabVM -VMName $n -TimeoutMinutes 5 }
        }
    }
    # Clusters start automatically when nodes boot; the VMs inside follow their AutomaticStartAction / cluster priority
}
Get-VM | Where-Object { $_.Notes -like 'HVLAB*' } | Format-Table Name, State, Uptime -AutoSize
