# avd-images-azure

Creates two Azure Image Builder templates in the existing image resource group from the shared customizers (`../shared/customizers`, embedded inline; no staging storage). `lz-avd` supplies the gallery, the image definitions, the AIB user-assigned identity and the image-build subnet.

- **azure** template: distributes to its gallery image definition (the Azure realm uses it).
- **azl** template: distributes to its gallery definition **and** a VHD run output. AIB has no Azure Local distribute target; `avd-images-azure-local` imports the image into Azure Local.

Authored by gpt-6-sol via the HCS Foundry gateway; review is recorded in `design/shared/verification-log.md`.

## Order

1. Deploy `lz-avd`.
2. `scripts/Get-PlatformImageVersion.ps1` for the region, publisher, offer and SKU: the lab pins an **exact** source version so every build is reproducible (AIB would accept `latest`, resolved at build time; the script refuses it by design).
3. Deploy the IaC (Bicep or Terraform) with that version and the two generated template specs. Keep `install_teams_app = 'false'` for the Microsoft 365 marketplace source (it already ships Teams).
4. `scripts/Start-ImageBuild.ps1` without `-Execute` to see the plan, then with `-Execute`. A build takes 45-90 minutes: record it, never run it live. The result is the recorded last-run status; record the resulting gallery image version ids for `avd-images-azure-local` and the session-host solutions.

AIB creates a staging resource group (`IT_<rg>_<template>_<guid>`); the policy exemption in the landing zone covers it.

No identity and no FSLogix share path is baked into either image; Entra join and the share paths are applied per VM.

## Verify at first run

- The customizer exit codes in the AIB customization log.
- The exact source SKU exists in the region (the version script fails otherwise).
- The image-build subnet's network-policy settings allow the AIB proxy / build VM.
- The `WindowsUpdate` customizer: the filter excludes preview updates; check the resulting build number against the Entra Kerberos baseline noted in the AVD landing-zone design.

`Start-ImageBuild.ps1` remembers the template's previous `lastRunStatus.startTime` and ignores that status, so a stale `Succeeded` from an earlier run cannot end the wait before the new build has run.
