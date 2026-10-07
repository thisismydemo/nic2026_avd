// Microsoft built-in role and policy definition ids (public constants, identical in every tenant — not environment values).
// This is the ONLY file in lz-avd that may contain GUIDs; tests/LzAvd.Secrets.Tests.ps1 allow-lists it by name.
// The Terraform track needs none of these: it resolves the same definitions by display name (data sources /
// role_definition_name). Test-AvdLandingZone.ps1 check "builtin-ids" verifies the display names live.
@export()
var builtInRoles = {
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  virtualMachineUserLogin: 'fb879df8-f326-4884-b1cf-06f3ad86be52' // Virtual Machine User Login
  virtualMachineAdministratorLogin: '1c0163c0-47e6-4577-8991-ea5c82e286e4' // Virtual Machine Administrator Login
  desktopVirtualizationContributor: '082f0a83-3be5-4ba1-904c-961cca79b387' // Desktop Virtualization Contributor
  desktopVirtualizationReader: '49a72310-ab8d-41df-bbb0-79b649203868' // Desktop Virtualization Reader
  azureConnectedMachineOnboarding: 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7' // Azure Connected Machine Onboarding
  tagContributor: '4a9ae827-6dc8-4573-8ac7-8239d42aa03f' // Tag Contributor
}

@export()
var builtInPolicies = {
  allowedLocations: 'e56962a6-4747-49cd-b67b-bf8b01975c4c' // Allowed locations
  requireTagOnResourceGroups: '96670d01-0a4d-4649-9c89-2d3abc0a5025' // Require a tag on resource groups
  inheritTagFromResourceGroupIfMissing: 'ea3f2387-9b95-492a-a190-fcdc54f7b070' // Inherit a tag from the resource group if missing
  storageAccountsDisablePublicNetworkAccess: 'b2982f36-99f2-4db5-8eff-283140c09693' // Storage accounts should disable public network access
  secureTransferToStorageAccounts: '404c3081-a854-4457-ae30-26a93ef643f9' // Secure transfer to storage accounts should be enabled
  networkInterfacesNoPublicIps: '83a86a26-fd1f-447c-b59d-e51f44264114' // Network interfaces should not have public IPs
}

@export()
var builtInDisplayNames = {
  roles: {
    reader: 'Reader'
    virtualMachineUserLogin: 'Virtual Machine User Login'
    virtualMachineAdministratorLogin: 'Virtual Machine Administrator Login'
    desktopVirtualizationContributor: 'Desktop Virtualization Contributor'
    desktopVirtualizationReader: 'Desktop Virtualization Reader'
    azureConnectedMachineOnboarding: 'Azure Connected Machine Onboarding'
    tagContributor: 'Tag Contributor'
  }
  policies: {
    allowedLocations: 'Allowed locations'
    requireTagOnResourceGroups: 'Require a tag on resource groups'
    inheritTagFromResourceGroupIfMissing: 'Inherit a tag from the resource group if missing'
    storageAccountsDisablePublicNetworkAccess: 'Storage accounts should disable public network access'
    secureTransferToStorageAccounts: 'Secure transfer to storage accounts should be enabled'
    networkInterfacesNoPublicIps: 'Network interfaces should not have public IPs'
  }
}
