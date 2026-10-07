# demo-avd — AVD Anywhere session demo helpers

Scripts behind planning/sessions/avd/outline.md §0 (workspace with three pools) and §8 (routing, profile portability, forced session-host failure, one monitoring layer), and the Hybrid failure/recovery design in design/avd/hybrid-hyperv-hosts.md §12. Everything runs from the Windows jump server: Az (`Az.DesktopVirtualization`, `Az.Compute`, `Az.Storage`, `Az.OperationalInsights`), Microsoft Graph for the realm groups, Azure CLI `stack-hci-vm` for the Azure Local realm, PowerShell remoting to the cluster for the Hybrid realm. No RDP automation, no secret is read (registration tokens are never stored, HYB-07).

| Beat | Script | Mode |
|---|---|---|
| §0, §8.1, §8.4 | `Show-AvdState.ps1` | read-only: workspace, 3 host pools, hosts Available/Unavailable, active sessions (`-Count` to refresh) |
| §8.2, §8.3 | `Switch-UserHostPool.ps1 -UserPrincipalName <upn> -TargetRealm azure|azl|hybrid` | `-WhatIf` default; moves the user between the realm groups (or `-Mode Direct` app-group role); reversible, idempotent, UNDO printed first |
| §8.3 | `Test-ProfilePortability.ps1 -UserPrincipalName <upn>` | read-only evidence: FSLogix VHDX name/size/last write, open handles, sessions, host pools signed in to (Insights). No file contents |
| §8.4 | `Stop-SessionHost.ps1 -Realm <r> -HostName <h>` / `Restore-SessionHost.ps1` | `-Execute`; preflight requires a second Available host; azure = deallocate, azl = Arc VM stop, hybrid = `Stop-VM -TurnOff` on the owner node |
| before the session | `Test-AvdDemoSmoke.ps1` | read-only pass/fail list; exit code |

## The Hybrid failure beat (design §12, HYB-09)

```powershell
.\Show-AvdState.ps1 -Count 30 -IntervalSeconds 15                          # second window
.\Stop-SessionHost.ps1 -Realm hybrid -HostName avd-hv01 -Execute      # hard power-off on its owner node; host -> Unavailable
# user reconnects in Windows App -> lands on hv02 with the same profile
.\Restore-SessionHost.ps1 -Execute                                           # Start-ClusterGroup; waits for Available; clears the lock
```

`Restore-SessionHost.ps1` prints the line the presenter must say: **AVD did not restart this VM.** The clustered role was Offline because an administrator turned the VM off, so the cluster did not restart it either; the operator started it (`Start-ClusterGroup`). AVD Hybrid owns no VM lifecycle. If the reconnect is blocked by a stale profile handle (design §12 step 3a): `Close-AzStorageFileHandle -ShareName <profiles share> -Path '<user folder>' -CloseAll -Context (New-AzStorageContext -StorageAccountName <fslogix account> -UseConnectedAccount)`; `Test-ProfilePortability.ps1` shows the open-handle count.

For the Azure realm the same scripts deallocate/start the VM (the platform story); for the Azure Local realm they stop/start the Arc VM through `az stack-hci-vm` (resource group `rg-<org>-<token>-avd-azl-<region>-01` by default — owner of `session-hosts-azure-local` to confirm, `-ResourceGroupName` overrides).

## Routing

Group mode (default) matches how the landing zone assigns desktops: `grp-…-avd-azure|azl|hybrid` are assigned to the realm's desktop application group, so moving the user between groups re-routes the feed (Windows App: sign out, refresh, sign in). `-RemoveOnly` takes the user out of every realm (undo of a first assignment). Names come from `entra_groups` in the environment file and `New-NIC26ResourceName` (`vdpool-…-<realm>`, `vdag-…-<realm>-desktop`).

## Tests

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path .\automation\demo\avd\tests -Output Detailed
```

Covers: Switch-UserHostPool WhatIf default, azure → azl → azure reversal, idempotent no-op, two-realm cleanup, `-RemoveOnly`, Direct mode; Stop/Restore preflight refusal (no second Available host, fault already active), per-realm stop/start wrappers, the "AVD did NOT restart" message and lock lifecycle; Show-AvdState hygiene; profile evidence metadata only; smoke test rows. No Azure, Graph or device is contacted.
