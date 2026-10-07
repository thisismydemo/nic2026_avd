# Azure Virtual Desktop: Deployment Checklist

Use this checklist to plan, deploy, validate and operate an Azure Virtual Desktop environment across Azure, Azure Local and Azure Virtual Desktop Hybrid.

**Status:** prepared 2026-10-06 against Microsoft Learn; use it with the Identity and FSLogix handouts and re-check the Learn pages for your release.

## Before you start

- [ ] An Azure subscription and a Microsoft Entra tenant exist.
- [ ] The Microsoft.DesktopVirtualization resource provider is registered in the subscription.
- [ ] Every user has an eligible licence (below).
- [ ] The person who manages host pools has the Desktop Virtualization Contributor role.
- [ ] The deployment model is decided per host pool.

Eligible licences:

- **Windows client session hosts:** Microsoft 365 E3, E5, A3, A5, F3, Business Premium or Student Use Benefit; Windows Enterprise E3 or E5; Windows Education A3 or A5; or Windows VDA per user.
- **Windows Server session hosts:** an RDS CAL with Software Assurance, or RDS User Subscription Licenses.
- **External users:** per-user access pricing, by enrolling an Azure subscription. It is not available for Windows Server session hosts.

A host pool is either all Azure or all Azure Local. Azure Virtual Desktop Hybrid session hosts have their own host pool.

## Identity

The Identity handout has the detail.

- [ ] Users and groups exist.
- [ ] The join type is decided per deployment model.
- [ ] Single sign-on is configured.
- [ ] Conditional Access covers the Azure Virtual Desktop and Windows Cloud Login applications.
- [ ] The Virtual Machine User Login role is assigned on Microsoft Entra-joined hosts.
- [ ] Per-user MFA is off.

## Network

- [ ] A virtual network and subnet exist in the same Azure region as the session hosts (Azure deployments).
- [ ] Session hosts can reach the required URLs outbound over TCP 443: `login.microsoftonline.com`, `*.wvd.microsoft.com`, the monitoring and agent endpoints, and, for Windows activation, `azkms.core.windows.net` on port 1688.
- [ ] The Azure platform addresses `169.254.169.254` and `168.63.129.16` are not intercepted or proxied.
- [ ] Domain controllers and DNS are reachable if hosts join AD DS or Microsoft Entra Domain Services.
- [ ] Round-trip latency from the client network to the Azure region of the host pool is below 150 ms.
- [ ] Microsoft 365 endpoints are allowed if users run Microsoft 365 apps.

No inbound ports are needed for users or hosts to connect to the service. RDP Shortpath (UDP) is optional: for managed networks, enable the listener (default port 3390) and allow that inbound port on the session hosts; for public networks, STUN and TURN work without extra configuration when firewalls allow them.

## Host pool, workspace and application group

- [ ] The host pool is created (pooled or personal, with a load balancing option; a validation environment is optional).
- [ ] The desktop application group is created and registered to a workspace.
- [ ] Users or groups are assigned to the application group.
- [ ] A registration key is generated only for as long as needed.

Notes:

- A workspace can expose desktops from several host pools, including host pools of different deployment models.
- A registration key authorises session hosts to join a host pool. Its expiry is between one hour and 27 days.
- Event 3277 with `INVALID_REGISTRATION_TOKEN` or `EXPIRED_MACHINE_TOKEN` means the key is not valid. Create a new key, set `IsRegistered` to `0` and the new `RegistrationToken` under `HKLM:\SOFTWARE\Microsoft\RDInfraAgent`, then restart the `RDAgentBootLoader` service.
- The session host configuration feature is not supported on Azure Local or Hybrid.

## Session hosts on Azure

- [ ] Hosts deploy from a pinned image (Azure Marketplace or an Azure Compute Gallery image).
- [ ] The OS disk is Premium SSD for production.
- [ ] The Windows licence is applied: automatically when you deploy through Azure Virtual Desktop, otherwise set the `Windows_Client` (or server) licence type yourself.
- [ ] Windows Server hosts can reach an RDS licence server.

Trusted launch is the default security type in the portal flow.

## Session hosts on Azure Local

- [ ] The instance runs Azure Local 23H2 or later and is registered with Azure.
- [ ] The image is supported: Windows 11 Enterprise (multi-session or single-session), Windows 10 Enterprise (both), or Windows Server 2025, 2022 or 2019.
- [ ] The Azure Connected Machine (Arc) agent is on the VMs; the portal flow installs it.
- [ ] The VMs are licensed and activated: Azure verification for VMs covers Windows 10 and 11 Enterprise multi-session and Windows Server 2022 Datacenter: Azure Edition; other editions use your existing activation method.
- [ ] The join method is chosen: the portal adds hosts only to an AD DS domain (including hybrid join); Microsoft Entra join is done with PowerShell or other deployment methods.
- [ ] Sizing is checked against your hardware, then monitored: performance and density vary by hardware.

The Azure Virtual Desktop service in Azure is required for brokering, and each host pool holds only Azure Local hosts. Azure Virtual Desktop Insights and Azure policy reach these hosts through Arc.

## Session hosts on Azure Virtual Desktop Hybrid

- [ ] Each machine is Arc-enabled with the Azure Connected Machine agent, and the Arc endpoints are allowed.
- [ ] A host pool registration key is generated.
- [ ] The Azure Virtual Desktop Arc extension (`CloudDeviceExtension`, publisher `Microsoft.AzureVirtualDesktop`) is installed with the registration token.
- [ ] You can deploy and power-manage the VMs with your hypervisor tools.

Facts to plan around:

- Supported operating systems: Windows 11 or 10 Enterprise single-session, and Windows Server 2025, 2022, 2019 or 2016. Multi-session editions are not supported.
- Windows client hosts can be Microsoft Entra joined, AD DS joined or hybrid joined; Windows Server hosts must be AD DS joined or hybrid joined.
- Licensing is the user entitlement (as for Azure; for Windows Server an RDS CAL with Software Assurance or RDS User Subscription Licenses) plus the Azure Virtual Desktop Hybrid service user license.
- Hybrid does not provide power management, autoscale, Start VM on Connect or session host configuration.

## Profiles with FSLogix

- [ ] The share and identity source are planned using the FSLogix handout.
- [ ] The standard registry values are deployed.
- [ ] Antivirus exclusions are configured.
- [ ] ACLs are applied.
- [ ] Sign-in is tested on each deployment model.

## Monitoring and scaling

- [ ] Host pool diagnostics go to a Log Analytics workspace, and Azure Virtual Desktop Insights is enabled.
- [ ] A scaling approach is chosen for each host pool (below).

Scaling facts:

- Autoscale scaling plans work for pooled and personal host pools on Azure. Power management autoscale is generally available; dynamic autoscale is in preview and needs a session host configuration.
- Autoscale needs the Desktop Virtualization Power On Off Contributor role for the Azure Virtual Desktop service principal, at host pool, resource group or subscription scope.
- Do not use autoscale and the Azure Automation scaling tool on the same host pool.
- Session host configuration is not supported on Azure Local, so dynamic autoscale is not available there, and the Learn autoscale articles do not list Azure Local for power management; confirm before you rely on it.
- Start VM on Connect is an Azure option.

## Security

- [ ] Conditional Access with MFA is applied through the two applications.
- [ ] Trusted launch and Secure Boot are on for Azure hosts.
- [ ] RBAC follows least privilege.
- [ ] Windows, FSLogix and the Arc agent are kept patched.
- [ ] Azure Local machines meet the TPM 2.0 and Secure Boot requirements.

## Test before go-live

- [ ] Sign in from Windows App once and confirm a single prompt.
- [ ] Both Microsoft Entra sign-in log entries (Azure Virtual Desktop and Windows Cloud Login) show Success.
- [ ] A cifs Kerberos ticket exists in the session.
- [ ] The profile container is created on the share and detaches at sign-out.
- [ ] The registration key is replaced or expired after use.
- [ ] A failure drill passes: stop one host and confirm a new session lands on another host.

## Day 1 and Day 2

Day 1:

- [ ] Users reach desktops from each deployment model.
- [ ] Profile portability is validated.
- [ ] Monitoring data is arriving.

Day 2:

- [ ] The image replacement process is reviewed.
- [ ] Patching is reviewed.
- [ ] Autoscale and capacity are reviewed.
- [ ] Registration keys are rotated.
- [ ] Conditional Access sign-in logs are reviewed.

## Quick fixes

| Symptom | Fix |
|---|---|
| "Your account is configured to prevent you from using this device" | Assign the Virtual Machine User Login role. |
| Error 1327 on the file share | Exclude the storage account application from MFA. |
| Repeated sign-in prompts | Align the two Conditional Access applications and disable per-user MFA. |
| Host not available after resume from hibernate | Known limitation: prefer deallocate. |
| `INVALID_REGISTRATION_TOKEN` | Create a new registration key and re-register the host. |
| Windows App cannot sign in | A Conditional Access policy blocks the Windows 365 application. |
