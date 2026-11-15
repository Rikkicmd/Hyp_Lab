@{
    # ------------------------------------------------------------------
    # Hyper-V Training Lab - central configuration
    # Every script reads this file. Change values here, not in scripts.
    # Sized for ONE physical host: Windows Server 2025, 64 GB RAM,
    # 8+ cores with VT-x/AMD-V + SLAT, ~600 GB free SSD/NVMe.
    # ------------------------------------------------------------------

    LabName        = 'HVLAB'
    LabRoot        = 'D:\HVLab'                 # VMs, disks, images, logs live here
    IsoPath        = 'D:\ISO\WindowsServer2025.iso'  # Evaluation ISO is fine
    ImageIndexName = 'Windows Server 2025 Datacenter Evaluation (Desktop Experience)'
    CoreImageName  = 'Windows Server 2025 Datacenter Evaluation'   # Server Core edition
    TimeZone       = 'UTC'
    InputLocale    = 'en-US'

    # Lab-only credential. NEVER reuse a real password here.
    AdminPassword  = 'P@ssw0rd!Lab2025'

    Domain = @{
        FQDN         = 'hvlab.internal'
        NetBIOS      = 'HVLAB'
        SafeModePwd  = 'P@ssw0rd!Dsrm2025'
        OUs          = @('Lab Servers', 'Hyper-V Hosts', 'Service Accounts', 'Lab Users', 'Lab Groups')
    }

    Network = @{
        # Internal switch + host NAT gives every VM outbound Internet without touching your LAN.
        Mgmt    = @{ Switch = 'HVLAB-Mgmt';    Type = 'Internal'; Prefix = '10.10.0';  Length = 24; Gateway = '10.10.0.1'; NatName = 'HVLAB-NAT' }
        # Private switches never leave the host: storage and cluster/live-migration traffic.
        Storage = @{ Switch = 'HVLAB-Storage'; Type = 'Private';  Prefix = '10.10.20'; Length = 24 }
        Cluster = @{ Switch = 'HVLAB-Cluster'; Type = 'Private';  Prefix = '10.10.30'; Length = 24 }
        DnsServer   = '10.10.0.10'
        DhcpScope   = @{ Start = '10.10.0.100'; End = '10.10.0.199'; Name = 'HVLAB-Clients' }
        VlanTrainingIds = @(10, 20, 30)   # used in Module 02 VLAN exercises
    }

    # Role-based VM definitions. Memory in bytes (PowerShell understands GB/MB suffixes).
    # Nested Hyper-V hosts MUST use static memory and ExposeVirtualizationExtensions.
    VMs = @(
        @{ Name = 'DC01';    Role = 'DC';      Edition = 'Core';    CPU = 2; MemStartup = 2GB;  MemMin = 1GB; MemMax = 4GB;  Dynamic = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 10 }) }

        @{ Name = 'MGMT01';  Role = 'Mgmt';    Edition = 'Desktop'; CPU = 2; MemStartup = 4GB;  MemMin = 2GB; MemMax = 6GB;  Dynamic = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 20 }) }

        @{ Name = 'STOR01';  Role = 'Storage'; Edition = 'Core';    CPU = 2; MemStartup = 2GB;  MemMin = 1GB; MemMax = 4GB;  Dynamic = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 30 }, @{ Net = 'Storage'; IP = 30 })
           DataDisks = @(200GB) }

        @{ Name = 'HV01';    Role = 'HyperV';  Edition = 'Core';    CPU = 4; MemStartup = 12GB; Dynamic = $false; Nested = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 11 }, @{ Net = 'Storage'; IP = 11 }, @{ Net = 'Cluster'; IP = 11 }) }

        @{ Name = 'HV02';    Role = 'HyperV';  Edition = 'Core';    CPU = 4; MemStartup = 12GB; Dynamic = $false; Nested = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 12 }, @{ Net = 'Storage'; IP = 12 }, @{ Net = 'Cluster'; IP = 12 }) }

        # Standalone host: Hyper-V Replica target + shared-nothing live migration partner.
        @{ Name = 'HV03';    Role = 'HyperV';  Edition = 'Core';    CPU = 4; MemStartup = 8GB;  Dynamic = $false; Nested = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 13 }) }
    )

    # Optional VMs, created only with -IncludeOptional on 04-New-LabVMs.ps1
    OptionalVMs = @(
        # Host Guardian Service lives in its OWN forest (Module 13).
        @{ Name = 'HGS01';   Role = 'HGS';     Edition = 'Core';    CPU = 2; MemStartup = 2GB;  MemMin = 1GB; MemMax = 3GB;  Dynamic = $true
           Nics = @(@{ Net = 'Mgmt'; IP = 40 }) }
    )

    Cluster = @{
        Name        = 'HVCLU01'
        IP          = '10.10.0.50'
        Nodes       = @('HV01', 'HV02')
        CsvLunSize  = 120GB
        WitnessSize = 1GB
        IscsiTarget = 'HVCLU01-Target'
    }

    S2D = @{
        # Module 11 alternative track: data disks added to each node instead of iSCSI.
        DisksPerNode = 4
        DiskSize     = 64GB
    }

    Replica = @{
        Server     = 'HV03'
        BrokerName = 'HVCLU01-RB'
        BrokerIP   = '10.10.0.51'
        Port       = 80     # Kerberos/HTTP. Module 09 also covers 443/certificates.
        StoragePath = 'C:\ReplicaStorage'
    }
}
