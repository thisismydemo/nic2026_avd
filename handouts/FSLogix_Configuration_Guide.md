# Azure Virtual Desktop: FSLogix Configuration Guide

This handout summarizes FSLogix profile container configuration choices for the three Azure Virtual Desktop deployment models.

**Status:** prepared 2026-10-06 against Microsoft Learn; check the FSLogix and Azure Files documentation for your versions before you deploy.

## What a profile container is

FSLogix stores the whole user profile in a VHD or VHDX file on an SMB share. The container is attached when the user signs in and detached when the user signs out, so pooled session hosts stay stateless. With the default `ProfileType` of `0`, one connection mounts the container at a time.

Antivirus exclusions for FSLogix are a prerequisite; see the FSLogix prerequisites page for them.

## Where the container lives in each deployment model

| Model | Profile storage | Note |
|---|---|---|
| Azure | Azure Files, with Microsoft Entra Kerberos, AD DS or Microsoft Entra Domain Services identity | |
| Azure Local | An SMB service: a file server VM or Scale-Out File Server on the cluster, or Azure Files | FSLogix needs an SMB service, not a cluster shared volume path. |
| Azure Virtual Desktop Hybrid | Any SMB path: Azure Files with Microsoft Entra Kerberos, or on-premises SMB with AD DS Kerberos | |

Microsoft Learn notes that keeping profiles on the Azure Local instance's own storage gives low latency and a simpler design, but it may limit scalability compared with a separate file share, it suits smaller deployments, and it raises the capacity and performance demand on the cluster. All-flash storage (SSD or NVMe) is preferable to hybrid storage for this approach.

## Standard configuration

The registry key is `HKEY_LOCAL_MACHINE\SOFTWARE\FSLogix\Profiles`.

| Name | Type | Value | Purpose |
|---|---|---:|---|
| `Enabled` | DWORD | `1` | Required. |
| `DeleteLocalProfileWhenVHDShouldApply` | DWORD | `1` | Recommended, so users do not use local profiles and lose data. |
| `FlipFlopProfileDirectoryName` | DWORD | `1` | Recommended; makes container folders easier to browse. |
| `LockedRetryCount` | DWORD | `3` | Recommended; faster failure. |
| `LockedRetryInterval` | DWORD | `15` | Recommended; faster failure. |
| `ProfileType` | DWORD | `0` | Default; single connection. |
| `ReAttachIntervalSeconds` | DWORD | `15` | Recommended; faster failure. |
| `ReAttachRetryCount` | DWORD | `3` | Recommended; faster failure. |
| `SizeInMBs` | DWORD | `30000` | Default container size. |
| `VHDLocations` | MULTI_SZ or REG_SZ | SMB path | The profile container location. |
| `VolumeType` | REG_SZ | `VHDX` | Recommended; supports a larger size and has fewer corruption cases than VHD. |

Notes:

- Before you enable `DeleteLocalProfileWhenVHDShouldApply`, make sure users saved their data outside the local profile. Existing local profiles are not removed automatically without it.
- Changing `FlipFlopProfileDirectoryName` in an existing environment can give users new profiles.
- Example path for `VHDLocations`: `\\<storage-account-name>.file.core.windows.net\<share-name>`.
- This standard configuration has one VHD location, one profile container, no Office Data and Files Container, no concurrent connections and no custom redirections. Object-specific `VHDLocations` (per user or group SID) exist for advanced layouts.

Example PowerShell for the Profiles key:

```powershell
$key = 'HKLM:\SOFTWARE\FSLogix\Profiles'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name Enabled -PropertyType DWord -Value 1 -Force
New-ItemProperty -Path $key -Name VHDLocations -PropertyType String -Value '\\<storage-account-name>.file.core.windows.net\<share-name>' -Force
New-ItemProperty -Path $key -Name VolumeType -PropertyType String -Value 'VHDX' -Force
New-ItemProperty -Path $key -Name FlipFlopProfileDirectoryName -PropertyType DWord -Value 1 -Force
New-ItemProperty -Path $key -Name DeleteLocalProfileWhenVHDShouldApply -PropertyType DWord -Value 1 -Force
```

## Storage permissions

SMB permissions use NTFS ACLs: only the user (CREATOR OWNER) should have access to their profile folder, and administrators need Full Control.

| Principal | Permission | Applies to |
|---|---|---|
| CREATOR OWNER | Modify | Subfolders and files only |
| Administrative group | Full Control | This folder, subfolders and files |
| Users group | Modify | This folder only, so users can create their folder |

For Azure Files:

- Assign share-level permissions. The recommended default share-level permission is Storage File Data SMB Share Contributor for all authenticated identities.
- To set Windows ACLs, use a user or group with the Storage File Data SMB Share Elevated Contributor role, or mount the share with the storage account key first.
- Apply the ACLs with `icacls` or File Explorer (File Explorer cannot be used for cloud-only identities), or let FSLogix set them when it creates a folder, with the `SIDDirSDDL` setting.

Example `icacls` pattern with placeholders:

```text
icacls \\<server>\<share> /inheritance:r
icacls \\<server>\<share> /grant:r "CREATOR OWNER":(OI)(CI)(IO)(M)
icacls \\<server>\<share> /grant:r "<ADMIN-GROUP>":(OI)(CI)(F)
icacls \\<server>\<share> /grant:r "<USERS-GROUP>":(M)
```

## Authentication to Azure Files

The Identity Reference Architecture handout has the detail. In short:

- With Microsoft Entra Kerberos, session hosts need no domain controller connectivity.
- Enable it on the storage account, grant admin consent to the generated application, and exclude that application from MFA Conditional Access policies.
- Set `CloudKerberosTicketRetrievalEnabled` to `1` on the clients (Intune settings catalog on multi-session, Group Policy or registry), and `LoadCredKeyFromProfile` to `1` under the `AzureADAccount` policy key.
- Cloud-only identities also need the `kdc_enable_cloud_group_sids` tag in the application manifest.
- A storage account uses only one identity source.

Warnings from Microsoft Learn:

- A Windows update in April 2026 changes the default Kerberos encryption type from RC4 to AES-SHA1. File shares that host FSLogix containers must be upgraded first.
- If Microsoft Entra Kerberos was enabled through the old manual preview steps, the storage account service principal password expires every six months, and users then cannot get tickets.

## High availability with Cloud Cache

Cloud Cache is a design choice; the standard configuration does not need it.

- Use `CCDLocations` instead of `VHDLocations`.
- For high availability, use at least two storage providers in the same region as the VMs. For disaster recovery, use providers in different regions.
- Related settings: `ClearCacheOnLogoff` = `1`, and `HealthyProvidersRequiredForRegister` = `1`, which prevents a local cache when a provider is unhealthy.

Example `CCDLocations` string:

```text
type=smb,name="PRIMARY",connectionString=\\<storage-account-name-1>.file.core.windows.net\<share-name>;type=smb,name="SECONDARY",connectionString=\\<storage-account-name-2>.file.core.windows.net\<share-name>
```

## One profile across three deployment models

- Use the same `VHDLocations` pattern, the same container settings and the same user identity in each model. The user then gets the same container.
- With `ProfileType` set to `0`, one connection uses the container at a time, so this supports sequential use across models.
- Roaming a profile between models is not replication, and replication is not recovery.
- Keep the SMB path reachable from every model (network and DNS), and test sign-in on each model.

## Sizing and growth

- The default container size is `30000` MB (`SizeInMBs`). Raising `SizeInMBs` enlarges the container when a larger value is used, and it affects all users with dynamic disks.
- Deleting content from a container lets it compact at sign-out. Compaction needs FSLogix 2210 (`2.9.8361.52623`) or later.
- Plan the share size as users times expected container size, plus growth, and keep it inside the limits of your storage. Confirm those limits with the storage provider; do not assume a per-user number.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| User gets a temporary or local profile | `Enabled` is not `1`, `VHDLocations` is unreachable, or permissions are wrong | Check the registry values, test the UNC path from the host, and check the share-level role and ACLs. |
| Container full or low disk warning | `SizeInMBs` reached | Raise `SizeInMBs`, then clean up and let the container compact. |
| Local profile exists and the container is ignored | Local profiles are not removed automatically | Enable `DeleteLocalProfileWhenVHDShouldApply` after users have saved data elsewhere. |
| Sign-in to the share fails with System error 1327 | The storage application is not excluded from MFA | Exclude the application. |
| No ticket for the storage account | `CloudKerberosTicketRetrievalEnabled` is missing, or admin consent was not granted | Set the client setting and check consent. |
| Tickets stop after about six months | Manual preview setup; the service principal password expired | Follow the Microsoft Learn mitigation. |
| Container locked | The previous session did not detach | The lock retry settings shorten the wait; check for a second session. |

## Checklist

- [ ] The share is created in the right region.
- [ ] The identity source is enabled once.
- [ ] Share-level permissions are assigned.
- [ ] ACLs are applied.
- [ ] Antivirus exclusions are in place.
- [ ] Registry values are deployed by policy or image.
- [ ] Kerberos client settings are deployed.
- [ ] The Cloud Cache decision is recorded.
- [ ] Sign-in is tested on every deployment model.
- [ ] A growth and size plan is recorded.
