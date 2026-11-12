# VIFolderManager

A PowerShell utility to export and import vCenter inventory folder structures (VM, Host, Datastore and Network folders), including which objects sit in which folder and the permissions set on each folder. Useful for backing up the folder layout, rebuilding it on a new vCenter, and putting migrated VMs back into their folders.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VIFolderManager.ps1` | 1.0.0 | Export / import vCenter folder trees. **Not yet tested against a vCenter.** |

---

## How it works

The script connects to a vCenter, then runs one of two modes. Pass `-Mode Export|Import`, or leave it out to pick from a menu. Pass `-FolderType VM,Host,Datastore,Network` (any combination), or leave it out to pick from a menu. Every picker accepts single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel`. Every action is logged to the console and a timestamped log file.

### Export

1. Pick one or more datacenters and the folder types.
2. For each datacenter, one JSON file (`Folders_<datacenter>_<timestamp>.json`) is written to the backup directory. It holds, per folder type:
   - every folder path, the hidden root folder included;
   - the objects in each folder (see the table below);
   - the permissions set **directly** on each folder (principal, group or user, role name, propagate). Inherited permissions are not exported.

| Folder type | Objects recorded |
|---|---|
| VM | Virtual machines and templates |
| Host | Clusters and standalone hosts |
| Datastore | Datastores and datastore clusters (datastores inside a datastore cluster stay with the cluster) |
| Network | Distributed switches (their port groups stay with the switch) |

The `vCLS` folder in the VM tree is skipped, because vCenter creates and manages it.

### Import

1. Pick an export file, the target datacenter (the one with the same name is marked) and the folder types.
2. Choose whether to **move objects** and whether to **re-apply permissions** (or pass `-MoveObjects` / `-ApplyPermissions`, with `:$false` to skip the question).
3. Confirm. With `-DryRun` nothing is changed and the log shows what would happen.

What Import does, per folder type:

- **Folders:** existing folders with the same path are reused, missing ones are created. Nothing is renamed or removed.
- **Objects (optional):** an object in the target datacenter with the same type and name as in the export is moved into its exported folder. Objects that are not in the target are counted and listed in the log file only, so you can import a full export after migrating part of the VMs. Objects whose name occurs more than once in the target are skipped. VMs inside a vApp and datastores inside a datastore cluster are not moved.
- **Permissions (optional):** roles are matched by **name**. Custom roles must exist on the target first; use [VIRoleManager](https://github.com/pauldiee/VIRoleManager) to copy them. Principals must be resolvable by the target vCenter's identity sources. A permission that is already present is left alone; one for the same principal with a different role is replaced, because vCenter allows one permission per principal per object.

There is deliberately **no Delete mode**: destroying a vSphere folder also destroys everything inside it, VMs included.

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Included with Windows 10 / Server 2016 and later |
| VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+ | `Install-Module -Name VCF.PowerCLI -Scope CurrentUser` |
| Network access | HTTPS to vCenter Server |
| Privileges | Export: read access to the inventory and its permissions. Import: create folders, move the objects, and modify permissions |

## Usage

```powershell
# Fully interactive
.\Invoke-VIFolderManager.ps1 -vCenterServer vc01.vcf.lab

# Export the VM and Host folder trees
.\Invoke-VIFolderManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -FolderType VM,Host

# Preview an import on another vCenter, including moves and permissions
.\Invoke-VIFolderManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -MoveObjects -ApplyPermissions -DryRun

# Recreate the folders only
.\Invoke-VIFolderManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -MoveObjects:$false -ApplyPermissions:$false
```

## Parameters

| Parameter | Description |
|---|---|
| `-vCenterServer` | FQDN or IP of the vCenter Server (required) |
| `-Mode` | `Export` or `Import`; menu when omitted |
| `-FolderType` | `VM`, `Host`, `Datastore`, `Network` (one or more); menu when omitted |
| `-BackupDirectory` | Where JSON files are written and read. Default: `Backups\` next to the script |
| `-LogDirectory` | Default: `Logs\` next to the script |
| `-MoveObjects` | Import: move same-named objects into their folder; asked when omitted |
| `-ApplyPermissions` | Import: re-apply folder permissions; asked when omitted |
| `-DryRun` | Import: show what would change, change nothing |
| `-CredentialPath` | Default: `<vCenterServer>.cred` next to the script |
| `-ResetCredentials` | Prompt for new credentials |
| `-SkipCertificateValidation` | Accept self-signed certificates (lab use) |

## Credentials

Saved with `Export-Clixml` as `<vCenterServer>.cred` next to the script. On Windows the password is DPAPI-encrypted for the current user; on Linux and macOS it is **not** encrypted. `*.cred` files are git-ignored.

## Author

Paul van Dieen – [hollebollevsan.nl](https://www.hollebollevsan.nl)
