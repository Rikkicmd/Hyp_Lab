#Requires -Version 5.1
<#
.SYNOPSIS
    Validates the lab state for one or all training modules and prints PASS/FAIL per check.
.DESCRIPTION
    Each module's checks prove the outcome of the build scripts AND of the hands-on exercises in the module
    guide (checks marked [Exercise] only pass once you have completed that exercise yourself).
    Run from the physical host in an elevated session.
.EXAMPLE
    .\Test-LabModule.ps1 -Module 7
    .\Test-LabModule.ps1 -All
    .\Test-LabModule.ps1 -All -PassThru | Export-Csv results.csv -NoTypeInformation
#>
[CmdletBinding(DefaultParameterSetName = 'One')]
param(
    [Parameter(ParameterSetName = 'One', Mandatory)][ValidateRange(1, 14)][int]$Module,
    [Parameter(ParameterSetName = 'All')][switch]$All,
    [switch]$PassThru
)

Import-Module "$PSScriptRoot\..\scripts\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$results = [System.Collections.Generic.List[object]]::new()
$dc = Get-LabCredential -Domain

function Test-Check {
    param([int]$Mod, [string]$Name, [scriptblock]$Test)
    try { $ok = [bool](& $Test); $detail = '' } catch { $ok = $false; $detail = $_.Exception.Message }
    $results.Add([pscustomobject]@{ Module = $Mod; Status = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $Name; Detail = $detail })
}
function In-VM { param($vm, [scriptblock]$sb, $argList) Invoke-Command -VMName $vm -Credential $dc -ScriptBlock $sb -ArgumentList $argList -ErrorAction Stop }

$checks = @{
    1 = {
        Test-Check 1 'Hyper-V role active on host'          { (Get-CimInstance Win32_ComputerSystem).HypervisorPresent }
        Test-Check 1 'VMMS service running'                  { (Get-Service vmms).Status -eq 'Running' }
        Test-Check 1 'Default VM path under LabRoot'         { (Get-VMHost).VirtualMachinePath -like "$($cfg.LabRoot)*" }
    }
    2 = {
        foreach ($k in 'Mgmt', 'Storage', 'Cluster') {
            $n = $cfg.Network[$k]
            Test-Check 2 "Switch $($n.Switch) is $($n.Type)" { (Get-VMSwitch -Name $n.Switch).SwitchType -eq $n.Type }
        }
        Test-Check 2 'Host gateway IP on Mgmt vNIC'          { Get-NetIPAddress -IPAddress $cfg.Network.Mgmt.Gateway -ErrorAction Stop }
        Test-Check 2 'NAT for lab subnet'                    { Get-NetNat | Where-Object InternalIPInterfaceAddressPrefix -eq "$($cfg.Network.Mgmt.Prefix).0/24" }
        Test-Check 2 'DC01 reaches the Internet through NAT' { In-VM DC01 { Test-NetConnection 1.1.1.1 -Port 443 -InformationLevel Quiet } }
        Test-Check 2 '[Exercise] VLAN lab: a VM adapter tagged with a training VLAN' {
            Get-VM | Get-VMNetworkAdapterVlan | Where-Object { $_.OperationMode -ne 'Untagged' -and $_.AccessVlanId -in $cfg.Network.VlanTrainingIds } }
    }
    3 = {
        foreach ($e in 'Desktop', 'Core') {
            $p = Join-Path $cfg.LabRoot "Images\WS2025-$e.vhdx"
            Test-Check 3 "Golden image $e exists and is read-only" { (Get-Item $p).IsReadOnly }
        }
        foreach ($d in $cfg.VMs) {
            Test-Check 3 "$($d.Name) is Gen 2 with Secure Boot"    { $v = Get-VM $d.Name; $v.Generation -eq 2 -and (Get-VMFirmware $v).SecureBoot -eq 'On' }
            Test-Check 3 "$($d.Name) boots from a differencing disk" { (Get-VHD (Get-VMHardDiskDrive -VMName $d.Name | Select-Object -First 1).Path).VhdType -eq 'Differencing' }
        }
        Test-Check 3 '[Exercise] Sysprepped template VHDX in Templates\' { Get-ChildItem (Join-Path $cfg.LabRoot 'Templates') -Filter *.vhdx -ErrorAction Stop }
    }
    4 = {
        Test-Check 4 'Domain hvlab.internal answers on DC01'  { Test-LabDomainReady }
        Test-Check 4 'DNS resolves hv01.hvlab.internal'       { In-VM DC01 { Resolve-DnsName "hv01.$($args[0])" -ErrorAction Stop } $cfg.Domain.FQDN }
        Test-Check 4 'Reverse zone for 10.10.0.0/24'          { In-VM DC01 { Get-DnsServerZone -Name '0.10.10.in-addr.arpa' } }
        Test-Check 4 'DHCP authorized with an active scope'   { In-VM DC01 { (Get-DhcpServerInDC) -and ((Get-DhcpServerv4Scope).State -contains 'Active') } }
        Test-Check 4 'All members are domain joined'          {
            $m = $cfg.VMs | Where-Object Role -ne 'DC'
            -not ($m | Where-Object { -not (In-VM $_.Name { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }) }) }
        Test-Check 4 'Hyper-V hosts are in OU=Hyper-V Hosts'  { In-VM DC01 { (Get-ADComputer HV01).DistinguishedName -like '*OU=Hyper-V Hosts*' } }
    }
    5 = {
        foreach ($h in ($cfg.VMs | Where-Object Role -eq 'HyperV').Name) {
            Test-Check 5 "$h exposes virtualization extensions" { (Get-VMProcessor -VMName $h).ExposeVirtualizationExtensions }
            Test-Check 5 "$h has MAC spoofing on"               { -not (Get-VMNetworkAdapter -VMName $h | Where-Object MacAddressSpoofing -ne 'On') }
            Test-Check 5 "$h runs Hyper-V with a SET switch"    { In-VM $h { (Get-VMSwitch -Name SETswitch).EmbeddedTeamingEnabled } }
            Test-Check 5 "$h live migration uses Kerberos"      { In-VM $h { $v = Get-VMHost; $v.VirtualMachineMigrationEnabled -and $v.VirtualMachineMigrationAuthenticationType -eq 'Kerberos' } }
        }
        Test-Check 5 'Constrained delegation HV01 -> HV02'      { In-VM DC01 { (Get-ADComputer HV01 -Properties msDS-AllowedToDelegateTo).'msDS-AllowedToDelegateTo' -match 'Migration Service/HV02' } }
    }
    6 = {
        Test-Check 6 'iSCSI target has two LUNs mapped'        { In-VM STOR01 { @((Get-IscsiServerTarget).LunMappings).Count -ge 2 } }
        foreach ($n in $cfg.Cluster.Nodes) {
            Test-Check 6 "$n has a persistent iSCSI session"    { In-VM $n { Get-IscsiSession | Where-Object { $_.IsConnected -and $_.IsPersistent } } }
            Test-Check 6 "$n MPIO claims iSCSI"                 { In-VM $n { (Get-MSDSMAutomaticClaimSettings)['iSCSI'] } }
        }
        Test-Check 6 '[Exercise] Second iSCSI path (MPIO paths >= 2) on HV01' { In-VM HV01 { (Get-IscsiSession | Where-Object IsConnected | Measure-Object).Count -ge 2 } }
    }
    7 = {
        $n = $cfg.Cluster.Nodes[0]
        Test-Check 7 'Cluster nodes are Up'                    { In-VM $n { -not (Get-ClusterNode | Where-Object State -ne 'Up') } }
        Test-Check 7 'Quorum uses a witness'                   { In-VM $n { (Get-ClusterQuorum).QuorumResource } }
        Test-Check 7 'At least one CSV online'                 { In-VM $n { Get-ClusterSharedVolume | Where-Object State -eq 'Online' } }
        Test-Check 7 'Storage network carries no cluster traffic' { In-VM $n { (Get-ClusterNetwork | Where-Object Name -eq 'Storage').Role -eq 'None' } }
        Test-Check 7 'Clustered VMs online'                    { In-VM $n { Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VirtualMachine' -and $_.State -eq 'Online' } } }
        Test-Check 7 '[Exercise] Cluster-Aware Updating role added' { In-VM $n { Get-ClusterResource | Where-Object ResourceType -like 'ClusterAwareUpdatingResource' } }
    }
    8 = {
        $n = $cfg.Cluster.Nodes[0]
        Test-Check 8 'VMs exist on both nodes (balanced/migrated)' { In-VM $n { @(Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine' | ForEach-Object { $_.OwnerNode.Name } | Sort-Object -Unique).Count -ge 2 } }
        Test-Check 8 '[Exercise] Live migration events logged'      { In-VM $n { Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-VMMS-Admin' -MaxEvents 1000 | Where-Object Message -like '*migration*completed*' } }
        Test-Check 8 '[Exercise] A VM was moved to HV03 (shared nothing)' { In-VM HV03 { Get-VM | Where-Object { $_.Name -like 'SHELL*' -and $_.ReplicationMode -ne 'Replica' } } }
    }
    9 = {
        Test-Check 9 'HV03 is a replica server'                { In-VM HV03 { (Get-VMReplicationServer).ReplicationEnabled } }
        Test-Check 9 'Replica Broker role online'              { In-VM HV01 { Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VMReplicaBroker' -and $_.State -eq 'Online' } } }
        Test-Check 9 'Replicas on HV03 are healthy'            { In-VM HV03 { $r = Get-VMReplication; $r -and -not ($r | Where-Object Health -ne 'Normal') } }
        Test-Check 9 '[Exercise] Test failover VM was created and cleaned up' { In-VM HV03 { Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-VMMS-Admin' -MaxEvents 1000 | Where-Object Message -like '*test failover*' } }
    }
    10 = {
        Test-Check 10 'Lab VMs default to Production checkpoints' { -not (Get-VM | Where-Object { $_.Notes -like 'HVLAB*' -and $_.CheckpointType -ne 'Production' }) }
        Test-Check 10 '[Exercise] A VM export exists in Exports\'  { Get-ChildItem (Join-Path $cfg.LabRoot 'Exports') -Directory -ErrorAction Stop }
        Test-Check 10 '[Exercise] Windows Server Backup on HV03'  { In-VM HV03 { (Get-WindowsFeature Windows-Server-Backup).Installed } }
    }
    11 = {
        Test-Check 11 '[S2D track] Storage pool healthy'        { In-VM HV01 { (Get-StoragePool -FriendlyName 'S2D*').HealthStatus -eq 'Healthy' } }
        Test-Check 11 '[S2D track] Mirrored virtual disk'       { In-VM HV01 { (Get-VirtualDisk).ResiliencySettingName -contains 'Mirror' } }
    }
    12 = {
        Test-Check 12 'RSAT Hyper-V tools on MGMT01'            { In-VM MGMT01 { (Get-WindowsFeature RSAT-Hyper-V-Tools).Installed } }
        Test-Check 12 'Failover Cluster Manager on MGMT01'      { In-VM MGMT01 { (Get-WindowsFeature RSAT-Clustering-Mgmt).Installed } }
        Test-Check 12 'Windows Admin Center service running'    { In-VM MGMT01 { Get-Service WindowsAdminCenter* | Where-Object Status -eq 'Running' } }
        Test-Check 12 'MGMT01 can manage the cluster remotely'  { In-VM MGMT01 { Get-ClusterNode -Cluster $args[0] } -argList $cfg.Cluster.Name }
    }
    13 = {
        Test-Check 13 '[Optional] HGS client configured on HV01' { In-VM HV01 { (Get-HgsClientConfiguration).AttestationServerUrl } }
        Test-Check 13 'vTPM demo VM has TPM enabled'            { In-VM HV01 { (Get-VMSecurity -VMName VTPM01).TpmEnabled } }
        Test-Check 13 '[Exercise] JEA endpoint for HV-Operators' { In-VM HV01 { Get-PSSessionConfiguration -Name 'HVOperator' } }
    }
    14 = {
        Test-Check 14 '[Exercise] Resource metering on a clustered VM' { In-VM HV01 { Get-VM | Where-Object ResourceMeteringEnabled } }
        Test-Check 14 '[Exercise] Data collector set "HVLAB-Perf" exists' { In-VM HV01 { logman query 'HVLAB-Perf' | Select-String 'HVLAB-Perf' } }
        Test-Check 14 'No critical VMMS events in last 24h on HV01'  { In-VM HV01 { -not (Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Hyper-V-VMMS-Admin'; Level = 1; StartTime = (Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue) } }
    }
}

$mods = if ($All) { 1..14 } else { @($Module) }
foreach ($m in $mods) { & $checks[$m] }

$results | Format-Table Module, Status, Check, Detail -AutoSize -Wrap
$pass = @($results | Where-Object Status -eq 'PASS').Count
Write-Host ("{0}/{1} checks passed" -f $pass, $results.Count) -ForegroundColor $(if ($pass -eq $results.Count) { 'Green' } else { 'Yellow' })
if ($PassThru) { $results }
