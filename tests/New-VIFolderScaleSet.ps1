#Requires -Version 5.1

<#
.SYNOPSIS
    Builds or removes a large throwaway folder set in a LAB vCenter, to test
    Invoke-VIFolderManager.ps1 at scale (progress, duration).

.DESCRIPTION
    Create  A folder 'VIFM-S' in the VM, Host, Datastore and Network folders
            of a datacenter, each with a tree of empty folders below it:
            together -FolderCount folders (default 5000; 60% VM, 10% Host,
            15% Datastore, 15% Network), up to six levels deep with five
            children per folder. Names repeat across branches (BU-01..,
            Prod/Test/Dev/Acc/DR, Web/App/DB/Mgmt/Infra, Team-1.., Svc-1..),
            like real trees. With -TestPrincipal, -PermissionCount folders
            of the VM tree (default 500) get a permission for that principal
            with the built-in ReadOnly role, half of them propagating.
            Running Create again adds what is missing.
            -WithTargetDatacenter also creates an empty datacenter
            'VIFM-S-DC2' as the target of a real import at scale.
    Remove  Deletes the four 'VIFM-S' trees, only when they hold nothing
            but folders (no VM, host, datastore or network inside).
            Permissions go with the folders. Also removes 'VIFM-S-DC2'
            when it holds nothing but folders.

    Folders only: no VMs or hosts needed. Lab use only.

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create or Remove.

.PARAMETER FolderCount
    Total number of folders below the four VIFM-S roots (Create). Default 5000.

.PARAMETER PermissionCount
    Number of folder permissions (Create, needs -TestPrincipal). Default 500.

.PARAMETER TestPrincipal
    Principal for the permissions, e.g. VSPHERE.LOCAL\vifm-test. Use a
    dedicated test user, never a group that contains your admin account.
    Without it, no permissions are set.

.PARAMETER Datacenter
    Datacenter to build the set in. Defaults to the first datacenter
    (never VIFM-S-DC2).

.PARAMETER WithTargetDatacenter
    Create mode: also create the empty datacenter 'VIFM-S-DC2', to import
    the exported set into.

.PARAMETER CredentialPath
    Saved credential file. Defaults to <vCenterServer>.cred next to this
    script, or in the repo root.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.EXAMPLE
    .\New-VIFolderScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Create -TestPrincipal 'VSPHERE.LOCAL\vifm-test'

.EXAMPLE
    .\New-VIFolderScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Remove

.NOTES
    Script   : New-VIFolderScaleSet.ps1
    Version  : 0.1.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : Lab, 2026-11-19: VCF 9.1.1 (Holodeck)
#>

<# CHANGELOG
    v0.1.0  2026-11-19  Paul van Dieen
        - Initial version: Create and Remove of a large folder set with
          permissions for scale tests of Invoke-VIFolderManager.ps1 (#16)
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Remove')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [ValidateRange(4, 50000)]
    [int]$FolderCount = 5000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 50000)]
    [int]$PermissionCount = 500,

    [Parameter(Mandatory = $false)]
    [string]$TestPrincipal = '',

    [Parameter(Mandatory = $false)]
    [string]$Datacenter = '',

    [Parameter(Mandatory = $false)]
    [switch]$WithTargetDatacenter,

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '0.1.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VIFolderScaleSet.ps1' + (' ' * 21) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

$rootName = 'VIFM-S'
$dc2Name  = 'VIFM-S-DC2'
$fanout   = 5
$maxDepth = 6
# Name pools per level below the root: names repeat across branches
$pools = @(
    @(1..$fanout | ForEach-Object { 'BU-{0:D2}' -f $_ }),
    @('Prod', 'Test', 'Dev', 'Acc', 'DR'),
    @('Web', 'App', 'DB', 'Mgmt', 'Infra'),
    @(1..$fanout | ForEach-Object { "Team-$_" }),
    @(1..$fanout | ForEach-Object { "Svc-$_" }),
    @(1..$fanout | ForEach-Object { "Item-$_" })
)
$share = [ordered]@{ VM = 0.60; Host = 0.10; Datastore = 0.15; Network = 0.15 }

function Say { param([string]$Text, [string]$Color = 'Cyan') Write-Host "  $Text" -ForegroundColor $Color }

# --- Connect ------------------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) {
    $CredentialPath = Join-Path $scriptDir "$safeVc.cred"
    if (-not (Test-Path $CredentialPath)) { $CredentialPath = Join-Path (Split-Path $scriptDir -Parent) "$safeVc.cred" }
}
if (Test-Path $CredentialPath) {
    $credential = Import-Clixml -Path $CredentialPath
} else {
    $credential = Get-Credential -Message "Credentials for $vCenterServer"
}
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Say "Connected to $vCenterServer ($($vi.Version), build $($vi.Build))" Green

try {
    $dc = if ($Datacenter) { Get-Datacenter -Server $vi -Name $Datacenter } else { Get-Datacenter -Server $vi | Where-Object { $_.Name -ne $dc2Name } | Select-Object -First 1 }
    if (-not $dc) { throw 'No datacenter found.' }
    Say "Datacenter: $($dc.Name)"
    $dcView = $dc.ExtensionData
    $typeRoot = [ordered]@{
        VM        = $dcView.VmFolder
        Host      = $dcView.HostFolder
        Datastore = $dcView.DatastoreFolder
        Network   = $dcView.NetworkFolder
    }

    function Get-ChildFolderMap {
        # Child folders of a folder, name -> MoRef (one call per folder that has any)
        param($ParentRef)
        $map = @{}
        $kids = @((Get-View -Server $vi -Id $ParentRef -Property ChildEntity).ChildEntity | Where-Object { $_ -and $_.Type -eq 'Folder' })
        if ($kids.Count -gt 0) {
            foreach ($v in @(Get-View -Server $vi -Id $kids -Property Name)) { $map[$v.Name] = $v.MoRef }
        }
        return $map
    }

    if ($Mode -eq 'Create') {
        $started = Get-Date
        $created = 0
        $existing = 0
        $vmTree = New-Object System.Collections.Generic.List[object]
        $types = @($share.Keys)
        $left = $FolderCount
        for ($ti = 0; $ti -lt $types.Count; $ti++) {
            $type = $types[$ti]
            # The last type takes the rest, so the total is exact
            $want = if ($ti -eq $types.Count - 1) { $left } else { [Math]::Max(1, [int][Math]::Round($FolderCount * $share[$type])) }
            $left -= $want
            $rootMap = Get-ChildFolderMap $typeRoot[$type]
            if ($rootMap.ContainsKey($rootName)) { $rootRef = $rootMap[$rootName] }
            else { $rootRef = (Get-View -Server $vi -Id $typeRoot[$type]).CreateFolder($rootName) }
            Say "$type folders: building $want below $rootName ..."

            # Breadth-first: five children per folder, level by level, until $want
            $level = @(@{ Ref = $rootRef; Depth = 0 })
            $made = 0
            while ($made -lt $want -and $level.Count -gt 0) {
                $next = New-Object System.Collections.Generic.List[object]
                foreach ($p in $level) {
                    if ($made -ge $want) { break }
                    if ($p.Depth -ge $maxDepth) { continue }
                    $have = Get-ChildFolderMap $p.Ref
                    $parentView = $null
                    foreach ($name in $pools[$p.Depth]) {
                        if ($made -ge $want) { break }
                        if ($have.ContainsKey($name)) {
                            $ref = $have[$name]; $existing++
                        } else {
                            if (-not $parentView) { $parentView = Get-View -Server $vi -Id $p.Ref }
                            $ref = $parentView.CreateFolder($name); $created++
                        }
                        $made++
                        $next.Add(@{ Ref = $ref; Depth = $p.Depth + 1 })
                        if ($type -eq 'VM') { $vmTree.Add($ref) }
                        if ($made % 500 -eq 0) {
                            Write-Progress -Activity "Creating $type folders" -Status "$made of $want" -PercentComplete ([int](100 * $made / $want))
                            Say "  $type`: $made of $want"
                        }
                    }
                }
                $level = $next.ToArray()
            }
            Write-Progress -Activity "Creating $type folders" -Completed
            if ($made -lt $want) { Say "$type`: only $made folders fit in $maxDepth levels of $fanout." Yellow }
        }
        Say "Folders: $created created, $existing already there"

        # --- Permissions --------------------------------------------------------
        $perms = 0
        if ($TestPrincipal -and $PermissionCount -gt 0 -and $vmTree.Count -gt 0) {
            $authMgr = Get-View -Server $vi -Id (Get-View -Server $vi ServiceInstance).Content.AuthorizationManager
            $readOnly = @($authMgr.RoleList | Where-Object { $_.Name -eq 'ReadOnly' })[0]
            $step = [Math]::Max(1, [int][Math]::Floor($vmTree.Count / $PermissionCount))
            $isGroup = $false
            for ($i = 0; $i -lt $vmTree.Count -and $perms -lt $PermissionCount; $i += $step) {
                $perm = New-Object VMware.Vim.Permission
                $perm.Principal = $TestPrincipal
                $perm.Group     = $isGroup
                $perm.RoleId    = $readOnly.RoleId
                $perm.Propagate = ($perms % 2 -eq 0)
                $authMgr.SetEntityPermissions($vmTree[$i], @($perm))
                $perms++
                if ($perms % 100 -eq 0) {
                    Write-Progress -Activity 'Setting folder permissions' -Status "$perms of $PermissionCount" -PercentComplete ([int](100 * $perms / $PermissionCount))
                }
            }
            Write-Progress -Activity 'Setting folder permissions' -Completed
            Say "Permissions: $perms for $TestPrincipal (ReadOnly, half propagating)"
        } elseif (-not $TestPrincipal) {
            Say 'No -TestPrincipal: no permissions set.' Yellow
        }
        if ($WithTargetDatacenter) {
            if (Get-Datacenter -Server $vi -Name $dc2Name -ErrorAction SilentlyContinue) { Say "Datacenter $dc2Name already there" }
            else {
                $null = New-Datacenter -Server $vi -Name $dc2Name -Location (Get-Folder -Server $vi -NoRecursion)
                Say "Created empty datacenter $dc2Name (import target)"
            }
        }
        Say ("Done in {0:mm\:ss}: {1} folders, {2} permissions." -f ((Get-Date) - $started), $FolderCount, $perms) Green
    }
    else {
        # --- Remove -------------------------------------------------------------
        $viewMgr = Get-View -Server $vi -Id (Get-View -Server $vi ServiceInstance).Content.ViewManager
        foreach ($type in $typeRoot.Keys) {
            $rootMap = Get-ChildFolderMap $typeRoot[$type]
            if (-not $rootMap.ContainsKey($rootName)) { Say "$type`: no $rootName folder."; continue }
            $rootRef = $rootMap[$rootName]
            # Everything below the root, of any type: only folders may be there
            $cv = Get-View -Server $vi -Id ($viewMgr.CreateContainerView($rootRef, [string[]]@('ManagedEntity'), $true))
            try {
                $all = @($cv.View | Where-Object { $_ })
            } finally { try { $cv.DestroyView() } catch { } }
            $other = @($all | Where-Object { $_.Type -ne 'Folder' })
            if ($other.Count -gt 0) {
                Say "$type`: $rootName holds $($other.Count) object(s) that are not folders; left in place." Yellow
                continue
            }
            $task = (Get-View -Server $vi -Id $rootRef).Destroy_Task()
            $null = Get-Task -Server $vi -Id "Task-$($task.Value)" | Wait-Task
            Say "$type`: removed $rootName with $($all.Count) folder(s)"
        }
        $dc2 = Get-Datacenter -Server $vi -Name $dc2Name -ErrorAction SilentlyContinue
        if ($dc2) {
            $cv = Get-View -Server $vi -Id ($viewMgr.CreateContainerView($dc2.ExtensionData.MoRef, [string[]]@('ManagedEntity'), $true))
            try { $inDc2 = @($cv.View | Where-Object { $_ -and $_.Type -ne 'Folder' }) } finally { try { $cv.DestroyView() } catch { } }
            if ($inDc2.Count -gt 0) {
                Say "$dc2Name holds $($inDc2.Count) object(s) that are not folders; left in place." Yellow
            } else {
                $task = $dc2.ExtensionData.Destroy_Task()
                $null = Get-Task -Server $vi -Id "Task-$($task.Value)" | Wait-Task
                Say "Removed datacenter $dc2Name"
            }
        }
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
