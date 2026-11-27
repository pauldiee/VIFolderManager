# VIFolderManager test plan

How to test `Invoke-VIFolderManager.ps1` in a lab: which lab, which test set,
which cases, and what came out. Labs are named by code only; addresses live
outside this repository.

## Labs

| Code | What | Hosts | Role in the tests |
|---|---|---|---|
| **L8** | vCenter 8.0 U3, no hosts | none | Export source for vSphere 8 (`-FoldersOnly`) |
| **LA** | VCF 9.1.1 management vCenter | yes | Main target; scale tests |
| **LB** | VCF 9.0.2 management vCenter | yes | Second source/target (9.0.2 to 9.1.1) |

Use a dedicated SSO test user for `-TestPrincipal`, never a group your admin
account is in.

## Test sets

| Script | What it builds | Remove |
|---|---|---|
| `New-VIFolderTestSet.ps1` | Functional set: `VIFM-Test` tree in all four folder types, dummy VMs and a template, a same-named VM pair, `Web` twice, a non-ASCII folder name, optional permissions (`-TestPrincipal`) and an empty `VIFM-DC2` (`-WithSecondDatacenter`). `-FoldersOnly` on a vCenter without hosts. `-Mode Scramble` moves the VMs out and removes folders and permissions | `-Mode Remove` |
| `New-VIFolderScaleSet.ps1` | Scale set (0.2.0): `VIFM-S` trees with `-FolderCount` folders (default 5000: 60% VM, 10% Host, 15% Datastore, 15% Network; five children per folder, up to six levels, names repeat across branches), `-PermissionCount` ReadOnly permissions for `-TestPrincipal` (default 500, half propagating), and with `-WithTargetDatacenter` an empty `VIFM-S-DC2`; `-VMCount` dummy VMs spread over the VM tree, `-Mode Scramble` moves them to the root VM folder | `-Mode Remove` (marked VMs first, then trees and a DC2 that hold nothing but folders) |

## Test cases

### A. Functional (New-VIFolderTestSet.ps1)

| # | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| F1 | LA, LB | Create, Export, Scramble, Import `-DryRun`, Import, Import again, Export, compare with the first export, Remove | Folders, VM placement and permissions restored; second import "already present"; exports equal | 2026-11-12: run on LA and LB, findings in the README ("Lab findings"); a result per step was not recorded. Rerun and record here |
| F2 | L8 to LA | `-FoldersOnly` on L8, Export, Import into an empty datacenter on LA with `-ApplyPermissions` | 20 of 20 folders incl. both `Web` and `Café Ø ü`; 3 of 3 permissions | 2026-11-16: **pass** |
| F3 | LA | Export from 9.1.1 | `Virtual Private Clouds` network folder skipped as a system folder | 2026-11-16: **pass** |

### B. Scale (New-VIFolderScaleSet.ps1)

Create on LA: `-Mode Create -TestPrincipal <test user> -WithTargetDatacenter`
(about 4.5 minutes for 5000 folders and 500 permissions; a second Create run
that finds everything takes about 4 minutes).

| # | Steps | Expected | Result (LA, 2026-11-19) |
|---|---|---|---|
| S1 | Export all four types of the datacenter | Log line per type with the folder count; 3006 / 502 / 752 / 752 folders, 504 permissions on VM (500 + 4 Supervisor `wcp-*` on the hidden root) | 1.5.0: 2:11, VM tree silent for 78 s. **1.5.1: 3 s**, export identical to 1.5.0 |
| S2 | Import the export into the same datacenter, `-ApplyPermissions -DryRun` | 5008 folders and 500 permissions "already present", 16 root permissions skipped | 1.5.0: 29 s. **1.5.1: 6 s**, same counts |
| S3 | Real import into the empty `VIFM-S-DC2`, `-MoveObjects:$false -ApplyPermissions` | 5008 folders created, 500 permissions set, 0 failed | 1.5.1 before the parent-view cache: 7:01. **1.5.1: 4:46** |
| S4 | Export `VIFM-S-DC2`, compare paths and permissions of the `VIFM-S` trees with the source export | 0 differences | **pass** (5004 entries each) |
| S5 | Remove | All `VIFM-S` trees and `VIFM-S-DC2` gone | **pass** |
| S6 | Create with `-VMCount 200`, Export, Scramble, Import `-MoveObjects -DryRun`, Import `-MoveObjects` | 200 VMs back in their folders; duration and progress noted | not run yet (the set itself: Create with 10 VMs, Scramble and Remove checked on LA, 2026-11-19) |

Findings that shaped 1.5.1:

- One `RetrieveEntityPermissions` call per folder cost about 26 ms; one
  `RetrieveAllPermissions` call replaces them all, but it leaves out the
  datacenter's hidden root folders, so those four are still read per folder.
- `Add-Content` per log line cost 2.5 ms (7 s for 3000 lines); one open
  writer flushed per line does the same in about 50 ms.
- Creating folders: a `Get-View` of the parent for every new child doubled
  the calls; parents are now fetched once.

**1.8.0 (W38, #9), 2026-11-27, lab B (vCenter 9.0.2, certificate not trusted by the laptop):** start without `-vCenterServer`, certificate question, error trap. `-Mode Export`; answers from stdin.

| # | Steps | Result |
|---|---|---|
| W1 | No `-vCenterServer`; pick the vCenter by number, `y` at the certificate question, `q` at the first picker | **pass**: list `[1] vc-mgmt-a.site-a.vcf.two`, `[2] 192.168.2.65`, `[3] vc-mgmt-a.site-a.vcf.lab`; `1`, certificate warning, `y`, "Certificate check off for this run", connected (9.0.2); `q` at the datacenter and folder-type pickers: "No datacenter or folder type selected. Skipping export.", exit 0. The same answers on 1.7.0 (PR #24, `-SkipCertificateValidation`) end the same way (continuing to the folder-type picker after `q` at the datacenter is older behaviour) |

## Open points

- Scale not yet run on LB (9.0.2) or L8 (8.0.3): `RetrieveAllPermissions`
  is only compared with the per-folder read on 9.1.1.
- S6: the `-MoveObjects` run at scale (the scale set has the VMs since 0.2.0).
