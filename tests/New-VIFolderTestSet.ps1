#Requires -Version 5.1
<#
.SYNOPSIS
    Builds, scrambles and removes a throwaway test set for testing
    Invoke-VIFolderManager.ps1 in a LAB vCenter.

.DESCRIPTION
    Create   - Creates a 'VIFM-Test' folder tree in the VM, Host, Datastore and
               Network folders of a datacenter, a handful of tiny dummy VMs
               (1 MB disk, 128 MB RAM, no NIC, never powered on) and one
               template in those folders, a same-named VM pair in two folders
               (ambiguous-name case), and optionally test permissions with a
               test role. -WithSecondDatacenter also creates an empty
               datacenter 'VIFM-DC2' as an import target.
    Scramble - Simulates a lost layout: moves the dummy VMs (except the
               same-named pair) to the datacenter's root VM folder, removes
               the empty test folders and the test permissions. Then run
               Invoke-VIFolderManager.ps1 -Mode Import to restore it.
    Remove   - Deletes the dummy VMs and template (only objects carrying the
               marker note), the VIFM-Test folders (only when empty), the
               test role (only when unused) and VIFM-DC2 (only when it holds
               no hosts or VMs).

    Lab use only. Every destructive step is limited to objects this script
    created (marker note or VIFM- names).

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create, Scramble or Remove.

.PARAMETER Datacenter
    Datacenter to build the test set in. Defaults to the first datacenter
    that has a connected host.

.PARAMETER TestPrincipal
    Optional principal (e.g. VSPHERE.LOCAL\vifm-test) that gets test
    permissions on the test folders. Use a dedicated test user, never a
    group that contains your admin account. Without it, no permissions are
    set.

.PARAMETER WithSecondDatacenter
    Create mode: also create the empty datacenter 'VIFM-DC2'.

.PARAMETER CredentialPath
    Saved credential file. Defaults to <vCenterServer>.cred next to the script.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.NOTES
    Script   : New-VIFolderTestSet.ps1
    Version  : 1.0.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : VCF 9.1.1 and 9.0.2 (Holodeck lab)

.CHANGELOG
    v1.0.0  2026-11-12  Paul van Dieen
        - Initial release: Create / Scramble / Remove of a lab test set for
          Invoke-VIFolderManager.ps1
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Scramble', 'Remove')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$Datacenter = '',

    [Parameter(Mandatory = $false)]
    [string]$TestPrincipal = '',

    [Parameter(Mandatory = $false)]
    [switch]$WithSecondDatacenter,

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VIFolderTestSet.ps1' + (' ' * 22) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

$marker   = 'VIFolderManager test object - safe to delete'
$rootName = 'VIFM-Test'
$roleName = 'VIFM-TestRole'
$dc2Name  = 'VIFM-DC2'

function Say { param([string]$Text, [string]$Color = 'Cyan') Write-Host "  $Text" -ForegroundColor $Color }

# --- Connect ------------------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $scriptDir "$safeVc.cred" }
if (Test-Path $CredentialPath) {
    $credential = Import-Clixml -Path $CredentialPath
} else {
    $credential = Get-Credential -Message "Credentials for $vCenterServer"
}
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Say "Connected to $vCenterServer ($($vi.Version))" Green

try {
    # --- Datacenter -------------------------------------------------------------
    if ($Datacenter) {
        $dc = Get-Datacenter -Server $vi -Name $Datacenter
    } else {
        $dc = Get-Datacenter -Server $vi | Where-Object { $_.Name -ne $dc2Name } |
            Where-Object { @(Get-VMHost -Server $vi -Location $_ | Where-Object ConnectionState -eq 'Connected').Count -gt 0 } |
            Select-Object -First 1
    }
    if (-not $dc) { throw 'No datacenter with a connected host found.' }
    Say "Datacenter: $($dc.Name)"

    $roots = [ordered]@{
        VM        = Get-VIObjectByVIView -Server $vi -MORef $dc.ExtensionData.VmFolder
        Host      = Get-VIObjectByVIView -Server $vi -MORef $dc.ExtensionData.HostFolder
        Datastore = Get-VIObjectByVIView -Server $vi -MORef $dc.ExtensionData.DatastoreFolder
        Network   = Get-VIObjectByVIView -Server $vi -MORef $dc.ExtensionData.NetworkFolder
    }

    function Get-ChildFolder {
        param($Parent, [string]$Name)
        return Get-Folder -Server $vi -Location $Parent -Name $Name -NoRecursion -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    function Confirm-Folder {
        param($Parent, [string]$Name)
        $f = Get-ChildFolder -Parent $Parent -Name $Name
        if (-not $f) {
            $f = New-Folder -Server $vi -Location $Parent -Name $Name
            Say "Created folder $Name (under $($Parent.Name))" Green
        }
        return $f
    }
    function Get-MarkedObjects {
        $vms   = @(Get-VM -Server $vi -Location $dc -ErrorAction SilentlyContinue | Where-Object { $_.ExtensionData.Config.Annotation -eq $marker })
        $tmpls = @(Get-Template -Server $vi -Location $dc -ErrorAction SilentlyContinue | Where-Object { $_.ExtensionData.Config.Annotation -eq $marker })
        return [pscustomobject]@{ VMs = $vms; Templates = $tmpls }
    }
    function Remove-EmptyFolderTree {
        # Removes $Folder and its subfolders, deepest first, but only folders that are empty
        param($Folder)
        foreach ($child in @(Get-Folder -Server $vi -Location $Folder -NoRecursion -ErrorAction SilentlyContinue)) {
            Remove-EmptyFolderTree -Folder $child
        }
        $view = Get-View -Server $vi -Id $Folder.Id -Property ChildEntity
        if (@($view.ChildEntity | Where-Object { $null -ne $_ }).Count -eq 0) {
            Remove-Folder -Server $vi -Folder $Folder -Confirm:$false
            Say "Removed empty folder $($Folder.Name)" Yellow
        } else {
            Say "Kept folder $($Folder.Name): not empty" DarkGray
        }
    }

    # ===========================================================================
    if ($Mode -eq 'Create') {
        $vmHost = Get-VMHost -Server $vi -Location $dc | Where-Object ConnectionState -eq 'Connected' | Select-Object -First 1
        $ds     = $vmHost | Get-Datastore -Server $vi | Where-Object { $_.State -eq 'Available' } | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
        $pool   = (Get-View -Server $vi -Id $vmHost.ExtensionData.Parent -Property ResourcePool).ResourcePool
        Say "Host: $($vmHost.Name); datastore: $($ds.Name)"

        # VM tree
        $t      = Confirm-Folder $roots.VM $rootName
        $prod   = Confirm-Folder $t 'Prod'
        $web    = Confirm-Folder $prod 'Web'
        $db     = Confirm-Folder $prod 'DB'
        $test   = Confirm-Folder $t 'Test'
        $empty  = Confirm-Folder $t 'Empty'
        $nested = Confirm-Folder $empty 'Nested'
        $null   = Confirm-Folder $nested 'Deep'
        $null   = Confirm-Folder $t 'Spaces & Specials (1)'

        # Other trees
        foreach ($type in 'Host', 'Datastore', 'Network') {
            $r = Confirm-Folder $roots[$type] $rootName
            $null = Confirm-Folder $r 'Sub-A'
            $null = Confirm-Folder $r 'Sub-B'
        }

        # Dummy VMs: tiny, no NIC, never powered on
        $vmPlan = @(
            @{ Name = 'vifm-web01';  Folder = $web  }
            @{ Name = 'vifm-db01';   Folder = $db   }
            @{ Name = 'vifm-test01'; Folder = $test }
            @{ Name = 'vifm-root01'; Folder = $t    }
            @{ Name = 'vifm-tmpl01'; Folder = $test; Template = $true }
            @{ Name = 'vifm-dup01';  Folder = $prod }
            @{ Name = 'vifm-dup01';  Folder = $test }
        )
        foreach ($p in $vmPlan) {
            $exists = @(Get-VM -Server $vi -Location $p.Folder -Name $p.Name -NoRecursion -ErrorAction SilentlyContinue) +
                      @(Get-Template -Server $vi -Location $p.Folder -Name $p.Name -NoRecursion -ErrorAction SilentlyContinue)
            if (@($exists | Where-Object { $null -ne $_ }).Count -gt 0) { Say "VM $($p.Name) in $($p.Folder.Name) exists" DarkGray; continue }
            # CreateVM via the API: New-VM always attaches a NIC to some network
            # (on a VCF host that can be an uplink port group with no free ports)
            $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
            $spec.Name       = $p.Name
            $spec.GuestId    = 'otherGuest64'
            $spec.NumCPUs    = 1
            $spec.MemoryMB   = 128
            $spec.Annotation = $marker
            $spec.Files      = New-Object VMware.Vim.VirtualMachineFileInfo
            $spec.Files.VmPathName = "[$($ds.Name)]"
            $folderView = Get-View -Server $vi -Id $p.Folder.Id -Property Name
            $vmRef = $folderView.CreateVM($spec, $pool, $vmHost.ExtensionData.MoRef)
            $vm    = Get-VIObjectByVIView -Server $vi -MORef $vmRef
            if ($p.ContainsKey('Template')) { $null = Set-VM -Server $vi -VM $vm -ToTemplate -Confirm:$false }
            Say "Created $(if ($p.ContainsKey('Template')) { 'template' } else { 'VM' }) $($p.Name) in $($p.Folder.Name)" Green
        }

        # Permissions
        if ($TestPrincipal) {
            $role = Get-VIRole -Server $vi -Name $roleName -ErrorAction SilentlyContinue
            if (-not $role) {
                $role = New-VIRole -Server $vi -Name $roleName -Privilege (Get-VIPrivilege -Server $vi -Id 'VirtualMachine.Interact.PowerOn')
                Say "Created role $roleName" Green
            }
            $null = New-VIPermission -Server $vi -Entity $prod -Principal $TestPrincipal -Role $role -Propagate:$true
            $null = New-VIPermission -Server $vi -Entity $test -Principal $TestPrincipal -Role (Get-VIRole -Server $vi -Name 'ReadOnly') -Propagate:$false
            $null = New-VIPermission -Server $vi -Entity (Get-ChildFolder $roots.Host $rootName) -Principal $TestPrincipal -Role (Get-VIRole -Server $vi -Name 'ReadOnly') -Propagate:$true
            Say "Set test permissions for $TestPrincipal on Prod ($roleName, propagate), Test (ReadOnly, no propagate) and Host/$rootName (ReadOnly)" Green
        } else {
            Say 'No -TestPrincipal: no permissions set.' Yellow
        }

        if ($WithSecondDatacenter -and -not (Get-Datacenter -Server $vi -Name $dc2Name -ErrorAction SilentlyContinue)) {
            $rootFolder = Get-Folder -Server $vi -NoRecursion | Select-Object -First 1
            $null = New-Datacenter -Server $vi -Location $rootFolder -Name $dc2Name
            Say "Created empty datacenter $dc2Name" Green
        }
    }

    # ===========================================================================
    if ($Mode -eq 'Scramble') {
        $marked = Get-MarkedObjects
        foreach ($vm in @($marked.VMs) + @($marked.Templates)) {
            if ($null -eq $vm -or $vm.Name -eq 'vifm-dup01') { continue }
            $null = Move-Inventory -Server $vi -Item $vm -Destination $roots.VM
            Say "Moved $($vm.Name) to the root VM folder" Yellow
        }
        $t = Get-ChildFolder $roots.VM $rootName
        if ($t) {
            # Only permissions DEFINED on a folder inside the test tree; Get-VIPermission
            # also returns inherited ones (e.g. from the vCenter root folder)
            $testFolders  = @($t) + @(Get-Folder -Server $vi -Location $t)
            $testFolderIds = @($testFolders | ForEach-Object { $_.Id })
            foreach ($perm in @(Get-VIPermission -Server $vi -Entity $testFolders -ErrorAction SilentlyContinue)) {
                if ($null -ne $perm -and $testFolderIds -contains $perm.EntityId -and $TestPrincipal -and $perm.Principal -eq $TestPrincipal) {
                    Remove-VIPermission -Permission $perm -Confirm:$false
                    Say "Removed permission $($perm.Principal)/$($perm.Role) on $($perm.Entity.Name)" Yellow
                }
            }
            foreach ($name in 'DB', 'Empty') {
                $parent = if ($name -eq 'DB') { Get-ChildFolder $t 'Prod' } else { $t }
                $f = if ($parent) { Get-ChildFolder $parent $name } else { $null }
                if ($f) { Remove-EmptyFolderTree -Folder $f }
            }
        }
        foreach ($type in 'Host', 'Datastore', 'Network') {
            $r = Get-ChildFolder $roots[$type] $rootName
            if ($r) {
                $sub = Get-ChildFolder $r 'Sub-B'
                if ($sub) { Remove-EmptyFolderTree -Folder $sub }
            }
        }
        Say 'Scrambled. Restore with Invoke-VIFolderManager.ps1 -Mode Import -MoveObjects -ApplyPermissions.' Cyan
    }

    # ===========================================================================
    if ($Mode -eq 'Remove') {
        $marked = Get-MarkedObjects
        foreach ($tm in @($marked.Templates)) {
            if ($null -eq $tm) { continue }
            Remove-Template -Server $vi -Template $tm -DeletePermanently -Confirm:$false
            Say "Deleted template $($tm.Name)" Yellow
        }
        foreach ($vm in @($marked.VMs)) {
            if ($null -eq $vm) { continue }
            Remove-VM -Server $vi -VM $vm -DeletePermanently -Confirm:$false
            Say "Deleted VM $($vm.Name)" Yellow
        }
        foreach ($type in $roots.Keys) {
            $r = Get-ChildFolder $roots[$type] $rootName
            if ($r) { Remove-EmptyFolderTree -Folder $r }
        }
        $dc2 = Get-Datacenter -Server $vi -Name $dc2Name -ErrorAction SilentlyContinue
        if ($dc2) {
            $busy = @(Get-VMHost -Server $vi -Location $dc2 -ErrorAction SilentlyContinue).Count + @(Get-VM -Server $vi -Location $dc2 -ErrorAction SilentlyContinue).Count
            if ($busy -eq 0) {
                Remove-Datacenter -Server $vi -Datacenter $dc2 -Confirm:$false
                Say "Removed datacenter $dc2Name" Yellow
            } else {
                Say "Kept datacenter ${dc2Name}: it holds hosts or VMs" Red
            }
        }
        $role = Get-VIRole -Server $vi -Name $roleName -ErrorAction SilentlyContinue
        if ($role) {
            if (@(Get-VIPermission -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.Role -eq $roleName }).Count -eq 0) {
                Remove-VIRole -Server $vi -Role $role -Confirm:$false
                Say "Removed role $roleName" Yellow
            } else {
                # VCF 9.1 adds its own permission for every role on the vCenter root
                # (principal VSPHERE.LOCAL\vcf_reserved_<n>); not touched by this script
                Say "Kept role ${roleName}: still in use (on VCF 9.1 possibly by a vcf_reserved_* permission on the vCenter root, managed by VCF)" Red
            }
        }
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
