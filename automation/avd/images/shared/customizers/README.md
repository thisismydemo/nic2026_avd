# Shared image customizers

One PowerShell script set used by every builder: Azure Image Builder embeds scripts 01-05 inline (the IaC substitutes the tokens before embedding); Packer renders and runs 01-06. They run inside the image as SYSTEM in Windows PowerShell 5.1.

Authored by gpt-6-sol via the HCS Foundry gateway; review is recorded in `design/shared/verification-log.md`.

| Script | Template token | Meaning |
|---|---|---|
| 02-Install-TeamsWebRtc.ps1 | `{{install_teams_app}}` | `true` provisions new Teams with the bootstrapper; `false` leaves the marketplace-provided app in place. |
| 02-Install-TeamsWebRtc.ps1 | `{{disable_teams_autoupdate}}` | `true` sets the Teams machine-wide update policy. |
| 03-Set-ShortpathListener.ps1 | `{{shortpath_port}}` | UDP listener port, 1024-65535. |
| 04-Set-DefenderExclusions.ps1 | `{{defender_paths}}` | Semicolon-separated local paths; may be empty. |
| 04-Set-DefenderExclusions.ps1 | `{{defender_processes}}` | Semicolon-separated local processes; may be empty. |
| 05-Invoke-Vdot.ps1 | `{{vdot_archive_uri}}` | Pinned VDOT ZIP URI; empty skips VDOT. |
| 05-Invoke-Vdot.ps1 | `{{vdot_archive_sha256}}` | Expected ZIP SHA-256 when VDOT is enabled. |
| 06-Copy-ArcAgent.ps1 | `{{arc_agent_uri}}` | Connected Machine agent MSI download URI. |
| 06-Copy-ArcAgent.ps1 | `{{arc_agent_directory}}` | Local directory the MSI is downloaded to. |

Script 06 is **Packer only**: the agent is installed but never connected. Vendor URLs (verified on Learn): `aka.ms/fslogix_download`, `aka.ms/msrdcwebrtcsvc/msi`, and the Teams bootstrapper `go.microsoft.com/fwlink/?linkid=2243204`.

No identity, enrollment, credential or FSLogix share path is baked into any image. Defender exclusions skip unresolved placeholders and UNC paths. Identity (Entra join), the share paths and any Arc connection are applied per VM after deployment.
