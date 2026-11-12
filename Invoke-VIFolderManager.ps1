#Requires -Version 5.1
<#
.SYNOPSIS
    Export and import vCenter inventory folder structures (VM, Host, Datastore
    and Network folders) interactively.

.DESCRIPTION
    Connects to a vCenter Server and presents interactive menus to select the
    datacenter(s) and folder types to act on. Supports two modes:

        Export  - Write the folder tree of the selected folder types to a JSON
                  file per datacenter: every folder path, which objects sit in
                  which folder (VMs and templates, clusters and standalone
                  hosts, datastores and datastore clusters, distributed
                  switches), and the permissions set directly on each folder.
        Import  - Recreate the folder tree from a JSON file in a chosen
                  datacenter (existing folders are reused, missing ones are
                  created). Optionally moves objects that exist in the target
                  datacenter under the same name into their exported folder,
                  and re-applies the folder permissions.

    Typical uses: back up the folder layout before changes, rebuild it on a
    new vCenter, and put migrated VMs back into their folders afterwards.

    There is deliberately no Delete mode: destroying a vSphere folder also
    destroys everything inside it, VMs included.

    All activity is written to both the console and a timestamped log file.
    Use -DryRun to see what Import would change without changing anything.

    Credentials are saved as <hostname>.cred next to the script using
    Export-Clixml (DPAPI-protected on Windows, tied to the current user; NOT
    encrypted on Linux/macOS).

.PARAMETER vCenterServer
    FQDN or IP of the vCenter Server.

.PARAMETER Mode
    The operation to perform: Export or Import.
    If omitted, an interactive menu is shown.

.PARAMETER FolderType
    One or more folder types to act on: VM, Host, Datastore, Network.
    If omitted, an interactive picker is shown.

.PARAMETER BackupDirectory
    Directory used to store exported JSON files (Export mode) or read them
    from (Import mode). Defaults to a "Backups" subfolder next to the script.

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder next to
    the script.

.PARAMETER MoveObjects
    Import mode: move objects that exist in the target datacenter into their
    exported folder. If not specified, Import asks.

.PARAMETER ApplyPermissions
    Import mode: re-apply the permissions that were set directly on each
    folder. Roles are matched by name, so custom roles must exist on the
    target first (see VIRoleManager). If not specified, Import asks.

.PARAMETER DryRun
    Import mode: log what would be created, moved and applied without
    changing anything.

.PARAMETER CredentialPath
    Path to the saved credential file. Defaults to <vCenterServer>.cred
    next to the script.

.PARAMETER ResetCredentials
    Force a new credential prompt even if a saved credential file exists.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation. For lab use with self-signed certificates.

.EXAMPLE
    # Interactive - pick the mode from a menu
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc01.lab.local

.EXAMPLE
    # Export the VM and Host folder trees
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc01.lab.local -Mode Export -FolderType VM,Host

.EXAMPLE
    # Preview an import on another vCenter, including VM moves and permissions
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc02.lab.local -Mode Import -MoveObjects -ApplyPermissions -DryRun

.EXAMPLE
    # Recreate only the folders, no moves, no permissions
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc02.lab.local -Mode Import -MoveObjects:$false -ApplyPermissions:$false

.NOTES
    Script   : Invoke-VIFolderManager.ps1
    Version  : 1.0.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : VCF.PowerCLI 9.0+ (recommended) or VMware.PowerCLI 13+
    Tested   : not yet tested against a vCenter

.CHANGELOG
    v1.0.0  2026-11-12  Paul van Dieen
        - Initial release: export/import of VM, Host, Datastore and Network
          folder trees per datacenter to JSON, including folder membership
          and folder permissions
        - Import reuses existing folders, creates missing ones, optionally
          moves same-named objects into their folder and re-applies
          permissions (roles matched by name); -DryRun previews all changes
        - vCLS system folder is skipped on export
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Export', 'Import')]
    [string]$Mode = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('VM', 'Host', 'Datastore', 'Network')]
    [string[]]$FolderType = @(),

    [Parameter(Mandatory = $false)]
    [string]$BackupDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = '',

    [Parameter(Mandatory = $false)]
    [switch]$MoveObjects,

    [Parameter(Mandatory = $false)]
    [switch]$ApplyPermissions,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# --- Console Banner -----------------------------------------------------------
Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  Invoke-VIFolderManager.ps1' + (' ' * 19) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

# --- Defaults -----------------------------------------------------------------
if (-not $BackupDirectory) { $BackupDirectory = Join-Path $scriptDir 'Backups' }
if (-not $LogDirectory)    { $LogDirectory    = Join-Path $scriptDir 'Logs' }

# Folder type -> datacenter root folder property and the object types that can
# live in that tree (and that this script records and moves)
$folderTypeMap = [ordered]@{
    VM        = @{ RootProperty = 'VmFolder';        MemberTypes = @('VirtualMachine') }
    Host      = @{ RootProperty = 'HostFolder';      MemberTypes = @('ClusterComputeResource', 'ComputeResource') }
    Datastore = @{ RootProperty = 'DatastoreFolder'; MemberTypes = @('Datastore', 'StoragePod') }
    Network   = @{ RootProperty = 'NetworkFolder';   MemberTypes = @('VmwareDistributedVirtualSwitch') }
}

# --- PowerCLI Module Check ----------------------------------------------------
$vcfModule    = Get-Module -Name VCF.PowerCLI              -ListAvailable
$legacyModule = Get-Module -Name VMware.VimAutomation.Core -ListAvailable

if (-not $vcfModule -and -not $legacyModule) {
    Write-Host '  [ERROR] No compatible PowerCLI module found.' -ForegroundColor Red
    Write-Host '          Install-Module -Name VCF.PowerCLI -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}

if ($vcfModule) {
    if (-not (Get-Module -Name VCF.PowerCLI)) {
        Write-Host '  [INFO] Loading VCF.PowerCLI...' -ForegroundColor Cyan
        Import-Module VCF.PowerCLI -ErrorAction Stop
    }
} else {
    if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
        Write-Host '  [INFO] Loading VMware.PowerCLI...' -ForegroundColor Cyan
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    }
}

# --- Logging Setup --------------------------------------------------------------
if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogFile   = Join-Path $LogDirectory "VIFolderManager_$timestamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO',
        # Write to the log file only (for long per-object lists)
        [switch]$FileOnly
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    if ($FileOnly) { return }
    switch ($Level) {
        'SUCCESS' { Write-Host "  $entry" -ForegroundColor Green  }
        'WARNING' { Write-Host "  $entry" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "  $entry" -ForegroundColor Red    }
        default   { Write-Host "  $entry" -ForegroundColor Cyan   }
    }
}

# --- Menu Functions -------------------------------------------------------------
function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return @()
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select everything, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host '  Your selection').Trim()
        if ($userInput -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'all') {
            Write-Host "  Selected all $($Items.Count) item(s)." -ForegroundColor Green
            return $Items
        }
        $selectedIndices = @()
        $parts           = $userInput -split ','
        $parseError      = $false
        foreach ($part in $parts) {
            $part = $part.Trim()
            if ($part -match '^\d+$') {
                $selectedIndices += [int]$part
            }
            elseif ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]
                $end   = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "  Invalid range: $part (start must be equal to or less than end)." -ForegroundColor Red
                    $parseError = $true
                    break
                }
                $selectedIndices += $start..$end
            }
            else {
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, or 'all'." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $Items.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($Items.Count)." -ForegroundColor Red
            continue
        }
        $selected = @($selectedIndices | ForEach-Object { $Items[$_ - 1] })
        Write-Host "`n  Selected $($selected.Count) item(s):" -ForegroundColor Green
        $selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host ''
        return $selected
    }
}

function Select-SingleItem {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return $null
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter a number to select one item, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host '  Your selection').Trim()
        if ($userInput -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $Items.Count) {
                $selected = $Items[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($Items.Count)." -ForegroundColor Red
    }
}

function Select-FolderTypes {
    param([string[]]$Available = @($folderTypeMap.Keys))
    $items = @($Available | ForEach-Object { [pscustomobject]@{ Label = "$_ folders"; Value = $_ } })
    $choice = Select-MultipleItems -Items $items -DisplayProperty 'Label' -Title 'Select folder types'
    return @($choice | ForEach-Object { $_.Value })
}

# --- Interactive Mode Menu ------------------------------------------------------
if (-not $Mode) {
    $modeOptions = @(
        [pscustomobject]@{ Label = 'Export  - save folder trees, membership and permissions to JSON'; Value = 'Export' }
        [pscustomobject]@{ Label = 'Import  - recreate folder trees from JSON (optionally move objects)'; Value = 'Import' }
    )
    $modeChoice = Select-SingleItem -Items $modeOptions -DisplayProperty 'Label' -Title 'Select operation mode'
    if (-not $modeChoice) {
        Write-Host '  No mode selected. Exiting.' -ForegroundColor Yellow
        exit 0
    }
    $Mode = $modeChoice.Value
}

if ($Mode -ne 'Import' -and ($DryRun -or $PSBoundParameters.ContainsKey('MoveObjects') -or $PSBoundParameters.ContainsKey('ApplyPermissions'))) {
    Write-Host '  [WARN] -MoveObjects, -ApplyPermissions and -DryRun only apply in Import mode and will be ignored.' -ForegroundColor Yellow
}

# --- Credential Management ------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $scriptDir "$safeVc.cred" }

if ($ResetCredentials -or -not (Test-Path $CredentialPath)) {
    if ($ResetCredentials) {
        Write-Host '  [WARN] -ResetCredentials specified - prompting for new credentials.' -ForegroundColor Yellow
    } else {
        Write-Host '  [INFO] No saved credentials found - prompting.' -ForegroundColor Cyan
    }
    $credUser   = Read-Host "  Username for $vCenterServer"
    $credPass   = Read-Host '  Password' -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new($credUser, $credPass)
    $credential | Export-Clixml -Path $CredentialPath
    Write-Host "  [OK]   Credentials saved to $CredentialPath." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Loading saved credentials from $CredentialPath." -ForegroundColor Cyan
    $credential = Import-Clixml -Path $CredentialPath
}

# --- Connect to vCenter ---------------------------------------------------------
Write-Log "===== VI Folder Manager started (Mode: $Mode$(if ($DryRun -and $Mode -eq 'Import') { ', DRY RUN' })) ====="
Write-Log "vCenter:          $vCenterServer"
Write-Log "Backup Directory: $BackupDirectory"
Write-Log "Log File:         $LogFile"

Write-Log "Connecting to vCenter: $vCenterServer ..."
try {
    $null = Set-PowerCLIConfiguration `
        -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
        -Confirm:$false -Scope Session -WarningAction SilentlyContinue
    $viConn = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Log "Connected to $vCenterServer (version $($viConn.Version), build $($viConn.Build))." -Level SUCCESS
} catch {
    Write-Log "Failed to connect to vCenter '$vCenterServer': $_" -Level ERROR
    exit 1
}

# --- vCenter Helper Functions ---------------------------------------------------
$serviceInstance = Get-View -Server $viConn ServiceInstance
$authManager     = Get-View -Server $viConn -Id $serviceInstance.Content.AuthorizationManager

function Get-ErrorDetail {
    param($ErrorRecord)
    # PowerCLI VimException messages are tab-separated: timestamp, cmdlet, detail
    $reason = "$($ErrorRecord.Exception.Message)"
    if ($reason -match "`t") {
        $reason = @($reason -split "`t" | Where-Object { $_.Trim() })[-1].Trim()
    }
    return $reason
}

function ConvertTo-PathArray {
    # JSON round-trips can turn an empty path into $null; always return an array
    param($Path)
    if ($null -eq $Path) { return ,@() }
    return ,@($Path | ForEach-Object { [string]$_ })
}

function Get-PathKey {
    param([object[]]$Path)
    if ($Path.Count -eq 0) { return '' }
    return ($Path -join [char]31)
}

function Format-Path {
    param([object[]]$Path)
    return '/' + ($Path -join '/')
}

function Get-DatacenterViews {
    return @(Get-View -Server $viConn -ViewType Datacenter -Property Name, VmFolder, HostFolder, DatastoreFolder, NetworkFolder |
        Sort-Object Name)
}

function Get-FolderIndex {
    # All folders below a datacenter, keyed by MoRef value
    param([Parameter(Mandatory = $true)]$DatacenterView)
    $index = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $views = @(Get-View -Server $viConn -ViewType Folder -SearchRoot $DatacenterView.MoRef -Property Name, ChildEntity)
    foreach ($v in $views) { $index[$v.MoRef.Value] = $v }
    # Make sure the four hidden root folders (vm, host, datastore, network) are present
    foreach ($prop in @('VmFolder', 'HostFolder', 'DatastoreFolder', 'NetworkFolder')) {
        $rootRef = $DatacenterView.$prop
        if ($rootRef -and -not $index.ContainsKey($rootRef.Value)) {
            $index[$rootRef.Value] = Get-View -Server $viConn -Id $rootRef -Property Name, ChildEntity
        }
    }
    return ,$index
}

function Get-FolderTree {
    # Walks one folder type tree from its datacenter root folder.
    # Returns the folders (path + MoRef) and the member objects (MoRef + type + path).
    param(
        [Parameter(Mandatory = $true)]$RootMoRef,
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$Type,
        [switch]$SkipSystemFolders
    )
    $memberTypes = $folderTypeMap[$Type].MemberTypes
    $folders = New-Object System.Collections.Generic.List[object]
    $members = New-Object System.Collections.Generic.List[object]
    $queue   = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ MoRef = $RootMoRef; Path = @() })
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if (-not $Index.ContainsKey($node.MoRef.Value)) { continue }
        $view = $Index[$node.MoRef.Value]
        $folders.Add([pscustomobject]@{ MoRef = $node.MoRef; Path = $node.Path })
        if (-not $view.ChildEntity) { continue }
        foreach ($child in $view.ChildEntity) {
            if ($child.Type -eq 'Folder') {
                if (-not $Index.ContainsKey($child.Value)) { continue }
                $childName = $Index[$child.Value].Name
                # vCLS is created and managed by vCenter itself
                if ($SkipSystemFolders -and $Type -eq 'VM' -and $node.Path.Count -eq 0 -and $childName -eq 'vCLS') {
                    Write-Log "Skipped system folder '/vCLS' (managed by vCenter)."
                    continue
                }
                $queue.Enqueue([pscustomobject]@{ MoRef = $child; Path = @($node.Path + $childName) })
            }
            elseif ($memberTypes -contains $child.Type) {
                $members.Add([pscustomobject]@{ MoRef = $child; Type = $child.Type; Path = $node.Path })
            }
        }
    }
    return [pscustomobject]@{ Folders = $folders; Members = $members }
}

function Get-FolderPermissions {
    # Permissions defined directly on the folder (not inherited)
    param([Parameter(Mandatory = $true)]$MoRef, [Parameter(Mandatory = $true)]$RoleNameById)
    $result = @()
    try {
        $perms = @($authManager.RetrieveEntityPermissions($MoRef, $false))
    } catch {
        Write-Log "Could not read permissions of folder $($MoRef.Value): $(Get-ErrorDetail $_)" -Level WARNING
        return ,@()
    }
    foreach ($p in $perms) {
        if ($null -eq $p) { continue }
        $roleName = if ($RoleNameById.ContainsKey([int]$p.RoleId)) { $RoleNameById[[int]$p.RoleId] } else { "roleId:$($p.RoleId)" }
        $result += [pscustomobject]@{
            Principal = $p.Principal
            Group     = [bool]$p.Group
            Role      = $roleName
            Propagate = [bool]$p.Propagate
        }
    }
    return ,$result
}

# =============================================================================
# EXPORT
# =============================================================================
if ($Mode -eq 'Export') {
    Write-Log '--- EXPORT MODE ---'
    $dcItems = @(Get-DatacenterViews | ForEach-Object { [pscustomobject]@{ Label = $_.Name; Item = $_ } })
    $dcChoices = Select-MultipleItems -Items $dcItems -DisplayProperty 'Label' -Title 'Select datacenter(s) to EXPORT'
    $types = if ($FolderType.Count -gt 0) { $FolderType } else { Select-FolderTypes }

    if (@($dcChoices).Count -eq 0 -or @($types).Count -eq 0) {
        Write-Log 'No datacenter or folder type selected. Skipping export.' -Level WARNING
    }
    else {
        if (-not (Test-Path -Path $BackupDirectory)) {
            Write-Log "Backup directory not found. Creating: $BackupDirectory"
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        }
        $roleNameById = @{}
        foreach ($r in $authManager.RoleList) { $roleNameById[[int]$r.RoleId] = $r.Name }

        foreach ($dcChoice in $dcChoices) {
            $dcView = $dcChoice.Item
            Write-Log "Exporting datacenter '$($dcView.Name)' (folder types: $($types -join ', ')) ..."
            try {
                $index       = Get-FolderIndex -DatacenterView $dcView
                $typeResults = @()
                foreach ($t in $types) {
                    $rootRef = $dcView.($folderTypeMap[$t].RootProperty)
                    $tree    = Get-FolderTree -RootMoRef $rootRef -Index $index -Type $t -SkipSystemFolders

                    # Resolve member names in one call
                    $nameById = @{}
                    if ($tree.Members.Count -gt 0) {
                        $refs = [VMware.Vim.ManagedObjectReference[]]@($tree.Members | ForEach-Object { $_.MoRef })
                        foreach ($v in @(Get-View -Server $viConn -Id $refs -Property Name)) {
                            $nameById[$v.MoRef.Value] = $v.Name
                        }
                    }

                    $folderEntries = @($tree.Folders | ForEach-Object {
                        [pscustomobject]@{
                            Path        = @($_.Path)
                            Permissions = (Get-FolderPermissions -MoRef $_.MoRef -RoleNameById $roleNameById)
                        }
                    })
                    $memberEntries = @($tree.Members | Where-Object { $nameById.ContainsKey($_.MoRef.Value) } | ForEach-Object {
                        [pscustomobject]@{
                            Name = $nameById[$_.MoRef.Value]
                            Type = $_.Type
                            Path = @($_.Path)
                        }
                    })
                    $permCount = 0
                    foreach ($f in $folderEntries) { $permCount += @($f.Permissions).Count }
                    Write-Log ("  {0,-9} {1} folder(s) (root included), {2} object(s), {3} folder permission(s)" -f $t, $folderEntries.Count, $memberEntries.Count, $permCount)
                    $typeResults += [pscustomobject]@{
                        Type    = $t
                        Folders = $folderEntries
                        Members = $memberEntries
                    }
                }

                $export = [pscustomobject]@{
                    Tool          = 'VIFolderManager'
                    ToolVersion   = $scriptVersion
                    ExportedAt    = (Get-Date -Format 'o')
                    SourceVCenter = $vCenterServer
                    Datacenter    = $dcView.Name
                    FolderTypes   = @($typeResults)
                }
                $safeDc   = $dcView.Name -replace '[\\/:*?"<>|]', '_'
                $jsonPath = Join-Path $BackupDirectory "Folders_${safeDc}_$timestamp.json"
                ConvertTo-Json -InputObject $export -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
                Write-Log "Exported: $jsonPath" -Level SUCCESS
            }
            catch {
                Write-Log "Could not export datacenter '$($dcView.Name)': $(Get-ErrorDetail $_)" -Level ERROR
            }
        }
    }
}

# =============================================================================
# IMPORT
# =============================================================================
if ($Mode -eq 'Import') {
    Write-Log '--- IMPORT MODE ---'
    if (-not (Test-Path -Path $BackupDirectory)) {
        Write-Log "Backup directory does not exist: $BackupDirectory" -Level ERROR
        Disconnect-VIServer -Server $viConn -Confirm:$false
        exit 1
    }
    $allJson = @(Get-ChildItem -Path $BackupDirectory -Filter '*.json' | Sort-Object Name)
    $fileChoice = $null
    if ($allJson.Count -eq 0) {
        Write-Log "No .json files found in '$BackupDirectory'. Nothing to import." -Level WARNING
    }
    else {
        $fileChoice = Select-SingleItem -Items $allJson -DisplayProperty 'Name' -Title 'Select folder export to IMPORT'
    }

    $data = $null
    if ($fileChoice) {
        try {
            $data = Get-Content -Path $fileChoice.FullName -Raw | ConvertFrom-Json
            if (-not ($data.PSObject.Properties.Name -contains 'Tool') -or $data.Tool -ne 'VIFolderManager') {
                Write-Log "'$($fileChoice.Name)' is not a VIFolderManager export." -Level ERROR
                $data = $null
            }
        } catch {
            Write-Log "Could not read '$($fileChoice.Name)': $($_.Exception.Message)" -Level ERROR
            $data = $null
        }
    }

    if ($data) {
        Write-Log "Export file: $($fileChoice.Name) (datacenter '$($data.Datacenter)' on $($data.SourceVCenter), exported $($data.ExportedAt))"

        # Target datacenter
        $dcItems = @(Get-DatacenterViews | ForEach-Object {
            $mark = if ($_.Name -eq $data.Datacenter) { '  [same name as export]' } else { '' }
            [pscustomobject]@{ Label = "$($_.Name)$mark"; Item = $_ }
        })
        $dcChoice = Select-SingleItem -Items $dcItems -DisplayProperty 'Label' -Title 'Select datacenter to IMPORT into'

        # Folder types present in the file
        $availableTypes = @($data.FolderTypes | ForEach-Object { $_.Type })
        if ($FolderType.Count -gt 0) {
            $types = @($FolderType | Where-Object { $availableTypes -contains $_ })
            $missing = @($FolderType | Where-Object { $availableTypes -notcontains $_ })
            if ($missing.Count -gt 0) { Write-Log "Not in this export, ignored: $($missing -join ', ')" -Level WARNING }
        } else {
            $types = @(Select-FolderTypes -Available $availableTypes)
        }

        if (-not $dcChoice -or $types.Count -eq 0) {
            Write-Log 'No target datacenter or folder type selected. Skipping import.' -Level WARNING
        }
        else {
            $targetDc = $dcChoice.Item
            Write-Log "Target datacenter: $($targetDc.Name); folder types: $($types -join ', ')"

            if (-not $PSBoundParameters.ContainsKey('MoveObjects')) {
                $MoveObjects = [switch]((Read-Host '  Move existing objects (VMs, hosts, datastores, switches) into their exported folder? (y/N)').Trim() -match '^[Yy]')
            }
            if (-not $PSBoundParameters.ContainsKey('ApplyPermissions')) {
                $ApplyPermissions = [switch]((Read-Host '  Re-apply folder permissions? (y/N)').Trim() -match '^[Yy]')
            }
            Write-Log "Move objects: $([bool]$MoveObjects); apply permissions: $([bool]$ApplyPermissions); dry run: $([bool]$DryRun)"

            $proceed = $true
            if (-not $DryRun) {
                $answer = (Read-Host "  Proceed with changes in datacenter '$($targetDc.Name)'? (y/N)").Trim()
                if ($answer -notmatch '^[Yy]') {
                    Write-Log 'Import cancelled by user.' -Level WARNING
                    $proceed = $false
                }
            }

            if ($proceed) {
                $stats = @{ Created = 0; Existing = 0; FolderFail = 0; Moved = 0; InPlace = 0; NotFound = 0; Ambiguous = 0; NotMovable = 0; MoveFail = 0; PermSet = 0; PermPresent = 0; PermFail = 0 }

                $roleIdByName = @{}
                foreach ($r in $authManager.RoleList) { $roleIdByName[$r.Name] = [int]$r.RoleId }

                $targetIndex = Get-FolderIndex -DatacenterView $targetDc

                function Resolve-TargetFolder {
                    # Returns the MoRef of the folder at $Path, creating missing
                    # folders on the way. Returns 'DRYRUN' for folders that would
                    # be created, or $null when creation failed.
                    param([object[]]$Path, $PathMap)
                    $current = $PathMap['']
                    for ($i = 0; $i -lt $Path.Count; $i++) {
                        $prefix = @($Path[0..$i])
                        $key    = Get-PathKey $prefix
                        if ($PathMap.ContainsKey($key)) {
                            $current = $PathMap[$key]
                            if ($null -eq $current) { return $null }
                            continue
                        }
                        if ($DryRun -or $current -is [string]) {
                            Write-Log "[DryRun] Would create folder $(Format-Path $prefix)"
                            $stats.Created++
                            $PathMap[$key] = 'DRYRUN'
                            $current = 'DRYRUN'
                            continue
                        }
                        try {
                            $parentView = Get-View -Server $viConn -Id $current -Property Name
                            $newRef     = $parentView.CreateFolder([string]$Path[$i])
                            Write-Log "Created folder $(Format-Path $prefix)" -Level SUCCESS
                            $stats.Created++
                            $PathMap[$key] = $newRef
                            $current = $newRef
                        } catch {
                            Write-Log "Could not create folder $(Format-Path $prefix): $(Get-ErrorDetail $_)" -Level WARNING
                            $stats.FolderFail++
                            $PathMap[$key] = $null
                            return $null
                        }
                    }
                    return $current
                }

                foreach ($t in $types) {
                    $typeData = @($data.FolderTypes | Where-Object { $_.Type -eq $t })[0]
                    Write-Log "--- $t folders ---"

                    # Existing folder tree in the target, keyed by path
                    $rootRef  = $targetDc.($folderTypeMap[$t].RootProperty)
                    $existing = Get-FolderTree -RootMoRef $rootRef -Index $targetIndex -Type $t
                    $pathMap  = New-Object 'System.Collections.Generic.Dictionary[string,object]'
                    foreach ($f in $existing.Folders) { $pathMap[(Get-PathKey $f.Path)] = $f.MoRef }

                    # 1. Folders (parents first)
                    $folderEntries = @($typeData.Folders | Sort-Object { (ConvertTo-PathArray $_.Path).Count })
                    foreach ($f in $folderEntries) {
                        $path = ConvertTo-PathArray $f.Path
                        if ($path.Count -eq 0) { continue }
                        if ($pathMap.ContainsKey((Get-PathKey $path))) {
                            $stats.Existing++
                            Write-Log "Folder exists: $(Format-Path $path)" -FileOnly
                            continue
                        }
                        $null = Resolve-TargetFolder -Path $path -PathMap $pathMap
                    }

                    # 2. Move objects
                    if ($MoveObjects) {
                        $objIndex = @{}
                        foreach ($mt in $folderTypeMap[$t].MemberTypes) {
                            foreach ($v in @(Get-View -Server $viConn -ViewType $mt -SearchRoot $targetDc.MoRef -Property Name, Parent)) {
                                # ComputeResource also returns clusters; keep exact types only
                                if ($v.MoRef.Type -ne $mt) { continue }
                                $k = "$mt|$($v.Name)"
                                if (-not $objIndex.ContainsKey($k)) { $objIndex[$k] = New-Object System.Collections.Generic.List[object] }
                                $objIndex[$k].Add($v)
                            }
                        }
                        foreach ($m in @($typeData.Members)) {
                            $path = ConvertTo-PathArray $m.Path
                            $k    = "$($m.Type)|$($m.Name)"
                            if (-not $objIndex.ContainsKey($k)) {
                                $stats.NotFound++
                                Write-Log "Not found in target: $($m.Type) '$($m.Name)'" -FileOnly
                                continue
                            }
                            $candidates = $objIndex[$k]
                            if ($candidates.Count -gt 1) {
                                $stats.Ambiguous++
                                Write-Log "Skipped $($m.Type) '$($m.Name)': $($candidates.Count) objects with this name in the target datacenter." -Level WARNING
                                continue
                            }
                            $obj = $candidates[0]
                            if ($null -eq $obj.Parent -or $obj.Parent.Type -ne 'Folder') {
                                # e.g. VM inside a vApp, datastore inside a datastore cluster
                                $stats.NotMovable++
                                Write-Log "Skipped $($m.Type) '$($m.Name)': not directly in a folder (vApp or datastore cluster member)." -FileOnly
                                continue
                            }
                            $target = Resolve-TargetFolder -Path $path -PathMap $pathMap
                            if ($null -eq $target) {
                                $stats.MoveFail++
                                Write-Log "Skipped $($m.Type) '$($m.Name)': target folder $(Format-Path $path) could not be created." -Level WARNING
                                continue
                            }
                            if ($target -isnot [string] -and $obj.Parent.Value -eq $target.Value) {
                                $stats.InPlace++
                                continue
                            }
                            if ($DryRun -or $target -is [string]) {
                                Write-Log "[DryRun] Would move $($m.Type) '$($m.Name)' to $(Format-Path $path)"
                                $stats.Moved++
                                continue
                            }
                            try {
                                $folderView = Get-View -Server $viConn -Id $target -Property Name
                                $folderView.MoveIntoFolder([VMware.Vim.ManagedObjectReference[]]@($obj.MoRef))
                                Write-Log "Moved $($m.Type) '$($m.Name)' to $(Format-Path $path)" -Level SUCCESS
                                $stats.Moved++
                            } catch {
                                Write-Log "Could not move $($m.Type) '$($m.Name)' to $(Format-Path $path): $(Get-ErrorDetail $_)" -Level WARNING
                                $stats.MoveFail++
                            }
                        }
                    }

                    # 3. Permissions
                    if ($ApplyPermissions) {
                        foreach ($f in $folderEntries) {
                            $perms = @($f.Permissions | Where-Object { $null -ne $_ })
                            if ($perms.Count -eq 0) { continue }
                            $path   = ConvertTo-PathArray $f.Path
                            $target = Resolve-TargetFolder -Path $path -PathMap $pathMap
                            if ($null -eq $target) {
                                $stats.PermFail += $perms.Count
                                continue
                            }
                            $current = @()
                            if ($target -isnot [string]) {
                                try { $current = @($authManager.RetrieveEntityPermissions($target, $false)) } catch { $current = @() }
                            }
                            foreach ($p in $perms) {
                                $label = "$($p.Principal) as '$($p.Role)' on $(Format-Path $path)"
                                if (-not $roleIdByName.ContainsKey($p.Role)) {
                                    Write-Log "Skipped permission $label`: role not present on this vCenter (import it first, e.g. with VIRoleManager)." -Level WARNING
                                    $stats.PermFail++
                                    continue
                                }
                                $roleId = $roleIdByName[$p.Role]
                                $already = @($current | Where-Object {
                                    $null -ne $_ -and $_.Principal -eq $p.Principal -and $_.RoleId -eq $roleId -and [bool]$_.Propagate -eq [bool]$p.Propagate
                                })
                                if ($already.Count -gt 0) {
                                    $stats.PermPresent++
                                    continue
                                }
                                if ($DryRun -or $target -is [string]) {
                                    Write-Log "[DryRun] Would set permission $label"
                                    $stats.PermSet++
                                    continue
                                }
                                try {
                                    $perm = New-Object VMware.Vim.Permission
                                    $perm.Principal = $p.Principal
                                    $perm.Group     = [bool]$p.Group
                                    $perm.RoleId    = $roleId
                                    $perm.Propagate = [bool]$p.Propagate
                                    $authManager.SetEntityPermissions($target, [VMware.Vim.Permission[]]@($perm))
                                    Write-Log "Set permission $label" -Level SUCCESS
                                    $stats.PermSet++
                                } catch {
                                    Write-Log "Could not set permission $label`: $(Get-ErrorDetail $_). Check that the principal exists in this vCenter's identity source." -Level WARNING
                                    $stats.PermFail++
                                }
                            }
                        }
                    }
                }

                $verb = if ($DryRun) { 'would be ' } else { '' }
                Write-Log "Folders: $($stats.Created) ${verb}created, $($stats.Existing) already present, $($stats.FolderFail) failed."
                if ($MoveObjects) {
                    Write-Log "Objects: $($stats.Moved) ${verb}moved, $($stats.InPlace) already in place, $($stats.NotFound) not found in target, $($stats.Ambiguous) ambiguous name, $($stats.NotMovable) not directly in a folder, $($stats.MoveFail) failed."
                    if ($stats.NotFound -gt 0) { Write-Log 'Objects not found in the target are listed in the log file.' }
                }
                if ($ApplyPermissions) {
                    Write-Log "Permissions: $($stats.PermSet) ${verb}set, $($stats.PermPresent) already present, $($stats.PermFail) skipped or failed."
                }
                if ($DryRun) { Write-Log 'Dry run: nothing was changed.' -Level WARNING }
            }
        }
    }
}

# =============================================================================
# DISCONNECT
# =============================================================================
Write-Log 'Disconnecting from vCenter...'
Disconnect-VIServer -Server $viConn -Confirm:$false
Write-Log '===== Script finished =====' -Level SUCCESS
Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
