# avd-control-plane

AVD workspace, three host pools (Azure, Azure Local, Hybrid), one Desktop application group per pool, an Azure-pool scaling plan, role assignments and diagnostics. Design: `design/avd/landing-zone.md` §6 (AVD-LZ-09). Bicep and Terraform tracks implement the same contract; values come from `environment/*.yml` through `ConvertTo-NIC26BicepParam` / `ConvertTo-NIC26TfVars`, never from this folder.

## What is here

| Path | Purpose |
|---|---|
| `solution.yml` | Manifest: inputs, outputs, name catalog (contract §2, §10) |
| `bicep/main.bicep`, `bicep/modules/sub-role-assignment.bicep`, `bicep/main.example.bicepparam` | Bicep track (resource-group scope; one subscription-scope module for the Power On Off role) |
| `terraform/` | Terraform track (azapi for host pools, azurerm for the rest) |
| `scripts/New-AvdRegistrationToken.ps1` | Generates a registration token **in memory only** (K-7); `-Revoke` removes it |
| `tests/` | Pester 5 tests for the script |

## Decisions worth knowing

- **Host pools use a preview API on purpose** (`Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview`, Terraform azapi). The stable versions (2024-04-03, 2025-10-10) only allow a system-assigned identity; the design uses one user-assigned identity on all three pools (Reader on the Arc and Azure Local resource groups). Everything else uses stable `2025-10-10`.
- **Diagnostics use the `allLogs` category group** (the AVM default) instead of hand-written category names. It covers Feed, Connection, HostRegistration, AgentHealthStatus, Network, ConnectionGraphics, SessionHostManagement and the pooled Autoscale logs. `Microsoft.Insights/diagnosticSettings@2021-05-01-preview` is the only version that supports category groups (the Bicep linter rule `use-recent-api-versions` is off in this solution's `bicepconfig.json` for that reason).
- **No registration token is created by IaC**, and host pools carry no `registrationInfo`. Run `New-AvdRegistrationToken.ps1 -Execute` at join time and pass the returned SecureString straight to the session-host solution.
- **The scaling plan is for the Azure pool only** (`scaling_plan.assigned_pools`); the Terraform track validates the entries, the example data assigns `azure` only.

## Behaviour to expect (incremental deployment is additive)

- Setting `enable_scaling_plan` to false does **not** remove or disable an already-deployed scaling plan; use `destroy` or delete it. Removing a group id from `group_object_ids` does not revoke the old group's role assignment either. This is by design for a short-lived deployment; treat changes to these inputs as destroy/recreate.
- Role assignments are named deterministically from scope, principal and role. If someone created an equivalent assignment by hand under a different name, the deployment fails with `RoleAssignmentExists`; remove the manual one.

## Run

```powershell
# What-if first (nothing changes without -Execute in the wrapper scripts; Bicep/Terraform use their own plan steps)
az bicep build --file bicep/main.bicep
terraform -chdir=terraform init -backend=false ; terraform -chdir=terraform validate
```

Quality gates: `az bicep build` (0 warnings), `terraform fmt -check`, `terraform init -backend=false` + `validate`, PSScriptAnalyzer (0 findings), `Invoke-Pester` (Pester 5.9.1).

## Review

Authored by `gpt-6-sol` via the HCS Foundry gateway; reviewed by `deepseek-v4-pro` and `gpt-6-astra` (verification log R-08). Not deployed; the first What-If is the next verification step.

## Verify at the first plan / deploy

- Terraform: if `azapi` 2.12 rejects `Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview` locally, set `schema_validation_enabled = false` on `azapi_resource.host_pool` (the service still validates).
- `az monitor diagnostic-settings categories list --resource <scaling plan id>` to confirm `allLogs` is accepted for the scaling plan.
- The first run may need a second apply if RBAC propagation for the Power On Off role lags behind the scaling-plan association.

## Registration-token runtime configuration

`registration_token_ttl_hours` remains in the approved AVD environment configuration. It is a runtime setting, so it is excluded from IaC parameters. Token creation remains a separate, explicit join-time operation that returns a SecureString in memory.

After loading the approved configuration and deployment outputs, pass its lifetime explicitly instead of relying on the token script's two-hour default:

```powershell
$cfg = Get-NIC26Config -Scope avd
$registration = .\scripts\New-AvdRegistrationToken.ps1 -SubscriptionId $cfg.values.subscription_id_avd -ResourceGroupName $outputs.hostpool_rg -HostPoolName $outputs.hostpool_names.azure -ExpirationHours $cfg.values.registration_token_ttl_hours -Execute
```

Pass the returned SecureString directly to session-host protected settings. Do not print it, save it, or include it in a transcript. This control-plane deployment creates no registration tokens.

The scaling schedule maps canonical `ramp_up_load_balancing`, `peak_load_balancing`, `ramp_down_load_balancing` and `off_peak_load_balancing` fields to the Azure API and Terraform provider algorithm properties. Ramp-down uses `ZeroSessions`, matching the existing example policy: hosts stop after sessions are gone. The canonical environment schema does not expose a stop-host-policy field; Bicep and Terraform use this same explicit default.

The optional scaling exclusion tag defaults to an empty string when omitted from the canonical environment, so no tag excludes hosts from the schedule. Both implementations apply the same default.

Canonical schedule start times remain `HH:mm` strings. Bicep maps each of the four times to integer `hour`/`minute` objects required by [the 2025-10-10 scaling-plan API](https://learn.microsoft.com/en-us/azure/templates/microsoft.desktopvirtualization/2025-10-10/scalingplans); Terraform passes the strings directly to its provider.

Power-management autoscale grants the existing shared host-pool managed identity the subscription-scope Desktop Virtualization Power On Off Contributor role before the scaling plan is created, as required by [Microsoft's autoscale prerequisites](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-create-assign-scaling-plan). The tenant-specific optional Azure Virtual Desktop service-principal input remains separate; no managed-identity object ID is substituted into it. Role propagation can delay scaling-plan acceptance after a first assignment.
