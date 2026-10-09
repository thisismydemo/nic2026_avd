# Realm comparison: AVD on Azure, Azure Local and AVD Hybrid

Thirteen rows, three deployment models. The session slide shows five of these rows (locality, lifecycle owner, identity and OS, operations, support and licensing); this handout has all thirteen.

**Status:** prepared 2026-10-06; cloud-only Azure Files guidance reviewed 2026-10-09 from Microsoft Learn (2609 release family for Azure Local) and the session lab; every cell was checked against the Learn pages listed under Sources. Support statements change by release, so re-check the linked documentation before you design from this table.

| # | Axis | AVD on Azure | AVD on Azure Local | AVD Hybrid |
|---|---|---|---|---|
| 1 | Where compute runs | Azure | Your Azure Local cluster | Your hypervisor (Hyper-V, VMware vSphere, Nutanix AHV) |
| 2 | Lifecycle owner | Azure | Azure for the platform through Arc; you for the guest | You, with your hypervisor tools |
| 3 | Session host OS | Windows 11 Enterprise (single or multi-session); Windows Server | Windows 11 Enterprise multi-session and single-session, Windows 10 Enterprise (both), Windows Server 2025, 2022 and 2019; Azure Local 23H2 or later, registered with Azure | Windows 11 or 10 Enterprise single-session; Windows Server |
| 4 | Multi-session | Yes (Windows 11 multi-session) | Yes (Windows 11 and Windows 10 Enterprise multi-session) | No |
| 5 | Join and single sign-on | Entra join with SSO; AD DS and hybrid join also supported | The AVD portal can only join session hosts to AD DS (including hybrid join); native Entra join is supported through PowerShell and other deployment methods | Windows 11 can be Entra-only; Windows Server needs Active Directory |
| 6 | Profile storage and authentication | Azure Files: Entra Kerberos (hybrid identities in all clouds; cloud-only identities generally available in the public cloud, with client, permissions and storage-application prerequisites; external identities only for FSLogix on AVD), AD DS or Entra Domain Services; a storage account uses one identity source | FSLogix needs an SMB service, not a cluster shared volume: a file server VM or Scale-Out File Server on the cluster, or Azure Files | Any SMB path: Azure Files with Entra Kerberos, or on-premises SMB with AD DS Kerberos |
| 7 | Image tooling | Azure Image Builder to Azure Compute Gallery | Gallery or VHD, imported as an Azure Local image (there is no direct Image Builder target) | Packer with the platform builder (hyperv-iso, vsphere-iso, Nutanix plugin) |
| 8 | Patching | Image replacement; Intune or Windows Update for Business for Windows 11. Azure Update Manager covers Windows Server, not Windows 10 or 11 | Same for guests; Azure Local Lifecycle Manager for the cluster | Same for guests; hypervisor patching is yours |
| 9 | Scaling and power | Scaling plan and Start VM on Connect | Dynamic autoscale needs a session host configuration, which is not supported on Azure Local, and the Learn autoscale articles do not list Azure Local for power management; plan to manage power yourself and confirm support before relying on a scaling plan | None from AVD: Hybrid does not support power management, autoscale, Start VM on Connect or session host configuration; you scale and power-manage the VMs |
| 10 | Monitoring | AVD Insights and Azure Monitor | Same workspace, through Arc | Same workspace, through the Arc agent in the guest |
| 11 | Failed host recovery | Redeploy from the image | The cluster and the operator | The hypervisor, not AVD |
| 12 | GPU | Azure GPU VM sizes | Discrete Device Assignment (a whole GPU to one VM, no live migration) or GPU partitioning (a fraction of a GPU, one partition per VM, live migration needs OS build 26100 or later and NVIDIA vGPU 18 or later); a physical GPU is either DDA or partitioned, and the GPU configuration must be homogeneous across machines | Per hypervisor; AVD neither adds nor blocks GPU support |
| 13 | Support and licensing | Azure compute plus the user licence | Cluster, the AVD on Azure Local service fee and the user licence | Your infrastructure, the user entitlement (an eligible Windows client licence, or RDS CALs with Software Assurance for Windows Server) and the AVD Hybrid service user license; Windows multi-session is not supported on Hybrid |

## How to read the table

- **One workspace, three desktops:** an AVD workspace can expose desktops from all three models to the same user. Group entitlement decides which desktops the user sees; it does not decide which host the user lands on.
- **One profile pattern:** the same FSLogix configuration and the same user identity give the same container in each model, for sequential use. Roaming a profile is not replication, and replication is not recovery.
- **Shared monitoring, separate operations:** one Log Analytics workspace sees all three. Patching, power and recovery differ, as rows 8, 9 and 11 show.

## Decision rules of thumb

| If you need | Start with |
|---|---|
| Elasticity and scale, minimal infrastructure to run | AVD on Azure |
| Data, latency or regulation that keeps compute at your site | AVD on Azure Local |
| To reuse the hypervisor you already own, with no new hardware | AVD Hybrid |

## Sources

Microsoft Learn: Azure Virtual Desktop on Azure Local (overview, supported configurations, limitations, licensing and pricing); Azure Virtual Desktop for Azure Local (architecture); Azure Virtual Desktop Hybrid overview and deployment; Licensing Azure Virtual Desktop; Prepare GPUs for Azure Local, Manage GPUs via Discrete Device Assignment, Manage GPUs using partitioning; Autoscale scaling plans, glossary and scenarios; Deploy Azure Virtual Desktop (session host configuration); Enable Microsoft Entra Kerberos authentication for hybrid and cloud-only identities on Azure Files; Azure Update Manager FAQ.


Cloud-only Azure Files guidance reviewed 9 October 2026: [Azure Files GA release notes](https://learn.microsoft.com/en-us/azure/storage/files/files-whats-new), [Entra Kerberos prerequisites](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable), and [supported directory ACL methods](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-configure-file-level-permissions).
