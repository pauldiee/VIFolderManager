#Requires -Version 5.1

<#
.SYNOPSIS
    Turns a VIFolderManager target placement list into an HTML page for the
    operator who picks the destination folder per VM in HCX.

.DESCRIPTION
    Reads the target placement list that Invoke-VIFolderManager.ps1 writes on
    an import with -Csv (<export>_target-<datacenter>.csv) and writes one
    self-contained HTML page next to it (<list>_sheet.html). No vCenter
    connection is needed; the page works offline in any browser.

    The page has:
      - a search box (VM name or folder) that filters every view;
      - Per folder: every destination folder as a path from the datacenter,
        with its folder ID on the target vCenter, its VM count and its VMs;
      - Per VM: every VM A-Z with its destination folder;
      - Attention: folders that don't exist on the target yet, folder names
        that occur in more than one path, VM names that occur more than once,
        and VMs that belong in the datacenter root;
      - the time the list was written, so the operator sees how fresh it is.

    Make the list right before the operator starts: run the import on the
    target vCenter with -MoveObjects:$false -Csv (not as a dry run, so the
    folders exist and have an ID), then run this script on the CSV.

.PARAMETER Path
    The target placement list (<export>_target-<datacenter>.csv). When
    omitted, the newest *_target-*.csv in -BackupDirectory is used.

.PARAMETER BackupDirectory
    Where to look for the newest list when -Path is omitted. Default:
    Backups\ next to the script.

.PARAMETER FolderType
    Folder types to show. Default: VM (HCX migrates VMs). Pass VM, Host,
    Datastore, Network or a combination to show other types too.

.PARAMETER OutFile
    HTML file to write. Default: the list's name with _sheet.html, next to it.

.PARAMETER Title
    Page title. Default: "Destination folders - <datacenter>".

.EXAMPLE
    .\Invoke-VIFolderManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FolderType VM -MoveObjects:$false -ApplyPermissions:$false -Csv
    .\New-VIFolderPlacementSheet.ps1

    Creates the folders on the target, writes the target list, and turns the
    newest list in Backups\ into the HTML page.

.EXAMPLE
    .\New-VIFolderPlacementSheet.ps1 -Path D:\migration\Folders_DC01_2026-11-26_10-00-00_target-DC01.csv

.NOTES
    Script  : New-VIFolderPlacementSheet.ps1
    Version : 0.1.1
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Requires: PowerShell 5.1 or 7.x; no PowerCLI, no vCenter connection
    Tested  : PowerShell 7.6.10; target list from lab B (vCenter 9.0.2), 2026-11-26
    The page holds VM and folder names: keep it where you keep the export.
#>

<#
CHANGELOG
v0.1.1  2026-11-26  Paul van Dieen
    - Layout in the VIExportViewer house style: sticky header with the tabs,
      light/dark switch, one folder table with VM chips, paths below the
      datacenter, expand/collapse all, root VMs as chips (#25).

v0.1.0  2026-11-26  Paul van Dieen
    - First version (#25): search, per folder, per VM, attention list,
      list time, printable.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [string]$BackupDirectory,
    [ValidateSet('VM', 'Host', 'Datastore', 'Network')]
    [string[]]$FolderType = @('VM'),
    [string]$OutFile,
    [string]$Title
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptVersion = '0.1.1'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'

Write-Host ''
Write-Host "  New-VIFolderPlacementSheet $scriptVersion" -ForegroundColor Cyan
Write-Host "  $scriptAuthor - $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ''

# --- Find the list ---------------------------------------------------------
# Default set here: PowerShell 5.1 leaves $PSScriptRoot empty in a param default
if (-not $BackupDirectory) { $BackupDirectory = Join-Path $PSScriptRoot 'Backups' }
if (-not $Path) {
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        throw "No -Path given and '$BackupDirectory' does not exist."
    }
    $newest = Get-ChildItem -LiteralPath $BackupDirectory -Filter '*_target-*.csv' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        throw "No *_target-*.csv in '$BackupDirectory'. Run Invoke-VIFolderManager.ps1 -Mode Import -Csv first."
    }
    $Path = $newest.FullName
    Write-Host "  Newest list: $Path"
}
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "List not found: $Path" }
$listFile = Get-Item -LiteralPath $Path

$rows = @(Import-Csv -LiteralPath $listFile.FullName)
$required = 'FolderType', 'ObjectType', 'Name', 'Path', 'TargetFolderId', 'Note'
if ($rows.Count -gt 0) {
    $missing = @($required | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw ("'{0}' is not a target placement list (missing column(s): {1}). Use the list from -Mode Import -Csv, not the export's _placement.csv." -f $listFile.Name, ($missing -join ', '))
    }
}
$rows = @($rows | Where-Object { $FolderType -contains $_.FolderType })
if ($rows.Count -eq 0) { throw "No rows for folder type(s) $($FolderType -join ', ') in $($listFile.Name)." }

# Datacenter from the file name: <export>_target-<datacenter>.csv
$datacenter = ''
if ($listFile.Name -match '_target-(.+)\.csv$') { $datacenter = $Matches[1] }
if (-not $Title) { $Title = if ($datacenter) { "Destination folders - $datacenter" } else { 'Destination folders' } }
if (-not $OutFile) {
    $OutFile = Join-Path $listFile.DirectoryName ([System.IO.Path]::GetFileNameWithoutExtension($listFile.Name) + '_sheet.html')
}

# --- Build the data --------------------------------------------------------
$items = foreach ($r in $rows) {
    [pscustomobject]@{
        t  = $r.FolderType
        o  = $r.ObjectType
        n  = $r.Name
        p  = $r.Path
        id = $r.TargetFolderId
        nt = $r.Note
    }
}
$data = [pscustomobject]@{
    title      = $Title
    datacenter = $datacenter
    list       = $listFile.Name
    listTime   = $listFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    made       = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    tool       = "New-VIFolderPlacementSheet $scriptVersion"
    items      = @($items)
}
$json = ConvertTo-Json -InputObject $data -Depth 5 -Compress
# Keep the embedded block closed: no literal '<' (a name with </script>).
# The backslash is built in code; a literal escape in source can arrive as
# the character itself.
$bs = [string][char]92
$json = $json.Replace('<', $bs + 'u003c').Replace([string][char]0x2028, $bs + 'u2028').Replace([string][char]0x2029, $bs + 'u2029')

$template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Destination folders</title>
<style>
/* ITQ house style, the same tokens as VIExportViewer 0.2.0 (itq-design
   skill): Royal Blue text and surfaces, Orange for emphasis and the active
   tab, Light Blue as the soft secondary. No logos and nothing external: the
   page works offline, so the font is Titillium when installed, else Calibri. */
:root {
  --royal: #040559; --orange: #FF4F41; --lightblue: #CDE3F7;
  --bg: #F4F8FD; --panel: #FFFFFF; --text: #040559; --muted: #535353; --line: #E2E8F0;
  --head-bg: #040559; --head-text: #FFFFFF; --head-quiet: #CDE3F7;
  --accent: #FF4F41; --accent-soft: #FFE3E0; --soft: #E6F1FB; --group: #CDE3F7; --group-text: #040559; --group-quiet: #33437A;
  --vmbox: #FFFFFF; --chip: #F4F8FD; --chip-line: #CDE3F7; --dot: #FF4F41; --pill: #040559; --pill-text: #FFFFFF; --code: #FFFFFF;
  --warn: #CC3528; --warn-soft: #FFE3E0;
  --shadow-sm: 0 2px 6px rgba(4, 5, 90, 0.08); --shadow-md: 0 8px 24px rgba(4, 5, 90, 0.10);
  --focus: 0 0 0 3px rgba(255, 79, 65, 0.35);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #02032E; --panel: #0B0C4A; --text: #FFFFFF; --muted: #CDE3F7; --line: #2A2B6E;
    --head-bg: #040559; --soft: #1A1B5E; --group: #22247E; --group-text: #FFFFFF; --group-quiet: #CDE3F7;
    --vmbox: #0B0C4A; --chip: #02032E; --chip-line: #2F3190; --dot: #FF4F41; --pill: #CDE3F7; --pill-text: #040559; --code: #02032E; --accent-soft: #3A1A30;
    --warn: #FF8A80; --warn-soft: #3A1A30;
  }
}
:root[data-theme="dark"] {
  --bg: #02032E; --panel: #0B0C4A; --text: #FFFFFF; --muted: #CDE3F7; --line: #2A2B6E;
  --head-bg: #040559; --soft: #1A1B5E; --group: #22247E; --group-text: #FFFFFF; --group-quiet: #CDE3F7;
  --vmbox: #0B0C4A; --chip: #02032E; --chip-line: #2F3190; --dot: #FF4F41; --pill: #CDE3F7; --pill-text: #040559; --code: #02032E; --accent-soft: #3A1A30;
  --warn: #FF8A80; --warn-soft: #3A1A30;
}
* { box-sizing: border-box; }
html, body { margin: 0; }
body { background: var(--bg); color: var(--text); font: 15px/1.5 "Titillium", Calibri, "Segoe UI", sans-serif; }
header.app { position: sticky; top: 0; z-index: 5; background: var(--head-bg); color: var(--head-text); box-shadow: var(--shadow-md); }
.headrow, .bar, main, footer { max-width: 1240px; margin-left: auto; margin-right: auto; }
.headrow { display: flex; flex-wrap: wrap; gap: 14px; align-items: center; justify-content: space-between; padding: 14px 24px 10px; }
header.app h1 { font-size: 21px; font-weight: 700; margin: 0; letter-spacing: .2px; }
header.app .meta { color: var(--head-quiet); font-size: 13px; margin-top: 2px; }
header.app .meta b { color: var(--head-text); font-weight: 600; }
.tabs { display: flex; gap: 2px; background: rgba(255, 255, 255, .08); border-radius: 6px; padding: 3px; }
.tabs button { border: 0; background: transparent; color: var(--head-quiet); border-radius: 4px; padding: 6px 16px; font: inherit; font-weight: 600; cursor: pointer; transition: background .16s cubic-bezier(.4,0,.2,1), color .16s; }
.tabs button:hover { color: #fff; background: rgba(255, 255, 255, .08); }
.tabs button[aria-selected="true"] { background: var(--orange); color: #fff; }
.tabs .count { opacity: .85; font-size: 12px; font-weight: 400; margin-left: 5px; }
.right { display: flex; gap: 10px; align-items: center; }
.btn { border: 1px solid rgba(255, 255, 255, .45); background: transparent; color: #fff; border-radius: 6px; padding: 6px 12px; font: inherit; font-size: 13px; font-weight: 600; cursor: pointer; }
.btn:hover { background: rgba(255, 255, 255, .1); }
.btn:focus-visible, .tabs button:focus-visible, input:focus-visible, .grp:focus-visible { outline: none; box-shadow: var(--focus); }
.bar { display: flex; gap: 14px; flex-wrap: wrap; align-items: center; padding: 0 24px 12px; }
.bar input { flex: 1 1 320px; max-width: 480px; padding: 8px 12px; font: inherit; color: var(--royal);
  background: #fff; border: 1px solid transparent; border-radius: 6px; }
.stats { color: var(--head-quiet); font-size: 13px; }
.bar .link { background: none; border: 0; color: var(--head-quiet); font: inherit; font-size: 13px; cursor: pointer; text-decoration: underline; padding: 0; }
.bar .link:hover { color: #fff; }
main { padding: 20px 24px 40px; }
.note { background: var(--panel); border: 1px solid var(--line); border-left: 4px solid var(--orange); border-radius: 6px; padding: 10px 14px; margin: 0 0 16px; font-size: 14px; box-shadow: var(--shadow-sm); }
.sheet { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; box-shadow: var(--shadow-sm); overflow: hidden; }
.grp { display: grid; grid-template-columns: 18px minmax(0, 1fr) auto auto; gap: 12px; align-items: center;
  padding: 10px 16px 10px 12px; background: var(--group); color: var(--group-text); border-top: 1px solid var(--line);
  border-left: 4px solid var(--orange); cursor: pointer; user-select: none; }
.grp:hover { filter: brightness(1.04); }
.sheet > .grp:first-child { border-top: 0; }
.grp .tw { color: var(--group-quiet); font-size: 12px; }
.grp .crumb .up, .grp .crumb .sep { color: var(--group-quiet); }
.grp .flags { grid-column: 2 / -1; display: flex; gap: 6px; flex-wrap: wrap; }
.grp .flags:empty { display: none; }
.vmbox { display: flex; flex-wrap: wrap; gap: 8px; padding: 12px 16px 14px 46px; background: var(--vmbox); }
.vmbox[hidden] { display: none; }
.vm { background: var(--chip); border: 1px solid var(--chip-line); border-radius: 6px; padding: 3px 10px 3px 8px; font-size: 14px; white-space: nowrap; }
.vm::before { content: ""; display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: var(--dot); margin-right: 7px; vertical-align: 1px; }
.vm.dup { background: var(--warn-soft); border-color: var(--warn); color: var(--warn); font-weight: 600; }
.vm.dup::before { background: var(--warn); }
.vm.dup::after { content: " \00B7 duplicate name"; font-weight: 400; font-size: 12px; }
.crumb .up { color: var(--muted); }
.crumb .sep { color: var(--muted); margin: 0 6px; }
.crumb .leaf { font-weight: 700; }
.crumb .root { font-weight: 700; font-style: italic; }
.count-badge { background: var(--pill); color: var(--pill-text); border-radius: 999px; padding: 1px 10px; font-size: 12px; font-weight: 600; white-space: nowrap; }
.id { font-family: Consolas, "Cascadia Mono", monospace; font-size: 12px; background: var(--code); color: var(--text);
  border-radius: 4px; padding: 1px 7px; white-space: nowrap; }
.id.none { background: var(--warn-soft); color: var(--warn); }
.flag { background: var(--warn-soft); color: var(--warn); border-radius: 4px; padding: 1px 7px; font-size: 12px; font-weight: 600; }
.typ { background: var(--soft); border-radius: 4px; padding: 1px 7px; font-size: 12px; }
table { width: 100%; border-collapse: collapse; background: var(--panel); border: 1px solid var(--line);
  border-radius: 12px; overflow: hidden; box-shadow: var(--shadow-sm); }
th, td { text-align: left; padding: 8px 14px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { background: var(--group); color: var(--group-text); font-weight: 600; font-size: 13px; }
tr:last-child td { border-bottom: 0; }
tr:hover td { background: var(--soft); }
h2 { font-size: 17px; margin: 26px 0 4px; }
h2:first-child { margin-top: 0; }
.explain { color: var(--muted); font-size: 14px; margin: 0 0 10px; max-width: 900px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; box-shadow: var(--shadow-sm); }
.empty { color: var(--muted); padding: 18px 0; }
footer { color: var(--muted); font-size: 12px; padding: 0 24px 24px; }
[hidden] { display: none !important; }
@media print {
  :root, :root[data-theme="dark"] { --bg: #fff; --panel: #fff; --text: #040559; --muted: #535353; --line: #CDCDDF; --soft: #F4F8FD; --group: #E6F1FB; --group-text: #040559; --group-quiet: #535353; --vmbox: #fff; --chip: #fff; --chip-line: #CDCDDF; --pill: #040559; --pill-text: #fff; --code: #fff; }
  header.app { position: static; box-shadow: none; background: #fff; color: var(--text); border-bottom: 2px solid var(--royal); }
  header.app .meta, header.app .meta b { color: var(--text); }
  .tabs, .bar, .right { display: none; }
  .vmbox[hidden] { display: flex !important; }
  .sheet, table, .chips { box-shadow: none; }
  section[hidden] { display: block !important; }
  section { break-before: page; }
  section:first-of-type { break-before: auto; }
}
</style>
</head>
<body>
<header class="app">
  <div class="headrow">
    <div>
      <h1 id="title"></h1>
      <div class="meta" id="meta"></div>
    </div>
    <div class="right">
      <div class="tabs" role="tablist">
        <button role="tab" data-view="folders" aria-selected="true">Per folder<span class="count" id="c-folders"></span></button>
        <button role="tab" data-view="vms" aria-selected="false">Per VM<span class="count" id="c-vms"></span></button>
        <button role="tab" data-view="attention" aria-selected="false">Attention<span class="count" id="c-att"></span></button>
      </div>
      <button class="btn" id="theme" type="button" title="Switch light / dark"></button>
    </div>
  </div>
  <div class="bar">
    <input id="q" type="search" placeholder="Search VM or folder ..." autocomplete="off" aria-label="Search VM or folder">
    <span class="stats" id="stats"></span>
    <button class="link" id="toggle-all" type="button">Collapse all</button>
  </div>
</header>
<main>
  <section id="v-folders"></section>
  <section id="v-vms" hidden></section>
  <section id="v-attention" hidden></section>
</main>
<footer id="foot"></footer>
<script id="data" type="application/json">__DATA__</script>
<script>
(function () {
  var D = JSON.parse(document.getElementById('data').textContent);
  var items = D.items || [];
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function segs(p) { return (p || '/').split('/').filter(function (s) { return s !== ''; }); }
  function leaf(p) { var s = segs(p); return s.length ? s[s.length - 1] : ''; }
  function key(s) { return (s || '').toLowerCase(); }

  document.title = D.title;
  document.getElementById('title').textContent = D.title;
  var meta = document.getElementById('meta');
  function metaPart(label, value) { if (meta.childNodes.length) meta.appendChild(document.createTextNode('  \u00B7  ')); meta.appendChild(document.createTextNode(label + ' ')); meta.appendChild(el('b', null, value)); }
  if (D.datacenter) metaPart('Target datacenter', D.datacenter);
  metaPart('List written', D.listTime);
  metaPart('Page made', D.made);
  document.getElementById('foot').textContent = 'Source: ' + D.list + ' - ' + D.tool + '. Folder IDs are those on the target vCenter. Make a fresh list right before a migration wave.';

  // Folders and checks
  var folders = {}, order = [];
  items.forEach(function (it) {
    var k = it.t + '|' + it.p;
    if (!folders[k]) { folders[k] = { t: it.t, p: it.p, id: it.id, nt: it.nt, vms: [] }; order.push(k); }
    folders[k].vms.push(it);
    if (!folders[k].id && it.id) folders[k].id = it.id;
  });
  order.sort(function (a, b) { return key(folders[a].t + folders[a].p) < key(folders[b].t + folders[b].p) ? -1 : 1; });
  order.forEach(function (k) { folders[k].vms.sort(function (a, b) { return key(a.n) < key(b.n) ? -1 : 1; }); });

  var leafPaths = {};
  order.forEach(function (k) { var f = folders[k]; var l = key(leaf(f.p)); if (!l) return; (leafPaths[l] = leafPaths[l] || []).push(f.p); });
  var nameCount = {};
  items.forEach(function (it) { var n = key(it.o + '|' + it.n); nameCount[n] = (nameCount[n] || 0) + 1; });
  function ambiguousLeaf(p) { var l = key(leaf(p)); return l && leafPaths[l] && leafPaths[l].length > 1; }
  function dupName(it) { return nameCount[key(it.o + '|' + it.n)] > 1; }
  function isRoot(p) { return segs(p).length === 0; }

  // Path below the datacenter (the datacenter is in the header): parents
  // muted, the destination folder itself bold.
  function crumb(p) {
    var c = el('span', 'crumb');
    var s = segs(p);
    if (!s.length) { c.appendChild(el('span', 'root', '(datacenter root)')); return c; }
    s.forEach(function (part, i) {
      if (i > 0) c.appendChild(el('span', 'sep', '\u203A'));
      c.appendChild(el('span', i === s.length - 1 ? 'leaf' : 'up', part));
    });
    return c;
  }
  function flags(container, f, it) {
    if (f.nt) container.appendChild(el('span', 'flag', f.nt));
    if (ambiguousLeaf(f.p)) container.appendChild(el('span', 'flag', 'name in ' + leafPaths[key(leaf(f.p))].length + ' paths'));
    if (it && dupName(it)) container.appendChild(el('span', 'flag', 'duplicate VM name'));
  }
  function idChip(id) { return el('span', id ? 'id' : 'id none', id || 'no ID'); }
  function typeLabel(it) { return it.o === 'VirtualMachine' ? '' : ' (' + it.o + ')'; }
  function showTypes() { var t = {}; items.forEach(function (it) { t[it.t] = 1; }); return Object.keys(t).length > 1; }
  var multiType = showTypes();

  var q = document.getElementById('q');
  function matches(text, term) { return !term || key(text).indexOf(term) !== -1; }

  // Collapsed folders survive a re-render (search); large lists start collapsed.
  var collapsed = {};
  if (order.length > 30) order.forEach(function (k) { collapsed[k] = true; });

  function renderFolders(term) {
    var v = document.getElementById('v-folders'); v.textContent = '';
    var shown = 0;
    if (!term) v.appendChild(el('p', 'note', 'One mobility group per destination folder keeps it simple; otherwise use the largest folder as the group default and set the rest per VM. Paths start below the target datacenter.'));
    var sheet = el('div', 'sheet');
    order.forEach(function (k) {
      var f = folders[k];
      var folderHit = matches(f.p, term);
      var vms = f.vms.filter(function (it) { return folderHit || matches(it.n, term); });
      if (!vms.length) return;
      shown++;
      var open = !!term || !collapsed[k];
      var g = el('div', 'grp'); g.tabIndex = 0; g.setAttribute('role', 'button'); g.setAttribute('aria-expanded', open ? 'true' : 'false');
      g.appendChild(el('span', 'tw', open ? '\u25BE' : '\u25B8'));
      var name = el('span'); if (multiType) { name.appendChild(el('span', 'typ', f.t)); name.appendChild(document.createTextNode(' ')); }
      name.appendChild(crumb(f.p)); g.appendChild(name);
      g.appendChild(el('span', 'count-badge', vms.length + (vms.length === 1 ? ' VM' : ' VMs')));
      g.appendChild(idChip(f.id));
      var fl = el('span', 'flags'); flags(fl, f, null); g.appendChild(fl);
      var box = el('div', 'vmbox'); box.hidden = !open;
      vms.forEach(function (it) { box.appendChild(el('span', dupName(it) ? 'vm dup' : 'vm', it.n + typeLabel(it))); });
      function toggle() {
        collapsed[k] = !box.hidden; box.hidden = collapsed[k];
        g.setAttribute('aria-expanded', box.hidden ? 'false' : 'true');
        g.firstChild.textContent = box.hidden ? '\u25B8' : '\u25BE';
        syncToggleAll();
      }
      g.addEventListener('click', toggle);
      g.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } });
      sheet.appendChild(g); sheet.appendChild(box);
    });
    if (shown) v.appendChild(sheet);
    else v.appendChild(el('p', 'empty', 'Nothing matches "' + q.value + '".'));
    return shown;
  }

  var toggleAll = document.getElementById('toggle-all');
  function anyOpen() { return order.some(function (k) { return !collapsed[k]; }); }
  function syncToggleAll() { toggleAll.textContent = anyOpen() ? 'Collapse all' : 'Expand all'; }
  toggleAll.addEventListener('click', function () {
    var close = anyOpen(); order.forEach(function (k) { collapsed[k] = close; }); render();
  });

  // Theme: follows the system until the button is used
  var root = document.documentElement, themeBtn = document.getElementById('theme');
  function isDark() { var t = root.getAttribute('data-theme'); return t ? t === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches; }
  function syncTheme() { themeBtn.textContent = isDark() ? 'Light' : 'Dark'; }
  themeBtn.addEventListener('click', function () { root.setAttribute('data-theme', isDark() ? 'light' : 'dark'); syncTheme(); });
  syncTheme();

  function renderVms(term) {
    var v = document.getElementById('v-vms'); v.textContent = '';
    var list = items.filter(function (it) { return matches(it.n, term) || matches(it.p, term); })
      .sort(function (a, b) { return key(a.n) < key(b.n) ? -1 : 1; });
    if (!list.length) { v.appendChild(el('p', 'empty', 'Nothing matches "' + q.value + '".')); return 0; }
    var t = el('table'); var h = el('tr');
    ['VM', 'Destination folder', 'Folder ID', ''].forEach(function (c) { h.appendChild(el('th', null, c)); });
    t.appendChild(h);
    list.forEach(function (it) {
      var tr = el('tr');
      tr.appendChild(el('td', null, it.n + typeLabel(it)));
      var td = el('td'); td.appendChild(crumb(it.p)); tr.appendChild(td);
      td = el('td'); td.appendChild(idChip(it.id)); tr.appendChild(td);
      td = el('td'); flags(td, { p: it.p, nt: it.nt }, it); tr.appendChild(td);
      t.appendChild(tr);
    });
    v.appendChild(t);
    return list.length;
  }

  function renderAttention() {
    var v = document.getElementById('v-attention'); v.textContent = '';
    var total = 0;
    function block(title, explain, rows, cols, cells) {
      if (!rows.length) return;
      total += rows.length;
      v.appendChild(el('h2', null, title + ' (' + rows.length + ')'));
      v.appendChild(el('p', 'explain', explain));
      if (cols === null) {
        // A list of names only: chips instead of a one-column table
        var box = el('div', 'chips');
        rows.forEach(function (r) { box.appendChild(el('span', 'vm', cells(r))); });
        v.appendChild(box);
        return;
      }
      var t = el('table'); var h = el('tr');
      cols.forEach(function (c) { h.appendChild(el('th', null, c)); });
      t.appendChild(h);
      rows.forEach(function (r) { var tr = el('tr'); cells(r).forEach(function (c) { var td = el('td'); if (typeof c === 'string') td.textContent = c; else td.appendChild(c); tr.appendChild(td); }); t.appendChild(tr); });
      v.appendChild(t);
    }
    block('Folders without an ID on the target',
      'These folders do not exist on the target vCenter yet, or the list came from a dry run. Run the import on the target with -MoveObjects:$false -Csv (no -DryRun) and make the page again.',
      order.filter(function (k) { return !folders[k].id && !isRoot(folders[k].p); }).map(function (k) { return folders[k]; }),
      ['Folder', 'VMs', 'Note'], function (f) { return [crumb(f.p), String(f.vms.length), f.nt || '']; });
    var amb = Object.keys(leafPaths).filter(function (l) { return leafPaths[l].length > 1; }).sort();
    block('Folder names in more than one path',
      'A picker that shows only the folder name cannot tell these apart. Check the full path before you pick.',
      amb, ['Folder name', 'Paths'], function (l) {
        var span = el('span'); leafPaths[l].sort().forEach(function (p, i) { if (i) span.appendChild(el('br')); span.appendChild(crumb(p)); });
        return [leaf(leafPaths[l][0]), span];
      });
    block('VM names that occur more than once',
      'More than one exported object has this name. The name alone does not tell which one goes where: check the source vCenter ID (column SourceId in the list).',
      items.filter(dupName).sort(function (a, b) { return key(a.n) < key(b.n) ? -1 : 1; }),
      ['VM', 'Destination folder'], function (it) { return [it.n, crumb(it.p)]; });
    block('VMs in the datacenter root',
      'These VMs sit directly in the datacenter, not in a folder. In HCX pick the datacenter itself (its root VM folder).',
      items.filter(function (it) { return isRoot(it.p); }),
      null, function (it) { return it.n + typeLabel(it); });
    if (!total) v.appendChild(el('p', 'empty', 'Nothing needs attention.'));
    return total;
  }

  var att = renderAttention();
  document.getElementById('c-att').textContent = att ? '(' + att + ')' : '';
  function render() {
    var term = key(q.value.trim());
    var f = renderFolders(term), n = renderVms(term);
    document.getElementById('c-folders').textContent = '(' + f + ')';
    document.getElementById('c-vms').textContent = '(' + n + ')';
    document.getElementById('stats').textContent = items.length + ' objects in ' + order.length + ' folders';
    syncToggleAll();
  }
  q.addEventListener('input', render);
  var tabs = document.querySelectorAll('.tabs button');
  function select(b) {
    Array.prototype.forEach.call(tabs, function (x) {
      var on = x === b; x.setAttribute('aria-selected', on ? 'true' : 'false');
      document.getElementById('v-' + x.getAttribute('data-view')).hidden = !on;
    });
    toggleAll.hidden = b.getAttribute('data-view') !== 'folders';
  }
  Array.prototype.forEach.call(tabs, function (b) {
    b.addEventListener('click', function () { select(b); });
    if (location.hash === '#' + b.getAttribute('data-view')) select(b);
  });
  render();
  q.focus();
})();
</script>
</body>
</html>
'@

$html = $template.Replace('__DATA__', $json)
[System.IO.File]::WriteAllText($OutFile, $html, (New-Object System.Text.UTF8Encoding($false)))

$folderCount = @($rows | ForEach-Object { "$($_.FolderType)|$($_.Path)" } | Sort-Object -Unique).Count
$noId = @($rows | Where-Object { -not $_.TargetFolderId -and $_.Path -ne '/' }).Count
Write-Host ("  {0} object(s) in {1} folder(s), list written {2}" -f $rows.Count, $folderCount, $data.listTime)
if ($noId -gt 0) {
    Write-Host ("  {0} object(s) point to a folder without an ID on the target (see Attention)." -f $noId) -ForegroundColor Yellow
}
Write-Host "  Sheet: $OutFile" -ForegroundColor Green
Write-Host ''
