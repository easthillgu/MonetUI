# tools/make-minimap-mask.ps1
#
# Generates Assets/Textures/minimap-rect-mask.tga -- the 256x256 alpha mask that
# keeps only the middle 190px band of the minimap canvas, giving MonetUI its
# 256x190 rectangular minimap.
#
#   rows   0..32  and  223..255 : transparent black  -> cropped away
#   rows  33..222               : opaque white       -> the visible band
#
# White *and* opaque on purpose, so the mask behaves the same whether the client
# reads the mask's luminance or its alpha channel.
#
# The asset is generated rather than copied so the addon ships no third-party
# art; re-run this script after changing $crop.
#
#   powershell -ExecutionPolicy Bypass -File tools\make-minimap-mask.ps1

param(
    [string]$Out = (Join-Path $PSScriptRoot "..\Assets\Textures\minimap-rect-mask.tga")
)

$ErrorActionPreference = 'Stop'

$w       = 256
$crop    = 33                    # (256 - 190) / 2
$mid     = $w - $crop * 2        # 190 visible rows
$hidden  = @(0xFF, 0,   0,   0,   0,     0xFF, 0,   0,   0,   0)
$shown   = @(0xFF, 255, 255, 255, 255,   0xFF, 255, 255, 255, 255)

# 0xFF = 0x80 (RLE packet) -bor 127, i.e. one run of 128 pixels; two of them
# cover a whole 256px row of a single colour.

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

$bw.Write([byte]0)        # id length
$bw.Write([byte]0)        # no colour map
$bw.Write([byte]10)       # image type 10 = RLE true-colour
$bw.Write([uint16]0)      # colour map first entry
$bw.Write([uint16]0)      # colour map length
$bw.Write([byte]0)        # colour map entry size
$bw.Write([uint16]0)      # x origin
$bw.Write([uint16]0)      # y origin
$bw.Write([uint16]$w)     # width
$bw.Write([uint16]$w)     # height
$bw.Write([byte]32)       # bits per pixel
$bw.Write([byte]0x08)     # 8 alpha bits, bottom-left origin (band is symmetric)

for ($y = 0; $y -lt $w; $y++) {
    $row = if ($y -lt $crop -or $y -ge ($w - $crop)) { $hidden } else { $shown }
    foreach ($b in $row) { $bw.Write([byte]$b) }
}
$bw.Flush()

$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes($Out, $ms.ToArray())
$bw.Dispose()

# -- Verify: decode the file back and assert the geometry -------------------
# A malformed RLE stream would otherwise only show up as a broken minimap in
# game, so the script checks its own output.
$bytes = [System.IO.File]::ReadAllBytes($Out)
$vw    = [int]$bytes[12] + [int]$bytes[13] * 256
$vh    = [int]$bytes[14] + [int]$bytes[15] * 256
$pos   = 18
$ok    = 0
$clear = 0
$bad   = @()

for ($y = 0; $y -lt $vh; $y++) {
    $x        = 0
    $rowAlpha = -1
    while ($x -lt $vw) {
        $hdr = $bytes[$pos]; $pos++
        $count = ($hdr -band 0x7F) + 1
        for ($i = 0; $i -lt $count; $i++) {
            if ($i -eq 0) { $rowAlpha = $bytes[$pos + 3] }
            if (-not ($hdr -band 0x80)) { $pos += 4 }
        }
        if ($hdr -band 0x80) { $pos += 4 }
        $x += $count
    }
    if ($x -ne $vw) { $bad += "row $y decoded $x pixels, want $vw" }
    $want = if ($y -lt $crop -or $y -ge ($vh - $crop)) { 0 } else { 255 }
    if ($rowAlpha -ne $want) { $bad += "row $y alpha $rowAlpha, want $want" }
    if ($want -eq 255) { $ok++ } else { $clear++ }
}

"wrote  : $Out ($($bytes.Length) bytes)"
"format : type=$($bytes[2]) ${vw}x${vh} depth=$($bytes[16]) descriptor=0x$($bytes[17].ToString('X2'))"
"bands  : $ok opaque (want $mid), $clear transparent (want $($vw - $mid))"
if ($bad.Count -eq 0) { "verify : OK" }
else { "verify : FAILED"; $bad | Select-Object -First 5 | ForEach-Object { "  $_" }; exit 1 }
