@{
    # Microsoft first-party application IDs used by the Entra tenant scripts (public constants, not tenant values).
    # Source: Learn "Enforce MFA for AVD using Conditional Access" and "Configure single sign-on for AVD".
    AzureVirtualDesktop              = '9cdead84-a844-4324-93f2-b2e6bb768d07'
    WindowsCloudLogin                = '270efc09-cd0d-444b-a71f-39af4910ec45'
    # Never target these two in the MFA policies.
    AzureVirtualDesktopArmProvider   = '50e95039-b200-4007-bc97-8d5790743a63'
    Windows365                       = '0af06dc6-e4b5-4f28-818e-e78e62d137a5'
}
