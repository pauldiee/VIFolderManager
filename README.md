# VIFolderManager

A PowerShell utility to export and import vCenter inventory folder structures (VM, Host, Datastore and Network folders), including which objects sit in which folder and the permissions set on each folder. Useful for backing up the folder layout, rebuilding it on a new vCenter, and putting migrated VMs back into their folders.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VIFolderManager.ps1` | 1.6.0 | Export / import vCenter folder trees. Lab-tested on VCF 9.1.1 and 9.0.2, and from vCenter 8.0 U3 to 9.1.1 |
| `New-VIFolderPlacementSheet.ps1` | 0.1.1 | Turns the target placement list into an HTML page for the operator who picks destination folders in HCX (offline, no vCenter). Lab-tested with a target list from VCF 9.0.2 |
| `tests/New-VIFolderTestSet.ps1` | 1.1.1 | Builds, scrambles and removes a throwaway test set in a **lab** vCenter |
| `tests/New-VIFolderScaleSet.ps1` | 0.2.0 | Builds, scrambles and removes a large folder set (default 5000 folders, 500 permissions, optional dummy VMs) in a **lab** vCenter |

> **Status: lab-tested.** VIFolderManager has been lab-tested on VCF 9.1.1 and 9.0.2 management vCenters only. It has not yet been used in a production migration. Exporting from a vCenter 8.0 U3 source into 9.1.1 has been lab-tested (folders and permissions, on a vCenter 8 without hosts, so no VM moves); a 7.x source has not. Try it in a lab first, always run an import with `-DryRun` before the real one, and check the log. Use it at your own risk; feedback and issues are welcome.

---

## How it works

The script connects to a vCenter, then runs one of two modes. Pass `-Mode Export|Import`, or leave it out to pick from a menu. Pass `-FolderType VM,Host,Datastore,Network` (any combination), or leave it out to pick from a menu. Every picker accepts single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel` (or `exit`, `quit`, `q`). The datacenter picker and the export-file picker also filter by name: a wildcard (`*DC01*`) or `/text` for a substring narrows and renumbers the list, `reset` clears it, `list` shows everything; above 50 items the picker asks for a filter instead of printing the whole list. Every action is logged to the console and a timestamped log file. Long steps show a progress bar with "n of N: item", the percentage and the time left; it disappears when the step ends.

**Backup directory.** Without `-BackupDirectory`, an interactive run asks for it right after the mode: **Enter** keeps the default `Backups\` next to the script, **B** opens the Windows folder browser (only where a GUI is available), or type a path. Import shows how many exports the folder holds and asks again when it holds none. An unattended run (`-Datacenter` on Export, `-ExportFile` on Import) doesn't ask.

**Failures stand out.** A datacenter that fails to export, a folder that can't be created, an object that can't be moved and a permission that can't be set are logged in red as `FAILED …`, with vCenter's own message. Each summary line is red when something failed, yellow when something was only skipped (an ambiguous name, a role missing on the target), green otherwise, and is followed by the list of failures. Objects that are not in the target yet don't colour the line: during a migration that's normal.

### Filtering a picker

The filter works in the datacenter picker and the export-file picker. While a filter is on, the prompt shows it, for example `Your selection (filter: /DC01, 3 shown)`.

| To | Type |
|---|---|
| Narrow the list | A wildcard (`*DC01*`) or `/text` for a substring |
| Change the filter | The new filter straight away; it searches the full list again, not within the previous filter |
| Clear the filter | `reset`, or just Enter |
| See everything in the current list | `list` |

The list is renumbered after every filter and after clearing it, so pick the number from the list shown just above the prompt. `all` takes what the filter shows. A filter that matches nothing leaves the list as it was.


### Export

1. Pick one or more datacenters and the folder types (or pass `-Datacenter`, names or wildcards, and `-FolderType`).
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

Top-level folders that vCenter, the Supervisor or NSX create and manage themselves are skipped, including everything below them. Pass `-IncludeSystemFolders` to export them anyway.

| Folder type | Skipped system folders |
|---|---|
| VM | `vCLS`, `Namespaces` (Supervisor: vSphere Pods, VKS nodes) |
| Network | `NSX Managed Folders`, `Virtual Private Clouds` |

### Import

1. Pick an export file, the target datacenter (the one with the same name is marked) and the folder types (or pass `-ExportFile`, `-Datacenter` and `-FolderType`; when a wildcard in `-ExportFile` matches several files, the newest is used and logged).
2. Choose whether to **move objects** and whether to **re-apply permissions** (or pass `-MoveObjects` / `-ApplyPermissions`, with `:$false` to skip the question).
3. Confirm. With `-DryRun` nothing is changed and the log shows what would happen. An import with every choice passed as a parameter (`-ExportFile`, `-Datacenter`, `-FolderType`, `-MoveObjects`, `-ApplyPermissions`) runs without this question.

What Import does, per folder type:

- **Folders:** existing folders with the same path are reused, missing ones are created. Nothing is renamed or removed.
- **Objects (optional):** an object in the target datacenter with the same type and name as in the export is moved into its exported folder. Objects that are not in the target are counted and listed in the log file only, so you can import a full export after migrating part of the VMs. If a name occurs more than once in the target, the object counts as in place when one of them already sits in the exported folder; otherwise it is skipped. VMs inside a vApp and datastores inside a datastore cluster are not moved.
- **Permissions (optional):** roles are matched by **name**. Custom roles must exist on the target first; use [VIRoleManager](https://github.com/pauldiee/VIRoleManager) to copy them. Principals must be resolvable by the target vCenter's identity sources. Permissions on the hidden root folder of a datacenter (`vm`, `host`, `datastore`, `network`) are not re-applied, because vCenter refuses that ("Operation not allowed on sub-entity"); they are listed in the log file. On VCF these are Supervisor service accounts (`wcp-*`). A permission that is already present is left alone; one for the same principal with a different role is replaced, because vCenter allows one permission per principal per object.

There is deliberately **no Delete mode**: destroying a vSphere folder also destroys everything inside it, VMs included.

### Placement lists and the HCX destination folder

From 1.5.0 the export holds the vCenter ID of every folder and object (`Id`, for example `group-v4` and `vm-17`), and every object the ID of its folder (`FolderId`). Import still matches by type and name, so these IDs change nothing there; older exports without IDs import as before.

Add `-Csv` to get the same as a list you can open in Excel:

| Mode | File | One row per object |
|---|---|---|
| Export | `Folders_<datacenter>_<timestamp>_placement.csv` | `FolderType`, `Path`, `FolderId`, `ObjectType`, `Name`, `Id` (source vCenter) |
| Import | `<export>_target-<datacenter>.csv` | `FolderType`, `ObjectType`, `Name`, `SourceId`, `Path`, `TargetFolderId` (**target** vCenter), `Note` |

The import list is the one for an HCX migration: it tells you per VM which folder it belongs in on the new vCenter, and that folder's ID there. Run the import **before** the wave with `-MoveObjects:$false`, so the folders exist on the target and have an ID; in a dry run, folders that don't exist yet are listed with *"created on a real run"* and no ID.

```powershell
.\Invoke-VIFolderManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FolderType VM -MoveObjects:$false -ApplyPermissions:$false -Csv
```

In HCX, pick that folder as the destination folder of the VM in the Mobility Group. With HCX PowerCLI, `New-HCXMigration -Folder` takes an HCX folder container: `Get-HCXContainer -Type Folder -Site <destination>` lists them by name (two folders with the same name are ambiguous), and `Get-HCXContainer -Uid` picks one by its HCX ID. Whether that HCX ID equals the vCenter folder ID in `TargetFolderId` is **not verified** yet; compare them once with `Get-HCXContainer -Type Folder -Site <destination> | Select-Object Name, Uid` before you script on it.

After the wave, the same import with `-MoveObjects` puts any VM that landed elsewhere into its folder.

#### Placement sheet for the HCX operator

When the operator picks the destination folder per VM by hand, a CSV next to the HCX screen is awkward. `New-VIFolderPlacementSheet.ps1` turns the target list into one HTML page (`<list>_sheet.html`, next to the list) that opens offline in any browser:

- **Header:** the target datacenter, the time the list was written (so the operator sees how fresh it is), the three views and a light/dark switch (it follows the system until you use it). The header stays in view while you scroll.
- **Search** on VM or folder name; it filters every view.
- **Per folder:** one bar per destination folder with its path below the target datacenter (`Prod › Web`, the folder itself in bold), its VM count and its folder ID on the target, and its VMs underneath. Click a bar to fold it; **Collapse all** / **Expand all** does them all, and a list of more than 30 folders starts folded. A VM name that occurs more than once is marked red. One mobility group per destination folder keeps the picking simple.
- **Per VM:** every VM A-Z with its destination folder and folder ID.
- **Attention:** folders without an ID on the target (not created yet, or the list came from a dry run), folder names that occur in more than one path, VM names that occur more than once, and VMs in the datacenter root.
- **Print / PDF** prints every view, with folded folders opened, on a white background.

The page uses the same ITQ house style as the [VIExportViewer](https://github.com/pauldiee/VIExportViewer) report and loads nothing from the internet.

```powershell
# On the target vCenter, right before the operator starts: create the folders and write the target list
.\Invoke-VIFolderManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FolderType VM -MoveObjects:$false -ApplyPermissions:$false -Csv
# Turn the newest target list in Backups\ into the page (or pass -Path <list>)
.\New-VIFolderPlacementSheet.ps1
```

It shows VM folders only by default; `-FolderType` adds other types. It needs PowerShell 5.1 or 7 and no PowerCLI. The page holds VM and folder names: keep it where you keep the export.

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 7.4+ | VCF.PowerCLI 9.x needs PowerShell 7 ([KB 409981](https://knowledge.broadcom.com/external/article/409981)); Windows ships 5.1, so start the script from `pwsh` |
| VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+ | `Install-Module -Name VCF.PowerCLI -Scope CurrentUser` |
| Network access | HTTPS to vCenter Server |
| Privileges | Export: read access to the inventory and its permissions. Import: create folders, move the objects, and modify permissions |

Setting up PowerShell 7 and VCF.PowerCLI on a jump host, with or without internet access, and keeping one PowerCLI version per host: [Jump Host: PowerShell 7 and VCF PowerCLI](https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/).

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

# Unattended export of every datacenter whose name starts with DC
.\Invoke-VIFolderManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -Datacenter 'DC*' -FolderType VM,Host,Datastore,Network -BackupDirectory D:\migration\folders

# Unattended import after a migration wave: newest export of DC01, move the VMs, no permissions
.\Invoke-VIFolderManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -ExportFile 'Folders_DC01_*' -Datacenter DC01 -FolderType VM -MoveObjects -ApplyPermissions:$false -BackupDirectory D:\migration\folders
```

From a scheduled task or another script, start it with `pwsh -Command` rather than `pwsh -File`: with `-File`, `-FolderType VM,Host` arrives as one string and is refused.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Finished without failures (skips are allowed) |
| 1 | Something failed: see the red `FAILED` lines and the summary, or the script could not start (PowerCLI, connection, unknown datacenter, no matching export file) |
| 2 | Stopped because a prompt needed console input in an unattended run; the message names the parameters to pass. Save the credential first with one interactive run |

## Parameters

| Parameter | Description |
|---|---|
| `-vCenterServer` | FQDN or IP of the vCenter Server (required) |
| `-Mode` | `Export` or `Import`; menu when omitted |
| `-IncludeSystemFolders` | Export: also export the system folders listed above |
| `-Csv` | Export: placement list with folder and object IDs. Import: target placement list with the folder ID on the target vCenter (see Placement lists) |
| `-FolderType` | `VM`, `Host`, `Datastore`, `Network` (one or more); menu when omitted |
| `-BackupDirectory` | Where JSON files are written and read. Default: `Backups\` next to the script. Asked after the mode when omitted (Enter, B for the folder browser, or a path), except in an unattended run |
| `-Datacenter` | Export: datacenter names or wildcards instead of the picker. Import: the exact target datacenter. An unknown name stops the script with the list |
| `-ExportFile` | Import: export file name or wildcard (`.json` optional) instead of the picker; the newest match wins |
| `-LogDirectory` | Default: `Logs\` next to the script |
| `-MoveObjects` | Import: move same-named objects into their folder; asked when omitted |
| `-ApplyPermissions` | Import: re-apply folder permissions; asked when omitted |
| `-Report` | Export: also write an HTML report next to the JSON (see Visual report) |
| `-DryRun` | Import: show what would change, change nothing |
| `-CredentialPath` | Default: `<vCenterServer>.cred` next to the script |
| `-ResetCredentials` | Prompt for new credentials |
| `-SkipCertificateValidation` | Accept self-signed certificates (lab use) |

## Visual report

Add `-Report` to an export to get an HTML file next to the JSON (same name, `.html`). It shows what the export holds: the folder tree per folder type, which objects sit in which folder, and the permissions on each folder. It's the [VI Export Viewer](https://github.com/pauldiee/VIExportViewer) (`report/viewer.html`) with the export embedded: one file that opens offline in any browser, loads nothing from the internet and uploads nothing. **Print / PDF** gives a clean printout for the migration file. The look follows the ITQ house style, without logos.

Drop a second export on the open report (for example the same export from the target vCenter) and switch to **Compare**: every item is marked as missing on the target, different, only on the target, or the same. The older export is the source; **Swap** turns it round.

The report holds the full export, names included. Keep it where you keep the export files; `Backups/` is git-ignored.

## Testing in a lab

`tests/New-VIFolderTestSet.ps1` builds a test set in a **lab** vCenter (`-Mode Create`): a `VIFM-Test` folder tree in all four folder types, tiny dummy VMs and a template (no disk, no NIC, never powered on), a same-named VM pair in two folders, optionally an empty second datacenter (`-WithSecondDatacenter`) and test permissions (`-TestPrincipal`, a dedicated SSO test user you create first). `-Mode Scramble` moves the VMs out and removes folders and permissions, so an Import has something to restore; `-Mode Remove` cleans up. It only touches objects it created (marker note, `VIFM-` names).

Suggested run: Create, Export, Scramble, Import `-DryRun`, Import, Import again (everything should be "already present"), compare a new export with the first one, Remove.

`tests/New-VIFolderScaleSet.ps1` builds a large set for scale tests: a `VIFM-S` tree in all four folder types (default 5000 folders, up to six levels, names that repeat across branches), 500 folder permissions for `-TestPrincipal` with the built-in ReadOnly role, and with `-WithTargetDatacenter` an empty datacenter `VIFM-S-DC2` to import into. `-VMCount` adds that many dummy VMs (no disk, no NIC, never powered on) spread over the VM tree, and `-Mode Scramble` moves them to the root VM folder, so an import with `-MoveObjects` can be tested at scale. `-Mode Remove` deletes the VMs first, then the trees. Test cases and measured durations are in `tests/TESTPLAN.md`.

Scale (VCF 9.1.1, 2026-11-19, 5000 folders and 500 permissions): export 3 s, import `-DryRun` 6 s, a real import into an empty datacenter 4:46 (5008 folders and 500 permissions, identical to the source).

On a vCenter without hosts, `-FoldersOnly` builds the folders and permissions without the dummy VMs. The tree also has a second `Web` under `Test` (same name as `Prod\Web`) and a folder with non-ASCII characters (`Café Ø ü`).

Lab findings (vCenter 8.0.3 build 25600417 to 9.1.1 build 25784172, 2026-11-16, clean `pwsh -NoProfile`, `-FoldersOnly`, import into an empty datacenter):

- 20 of 20 folders, including nesting, the two `Web` folders, `Spaces & Specials (1)` and `Café Ø ü`.
- With `-ApplyPermissions`: 3 of 3 permissions for the SSO test user, with the same role and propagation as the source (the role existed on the target).
- vCenter 9.1.1 creates a `Virtual Private Clouds` network folder in every new datacenter; it's on the system-folder list, so an export from 9.1.1 skips it.

Lab findings (Holodeck, VCF 9.1.1 and 9.0.2, 2026-11-12):

- Use a dedicated test user for `-TestPrincipal`, never a group your admin account is in: a permission set directly on a folder overrides inherited ones for that principal.
- On VCF 9.1.1 a custom role gets an extra permission on the vCenter root for a principal `VSPHERE.LOCAL\vcf_reserved_<n>`, so `-Mode Remove` may report the test role as still in use. The script leaves that permission alone. Deleting the role yourself does work (lab-verified 2026-11-19, see VIRoleManager's README): the vSphere Client's *Delete role* with *remove permissions*, or `RemoveAuthorizationRole(<roleId>, $false)`, removes the role together with its own `vcf_reserved_<roleId>` permission.
- `VMware.vSphere.SsoAdmin` 1.4.0 could not connect from PowerShell 7.6 with VCF.PowerCLI 9.1.1 installed (missing `VMware.System.Private.ServiceModel` type), so the test user was created in the vSphere Client.

## Credentials

Saved with `Export-Clixml` as `<vCenterServer>.cred` next to the script. On Windows the password is DPAPI-encrypted for the current user; on Linux and macOS it is **not** encrypted. `*.cred` files are git-ignored.

## Author

Paul van Dieen – [hollebollevsan.nl](https://www.hollebollevsan.nl)
