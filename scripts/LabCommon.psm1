#Requires -Version 5.1
<#
    Shared helpers for every lab script.
    Import with:  Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
#>

Set-StrictMode -Version Latest

$script:LabConfig = $null

function Get-LabConfig {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot '..\config\LabConfig.psd1'))
    if (-not $script:LabConfig) {
        if (-not (Test-Path $Path)) { throw "Lab config not found at $Path" }
        $script:LabConfig = Import-PowerShellDataFile -Path $Path
    }
    return $script:LabConfig
}

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Step', 'Ok', 'Warn', 'Error')][string]$Level = 'Info'
    )
    $cfg = Get-LabConfig
    $logDir = Join-Path $cfg.LabRoot 'Logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    Add-Content -Path (Join-Path $logDir 'lab.log') -Value $line
    $color = @{ Info = 'Gray'; Step = 'Cyan'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function Assert-LabAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
    }
}

function Get-LabVMDefinition {
    [CmdletBinding()]
    param([string]$Name, [switch]$IncludeOptional)
    $cfg = Get-LabConfig
    $all = @($cfg.VMs)
    if ($IncludeOptional) { $all += @($cfg.OptionalVMs) }
    if ($Name) { return $all | Where-Object { $_.Name -eq $Name } }
    return $all
}

function Get-LabIP {
    <# Returns the full IP for a VM on a given lab network, e.g. Get-LabIP -VMName HV01 -Net Storage #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VMName, [string]$Net = 'Mgmt')
    $cfg = Get-LabConfig
    $def = Get-LabVMDefinition -Name $VMName -IncludeOptional
    if (-not $def) { throw "No VM named $VMName in LabConfig." }
    $nic = $def.Nics | Where-Object { $_.Net -eq $Net }
    if (-not $nic) { return $null }
    return '{0}.{1}' -f $cfg.Network[$Net].Prefix, $nic.IP
}

function Get-LabCredential {
    <# Local Administrator (pre-domain) or HVLAB\Administrator (post-domain). #>
    [CmdletBinding()]
    param([switch]$Domain)
    $cfg = Get-LabConfig
    $sec = ConvertTo-SecureString $cfg.AdminPassword -AsPlainText -Force
    $user = if ($Domain) { "$($cfg.Domain.NetBIOS)\Administrator" } else { 'Administrator' }
    return New-Object System.Management.Automation.PSCredential($user, $sec)
}

function Wait-LabVM {
    <#
        Waits until PowerShell Direct (VMBus, no network needed) answers inside the guest.
        This is the standard technique for configuring VMs before they have networking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [System.Management.Automation.PSCredential]$Credential = (Get-LabCredential),
        [int]$TimeoutMinutes = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-LabLog "Waiting for $VMName to answer PowerShell Direct as $($Credential.UserName)..."
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            if ($r) { Write-LabLog "$VMName is ready ($r)." -Level Ok; return }
        } catch { Start-Sleep -Seconds 10 }
    }
    throw "Timed out after $TimeoutMinutes min waiting for $VMName."
}

function Invoke-LabCommand {
    <# Thin wrapper over PowerShell Direct with logging and domain/local credential choice. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$VMName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [switch]$Domain,
        [string]$Activity = 'Remote command'
    )
    $cred = Get-LabCredential -Domain:$Domain
    foreach ($vm in $VMName) {
        Write-LabLog "[$vm] $Activity" -Level Step
        Invoke-Command -VMName $vm -Credential $cred -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}

function Restart-LabVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VMName, [switch]$Domain)
    Write-LabLog "Restarting $VMName"
    Restart-VM -Name $VMName -Force -Wait -For Heartbeat
    Wait-LabVM -VMName $VMName -Credential (Get-LabCredential -Domain:$Domain)
}

function Test-LabDomainReady {
    [CmdletBinding()]
    param([string]$VMName = 'DC01')
    try {
        Invoke-Command -VMName $VMName -Credential (Get-LabCredential -Domain) -ErrorAction Stop -ScriptBlock {
            (Get-ADDomain -ErrorAction Stop).DNSRoot
        } | Out-Null
        return $true
    } catch { return $false }
}

Export-ModuleMember -Function *-Lab*
