# avd-session-hosts-hybrid

AVD Hybrid realm: two plain **Generation 2 Hyper-V VMs** on the Azure Local cluster (clustered VM roles outside Azure Local VM management), Entra-joined by a provisioning package, Arc-enabled, and registered to the Hybrid host pool through the `Microsoft.AzureVirtualDesktop.CloudDeviceExtension`. Implements `design/avd/hybrid-hyperv-hosts.md` (HYB-01..09).

Authored by gpt-6-sol via the HCS Foundry gateway; external review is recorded in `design/shared/verification-log.md`. Nothing here is deployed.

## What is where

| Part | Files | Runs |
|---|---|---|
| IaC (Bicep + Terraform) | `bicep/`, `terraform/` | Arc-RG RBAC (off by default: lz-avd owns it), AMA extension + DCR association on the two Arc machines (off until the machines exist) |
| VM build | `scripts/New-HybridVm.ps1`, `HybridCommon.psm1` | On the VM's preferred-owner node |
| vTPM guardians | `scripts/Sync-HybridGuardianCertificates.ps1` | On each node (export, copy over a secure channel, import) |
| Entra join + Arc | `scripts/Install-ArcAgent.ps1` | Jump server / node, over PowerShell Direct |
| AVD registration | `scripts/Register-HybridHosts.ps1` | Jump server (K-7: the token is never stored) |
| Validation | `scripts/Test-HybridHost.ps1` | Jump server, read-only |
| Network data | `scripts/Set-HybridVmDhcpData.ps1` | Writes the DHCP reservation JSON (hostname, MAC, IP, VLAN) for your DHCP server or network automation |
| Teardown | `scripts/Remove-HybridVm.ps1` | Destructive; needs owner approval, `-Execute`, `-ConfirmName` and `-Confirm` |

## Order (design section 14)

1. Image: the Packer master VHDX exists on the CSV (`avd/images`).
2. `Sync-HybridGuardianCertificates.ps1`: export on each node, import on the other, so a VM with a local key protector can start on either node. Prove live migration and cold failover in both directions before the demo.
3. `New-HybridVm.ps1` per VM on its owner node (plan first, then `-Execute`; add `-Start` to boot). The Entra bulk-enrollment package is written only into the mounted image and removed by the first-boot script.
4. `Set-HybridVmDhcpData.ps1` and apply the reservations on your DHCP server or through your network automation.
5. After first boot: `Install-ArcAgent.ps1` (checks `AzureAdJoined : YES`, connects Arc, checks `Connected`). PowerShell Direct only reaches VMs on the Hyper-V host it starts from: run it on the node that currently runs the VM, or from the jump server with `-ComputerName <node>`. The Arc agent MSI must already be in the image (the script fails with a fixed message if it is not).
6. IaC with `enable_arc_extensions = true` (AMA + DCR), then `Register-HybridHosts.ps1` (extension with the token as a protected setting, wait for `Available`, up to 15 minutes), then `Test-HybridHost.ps1`.

## Residuals and first-day checks

- `azcmagent connect` takes the onboarding service-principal secret on the guest command line; guest command-line auditing (event 4688) or Sysmon would record it. The principal can only create Arc machines in the Arc resource group; rotate its secret after the build.
- The Learn install of the Arc/AVD extension is the documented Hybrid path; the first VM on this hardware is the early test of `CloudDeviceExtension` (master plan "verify early").
- Unattend placement (`Panther\Unattend\Unattend.xml` and the specialize-pass command) and `Install-ProvisioningPackage` timing on Windows 11 25H2 are **(verify)** items in the design; the fallback is the `Recovery\Customizations` pickup.
- `Add-ClusterVirtualMachineRole` cannot run remotely without CredSSP, so the build runs locally on the node.
- Windows 11 is not patched by Azure Update Manager; the patch channel is Intune / Windows Update for Business.
- The clustered role is **offline, not failed**, after an administrator hard power-off: the operator restarts the VM (the demo's lesson, HYB-09).
- The AVD registration token is passed in the extension's **protected settings**, which the Arc extension service persists encrypted as extension configuration (the documented Hybrid mechanism). It is never in IaC, files, state or logs and expires after `-ExpirationHours` (default 2).
- The guardian PFX files hold private keys: export to a local, access-restricted folder (never the CSV; the script refuses), use a strong one-time password, copy over an administrator channel, import with `-RemoveFilesAfterImport`, and delete the source copy.
- If a build stops part-way (power loss, killed session), `New-HybridVm.ps1` refuses to run again because the VM disk exists: `Dismount-VHD` it if it is still mounted, delete the VM folder, and re-run. A half-finished image can hold the Entra bulk-enrollment package until then.
- The answer file is placed at `Windows\Panther\Unattend\Unattend.xml` (an implicit search location). Components carry their full identity, OOBE uses the `Hide*`/`ProtectYourPC` settings (Learn: do not use `SkipMachineOOBE`), and the first-boot script deletes the file after the specialize pass; Setup removes sensitive data from the cached copy at the end of each pass.
