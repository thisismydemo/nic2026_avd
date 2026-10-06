# Realm comparison: AVD on Azure, Azure Local and AVD Hybrid

Thirteen rows, three deployment models. The session slide shows five of these rows (locality, lifecycle owner, identity and OS, operations, support and licensing); this handout has all thirteen.

**Status:** prepared 2026-10-06 from Microsoft Learn and the session lab. Cells marked **verify** depend on the exact build, release or tenant and are tested before the session. Re-check the linked product documentation before you design from this table.

| # | Axis | AVD on Azure | AVD on Azure Local | AVD Hybrid |
|---|---|---|---|---|
| 1 | Where compute runs | Azure | Your Azure Local cluster | Your hypervisor (Hyper-V, VMware vSphere, Nutanix AHV) |
| 2 | Lifecycle owner | Azure | Azure for the platform through Arc; you for the guest | You, with your hypervisor tools |
| 3 | Session host OS | Windows 11 Enterprise (single or multi-session); Windows Server | Windows 11 multi-session is supported; check the supported-configuration list at build time | Windows 11 or 10 Enterprise single-session; Windows Server |
| 4 | Multi-session | Yes (Windows 11 multi-session) | Yes; **verify** on your build | No |
| 5 | Join and single sign-on | Entra join with SSO; AD DS and hybrid join also supported | Entra join of Azure Local VMs: **verify** (the portal offers AD DS join; Entra join through PowerShell is documented) | Windows 11 can be Entra-only; Windows Server needs Active Directory |
| 6 | Profile storage and authentication | Azure Files: Entra Kerberos (hybrid identities GA, cloud-only identities preview), AD DS or Entra Domain Services | FSLogix needs an SMB service, not a cluster shared volume: a file server VM or Scale-Out File Server on the cluster, or Azure Files | Any SMB path: Azure Files with Entra Kerberos, or on-premises SMB with AD DS Kerberos |
| 7 | Image tooling | Azure Image Builder to Azure Compute Gallery | Gallery or VHD, imported as an Azure Local image (there is no direct Image Builder target) | Packer with the platform builder (hyperv-iso, vsphere-iso, Nutanix plugin) |
| 8 | Patching | Image replacement; Intune or Windows Update for Business for Windows 11. Azure Update Manager covers Windows Server, not Windows 10 or 11 | Same for guests; Azure Local Lifecycle Manager for the cluster | Same for guests; hypervisor patching is yours |
| 9 | Scaling and power | Scaling plan and Start VM on Connect | **Verify** | None from AVD: you scale and power-manage the VMs |
| 10 | Monitoring | AVD Insights and Azure Monitor | Same workspace, through Arc | Same workspace, through the Arc agent in the guest |
| 11 | Failed host recovery | Redeploy from the image | The cluster and the operator | The hypervisor, not AVD |
| 12 | GPU | Azure GPU VM sizes | Discrete Device Assignment or GPU partitioning; one assignment mode per node; **verify** on your exact build | Per hypervisor; AVD neither adds nor blocks GPU support |
| 13 | Support and licensing | Azure compute plus the user licence | Cluster, the AVD on Azure Local service fee and the user licence | Your infrastructure plus the user licence; the AVD Hybrid service licence: **verify** |

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

Microsoft Learn: Azure Virtual Desktop on Azure Local; Deploy Azure Virtual Desktop Hybrid; Enable Microsoft Entra Kerberos authentication for hybrid and cloud-only identities on Azure Files; Azure Update Manager FAQ; Azure Virtual Desktop supported configurations.
