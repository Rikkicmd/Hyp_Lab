#Requires -Version 5.1
<#
.SYNOPSIS
    Module 04 - Joins member servers to hvlab.internal and places them in the right OU.
.DESCRIPTION
    Hyper-V hosts go to "OU=Hyper-V Hosts", everything else to "OU=Lab Servers".
    HGS01 is skipped on purpose: the Host Guardian Service must live in its own forest (Module 13).
#>
[CmdletBinding()]
param([string[]]$Name)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
if (-not (Test-LabDomainReady)) { throw 'Domain is not ready. Run 05-Initialize-DomainController.ps1 first.' }

$root = 'DC=' + ($cfg.Domain.FQDN -replace '\.', ',DC=')
$members = Get-LabVMDefinition | Where-Object { $_.Role -notin 'DC', 'HGS' }
if ($Name) { $members = $members | Where-Object { $_.Name -in $Name } }

foreach ($m in $members) {
    $ou = if ($m.Role -eq 'HyperV') { "OU=Hyper-V Hosts,$root" } else { "OU=Lab Servers,$root" }
    $already = Invoke-LabCommand -VMName $m.Name -Activity 'Check domain membership' -ScriptBlock { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
    if ($already) { Write-LabLog "$($m.Name) is already domain joined."; continue }

    Invoke-LabCommand -VMName $m.Name -Activity "Join $($cfg.Domain.FQDN) in $ou" `
        -ArgumentList $cfg.Domain.FQDN, "$($cfg.Domain.NetBIOS)\Administrator", $cfg.AdminPassword, $ou -ScriptBlock {
        param($fqdn, $user, $pass, $ouPath)
        $cred = New-Object PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
        # Retry: DNS registration of the new DC can lag a minute behind promotion
        for ($i = 0; $i -lt 10; $i++) {
            try { Add-Computer -DomainName $fqdn -Credential $cred -OUPath $ouPath -ErrorAction Stop; break }
            catch { Start-Sleep 15; if ($i -eq 9) { throw } }
        }
    }
    Restart-VM -Name $m.Name -Force -Wait -For Heartbeat
}

foreach ($m in $members) { Wait-LabVM -VMName $m.Name -Credential (Get-LabCredential -Domain) }

# Hyper-V hosts: HV-Admins become local admins (HV-Operators get the narrower "Hyper-V Administrators" group in script 07)
$hvHosts = @($members | Where-Object Role -eq 'HyperV' | ForEach-Object Name)
if ($hvHosts) { Invoke-LabCommand -VMName $hvHosts -Domain -Activity 'Add HV-Admins to local Administrators' `
    -ArgumentList $cfg.Domain.NetBIOS -ScriptBlock {
    param($nb)
    Add-LocalGroupMember -Group 'Administrators' -Member "$nb\HV-Admins" -ErrorAction SilentlyContinue
} }

Write-LabLog 'Member servers joined. Next: 07-Install-NestedHyperV.ps1' -Level Ok
