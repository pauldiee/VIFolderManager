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
    Version : 0.1.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Requires: PowerShell 5.1 or 7.x; no PowerCLI, no vCenter connection
    Tested  : PowerShell 7.6.10 with a generated list (no live vCenter yet)
    The page holds VM and folder names: keep it where you keep the export.
#>

<#
CHANGELOG
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

$scriptVersion = '0.1.0'
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
:root {
  --royal: #040559; --orange: #FF4F41; --lightblue: #CDE3F7;
  --bg: #F4F8FD; --panel: #FFFFFF; --text: #040559; --muted: #535353; --line: #E2E8F0;
  --head-bg: #040559; --head-text: #FFFFFF; --head-quiet: #CDE3F7;
  --accent: #FF4F41; --accent-soft: #FFE3E0; --soft: #E6F1FB; --code: #E6EBEB;
  --warn: #CC3528; --warn-soft: #FFE3E0;
  --shadow-sm: 0 2px 6px rgba(4, 5, 90, 0.08);
  --focus: 0 0 0 3px rgba(255, 79, 65, 0.35);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #02032E; --panel: #0B0C4A; --text: #FFFFFF; --muted: #CDE3F7; --line: #2A2B6E;
    --head-bg: #02032E; --soft: #1A1B5E; --code: #1A1B5E; --accent-soft: #3A1A30;
    --warn: #FF8A80; --warn-soft: #3A1A30;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.45 "Segoe UI", system-ui, -apple-system, sans-serif; }
header { background: var(--head-bg); color: var(--head-text); padding: 18px 28px 14px; }
header h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
header .meta { color: var(--head-quiet); font-size: 13px; }
header .meta b { color: var(--head-text); font-weight: 600; }
.bar { position: sticky; top: 0; z-index: 2; background: var(--bg); padding: 12px 28px;
  border-bottom: 1px solid var(--line); display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
.bar input { flex: 1 1 320px; max-width: 520px; padding: 9px 12px; font: inherit; color: var(--text);
  background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
.bar input:focus { outline: none; box-shadow: var(--focus); border-color: var(--accent); }
.tabs { display: flex; gap: 6px; }
.tabs button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid var(--line);
  background: var(--panel); color: var(--text); cursor: pointer; }
.tabs button[aria-selected="true"] { background: var(--accent); border-color: var(--accent); color: #fff; }
.tabs button:focus-visible { outline: none; box-shadow: var(--focus); }
.tabs .count { opacity: .8; font-size: 12px; margin-left: 4px; }
.stats { color: var(--muted); font-size: 13px; }
main { padding: 18px 28px 40px; }
.note { background: var(--soft); border-radius: 8px; padding: 10px 14px; margin: 0 0 16px; font-size: 14px; }
.folder { background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
  box-shadow: var(--shadow-sm); margin: 0 0 10px; }
.folder > summary { list-style: none; cursor: pointer; padding: 10px 14px; display: flex;
  gap: 12px; align-items: baseline; flex-wrap: wrap; }
.folder > summary::-webkit-details-marker { display: none; }
.folder > summary::before { content: "\25B8"; color: var(--muted); }
.folder[open] > summary::before { content: "\25BE"; }
.crumb { font-weight: 600; }
.crumb .sep { color: var(--muted); font-weight: 400; margin: 0 5px; }
.crumb .dc { color: var(--muted); font-weight: 400; }
.badge { background: var(--soft); border-radius: 999px; padding: 1px 9px; font-size: 12px; }
.id { font-family: Consolas, "Cascadia Mono", monospace; font-size: 12px; background: var(--code);
  border-radius: 4px; padding: 1px 6px; }
.flag { background: var(--warn-soft); color: var(--warn); border-radius: 4px; padding: 1px 7px; font-size: 12px; font-weight: 600; }
.vms { columns: 3 220px; column-gap: 24px; margin: 0; padding: 4px 14px 12px 38px; }
.vms li { break-inside: avoid; padding: 1px 0; }
table { width: 100%; border-collapse: collapse; background: var(--panel); border: 1px solid var(--line);
  border-radius: 10px; overflow: hidden; box-shadow: var(--shadow-sm); }
th, td { text-align: left; padding: 7px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { background: var(--soft); font-weight: 600; font-size: 13px; }
tr:last-child td { border-bottom: 0; }
h2 { font-size: 17px; margin: 22px 0 6px; }
h2:first-child { margin-top: 0; }
.explain { color: var(--muted); font-size: 14px; margin: 0 0 10px; }
.empty { color: var(--muted); padding: 18px 0; }
mark { background: var(--accent-soft); color: inherit; border-radius: 3px; }
footer { color: var(--muted); font-size: 12px; padding: 0 28px 24px; }
[hidden] { display: none !important; }
@media print {
  :root { --bg: #fff; --panel: #fff; --text: #040559; --muted: #535353; --line: #CDCDDF; --soft: #F4F8FD; --code: #E6EBEB; }
  .bar { display: none; }
  header { background: #fff; color: var(--text); border-bottom: 2px solid var(--royal); }
  header .meta, header .meta b { color: var(--text); }
  .folder, table { box-shadow: none; break-inside: avoid; }
  section[hidden] { display: block !important; }
  section { break-before: page; }
  section:first-of-type { break-before: auto; }
}
</style>
</head>
<body>
<header>
  <h1 id="title"></h1>
  <div class="meta" id="meta"></div>
</header>
<div class="bar">
  <input id="q" type="search" placeholder="Search VM or folder ..." autocomplete="off" aria-label="Search VM or folder">
  <div class="tabs" role="tablist">
    <button role="tab" data-view="folders" aria-selected="true">Per folder<span class="count" id="c-folders"></span></button>
    <button role="tab" data-view="vms" aria-selected="false">Per VM<span class="count" id="c-vms"></span></button>
    <button role="tab" data-view="attention" aria-selected="false">Attention<span class="count" id="c-att"></span></button>
  </div>
  <span class="stats" id="stats"></span>
</div>
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
  function metaPart(label, value) { if (meta.childNodes.length) meta.appendChild(document.createTextNode('  ·  ')); meta.appendChild(document.createTextNode(label + ' ')); meta.appendChild(el('b', null, value)); }
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

  function crumb(p) {
    var c = el('span', 'crumb');
    if (D.datacenter) c.appendChild(el('span', 'dc', D.datacenter));
    var s = segs(p);
    if (!s.length) { c.appendChild(el('span', 'sep', '\u203A')); c.appendChild(document.createTextNode('(datacenter root)')); return c; }
    s.forEach(function (part, i) {
      if (D.datacenter || i > 0) c.appendChild(el('span', 'sep', '\u203A'));
      c.appendChild(document.createTextNode(part));
    });
    return c;
  }
  function flags(container, f, it) {
    if (f.nt) container.appendChild(el('span', 'flag', f.nt));
    if (ambiguousLeaf(f.p)) container.appendChild(el('span', 'flag', 'name in ' + leafPaths[key(leaf(f.p))].length + ' paths'));
    if (it && dupName(it)) container.appendChild(el('span', 'flag', 'duplicate VM name'));
  }
  function idChip(id) { return el('span', 'id', id || 'no ID'); }
  function typeLabel(it) { return it.o === 'VirtualMachine' ? '' : ' (' + it.o + ')'; }
  function showTypes() { var t = {}; items.forEach(function (it) { t[it.t] = 1; }); return Object.keys(t).length > 1; }
  var multiType = showTypes();

  var q = document.getElementById('q');
  function matches(text, term) { return !term || key(text).indexOf(term) !== -1; }

  function renderFolders(term) {
    var v = document.getElementById('v-folders'); v.textContent = '';
    var shown = 0;
    if (!term) v.appendChild(el('p', 'note', 'One mobility group per destination folder keeps it simple; otherwise use the largest folder as the group default and set the rest per VM. The path starts at the target datacenter.'));
    order.forEach(function (k) {
      var f = folders[k];
      var folderHit = matches(f.p, term);
      var vms = f.vms.filter(function (it) { return folderHit || matches(it.n, term); });
      if (!vms.length) return;
      shown++;
      var d = el('details', 'folder'); d.open = !!term || order.length <= 30;
      var s = el('summary');
      if (multiType) s.appendChild(el('span', 'badge', f.t));
      s.appendChild(crumb(f.p));
      s.appendChild(el('span', 'badge', vms.length + (vms.length === 1 ? ' VM' : ' VMs')));
      s.appendChild(idChip(f.id));
      flags(s, f, null);
      d.appendChild(s);
      var ul = el('ul', 'vms');
      vms.forEach(function (it) {
        var li = el('li', null, it.n + typeLabel(it));
        if (dupName(it)) { li.appendChild(document.createTextNode(' ')); li.appendChild(el('span', 'flag', 'duplicate')); }
        ul.appendChild(li);
      });
      d.appendChild(ul);
      v.appendChild(d);
    });
    if (!shown) v.appendChild(el('p', 'empty', 'Nothing matches "' + q.value + '".'));
    return shown;
  }

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
      ['VM'], function (it) { return [it.n + typeLabel(it)]; });
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
  }
  q.addEventListener('input', render);
  var tabs = document.querySelectorAll('.tabs button');
  function select(b) {
    Array.prototype.forEach.call(tabs, function (x) {
      var on = x === b; x.setAttribute('aria-selected', on ? 'true' : 'false');
      document.getElementById('v-' + x.getAttribute('data-view')).hidden = !on;
    });
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
