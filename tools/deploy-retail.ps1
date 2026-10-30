<#
.SYNOPSIS
  Deploy MonetUI into a retail WoW client's Interface\AddOns folder.

.DESCRIPTION
  Copies the runtime files (toc, Core.lua, Assets, Libs, Utils, Config, Modules)
  into <Dest>\Interface\AddOns\MonetUI, then rewrites the copied toc's
  `## Interface:` line to the retail client's own number.  The source toc keeps
  16001 (WoW Forever); retail would otherwise mark the addon out of date and
  refuse to load it without ticking "Load out of date AddOns".

  Re-run after every code change — the copy is mirrored, so deleted files go
  away too.  WTF / SavedVariables are never touched.

.PARAMETER Dest
  The _retail_ directory of the retail client.
  Default: the CN install on this machine.

.PARAMETER Interface
  Interface number written into the deployed toc.
  12.1.5 = 120105 (MMmmpp).  Check the client build if it stops loading.

.EXAMPLE
  powershell -File tools/deploy-retail.ps1
  powershell -File tools/deploy-retail.ps1 -Dest "D:\WoW\_retail_"
#>
[CmdletBinding()]
# NOTE: this script must stay ASCII-only. Windows PowerShell 5.1 reads BOM-less
# .ps1 files as ANSI, and a non-ASCII byte inside param() breaks parameter
# binding ("cannot bind argument to parameter 'Path' because it is null").
# Default target = the client actually in use (WOWFOREVER); before 2026-10-29 it
# pointed at the old ...\Blizzards\World of Warcraft\_retail_ install, so a bare
# run would deploy into the wrong client.
param(
    [string]$Dest = 'C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_retail_',
    [int]$Interface = 120105
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot          # repo root
$target = Join-Path $Dest 'Interface\AddOns\MonetUI'

if (-not (Test-Path (Join-Path $Dest 'Wow.exe'))) {
    throw "Not a _retail_ folder (no Wow.exe): $Dest"
}
if (-not (Test-Path (Join-Path $root 'MonetUI.toc'))) {
    throw "Repo root not found at $root"
}

Write-Host "MonetUI -> $target" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $target | Out-Null

# Runtime directories, mirrored so stale files do not survive a rename.
foreach ($dir in 'Assets', 'Libs', 'Utils', 'Config', 'Modules') {
    robocopy (Join-Path $root $dir) (Join-Path $target $dir) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $dir (exit $LASTEXITCODE)" }
}

foreach ($file in 'MonetUI.toc', 'Core.lua', 'LICENSE', 'THIRD-PARTY-NOTICES.txt') {
    Copy-Item (Join-Path $root $file) (Join-Path $target $file) -Force
}

# Patch the deployed toc only — the repo's copy stays on 16001.
$toc = Join-Path $target 'MonetUI.toc'
$text = [System.IO.File]::ReadAllText($toc)
$patched = [regex]::Replace($text, '(?m)^## Interface:\s*\d+', "## Interface: $Interface")
[System.IO.File]::WriteAllText($toc, $patched, (New-Object System.Text.UTF8Encoding($false)))

$line = (Select-String -Path $toc -Pattern '^## Interface:').Line
$count = (Get-ChildItem $target -Recurse -File | Measure-Object).Count
Write-Host ("Done: {0} files, {1}" -f $count, $line) -ForegroundColor Green
Write-Host "In game: tick 'Load out of date AddOns' if it still shows out of date." -ForegroundColor DarkGray
