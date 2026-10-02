# Q&A Resources - AVD Anywhere

## General AVD Questions

**Q: What's the difference between Azure Virtual Desktop and Remote Desktop Services?**

A: Azure Virtual Desktop (AVD) is the cloud-based replacement for RDS. It's managed by Microsoft, automatically updated, and integrates natively with Entra ID and Azure services. RDS requires you to manage the infrastructure yourself.

**Q: Can I use AVD without Azure?**

A: Only with AVD Hybrid on-premises. But Hybrid still requires Azure for the control plane (AVD service). You can't run AVD entirely on-premises.

**Q: What's the difference between Pooled and Personal host pools?**

A: **Pooled** = Multiple users per VM (cost-efficient, stateless). **Personal** = One user per VM (desktop persistence, more stateful).

---

## Deployment Model Comparison

**Q: Should I use Azure, Azure Local, or Hybrid?**

A: 
- **Azure** = Scalability, elasticity, global reach needed
- **Azure Local** = Data sovereignty, latency-sensitive workloads, on-premises data
- **Hybrid** = Existing on-premises infrastructure, no budget for new hardware

**Q: Can I mix all three in one workspace?**

A: Yes! One workspace, multiple host pools in different deployment models. Users see one sign-in; AVD routes to appropriate pool.

**Q: How do I move users between deployment models?**

A: If FSLogix is configured identically, users maintain profile continuity. Different storage paths, same profile structure.

---

## Identity & Authentication

**Q: Do I need on-premises Active Directory?**

A:
- **Azure**: No (Entra ID-only is recommended)
- **Azure Local**: No (use Local Identity), but AD is supported
- **Hybrid**: Yes, recommended (can use cloud-only with Arc)

**Q: What's the difference between Entra ID-only and Hybrid identity?**

A:
- **Entra ID-only** = Users in cloud only, simpler
- **Hybrid** = Users synced from on-premises AD to Entra ID via Azure AD Connect, supports conditional on-premises + cloud access

**Q: Can users with Entra ID-only accounts access on-premises resources?**

A: Only if those resources are cloud-enabled or support modern auth (Kerberos delegation). Entra ID-only breaks traditional Kerberos delegation.

---

## FSLogix & Storage

**Q: What's the maximum profile size?**

A: No hard limit, but typical is 5-30 GB. Larger profiles = slower login. Consider archiving or excluding certain folders.

**Q: Do I need high-performance storage?**

A: Depends on scale:
- **Small** (< 100 users): Standard NAS or SMB is fine
- **Medium** (100-500 users): Premium tier or NAS with good throughput
- **Large** (> 500 users): Azure Files Premium, high-IOPS NAS, or local cluster CSV

**Q: What's Cloud Cache, and do I need it?**

A: Cloud Cache caches FSLogix containers locally on the session host for faster access. Recommended for remote deployments or slow storage.

**Q: Can I replicate profiles between Azure and on-premises?**

A: Not automatically. You'd need a sync service (e.g., Azure File Sync, custom replication). For true mobility, store profiles centrally (Azure Files or NAS both can access).

---

## Image Management

**Q: What's the difference between Image Builder and Packer?**

A:
- **Image Builder** = Azure-native, simpler, but only for Azure/Azure Local
- **Packer** = Generic tool, works anywhere (Hyper-V, vSphere, Nutanix)

**Q: How often should I update images?**

A: Monthly (with Windows Update) at minimum. Weekly if rapid patching is needed. Test updates in validation host pool first.

**Q: Can I use the same image for Azure, Azure Local, and Hybrid?**

A: No. Images are platform-specific (Hyper-V VHD, vSphere VMDK, Nutanix QCOW2). Use Image Builder for Azure/Azure Local, Packer for Hybrid.

---

## Networking

**Q: Do I need ExpressRoute for Hybrid deployments?**

A: Not required, but recommended. ExpressRoute provides:
- Better security (private connection)
- More consistent latency
- Higher reliability
- Better for hybrid identity and monitoring

Public internet works, but performance/security is lower.

**Q: What network bandwidth do I need?**

A: Depends on workload:
- **Office apps** = 1-2 Mbps per user
- **Video streaming** = 10-25 Mbps per user
- **GPU workloads** = 50+ Mbps

Multiply by concurrent user count + overhead.

---

## Performance & Scaling

**Q: Why are my users experiencing slow logins?**

A: Common causes (in order of likelihood):
1. Large FSLogix profile (check profile size)
2. Storage latency (check network, Cloud Cache)
3. Image too large or fragmented (rebuild image)
4. Session host resource contention (CPU/RAM/disk)
5. Network bandwidth insufficient

**Q: How many users per session host?**

A: Rule of thumb:
- **Light workload** = 4-6 users per 4-vCPU VM
- **Medium workload** = 2-4 users
- **Heavy workload** = 1-2 users

Test with your workload; results vary.

**Q: Should I use auto-scaling?**

A: Yes, if load varies (office hours vs. nights). Azure Autoscale pools VMs up/down based on demand. For consistent load, static sizing is fine.

---

## Security

**Q: Is AVD secure?**

A: Yes. Entra ID, conditional access, and network isolation provide strong security. But like any RDP/remote access, follow best practices:
- Multi-factor authentication (required)
- Conditional access policies
- Network segmentation
- Endpoint protection
- Regular patching

**Q: Can users access local devices (printer, USB, etc.)?**

A: Yes, via device redirection. Can be restricted by policy. Be careful with USB (security risk in multi-user environments).

**Q: How do I prevent data exfiltration?**

A: Use Conditional Access policies, DLP (Data Loss Prevention) in Microsoft 365, and monitor file access. Restrict copy/paste, file download.

---

## Monitoring & Support

**Q: How do I monitor AVD performance?**

A: Use Azure Monitor + Log Analytics. Collect:
- Session host CPU/memory/disk
- Connection latency
- Session login time
- User activity
- Errors/disconnects

**Q: What should I alert on?**

A:
- Host health (unhealthy, no heartbeat)
- Performance (CPU > 80%, memory > 90%)
- Connections (too many failures)
- Storage (latency spikes, disk full)
- Users (unusual access patterns)

**Q: How do I troubleshoot session host issues?**

A:
1. Check Event Viewer (System, Application, FSLogix logs)
2. Check Azure Monitor
3. Review RDP logs (Event ID 1101+)
4. Test connectivity to dependencies (storage, Entra ID, monitoring)
5. Check resource utilization (Task Manager, Performance Monitor)

---

## Costs

**Q: How much does AVD cost?**

A: Two components:
1. **Azure compute** = Session host VMs ($$ per hour)
2. **AVD licenses** = Per-user access rights (included in Microsoft 365 or $10/month standalone)

**Q: How can I optimize costs?**

A:
- Use Spot VMs (cheaper, preemptable)
- Right-size VMs (don't over-provision)
- Auto-scale (don't run empty VMs)
- Reserved Instances (if predictable load)
- Use pooled (not personal) host pools

**Q: What about storage costs?**

A: FSLogix profiles consume storage. Plan for:
- Profile storage (e.g., Azure Files @ $0.08/GB/month LRS)
- Backup storage
- Tiering (archive old profiles)

---

## Troubleshooting Guide - Quick Reference

| Symptom | Likely Cause | Quick Fix |
|---------|-------------|-----------|
| Can't sign in | Entra ID issue | Verify sign-in to Entra ID portal |
| Slow login | FSLogix storage latency | Enable Cloud Cache; check network |
| No network drive | Group Policy not applied | Reapply GPO or restart session host |
| Application won't launch | Missing app or permissions | Check app installation, user permissions |
| Choppy video/audio | Network bandwidth low | Check network, reduce video quality, close other apps |
| Can't access shared printer | Printer redirection disabled | Enable in host pool config |

---

## Resources & Links

**Microsoft Documentation:**
- AVD Learning Path: aka.ms/AVDLearn
- FSLogix: aka.ms/FSLogix
- Azure Local: aka.ms/AzureLocal
- Network ATC: aka.ms/NetworkATC

**Community:**
- AVD Tech Community: https://aka.ms/AVDTechCommunity
- Microsoft Q&A: https://learn.microsoft.com/answers/tags/345/azure-virtual-desktop

**Tools:**
- AVD Insights: Built into Azure Portal
- LAD (Lightweight Azure Diagnostics): GitHub
- FSLogix Troubleshooting: aka.ms/FSLogixTroubleshooting

---

## Still Have Questions?

- Check the **Identity_Reference_Architecture.md** for deep-dives on identity models
- Review **FSLogix_Configuration_Guide.md** for storage setup
- Use **Deployment_Checklist.md** to validate your setup
- Check Microsoft Learn for official documentation

