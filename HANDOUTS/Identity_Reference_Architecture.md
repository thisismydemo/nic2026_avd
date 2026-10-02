# Identity Reference Architecture - AVD Anywhere

## Overview

This guide explains the identity architecture that enables Azure Virtual Desktop to work seamlessly across three distinct deployment models: Azure, Azure Local, and AVD Hybrid (on-premises with Windows Server, VMware vSphere, or Nutanix AHV).

The core principle: **One identity model, three deployment patterns.**

## Architecture Layers

### Layer 1: Entra ID (Microsoft Entra) - The Central Identity Authority

All three deployment models rely on **Microsoft Entra ID (formerly Azure AD)** as the authoritative identity source:

- **User accounts** - Managed in Entra ID
- **Group membership** - Application and session host assignment
- **Conditional access** - Security policies apply uniformly
- **MFA enforcement** - Multi-factor authentication across all models
- **Application sign-on** - Single sign-on (SSO) to applications running in session

#### Why Entra ID First?
- Native to Azure (obviously)
- Hybrid-capable with on-premises AD via Azure AD Connect
- Supports seamless sign-on across cloud and on-premises resources
- Built-in Conditional Access and identity governance

---

## Deployment Model Identity Patterns

### Pattern 1: AVD on Azure

**Architecture:**
```
Entra ID
    ↓
Azure (Entra ID joined VMs)
    ↓
AVD Session Hosts
    ↓
FSLogix profiles via Azure Files (Kerberos auth)
```

**Identity Flow:**
1. User authenticates to Entra ID
2. Token obtained from Entra ID
3. AVD control plane validates user against Entra ID
4. Session redirected to appropriate host pool
5. FSLogix profile retrieved from Azure Files using Kerberos (Entra ID integrated)

**Key Characteristics:**
- VMs are **Entra ID joined** (not domain-joined to on-premises AD)
- No on-premises domain controller dependency
- Azure Files integration uses Entra ID Kerberos authentication
- Cleanest cloud-native approach

**Configuration Checklist:**
- [ ] VMs joined to Entra ID during deployment
- [ ] Azure Files storage account configured for Entra ID authentication
- [ ] FSLogix container paths set to Azure Files UNC paths
- [ ] Conditional Access policies in place

---

### Pattern 2: AVD on Azure Local

**Architecture:**
```
Entra ID
    ↓
Azure Local (Arc-connected VMs)
    ↓
AVD Session Hosts
    ↓
FSLogix profiles via CSV or SMB (Local AD or Entra ID)
```

**Identity Flow:**
1. User authenticates to Entra ID
2. AVD control plane (in Azure) validates user against Entra ID
3. Session directed to Azure Local cluster
4. Session host resolves user identity locally (via Arc integration)
5. FSLogix profile retrieved from cluster storage (CSV) or SMB share

**Key Considerations:**
- Azure Local clusters can use **Local Identity** (new, password-less) or **Active Directory**
- Arc Resource Bridge connects Azure Local back to Azure/Entra ID
- FSLogix storage can be on cluster CSV or external SMB (for redundancy)
- Hybrid identity: Entra ID for session access, Local AD or Local Identity for resource access

**Two Sub-Patterns:**

#### Sub-Pattern 2a: Local Identity (Recommended for new deployments)
- Azure Local uses built-in Local Identity (no on-premises AD required)
- Entra ID for user sign-on
- Arc integration enables Azure-based management
- Password-less, certificate-based authentication

#### Sub-Pattern 2b: Active Directory Integrated (On-premises AD)
- Azure Local joined to on-premises AD domain
- Entra ID for AVD control plane access
- Entra ID Connect or similar for directory sync
- More complex but allows on-premises AD policies

**Configuration Checklist:**
- [ ] Azure Local cluster Arc-connected to Azure
- [ ] Local Identity initialized or AD domain configured
- [ ] FSLogix profile storage on CSV or external SMB
- [ ] Entra ID Conditional Access policies configured
- [ ] Arc agents deployed for monitoring

---

### Pattern 3: AVD Hybrid (On-Premises Hypervisors)

**Architecture:**
```
Entra ID
    ↓
Windows Server / vSphere / Nutanix (On-premises)
    ↓
AVD Agent (Hybrid mode)
    ↓
FSLogix profiles via on-prem storage
    ↓
Arc connectivity back to Azure/Entra ID
```

**Identity Flow:**
1. User authenticates to Entra ID (or on-premises AD with Entra ID sync)
2. AVD control plane (in Azure) routes to on-premises session host
3. Session host may use local AD or Entra ID (via Arc)
4. FSLogix profile retrieved from on-premises storage (SMB, NAS, platform-native)
5. Arc agent on session host reports back to Azure for monitoring

**Three Hypervisor Sub-Patterns:**

#### Sub-Pattern 3a: Windows Server Hyper-V
- Session hosts run on Windows Server with Hyper-V role
- VMs domain-joined to on-premises Active Directory
- Optional: Arc enablement for Azure monitoring
- FSLogix on SMB scale-out file server or local NAS

#### Sub-Pattern 3b: VMware vSphere
- Session hosts are vSphere VMs
- Domain-joined to on-premises AD (via vSphere AD plugin or traditional domain)
- Arc enablement via Arc-enabled servers
- FSLogix on vSAN, external SMB, or NAS

#### Sub-Pattern 3c: Nutanix AHV
- Session hosts are Nutanix VMs
- Domain-joined to on-premises AD
- Arc enablement for Azure governance
- FSLogix on Nutanix Files, external SMB, or NAS

**Key Characteristics:**
- Session hosts remain on-premises
- On-premises Active Directory for local resource access
- Entra ID for cloud-based access (AVD control plane)
- Arc integration bridges on-prem and cloud identity contexts
- Network connectivity to Azure required (ExpressRoute recommended)

**Configuration Checklist:**
- [ ] Session hosts domain-joined to on-premises AD
- [ ] Entra ID Connect (or similar) syncing users to cloud
- [ ] Arc-enabled servers configured and registered
- [ ] Firewall/network access to Entra ID endpoints
- [ ] FSLogix profile storage accessible from session hosts

---

## Cross-Model Identity Patterns

### 1. Profile Portability Between Models

**Challenge:** A user should be able to move between Azure, Azure Local, and Hybrid deployment models without losing their profile or application state.

**Solution:**
- **FSLogix Design:** Store profiles in a portable format and storage technology that all three models can access
- **Option A:** All profiles in Azure Files (requires network access from on-prem; not always feasible)
- **Option B:** Profiles stored per-deployment but synchronized (more complex)
- **Option C:** Unique profiles per model but configured identically (simplest)

**Recommended Approach:**
Use **portable FSLogix configuration files** that specify profile paths relative to the deployment model:
```
Azure: \\<storage-account>.file.core.windows.net\fslogix
Azure Local: \\<csv-path>\fslogix or \\<smb-server>\fslogix
Hybrid: \\<on-prem-nas>\fslogix
```

All use **identical FSLogix profile containers**, just different UNC paths based on deployment.

### 2. Unified Monitoring via Arc and Entra ID

**Challenge:** Monitor users and sessions across all three deployment models from a single Azure dashboard.

**Solution:**
- Deploy Arc agents on all session hosts (even Azure Local and Hybrid)
- Collect logs to Azure Log Analytics
- Use Azure Monitor for unified telemetry
- Map sessions back to Entra ID users for consistent reporting

### 3. Conditional Access Policies

**Challenge:** Apply consistent security policies across all deployment models.

**Solution:**
- Entra ID Conditional Access policies apply to AVD sign-on (all models)
- Policies enforce MFA, device compliance, location-based rules
- Session hosts inherit policies based on user's Entra ID posture

---

## Identity Security Best Practices

### Across All Models:
1. **Enable MFA** - Require multi-factor authentication at Entra ID level
2. **Conditional Access** - Block sign-on from unexpected locations or non-compliant devices
3. **Session Host Hardening** - Restrict RDP/console access; use Just-In-Time (JIT) access
4. **Profile Encryption** - Ensure FSLogix containers are encrypted at rest and in transit
5. **RBAC** - Use Azure Role-Based Access Control for session host/pool management

### Azure-Specific:
- Use Entra ID-only (no domain join) when possible
- Enable Azure Files Entra ID Kerberos authentication
- Disable NTLM if not required

### Azure Local-Specific:
- Use Local Identity if not requiring on-premises AD
- Enable Arc for centralized identity governance
- Audit Local Identity certificate rotation

### Hybrid-Specific:
- Ensure on-premises AD is secure (Tier 0 protection)
- Use Arc with Managed Identity for session host authentication
- Implement network segmentation (ExpressRoute, firewall rules)
- Regularly audit on-premises directory sync

---

## Decision Tree: Which Model for Your Organization?

```
Start: Do you have on-premises infrastructure?
├─ NO → Go to Azure
│   └─ Start with Entra ID-joined, Azure Files, FSLogix
│       └─ Simplest path; cloud-native identity
│
└─ YES → Do you need Azure Local (AI/ML, Edge)?
    ├─ NO → Use Hybrid (Hyper-V/vSphere/Nutanix)
    │   └─ Session hosts on-prem, Arc for monitoring
    │   └─ FSLogix on existing on-premises storage
    │
    └─ YES → Use Azure Local
        └─ New cluster deployed; choose Local Identity or AD
        └─ FSLogix on cluster CSV or SMB
        └─ Arc integration for Azure management
```

---

## Configuration Examples

### Example 1: Azure + Entra ID + Azure Files

```bicep
// Identity: Entra ID
// Session Hosts: Entra ID joined
// FSLogix Storage: Azure Files with Entra ID Kerberos
// No on-premises components required
```

### Example 2: Azure Local + Local Identity + Cluster CSV

```bicep
// Identity: Local Identity (Azure Local built-in)
// Session Hosts: Azure Local VMs, Arc-connected
// FSLogix Storage: Cluster CSV (built-in redundancy)
// Simplified, no on-premises AD needed
```

### Example 3: Hybrid + On-Premises AD + Entra ID Sync + SMB

```powershell
// Identity: On-premises AD (source), Entra ID (sync)
// Session Hosts: Windows Server Hyper-V, domain-joined
// FSLogix Storage: SMB scale-out file server
// FSLogix user credentials: On-premises AD accounts
// Arc agents report to Azure for monitoring
```

---

## Common Questions

**Q: Can I mix identity models in the same workspace?**
A: Yes! You can have some host pools Entra ID-only, others AD-joined. Users see one workspace; they just connect to the appropriate pool.

**Q: What if my on-premises AD is unavailable?**
A: If you're purely on Azure or use Azure Local with Local Identity, no on-prem dependency. Hybrid deployments need on-prem AD; use BCP/failover strategies.

**Q: Do I need to sync on-premises AD to Entra ID?**
A: For hybrid, yes (via Azure AD Connect). For Azure-only, no. For Azure Local with on-prem AD, yes.

**Q: Can FSLogix profiles move between models?**
A: If configured identically, yes. Different storage paths, same profile structure. Not automatic; requires planning.

---

## Summary

| Model | Identity Source | Storage | Complexity | On-Prem Dependency |
|-------|-----------------|---------|------------|-------------------|
| **Azure** | Entra ID only | Azure Files | Low | None |
| **Azure Local** | Local Identity or AD | Cluster CSV | Medium | Optional (AD) |
| **Hybrid** | On-prem AD + Entra ID | On-prem SMB/NAS | High | Required |

**Remember:** All three models use Entra ID as the access control layer. The identity *architecture* changes; the access *model* stays consistent.

---

## Next Steps

1. Read the Deployment Checklist to validate your identity setup
2. Review FSLogix_Configuration_Guide.md for storage integration details
3. Check Q&A_Resources.md for specific platform configurations
