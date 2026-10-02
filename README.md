# AVD Anywhere: Azure Virtual Desktop on Azure, Azure Local, and AVD Hybrid Platforms

## Session Overview

**Conference:** NIC 2026  
**Date:** October 14, 2026  
**Time:** 1:20 PM (W Europe Time)  
**Duration:** 60 minutes  
**Level:** 400 (Expert)  
**Location:** Amsterdam

Azure Virtual Desktop is no longer a single-deployment story. This Level 400 session walks through all three deployment models and the engineering decisions that enable one identity, one profile pattern, and one operational story to span them all:

- **Azure** - For elasticity and scale
- **Azure Local** - For data gravity, regulation, or latency
- **AVD Hybrid** - Running on Windows Server Hyper-V, VMware vSphere, or Nutanix AHV (no validated Azure Local hardware required)

## What You'll Learn

This session covers the complete architecture and operational patterns for running Azure Virtual Desktop across three distinct deployment models:

### AVD on Azure
- Session host architecture and configuration
- Azure Files integration with Entra ID Kerberos for FSLogix
- Azure Compute Gallery with Image Builder for image management
- AVD Insights and telemetry
- Data collection rules for cost-conscious monitoring

### AVD on Azure Local
- Session hosts as Azure Local VMs
- Arc Resource Bridge and AKS dependencies
- Azure Image Builder targeting Azure Local resources
- FSLogix profile storage on cluster CSV vs. SMB scale-out file servers
- GPU placement with DDA passthrough on cluster

### AVD Hybrid on Third-Party Platforms
- AVD agent deployment on Hyper-V, vSphere, and Nutanix AHV
- Image management without Azure Image Builder (using Packer and platform-native tooling)
- FSLogix profile placement on platform-native storage (vSAN, Nutanix Files, SMB scale-out, third-party NAS)
- Identity flow from on-prem session hosts back to Entra ID
- Network connectivity from on-prem hosts to AVD control plane in Azure
- GPU passthrough patterns specific to each hypervisor
- Arc-enabling session hosts for monitoring and Azure Update Manager

### Cross-Cutting Patterns
- One identity model spanning all three deployment types
- FSLogix profile structures designed for portability across platforms
- Image strategy: Azure Image Builder for Azure/Azure Local + Packer for AVD Hybrid, all driven from the same repository
- Unified Azure Monitor and Log Analytics layer via Arc for session hosts everywhere

## Live Demo

Three host pools in a single AVD workspace covering all three deployment models:
- User routed to appropriate host pool based on deployment model
- Profile portability demonstration between deployment models
- Forced session host failure with automatic recovery demonstration

## Attendee Deliverables

You'll leave with production-ready artifacts to take home:

- ✅ **Azure Image Builder templates** - Ready-to-use for Azure and Azure Local deployments
- ✅ **Packer templates** - For Hyper-V, VMware vSphere, and Nutanix AHV
- ✅ **Bicep infrastructure code** - Complete workspace and host pool deployment
- ✅ **FSLogix configuration profiles** - Portable across all deployment models
- ✅ **Arc onboarding scripts** - PowerShell automation for AVD Hybrid session hosts
- ✅ **Identity reference architecture diagram** - Design patterns for multi-model deployment
- ✅ **Complete GitHub repository** - Full deployment code, documentation, and scripts

## Repository Contents

### `/PRESENTATION`
- NIC 2026 PowerPoint presentation (using official NIC template)
- Speaker notes and slide references

### `/HANDOUTS`
- **Identity_Reference_Architecture.md** - Detailed identity design patterns for all three models
- **FSLogix_Configuration_Guide.md** - Comprehensive FSLogix setup and best practices
- **Deployment_Checklist.md** - Step-by-step deployment validation checklist
- **Q&A_Resources.md** - Common questions and detailed answers with links to documentation

### `/src/bicep`
- `avd-azure.bicep` - Azure deployment template
- `avd-azurelocal.bicep` - Azure Local deployment template
- `workspace.bicep` - Workspace with multiple host pools

### `/src/packer`
- `avd-hyperv.pkr.hcl` - Packer configuration for Hyper-V
- `avd-vsphere.pkr.hcl` - Packer configuration for VMware vSphere
- `avd-nutanix.pkr.hcl` - Packer configuration for Nutanix AHV

### `/src/arm-templates/image-builder`
- Azure Image Builder configuration for Azure and Azure Local

### `/src/scripts`
- **arc-onboarding/** - Enable-ArcVM.ps1 for hybrid session hosts
- **fslogix/** - Configuration scripts and FSLogix profiles XML

### `/src/monitoring`
- `dcr-avd.json` - Azure Monitor Data Collection Rules for cost-conscious logging

## Getting Started

1. **Review the Identity Reference Architecture** - Start with `HANDOUTS/Identity_Reference_Architecture.md`
2. **Choose your deployment model** - Pick the Bicep or Packer templates that match your environment
3. **Follow the Deployment Checklist** - Use `HANDOUTS/Deployment_Checklist.md` for step-by-step validation
4. **Customize for your environment** - Update Bicep parameters and configuration files for your specific needs
5. **Review Q&A Resources** - Check `HANDOUTS/Q&A_Resources.md` for answers to common deployment questions

## Prerequisites

- Basic understanding of Azure Virtual Desktop concepts
- Familiarity with Bicep (for Azure deployments) or Packer (for hybrid)
- Access to Azure or appropriate hybrid platform
- PowerShell 7+ for scripting

## Support & Questions

For questions about the content:
- Check the Q&A Resources in HANDOUTS
- Review the Deployment Checklist for common issues
- Refer to official Microsoft documentation links in the handouts

## License

These materials are provided as-is for educational purposes.

## Speaker

Presented at NIC 2026

---

**Questions? Issues? Feedback?** Open an issue in this repository.
