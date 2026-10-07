# avd-images-azure-local

Imports an AIB-built gallery image into Azure Local as an Azure Local VM image. Run it **after** `avd-images-azure` has built the `azl` template.

Authored by gpt-6-sol via the HCS Foundry gateway; review is recorded in `design/shared/verification-log.md`.

`scripts/Import-AzureLocalImage.ps1` (plan without `-Execute`, then `-Execute`):

1. Refuses when the Azure Local image already exists (never replaced).
2. Creates a managed disk from the gallery image version in the AVD subscription and grants a short read-only SAS.
3. Hands the SAS only to `az stack-hci-vm image create --image-path <SAS>`; CLI output and error text are never surfaced, so the SAS cannot reach a log.
4. **Always** revokes the access and deletes the temporary disk (also when creation fails). A leftover managed disk costs money.
5. Returns the Azure Local image resource id.

Rules: the image name must match `^img-[a-z0-9-]+$` and must **not contain `windows`** (Azure rejects such names). Azure Local can also import from a blob SAS or a local VHDX; only the gallery-through-temporary-disk route is implemented here.

## Verify before the first run

- The `az` CLI with the `stack-hci-vm` extension is installed and signed in for both subscriptions.
- The custom location id, the optional storage path id, and the AVD-subscription resource group for the temporary disk are the real ones.
- After the import, confirm the image reaches `Available` on the cluster before creating VMs from it.

## Residuals

- `az stack-hci-vm image create --image-path <SAS>` takes the SAS on its command line (the documented usage). Process-creation auditing with command lines on the machine that runs the script would record it. The SAS is read-only, lives `-SasDurationSeconds` (default 3600; lower it) and is revoked in `finally`, but treat that log as sensitive.
- The temporary disk name must be unused: the script refuses a name that already exists, so it never touches a disk it did not create.
