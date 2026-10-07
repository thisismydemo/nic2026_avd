# avd-session-hosts-azure-local

Creates 1-2 Windows 11 multi-session **Azure Local VMs** from an image that is already on the cluster. Each host is an HCI Arc machine (system-assigned identity), a logical-network NIC and a `default` virtual-machine instance, plus the optional Entra login extension, Azure Monitor Agent and a machine-scoped DCR association. The IaC does **not** configure the host pool or install the AVD agent.

Authored by gpt-6-sol via the HCS Foundry gateway; external review is recorded in `design/shared/verification-log.md`.

## Order

1. Deploy `lz-azure-local`; configure the cluster and its image (`cluster-configure`, `avd-images-azure-local`).
2. Deploy `lz-avd` and `avd-control-plane`; the host pool must be the Azure Local one (a host pool holds hosts from Azure **or** Azure Local, never both).
3. Supply the generated names and the dependency outputs. Bicep takes an ARM JSON parameters file (`az bicep build-params bicep/main.example.bicepparam`); Terraform takes a tfvars JSON file and the private backend.
4. Run `scripts/Invoke-SessionHostsAzureLocalDeploy.ps1` without `-Execute` (What-If / plan), then with `-Execute`. It needs `NIC26.Automation` imported and two `keyvault://` administrator references, and supplies the credentials in memory.
5. Run `scripts/Register-AvdSessionHostsAzureLocal.ps1` without `-Execute` to preview, then with `-Execute`, passing the control-plane `New-AvdRegistrationToken.ps1` as `-TokenScriptPath`.

## K-7: why registration is a script

The registration token never enters Bicep, Terraform, parameter files, state, outputs or logs. The script obtains a fresh token per machine and sends it only as an Arc Run Command **protected parameter**, reads only the execution state and exit code (the flattened `InstanceViewExecutionState` / `InstanceViewExitCode`), and removes the Run Command (also on failure). Exit codes 0 and 3010 count as success; the script never restarts the guest, so restart it when convenient after 3010. Terraform **does** keep the local administrator password in state: keep state in the private encrypted backend with restricted access.

## Known residuals

- The Microsoft-documented install puts `REGISTRATIONTOKEN=<token>` on the guest `msiexec` command line; process-creation auditing with command lines (event 4688) or Sysmon would record it. The token is short-lived (`-ExpirationHours`, default 2).
- The Run Command name is fixed per machine; do not run two registrations against one machine at once.
- Windows 11 multi-session is not eligible for Azure automatic guest patching; patch through the image.
- Trusted launch is **not** used: Azure Site Recovery does not support trusted-launch Azure Local VMs.

## First-day verification

- **Entra join.** `AADLoginForWindows` as an Arc extension is documented for Windows Server 2025 and Windows 11 24H2+ on Arc machines, while another Learn page says the portal can only AD-join Azure Local session hosts and that native Entra join is supported "via PowerShell and other deployment methods". Treat this as a flagged compatibility test, not an established combination. Fallback: a provisioning package applied in the guest, as in `session-hosts-hybrid`. Set `entra_join_extension = false` to skip the extension.
- The image id exists **on this cluster**; the custom-location and logical-network ids are the real ones.
- DNS on the logical network points at the Private Resolver inbound IP.
- The host-pool identity has Reader on this resource group.
- Extension health, host registration and `Available` before assigning users.
- If a host does not reach `Available` after an installer that needed a reboot (MSI exit 3010 is accepted as success), restart the guest and re-check; the script waits only for the configured time.
