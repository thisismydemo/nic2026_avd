# AVD Anywhere - Deployment Checklist

## Pre-Deployment Validation

- [ ] Azure subscription/Azure Local cluster access verified
- [ ] Required roles assigned (Contributor or higher)
- [ ] Resource quotas checked (VMs, storage, IP addresses)
- [ ] Network connectivity validated (no firewall blocks)
- [ ] Image artifacts prepared (Windows Server, AVD client)

## Identity Configuration

- [ ] Entra ID tenant configured (or on-premises AD + Azure AD Connect)
- [ ] User accounts and groups created
- [ ] Conditional Access policies designed
- [ ] MFA configured and tested
- [ ] Application permissions assigned
- [ ] Service principals created (if using automation)

## Storage & FSLogix Setup

- [ ] FSLogix storage provisioned (Azure Files / CSV / SMB / NAS)
- [ ] Storage access validated from session hosts
- [ ] FSLogix profiles configured
- [ ] Cloud Cache enabled (if applicable)
- [ ] Profile size baseline established
- [ ] Backup strategy implemented

## Azure Deployment Checklist

*If deploying AVD on Azure:*

- [ ] Bicep templates validated (syntax, parameters)
- [ ] Key Vault configured for secrets
- [ ] Azure Image Builder template prepared
- [ ] Session host images built and tested
- [ ] Host pool created in workspace
- [ ] Session hosts deployed and verified
- [ ] Azure Files Entra ID Kerberos enabled
- [ ] FSLogix profiles attached and tested

## Azure Local Deployment Checklist

*If deploying AVD on Azure Local:*

- [ ] Cluster validated and Arc-connected
- [ ] Local Identity initialized (or AD domain configured)
- [ ] Network ATC intent designed and applied
- [ ] Cluster CSV prepared for FSLogix
- [ ] Session host image created (via Image Builder or local tooling)
- [ ] VMs deployed on cluster
- [ ] FSLogix profile paths verified
- [ ] Arc agents reporting to Azure

## Hybrid Deployment Checklist

*If deploying AVD on Windows Server / vSphere / Nutanix:*

- [ ] On-premises infrastructure assessed (hypervisor, network, storage)
- [ ] Session host VMs created
- [ ] Session hosts domain-joined to on-premises AD
- [ ] Entra ID Connect running and syncing users
- [ ] AVD agent installed on session hosts
- [ ] Arc agents installed and connected to Azure
- [ ] On-premises storage configured for FSLogix
- [ ] Network connectivity to Azure verified (ExpressRoute recommended)
- [ ] Firewall rules allow Entra ID endpoints

## AVD Workspace & Host Pool Setup

- [ ] AVD workspace created in Azure
- [ ] Host pool created (Pooled, Personal, or Validation)
- [ ] Host pool settings configured:
  - [ ] Max session limit
  - [ ] Load balancing algorithm
  - [ ] Start VM on disconnect
  - [ ] User assignment policy
- [ ] Application groups created (Desktop, Remote App)
- [ ] Users assigned to host pool
- [ ] Validation host pool tested first

## Monitoring & Logging Configuration

- [ ] Azure Monitor agent installed on session hosts
- [ ] Data Collection Rule configured
- [ ] Log Analytics workspace created
- [ ] AVD-specific queries setup
- [ ] Alerts configured for:
  - [ ] High CPU/memory utilization
  - [ ] Storage connectivity issues
  - [ ] Session host failures
- [ ] Insights dashboard configured

## Security Hardening

- [ ] Session host image hardened (Windows Defender, Windows Firewall)
- [ ] RDP access restricted (NLA enabled)
- [ ] UAC configured appropriately
- [ ] Antivirus/EDR deployed
- [ ] Network Security Groups configured
- [ ] Private endpoints used (if applicable)
- [ ] Encryption enabled (storage, transport)

## User Testing

- [ ] Test user account created
- [ ] User can sign in to AVD workspace
- [ ] Session launches and connects successfully
- [ ] Profile loads correctly
- [ ] Network drives/printers mapped
- [ ] Applications launch
- [ ] Performance acceptable (login time < 30 sec)
- [ ] Multiple concurrent users tested

## Failover & Disaster Recovery

- [ ] Backup strategy documented
- [ ] Storage backup tested
- [ ] Session host image backup validated
- [ ] Failover procedures documented
- [ ] ASR (Site Recovery) configured (if applicable)
- [ ] RTO/RPO targets established
- [ ] Failover drill completed

## Go-Live Preparation

- [ ] Runbook documented
- [ ] Support team trained
- [ ] Communication sent to users
- [ ] Phased rollout planned
- [ ] Rollback plan prepared
- [ ] Monitoring dashboards ready
- [ ] Support contact information distributed

## Post-Deployment Validation (Day 1)

- [ ] All users connected successfully
- [ ] No critical errors in logs
- [ ] Performance metrics within baseline
- [ ] Storage performing normally
- [ ] Monitor load (concurrent connections, CPU, memory)
- [ ] Respond to user issues

## Day-2 Operations

- [ ] Monitoring alerts validated
- [ ] Performance baselines established
- [ ] Capacity planning begun
- [ ] Patching schedule defined
- [ ] Backup restoration tested
- [ ] Access review completed

---

## Deployment Validation Script

Use this PowerShell snippet to validate post-deployment:

```powershell
# Validate session host connectivity
$sessionHosts = Get-AzVMHostGroup -ResourceGroupName <rg> | ForEach-Object { $_.Name }
foreach ($host in $sessionHosts) {
    if (Test-Connection -ComputerName $host -Count 1 -Quiet) {
        Write-Host "✓ $host - Reachable"
    } else {
        Write-Host "✗ $host - Not reachable"
    }
}

# Validate FSLogix profile storage
$profilePath = "\\<storage>\fslogix"
if (Test-Path -Path $profilePath) {
    Write-Host "✓ FSLogix storage accessible"
    Get-ChildItem -Path $profilePath | Measure-Object | Select-Object Count
} else {
    Write-Host "✗ FSLogix storage not accessible"
}

# Validate Entra ID connectivity
Connect-MgGraph -Scopes "User.Read.All" -NoWelcome
if ($?) {
    Write-Host "✓ Entra ID connectivity verified"
} else {
    Write-Host "✗ Entra ID connectivity failed"
}
```

---

## Common Issues & Quick Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| Users can't sign in | Entra ID / network issue | Verify Entra ID, check firewall, test DNS |
| FSLogix profile not loading | Storage unreachable or permissions | Verify path, check NTFS permissions, test connectivity |
| Session host not healthy | Image issue or resource constraint | Check event logs, verify CPU/memory/disk, reimage if needed |
| Slow login time | Storage latency or large profile | Enable Cloud Cache, optimize profile, check network |
| Users lose settings | Profile sync issue | Verify FSLogix is enabled, check storage space |

