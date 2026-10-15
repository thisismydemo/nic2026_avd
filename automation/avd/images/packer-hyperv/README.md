# avd-images-packer-hyperv

Packer `hyperv-iso` builds a generalized **Windows 11 Enterprise 25H2 Generation 2** VHDX (Secure Boot, vTPM) on an Azure Local node for the AVD Hybrid host pool. It uses the shared customizers (`../shared/customizers`, scripts 01-06), including the Arc agent MSI (installed, never connected).

Authored by gpt-6-sol via the HCS Foundry gateway; review is recorded in `design/shared/verification-log.md`. **`packer init`, `packer fmt -check` and `packer validate` pass with Packer 1.16.1 and the hyperv plugin 1.1.5 (review R-39); a build itself has never been run, so the first build on the Hyper-V host is the real test.** The template needs `customizer_directory` to point at the real shared customizers when validating.

## Use

1. Set the values in your environment file; nothing is edited in a Packer file. The `images` block holds the ISO path and checksum, the output directory and the Key Vault references of the build account (`build_admin_username_secret`, `build_admin_password_secret`); `hybrid` holds the switch and VLAN; optional keys (`images.packer_cpus`, `packer_memory_mb`, `packer_disk_size_mb`, `packer_winrm_timeout`, `image_version`, `arc_agent_uri`, `arc_agent_directory`, `defender_*`, `vdot_*`, `install_teams_app`) tune the build. See the commented example in `automation/shared/examples/environment.avd.example.yml`. `packer/windows11.auto.pkrvars.example.json` only shows the shape of the variable file that is generated for you.
2. `scripts/Invoke-PackerBuild.ps1` without `-Execute` prints the plan. With `-Execute` it generates the Packer variable file from the environment file (`ConvertTo-NIC26PackerVars`) in a temporary folder, resolves the build account from its `keyvault://` references in memory, and runs `packer init`, `validate`, `build`; the build password is set only in the Packer child process (`PKR_VAR_build_password`). `-EnvironmentPath` selects another environment folder; `-VarFile`, `-BuildUsername`, `-BuildPasswordRef` and `-ManifestPath` stay available as overrides. Packer's own output is withheld because plugins can echo rendered content.
3. The script hashes the single produced VHDX and writes a new manifest (VHDX path, SHA-256, build id, Packer version); it never overwrites one. `avd/session-hosts-hybrid` consumes the VHDX as its master image.

## Notes and gaps

- **Windows Update is a known gap.** The template does not install updates (no reliable Packer-native step without a community plugin). Install and verify updates, including pending reboots, before the sysprep `shutdown_command` runs.
- The unattended build account uses `PlainText` because Setup needs it; it exists only in the build VM and sysprep `/generalize` removes it. Isolate the build network (WinRM is unencrypted there), and do not keep or publish the secondary ISO.
- Licensing: an Enterprise volume-license ISO with KMS/MAK or subscription activation. The owner has not yet decided; `product_key` stays empty by default.
- A build is **recorded, not live**.
- The vSphere and Nutanix take-home templates are slides only and are not built here.

## Residuals

- The rendered `autounattend.xml` (with the build password) lives in a secondary ISO that Packer creates in its temporary directory on the build host. Point `PACKER_TMP_DIR` / `TMPDIR` at an access-restricted folder and confirm it is cleaned up after the build.
- Setup removes sensitive data from the cached answer file at the end of each pass (Learn); still check that the captured image holds no plaintext password in `C:\Windows\Panther`.
- The wrapper removes any inherited `PKR_VAR_*` variables from the Packer child process so only the supplied password variable reaches it.
