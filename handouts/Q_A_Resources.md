# Azure Virtual Desktop: Questions and Resources

This handout answers the questions attendees ask most often and lists where to read more.

**Status:** prepared 2026-10-06 against Microsoft Learn; prices and support change, so follow the pricing and documentation links.

## Choosing a deployment model

**Which components always live in Azure?** The Azure Virtual Desktop service components: host pools, workspaces and application groups.

**Where can session hosts run?** On Azure, on Azure Local (your cluster), or on your own hypervisor with Azure Virtual Desktop Hybrid.

**Can one workspace include more than one deployment model?** Yes. One workspace can show desktops from host pools of several models. A host pool is either all Azure or all Azure Local.

**How should I choose?**

- Azure for elasticity and the least infrastructure.
- Azure Local when data or latency keeps compute on site and you have Azure Local.
- Hybrid to reuse an existing hypervisor without new hardware.

**What should I confirm for the host operating system?**

- Azure Local needs version 23H2 or later registered with Azure, and supports Windows 11 Enterprise (multi-session and single-session), Windows 10 Enterprise, and Windows Server 2025, 2022 and 2019.
- Hybrid supports Windows 11 or 10 Enterprise single-session and Windows Server, but not multi-session. It has no power management, autoscale, Start VM on Connect or session host configuration.
- The Realm Comparison handout covers all thirteen axes.

## Identity and sign-in

**Can users be cloud-only or hybrid?** Yes. Hybrid users are synced with Microsoft Entra Connect Sync or Microsoft Entra Cloud Sync.

**Do session hosts need AD DS?** Not Microsoft Entra-joined Windows client hosts. Windows Server hosts need AD DS or hybrid join.

**What enables single sign-on?** It uses the Azure Virtual Desktop and Windows Cloud Login applications; keep their Conditional Access policies aligned.

**Which role do users need on Microsoft Entra-joined hosts?** The Virtual Machine User Login role. Use Conditional Access for MFA, not per-user MFA.

The Identity Reference Architecture handout has the detail.

## Profiles

**How does FSLogix store profiles?** In VHDX containers on an SMB share, attached at sign-in.

**What is the cloud-first storage option?** Azure Files with Microsoft Entra Kerberos. Session hosts need no domain controller connectivity, and a storage account uses one identity source.

**What storage works with Azure Local hosts?** A file server VM, Scale-Out File Server on the cluster, or Azure Files. FSLogix needs an SMB service, not a cluster shared volume path.

**Roaming, redundancy and recovery?** Cloud Cache gives redundancy across storage providers. Roaming a profile is not replication, and replication is not recovery.

The FSLogix Configuration Guide has the settings.

## Images

**How do I build and publish images for Azure hosts?** Build with Azure Image Builder or your own pipeline, publish to an Azure Compute Gallery, and deploy hosts from an image version.

**How are Azure Local images supplied?** As an Azure Local VM image, for example from Azure Marketplace images, a gallery or a VHD import.

**How are Hybrid images built?** Typically with Packer and the platform builder for your hypervisor.

**Any practices to keep?** Share customisation scripts between realms and do not bake identity into an image. For pooled pools, this session's practice is to replace hosts from a new image version instead of patching in place; that is the session's practice, not a Microsoft requirement.

## Networking

**Do I open inbound ports?** No. Clients and hosts make outbound TCP 443 connections to the service, and the required URL list must be allowed.

**Which Azure platform addresses must not be intercepted?** `169.254.169.254` and `168.63.129.16`.

**What does RDP Shortpath do?** It adds a UDP transport for better reliability and latency, on managed networks and on public networks (STUN or TURN).

**What latency and region rules apply?** Client-to-region round-trip latency should be below 150 ms, and session hosts on Azure must be in a virtual network in the same region.

## Scaling and cost

**What costs apply to each model?**

- Azure: Azure compute and storage, plus the user licence.
- Azure Local: the Azure Local service fee, the Azure Virtual Desktop for Azure Local service fee (charged per active vCPU of session hosts), and the user licence.
- Hybrid: your infrastructure, the user licence, and the Azure Virtual Desktop Hybrid service user license.

For amounts, use the Azure Virtual Desktop and Azure Local pricing pages.

**Which user licences are eligible?**

- Windows client session hosts: Microsoft 365 E3, E5, A3, A5, F3, Business Premium or Student Use Benefit; Windows Enterprise E3 or E5; Windows Education A3 or A5; Windows VDA per user.
- Windows Server session hosts: an RDS CAL with Software Assurance, or RDS User Subscription Licenses.
- External commercial users: per-user access pricing (Windows client only).
- Azure Dev/Test pricing lets users connect to a deployment in a Dev/Test subscription for acceptance tests without separate licence entitlement.

**What autoscale options exist?** Scaling plans work for pooled and personal host pools on Azure. Power management autoscale is generally available; dynamic autoscale is in preview and needs a session host configuration. Session host configuration is not supported on Azure Local, and Hybrid has none of these features.

**What else keeps cost down?** Right-size VMs from measured usage and use multi-session. Do not use autoscale and the Azure Automation scaling tool on the same host pool.

## Security

**What is the default VM security type in the Azure host pool flow?** Trusted launch.

**How do I apply MFA and access control?** Use Conditional Access with MFA through the Azure Virtual Desktop and Windows Cloud Login applications, and least-privilege roles: Desktop Virtualization Contributor for host pool management and Desktop Virtualization User for application group users.

**What about Azure Local machines?** They require TPM 2.0 and Secure Boot. Keep agents and Windows updated.

## Monitoring and support

**Where do diagnostics go?** To a Log Analytics workspace, with Azure Virtual Desktop Insights on top.

**How do Azure Local and Hybrid hosts report?** Through the Azure Arc agent, into the same workspace.

**Which patching tool applies?** Azure Update Manager covers Windows Server, not Windows 10 or 11 guests; use Intune or Windows Update for Business for those.

**What do I collect before a support request?** The agent events from the session host (RDAgent), along with the host pool name and region.

## Quick troubleshooting

| Symptom | What to check |
|---|---|
| Host shows Unavailable after a registration problem | Event 3277, then generate a new registration key (valid from 1 hour to 27 days). |
| Sign-in works but the desktop will not open | The Virtual Machine User Login role, and the Windows Cloud Login application in Conditional Access. |
| Repeated sign-in prompts | Align the two Conditional Access policies and disable per-user MFA. |
| Profile will not attach | The share path, permissions, the Kerberos ticket, and whether the storage application is excluded from MFA. |
| Windows App sign-in error with Conditional Access | Whether a policy blocks the Windows 365 application. |
| Hosts not scaling | The role on the Azure Virtual Desktop service principal, and that the host pool is not using two scaling tools. |

## Resources

Microsoft Learn topics:

- Prerequisites for Azure Virtual Desktop
- Licensing Azure Virtual Desktop
- Azure Virtual Desktop on Azure Local
- Azure Virtual Desktop Hybrid overview
- Required FQDNs and endpoints for Azure Virtual Desktop
- Configure single sign-on for Azure Virtual Desktop using Microsoft Entra ID
- Enforce Microsoft Entra multifactor authentication for Azure Virtual Desktop using Conditional Access
- FSLogix: configure profile containers
- FSLogix: store profile containers on Azure Files using Microsoft Entra ID
- Autoscale scaling plans for Azure Virtual Desktop
- Azure Virtual Desktop Insights
- RDP Shortpath for Azure Virtual Desktop
- Azure Virtual Desktop pricing

In this repository:

- [Realm comparison](Realm_Comparison.md)
- [Identity reference architecture](Identity_Reference_Architecture.md)
- [FSLogix configuration guide](FSLogix_Configuration_Guide.md)
- [Deployment checklist](Deployment_Checklist.md)
