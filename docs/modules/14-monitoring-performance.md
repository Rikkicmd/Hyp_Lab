# Module 14: Monitoring, Performance & Capacity

**Time:** 1.5 h · **Scripts:** none

## Objectives
- Measure host and VM performance with the right counters (not Task Manager)
- Use resource metering for chargeback and capacity trending
- Know the event logs and health tools that matter
- Size and plan capacity for a cluster

## Concepts

### Why Task Manager lies on a Hyper-V host
The root partition is itself a VM. Its Task Manager only shows the root's own vCPUs. Use the **Hyper-V Hypervisor Logical Processor** counters for true host CPU.

### Key counters
| Area | Counter | Healthy |
|---|---|---|
| Host CPU | `\Hyper-V Hypervisor Logical Processor(_Total)\% Total Run Time` | < 75% sustained |
| VM CPU | `\Hyper-V Hypervisor Virtual Processor(*)\% Guest Run Time` | Workload dependent |
| CPU contention | `\Hyper-V Hypervisor Virtual Processor(*)\CPU Wait Time Per Dispatch` | Low and stable (rising means oversubscription) |
| Memory | `\Hyper-V Dynamic Memory Balancer(*)\Available Memory`, `\Memory\Available MBytes` | > 10% free |
| Dynamic memory | `\Hyper-V Dynamic Memory VM(*)\Current Pressure` | < 100 |
| Storage latency | `\Hyper-V Virtual Storage Device(*)\Latency` / `\Cluster CSV File System(*)\Read Latency`, `Write Latency` | < 10 ms SSD, < 20 ms HDD |
| Network | `\Hyper-V Virtual Network Adapter(*)\Bytes/sec`, `\Hyper-V Virtual Switch(*)\Dropped Packets Outgoing/sec` | No drops |
| CSV | `\Cluster CSV File System(*)\Redirected Read Bytes/sec` | 0 (anything else means redirected I/O) |

### Event logs that matter
- `Microsoft-Windows-Hyper-V-VMMS-Admin`: VM management, migrations, replica
- `Microsoft-Windows-Hyper-V-Worker-Admin`: per-VM worker process issues
- `Microsoft-Windows-FailoverClustering/Operational` and `System` (source FailoverClustering, IDs 1069, 1135, 1146, 1177, 5120, 5142)
- `Microsoft-Windows-Hyper-V-VmSwitch-Operational`, `Microsoft-Windows-Hyper-V-High-Availability-Admin`

### Capacity planning rules of thumb
- **N+1:** a cluster must run all VMs with one node down. Usable RAM = (nodes - 1) x RAM per node - root reserve.
- vCPU:pCore ratios of 4:1 to 8:1 are typical for general server workloads. Track CPU Wait Time per Dispatch, not the ratio.
- Storage: plan IOPS and latency, not just capacity. Leave 20% of CSV free for checkpoints and merges.

## Exercises

**1. Live counters.** On HV01, sample host CPU, CSV latency and available memory every 2 s for 30 s.
<details><summary>Solution</summary>

```powershell
Get-Counter -Counter '\Hyper-V Hypervisor Logical Processor(_Total)\% Total Run Time',
  '\Cluster CSV File System(*)\Write Latency', '\Memory\Available MBytes' -SampleInterval 2 -MaxSamples 15
```
</details>

**2. Data collector set.** Create a Performance Monitor data collector set named `HVLAB-Perf` on HV01 with the key counters above, logging every 15 s, and start it.
<details><summary>Solution</summary>

```powershell
$c = '\Hyper-V Hypervisor Logical Processor(_Total)\% Total Run Time','\Hyper-V Dynamic Memory Balancer(*)\Available Memory','\Cluster CSV File System(*)\*Latency*','\Hyper-V Virtual Network Adapter(*)\Bytes/sec'
logman create counter HVLAB-Perf -c $c -si 15 -o C:\PerfLogs\HVLAB-Perf -f bincirc -max 256
logman start HVLAB-Perf
```
</details>

**3. Resource metering.** Enable resource metering on all VMs of the cluster, generate some load, then report average CPU, RAM, disk and network per VM. Reset the counters.
<details><summary>Solution</summary>

```powershell
Get-VM | Enable-VMResourceMetering
Get-VM | Measure-VM | ft VMName, AvgCPU, AvgRAM, TotalDisk, AggregatedAverageNormalizedIOPS
Get-VM | Reset-VMResourceMetering
```
</details>

**4. Cluster health.** Find all cluster events with IDs 1135 (node removed) and 1069 (resource failed) from the failover exercise in Module 07.
<details><summary>Solution</summary>

`Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering'; Id=1135,1069} | ft TimeCreated, Id, Message -Wrap`
</details>

**5. Capacity exercise.** HVCLU01 nodes have 12 GB each, with about 2 GB root reserve. How much VM memory can you commit while still tolerating one node failure? Check what is committed now, and report whether the cluster is N+1 compliant.
<details><summary>Solution</summary>

(2 - 1) x (12 - 2) = 10 GB. Committed: `Invoke-Command HV01,HV02 { (Get-VM | ? State -eq Running | Measure-Object MemoryAssigned -Sum).Sum/1GB }`. Add both nodes' figures and compare with 10 GB.
</details>

**6. Stretch: Azure Monitor / Insights.** Outline how you would onboard the cluster to Azure Arc and Azure Monitor (or SCOM) for alerting on the counters above.

## Validate
```powershell
..\validation\Test-LabModule.ps1 -Module 14
```

## Review questions
1. Which counter shows true host CPU usage, and why not Task Manager?
2. What does a rising CPU Wait Time Per Dispatch tell you?
3. What does non-zero CSV redirected I/O indicate?
4. Explain N+1 capacity for a 4-node cluster with 512 GB per node.
