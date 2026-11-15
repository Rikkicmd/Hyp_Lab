#Requires -Version 5.1
<#
.SYNOPSIS
    Module 12 - Turns MGMT01 into the admin workstation: RSAT + Windows Admin Center.
.DESCRIPTION
    - RSAT: Hyper-V Manager, Failover Cluster Manager, AD/DNS/DHCP consoles, iSCSI/storage tools
    - Windows Admin Center (downloaded through the lab NAT from https://aka.ms/WACdownload), silent install
      with a self-signed certificate on port 443. Browse to https://mgmt01.hvlab.internal from MGMT01.
    - Trusted hosts / CredSSP are NOT used: everything relies on Kerberos and the constrained
      delegation configured by script 07 (the production-recommended pattern).
    SCVMM is covered as a guided optional install in docs\modules\12-management.md because it needs
    its own evaluation media and SQL Server.
#>
[CmdletBinding()]
param([switch]$SkipWAC)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin

Invoke-LabCommand -VMName MGMT01 -Domain -Activity 'Install RSAT and management consoles' -ScriptBlock {
    $f = 'RSAT-Hyper-V-Tools', 'Hyper-V-Tools', 'Hyper-V-PowerShell', 'RSAT-Clustering', 'RSAT-Clustering-Mgmt', 'RSAT-Clustering-PowerShell',
         'RSAT-AD-Tools', 'RSAT-DNS-Server', 'RSAT-DHCP', 'RSAT-File-Services', 'GPMC'
    Install-WindowsFeature -Name $f -IncludeManagementTools | Select-Object Success, RestartNeeded, FeatureResult
}

if (-not $SkipWAC) {
    Invoke-LabCommand -VMName MGMT01 -Domain -Activity 'Download and install Windows Admin Center' -ScriptBlock {
        $installer = 'C:\Temp\WindowsAdminCenter.exe'
        New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null
        if (-not (Get-Service -Name WindowsAdminCenter -ErrorAction SilentlyContinue)) {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri 'https://aka.ms/WACdownload' -OutFile $installer -UseBasicParsing
            } catch {
                Write-Warning "Download failed ($_). Copy the WAC installer to MGMT01 C:\Temp\WindowsAdminCenter.exe (Copy-VMFile) and re-run."
                return
            }
            Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/log=C:\Temp\wac-install.log' -Wait
        }
        Get-Service -Name WindowsAdminCenter* | Select-Object Name, Status, StartType
    }
}

Write-LabLog 'Management tools installed. Log on to MGMT01 as HVLAB\hvadmin and open Hyper-V Manager, Failover Cluster Manager and https://mgmt01.hvlab.internal' -Level Ok
