# AVD Anywhere: Azure Virtual Desktop on Azure, Azure Local, and AVD Hybrid Platforms

This repository accompanies a session that shows one AVD workspace with three host pools, one for each deployment model: Azure for elasticity, Azure Local for data gravity, regulation and latency, and AVD Hybrid for Windows Server Hyper-V, VMware vSphere or Nutanix AHV without validated Azure Local hardware. The session uses one identity pattern, one FSLogix profile pattern and one operations story across the three deployment models. The demos route a user to the right host pool, move a profile between host pools and recover from a forced session host failure.

## Session

| | |
|---|---|
| Conference | NIC 2026 |
| Date and time | Wednesday 14 October 2026, 13:20 (W. Europe Time) |
| Length | 60 minutes |
| Level | 400 |
| Speaker | Kristopher Turner |

## Start here

1. Open the [follow-along site](https://thisismydemo.cloud/nic2026_avd/) (GitHub Pages, built by the workflow in this repository), or open the guide as [PDF](follow-along/AVD_Anywhere_Follow_Along_Guide.pdf) or [Word](follow-along/AVD_Anywhere_Follow_Along_Guide.docx) (Markdown: [follow-along/README.md](follow-along/README.md)).
2. Read the handouts, each as PDF or Word (Markdown alongside in [handouts/](handouts/)): Deployment Checklist ([PDF](handouts/Deployment_Checklist.pdf), [Word](handouts/Deployment_Checklist.docx)) · FSLogix Configuration Guide ([PDF](handouts/FSLogix_Configuration_Guide.pdf), [Word](handouts/FSLogix_Configuration_Guide.docx)) · Identity Reference Architecture ([PDF](handouts/Identity_Reference_Architecture.pdf), [Word](handouts/Identity_Reference_Architecture.docx)) · Platform Comparison ([PDF](handouts/Platform_Comparison.pdf), [Word](handouts/Platform_Comparison.docx)) · Q A Resources ([PDF](handouts/Q_A_Resources.pdf), [Word](handouts/Q_A_Resources.docx)).
3. Read [automation/README.md](automation/README.md) for the run order, configuration and tests of the deployment automation.

## What is in this repository

| Path | What it holds |
|---|---|
| `presentation/AVD_Anywhere_NIC2026.pptx` | The deck |
| `handouts/` | Each handout as PDF and Word (`.pdf`, `.docx`) with its Markdown source: `Identity_Reference_Architecture.md`, `Identity_Three_Paths.png`, `FSLogix_Configuration_Guide.md`, `Deployment_Checklist.md`, `Platform_Comparison.md`, `Q_A_Resources.md` |
| `follow-along/` | The attendee guide: `AVD_Anywhere_Follow_Along_Guide.pdf`, `AVD_Anywhere_Follow_Along_Guide.docx` and `README.md` (Markdown) |
| `follow-along-site/` | Source of the follow-along site |
| `automation/shared/` | The `NIC26.Automation` PowerShell module (config loader, naming, converters, Key Vault resolver), JSON Schemas and example environment files |
| `automation/landing-zones/avd/` | Spoke network, private DNS resolver, FSLogix storage, monitoring configuration, Entra groups and SSO scripts |
| `automation/avd/control-plane/` | Workspace, host pools, application groups and scaling plan |
| `automation/avd/fslogix/` | Share permissions, host settings and `redirections.xml` |
| `automation/avd/images/` | Azure Image Builder for Azure and Azure Local; Packer for Hyper-V (template passes `packer validate`; the lab hosts use the marketplace image); Packer for vSphere and Nutanix AHV (reference templates, not run) |
| `automation/avd/session-hosts-azure/`, `session-hosts-azure-local/`, `session-hosts-hybrid/` | Session hosts per deployment model; the hybrid one builds Hyper-V VMs and installs the Arc agent and CloudDeviceExtension |
| `automation/demo/` | The helpers the follow-along guide uses: state, routing, portability, failure and smoke test |

Bicep and Terraform are kept in parity; PowerShell orchestrates.

## What is tested and what is not

The code is tested with Pester (using mocks), by compiling the Bicep and by validating the Terraform. It has not yet been run end to end against a tenant from this repository: treat the first deployment as a test and use a non-production subscription. The vSphere and Nutanix Packer templates are references that have not been run. Everything is variable-driven, and the example files hold neutral placeholder values that you replace with your own.

## Prerequisites

- PowerShell 7.4 or later, Az PowerShell, Azure CLI with Bicep, Terraform 1.9 or later, Pester 5.5 or later
- An Azure subscription
- For AVD Hybrid, a Windows Server Hyper-V host

## Security

Secrets never go in files; use Key Vault references only. Report a suspected vulnerability or leaked secret privately through the repository's Security tab (see [SECURITY.md](SECURITY.md)), and never in a public issue.

## License

MIT. See [LICENSE](LICENSE).

## Feedback

Open an issue for content questions.
