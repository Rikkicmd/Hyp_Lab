#Requires -Version 5.1
<#
.SYNOPSIS
    Module 04 - Promotes DC01 to the first domain controller of hvlab.internal and adds DNS + DHCP.
.DESCRIPTION
    Runs entirely over PowerShell Direct from the physical host.
      - AD DS + DNS: new forest, Windows Server 2025 functional level
      - DNS: forwarders to the NAT gateway, reverse lookup zones for every lab subnet
      - DHCP: authorized in AD, scope for 10.10.0.100-199 (options 003/006/015)
      - Directory: OUs, a Hyper-V admins group, a cluster/service account, sample users
#>
[CmdletBinding()]
param()

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$dom = $cfg.Domain
$net = $cfg.Network

if (Test-LabDomainReady) {
    Write-LabLog "Domain $($dom.FQDN) already exists on DC01; skipping promotion."
} else {
    Invoke-LabCommand -VMName DC01 -Activity 'Install AD DS + DNS and create forest' -ArgumentList $dom.FQDN, $dom.NetBIOS, $dom.SafeModePwd -ScriptBlock {
        param($fqdn, $netbios, $dsrm)
        Set-DnsClientServerAddress -InterfaceAlias 'Mgmt' -ServerAddresses '127.0.0.1'
        Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
        Import-Module ADDSDeployment
        Install-ADDSForest -DomainName $fqdn -DomainNetbiosName $netbios `
            -ForestMode 'Win2025' -DomainMode 'Win2025' -InstallDns `
            -SafeModeAdministratorPassword (ConvertTo-SecureString $dsrm -AsPlainText -Force) `
            -NoRebootOnCompletion -Force | Out-Null
    }
    Restart-VM -Name DC01 -Force -Wait -For Heartbeat
    # After promotion the local Administrator becomes the domain Administrator (same password)
    Wait-LabVM -VMName DC01 -Credential (Get-LabCredential -Domain) -TimeoutMinutes 30
    Write-LabLog 'Waiting for AD Web Services to come up...'
    $tries = 0
    while (-not (Test-LabDomainReady) -and $tries -lt 30) { Start-Sleep 20; $tries++ }
    if (-not (Test-LabDomainReady)) { throw 'Domain did not come up in time. Check DC01 event logs (Directory Service, DNS Server).' }
}

$dnsArgs = @(
    $net.Mgmt.Gateway,
    @("$($net.Mgmt.Prefix).0/24", "$($net.Storage.Prefix).0/24", "$($net.Cluster.Prefix).0/24")
)
Invoke-LabCommand -VMName DC01 -Domain -Activity 'Configure DNS forwarders and reverse zones' -ArgumentList $dnsArgs -ScriptBlock {
    param($gateway, $subnets)
    Set-DnsServerForwarder -IPAddress $gateway -UseRootHint $true
    foreach ($s in $subnets) {
        $o = ($s -split '/')[0] -split '\.'
        $zoneName = '{0}.{1}.{2}.in-addr.arpa' -f $o[2], $o[1], $o[0]
        if (-not (Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue)) {
            Add-DnsServerPrimaryZone -NetworkId $s -ReplicationScope Forest -DynamicUpdate Secure
        }
    }
    Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 -ApplyOnAllZones
}

$dhcpArgs = @($cfg.Domain.FQDN, $net.DhcpScope.Name, $net.DhcpScope.Start, $net.DhcpScope.End, "$($net.Mgmt.Prefix).0", $net.Mgmt.Gateway, $net.DnsServer, "$($net.Mgmt.Prefix).10")
Invoke-LabCommand -VMName DC01 -Domain -Activity 'Install, authorize and scope DHCP' -ArgumentList $dhcpArgs -ScriptBlock {
    param($fqdn, $scopeName, $start, $end, $scopeId, $gw, $dns, $dcIp)
    if ((Get-WindowsFeature DHCP).InstallState -ne 'Installed') { Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null }
    netsh dhcp add securitygroups | Out-Null
    Restart-Service DHCPServer
    if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $dcIp)) { Add-DhcpServerInDC -DnsName "dc01.$fqdn" -IPAddress $dcIp }
    # Tell Server Manager the post-install configuration is done
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2
    if (-not (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object ScopeId -eq $scopeId)) {
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $start -EndRange $end -SubnetMask 255.255.255.0 -LeaseDuration 8.00:00:00 -State Active
    }
    Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $gw -DnsServer $dns -DnsDomain $fqdn
    Set-DhcpServerv4DnsSetting -DynamicUpdates Always -DeleteDnsRRonLeaseExpiry $true
}

Invoke-LabCommand -VMName DC01 -Domain -Activity 'Create OUs, groups, service and user accounts' -ArgumentList $dom.OUs, $cfg.AdminPassword -ScriptBlock {
    param($ous, $labPwd)
    $root = (Get-ADDomain).DistinguishedName
    foreach ($ou in $ous) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $root -SearchScope OneLevel)) {
            New-ADOrganizationalUnit -Name $ou -Path $root -ProtectedFromAccidentalDeletion $true
        }
    }
    $sec = ConvertTo-SecureString $labPwd -AsPlainText -Force
    $groupsOU = "OU=Lab Groups,$root"; $usersOU = "OU=Lab Users,$root"; $svcOU = "OU=Service Accounts,$root"
    foreach ($g in 'HV-Admins', 'HV-Operators', 'Cluster-Admins') {
        if (-not (Get-ADGroup -Filter "Name -eq '$g'")) { New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path $groupsOU }
    }
    $users = @(
        @{ Sam = 'hvadmin';  Name = 'Hyper-V Admin';   Groups = 'HV-Admins', 'Cluster-Admins', 'Domain Admins' }
        @{ Sam = 'hvop';     Name = 'Hyper-V Operator'; Groups = 'HV-Operators' }
        @{ Sam = 'student';  Name = 'Lab Student';     Groups = 'HV-Operators' }
    )
    foreach ($u in $users) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'")) {
            New-ADUser -SamAccountName $u.Sam -Name $u.Name -UserPrincipalName "$($u.Sam)@$((Get-ADDomain).DNSRoot)" `
                -AccountPassword $sec -Enabled $true -PasswordNeverExpires $true -Path $usersOU
        }
        foreach ($g in $u.Groups) { Add-ADGroupMember -Identity $g -Members $u.Sam -ErrorAction SilentlyContinue }
    }
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'svc-backup'")) {
        New-ADUser -SamAccountName 'svc-backup' -Name 'Backup Service' -AccountPassword $sec -Enabled $true -PasswordNeverExpires $true -Path $svcOU
    }
    # KDS root key for gMSAs (backdated so it is usable immediately in a single-DC lab)
    if (-not (Get-KdsRootKey)) { Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null }
}

Write-LabLog "Domain $($dom.FQDN) is ready. Next: 06-Join-LabDomain.ps1" -Level Ok
