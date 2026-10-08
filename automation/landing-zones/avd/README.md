# lz-avd — AVD landing zone

Implements design/avd/landing-zone.md (AVD-LZ-01..14) under the rules of automation/CONTRACT.md. It is the foundation the AVD solutions (`avd-control-plane`, `avd-fslogix`, `avd-images`, `session-hosts-*`) build on. Nothing here deploys by itself: every script is `-WhatIf` by default and changes Azure only with `-Execute`.

## Ownership before deployment

The workload-only default is `deploy_platform_scope_items=false`. The template does not write the platform-owned hub reverse peering or policy assignments in this mode. The platform must supply an existing hub-to-AVD peering with gateway transit before the spoke enables remote gateways. The Azure Local reverse peering is workload-owned and remains in this deployment. D-040 approves only the three Azure Local platform reverse peerings; it does not approve an AVD hub reverse peering.

Use the centrally delivered monitoring workspace for `log_analytics_workspace_id`. A budget amount of zero skips the workload budget while its placement or access remains unresolved; positive amounts retain the existing budget behavior. These omissions do not prove that platform controls or connectivity are present: read and verify them separately.

For Terraform state that already manages a platform resource, changing the flag to false can plan its destruction. Review ownership and transfer state before applying; never use the flag to delete platform resources. Bicep incremental mode retains resources omitted by a false condition.

## What it deploys

| Area | Resources | Design |
|---|---|---|
| Governance | 7 resource groups by lifecycle (`control`, `net`, `hosts`, `img`, `stor`, `mon`, `arc`), tags, subscription budget (50/80/100 % actual + 100 % forecast), built-in policy assignments (allowed locations, require/inherit 5 tags, storage hygiene audit, no public IPs on the hosts RG) | §2, §3 |
| Network | Spoke VNet (`avd_vnet_prefix`) with `hosts`, `pe`, `imgbuild` (private-link policies off), `dnsin` (delegated) subnets; three NSGs per §4.6; peerings hub↔spoke (hub reverse side only with platform-scope approval, gateway transit) and spoke↔Azure Local spoke (both sides); DNS Private Resolver inbound endpoint only with `enable_private_endpoints` and `enable_dns_private_resolver` (D-029: off by default) | §4 |
| Private DNS | **Off by default (D-029).** With `enable_private_endpoints=true`: own `privatelink.file.core.windows.net` zone (P-11) linked to the AVD spoke, the Azure Local spoke and the identity VNet; hub link behind `link_privatelink_zone_to_hub` | §4.5 |
| Profiles | Premium FileStorage account: public endpoint by default (D-029; disabled with `enable_private_endpoints`), shared keys only for backup, TLS 1.2, SMB 3.1.1 / Kerberos / AES-256, `directoryServiceOptions = AADKERB`, `defaultSharePermission = None`; two shares with share-level RBAC; private endpoint with DNS zone group only with `enable_private_endpoints`; Recovery Services vault + Azure Files snapshot policy + protected items behind `enable_backup` | §7 |
| Images | Compute Gallery with the definitions listed in `images.image_definitions`; Image Builder identity + two custom roles | §8.1 |
| Identity / RBAC | Host-pool UAMI (Reader on the Arc RG), users/admins VM login roles on the hosts and Arc RGs, Desktop Virtualization Contributor/Reader, share roles, Arc onboarding role for the SPN (when `arc_onboard_sp_object_id` is set) | §5.3, hybrid §3 |
| Monitoring | AVD Insights DCR (default counters/events, Windows kind) to the supplied central workspace; three scheduled-query alerts to the ops action group; diagnostic settings on VNet, NSGs, storage, vault | §9 |

Not in this solution (owned elsewhere): AVD workspace/host pools/app groups/scaling plan (`avd-control-plane`), AIB templates and Packer (`avd-images`), session hosts, the Azure Local VM RG cross-subscription Reader (lz-azure-local, needs `hostpool_identity_principal_id`), the ops vault / workspace / action group / jump server (lz-azure-local).

## Inputs and outputs

The single source is [`solution.yml`](solution.yml): every input (canonical names from the design variables table, `path:` where the environment schema key differs, e.g. `lab_token -> token`, `p2s_pool -> p2s_client_pool`, `image_definitions -> images.image_definitions`) and every output. Bicep parameters, Terraform variables and outputs mirror it one-to-one (`tests/LzAvd.Parity.Tests.ps1`). Names come only from the `names:` catalog (contract §10) and reach IaC as the `names` object.

Inputs added beyond the design table (reported to the owner): `bastion_subnet_prefix` (admin RDP source; design named it without a variable), `owner_email`, `enable_dns_private_resolver`, `enable_backup`, `enable_policy_assignments`, `link_privatelink_zone_to_hub`, `arc_onboard_sp_object_id`. These flags are supported by `automation/shared/schemas/avd.environment.schema.json`. The additional `deploy_platform_scope_items` flag defaults to false and gates platform-owned delivery.

Outputs consumed downstream: resource group names, subnet ids, `dns_resolver_inbound_ip` (Azure Local lnet DNS and the Hyper-V DHCP reservations), `privatelink_file_zone_id`, storage account id/name and both UNC paths, `gallery_id` + `image_definition_ids`, host-pool identity ids, `aib_identity_*`, `dcr_avd_insights_id`, `recovery_vault_id`.

## Configuration reference: every variable, default, where to set it

Nothing environment-specific is written in the code. Every name, region, address range, identity and size comes from one of three places, and the same values drive the Bicep and the Terraform track:

1. **Your environment config** (`environment/shared/*.yml` and `environment/avd/*.yml`, validated by the schemas in `automation/shared/schemas`). Start from the `main.example.bicepparam` and `terraform.example.tfvars.json` files next to the code: they use the placeholder organisation `iic`, the lab token `nic26`, all-zero GUIDs and the `contoso.com` domain. Replace them with your own values.
2. **The name catalog** (the `names:` section of `solution.yml`). Resource names are generated from `org`, `lab_token` and `location_short` by the shared naming module, never typed in code. Peering names are derived from the VNet names in the catalog.
3. **Script parameters.** The Entra and clean-up scripts take `-Org`, `-LabToken`, `-Users`, `-Domain`, `-KeyVaultName` and `-SecretNamePrefix` as mandatory parameters; there are no lab defaults to forget to change.

| Variable | Type | Required | Default | Where to set it | What it does |
|---|---|---|---|---|---|
| `org` | string | required |  | your environment config (`environment/`) | Organization token in every name (D-006). |
| `lab_token` | string | required |  | your environment config (`environment/`) | Lab/conference token in every name (D-005); shared schema key `token`. |
| `location` | string | required |  | your environment config (`environment/`) | Azure region for every regional resource (D-010). |
| `location_short` | string | required |  | your environment config (`environment/`) | Short region token used in names. |
| `tenant_id` | string | required |  | your environment config (`environment/`) | Entra tenant id (D-002). |
| `subscription_id_avd` | string | required |  | your environment config (`environment/`) | AVD landing-zone subscription id (D-004). |
| `subscription_id_azl` | string | required |  | your environment config (`environment/`) | Azure Local landing-zone subscription id (D-004); far side of the spoke-to-spoke peering. |
| `management_group_id` | string | required |  | your environment config (`environment/`) | Parent management group (D-004); informational, policy is assigned at subscription scope (P-06). |
| `tags` | map | required |  | your environment config (`environment/`) | The seven required tags (naming standard 3a); workload=avd and managed-by are added per track. |
| `owner_email` | string | required |  | your environment config (`environment/`) | Owner e-mail for budget notifications (shared schema key). |
| `names` | map | required |  | generated (name catalog or another solution) | Name catalog resolved by ConvertTo-NIC26BicepParam / ConvertTo-NIC26TfVars from the names section below (contract 10). |
| `hub_vnet_id` | string | required |  | your environment config (`environment/`) | Existing hub VNet resource id (connectivity subscription). The hub-side peering is the only change made to it. |
| `hub_address_space` | string | required |  | your environment config (`environment/`) | Hub address space (reference for NSG sanity checks). |
| `identity_spoke_vnet_id` | string | required |  | your environment config (`environment/`) | Existing identity spoke VNet id; receives a link to the lab's privatelink.file zone (P-11). |
| `p2s_pool` | string | required |  | your environment config (`environment/`) | Point-to-site client pool (presenter path, D-018) for the Shortpath NSG rule; shared schema key `p2s_client_pool`. |
| `bastion_subnet_prefix` | string | required |  | your environment config (`environment/`) | Existing AzureBastionSubnet prefix; admin RDP source for the hosts NSG (design 4.6). The lab jump server is covered by azl_spoke_prefix. |
| `onprem_compute_prefixes` | list | required |  | your environment config (`environment/`) | On-prem session-host ranges (AVD-hosts VLAN per P-08 plus the Azure Local AVD lnet range) allowed to the private endpoint. |
| `azl_spoke_vnet_id` | string | required |  | your environment config (`environment/`) | Azure Local spoke VNet id (lz-azure-local output) for the direct spoke-to-spoke peering and the zone link. |
| `azl_spoke_prefix` | string | required |  | your environment config (`environment/`) | Azure Local spoke prefix (NSG rules; also the admin source for the jump server). |
| `log_analytics_workspace_id` | string | required |  | your environment config (`environment/`) | Supplied central monitoring workspace; destination for the AVD DCR, diagnostics and alerts (AVD-LZ-12). |
| `key_vault_id` | string | required |  | your environment config (`environment/`) | Operations vault id (lz-azure-local output). Consumed by scripts only; IaC never reads secrets (AVD-LZ-13). |
| `action_group_id` | string | required |  | your environment config (`environment/`) | Ops action group id (lz-azure-local output) for budget and alert notifications. |
| `avd_vnet_prefix` | string | required |  | your environment config (`environment/`) | AVD spoke address space (AVD-LZ-04). |
| `avd_subnets` | map | required |  | your environment config (`environment/`) | Subnet prefixes keyed hosts, pe, imgbuild, dnsin (design 4.1). |
| `enable_private_endpoints` | bool | optional | `False` | your environment config (`environment/`) | Owner decision D-029: false (default) = Azure Files on its public endpoint; no privatelink zone, links or resolver. true restores the private-endpoint design. |
| `enable_dns_private_resolver` | bool | optional | `True` | your environment config (`environment/`) | Deploy the DNS Private Resolver inbound endpoint (AVD-LZ-06 / P-07 option B). Set false for the DC conditional-forwarder option. ADDED flag; not yet in avd.environment.schema.json. |
| `dns_resolver_inbound_ip` | string | required |  | your environment config (`environment/`) | Static IP of the resolver inbound endpoint inside the dnsin subnet; handed back to the Azure Local design for lnet DNS. |
| `privatelink_file_zone_id` | string | optional | (empty) | your environment config (`environment/`) | Existing privatelink.file.core.windows.net zone id to reuse; empty creates the lab's own zone (P-11). |
| `link_privatelink_zone_to_hub` | bool | optional | `False` | your environment config (`environment/`) | Also link the zone to the hub VNet (design 4.5 lists the hub; P-11 lists the identity VNet). ADDED flag; not yet in the schema. |
| `share_names` | map | required |  | your environment config (`environment/`) | FSLogix share names keyed profiles and odfc (naming standard 5). |
| `share_quota_gib` | int | optional | `256` | your environment config (`environment/`) | Provisioned size per share in GiB. |
| `enable_backup` | bool | optional | `True` | your environment config (`environment/`) | Deploy the Recovery Services vault and protect both shares (design 7.9). ADDED flag; not yet in the schema. |
| `backup_policy` | map | required |  | your environment config (`environment/`) | Azure Files backup policy: schedule_time_utc (HH:mm), retention_days (schema shape). |
| `image_definitions` | list | required |  | your environment config (`environment/`) | Gallery image definitions (name, publisher, offer, sku, os_type, hyper_v_generation, security_type, os_state); schema path images.image_definitions. |
| `avd_budget_monthly` | int | required |  | your environment config (`environment/`) | Monthly budget amount (design 2.3). |
| `enable_policy_assignments` | bool | optional | `True` | your environment config (`environment/`) | Assign the built-in Deny/Audit/Modify policies of design 2.4 at subscription scope. ADDED flag; not yet in the schema (DINE policies are a documented gap). |
| `group_object_ids` | map | required |  | your environment config (`environment/`) | Object ids of the AVD groups (schema keys avd_azure, avd_azl, avd_hybrid, avd_users, avd_admins, avd_devices, lab_operators); this solution uses avd_users, avd_admins, lab_operators. |
| `arc_onboard_sp_object_id` | string | optional | (empty) | your environment config (`environment/`) | Object id of the Arc onboarding service principal (New-AvdEntraGroups.ps1 -IncludeArcOnboardingPrincipal); empty skips its role assignment. ADDED; not yet in the schema. |


Built-in Azure role and policy definition IDs in `bicep/modules/builtin-ids.bicep` are fixed Microsoft constants, not environment values. Microsoft download links (AVD Agent, Bootloader) are parameters of the registration scripts with the current links as defaults.
## Modules (verified 2026-10-03, versions pinned)

Bicep (`br/public:avm/...`):

| Module | Version | Used for |
|---|---|---|
| `avm/res/resources/resource-group` | 0.4.4 | 7 RGs |
| `avm/res/network/network-security-group` | 0.5.3 | 3 NSGs (+diagnostics) |
| `avm/res/network/virtual-network` | 0.10.2 | spoke VNet + subnets |
| `avm/res/network/virtual-network/virtual-network-peering` | 0.2.0 | 4 peerings (hub and Azure Local sides deployed cross-subscription by scope) |
| `avm/res/network/dns-resolver` | 0.5.8 | resolver + inbound endpoint (design said "AVM not confirmed"; it exists and is pinned) |
| `avm/res/network/private-dns-zone` | 0.8.1 | zone + links |
| `avm/res/storage/storage-account` | 0.33.1 | account, shares, share RBAC, private endpoint (through its `privateEndpoints` interface), diagnostics |
| `avm/res/recovery-services/vault` | 0.13.2 | vault + Azure Files policy (design said "AVM not confirmed"; it exists and is pinned) |
| `avm/res/compute/gallery` | 0.9.5 | gallery + image definitions + Reader for lab operators |
| `avm/res/managed-identity/user-assigned-identity` | 0.6.0 | host-pool and AIB identities (design: "believed to exist; verify" — verified) |
| `avm/res/insights/data-collection-rule` | 0.11.0 | AVD Insights DCR |
| `avm/res/insights/scheduled-query-rule` | 0.6.0 | 3 alert rules |
| `avm/res/authorization/role-assignment/rg-scope` | 0.1.1 | RG-scope role assignments |
| `avm/res/authorization/role-assignment/sub-scope` | 0.1.1 | Desktop Virtualization Reader at subscription scope |

Bicep gap-fill modules in [`bicep/modules/`](bicep/modules/) and why:

| Module | Why not AVM |
|---|---|
| `budget.bicep` | `avm/res/consumption/budget` 0.3.8 applies one `thresholdType` to all thresholds; the design needs Actual 50/80/100 and Forecasted 100 in one budget |
| `policy-assignments.bicep`, `policy-assignment-rg.bicep` | `avm/ptn/authorization/policy-assignment` 0.5.3 is a management-group-scoped template; P-06 assigns at subscription scope |
| `role-definitions.bicep` | no AVM module publishes `Microsoft.Authorization/roleDefinitions` (the two Image Builder custom roles) |
| `backup-fileshare.bicep` | the AVM vault module does not register the storage account's protection container, which Azure requires before an Azure Files protected item |
| `builtin-ids.bicep` | the single file holding Microsoft built-in role/policy definition GUIDs (the role-assignment AVM modules resolve only a short list of role names); `Test-AvdLandingZone.ps1` check 11 verifies the policy ids against their display names live |

Terraform (`Azure/avm-res-*/azurerm`): `resources-resourcegroup` 0.4.0, `network-networksecuritygroup` 0.5.2, `network-virtualnetwork` 0.22.2, `network-dnsresolver` 0.8.0, `network-privatednszone` 0.5.0, `storage-storageaccount` 0.10.0, `recoveryservices-vault` 1.3.2, `compute-gallery` 0.2.1, `managedidentity-userassignedidentity` 0.5.3, `insights-datacollectionrule` 0.1.0. Providers: `hashicorp/azurerm ~> 4.60` (the modules cap at `< 5.0`), `Azure/azapi ~> 2.12`, `hashicorp/random ~> 3.6`. Plain resources where no AVM module exists: peerings (`azapi_resource`, one provider for both subscriptions), budget (`azurerm_consumption_budget_subscription`), policy (`azurerm_*_policy_assignment` with `data.azurerm_policy_definition` by display name — no GUIDs), custom roles (`azurerm_role_definition`), role assignments (`azurerm_role_assignment` by role name, as the design lists), alerts (`azurerm_monitor_scheduled_query_rules_alert_v2`).

## Parity gaps

- Terraform looks policy definitions up by display name; Bicep must carry their GUIDs (`builtin-ids.bicep`). Same definitions, different lookup.
- The Bicep track uses the vault's `backup-fileshare.bicep` gap-fill; Terraform uses the AVM vault module's `backup_protected_file_share`. Same end state.
- The gallery image-definition ids are a module output in Bicep and composed from the gallery id in Terraform.
- `tags.managed-by` is `bicep` or `terraform` per track by design (§2.4); everything else is identical.

## How to run (authoring machine or the jump server)

```powershell
# 0. once: providers (read-only report; -Execute registers)
.\scripts\Register-AvdProviders.ps1 -SubscriptionId <avd sub id>

# 1. generate the parameter files from environment/ (git-ignored outputs) and preview — changes nothing
Import-Module ..\..\shared\powershell\NIC26.Automation
$cfg = Get-NIC26Config -Scope avd
ConvertTo-NIC26BicepParam -Solution lz-avd -Config $cfg -Execute
ConvertTo-NIC26TfVars     -Solution lz-avd -Config $cfg -Execute
.\scripts\Invoke-LzAvdDeploy.ps1 -Tool Bicep            # Prereqs, Generate, Validate, Preview (what-if)
.\scripts\Invoke-LzAvdDeploy.ps1 -Tool Terraform -BackendConfig ..\..\..\environment\avd\backend.lz-avd.hcl

# 2. deploy (owner approval; still prompts, -Confirm:$false to skip)
.\scripts\Invoke-LzAvdDeploy.ps1 -Tool Bicep -Stage Deploy -Execute

# 3. validate (read-only; run from the jump server and from a session host for the DNS/445 probes)
.\scripts\Test-AvdLandingZone.ps1 -InputFile .\terraform\terraform.generated.tfvars.json -OutputJson .\lz-avd-validation.json
```

Order with the other solutions: lz-azure-local (vault, workspace, action group, Azure Local spoke) → `New-AvdEntraGroups.ps1` (object ids into the environment file) → **lz-avd** → `Set-AvdStorageEntraKerberos.ps1` → `New-AvdDemoUsers.ps1` → avd-control-plane → avd-images → session hosts. The stray-resource decommission (P-10) runs before lz-avd: `Remove-StrayAvdLzResources.ps1 -SubscriptionId <id>` lists, `-Execute -ConfirmDeleteList <owner-approved.json>` deletes only ids from that list that are stray and inside that subscription.

## Scripts

| Script | Default | Changes with |
|---|---|---|
| `Invoke-LzAvdDeploy.ps1` | what-if / plan | `-Stage Deploy -Execute` |
| `Register-AvdProviders.ps1` | report | `-Execute` |
| `New-AvdEntraGroups.ps1` | report | `-Execute` (groups, nesting, dynamic device group; `-IncludeArcOnboardingPrincipal` writes the SPN secret to the ops vault — Windows jump server only) |
| `New-AvdDemoUsers.ps1` | report | `-Execute` (Windows jump server only; passwords generated in memory, written to the vault, never shown). Pass `-UsersGroupName` so each user becomes a direct member of the union group that holds the share role (Entra Kerberos does not expand nested groups) |
| `Set-AvdStorageEntraKerberos.ps1` | report | `-Execute` (AADKERB, admin consent, `kdc_enable_cloud_group_sids`, privatelink identifierUri only with `-PrivateEndpoints`, CA exclusion for named policies) |
| `Remove-StrayAvdLzResources.ps1` | discovery: writes a hashed candidate file + audit JSON | `-Execute -TenantId -ConfirmDeleteList <reviewed candidate file with approved=true entries>`; `-RemoveLocks` (+ `removeLock=true` per entry); `-DeleteEmptyResourceGroups` (separate run); `-AllowStaleList`; `-ContinueOnError` |
| `Test-AvdLandingZone.ps1` | read-only | never |
| `New-AvdLzTeardownPlan.ps1` | plan | `-Execute` |

## Stray-resource decommission (P-10) — safety model

`Remove-StrayAvdLzResources.ps1` follows the cross-vendor review of the sibling Azure Local script:

1. **Discovery fails closed** (no `SilentlyContinue`; authorization and transport errors are classified and abort). Candidates = no lab token in the name and no `project=<token>` tag. Known types get a deletion order (Arc machines 100 ... workspaces 240); **every other type is an order-800 blocker** (`approved=false`, never deleted here). Locks (own and inherited) are recorded.
2. The candidate file embeds `generatedOn`, `subscriptionId` and a SHA-256 of the item list. The owner sets `approved=true` per entry (`removeLock=true`, `acknowledgePermanent=true` where needed) and hands the same file back as `-ConfirmDeleteList`. **Only objects with `approved` + `id` are accepted; bare strings are an error.** A list for another subscription, with a broken integrity hash, older than 24 h or whose hash differs from the live discovery is refused (`-AllowStaleList` overrides the last two; per-item re-validation still applies).
3. Before each delete the entry is **re-validated against the current candidate (same id and type)**; the context is pinned to the subscription on every Az call and tenant + subscription are verified first. Each delete is **polled to a terminal state** (`-DeleteTimeoutMinutes`, default 10). The run **stops at the first failure** unless `-ContinueOnError`.
4. **Locks are never removed automatically.** Locked items are blocked unless `-RemoveLocks` and the entry's `removeLock=true`; inherited RG/subscription locks are never touched; removed locks are audited and restored when the delete fails.
5. **Resource groups are never deleted in the resource pass.** `-DeleteEmptyResourceGroups` is a separate run: full re-enumeration (any type, errors fatal), only empty and unlocked approved groups, final re-check.
6. **Key Vaults**: soft-delete / purge protection inspected first; soft-delete disabled needs `acknowledgePermanent=true`; after deletion the vault is awaited in the removed state, purged (unless purge-protected), verified; purge failures are reported as `purge-failed`.
7. `-Execute -WhatIf` validates everything and deletes nothing. A **durable audit JSON** (`-AuditFile`) is written on every run: operator, tenant, subscription, mode, reviewed-list hash, each action with timestamp/status/error, lock changes, blocked and skipped items, final state.

## Manual steps that IaC cannot do

1. Entra Kerberos follow-ups on the storage account's generated app `[Storage Account] <account>.file.core.windows.net` — scripted in `Set-AvdStorageEntraKerberos.ps1` (Graph), but they need a Global/Cloud Application Administrator and run *after* the account exists: admin consent (openid, profile, User.Read), the **mandatory cloud-only tag** `kdc_enable_cloud_group_sids`, the `<account>.privatelink.file.core.windows.net` identifierUri (Kerberos through the private endpoint), MFA exclusion in Conditional Access (the script only edits policies you name).
   **Cloud-only Entra Kerberos is PREVIEW** (Learn, read 2026-10-03): session hosts need Windows 11 25H2 with KB5079391 (OS build 26200.8116) or later, Windows 11 24H2 build 26100.8116+, or Windows Server 2025 with current updates. `Test-AvdLandingZone.ps1` prints this as a WARNING/info row, not a failure; the image solution must pin a qualifying build.
2. NTFS root ACLs on both shares (design §7.5) with `icacls` from an Entra-joined admin host; `CloudKerberosTicketRetrievalEnabled` / `LoadCredKeyFromProfile` on every host (realm configuration step).
3. Hub-side peering and zone links need Network Contributor on the hub VNet / join rights on the identity VNet (design open item 2); the azl-side peering needs rights on the Azure Local spoke.
4. Cross-subscription Reader for `hostpool_identity_principal_id` on the Azure Local session-host resource group, which is the cluster resource group `rg-iic-nic26-azl-eus-01` (design §5.4) — done by the Azure Local landing zone owner.
5. P-07: if the owner chooses DC conditional forwarders, set `enable_dns_private_resolver: false` (and add the key to the schema) and add the DC conditional forwarder for `file.core.windows.net` to the Azure DNS virtual IP (design §4.5 option A).
6. The SPN client secret and demo-user passwords live only in the ops vault; registration tokens are never stored (K-7).

## Destroy

`New-AvdLzTeardownPlan.ps1 -InputFile <generated tfvars>` prints and saves the ordered plan (backup items → hub-side peering → Azure Local-side peering → RGs hosts, arc, mon, img, stor, net, control → policy assignments, budget, custom roles). `-Execute` runs it (Bicep track: Az deletions; `-Tool Terraform`: `terraform plan -destroy` then apply). Session-host, control-plane and image solutions are torn down first; shared hub/VPN/DCs/Bastion and the Azure Local landing zone are never touched (the plan drops anything without the lab token).

## Tests and gates

`.\tests\Invoke-LzAvdTests.ps1` runs PSScriptAnalyzer with [`automation/shared/powershell/PSScriptAnalyzerSettings.psd1`](../../shared/powershell/PSScriptAnalyzerSettings.psd1) and the Pester 5 suites: script safety (`LzAvd.Scripts.Tests.ps1`: WhatIf default, `-Execute`, ShouldProcess, no transcript/Write-Host/plaintext conversion, delete only approved + in-subscription ids), parity (`LzAvd.Parity.Tests.ps1`: manifest = Bicep = Terraform for inputs, outputs and names; naming rules), secrets sweep (`LzAvd.Secrets.Tests.ps1`: GUIDs, private identifiers, credential literals, IPs) and IaC (`LzAvd.Iac.Tests.ps1`: `az bicep build` 0 errors/0 warnings on every file, `terraform fmt -check`, `init -backend=false`, `validate`). Requires Pester 5.x (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser`), `powershell-yaml`, az with bicep, terraform, internet for module restore.

## Open items for the owner (also in the build report)

- Naming registry type `role` (custom RBAC role, `{type}-{org}-{token}-{purpose}`) was added by the shared-module owner on 2026-10-03; both converters were dry-run against the shared example environment (37 inputs, 45 names resolved, generated bicepparam compiles against `main.bicep`).
- Environment schema: `enable_dns_private_resolver`, `enable_backup`, `enable_policy_assignments`, `link_privatelink_zone_to_hub`, `arc_onboard_sp_object_id` are being added to `avd.environment.schema.json` and the example file by the shared-module owner; until then the manifest defaults apply.
- Design §4.5 links the zone to the hub, P-11 to the identity VNet — the identity link is built, the hub link is a flag.
- DeployIfNotExists policies (diagnostics, AMA/DCR on Arc machines) are not assigned here; they belong to the Day-2/session-host solutions.

## Azure Files backup needs account-key access (review R-36)

Learn (support matrix for Azure Files backup): the source storage account must have **Allow storage account key access** enabled for backup and restore to work. The profile account would otherwise have it off, so shared-key access now **follows `enable_backup`** (Bicep `allowSharedKeyAccess`, Terraform `shared_access_key_enabled`). With `enable_backup = true` the account allows key access; the FSLogix path itself stays Kerberos-only (SMB authentication method, no default share permission, Entra Kerberos), and account keys must never be output or logged. With `enable_backup = false` the account has no key access. **Decision taken:** Azure Backup is the example, so `enable_backup` stays `true` and the profile account allows key access. `Test-AvdLandingZone.ps1` check 7 asserts the pairing.
