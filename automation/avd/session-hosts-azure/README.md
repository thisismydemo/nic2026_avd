# avd-session-hosts-azure

Creates 1-2 Entra-joined Windows 11 multi-session VMs from an existing Compute Gallery image, with private accelerated NICs, Trusted Launch, Azure Monitor Agent and AVD Insights DCR associations. The IaC does **not** configure the host pool or install the AVD agent.

Authored by gpt-6-sol via the HCS Foundry gateway; external review is recorded in `design/shared/verification-log.md`.

## Order

1. Deploy `lz-avd`, `avd-control-plane` and `avd-images-azure`.
2. Supply the generated names and the dependency outputs. For Terraform, initialise the private backend.
3. Run `scripts/Invoke-SessionHostsAzureDeploy.ps1` without `-Execute` (What-If / plan), then with `-Execute`. Bicep takes an ARM JSON parameters file (`az bicep build-params bicep/main.example.bicepparam`); the wrapper supplies the two secure admin parameters at run time.
4. Run `scripts/Register-AvdSessionHosts.ps1` without `-Execute` to preview, then with `-Execute`, passing the control-plane `New-AvdRegistrationToken.ps1` as `-TokenScriptPath`.

The deploy wrapper needs the `NIC26.Automation` module imported and `keyvault://` references for the administrator credentials.

## K-7: why registration is a script

The registration token must never enter IaC, parameter files, Terraform state or logs. The script passes it to each VM only as a **protected Run Command parameter**, reads only the execution state and exit code, and removes the Run Command (also on failure). Never enable MSI verbose logging (`/l*v`): the log would contain the token. Terraform **does** keep the local administrator password in state, so state stays in the private encrypted backend with restricted access.

`-RestartWhenAvailable` restarts a VM only after its host reports **Available**. Windows 11 multi-session needs no RD Session Host role.

## Verify at first deploy

- The `EncryptionAtHost` provider feature is registered on the subscription.
- `image_version_id` is the real image-version id from the image solution.
- `dcr_id` is the AVD Insights DCR id from `lz-avd`.

## Known residuals

- The Microsoft-documented install puts `REGISTRATIONTOKEN=<token>` on the `msiexec` command line inside the guest. If process-creation auditing with command lines (event 4688) or Sysmon is enabled on the VM, the token is recorded there. The token is short-lived (`-ExpirationHours`, default 2); keep command-line auditing off on freshly built session hosts or treat that log as sensitive.
- Windows 11 multi-session is not eligible for Azure automatic guest patching (Learn: Windows Update management for AVD session hosts), so the VMs use `patchMode: Manual`; patch through the image and session host update.
- The Run Command name is fixed per VM. Do not run two registrations against the same VM at once.
- If a host does not reach `Available` after an installer that needed a reboot (MSI exit 3010 is accepted as success), restart the guest and re-check; the script waits only for the configured time.
