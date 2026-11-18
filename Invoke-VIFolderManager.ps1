#Requires -Version 7.4

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
    Without this parameter an interactive run asks for the directory after
    the mode: Enter keeps the default, B opens the Windows folder browser,
    or type a path. Import shows how many exports the folder holds. No
    prompt in an unattended run (-Datacenter on Export, -ExportFile on
    Import).

.PARAMETER Datacenter
    Export mode: one or more datacenter names or wildcards to export,
    instead of the datacenter picker. Import mode: the exact name of the
    datacenter to import into, instead of the picker. An unknown name stops
    the script with the list of datacenters.

.PARAMETER ExportFile
    Import mode: the export file to import (a name or wildcard, with or
    without .json) instead of the file picker. When a wildcard matches
    several files, the newest is used and logged. Together with -Datacenter,
    -FolderType, -MoveObjects and -ApplyPermissions (use -MoveObjects:$false
    to say no) an Import runs unattended, without the Proceed question
    (saved credential required); without console input every prompt stops
    the script with a clear message and exit code 2.

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder next to
    the script.

.PARAMETER IncludeSystemFolders
    Export mode: also export the top-level folders that vCenter, the
    Supervisor and NSX manage themselves (VM: vCLS, Namespaces; Network:
    NSX Managed Folders, Virtual Private Clouds). Skipped by default.

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

.EXAMPLE
    # Interactive: after the mode, press B to pick the backup folder in a dialog
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc02.lab.local -Mode Import

.EXAMPLE
    # Unattended export of every datacenter whose name starts with DC
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc01.lab.local -Mode Export -Datacenter 'DC*' -FolderType VM,Host,Datastore,Network

.EXAMPLE
    # Unattended import after a migration wave: newest export of DC01, move VMs, no permissions
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc02.lab.local -Mode Import -ExportFile 'Folders_DC01_*' -Datacenter DC01 -FolderType VM -MoveObjects -ApplyPermissions:$false

.NOTES
    Script   : Invoke-VIFolderManager.ps1
    Version  : 1.4.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ (or VMware.PowerCLI 13+)
    Tested   : VCF 9.1.1 and VCF 9.0.2 management vCenters (Holodeck lab,
               2026-11-12), incl. import across the two vCenters
#>

<# CHANGELOG
    v1.4.0  2026-11-18  Paul van Dieen
        - Progress bar during long steps (#12): "n of N: item", the
          percentage and the time left, in the export while it reads each
          folder and its permissions (per datacenter and folder type), and
          the import while it creates folders, moves objects and sets
          permissions. Updated at most every 250 ms; the bar disappears when
          the step ends. The log file is unchanged

    v1.3.0  2026-11-18  Paul van Dieen
        - On par with VDSPortGroupManager 1.6.1 (#10)
        - Pick the backup directory interactively: without -BackupDirectory,
          Export and Import ask for it after the mode. Enter keeps the
          default Backups folder, B opens the Windows folder browser (only
          where a GUI is available), or type a path. Import shows how many
          exports the folder holds and asks again when it holds none.
        - Failures stand out: a datacenter that fails to export, a folder
          that can't be created, an object that can't be moved and a
          permission that can't be set are logged as an ERROR (red)
          starting with FAILED, with the vCenter message without the
          PowerShell wrapper. Summaries are red with failures, yellow with
          only skips, green otherwise, and list every failure. A run with
          failures ends with exit code 1 (was always 0).
        - A permission whose role doesn't exist on the target is a skip
          (yellow), counted apart from permissions that failed
        - New -Datacenter (Export: names or wildcards; Import: the target)
          and -ExportFile (Import: name or wildcard, newest match wins), so
          Export and Import can run unattended; a fully parameterised
          Import skips the Proceed question
        - Without console input (scheduled task, CI, -NonInteractive) every
          prompt stops with a clear message naming the parameters and exit
          code 2, instead of an error
        - Picker: filter by name (a wildcard such as *DC01*, or /text for a
          substring), renumbered; 'all' takes what the filter shows,
          'reset' clears it, 'list' shows everything; above 50 items it asks
          for a filter instead of printing the whole list; cancel also with
          exit, quit or q

    v1.2.1  2026-11-18  Paul van Dieen
        - Get-Help shows the full help again: the changelog moved out of the
          help block into its own comment block (the unknown .CHANGELOG
          keyword made Get-Help ignore the whole help block)
        - Blank line between #Requires and the help block, for the same reason

    v1.2.0  2026-11-16  Paul van Dieen
        - Minimum PowerShell is now 7.4: VCF.PowerCLI 9.x needs PowerShell 7
          (KB 409981); #Requires, .NOTES and README updated (#2)
        - PowerCLI loading imports only VMware.VimAutomation.Core instead of
          the whole VCF.PowerCLI bundle, with -ErrorAction Stop (#4)
        - Stops up front when PowerCLI modules of different versions are
          already loaded in the session
        - Load failures show the short error, the loaded VMware.* modules and
          a link to the jump-host guide (one PowerCLI version per host,
          completeness check, pitfalls); same text as VDSPortGroupManager

    v1.1.0  2026-11-12  Paul van Dieen
        - Lab-tested on VCF 9.1.1 and 9.0.2 (export, dry run, import with
          moves and permissions, re-run, import into a second datacenter and
          into a second vCenter)
        - Export skips top-level system folders by default: VM 'vCLS' and
          'Namespaces' (Supervisor, vSphere Pods, VKS nodes), Network 'NSX
          Managed Folders' and 'Virtual Private Clouds'; new switch
          -IncludeSystemFolders exports them anyway
        - Import no longer tries to set permissions on the hidden datacenter
          root folders - vCenter refuses that ('Operation not allowed on
          sub-entity'); they are counted and listed in the log file
        - Objects whose name occurs more than once in the target count as
          already in place when one of them sits in the exported folder,
          instead of being skipped as ambiguous

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
    [string[]]$Datacenter = @(),

    [Parameter(Mandatory = $false)]
    [string]$ExportFile = '',

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSystemFolders,

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

$scriptVersion = '1.4.0'
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

if ($ExportFile -and $Mode -and $Mode -ne 'Import') {
    Write-Host '  [WARN] -ExportFile is only applied in Import mode and will be ignored.' -ForegroundColor Yellow
}

# Folder type -> datacenter root folder property and the object types that can
# live in that tree (and that this script records and moves)
$folderTypeMap = [ordered]@{
    VM        = @{ RootProperty = 'VmFolder';        MemberTypes = @('VirtualMachine') }
    Host      = @{ RootProperty = 'HostFolder';      MemberTypes = @('ClusterComputeResource', 'ComputeResource') }
    Datastore = @{ RootProperty = 'DatastoreFolder'; MemberTypes = @('Datastore', 'StoragePod') }
    Network   = @{ RootProperty = 'NetworkFolder';   MemberTypes = @('VmwareDistributedVirtualSwitch') }
}

# Top-level folders created and managed by vCenter (vCLS), the Supervisor
# (Namespaces: vSphere Pods, VKS nodes) and NSX (segments, VPCs). Skipped on
# export unless -IncludeSystemFolders. Names as seen on VCF 9.1.1.
$systemFolders = @{
    VM        = @('vCLS', 'Namespaces')
    Host      = @()
    Datastore = @()
    Network   = @('NSX Managed Folders', 'Virtual Private Clouds')
}

# --- PowerCLI Module Check ----------------------------------------------------
# The script needs only VMware.VimAutomation.Core (and what it requires), not
# the whole VCF.PowerCLI bundle. Loading problems almost always come from the
# jump host (several PowerCLI versions side by side, an old one already loaded
# in the session, an incomplete or blocked offline install); the fix belongs
# there, so the script only explains what it found and where to read on.
$jumpHostGuide = 'https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/'

function Stop-ModuleLoadFailure {
    param([string]$Reason)
    Write-Host '  [ERROR] Could not load PowerCLI (VMware.VimAutomation.Core).' -ForegroundColor Red
    if ($Reason) { Write-Host "          $Reason" -ForegroundColor Red }
    Write-Host '          Start a clean session with "pwsh -NoProfile" and run the script first.' -ForegroundColor Yellow
    Write-Host '          Keep one complete, unblocked PowerCLI version on this host; see the jump-host' -ForegroundColor Yellow
    Write-Host "          guide, section 4 (completeness check) and 6 (pitfalls): $jumpHostGuide" -ForegroundColor Yellow
    $loaded = @(Get-Module -Name VMware.*, VCF.PowerCLI)
    if ($loaded.Count -gt 0) {
        Write-Host '          Loaded now:' -ForegroundColor Yellow
        $loaded | Sort-Object Name | ForEach-Object {
            Write-Host "            $($_.Name) $($_.Version)  ($($_.ModuleBase))" -ForegroundColor Yellow
        }
    }
    exit 1
}
function Get-ShortError {
    param($ErrorRecord)
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    return $m
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Host '  [ERROR] No PowerCLI found (VMware.VimAutomation.Core is not installed).' -ForegroundColor Red
    Write-Host '          Install-Module -Name VCF.PowerCLI -Scope CurrentUser' -ForegroundColor Yellow
    Write-Host "          Without internet access: $jumpHostGuide (section 3)" -ForegroundColor Yellow
    exit 1
}

# All VMware.VimAutomation.* modules of one PowerCLI release share one version
# (13.5.1.x for VCF.PowerCLI 9.1.1); StorageUtility is versioned on its own.
$loadedVersions = @(Get-Module -Name VMware.VimAutomation.* |
    Where-Object { $_.Name -ne 'VMware.VimAutomation.StorageUtility' } |
    ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
if ($loadedVersions.Count -gt 1) {
    Stop-ModuleLoadFailure -Reason "PowerCLI modules of different versions are already loaded in this session ($($loadedVersions -join ', '))."
}

try {
    Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
}
catch {
    Stop-ModuleLoadFailure -Reason (Get-ShortError $_)
}
Write-Host "  [INFO] PowerCLI $(@(Get-Module -Name VMware.VimAutomation.Core)[0].Version) loaded." -ForegroundColor Cyan

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

# --- Run results (#10, as VDSPortGroupManager #20) --------------------------------
# Every datacenter, folder, object or permission that fails is logged as an
# ERROR (red) and collected, so the summary names them with the reason and the
# run ends with exit code 1 (0 = no failures, 2 = stopped for lack of console
# input).
$script:RunFailures = [System.Collections.Generic.List[object]]::new()

function Get-FailReason {
    # The vCenter message without PowerShell's wrapper: 'Exception calling
    # "CreateDVPortgroup" with "1" argument(s): "..."', or PowerCLI's
    # tab-separated 'timestamp<TAB>cmdlet<TAB>detail'.
    param($ErrorRecord)
    $m = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { "$($ErrorRecord.Exception.Message)" } else { "$ErrorRecord" }
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    if ($m -match '^Exception calling "[^"]+" with "\d+" argument\(s\): "(.*)"$') { $m = $Matches[1] }
    return $m.Trim()
}

function Add-RunFailure {
    param([string]$Action, [string]$Name, [string]$Reason)
    $script:RunFailures.Add([pscustomobject]@{ Action = $Action; Name = $Name; Reason = $Reason })
    Write-Log "FAILED $($Action.ToLower()) '$Name': $Reason" -Level ERROR
}

function Write-RunSummary {
    # One summary line, coloured by outcome, then the failures of these actions.
    param([string]$Line, [int]$Failed, [int]$Skipped = 0, [string[]]$Actions = @())
    $level = if ($Failed -gt 0) { 'ERROR' } elseif ($Skipped -gt 0) { 'WARNING' } else { 'SUCCESS' }
    Write-Log $Line -Level $level
    $mine = @($script:RunFailures | Where-Object { $Actions -contains $_.Action })
    if ($mine.Count -gt 0) {
        Write-Log "  Failed ($($mine.Count)):" -Level ERROR
        foreach ($f in $mine) { Write-Log "    - $($f.Name): $($f.Reason)" -Level ERROR }
    }
}

# --- Progress (#12) -------------------------------------------------------------
# A progress bar per long step: "12 of 637: name", percentage and time left.
# Updated at most every 250 ms, so thousands of items don't slow the run down;
# Complete-Progress removes the bar. Id 1 is the outer step, Id 2 the items
# inside it. The log file is unchanged.
$script:ProgressState = @{}
function Show-Progress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Total,
        [string]$Item = '',
        [int]$Id = 1,
        [int]$ParentId = -1
    )
    if ($Total -le 0) { return }
    $now = [DateTime]::UtcNow
    if (-not $script:ProgressState.ContainsKey($Id) -or $Index -le 1) {
        $script:ProgressState[$Id] = @{ Start = $now; Last = [DateTime]::MinValue }
    }
    $st = $script:ProgressState[$Id]
    if ($Index -gt 1 -and $Index -lt $Total -and ($now - $st.Last).TotalMilliseconds -lt 250) { return }
    $st.Last = $now
    $p = @{
        Id              = $Id
        Activity        = $Activity
        Status          = "$Index of $Total$(if ($Item) { ": $Item" })"
        PercentComplete = [Math]::Min(100, [int](100 * ($Index - 1) / $Total))
    }
    if ($Index -gt 1) {
        $perItem = ($now - $st.Start).TotalSeconds / ($Index - 1)
        $p.SecondsRemaining = [int]($perItem * ($Total - $Index + 1))
    }
    if ($ParentId -ge 0) { $p.ParentId = $ParentId }
    Write-Progress @p
}

function Complete-Progress {
    param([int]$Id = 1)
    $null = $script:ProgressState.Remove($Id)
    Write-Progress -Id $Id -Activity 'Done' -Completed
}

# --- Menu Functions -------------------------------------------------------------
# Long lists: above $PickerListMax items the picker shows a count and a few
# examples and asks for a filter first; above $PickerEchoMax selected items
# the confirmation shows the count plus the first and last few (#4).
$PickerListMax = 50
$PickerEchoMax = 20

# Words that abort a picker or prompt (#13); -in is case-insensitive.
$CancelWords = @('cancel', 'exit', 'quit', 'q')
function Test-CancelInput {
    param([string]$Text)
    return ($Text -in $CancelWords)
}

# Every prompt goes through Read-Input (#11): without console input (a
# scheduled task, CI, pwsh -NonInteractive, redirected stdin) Read-Host
# throws or returns $null; stop with a clear message instead of a
# null-valued-expression error.
function Stop-NoConsoleInput {
    param([string]$Prompt)
    Write-Host "`n  [ERROR] No console input available (unattended run?). The script asked: $($Prompt.Trim())" -ForegroundColor Red
    Write-Host '  Pass the choices as parameters instead: -Mode, -Datacenter and -FolderType, plus' -ForegroundColor Yellow
    Write-Host '  -ExportFile, -MoveObjects and -ApplyPermissions for Import (-MoveObjects:$false to' -ForegroundColor Yellow
    Write-Host '  say no). Save the credential first with one interactive run.' -ForegroundColor Yellow
    $conn = Get-Variable -Name viConn -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($conn) { Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue }
    exit 2
}

function Read-Input {
    param([string]$Prompt, [switch]$AsSecureString)
    try {
        $value = if ($AsSecureString) { Read-Host $Prompt -AsSecureString } else { Read-Host $Prompt }
    }
    catch {
        $value = $null
    }
    if ($null -eq $value) { Stop-NoConsoleInput -Prompt $Prompt }
    if ($AsSecureString) { return $value }
    return $value.Trim()
}

function Write-ItemList {
    param([array]$Items, [string]$DisplayProperty, [switch]$Full)
    $width = "$($Items.Count)".Length
    $fmt   = '  [{0,' + $width + '}]  {1}'
    if ($Full -or $Items.Count -le $PickerListMax) {
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
        return
    }
    for ($i = 0; $i -lt 5; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
    Write-Host ('  ' + (' ' * ($width + 2)) + "  ... $($Items.Count - 10) more ...") -ForegroundColor DarkGray
    for ($i = $Items.Count - 5; $i -lt $Items.Count; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
    Write-Host "`n  $($Items.Count) items: too many to list. Narrow the list with a filter, or type 'list' to show them all." -ForegroundColor Yellow
}

function Write-SelectionSummary {
    param([array]$Selected, [string]$DisplayProperty)
    Write-Host "`n  Selected $($Selected.Count) item(s):" -ForegroundColor Green
    if ($Selected.Count -le $PickerEchoMax) {
        $Selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
    }
    else {
        $Selected[0..4] | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host "    ... $($Selected.Count - 10) more ..." -ForegroundColor DarkGray
        $Selected[($Selected.Count - 5)..($Selected.Count - 1)] | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
    }
    Write-Host ''
}

function Select-ItemsByName {
    # Non-interactive selection (-Datacenter): every item
    # whose name matches one of the patterns (names or wildcards, -like).
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$NameProperty,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [string]$What = 'item'
    )
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in $Patterns) {
        $hits = @($Items | Where-Object { $_.$NameProperty -like $pattern })
        if ($hits.Count -eq 0) {
            Write-Log "No $What matches '$pattern'." -Level WARNING
        }
        foreach ($hit in $hits) { if (-not $selected.Contains($hit)) { $selected.Add($hit) } }
    }
    if ($selected.Count -gt 0) {
        Write-Log "Selected $($selected.Count) $What(s) by name: $($Patterns -join ', ')"
        Write-SelectionSummary -Selected @($selected) -DisplayProperty $DisplayProperty
    }
    return @($selected)
}

function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title,
        # Property the filter matches on (defaults to the display text)
        [string]$NameProperty = ''
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return @()
    }
    if (-not $NameProperty) { $NameProperty = $DisplayProperty }
    $view   = $Items
    $filter = ''
    Write-Host "`n  $Title" -ForegroundColor Cyan
    Write-ItemList -Items $view -DisplayProperty $DisplayProperty
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select every item shown, or 'cancel' (or exit, quit, q) to abort." -ForegroundColor Gray
    Write-Host "  Filter by name: a wildcard (e.g. *DC01*) or /text for a substring; 'reset' clears" -ForegroundColor Gray
    Write-Host "  the filter, 'list' shows every item in the current list.`n" -ForegroundColor Gray
    while ($true) {
        $prompt    = if ($filter) { "  Your selection (filter: $filter, $($view.Count) shown)" } else { '  Your selection' }
        $userInput = Read-Input $prompt
        if (Test-CancelInput $userInput) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'list') {
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full
            continue
        }
        if ($userInput -eq 'reset' -or ($userInput -eq '' -and $filter)) {
            $view = $Items; $filter = ''
            Write-Host "`n  Filter cleared: $($view.Count) item(s)." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -match '[*?]' -or $userInput.StartsWith('/')) {
            $pattern = if ($userInput.StartsWith('/')) { '*' + [WildcardPattern]::Escape($userInput.Substring(1)) + '*' } else { $userInput }
            $hits    = @($Items | Where-Object { $_.$NameProperty -like $pattern })
            if ($hits.Count -eq 0) {
                Write-Host "  Nothing matches '$userInput'; the list is unchanged." -ForegroundColor Yellow
                continue
            }
            $view = $hits; $filter = $userInput
            Write-Host "`n  Filter '$filter': $($view.Count) of $($Items.Count) item(s), renumbered." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -eq '') { continue }
        if ($userInput -eq 'all') {
            if ($view.Count -gt $PickerListMax -and -not $filter) {
                Write-Host "  'all' selects all $($view.Count) item(s)." -ForegroundColor Yellow
            }
            Write-SelectionSummary -Selected $view -DisplayProperty $DisplayProperty
            return $view
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
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, 'all', or a filter (*text* or /text)." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $view.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($view.Count)." -ForegroundColor Red
            continue
        }
        $selected = @($selectedIndices | ForEach-Object { $view[$_ - 1] })
        Write-SelectionSummary -Selected $selected -DisplayProperty $DisplayProperty
        return $selected
    }
}

function Select-SingleItem {
    # One item. With -Filter the list can be narrowed like the multi picker
    # (wildcard or /text, 'reset', 'list'); used for the export file list,
    # which grows with every export (#10).
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title,
        [switch]$Filter
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return $null
    }
    $view = $Items
    $flt  = ''
    Write-Host "`n  $Title" -ForegroundColor Cyan
    if ($Filter) { Write-ItemList -Items $view -DisplayProperty $DisplayProperty }
    else { Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full }
    Write-Host "`n  Enter a number to select one item, or 'cancel' (or exit, quit, q) to abort." -ForegroundColor Gray
    if ($Filter) {
        Write-Host "  Filter by name: a wildcard (e.g. *DC01*) or /text for a substring; 'reset' clears" -ForegroundColor Gray
        Write-Host "  the filter, 'list' shows every item in the current list." -ForegroundColor Gray
    }
    Write-Host ''
    while ($true) {
        $prompt    = if ($flt) { "  Your selection (filter: $flt, $($view.Count) shown)" } else { '  Your selection' }
        $userInput = Read-Input $prompt
        if (Test-CancelInput $userInput) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if ($Filter -and $userInput -eq 'list') {
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full
            continue
        }
        if ($Filter -and ($userInput -eq 'reset' -or ($userInput -eq '' -and $flt))) {
            $view = $Items; $flt = ''
            Write-Host "`n  Filter cleared: $($view.Count) item(s)." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($Filter -and ($userInput -match '[*?]' -or $userInput.StartsWith('/'))) {
            $pattern = if ($userInput.StartsWith('/')) { '*' + [WildcardPattern]::Escape($userInput.Substring(1)) + '*' } else { $userInput }
            $hits    = @($Items | Where-Object { $_.$DisplayProperty -like $pattern })
            if ($hits.Count -eq 0) {
                Write-Host "  Nothing matches '$userInput'; the list is unchanged." -ForegroundColor Yellow
                continue
            }
            $view = $hits; $flt = $userInput
            Write-Host "`n  Filter '$flt': $($view.Count) of $($Items.Count) item(s), renumbered." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $view.Count) {
                $selected = $view[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($view.Count)." -ForegroundColor Red
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

# --- Backup Directory (#10, as VDSPortGroupManager #18) ---------------------------
# Interactive runs ask where the exports are (Import) or go (Export): Enter
# keeps the default, B opens the Windows folder browser, or type a path. No
# prompt when -BackupDirectory is given, or when the run is unattended
# (-Datacenter for Export, -ExportFile for Import).
function Test-FolderDialogAvailable {
    if (-not $IsWindows) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; return $true }
    catch { return $false }
}

function Select-FolderDialog {
    param([string]$Description, [string]$StartPath)
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.UseDescriptionForTitle = $true
    $dialog.ShowNewFolderButton = $true
    if ($StartPath -and (Test-Path -Path $StartPath -PathType Container)) { $dialog.SelectedPath = (Resolve-Path $StartPath).Path }
    # A hidden top-most owner keeps the dialog in front of the console window.
    $owner = [System.Windows.Forms.Form]::new()
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.WindowState = 'Minimized'
    try {
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    finally {
        $dialog.Dispose()
        $owner.Dispose()
    }
}

function Get-BackupCount {
    param([string]$Path)
    return @(Get-ChildItem -Path $Path -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}

$askBackupDir = -not $PSBoundParameters.ContainsKey('BackupDirectory') -and (
    ($Mode -eq 'Export' -and $Datacenter.Count -eq 0) -or
    ($Mode -eq 'Import' -and -not $ExportFile))

if ($askBackupDir) {
    $canBrowse = Test-FolderDialogAvailable
    $purpose   = if ($Mode -eq 'Import') { 'to import from' } else { 'to export to' }
    while ($true) {
        Write-Host "`n  Backup directory ${purpose}:" -ForegroundColor Cyan
        Write-Host "    $BackupDirectory"
        if ($Mode -eq 'Import' -and (Test-Path -Path $BackupDirectory -PathType Container)) {
            Write-Host "    ($(Get-BackupCount $BackupDirectory) export(s) here)" -ForegroundColor DarkGray
        }
        $hint = if ($canBrowse) { "  [Enter] use it, [B] browse, or type a path ('q' to quit)" } else { "  [Enter] use it, or type a path ('q' to quit)" }
        $answer = Read-Input $hint
        if (Test-CancelInput $answer) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            exit 0
        }

        $candidate = $BackupDirectory
        if ($canBrowse -and $answer -match '^[Bb]$') {
            $desc = if ($Mode -eq 'Import') { 'Select the folder with the folder exports (.json)' } else { 'Select the folder for the folder exports' }
            $picked = Select-FolderDialog -Description $desc -StartPath $BackupDirectory
            if (-not $picked) { Write-Host '  No folder chosen.' -ForegroundColor Yellow; continue }
            $candidate = $picked
        }
        elseif ($answer) {
            $candidate = $answer.Trim('"', "'")
        }

        if ($Mode -eq 'Import') {
            if (-not (Test-Path -Path $candidate -PathType Container)) {
                Write-Host "  Folder not found: $candidate" -ForegroundColor Red
                continue
            }
            $count = Get-BackupCount $candidate
            if ($count -eq 0) {
                Write-Host "  No exports (.json) in $candidate. Choose another folder." -ForegroundColor Red
                $BackupDirectory = $candidate
                continue
            }
            Write-Host "  [OK]   $count export(s) in $candidate." -ForegroundColor Green
        }
        elseif (Test-Path -Path $candidate -PathType Leaf) {
            Write-Host "  That is a file, not a folder: $candidate" -ForegroundColor Red
            continue
        }
        $BackupDirectory = $candidate
        break
    }
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
    $credUser   = Read-Input "  Username for $vCenterServer"
    $credPass   = Read-Input '  Password' -AsSecureString
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

function Stop-UnknownDatacenter {
    # -Datacenter matched nothing: stop with the list, like -VDSwitchName in VDSPortGroupManager
    param([string]$Name, [array]$Views)
    Write-Log "Datacenter '$Name' not found on $vCenterServer. Datacenters: $(@($Views | ForEach-Object { $_.Name }) -join ', ')" -Level ERROR
    Disconnect-VIServer -Server $viConn -Confirm:$false
    exit 1
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
                # Top-level folders that vCenter, the Supervisor or NSX create and manage
                if ($SkipSystemFolders -and $node.Path.Count -eq 0 -and @($systemFolders[$Type]) -contains $childName) {
                    Write-Log "Skipped system folder '$Type`:/$childName' and everything below it (managed by vCenter/Supervisor/NSX; use -IncludeSystemFolders to export it)."
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
    $dcViews = @(Get-DatacenterViews)
    $dcItems = @($dcViews | ForEach-Object { [pscustomobject]@{ Label = $_.Name; Name = $_.Name; Item = $_ } })
    $dcChoices = if ($Datacenter.Count -gt 0) {
        Select-ItemsByName -Items $dcItems -NameProperty 'Name' -DisplayProperty 'Label' -Patterns $Datacenter -What 'datacenter'
    } else {
        Select-MultipleItems -Items $dcItems -DisplayProperty 'Label' -Title 'Select datacenter(s) to EXPORT'
    }
    if ($Datacenter.Count -gt 0 -and @($dcChoices).Count -eq 0) {
        Stop-UnknownDatacenter -Name ($Datacenter -join ', ') -Views $dcViews
    }
    $types = if ($FolderType.Count -gt 0) { $FolderType } else { Select-FolderTypes }
    $exportOk = 0

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

        $dcNo = 0
        foreach ($dcChoice in $dcChoices) {
            $dcView = $dcChoice.Item
            $dcNo++
            Write-Log "Exporting datacenter '$($dcView.Name)' (folder types: $($types -join ', ')) ..."
            try {
                $index       = Get-FolderIndex -DatacenterView $dcView
                $typeResults = @()
                $typeNo      = 0
                foreach ($t in $types) {
                    $typeNo++
                    Show-Progress -Id 1 -Activity "Export of datacenter '$($dcView.Name)' ($dcNo of $(@($dcChoices).Count))" -Index $typeNo -Total @($types).Count -Item "$t folders"
                    $rootRef = $dcView.($folderTypeMap[$t].RootProperty)
                    $tree    = Get-FolderTree -RootMoRef $rootRef -Index $index -Type $t -SkipSystemFolders:(-not $IncludeSystemFolders)

                    # Resolve member names in one call
                    $nameById = @{}
                    if ($tree.Members.Count -gt 0) {
                        $refs = [VMware.Vim.ManagedObjectReference[]]@($tree.Members | ForEach-Object { $_.MoRef })
                        foreach ($v in @(Get-View -Server $viConn -Id $refs -Property Name)) {
                            $nameById[$v.MoRef.Value] = $v.Name
                        }
                    }

                    # One permission call per folder: the slow part with hundreds of folders
                    $fNo = 0; $fTotal = $tree.Folders.Count
                    $folderEntries = @($tree.Folders | ForEach-Object {
                        $fNo++
                        Show-Progress -Id 2 -ParentId 1 -Activity "Reading $t folders and their permissions" -Index $fNo -Total $fTotal -Item (Format-Path $_.Path)
                        [pscustomobject]@{
                            Path        = @($_.Path)
                            Permissions = (Get-FolderPermissions -MoRef $_.MoRef -RoleNameById $roleNameById)
                        }
                    })
                    Complete-Progress -Id 2
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
                $exportOk++
            }
            catch {
                Add-RunFailure -Action 'Export' -Name $dcView.Name -Reason (Get-FailReason $_)
            }
            Complete-Progress -Id 2
            Complete-Progress -Id 1
        }
        $exportFail = @($script:RunFailures | Where-Object { $_.Action -eq 'Export' }).Count
        Write-RunSummary -Line "Export complete: $exportOk datacenter(s) exported, $exportFail failed." -Failed $exportFail -Actions 'Export'
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
    $allJson = @(Get-ChildItem -Path $BackupDirectory -Filter '*.json' -File | Sort-Object Name)
    $fileChoice = $null
    if ($ExportFile) {
        # Unattended: a name or wildcard, with or without .json; the newest match wins
        $pattern = if ($ExportFile -like '*.json') { $ExportFile } else { "$ExportFile.json" }
        $hits = @($allJson | Where-Object { $_.Name -like $pattern } | Sort-Object LastWriteTime -Descending)
        if ($hits.Count -eq 0) {
            Write-Log "No export matches '$ExportFile' in '$BackupDirectory'." -Level ERROR
            Disconnect-VIServer -Server $viConn -Confirm:$false
            exit 1
        }
        $fileChoice = $hits[0]
        if ($hits.Count -gt 1) {
            Write-Log "'$ExportFile' matches $($hits.Count) exports; using the newest: $($fileChoice.Name)" -Level WARNING
        }
    }
    elseif ($allJson.Count -eq 0) {
        Write-Log "No .json files found in '$BackupDirectory'. Nothing to import." -Level WARNING
    }
    else {
        $fileItems  = @($allJson | ForEach-Object { [pscustomobject]@{ Label = $_.Name; Name = $_.Name; Item = $_ } })
        $fileChoice = Select-SingleItem -Items $fileItems -DisplayProperty 'Label' -Title 'Select folder export to IMPORT' -Filter
        if ($fileChoice) { $fileChoice = $fileChoice.Item }
    }

    $data = $null
    if ($fileChoice) {
        try {
            $data = Get-Content -Path $fileChoice.FullName -Raw | ConvertFrom-Json
            if (-not ($data.PSObject.Properties.Name -contains 'Tool') -or $data.Tool -ne 'VIFolderManager') {
                Add-RunFailure -Action 'Read' -Name $fileChoice.Name -Reason 'not a VIFolderManager export'
                $data = $null
            }
        } catch {
            Add-RunFailure -Action 'Read' -Name $fileChoice.Name -Reason $_.Exception.Message
            $data = $null
        }
    }

    if ($data) {
        Write-Log "Export file: $($fileChoice.Name) (datacenter '$($data.Datacenter)' on $($data.SourceVCenter), exported $($data.ExportedAt))"

        # Target datacenter
        $dcViews = @(Get-DatacenterViews)
        $dcItems = @($dcViews | ForEach-Object {
            $mark = if ($_.Name -eq $data.Datacenter) { '  [same name as export]' } else { '' }
            [pscustomobject]@{ Label = "$($_.Name)$mark"; Item = $_ }
        })
        if ($Datacenter.Count -gt 0) {
            if ($Datacenter.Count -gt 1) { Write-Log "Import goes into one datacenter; using '$($Datacenter[0])'." -Level WARNING }
            $dcChoice = @($dcItems | Where-Object { $_.Item.Name -eq $Datacenter[0] })[0]
            if (-not $dcChoice) { Stop-UnknownDatacenter -Name $Datacenter[0] -Views $dcViews }
        } else {
            $dcChoice = Select-SingleItem -Items $dcItems -DisplayProperty 'Label' -Title 'Select datacenter to IMPORT into'
        }

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
                $MoveObjects = [switch]((Read-Input '  Move existing objects (VMs, hosts, datastores, switches) into their exported folder? (y/N)') -match '^[Yy]')
            }
            if (-not $PSBoundParameters.ContainsKey('ApplyPermissions')) {
                $ApplyPermissions = [switch]((Read-Input '  Re-apply folder permissions? (y/N)') -match '^[Yy]')
            }
            Write-Log "Move objects: $([bool]$MoveObjects); apply permissions: $([bool]$ApplyPermissions); dry run: $([bool]$DryRun)"

            # A fully parameterised import (#10) runs without the Proceed question
            $unattended = $ExportFile -and $Datacenter.Count -gt 0 -and $FolderType.Count -gt 0 -and
                $PSBoundParameters.ContainsKey('MoveObjects') -and $PSBoundParameters.ContainsKey('ApplyPermissions')
            $proceed = $true
            if ($unattended -and -not $DryRun) {
                Write-Log 'Unattended import (all choices given as parameters): no Proceed question.'
            }
            elseif (-not $DryRun) {
                $answer = Read-Input "  Proceed with changes in datacenter '$($targetDc.Name)'? (y/N)"
                if ($answer -notmatch '^[Yy]') {
                    Write-Log 'Import cancelled by user.' -Level WARNING
                    $proceed = $false
                }
            }

            if ($proceed) {
                $stats = @{ Created = 0; Existing = 0; FolderFail = 0; Moved = 0; InPlace = 0; NotFound = 0; Ambiguous = 0; NotMovable = 0; MoveSkip = 0; MoveFail = 0; PermSet = 0; PermPresent = 0; PermSkip = 0; PermFail = 0; PermRoot = 0 }

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
                            Add-RunFailure -Action 'Create folder' -Name "$t`:$(Format-Path $prefix)" -Reason (Get-FailReason $_)
                            $stats.FolderFail++
                            $PathMap[$key] = $null
                            return $null
                        }
                    }
                    return $current
                }

                $typeNo = 0
                foreach ($t in $types) {
                    $typeNo++
                    Show-Progress -Id 1 -Activity "Import into datacenter '$($targetDc.Name)'" -Index $typeNo -Total @($types).Count -Item "$t folders"
                    $typeData = @($data.FolderTypes | Where-Object { $_.Type -eq $t })[0]
                    Write-Log "--- $t folders ---"

                    # Existing folder tree in the target, keyed by path
                    $rootRef  = $targetDc.($folderTypeMap[$t].RootProperty)
                    $existing = Get-FolderTree -RootMoRef $rootRef -Index $targetIndex -Type $t
                    $pathMap  = New-Object 'System.Collections.Generic.Dictionary[string,object]'
                    foreach ($f in $existing.Folders) { $pathMap[(Get-PathKey $f.Path)] = $f.MoRef }

                    # 1. Folders (parents first)
                    $folderEntries = @($typeData.Folders | Sort-Object { (ConvertTo-PathArray $_.Path).Count })
                    $fNo = 0
                    foreach ($f in $folderEntries) {
                        $fNo++
                        $path = ConvertTo-PathArray $f.Path
                        Show-Progress -Id 2 -ParentId 1 -Activity "$t folders" -Index $fNo -Total $folderEntries.Count -Item (Format-Path $path)
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
                        $members = @($typeData.Members)
                        $mNo = 0
                        foreach ($m in $members) {
                            $mNo++
                            Show-Progress -Id 2 -ParentId 1 -Activity "Moving objects into their $t folders" -Index $mNo -Total $members.Count -Item $m.Name
                            $path = ConvertTo-PathArray $m.Path
                            $k    = "$($m.Type)|$($m.Name)"
                            if (-not $objIndex.ContainsKey($k)) {
                                $stats.NotFound++
                                Write-Log "Not found in target: $($m.Type) '$($m.Name)'" -FileOnly
                                continue
                            }
                            $candidates = $objIndex[$k]
                            if ($candidates.Count -gt 1) {
                                # Same name in several folders: fine if one of them already sits in the exported folder
                                $pathKey = Get-PathKey $path
                                if ($pathMap.ContainsKey($pathKey) -and $pathMap[$pathKey] -isnot [string] -and $null -ne $pathMap[$pathKey]) {
                                    $targetValue = $pathMap[$pathKey].Value
                                    if (@($candidates | Where-Object { $null -ne $_.Parent -and $_.Parent.Value -eq $targetValue }).Count -gt 0) {
                                        $stats.InPlace++
                                        continue
                                    }
                                }
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
                                $stats.MoveSkip++
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
                                Add-RunFailure -Action 'Move' -Name "$($m.Type) '$($m.Name)' to $(Format-Path $path)" -Reason (Get-FailReason $_)
                                $stats.MoveFail++
                            }
                        }
                    }

                    # 3. Permissions
                    if ($ApplyPermissions) {
                        $pNo = 0
                        foreach ($f in $folderEntries) {
                            $pNo++
                            Show-Progress -Id 2 -ParentId 1 -Activity "Permissions on $t folders" -Index $pNo -Total $folderEntries.Count -Item (Format-Path (ConvertTo-PathArray $f.Path))
                            $perms = @($f.Permissions | Where-Object { $null -ne $_ })
                            if ($perms.Count -eq 0) { continue }
                            $path   = ConvertTo-PathArray $f.Path
                            if ($path.Count -eq 0) {
                                # vCenter refuses SetEntityPermissions on the hidden datacenter root
                                # folders ("Operation not allowed on sub-entity"); these are usually
                                # Supervisor service accounts anyway
                                $stats.PermRoot += $perms.Count
                                foreach ($p in $perms) { Write-Log "Skipped permission $($p.Principal) as '$($p.Role)' on the hidden $t root folder (not settable via the API)." -FileOnly }
                                continue
                            }
                            $target = Resolve-TargetFolder -Path $path -PathMap $pathMap
                            if ($null -eq $target) {
                                # The folder could not be created; that failure is already listed
                                $stats.PermSkip += $perms.Count
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
                                    $stats.PermSkip++
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
                                    Add-RunFailure -Action 'Set permission' -Name $label -Reason "$(Get-FailReason $_) (check that the principal exists in this vCenter's identity source)"
                                    $stats.PermFail++
                                }
                            }
                        }
                    }
                }

                Complete-Progress -Id 2
                Complete-Progress -Id 1

                # Summaries (#10): red with failures, yellow with only skips, green otherwise.
                # Objects not found in the target are normal during a migration (not moved
                # yet), so they don't colour the line; they are listed in the log file.
                $verb = if ($DryRun) { 'would be ' } else { '' }
                Write-RunSummary -Line "Folders: $($stats.Created) ${verb}created, $($stats.Existing) already present, $($stats.FolderFail) failed." `
                    -Failed $stats.FolderFail -Actions 'Create folder'
                if ($MoveObjects) {
                    Write-RunSummary -Line "Objects: $($stats.Moved) ${verb}moved, $($stats.InPlace) already in place, $($stats.NotFound) not found in target, $($stats.Ambiguous) ambiguous name, $($stats.NotMovable) not directly in a folder, $($stats.MoveSkip) skipped (folder missing), $($stats.MoveFail) failed." `
                        -Failed $stats.MoveFail -Skipped ($stats.Ambiguous + $stats.NotMovable + $stats.MoveSkip) -Actions 'Move'
                    if ($stats.NotFound -gt 0) { Write-Log 'Objects not found in the target are listed in the log file.' }
                }
                if ($ApplyPermissions) {
                    Write-RunSummary -Line "Permissions: $($stats.PermSet) ${verb}set, $($stats.PermPresent) already present, $($stats.PermRoot) on hidden root folders skipped (listed in the log file), $($stats.PermSkip) skipped (role or folder missing), $($stats.PermFail) failed." `
                        -Failed $stats.PermFail -Skipped $stats.PermSkip -Actions 'Set permission'
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
if ($script:RunFailures.Count -gt 0) {
    Write-Log "===== Script finished with $($script:RunFailures.Count) failure(s); see the summary above =====" -Level ERROR
    Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
    exit 1
}
Write-Log '===== Script finished =====' -Level SUCCESS
Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
