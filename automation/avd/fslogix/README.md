# avd-fslogix

One `fslogix-settings.json` serves the Azure VM, Azure Local VM and Hyper-V VM session hosts ("one configuration profile, three realms"). It holds share **tokens**, not share names: pass the profile and ODFC UNC share roots (outputs `fslogix_profile_unc` and `fslogix_odfc_unc` of `lz-avd`) when you run the scripts. Nothing changes without `-Execute`; execution also honours `-WhatIf`. Design: `design/avd/landing-zone.md` §7.

## Run order

1. **Share permissions**, from an Entra-joined admin host signed in with the Kerberos context that can reach both shares (a storage-key mount would set the ACLs under the wrong identity):
   `scripts/Set-FslogixSharePermissions.ps1 -ProfileShareUnc … -OdfcShareUnc … -UsersGroupObjectId <guid> -AdminsGroupObjectId <guid>`. Review the plan, then add `-Execute`. It removes inheritance, gives SYSTEM and the admins group Full control, the users group Modify on the root only, CREATOR OWNER Modify on subfolders and files, and removes Authenticated Users and built-in Users. Each write is read back and checked. The groups are given by **object id**; the script converts them to the `S-1-12-1-…` SIDs icacls needs.
2. **Redirections**: `scripts/Publish-FslogixRedirections.ps1 -ProfileShareUnc …` then `-Execute`. It validates the XML first and never replaces a different file without `-Overwrite`.
3. **Host settings on every session host**: `scripts/Set-FslogixHostConfig.ps1 -ProfileShareUnc … -OdfcShareUnc …` then `-Execute` (elevated). Azure VMs: Run Command or DSC. Azure Local VMs: Run Command. Hybrid Hyper-V VMs: a Packer provisioner with the share paths injected at provisioning, so the image stays environment-agnostic. `-SkipDefender` leaves the Defender exclusions alone.
4. **Check**: `scripts/Test-FslogixHostConfig.ps1` with the same parameters (read-only; throws on drift, or returns the rows with `-PassThru`).

`-Mode Production` (default) fails closed: a profile problem blocks sign-in (`PreventLoginWithFailure` / `PreventLoginWithTempProfile` = 1). `-Mode Rehearsal` sets both to 0 for diagnosis only; flip back before the session and check with the same mode you applied.

## Notes

- A hard power-off of a session host leaves the SMB handle on the user's VHDX open until the SMB session times out, so a reconnect can report "profile in use". The operator-controlled fallback is `Close-AzStorageFileHandle -ShareName <share> -Path <user folder> -CloseAll`; it can disrupt a live user, so check for active sessions first.
- `Set-FslogixHostConfig` creates a registry key only when it is missing (`New-Item -Force` on an existing key would clear the values already written to it; a test pins this).
- These scripts cannot verify Microsoft Entra Kerberos end to end. The storage-side Entra app consent, the `kdc_enable_cloud_group_sids` manifest tag and the Conditional Access exclusion are done by `landing-zones/avd/scripts/Set-AvdStorageEntraKerberos.ps1`.
- The Entra Kerberos path for cloud-only identities is a **preview** feature that needs Windows 11 25H2 at build 26200.8116 or later on the hosts (decision P-14).

## Review

Authored by `gpt-6-sol` via the HCS Foundry gateway; reviewed by `deepseek-v4-pro` and `gpt-6-astra` (verification log R-20). Tests: Pester 5.9.1.
