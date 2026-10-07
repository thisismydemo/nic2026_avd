# Packer: Windows 11 Enterprise single-session on vSphere

**Reference template, not run in the lab.** `packer init`, `fmt -check` and `validate` pass (Packer 1.16.1, vsphere plugin 2.5.0); no build has been run against a vCenter. The first build in your own environment is the real test.

It builds a UEFI Secure Boot, vTPM Windows 11 Enterprise single-session template for AVD Hybrid session hosts, with the same shared customizers, order and manifest output as the [Hyper-V template](../packer-hyperv/README.md). AVD Hybrid hosts must be single-session Windows 11 Enterprise (or Windows Server).

## Prerequisites

- Packer 1.11 or later and the `github.com/hashicorp/vsphere` plugin (`packer init`).
- A vCenter with a cluster, datastore, folder and a build network; a Windows 11 Enterprise ISO on a datastore.
- A key provider (or native key provider) configured on the vCenter: Windows 11 needs a vTPM.
- The shared customizers in [`../shared/customizers`](../shared/customizers/README.md) (the default `customizer_directory`).
- Network access from the build VM to the endpoints the customizers use; isolate the build network.

## Run

In `packer/`, copy `windows11.auto.pkrvars.example.json` to `windows11.auto.pkrvars.json` and replace the placeholders. Secrets are supplied only through the environment (from your secret store), never in a variable file or argument:

```sh
export PKR_VAR_build_password='<from your secret store>'
export PKR_VAR_vcenter_password='<from your secret store>'
cd packer
packer init .
packer validate -var-file=windows11.auto.pkrvars.json .
packer build -var-file=windows11.auto.pkrvars.json .
```

Unset both variables afterwards. Do not commit generated media or Packer logs.

## Known gaps and limits

- VMware Tools is installed by the answer file at first logon (second ISO, default `[] /vmimages/tools-isoimages/windows.iso`) so vSphere can report the guest IP to Packer; verify the silent install on your ESXi and Tools version.
- Windows updates are not installed; install and verify them, including pending reboots, before sysprep.
- The build uses `lsilogic-sas` and `e1000e` (inbox drivers) so Setup needs no driver injection; confirm they suit your VM compatibility level.
- The answer file carries a temporary plaintext build password that sysprep removes with the account. Protect the datastore and do not retain the generated CD.
- WinRM runs over HTTP with Basic authentication on the isolated build network only.
- Cleanup before capture: the build WinRM settings (HTTP, Basic) stay in the image and the cached unattend files stay under `C:\Windows\Panther`; harden WinRM and remove residual unattend files before sysprep in your own pipeline.
- Arc: the template stages the Connected Machine agent installer (customizer 06); onboarding happens at deployment, not in the image.
- Not validated here: vTPM behaviour with your key provider, ISO edition index, licensing, sysprep result, and AVD Hybrid registration.
