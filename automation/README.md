# AVD Anywhere: deployment automation

Automation that deploys the AVD Anywhere session's three deployment models (Azure, Azure Local, AVD Hybrid) from one configuration. Every value comes from a parameter, a `solution.yml` input or your environment files; nothing in the code is tied to a tenant, subscription, site or piece of hardware. Bicep and Terraform are kept in parity; PowerShell does the orchestration and the guest-level steps.

## Map

```text
automation/
├── shared/                          NIC26.Automation module (config loader, naming, converters, Key Vault resolver), JSON Schemas, examples
├── landing-zones/avd/               AVD spoke, private DNS resolver, FSLogix storage, monitoring configuration, Entra groups and SSO scripts
├── avd/
│   ├── control-plane/               workspace, host pools, application groups, scaling plan
│   ├── fslogix/                     share permissions, host settings, redirections.xml
│   ├── images/                      Azure Image Builder (Azure, Azure Local); Packer templates for Hyper-V (tested), vSphere and Nutanix AHV (reference, not run)
│   ├── session-hosts-azure/         platform "Azure"
│   ├── session-hosts-azure-local/   platform "Azure Local"
│   └── session-hosts-hybrid/        platform "Hybrid": Hyper-V VMs, Arc agent, CloudDeviceExtension
└── demo/{avd,shared}/               the helpers the follow-along guide uses (state, routing, portability, failure, smoke test)
```

## Run order

| # | Stage | Folder |
|---|---|---|
| 1 | Prerequisites: Entra groups, resource providers, Terraform state storage | `landing-zones/avd/scripts` |
| 2 | Landing zone | `landing-zones/avd` |
| 3 | Control plane | `avd/control-plane` |
| 4 | FSLogix | `avd/fslogix` |
| 5 | Images | `avd/images/*` |
| 6 | Session hosts per platform | `avd/session-hosts-*` |
| 7 | Demo helpers | `demo/avd` |

For every solution the loop is the same:

```powershell
Import-Module .\automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 -Force
$cfg = Get-NIC26Config -Scope avd                    # validates environment/<scope>/*.yml against the schemas
ConvertTo-NIC26BicepParam -Solution <solution folder or name> -Config $cfg -Execute
ConvertTo-NIC26TfVars     -Solution <solution folder or name> -Config $cfg -Execute
# Terraform state: New-NIC26TerraformBackendConfig -Solution <solution folder or name> -Config $cfg -Execute writes the -backend-config file from terraform_backend
# then the solution's own README: what-if or plan, review, deploy with -Execute, run its tests
```

Three things to know about the loop:

- **Wrapper-deployed solutions.** `avd/images/azure`, `avd/session-hosts-azure`, `avd/session-hosts-azure-local` and `avd/session-hosts-hybrid` take outputs of earlier stages (identity ids, the data collection rule, the host pool) and secure values (admin and domain-join credentials) that no environment file holds. The generated parameter file is therefore not complete for them. Deploy them through their wrapper script, which supplies those values in memory; `bicep/main.example.bicepparam` in each folder shows the full shape.
- **Tuning inputs.** Optional inputs (for example the VDOT and Teams switches, `defender_paths`, `enable_scaling_plan`, the session-host disk and size settings and the image build and Packer settings) have a default in the solution's `solution.yml`; set them in your environment file to change them. Each one is an optional key of the environment schema with a commented example in `shared/examples`; everything an environment file can set is in `shared/schemas`.
- **Entry points outside the loop.** `avd/images/packer-nutanix` and `avd/images/packer-vsphere` are Packer templates with their own README and variables file; they have no `solution.yml`.

## Your configuration

Copy the files in `shared/examples/` to `environment/shared/environment.yml` and `environment/avd/environment.yml` and replace every value (tenant, subscriptions, address plan, names). Secret values never go in a file: fields that need one hold `keyvault://<vault>/<secret>` references that are resolved in memory. The naming defaults (organisation, token, region) come from `shared/powershell/NIC26.Automation/NamingDefaults.psd1`, the `NIC26_ORG`, `NIC26_TOKEN` and `NIC26_REGION` variables, or your environment file; set your own. `landing-zones/avd/README.md` has the full configuration reference.

## Prerequisites

PowerShell 7.4+, `powershell-yaml`, Az PowerShell, Azure CLI with Bicep, Terraform 1.9+, Pester 5.5+ and PSScriptAnalyzer, Packer 1.10+ for the image templates. Owner or equivalent rights on the target subscription for the landing zone; each solution README lists what it needs.

## Safety

Anything that changes state needs `-Execute`; destructive actions default to `-WhatIf` and ask for a typed confirmation. Examples use IIC placeholder names and all-zero GUIDs. Packer templates for vSphere and Nutanix AHV are reference templates that have not been run against those platforms.

## Tests

Run each suite in its own PowerShell session: suites that load the real Az modules change what later suites in the same session can mock.

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path .\automation\shared\powershell\NIC26.Automation\Tests -Output Detailed
Invoke-Pester -Path .\automation\landing-zones\avd\tests -Output Detailed
Invoke-Pester -Path .\automation\avd -Output Detailed
Invoke-Pester -Path .\automation\demo\avd\tests -Output Detailed
Invoke-Pester -Path .\automation\demo\shared\tests -Output Detailed
```

## Example names and values

The example files use neutral values: private-range addresses and VLAN IDs that belong to no real site. `iic` (a fictional organisation) and `nic26` (the module prefix) are deliberate example names. Replace every value in your own copies of the `*.example.*` files before you deploy; keep the examples themselves unchanged.
