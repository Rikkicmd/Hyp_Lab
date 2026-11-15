# Module 02: Virtual Networking

**Time:** 2 h · **Script:** `02-New-LabNetwork.ps1`

## Objectives
- Choose the right virtual switch type for each traffic class
- Build NAT networking for an isolated lab
- Configure VLANs, bandwidth management, port ACLs and port mirroring
- Understand SET (Switch Embedded Teaming) and converged networking

## Concepts

### Switch types
| Type | Who can talk | Typical use |
|---|---|---|
| **External** | VMs ↔ host ↔ physical network (bound to a pNIC) | Production VM traffic, management |
| **Internal** | VMs ↔ host only | Labs, host-to-VM tooling, NAT gateways |
| **Private** | VMs ↔ VMs on the same host only | Isolated storage/heartbeat in labs, malware sandboxes |

In this lab, **Mgmt** is internal (the host is the router/NAT), while **Storage** and **Cluster** are private, so even the host cannot see that traffic. This simulates physically isolated fabrics.

### Production traffic classes (the classic list)
| Traffic | Typical isolation | QoS |
|---|---|---|
| Management | VLAN / host vNIC | Low weight |
| Cluster / CSV | VLAN / host vNIC | Medium |
| Live migration | VLAN / host vNIC or SMB Direct (RDMA) | High burst, capped |
| Storage (iSCSI/SMB) | Dedicated NICs or VLAN, jumbo frames | Guaranteed |
| VM traffic | Trunk to the vSwitch, VLAN per VM | Per-VM limits |

### SET vs LBFO
Since Server 2016, **Switch Embedded Teaming (SET)** is the recommended teaming method on Hyper-V hosts. Since Server 2022, creating a vSwitch on an LBFO team is blocked. SET supports up to 8 identical NICs, works with RDMA/SDN, and uses Hyper-V Port or Dynamic load balancing. You configure SET on HV01-HV03 in Module 05.

### Converged networking pattern
One SET switch on 2+ fast NICs, with several **host vNICs** (`Add-VMNetworkAdapter -ManagementOS`) for Mgmt, Cluster and LM, each tagged with a VLAN and given a minimum-bandwidth weight. This is the standard design in WSSD/Azure Local-style deployments.

### NAT
`New-NetNat` gives an internal switch outbound access through the host. There is only **one NetNat per host**. Port-forwarding: `Add-NetNatStaticMapping`.

## Build
```powershell
.\02-New-LabNetwork.ps1
Get-VMSwitch; Get-NetNat; Get-NetIPAddress -InterfaceAlias 'vEthernet (HVLAB-Mgmt)'
```

<details><summary>Manual equivalent</summary>

```powershell
New-VMSwitch -Name HVLAB-Mgmt    -SwitchType Internal
New-VMSwitch -Name HVLAB-Storage -SwitchType Private
New-VMSwitch -Name HVLAB-Cluster -SwitchType Private
New-NetIPAddress -InterfaceAlias 'vEthernet (HVLAB-Mgmt)' -IPAddress 10.10.0.1 -PrefixLength 24
New-NetNat -Name HVLAB-NAT -InternalIPInterfaceAddressPrefix 10.10.0.0/24
```
GUI: Hyper-V Manager > Virtual Switch Manager.
</details>

## Exercises
Do these after Module 03 (when VMs exist). Use MGMT01 and DC01, or create two throwaway VMs.

**1. VLAN isolation.** Put MGMT01's adapter on access VLAN 10 and test whether it can still ping DC01. Then put DC01 on VLAN 10 too, and explain the result. Put both back to untagged afterwards. For the validation check, create a throwaway VM and leave it tagged with VLAN 20.
<details><summary>Solution</summary>

```powershell
Set-VMNetworkAdapterVlan -VMName MGMT01 -Access -VlanId 10     # ping DC01 fails: different VLANs on the same switch
Set-VMNetworkAdapterVlan -VMName DC01   -Access -VlanId 10     # works again: same VLAN
Set-VMNetworkAdapterVlan -VMName DC01,MGMT01 -Untagged
# For the validation check, use a spare VM:
New-VM -Name VLANTEST -Generation 2 -MemoryStartupBytes 512MB -SwitchName HVLAB-Mgmt -Path D:\HVLab\VMs
Set-VM VLANTEST -Notes 'HVLAB exercise'
Set-VMNetworkAdapterVlan -VMName VLANTEST -Access -VlanId 20
```
The vSwitch acts like an 802.1Q switch. Untagged and VLAN 10 are different broadcast domains even on the same switch. The host vNIC is untagged, so tagged VMs also lose the NAT gateway.
</details>

**2. Trunk mode.** Configure a VM adapter as a trunk carrying VLANs 10, 20 and 30 with native VLAN 0. When would you do this in production?
<details><summary>Solution</summary>

`Set-VMNetworkAdapterVlan -VMName VLANTEST -Trunk -AllowedVlanIdList 10,20,30 -NativeVlanId 0`. Use it for virtual routers/firewalls (NVA) or nested hosts that tag traffic themselves.
</details>

**3. Bandwidth management.** Cap MGMT01 at 100 Mbps and guarantee a weight of 20.
<details><summary>Solution</summary>

Weight mode must be chosen when the switch is created (`-MinimumBandwidthMode Weight`), so for an existing switch use the maximum only:
`Set-VMNetworkAdapter -VMName MGMT01 -MaximumBandwidth 100000000`. Recreate a test switch with `-MinimumBandwidthMode Weight` to practise `-MinimumBandwidthWeight 20`.
</details>

**4. Port mirroring.** Mirror DC01's traffic to MGMT01 and capture DNS queries with `pktmon` on MGMT01.
<details><summary>Solution</summary>

```powershell
Set-VMNetworkAdapter -VMName DC01   -PortMirroring Source
Set-VMNetworkAdapter -VMName MGMT01 -PortMirroring Destination
# MGMT01: pktmon start --capture --pkt-size 0 -f C:\Temp\dns.etl; ...; pktmon stop; pktmon etl2pcap C:\Temp\dns.etl
```
Set both back to `None` afterwards.
</details>

**5. Extended port ACLs.** Block RDP (TCP 3389) inbound to DC01 at the vSwitch, without touching the guest firewall.
<details><summary>Solution</summary>

`Add-VMNetworkAdapterExtendedAcl -VMName DC01 -Action Deny -Direction Inbound -LocalPort 3389 -Protocol TCP -Weight 10`. Remove with `Remove-VMNetworkAdapterExtendedAcl`.
</details>

**6. DHCP guard / router guard.** Why should every VM *except* DC01 have DHCP Guard enabled? Enable it on MGMT01.
<details><summary>Solution</summary>

DHCP Guard drops DHCP server offers from a VM, which stops rogue DHCP servers. `Set-VMNetworkAdapter -VMName MGMT01 -DhcpGuard On -RouterGuard On`.
</details>

**7. NAT port forward.** Make MGMT01's RDP reachable on the host at port 33389.
<details><summary>Solution</summary>

`Add-NetNatStaticMapping -NatName HVLAB-NAT -Protocol TCP -ExternalIPAddress 0.0.0.0 -ExternalPort 33389 -InternalIPAddress 10.10.0.20 -InternalPort 3389`
</details>

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 2
```

## Review questions
1. Which switch type would you use for an iSCSI network that must not reach the host?
2. Why is LBFO no longer used for Hyper-V switches?
3. What does MAC address spoofing do, and when is it required?
4. Describe a converged networking design for a 2 x 25 GbE host.
