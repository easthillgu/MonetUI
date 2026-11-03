<#
.SYNOPSIS
  Deploy MonetUI into the shipping client's Interface\AddOns folder.

.DESCRIPTION
  NAME IS HISTORY: this script is the one and only deploy path, and since
  2026-11-02 its default target is the delivery client -- WOWFOREVER
  (_forever_, Interface 16001).  Renaming the file would break every doc /
  tool hint that already points at it (tools/sync-check.js tells you to run
  exactly this name), so the hint stays and the header says what it does.
  Only pass -Dest by hand when you really want the retired 12.1.5 install.

  Copies the runtime files (toc, Core.lua, Assets, Libs, Utils, Config, Modules)
  into <Dest>\Interface\AddOns\MonetUI, then rewrites the copied toc's
  `## Interface:` line.  Default 16001 = same as the source toc, so for the
  shipping client the patch is a no-op; pass -Interface 120105 only for a
  retail run, where an unpatched 16001 would show "out of date" and need
  "Load out of date AddOns" ticked.

  Re-run after every code change — the copy is mirrored, so deleted files go
  away too.  Only our own MonetUI directory is written: other addons' files are
  never touched.  WTF / SavedVariables are never touched.

.PARAMETER Dest
  Client root directory holding Wow.exe.
  Default: the WOWFOREVER install on this machine (_forever_).

.PARAMETER Interface
  Interface number written into the deployed toc.
  16001 = WoW Forever (the shipping target).  12.1.5 retail = 120105 (MMmmpp).

.EXAMPLE
  powershell -File tools/deploy-retail.ps1
  powershell -File tools/deploy-retail.ps1 -Dest "D:\WoW\_retail_" -Interface 120105
#>
[CmdletBinding()]
# NOTE: this script must stay ASCII-only. Windows PowerShell 5.1 reads BOM-less
# .ps1 files as ANSI, and a non-ASCII byte inside param() breaks parameter
# binding ("cannot bind argument to parameter 'Path' because it is null").
# Default target = the delivery client (WOWFOREVER, Interface 16001).  Until
# 2026-11-02 it pointed at the retired 12.1.5 _retail_ install; a bare run now
# deploys straight into the client that actually ships.
param(
    [string]$Dest = 'C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_forever_',
    [int]$Interface = 16001
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot          # repo root
$target = Join-Path $Dest 'Interface\AddOns\MonetUI'

if (-not (Test-Path (Join-Path $Dest 'Wow.exe'))) {
    throw "Not a WoW install (no Wow.exe): $Dest"
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
if ($Interface -ne 16001) {
    Write-Host "In game: tick 'Load out of date AddOns' if it still shows out of date." -ForegroundColor DarkGray
} else {
    Write-Host "Deployed to the shipping client (Interface 16001) -- verify with: node tools/sync-check.js" -ForegroundColor DarkGray
}
