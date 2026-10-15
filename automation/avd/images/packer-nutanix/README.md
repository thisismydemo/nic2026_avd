# Packer: Windows 11 Enterprise single-session on Nutanix AHV

**Reference template, not run end to end.** `packer init`, `fmt -check` and `validate` pass (Packer 1.16.1, Nutanix plugin 1.3.0); no build has been run against a Prism endpoint. The first build in your own environment is the real test.

It builds a UEFI Secure Boot, vTPM Windows 11 Enterprise single-session image for AVD Hybrid session hosts, with the same shared customizers, order and manifest output as the [Hyper-V template](../packer-hyperv/README.md). AVD Hybrid hosts must be single-session Windows 11 Enterprise (or Windows Server).

## Prerequisites

- Packer 1.11 or later and the `github.com/nutanix-cloud-native/nutanix` plugin (`packer init`).
- Prism access to a cluster whose AOS and AHV versions support Secure Boot and vTPM for guests.
- Two images already imported into Prism: the Windows 11 Enterprise ISO and the signed Windows 11 VirtIO driver ISO.
- A build subnet that Packer can reach over WinRM; isolate it.
- The shared customizers in [`../shared/customizers`](../shared/customizers/README.md) (the default `customizer_directory`).

## Run

Set the values in your environment file; nothing is edited in a Packer file. The `images.nutanix` block holds the Prism endpoint, account, cluster, subnet and the two image names, `images.build_admin_username_secret` and `images.build_admin_password_secret` are the Key Vault references of the build account, and the optional `images.packer_*`, `images.image_version` and `images.arc_agent_*` keys tune the build (see the commented example in `automation/shared/examples/environment.avd.example.yml`). `packer/windows11.auto.pkrvars.example.json` only shows the shape of the variable file.

Generate the variable file from the environment file, resolve the three secrets into the environment of the shell that runs Packer (never into a file or an argument), then build:

```powershell
Import-Module ./automation/shared/powershell/NIC26.Automation/NIC26.Automation.psd1
$cfg = Get-NIC26Config -Scope avd
ConvertTo-NIC26PackerVars -Solution avd-images-packer-nutanix -Config $cfg -Execute   # writes packer/windows11.generated.auto.pkrvars.json
$env:PKR_VAR_build_username = Resolve-NIC26KeyVaultRef -Ref $cfg.values.images.build_admin_username_secret -AsPlainText
$env:PKR_VAR_build_password = Resolve-NIC26KeyVaultRef -Ref $cfg.values.images.build_admin_password_secret -AsPlainText
$env:PKR_VAR_nutanix_password = Resolve-NIC26KeyVaultRef -Ref $cfg.values.images.nutanix.password_secret -AsPlainText
Set-Location ./automation/avd/images/packer-nutanix/packer
packer init .
packer validate .
packer build .
```

Packer loads `windows11.generated.auto.pkrvars.json` by itself (the name ends in `.auto.pkrvars.json`). Remove the three variables from the shell afterwards (`Remove-Item Env:PKR_VAR_*`). Do not commit generated media or Packer logs.

## How the answer file reaches Setup

`cd_content` renders `templates/autounattend.xml.tpl` into a CD that Packer attaches to the build VM. The answer file's windowsPE pass lists VirtIO driver paths (storage and network) on several candidate drive letters so Setup can see the disk and the NIC.

## Known gaps and limits

- Confirm the drive letters and VirtIO folder names on the first run; the candidate list is a reference, not proven.
- The Nutanix guest tools are not installed by this template; add and verify an installer step before the sysprep shutdown command.
- Windows updates are not installed; install and verify them, including pending reboots, before sysprep.
- The answer file carries a temporary plaintext build password that sysprep removes with the account. Do not retain the generated CD.
- WinRM runs over HTTP with Basic authentication on the isolated build network only.
- CPU topology is one socket with N cores (Windows 11 supports at most two sockets).
- Cleanup before capture: the build WinRM settings (HTTP, Basic) stay in the image and the cached unattend files stay under `C:\Windows\Panther`; harden WinRM and remove residual unattend files before sysprep in your own pipeline.
- Arc: the template stages the Connected Machine agent installer (customizer 06); onboarding happens at deployment, not in the image.
- Not validated here: Secure Boot and vTPM on your AHV version, disk and NIC ordering, licensing, sysprep result, and AVD Hybrid registration.
