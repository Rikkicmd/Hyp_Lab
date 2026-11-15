#Requires -Version 5.1
<#
.SYNOPSIS
    Module 13 (optional) - Deploys a Host Guardian Service in its own forest and registers HV01/HV02 as guarded hosts
    using host key attestation. Also enables vTPM on a test VM with a local key protector.
.DESCRIPTION
    Prerequisite: 04-New-LabVMs.ps1 -IncludeOptional -Name HGS01   (HGS01 is NOT joined to hvlab.internal)

    HGS01 : HostGuardianServiceRole, new forest hgs.internal, self-signed signing/encryption certs (lab only),
            host key attestation mode
    HV01/02: HostGuardian feature, host key generated and registered on HGS, client pointed at HGS URLs
    DNS   : conditional forwarder hvlab.internal <-> hgs.internal

    NOTE: Running fully shielded VMs on NESTED guarded hosts can fail the attestation health checks because
    nested VMs do not expose IOMMU / full VBS. The module treats the HGS deployment and attestation workflow as the
    learning goal, and uses vTPM + local key protector for the hands-on encryption part. Check Microsoft's current
    support status for guarded fabric before designing a production deployment.
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
if (-not (Get-VM -Name HGS01 -ErrorAction SilentlyContinue)) { throw 'HGS01 not found. Run: .\04-New-LabVMs.ps1 -IncludeOptional -Name HGS01' }
$hgsDomain = 'hgs.internal'
$hgsIP = Get-LabIP -VMName HGS01
$dsrm = $cfg.Domain.SafeModePwd
$labPwd = $cfg.AdminPassword

# HGS01 points at itself for DNS once it is a DC
Invoke-LabCommand -VMName HGS01 -Activity 'Install HGS role and create hgs.internal forest' -ArgumentList $hgsDomain, $dsrm -ScriptBlock {
    param($dom, $dsrmPwd)
    if ((Get-CimInstance Win32_ComputerSystem).Domain -eq $dom) { return }
    Set-DnsClientServerAddress -InterfaceAlias 'Mgmt' -ServerAddresses '127.0.0.1'
    Install-WindowsFeature -Name HostGuardianServiceRole -IncludeManagementTools -Restart:$false | Out-Null
    Install-HgsServer -HgsDomainName $dom -SafeModeAdministratorPassword (ConvertTo-SecureString $dsrmPwd -AsPlainText -Force) -Restart:$false
}
Restart-VM -Name HGS01 -Force -Wait -For Heartbeat
$hgsCred = New-Object PSCredential('HGS\Administrator', (ConvertTo-SecureString $labPwd -AsPlainText -Force))
Wait-LabVM -VMName HGS01 -Credential $hgsCred -TimeoutMinutes 30

Invoke-Command -VMName HGS01 -Credential $hgsCred -ArgumentList $labPwd, $cfg.Domain.FQDN, $cfg.Network.DnsServer -ScriptBlock {
    param($pfxPwd, $labDomain, $labDns)
    if (-not (Get-HgsServer -ErrorAction SilentlyContinue)) {
        $pw = ConvertTo-SecureString $pfxPwd -AsPlainText -Force
        $sign = New-SelfSignedCertificate -DnsName 'signing.hgs.internal' -CertStoreLocation Cert:\LocalMachine\My
        $enc  = New-SelfSignedCertificate -DnsName 'encryption.hgs.internal' -CertStoreLocation Cert:\LocalMachine\My
        Export-PfxCertificate -Cert $sign -FilePath C:\signing.pfx -Password $pw | Out-Null
        Export-PfxCertificate -Cert $enc  -FilePath C:\encryption.pfx -Password $pw | Out-Null
        Initialize-HgsServer -HgsServiceName 'HgsSvc' -TrustHostKey `
            -SigningCertificatePath C:\signing.pfx -SigningCertificatePassword $pw `
            -EncryptionCertificatePath C:\encryption.pfx -EncryptionCertificatePassword $pw | Out-Null
    }
    if (-not (Get-DnsServerZone -Name $labDomain -ErrorAction SilentlyContinue)) {
        Add-DnsServerConditionalForwarderZone -Name $labDomain -MasterServers $labDns
    }
    Get-HgsServer | Format-List
}

Invoke-LabCommand -VMName DC01 -Domain -Activity 'Conditional forwarder to hgs.internal' -ArgumentList $hgsDomain, $hgsIP -ScriptBlock {
    param($dom, $ip)
    if (-not (Get-DnsServerZone -Name $dom -ErrorAction SilentlyContinue)) { Add-DnsServerConditionalForwarderZone -Name $dom -MasterServers $ip -ReplicationScope Forest }
}

foreach ($n in $cfg.Cluster.Nodes) {
    $keyFile = Join-Path $cfg.LabRoot "Exports\$n-hostkey.cer"
    $remoteKey = 'C:\Windows\Temp\hostkey.cer'
    $reboot = Invoke-LabCommand -VMName $n -Domain -Activity 'Install HostGuardian feature and create host key' -ArgumentList $remoteKey -ScriptBlock {
        param($path)
        $r = Install-WindowsFeature -Name HostGuardian -IncludeManagementTools
        if (-not (Get-HgsClientHostKey -ErrorAction SilentlyContinue)) { Set-HgsClientHostKey | Out-Null }
        Get-HgsClientHostKey -Path $path | Out-Null
        $r.RestartNeeded -eq 'Yes'
    }
    if ($reboot) { Restart-LabVM -VMName $n -Domain }

    # Move the public host key: guest -> host (Copy-VMFile only copies host->guest, so read it as base64 over PS Direct)
    $b64 = Invoke-LabCommand -VMName $n -Domain -Activity 'Export host key' -ArgumentList $remoteKey -ScriptBlock {
        param($path); [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
    }
    [IO.File]::WriteAllBytes($keyFile, [Convert]::FromBase64String($b64))
    Copy-VMFile -Name HGS01 -SourcePath $keyFile -DestinationPath "C:\HostKeys\$n.cer" -FileSource Host -CreateFullPath -Force

    Invoke-Command -VMName HGS01 -Credential $hgsCred -ArgumentList $n -ScriptBlock {
        param($node)
        if (-not (Get-HgsAttestationHostKey -ErrorAction SilentlyContinue | Where-Object Name -eq $node)) {
            Add-HgsAttestationHostKey -Name $node -Path "C:\HostKeys\$node.cer"
        }
    }

    Invoke-LabCommand -VMName $n -Domain -Activity 'Point HGS client at HGS01' -ScriptBlock {
        Set-HgsClientConfiguration -AttestationServerUrl 'http://hgssvc.hgs.internal/Attestation' -KeyProtectionServerUrl 'http://hgssvc.hgs.internal/KeyProtection'
        Get-HgsClientConfiguration | Format-List IsHostGuarded, Mode, AttestationStatus, AttestationSubstatus, AttestationServerUrl
    }
}

# vTPM demo VM (works everywhere, including nested): local "UntrustedGuardian" key protector
Invoke-LabCommand -VMName $cfg.Cluster.Nodes[0] -Domain -Activity 'Create vTPM demo VM' -ScriptBlock {
    if (-not (Get-VM -Name 'VTPM01' -ErrorAction SilentlyContinue)) {
        $vm = New-VM -Name 'VTPM01' -Generation 2 -MemoryStartupBytes 512MB -NewVHDPath 'C:\VMs\Disks\VTPM01.vhdx' -NewVHDSizeBytes 20GB -Path 'C:\VMs'
        Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
        Enable-VMTPM -VM $vm
        Set-VMSecurity -VM $vm -EncryptStateAndVmMigrationTraffic $true
    }
    Get-VMSecurity -VMName 'VTPM01' | Format-List TpmEnabled, KsdEnabled, Shielded, EncryptStateAndVmMigrationTraffic
}
Write-LabLog 'HGS deployed and hosts registered. Continue with docs\modules\13-security.md' -Level Ok
