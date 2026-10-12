# avd-session-hosts-azure-local

Creates 1-3 Windows 11 multi-session **Azure Local VMs** from an image that is already on the cluster. Each host is an HCI Arc machine (system-assigned identity), a NIC attached to an Azure Local **logical network** and a `default` virtual-machine instance on an explicit **storage path** (`vmConfigStoragePathId`), joined to Active Directory with `JsonADDomainExtension` (`join_type = AD`, the default; `Entra` installs `AADLoginForWindows` instead), plus Azure Monitor Agent and a machine-scoped DCR association. VM-management resources use API `2026-04-01-preview`. Optional GPU DDA devices per host (`gpu_dda_counts`). The logical network is backed by the cluster's physical adapters, switches, VLANs and Network ATC intents; it is not an Azure VNet or Azure subnet. The IaC does **not** configure the host pool or install the AVD agent.

This placement follows [AzureLocal/azurelocal-avd](https://github.com/AzureLocal/azurelocal-avd): the AVD workspace, host pool and application groups are Azure control-plane resources, while session hosts remain on Azure Local. For profile storage, use the companion [AzureLocal/azurelocal-sofs-fslogix](https://github.com/AzureLocal/azurelocal-sofs-fslogix) architecture as guidance for SOFS guest VMs and local SMB/FSLogix traffic; that repository is under active development and must be release-validated before use.

Authored by gpt-6-sol via the HCS Foundry gateway; external review is recorded in `design/shared/verification-log.md`.

## Order

1. Deploy `lz-azure-local`; configure the cluster and its image (`cluster-configure`, `avd-images-azure-local`).
2. Deploy `lz-avd` and `avd-control-plane`; the host pool must be the Azure Local one (a host pool holds hosts from Azure **or** Azure Local, never both).
3. Supply the generated names and the dependency outputs. Bicep takes an ARM JSON parameters file (`az bicep build-params bicep/main.example.bicepparam`); Terraform takes a tfvars JSON file and the private backend.
4. Run `scripts/Invoke-SessionHostsAzureLocalDeploy.ps1` without `-Execute` (What-If / plan), then with `-Execute`. It needs `NIC26.Automation` imported and two `keyvault://` administrator references, and supplies the credentials in memory.
5. Run `scripts/Register-AvdSessionHostsAzureLocal.ps1` without `-Execute` to preview, then with `-Execute`, passing the control-plane `New-AvdRegistrationToken.ps1` as `-TokenScriptPath`.

### One command from the environment file

`scripts/Invoke-AzlSessionHostBuild.ps1 -EnvironmentFile <environment/avd/environment.yml>` reads the `azl_session_hosts` section (logical network, image, storage path per host, AD domain and OU, join-account `keyvault://` references, DCR, host pool), resolves every ID live, checks the image and logical network are `Succeeded`, runs the Bicep What-If (or the deployment with `-Execute`), merges and reads back the tags, then registers each host that is not yet in the host pool. Sign in with `Set-AzContext -Tenant <tenant> -Subscription <subscription>` first: the scripts keep the operator's tenant when they switch subscription (a multi-tenant account lists the same subscription under several tenants). The registration script takes `-HostPoolSubscriptionId` and `-SessionHostName` because the host pool lives in the AVD subscription and lists hosts by computer FQDN.

## K-7: why registration is a script

The registration token never enters Bicep, Terraform, parameter files, state, outputs or logs. The script obtains a fresh token per machine and sends it only as an Arc Run Command **protected parameter**, reads only the execution state and exit code (the flattened `InstanceViewExecutionState` / `InstanceViewExitCode`), and removes the Run Command (also on failure). Exit codes 0 and 3010 count as success; the script never restarts the guest, so restart it when convenient after 3010. Terraform **does** keep the local administrator password in state: keep state in the private encrypted backend with restricted access.

## Known residuals

- The Microsoft-documented install puts `REGISTRATIONTOKEN=<token>` on the guest `msiexec` command line; process-creation auditing with command lines (event 4688) or Sysmon would record it. The token is short-lived (`-ExpirationHours`, default 2).
- The Run Command name is fixed per machine; do not run two registrations against one machine at once.
- Windows 11 multi-session is not eligible for Azure automatic guest patching; patch through the image.
- Trusted launch is **not** used: Azure Site Recovery does not support trusted-launch Azure Local VMs.

## First-day verification

- **Join.** The default is AD DS join into the delegated session-host OU (D-050: hybrid users, the SOFS profile share needs AD Kerberos). `JsonADDomainExtension` is the extension the portal's domain-join option uses; the join password is only a `@secure()` parameter / protected setting. AD-only joined hosts do not get Entra SSO or Entra Kerberos tickets (Learn: Azure Files Entra Kerberos needs Entra-joined or hybrid-joined clients); hybrid join is a separate step through Entra Connect device sync.
- The image id exists **on this cluster**; the custom-location and logical-network ids are the real ones.
- DNS on the logical network points at the domain controllers (required for the AD join).
- The host-pool identity has Reader on this resource group.
- Extension health, host registration and `Available` before assigning users.
- If a host does not reach `Available` after an installer that needed a reboot (MSI exit 3010 is accepted as success), restart the guest and re-check; the script waits only for the configured time.
