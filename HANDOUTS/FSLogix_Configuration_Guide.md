# FSLogix Configuration Guide - AVD Anywhere

## What is FSLogix?

FSLogix is Microsoft's solution for managing user profiles and application containers in virtual desktop environments. Instead of storing profiles locally on session hosts, FSLogix redirects profiles to a centralized location, providing:

- **Profile Portability** - Users get the same profile regardless of session host
- **Reduced Session Host Footprint** - Profiles stored centrally, not on each VM
- **Rapid Deployment** - No profile initialization delay
- **Application Layering** - Application containers isolated from user profiles

## Profile Container Architecture

**Traditional (Local) Profile:**
```
Session Host VM
├── User Profile (C:\Users\username)
│   ├── Documents
│   ├── Desktop
│   ├── AppData\Roaming (app settings)
│   └── AppData\Local (temp, cache)
└── Lost when user logs off or VM is replaced
```

**FSLogix Profile Container:**
```
FSLogix Profile Container (VHD/VHDX)
├── User Profile (C:\Users\username)
│   ├── Documents
│   ├── Desktop
│   ├── AppData\Roaming
│   └── AppData\Local
│
Stored on Central Storage (Azure Files / SMB / NAS)
├── Portable across all session hosts
├── Survives session host replacement
└── Attached via FSLogix driver on sign-on
```

## Three Deployment Models = Three Storage Paths

### Model 1: Azure Deployment Storage

**Storage Technology:** Azure Files (SMB 3.1.1 over HTTPS)

**Advantages:**
- Managed by Azure; no on-premises storage infrastructure
- Azure Files native encryption at rest
- Auto-scaling; no capacity planning
- Built-in redundancy (LRS, GRS, GZRS options)
- Entra ID Kerberos authentication (native identity integration)

**FSLogix Configuration:**
```
VHDLocations = \\<storage-account>.file.core.windows.net\<share>\<path>
CloudCacheLocations = <optional for performance>
IsDynamic = 1  (containers expand as needed)
```

**Authentication:**
```
# Azure Files supports Entra ID Kerberos
# Session host must be Entra ID-joined
# No additional credentials needed (transparent auth)
```

**Example Configuration:**
```
Storage Account: avdprofiles.file.core.windows.net
Share: fslogix-profiles
Path: \\avdprofiles.file.core.windows.net\fslogix-profiles\Profile
```

---

### Model 2: Azure Local Deployment Storage

**Storage Technology:** Cluster CSV (Cluster Shared Volume) or SMB scale-out file server

**Advantages (CSV):**
- Built into Azure Local; no external dependency
- High performance (local cluster network)
- Integrated backup/replication
- No redundant network hops

**Advantages (SMB Scale-out):**
- External NAS for independence
- Redundancy across storage controllers
- Can be shared with other workloads

**FSLogix Configuration (CSV):**
```
VHDLocations = \\<cluster-name>\ClusterStorage$\fslogix-profiles
CloudCacheLocations = <optional>
IsDynamic = 1
```

**FSLogix Configuration (SMB Scale-out):**
```
VHDLocations = \\<smb-server>\fslogix-profiles
CloudCacheLocations = <optional>
IsDynamic = 1
```

**Authentication:**
- CSV: Cluster identity (internal, transparent)
- SMB: Local Identity or on-premises AD credentials

**Example Configuration:**
```
Cluster CSV:
\\azurelocal-cluster\ClusterStorage$\fslogix\Profile

External SMB:
\\smb-scale-out.internal\fslogix-profiles\Profile
```

---

### Model 3: Hybrid Deployment Storage

**Storage Technology:** On-premises NAS, SMB scale-out, or platform-native (vSAN, Nutanix Files)

**Advantages:**
- Uses existing on-premises storage infrastructure
- No Azure dependency for profile storage
- Can leverage existing backup/replication
- Works with Windows Server, VMware, Nutanix

**Sub-Options:**

**Option 3a: SMB Scale-out File Server**
```
VHDLocations = \\<smb-server>\fslogix-profiles
CloudCacheLocations = <local cache on session host>
IsDynamic = 1
```

**Option 3b: Third-Party NAS (NetApp, Isilon, etc.)**
```
VHDLocations = \\<nas-ip-or-name>\fslogix
CloudCacheLocations = <local cache>
IsDynamic = 1
```

**Option 3c: VMware vSAN**
```
# vSAN presented as SMB via scale-out file server or Hyper-Converged setup
VHDLocations = \\<vsan-smb-endpoint>\fslogix-profiles
```

**Option 3d: Nutanix Files**
```
VHDLocations = \\<nutanix-files-endpoint>\fslogix-profiles
CloudCacheLocations = <local cache>
IsDynamic = 1
```

**Authentication:**
- On-premises Active Directory credentials for SMB access
- Service account with permissions to profile shares

**Example Configuration:**
```
NAS SMB:
\\nas.internal.company.com\fslogix-profiles\Profile

Nutanix Files:
\\nutanix-files.internal\fslogix-profiles\Profile

vSAN SMB:
\\vsphere-smb-endpoint\fslogix-profiles\Profile
```

---

## FSLogix Configuration File Locations

### Windows Server (Hyper-V, Remote Desktop Services)
```
Group Policy: Computer Configuration\Policies\Administrative Templates\FSLogix\Profile Containers
Registry (if not using GPO): HKLM\Software\FSLogix\Profiles
```

### Azure / Azure Local Session Hosts
```
Group Policy (same as above): Computer Configuration\Policies\Administrative Templates\FSLogix\Profile Containers
OR
Configuration via Custom Script Extension or Template
```

### Key Configuration Options

```
VHDLocations = <path to profile storage>
        # UNC path to FSLogix profile storage

Enabled = 1
        # Enable FSLogix profile containers

IsDynamic = 1
        # Containers expand as needed (vs. fixed size)

VolumeType = VHDX
        # Use VHDX format (supports larger profiles)

DeleteLocalProfileWhenVHDShouldApply = 1
        # Remove local profile when FSLogix container detected
        # Prevents profile sync issues

FlipFlopDirectoryName = 0
        # Profile naming: Set to 1 if using flip-flop naming scheme

CloudCacheLocations = <optional local cache path>
        # Local cache on session host for performance
        # Especially useful for Hybrid/remote deployments
```

---

## Storage Performance Considerations

### Azure Files Performance
- **Typical:** 60 Mbps (SMB 3.0, standard tier)
- **Premium:** 100 Mbps+ (premium tier, higher cost)
- **Optimization:** Use Cloud Cache for frequently accessed profiles
- **Network:** Ensure sufficient bandwidth from session hosts to Azure

**Cloud Cache for Azure:**
```
CloudCacheLocations = C:\FSLogix-Cache
        # 15-30 GB local SSD for cache
        # Profiles cached locally; synced to Azure Files periodically
```

### Azure Local Performance
- **CSV (Local):** 500+ Mbps (cluster network, excellent)
- **SMB Scale-out:** 200-400 Mbps (depends on NIC/switch)
- **Optimization:** CSV preferred for performance; SMB for redundancy

### Hybrid Performance
- **On-premises NAS:** Varies (typically 100-400 Mbps)
- **vSAN:** 200-500 Mbps (cluster network dependent)
- **Nutanix Files:** 200-500 Mbps
- **Optimization:** Local Cloud Cache essential for remote locations
  ```
  CloudCacheLocations = C:\FSLogix-Cache or D:\FSLogix-Cache
  ```

---

## Sizing Guide: Storage Capacity

### Profile Container Sizes

**Light User** (minimal documents, small AppData):
- 2-5 GB per profile

**Standard User** (typical documents, moderate AppData):
- 5-15 GB per profile

**Power User** (large documents, many applications):
- 15-30 GB per profile

**Calculation:**
```
Total Storage = (Number of Users × Average Profile Size) × Growth Factor (1.3 for 30% overhead)

Example:
1000 users × 10 GB avg × 1.3 = 13 TB total storage required
```

### Storage Redundancy

**Azure Files:**
- LRS (Local Redundant Storage): 1x replication (within region)
- GRS (Geo-Redundant Storage): 2x replication (across regions)
- Recommended: GRS for critical deployments

**Azure Local:**
- CSV: Built-in cluster replication
- SMB Scale-out: RAID-based redundancy

**Hybrid:**
- NAS: RAID-6 or similar (double fault tolerance)
- vSAN: Ensure adequate cluster size (minimum 3 nodes)
- Nutanix: Native redundancy (RF2 or RF3)

---

## Troubleshooting Common FSLogix Issues

### Issue: Profile Not Loading

**Symptoms:**
- User logs in with temporary profile
- FSLogix driver not attaching container

**Diagnostics:**
```powershell
# Check FSLogix service
Get-Service -Name FSLogix | Select-Object Status, StartType

# Check event logs
Get-WinEvent -LogName "System" | Where-Object {$_.ProviderName -match "FSLogix"}

# Verify storage path accessibility
Test-NetConnection -ComputerName <storage-server> -Port 445

# Check file permissions
icacls "\\<storage-path>"
```

**Solutions:**
1. Verify network connectivity to storage
2. Check storage path permissions (user/service account needs Full Control)
3. Verify FSLogix service running on session host
4. Check disk space on storage and session host
5. Review FSLogix event logs for specific errors

### Issue: Slow Profile Loading

**Symptoms:**
- Prolonged login time (>30 seconds)
- High disk I/O during profile attach

**Diagnostics:**
```powershell
# Monitor profile size
Get-ChildItem -Path "\\<storage-path>" | Sort-Object Length -Descending | Select-Object Name, @{N="SizeGB";E={$_.Length/1GB}} | Head -10

# Check network latency
Measure-NetLatency -ComputerName <storage-server>

# Monitor disk performance
Get-Counter -Counter "\Physical Disk(*)\% Disk Time" -SampleInterval 1 -MaxSamples 60
```

**Solutions:**
1. Enable Cloud Cache for local caching
2. Reduce profile size (archive old documents)
3. Optimize storage backend (add IOPS, increase bandwidth)
4. Check network latency (ExpressRoute for hybrid)
5. Consider tiering (frequently accessed profiles on faster storage)

### Issue: Profile Corruption

**Symptoms:**
- User reports missing files or settings
- FSLogix container mount fails

**Prevention:**
1. Regular backups of profile storage
2. Monitor free disk space (don't let storage fill >80%)
3. Enable crash dumps for FSLogix driver

**Recovery:**
```powershell
# Detach corrupted profile
Remove-Item -Path "\\<storage-path>\<profile>" -Force

# User gets fresh profile on next login
# Data in backup or cloud can be recovered
```

---

## Portable Profile Strategy (Across All Three Models)

To enable users to move seamlessly between Azure, Azure Local, and Hybrid deployments:

### Step 1: Standardized Naming
```
Azure:       \\storageaccount.file.core.windows.net\fslogix\<username>
Azure Local: \\azurelocal-cluster\clusterStorage$\fslogix\<username>
Hybrid:      \\smb-server.internal\fslogix\<username>
```

### Step 2: Identical Container Configuration
All deployments use same FSLogix settings:
```
Same IsDynamic, VolumeType, CloudCache settings
Different VHDLocations only
```

### Step 3: User Mapping
```
Host Pool 1 (Azure) → Azure Files Path
Host Pool 2 (Azure Local) → Cluster CSV Path
Host Pool 3 (Hybrid) → On-premises NAS Path

User signs into workspace → AVD routes to appropriate host pool → Profile loads from designated storage
```

### Step 4: Profile Sync (Optional)
For true portability, implement async sync:
```powershell
# Scheduled task on each deployment model
# Copies profiles between storage tiers for replication
# Enables user mobility without data loss
```

---

## Security Best Practices

### Access Control
```
FSLogix share permissions:
├─ Modify: Authenticated Users (or service account)
├─ Read: Everyone (limited visibility)
└─ Full Control: Administrators + SYSTEM account
```

### Encryption

**Azure Files:**
- Encryption at rest: Always on (AES-256)
- Encryption in transit: SMB 3.1.1 + HTTPS
- No additional configuration needed

**On-Premises NAS:**
- Enable NAS encryption if available
- Use IPsec or TLS for transit security
- Ensure strong access credentials (avoid default passwords)

**Nutanix Files:**
- Enable Nutanix encryption (encryption at rest + in transit)
- Configure role-based access

### Monitoring
```powershell
# Monitor profile container access
Enable-PSRemoting -Force
Invoke-Command -ComputerName <session-hosts> -ScriptBlock {
    Get-NetTCPConnection -LocalPort 445 -State Established | 
    Where-Object {$_.RemoteAddress -match "<storage-server>"} |
    Select-Object LocalAddress, RemoteAddress, State
}
```

---

## Configuration Checklist

- [ ] FSLogix installed on all session hosts
- [ ] Storage path validated and accessible
- [ ] Permissions configured (Modify for users, Full Control for system)
- [ ] FSLogix Group Policy or registry configured
- [ ] Profile container location verified (Test with single user)
- [ ] Cloud Cache enabled (if using remote storage)
- [ ] Profile size monitored (baseline established)
- [ ] Backup strategy implemented
- [ ] Failover tested (storage unavailability)
- [ ] Performance baselines recorded

---

## Next Steps

1. Deploy FSLogix using configuration from your deployment model (Azure, Azure Local, or Hybrid)
2. Test with pilot users before production
3. Monitor performance and adjust Cloud Cache settings
4. Plan for profile migration if moving from local profiles
5. Implement backup/recovery strategy

