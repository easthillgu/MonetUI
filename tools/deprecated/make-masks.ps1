# tools/make-masks.ps1
#
# Generates the self-drawn alpha masks MonetUI ships (no third-party art):
#
#   Assets/Textures/minimap_rect_mask.tga   256x256, visible band rows 33..222 (190 tall)
#
# Opaque white inside the shape, white-with-alpha-0 outside -- white *and*
# opaque on purpose, so a mask behaves the same whether the client reads its
# luminance or its alpha channel, and the empty side is never pure black (a
# black key would fringe the edge the moment anything filters the texture).
#
# Geometry is in mask pixels, and a mask is authored at its frame's native size
# and applied 1:1 (Minimap:SetMaskTexture on a 256x256 canvas), so 1 mask px =
# 1 UI unit.
#
# Radius 4 is not a taste call, it is the geometry: the panel's rounded border
# (Utils/Widget.lua ROUND_SLICE = 3, ring 2 wide) leaves its interior corner at
# radius 1, and the minimap sits 4 UI units inside the panel, so a smaller mask
# leaves map pixels that paint over the ring's arc -- 4 cuts exactly the
# 3 pixels per corner that the ring already covers, and nothing of the map.
# NOTE the mask is hard-edged (no anti-aliasing) while the border arc is
# anti-aliased, so the two round independently at the 1px level: that is
# deliberate, the mask is a rectangle-with-cut-corners, not a curve.
#
# Re-run after changing the radius or the crop:
#
#   powershell -ExecutionPolicy Bypass -File tools\make-masks.ps1
#
# The corner previews it drops in %TEMP% are for judging the arc without
# launching the game; only the .tga is shipped, and previews are never committed.

param(
    [double]$Radius   = 4,                            # corner radius, mask px (= UI units), see the header
    [string]$OutDir   = (Join-Path $PSScriptRoot "..\Assets\Textures"),
    [int]$MinimapSize = 256,                          # same numbers as Modules/Minimap/Minimap.lua
    [int]$MinimapCrop = 33                            # (256 - 190) / 2
)

$ErrorActionPreference = 'Stop'

$OPAQUE = -1                                          # 0xFFFFFFFF as int32: B,G,R,A all 255
$CLEAR  = 0x00FFFFFF                                  # white with alpha 0 -- never pure black: the
                                                      # client's filtering would drag black into the edge

# --- the shape ------------------------------------------------------------
# A rounded rectangle spanning the full width, rows $BandTop..($H - $BandBottom - 1).
# Sampled at pixel centres, hard edges (no anti-aliasing): a pixel UI wants a
# crisp stair at the corner, not a grey fringe that reads as a soft edge.
function New-RoundedMask {
    param([int]$W, [int]$H, [int]$BandTop, [int]$BandBottom, [double]$R)

    $top    = [double]$BandTop
    $bottom = [double]($H - $BandBottom)
    $pix    = New-Object 'int[]' ($W * $H)
    for ($i = 0; $i -lt $pix.Length; $i++) { $pix[$i] = $CLEAR }

    for ($y = 0; $y -lt $H; $y++) {
        $cy = $y + 0.5
        if ($cy -lt $top -or $cy -ge $bottom) { continue }        # the cropped bands stay clear
        $base = $y * $W
        for ($x = 0; $x -lt $W; $x++) {
            if ($R -gt 0) {
                # only the four r x r corner squares need a distance test
                $cx = $x + 0.5
                $dx = 0.0; $dy = 0.0
                if     ($cx -lt $R)             { $dx = $R - $cx }
                elseif ($cx -gt ($W - $R))      { $dx = $cx - ($W - $R) }
                if     ($cy -lt ($top + $R))    { $dy = ($top + $R) - $cy }
                elseif ($cy -gt ($bottom - $R)) { $dy = $cy - ($bottom - $R) }
                if (($dx * $dx + $dy * $dy) -gt ($R * $R)) { continue }
            }
            $pix[$base + $x] = $OPAQUE
        }
    }
    return $pix
}

# --- the writer -----------------------------------------------------------
# TGA type 10 (RLE true-colour), 32bpp, descriptor 0x08 = 8 alpha bits with a
# bottom-left origin (every shape here is symmetric top-to-bottom, so the origin
# is asserted rather than relied on).  Run packets cover the flat areas, raw
# packets carry the corners, so a file stays a couple of KB instead of ~380 KB.
function Write-TgaRle {
    param([string]$Path, [int]$W, [int]$H, [int[]]$Pixels)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    $bw.Write([byte]0)         # id length
    $bw.Write([byte]0)         # no colour map
    $bw.Write([byte]10)        # image type 10 = RLE true-colour
    $bw.Write([uint16]0)       # colour map first entry
    $bw.Write([uint16]0)       # colour map length
    $bw.Write([byte]0)         # colour map entry size
    $bw.Write([uint16]0)       # x origin
    $bw.Write([uint16]0)       # y origin
    $bw.Write([uint16]$W)
    $bw.Write([uint16]$H)
    $bw.Write([byte]32)        # bits per pixel
    $bw.Write([byte]0x08)      # 8 alpha bits, bottom-left origin

    $n = $Pixels.Length
    $i = 0
    while ($i -lt $n) {
        $run = 1
        while ((($i + $run) -lt $n) -and ($Pixels[$i + $run] -eq $Pixels[$i]) -and ($run -lt 128)) { $run++ }

        if ($run -ge 2) {
            $bw.Write([byte](0x80 -bor ($run - 1)))
            $p = $Pixels[$i]
            $bw.Write([byte]($p -band 0xFF))
            $bw.Write([byte](($p -shr 8)  -band 0xFF))
            $bw.Write([byte](($p -shr 16) -band 0xFF))
            $bw.Write([byte](($p -shr 24) -band 0xFF))
            $i += $run
        }
        else {
            $start = $i
            $i++
            while (($i -lt $n) -and (($i - $start) -lt 128)) {
                # stop right before the next run, so the raw packet stays a raw packet
                if ((($i + 2) -lt $n) -and ($Pixels[$i] -eq $Pixels[$i + 1]) -and ($Pixels[$i] -eq $Pixels[$i + 2])) { break }
                $i++
            }
            $count = $i - $start
            $bw.Write([byte]($count - 1))
            for ($k = $start; $k -lt $i; $k++) {
                $p = $Pixels[$k]
                $bw.Write([byte]($p -band 0xFF))
                $bw.Write([byte](($p -shr 8)  -band 0xFF))
                $bw.Write([byte](($p -shr 16) -band 0xFF))
                $bw.Write([byte](($p -shr 24) -band 0xFF))
            }
        }
    }
    $bw.Flush()

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())

    $bw.Dispose()
    $ms.Dispose()
}

# --- the verifier ---------------------------------------------------------
# A malformed RLE stream would otherwise only show up as a broken minimap in
# game, so every file is decoded back and checked pixel by pixel against an
# independently recomputed shape.
function Test-TgaRle {
    param([string]$Path, [string]$Label, [int]$BandTop, [int]$BandBottom, [double]$R)

    $b   = [System.IO.File]::ReadAllBytes($Path)
    $w   = [int]$b[12] + [int]$b[13] * 256
    $h   = [int]$b[14] + [int]$b[15] * 256
    $pos = 18
    $alpha = New-Object 'int[]' ($w * $h)
    $x = 0; $y = 0
    $bad = @()

    while ($y -lt $h) {
        if ($pos -ge $b.Length) { $bad += "stream ended early at row $y"; break }
        $hdr   = $b[$pos]; $pos++
        $count = ($hdr -band 0x7F) + 1
        $rle   = [bool]($hdr -band 0x80)
        for ($i = 0; $i -lt $count; $i++) {
            if (($pos + 3) -ge $b.Length) { $bad += "stream ended inside a packet at row $y"; break }
            $alpha[$y * $w + $x] = $b[$pos + 3]        # a run packet reuses the same 4 bytes
            if (-not $rle) { $pos += 4 }
            $x++
            if ($x -eq $w) { $x = 0; $y++ }
        }
        if ($rle) { $pos += 4 }
        if ($bad.Count -gt 0) { break }
    }

    # expected shape, recomputed independently of the writer's inner loop
    $top    = [double]$BandTop
    $bottom = [double]($h - $BandBottom)
    $mismatch = 0
    $opaque   = 0
    for ($yy = 0; $yy -lt $h; $yy++) {
        $cy = $yy + 0.5
        for ($xx = 0; $xx -lt $w; $xx++) {
            $want = 0
            if ($cy -ge $top -and $cy -lt $bottom) {
                $cx = $xx + 0.5
                $dx = 0.0; $dy = 0.0
                if     ($cx -lt $R)        { $dx = $R - $cx }
                elseif ($cx -gt ($w - $R)) { $dx = $cx - ($w - $R) }
                if     ($cy -lt ($top + $R))    { $dy = ($top + $R) - $cy }
                elseif ($cy -gt ($bottom - $R)) { $dy = $cy - ($bottom - $R) }
                if (($dx * $dx + $dy * $dy) -le ($R * $R)) { $want = 255 }
            }
            if ($alpha[$yy * $w + $xx] -ne $want) { $mismatch++ }
            if ($want -eq 255) { $opaque++ }
        }
    }

    # the four corner pixels are the whole point of the change: report them
    $corners = @()
    foreach ($c in @(@(0, $BandTop), @(($w - 1), $BandTop),
                     @(0, ($h - $BandBottom - 1)), @(($w - 1), ($h - $BandBottom - 1)))) {
        $corners += "($($c[0]),$($c[1]))=$($alpha[$c[1] * $w + $c[0]])"
    }

    "{0,-24} {1,3}x{2,-3} {3,7} bytes  type={4} depth={5} desc=0x{6}" -f `
        $Label, $w, $h, $b.Length, $b[2], $b[16], $b[17].ToString('X2')
    "{0,-24} opaque {1} px of {2} ({3:N2}%)  corners {4}" -f `
        "", $opaque, ($w * $h), (100.0 * $opaque / ($w * $h)), ($corners -join " ")

    if ($bad.Count -eq 0 -and $mismatch -eq 0) { "{0,-24} verify : OK" -f "" }
    else {
        "{0,-24} verify : FAILED" -f ""
        $bad | Select-Object -First 5 | ForEach-Object { "  $_" }
        if ($mismatch -gt 0) { "  $mismatch pixels differ from the expected shape" }
        exit 1
    }
}

# --- generate -------------------------------------------------------------
$minimapH = $MinimapSize - $MinimapCrop * 2                      # 190

$jobs = @(
    @{ File = "minimap_rect_mask.tga"; Label = "minimap_rect_mask";
       W = $MinimapSize; H = $MinimapSize; Top = $MinimapCrop; Bottom = $MinimapCrop }
)

"radius  : $Radius mask px (= $Radius UI units)"
"minimap : ${MinimapSize}x${MinimapSize}, band rows $MinimapCrop..$($MinimapSize - $MinimapCrop - 1) (${minimapH} tall)"
""
foreach ($j in $jobs) {
    $out = Join-Path $OutDir $j.File
    $j.Pix = New-RoundedMask -W $j.W -H $j.H -BandTop $j.Top -BandBottom $j.Bottom -R $Radius
    Write-TgaRle -Path $out -W $j.W -H $j.H -Pixels $j.Pix
    Test-TgaRle -Path $out -Label $j.Label -BandTop $j.Top -BandBottom $j.Bottom -R $Radius
    ""
}

# --- preview --------------------------------------------------------------
# GDI+ cannot read TGA (and neither can a browser), so the previews are painted
# from the pixel arrays that were just written.  The .tga is the shippable
# asset; these PNGs only exist so the corner can be judged without launching the
# game.
$tmp = Join-Path $env:TEMP "opencode\monet_masks"
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }

Add-Type -AssemblyName System.Drawing

# white where the mask is opaque, a checkerboard where it is transparent
function New-MaskBitmap {
    param([int[]]$Pix, [int]$W, [int]$H, [int]$Zoom = 1, [int]$Cell = 8)

    $ow = $W * $Zoom
    $oh = $H * $Zoom
    $bytes = New-Object 'byte[]' ($ow * $oh * 4)
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            if ($Pix[$y * $W + $x] -eq $OPAQUE) { $b = 255; $gg = 255; $r = 255 }
            else {
                $shade = if ((([int]($x / $Cell) + [int]($y / $Cell)) % 2) -eq 0) { 58 } else { 34 }
                $b = $shade; $gg = $shade; $r = $shade
            }
            for ($zy = 0; $zy -lt $Zoom; $zy++) {
                $rowBase = (($y * $Zoom) + $zy) * $ow
                for ($zx = 0; $zx -lt $Zoom; $zx++) {
                    $i = ($rowBase + ($x * $Zoom) + $zx) * 4
                    $bytes[$i] = $b; $bytes[$i + 1] = $gg; $bytes[$i + 2] = $r; $bytes[$i + 3] = 255
                }
            }
        }
    }

    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $ow, $oh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bd  = $bmp.LockBits((New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $ow, $oh),
                         [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                         [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $bd.Scan0, $bytes.Length)
    $bmp.UnlockBits($bd)
    return $bmp
}

function Get-Crop {
    param([int[]]$Pix, [int]$W, [int]$X, [int]$Y, [int]$Size)
    $out = New-Object 'int[]' ($Size * $Size)
    for ($yy = 0; $yy -lt $Size; $yy++) {
        for ($xx = 0; $xx -lt $Size; $xx++) {
            $out[$yy * $Size + $xx] = $Pix[($Y + $yy) * $W + ($X + $xx)]
        }
    }
    return $out
}

function New-LabelledSheet {
    param([array]$Tiles, [string]$Path)              # tiles: @{ Bmp = ...; Label = "..." }

    $font  = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $probe = New-Object System.Drawing.Bitmap -ArgumentList 1, 1
    $pg    = [System.Drawing.Graphics]::FromImage($probe)

    $w = 0; $h = 16
    foreach ($t in $Tiles) {
        $labelW = [int][Math]::Ceiling($pg.MeasureString($t.Label, $font).Width)
        $w = [Math]::Max($w, [Math]::Max($t.Bmp.Width, $labelW))
        $h += $t.Bmp.Height + 26
    }
    $pg.Dispose(); $probe.Dispose()

    $sheet = New-Object System.Drawing.Bitmap -ArgumentList ($w + 16), $h
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 18, 18, 22))
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

    $y = 8
    foreach ($t in $Tiles) {
        $g.DrawString($t.Label, $font, $white, 8, $y)
        $y += 20
        $g.DrawImage($t.Bmp, 8, $y)
        $y += $t.Bmp.Height + 6
    }
    $g.Dispose()
    $sheet.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
}

$tiles = @()
foreach ($j in $jobs) {
    $tiles += @{ Bmp = (New-MaskBitmap -Pix $j.Pix -W $j.W -H $j.H); Label = "$($j.Label)  1:1  ($($j.W)x$($j.H))" }
}
New-LabelledSheet -Tiles $tiles -Path (Join-Path $tmp "mask-1x.png")
foreach ($t in $tiles) { $t.Bmp.Dispose() }

$zoom = 8
$cw   = 14
$tiles = @()
foreach ($j in $jobs) {
    $tiles += @{ Bmp = (New-MaskBitmap -Pix (Get-Crop -Pix $j.Pix -W $j.W -X 0 -Y $j.Top -Size $cw) -W $cw -H $cw -Zoom $zoom);
                 Label = "$($j.Label)  top-left corner, ${zoom}x  (radius $Radius)" }
}
foreach ($r in @(1, 2, 3, 4, 6)) {
    $tiles += @{ Bmp = (New-MaskBitmap -Pix (New-RoundedMask -W $cw -H $cw -BandTop 0 -BandBottom 0 -R $r) -W $cw -H $cw -Zoom $zoom);
                 Label = "same corner at radius $r" }
}
New-LabelledSheet -Tiles $tiles -Path (Join-Path $tmp "corners.png")
foreach ($t in $tiles) { $t.Bmp.Dispose() }

"preview : $tmp"
