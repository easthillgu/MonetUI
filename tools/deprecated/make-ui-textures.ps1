# tools/make-ui-textures.ps1
#
# Generates the Monet UI chrome set (exact-vector, two-tone painted edges):
#
#   Assets/Textures/monet-*.tga   -> in game (SetTexture / SetTexCoord)
#   Assets/Textures/monet-*.png   -> pixel-identical copy for the web preview
#   docs/texture-preview-data.js  -> manifest consumed by docs/texture-preview.html
#
# Every shape is drawn from scratch with GDI+ (lines, beziers, ellipses) -- no
# third-party art is traced, traced-over or copied, same rule as the minimap
# mask script.  The glyph set is VECTOR-CLEAN: straight segments are exactly
# straight, arcs keep a constant radius, there is no hand-drawn jitter and no
# soft glow halo.  Icons render at 4x supersampling and are down-scaled through
# a premultiplied buffer, so edges stay crisp without a dark fringe.
#
# Two colour families:
#   * chrome glyphs are built as two crisp layers -- a cream-white core with an
#     ochre (edge) copy nudged down-right beneath it, the "Monet edge".  Both
#     layers are tintable, so SetVertexColor multiplies them into the Monet
#     slot and the rim always lands a shade deeper than the core.
#   * role icons keep semantic colour (resource blue / health green / danger
#     red), keep the painterly dab pass and a soft backing shadow, and are
#     therefore marked tintable = false in the manifest.
#
#   powershell -ExecutionPolicy Bypass -File tools\make-ui-textures.ps1

param(
    [string]$OutDir      = (Join-Path $PSScriptRoot "..\Assets\Textures"),
    [string]$PreviewDir  = (Join-Path $PSScriptRoot "..\docs\texture-preview"),
    [string]$ManifestOut = (Join-Path $PSScriptRoot "..\docs\texture-preview-data.js")
)

# Only the .tga ships.  The game cannot read PNG, so a second copy of every icon inside the addon
# folder is dead weight; the .png twin exists purely so docs/texture-preview.html can show the pixels
# in a browser (and so the self-check can compare a PNG round-trip).  PreviewDir is gitignored.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:SS = 4                      # supersample factor

# -- Monet palette (mirrors Utils/Color.lua FALLBACK + LibMonetColor baseline) --
$PAL = @{
    white     = @(255, 252, 246)    # tintable cream-white base for chrome glyphs
    cream     = @(242, 237, 214)    # highlight wash
    edge      = @(217, 168, 92)     # warm ochre  (edge glow / primary)
    ambient   = @(61, 67, 92)       # cool blue-grey (ambient tint)
    neutral   = @(158, 153, 145)    # Monet grey
    health    = @(79, 191, 99)       # softened health green
    resource  = @(71, 137, 230)      # resource blue
    danger    = @(224, 90, 82)       # softened danger red
    shadow    = @(44, 47, 60)        # dark backing glow for coloured icons
}

# -- Canvas -------------------------------------------------------------------

function New-Canvas {
    param([int]$w, [int]$h)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ B = $bmp; G = $g; W = $w; H = $h }
}

function New-Pen {
    param([float]$width, [int[]]$rgb, [double]$alpha)
    $c = [System.Drawing.Color]::FromArgb([int][math]::Round($alpha * 255), [int]$rgb[0], [int]$rgb[1], [int]$rgb[2])
    $p = New-Object System.Drawing.Pen($c, $width)
    $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $p.MiterLimit = 2.0
    return $p
}

function New-Brush {
    param([int[]]$rgb, [double]$alpha)
    $c = [System.Drawing.Color]::FromArgb([int][math]::Round($alpha * 255), [int]$rgb[0], [int]$rgb[1], [int]$rgb[2])
    return New-Object System.Drawing.SolidBrush($c)
}

# -- Geometry (all coordinates in final icon units, scaled by $k internally) ----

function Get-Line {
    # Exact straight segment: two endpoints, nothing else.  The glyph set is
    # vector-clean by design -- geometry is trusted, never nudged or wobbled.
    param([double]$x1, [double]$y1, [double]$x2, [double]$y2)
    return , @(
        [System.Drawing.PointF]::new([float]$x1, [float]$y1),
        [System.Drawing.PointF]::new([float]$x2, [float]$y2)
    )
}

function Get-Arc {
    # Exact circular arc: constant radius at every step (no wobble term).
    param([double]$cx, [double]$cy, [double]$r, [double]$a0 = 0, [double]$a1 = 360,
          [int]$steps = 48)
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -le $steps; $i++) {
        $a = ($a0 + ($a1 - $a0) * ($i / $steps)) * [math]::PI / 180.0
        $pts.Add([System.Drawing.PointF]::new([float]($cx + [math]::Cos($a) * $r), [float]($cy + [math]::Sin($a) * $r)))
    }
    return , $pts.ToArray()
}

function Get-Bezier3 {
    param([double]$x0, [double]$y0, [double]$x1, [double]$y1,
          [double]$x2, [double]$y2, [double]$x3, [double]$y3, [int]$steps = 28)
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -le $steps; $i++) {
        $t = $i / $steps; $u = 1 - $t
        $x = $u*$u*$u*$x0 + 3*$u*$u*$t*$x1 + 3*$u*$t*$t*$x2 + $t*$t*$t*$x3
        $y = $u*$u*$u*$y0 + 3*$u*$u*$t*$y1 + 3*$u*$t*$t*$y2 + $t*$t*$t*$y3
        $pts.Add([System.Drawing.PointF]::new([float]$x, [float]$y))
    }
    return , $pts.ToArray()
}

function Get-RoundedRect {
    param([double]$x, [double]$y, [double]$w, [double]$h, [double]$r, [int]$cornerSteps = 8)
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    $cx = @(($x + $r), ($x + $w - $r), ($x + $w - $r), ($x + $r))
    $cy = @(($y + $r), ($y + $r), ($y + $h - $r), ($y + $h - $r))
    $a0 = @(180, 270, 0, 90)
    for ($c = 0; $c -lt 4; $c++) {
        $steps = if ($c -eq 0) { 2 } else { $cornerSteps }
        for ($i = 0; $i -le $steps; $i++) {
            $a = ($a0[$c] + 90.0 * $i / $steps) * [math]::PI / 180.0
            $pts.Add([System.Drawing.PointF]::new([float]($cx[$c] + [math]::Cos($a) * $r), [float]($cy[$c] + [math]::Sin($a) * $r)))
        }
    }
    return , $pts.ToArray()
}

function Get-Scaled {
    param([System.Drawing.PointF[]]$pts, [float]$k)
    $out = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    foreach ($p in $pts) { $out.Add([System.Drawing.PointF]::new($p.X * $k, $p.Y * $k)) }
    return , $out.ToArray()
}

# A GraphicsPath holding several disconnected subpaths (StartFigure between
# them, so the stroke never bridges two glyphs).
function New-Path {
    param([object[]]$strokes, [float]$k)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    foreach ($s in $strokes) {
        $pts = Get-Scaled ([System.Drawing.PointF[]]$s) $k
        $path.StartFigure()
        $path.AddLines($pts)
    }
    return $path
}

# -- Painting -----------------------------------------------------------------

function Draw-Strokes {
    param($g, [object[]]$strokes, [float]$k, [double]$width, [int[]]$rgb, [double]$alpha = 1.0)
    $pen = New-Pen ($width * $k) $rgb $alpha
    try {
        foreach ($s in $strokes) {
            $g.G.DrawLines($pen, (Get-Scaled ([System.Drawing.PointF[]]$s) $k))
        }
    } finally { $pen.Dispose() }
}

# Stroke a closed path directly (for shapes whose outline must follow the fill,
# e.g. the union outline of the healer cross).
function Draw-PathStroke {
    param($g, [System.Drawing.Drawing2D.GraphicsPath]$path, [float]$k, [double]$width,
          [int[]]$rgb, [double]$alpha = 1.0)
    $pen = New-Pen ($width * $k) $rgb $alpha
    try { $g.DrawPath($pen, $path) } finally { $pen.Dispose() }
}

# -- Exact-vector two-tone helpers --------------------------------------------

# Polyline through interleaved x,y pairs: Get-Poly @(16, 26, 32, 40, 48, 26)
function Get-Poly {
    param([double[]]$xy)
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt $xy.Length; $i += 2) {
        $pts.Add([System.Drawing.PointF]::new([float]$xy[$i], [float]$xy[$i + 1]))
    }
    return , $pts.ToArray()
}

function Get-Offset {
    param([System.Drawing.PointF[]]$pts, [double]$dx, [double]$dy)
    $out = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    foreach ($p in $pts) { $out.Add([System.Drawing.PointF]::new([float]($p.X + $dx), [float]($p.Y + $dy))) }
    return , $out.ToArray()
}

# The Monet edge: an ochre copy of every stroke nudged down-right, then the
# cream-white core on top.  Reads as a crisp vector glyph with a warm painted
# rim; a vertex tint multiplies both layers, so the rim always lands a shade
# deeper than the core whatever colour the slot is.
function Draw-TwoTone {
    param($c, [object[]]$strokes, [float]$k, [double]$width,
          [int[]]$core, [int[]]$rim, [double]$off = 2.2,
          [double]$coreAlpha = 1.0, [double]$rimAlpha = 1.0)
    $shifted = @()
    foreach ($s in $strokes) { $shifted += , (Get-Offset ([System.Drawing.PointF[]]$s) $off $off) }
    Draw-Strokes $c $shifted $k $width $rim $rimAlpha
    Draw-Strokes $c $strokes $k $width $core $coreAlpha
}

# Same two-tone idea for filled discs (radio dot, corner finials).
function Fill-DiscTwoTone {
    param($c, [double]$cx, [double]$cy, [double]$r, [float]$k,
          [int[]]$core, [int[]]$rim, [double]$off = 2.0,
          [double]$coreAlpha = 1.0, [double]$rimAlpha = 1.0)
    $g = $c.G
    $brush = New-Brush $rim $rimAlpha
    try {
        $g.FillEllipse($brush, [float](($cx + $off - $r) * $k), [float](($cy + $off - $r) * $k),
                       [float](2 * $r * $k), [float](2 * $r * $k))
    } finally { $brush.Dispose() }
    $brush = New-Brush $core $coreAlpha
    try {
        $g.FillEllipse($brush, [float](($cx - $r) * $k), [float](($cy - $r) * $k),
                       [float](2 * $r * $k), [float](2 * $r * $k))
    } finally { $brush.Dispose() }
}

# Soft halo behind a stroke: paint the line into a premultiplied layer, blur it
# by down/up-scaling (cheap Gaussian stand-in), composite it behind.
function Add-PathGlow {
    param($g, [object[]]$strokes, [float]$k, [double]$width, [int[]]$rgb,
          [double]$alpha = 0.5, [double]$extra = 8.0, [double]$blur = 7.0, [int]$W = 0, [int]$H = 0)
    $layer = New-Canvas $W $H
    Draw-Strokes $layer $strokes $k $width $rgb $alpha
    # widen: second pass slightly fatter grows the halo before blurring
    Draw-Strokes $layer $strokes $k ($width + $extra) $rgb ($alpha * 0.45)
    $blurred = Get-Blurred $layer.B $blur
    try { $g.DrawImage($blurred, 0, 0, $W, $H) } finally { $blurred.Dispose(); $layer.B.Dispose() }
}

function Add-SoftShape {
    # blurred fill (plate / halo) for a closed path
    param($g, [System.Drawing.Drawing2D.GraphicsPath]$path, [int[]]$rgb,
          [double]$alpha = 0.5, [double]$blur = 6.0, [int]$W = 0, [int]$H = 0)
    $layer = New-Canvas $W $H
    $brush = New-Brush $rgb $alpha
    try { $g2 = $layer.G; $g2.FillPath($brush, $path) } finally { $brush.Dispose() }
    $blurred = Get-Blurred $layer.B $blur
    try { $g.DrawImage($blurred, 0, 0, $W, $H) } finally { $blurred.Dispose(); $layer.B.Dispose() }
}

function Get-Blurred {
    # premultiplied down/upscale == soft blur with no dark fringe
    param([System.Drawing.Bitmap]$src, [double]$factor)
    $w = $src.Width; $h = $src.Height
    $w2 = [int][math]::Max(2, $w / $factor); $h2 = [int][math]::Max(2, $h / $factor)
    $pre = $src.Clone((New-Object System.Drawing.Rectangle(0, 0, $w, $h)), [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)

    $small = New-Object System.Drawing.Bitmap($w2, $h2, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $sg = [System.Drawing.Graphics]::FromImage($small)
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $sg.DrawImage($pre, 0, 0, $w2, $h2); $sg.Dispose()

    $out = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $og = [System.Drawing.Graphics]::FromImage($out)
    $og.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $og.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $og.DrawImage($small, 0, 0, $w, $h); $og.Dispose()

    $pre.Dispose(); $small.Dispose()
    return $out
}

# Broken-colour dabs scattered along strokes (the impressionist pass).
function Add-StrokeDabs {
    param($g, [object[]]$strokes, [float]$k, [int[]]$rgb, [int]$count,
          [double]$spread = 4.0, [double]$rMin = 1.4, [double]$rMax = 3.2,
          [double]$aMin = 0.05, [double]$aMax = 0.18, [double]$jitter = 16,
          [System.Random]$rng)
    for ($i = 0; $i -lt $count; $i++) {
        $s = $strokes[$rng.Next(0, $strokes.Count)]
        $s = [System.Drawing.PointF[]]$s
        if ($s.Length -lt 2) { continue }
        $idx = $rng.Next(0, $s.Length - 1)
        $p = $s[$idx]; $q = $s[[math]::Min($idx + 1, $s.Length - 1)]
        $dx = $q.X - $p.X; $dy = $q.Y - $p.Y
        $len = [math]::Max(0.001, [math]::Sqrt($dx * $dx + $dy * $dy))
        $nx = -$dy / $len; $ny = $dx / $len
        $off = ($rng.NextDouble() - 0.5) * $spread
        $px = ($p.X + $nx * $off) * $k; $py = ($p.Y + $ny * $off) * $k
        $r = ($rMin + $rng.NextDouble() * ($rMax - $rMin)) * $k
        $a = $aMin + $rng.NextDouble() * ($aMax - $aMin)
        $j = $rng.Next([int](-$jitter), [int]($jitter) + 1)
        $col = @(
            [int][math]::Min(255, [math]::Max(0, $rgb[0] + $j)),
            [int][math]::Min(255, [math]::Max(0, $rgb[1] + $j)),
            [int][math]::Min(255, [math]::Max(0, $rgb[2] + $j))
        )
        $brush = New-Brush $col $a
        $angle = [math]::Atan2($dy, $dx) * 180.0 / [math]::PI + ($rng.NextDouble() - 0.5) * 40
        try {
            $g.TranslateTransform($px, $py)
            $g.RotateTransform([float]$angle)
            $g.FillEllipse($brush, [float](-$r * 1.7), [float](-$r * 0.85), [float]($r * 3.4), [float]($r * 1.7))
            $g.ResetTransform()
        } finally { $brush.Dispose() }
    }
}

# Dabs clipped to a closed path (for filled shapes such as the role glyphs).
function Add-AreaDabs {
    param($g, [System.Drawing.Drawing2D.GraphicsPath]$path, [float]$k,
          [System.Drawing.RectangleF]$bounds, [int[]]$rgb, [int]$count,
          [double]$rMin = 1.6, [double]$rMax = 4.0, [double]$aMin = 0.05,
          [double]$aMax = 0.2, [double]$jitter = 18, [System.Random]$rng)
    $old = $g.Clip
    $g.Clip = New-Object System.Drawing.Region($path)
    try {
        for ($i = 0; $i -lt $count; $i++) {
            $px = ($bounds.Left + $rng.NextDouble() * $bounds.Width) * $k
            $py = ($bounds.Top + $rng.NextDouble() * $bounds.Height) * $k
            $r = ($rMin + $rng.NextDouble() * ($rMax - $rMin)) * $k
            $a = $aMin + $rng.NextDouble() * ($aMax - $aMin)
            $j = $rng.Next([int](-$jitter), [int]($jitter) + 1)
            $col = @(
                [int][math]::Min(255, [math]::Max(0, $rgb[0] + $j)),
                [int][math]::Min(255, [math]::Max(0, $rgb[1] + $j)),
                [int][math]::Min(255, [math]::Max(0, $rgb[2] + $j))
            )
            $brush = New-Brush $col $a
            try {
                $g.TranslateTransform($px, $py)
                $g.RotateTransform([float]($rng.NextDouble() * 180))
                $g.FillEllipse($brush, [float](-$r * 1.6), [float](-$r * 0.9), [float]($r * 3.2), [float]($r * 1.8))
                $g.ResetTransform()
            } finally { $brush.Dispose() }
        }
    } finally { $g.Clip = $old }
}

# Final anti-aliased down-scale: premultiplied source -> straight-alpha target.
function Scale-Down {
    param([System.Drawing.Bitmap]$src, [int]$w, [int]$h)
    $pre = $src.Clone((New-Object System.Drawing.Rectangle(0, 0, $src.Width, $src.Height)),
                      [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $out = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $og = [System.Drawing.Graphics]::FromImage($out)
    $og.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $og.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $og.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $og.Clear([System.Drawing.Color]::Transparent)
    $og.DrawImage($pre, 0, 0, $w, $h)
    $og.Dispose(); $pre.Dispose()
    return $out
}

# -- Output: PNG (preview) + TGA (game) ---------------------------------------

# Top-down BGRA bytes straight out of a rendered bitmap, orientation proved
# against GetPixel so a LockBits stride surprise can never silently flip art.
function Get-TopDownBytes {
    param([System.Drawing.Bitmap]$bmp)
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = [math]::Abs($bd.Stride)
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
    } finally { $bmp.UnlockBits($bd) }

    if ($bd.Stride -lt 0) { throw "unexpected negative stride from LockBits" }
    $row0 = $bmp.GetPixel(0, 0)
    $rowL = $bmp.GetPixel(0, $h - 1)
    $topDown = ($buf[0] -eq $row0.B -and $buf[1] -eq $row0.G -and $buf[2] -eq $row0.R -and $buf[3] -eq $row0.A)
    $flipped = ($buf[($h - 1) * $stride] -eq $row0.B -and $buf[($h - 1) * $stride + 1] -eq $row0.G -and
                $buf[($h - 1) * $stride + 2] -eq $row0.R -and $buf[($h - 1) * $stride + 3] -eq $row0.A)
    if ($topDown) {
        if ($buf[$h * $stride - $stride] -ne $rowL.B) { throw "LockBits row order check failed" }
        return , $buf
    }
    if ($flipped) {
        # rows come back bottom-up: reverse them with bulk copies
        $out = New-Object byte[] ($stride * $h)
        for ($y = 0; $y -lt $h; $y++) {
            [Array]::Copy($buf, ($h - 1 - $y) * $stride, $out, $y * $stride, $stride)
        }
        return , $out
    }
    throw "LockBits pixel layout could not be matched against GetPixel"
}

# 32-bit uncompressed TGA, bottom-left origin (descriptor 0x08) like the
# existing minimap mask, so row order is explicit and auditable.
function Write-Tga {
    param([string]$path, [System.Drawing.Bitmap]$bmp, [byte[]]$topDown)
    $w = $bmp.Width; $h = $bmp.Height
    $rowBytes = $w * 4
    $all = New-Object byte[] (18 + $rowBytes * $h)
    $all[2] = 2                                    # image type: uncompressed true-colour
    [Array]::Copy([BitConverter]::GetBytes([uint16]$w), 0, $all, 12, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$h), 0, $all, 14, 2)
    $all[16] = 32                                  # bits per pixel
    $all[17] = 0x08                                # 8 alpha bits, bottom-left origin
    for ($y = 0; $y -lt $h; $y++) {
        [Array]::Copy($topDown, ($h - 1 - $y) * $rowBytes, $all, 18 + $y * $rowBytes, $rowBytes)
    }
    [System.IO.File]::WriteAllBytes($path, $all)
    return $all.Length
}

# GDI+ leaves RGB = 0,0,0 in fully transparent pixels, and the game's mip chain plus bilinear
# filtering then drag that black into the visible edge -- a dark halo, worst on the 64px glyphs that
# are drawn at 16-22px.  Paint the transparent area with the art's own alpha-weighted average colour
# instead: alpha stays 0, so nothing on screen changes except the fringe, and pure black is never
# what "transparent" is made of.
function Fill-TransparentRgb {
    param([System.Drawing.Bitmap]$bmp)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
                        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $n = $bd.Stride * $bd.Height
        $buf = New-Object byte[] $n
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $n)

        $sumB = 0; $sumG = 0; $sumR = 0; $sumA = 0
        for ($i = 0; $i -lt $n; $i += 4) {
            $a = [int]$buf[$i + 3]
            if ($a -gt 0) {
                $sumB += [int]$buf[$i] * $a
                $sumG += [int]$buf[$i + 1] * $a
                $sumR += [int]$buf[$i + 2] * $a
                $sumA += $a
            }
        }
        if ($sumA -eq 0) { return }

        $fillB = [byte][math]::Round($sumB / $sumA)
        $fillG = [byte][math]::Round($sumG / $sumA)
        $fillR = [byte][math]::Round($sumR / $sumA)
        for ($i = 0; $i -lt $n; $i += 4) {
            if ($buf[$i + 3] -eq 0) {
                $buf[$i] = $fillB; $buf[$i + 1] = $fillG; $buf[$i + 2] = $fillR
            }
        }
        [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $bd.Scan0, $n)
    } finally { $bmp.UnlockBits($bd) }
}

function Test-Alpha {
    # decoded TGA bytes (bottom-up) vs the PNG ground truth: hash equality plus
    # two structural rules (transparent margins, non-empty glyph).  $fullBleed
    # assets fill the whole canvas (status-bar gradients) and skip the margins.
    param([string]$tgaPath, [string]$pngPath, [System.Drawing.Bitmap]$rendered,
          [string]$name, [bool]$fullBleed = $false)
    $tga = [System.IO.File]::ReadAllBytes($tgaPath)
    if ($tga[2] -ne 2 -or $tga[16] -ne 32) { throw "$name : unexpected TGA header" }
    $w = [int]$tga[12] + [int]$tga[13] * 256
    $h = [int]$tga[14] + [int]$tga[15] * 256
    $rowBytes = $w * 4

    # bottom-up TGA -> top-down, so it can be compared with the render
    $flat = New-Object byte[] ($rowBytes * $h)
    for ($y = 0; $y -lt $h; $y++) {
        [Array]::Copy($tga, 18 + $y * $rowBytes, $flat, ($h - 1 - $y) * $rowBytes, $rowBytes)
    }
    $ref = Get-TopDownBytes $rendered

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $a = [BitConverter]::ToString($md5.ComputeHash($flat))
        $b = [BitConverter]::ToString($md5.ComputeHash($ref))
    } finally { $md5.Dispose() }
    if ($a -ne $b) { throw "$name : TGA pixels differ from the rendered PNG source" }

    # transparent corners (glyphs keep a clean margin) + enough visible pixels
    if (-not $fullBleed) {
        $corners = @(0, (($w - 1) * 4), (($h - 1) * $rowBytes), ($h * $rowBytes - 4))
        foreach ($ci in $corners) {
            if ($flat[$ci + 3] -ne 0) { throw "$name : corner pixel is not transparent (margin lost)" }
        }
    }
    $seen = 0; $solid = 0
    for ($i = 3; $i -lt $flat.Length; $i += 16) {
        $seen++
        if ($flat[$i] -gt 8) { $solid++ }
    }
    if ($seen -eq 0 -or ($solid / $seen) -lt 0.01) { throw "$name : glyph is (nearly) empty" }
    return $solid / $seen
}

# -- Shared shape helpers -----------------------------------------------------

function New-PolyPath {
    # closed polygon path from final-unit points
    param([System.Drawing.PointF[]]$pts, [float]$k)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.StartFigure()
    $path.AddLines((Get-Scaled $pts $k))
    $path.CloseFigure()
    return $path
}

function Add-RoundedRectPath {
    param($path, [double]$x, [double]$y, [double]$w, [double]$h, [double]$r, [float]$k)
    $path.StartFigure()
    $path.AddLines((Get-Scaled (Get-RoundedRect $x $y $w $h $r) $k))
    $path.CloseFigure()
}

function Mix-Color {
    param([int[]]$from, [int[]]$to, [double]$t)
    return @(
        [int][math]::Round($from[0] + ($to[0] - $from[0]) * $t),
        [int][math]::Round($from[1] + ($to[1] - $from[1]) * $t),
        [int][math]::Round($from[2] + ($to[2] - $from[2]) * $t)
    )
}

function New-VGradient {
    param([double]$x, [double]$y, [double]$w, [double]$h, [float]$k,
          [int[]]$top, [int[]]$bottom, [double]$alphaTop = 1.0, [double]$alphaBottom = 1.0)
    $rect = New-Object System.Drawing.RectangleF([float]($x * $k), [float]($y * $k), [float]($w * $k), [float]($h * $k))
    $c1 = [System.Drawing.Color]::FromArgb([int][math]::Round($alphaTop * 255), [int]$top[0], [int]$top[1], [int]$top[2])
    $c2 = [System.Drawing.Color]::FromArgb([int][math]::Round($alphaBottom * 255), [int]$bottom[0], [int]$bottom[1], [int]$bottom[2])
    return New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
}

# -- Asset registry -----------------------------------------------------------

$assets = New-Object 'System.Collections.Generic.List[object]'

function Add-Asset {
    param([string]$name, [string]$group, [string]$title, [int]$w, [int]$h,
          [bool]$tintable, [string]$use, [string]$note, [scriptblock]$body,
          [bool]$fullBleed = $false)
    # The client mips and filters every texture, so a canvas that is not a power of two gets padded by
    # the engine at load time anyway: author at the size the art actually wants and keep it a power of
    # two, so that padding is never a surprise.
    foreach ($dim in @($w, $h)) {
        if ($dim -lt 1 -or (($dim -band ($dim - 1)) -ne 0)) {
            throw "$name : ${dim}px is not a power of two"
        }
    }
    $assets.Add([pscustomobject]@{
        name = $name; group = $group; title = $title; w = $w; h = $h
        tintable = $tintable; use = $use; note = $note; body = $body
        fullBleed = $fullBleed
    })
}

# -- Window controls ----------------------------------------------------------

function New-CloseBody {
    param([string]$state)
    return ({
        param($c, $k, $pal, $rng)
        $g = $c.G

        if ($state -ne 'normal') {
            # crisp circular plate (no blur): hover/push affordance, tintable
            $plateA = if ($state -eq 'hover') { 0.16 } else { 0.32 }
            $brush = New-Brush $pal.white $plateA
            try { $g.FillEllipse($brush, [float](8 * $k), [float](8 * $k), [float](48 * $k), [float](48 * $k)) }
            finally { $brush.Dispose() }
        }

        # exact 45-degree cross, cream core over the ochre side-layer
        $strokes = @((Get-Line 18 18 46 46), (Get-Line 46 18 18 46))
        Draw-TwoTone -c $c -strokes $strokes -k $k -width 6.0 -core $pal.white -rim $pal.edge
    }.GetNewClosure())
}

Add-Asset 'monet_close_normal' 'window' '关闭 · 常态' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '精确 45° 交叉双笔：奶白芯 + 赭金侧影' (New-CloseBody 'normal')
Add-Asset 'monet_close_hover'  'window' '关闭 · 悬停' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '同形 + 清晰圆形底板（alpha 0.16，无光晕）' (New-CloseBody 'hover')
Add-Asset 'monet_close_push'   'window' '关闭 · 按下' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '同形 + 更实底板（alpha 0.32）' (New-CloseBody 'push')

Add-Asset 'monet_win_minimize' 'window' '最小化' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '水平单笔，圆头端点，双色层次' ({
    param($c, $k, $pal, $rng)
    Draw-TwoTone -c $c -strokes @(,(Get-Line 18 32 46 32)) -k $k -width 6.0 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_win_maximize' 'window' '最大化' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '精确圆角方框（正圆角、零抖动）' ({
    param($c, $k, $pal, $rng)
    Draw-TwoTone -c $c -strokes @(,(Get-RoundedRect 17 17 30 30 5)) -k $k -width 5.6 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_win_restore' 'window' '还原' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '两个错落圆角框，前框挖空后框' ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $back  = Get-RoundedRect 24 14 26 26 4
    $front = Get-RoundedRect 14 24 26 26 4

    Draw-TwoTone -c $c -strokes @(,$back) -k $k -width 5.2 -core $pal.white -rim $pal.edge `
                 -coreAlpha 0.75 -rimAlpha 0.75

    # knock the back frame out where the front window covers it (front outer
    # box + its rim, so no gold sliver survives behind the front frame)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $erase = New-Brush @(0, 0, 0) 0.0
    try { $g.FillRectangle($erase, [float](11 * $k), [float](21 * $k), [float](33 * $k), [float](33 * $k)) }
    finally { $erase.Dispose(); $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver }

    Draw-TwoTone -c $c -strokes @(,$front) -k $k -width 5.2 -core $pal.white -rim $pal.edge
})

# -- Small chrome glyphs ------------------------------------------------------

Add-Asset 'monet_check' 'glyph' '勾选' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '两段折线，圆头圆角，双色层次' ({
    param($c, $k, $pal, $rng)
    Draw-TwoTone -c $c -strokes @(,(Get-Poly @(15, 33, 26, 44, 50, 18))) -k $k -width 6.4 `
                 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_radio' 'glyph' '单选点' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '实心圆点：奶白芯 + 赭金侧影（无外晕）' ({
    param($c, $k, $pal, $rng)
    Fill-DiscTwoTone -c $c -cx 32 -cy 32 -r 10.5 -k $k -core $pal.white -rim $pal.edge -off 2.4
})

Add-Asset 'monet_plus' 'glyph' '展开 (+)' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '等长双笔画，十字精确对齐' ({
    param($c, $k, $pal, $rng)
    $strokes = @((Get-Line 32 16 32 48), (Get-Line 16 32 48 32))
    Draw-TwoTone -c $c -strokes $strokes -k $k -width 6.0 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_minus' 'glyph' '收起 (−)' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '水平单笔，零倾斜' ({
    param($c, $k, $pal, $rng)
    Draw-TwoTone -c $c -strokes @(,(Get-Line 16 32 48 32)) -k $k -width 6.0 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_chevron_down' 'glyph' '下拉 ▾' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '对称折角，圆头' ({
    param($c, $k, $pal, $rng)
    Draw-TwoTone -c $c -strokes @(,(Get-Poly @(16, 26, 32, 40, 48, 26))) -k $k -width 6.4 `
                 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_chevron_up' 'glyph' '收起 ▴' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '对称折角，圆头' ({
    param($c, $k, $pal, $rng)
    Draw-TwoTone -c $c -strokes @(,(Get-Poly @(16, 38, 32, 24, 48, 38))) -k $k -width 6.4 `
                 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_arrow_left' 'glyph' '翻页 ←' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '水平杆 + 45° 箭头' ({
    param($c, $k, $pal, $rng)
    $strokes = @((Get-Line 46 32 18 32), (Get-Poly @(30, 20, 18, 32, 30, 44)))
    Draw-TwoTone -c $c -strokes $strokes -k $k -width 6.0 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_arrow_right' 'glyph' '翻页 →' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '水平杆 + 45° 箭头' ({
    param($c, $k, $pal, $rng)
    $strokes = @((Get-Line 18 32 46 32), (Get-Poly @(34, 20, 46, 32, 34, 44)))
    Draw-TwoTone -c $c -strokes $strokes -k $k -width 6.0 -core $pal.white -rim $pal.edge
})

Add-Asset 'monet_search' 'glyph' '搜索' 64 64 $true 'SetTexture 后按主题色 SetVertexColor' '正圆 + 45° 斜柄' ({
    param($c, $k, $pal, $rng)
    $strokes = @((Get-Arc 26.5 26.5 13.5 0 360 64), (Get-Line 36 36 48 48))
    Draw-TwoTone -c $c -strokes $strokes -k $k -width 6.0 -core $pal.white -rim $pal.edge
})

# -- Role icons (semantic colour, never vertex-tinted) ------------------------

Add-Asset 'monet_role_tank' 'role' '职责 · 坦克' 64 64 $false '直接 SetTexture，勿再 SetVertexColor' '盾牌：渐变填充 + 奶油描边 + 暗底投影' ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $shield = @()
    $shield += Get-Line 15 13 49 13
    $shield += Get-Line 49 13 49 31
    $shield += Get-Bezier3 49 31 49 44 43 52 32 53 14
    $shield += Get-Bezier3 32 53 21 52 15 44 15 31 14
    $shield += Get-Line 15 31 15 13

    $path = New-Path @(,$shield) $k
    Add-SoftShape -g $g -path $path -rgb $pal.shadow -alpha 0.45 -blur 6.5 -W $c.W -H $c.H

    $fill = New-VGradient 15 13 34 41 $k (Mix-Color $pal.resource @(255, 255, 255) 0.42) $pal.resource
    try { $g.FillPath($fill, $path) } finally { $fill.Dispose() }

    Add-AreaDabs -g $g -path $path -k $k -bounds (New-Object System.Drawing.RectangleF(15, 13, 34, 40)) `
                 -rgb (Mix-Color $pal.resource @(255, 255, 255) 0.55) -count 34 -rMin 1.5 -rMax 3.2 `
                 -aMin 0.06 -aMax 0.15 -jitter 10 -rng $rng

    # inner shield ridge for depth
    $ridge = @(,(Get-Bezier3 32 19 28 27 27 35 32 45 12))
    Draw-Strokes -g $c -strokes $ridge -k $k -width 2.4 -rgb (Mix-Color $pal.resource @(255, 255, 255) 0.7) -alpha 0.55

    Draw-Strokes -g $c -strokes @(,$shield) -k $k -width 4.0 -rgb $pal.cream -alpha 0.92
    Add-StrokeDabs -g $g -strokes @(,$shield) -k $k -rgb $pal.cream -count 30 -spread 3.2 `
                   -aMin 0.08 -aMax 0.18 -jitter 12 -rng $rng
})

Add-Asset 'monet_role_heal' 'role' '职责 · 治疗' 64 64 $false '直接 SetTexture，勿再 SetVertexColor' '十字：圆角填充 + 奶油描边 + 暗底投影' ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
    Add-RoundedRectPath $path 26 12 12 40 5 $k
    Add-RoundedRectPath $path 12 26 40 12 5 $k

    Add-SoftShape -g $g -path $path -rgb $pal.shadow -alpha 0.45 -blur 6.5 -W $c.W -H $c.H

    $fill = New-VGradient 12 12 40 40 $k (Mix-Color $pal.health @(255, 255, 255) 0.45) $pal.health
    try { $g.FillPath($fill, $path) } finally { $fill.Dispose() }

    Add-AreaDabs -g $g -path $path -k $k -bounds (New-Object System.Drawing.RectangleF(12, 12, 40, 40)) `
                 -rgb (Mix-Color $pal.health $pal.cream 0.6) -count 40 -rMin 1.5 -rMax 3.4 `
                 -aMin 0.06 -aMax 0.16 -jitter 14 -rng $rng

    # one outline around the union of both bars, never two crossing rectangles
    Draw-PathStroke -g $g -path $path -k $k -width 3.4 -rgb $pal.cream -alpha 0.92
    Add-StrokeDabs -g $g -strokes @((Get-RoundedRect 26 12 12 40 5), (Get-RoundedRect 12 26 40 12 5)) `
                   -k $k -rgb $pal.cream -count 30 -spread 3.0 -aMin 0.08 -aMax 0.18 -jitter 12 -rng $rng
})

Add-Asset 'monet_role_dps' 'role' '职责 · 输出' 64 64 $false '直接 SetTexture，勿再 SetVertexColor' '双剑交叉：笔画 + 护手 + 暗底投影' ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $mirror = {
        param($pts)
        $out = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        foreach ($p in $pts) { $out.Add([System.Drawing.PointF]::new([float](64 - $p.X), $p.Y)) }
        return , $out.ToArray()
    }
    $gc0 = 22.4; $hx = 4.3
    $blade  = Get-Line 16 48 48 16
    $blade2 = & $mirror $blade
    $guard  = Get-Line ($gc0 - $hx) (41.6 - $hx) ($gc0 + $hx) (41.6 + $hx)
    $guard2 = & $mirror $guard

    $all = @($blade, $blade2, $guard, $guard2)
    Add-PathGlow -g $g -strokes $all -k $k -width 5.2 -rgb $pal.shadow -alpha 0.5 -extra 8 -blur 8.5 -W $c.W -H $c.H

    # blades: crimson core over a deep-wine side-layer (same two-tone idea,
    # fixed colours instead of a tintable pair)
    Draw-TwoTone -c $c -strokes @($blade, $blade2) -k $k -width 5.4 -off 1.8 `
                 -core (Mix-Color $pal.danger @(255, 255, 255) 0.12) -rim (Mix-Color $pal.danger $pal.shadow 0.55)
    Draw-TwoTone -c $c -strokes @($guard, $guard2) -k $k -width 4.2 -off 1.6 `
                 -core $pal.cream -rim $pal.edge

    # catch-light along the upper-left edge of each blade
    foreach ($s in @($blade, $blade2)) {
        $lit = Get-Offset ([System.Drawing.PointF[]]$s) -0.9 -0.9
        Draw-Strokes -g $c -strokes @(,$lit) -k $k -width 1.5 -rgb $pal.cream -alpha 0.5
    }

    # hilts
    foreach ($pt in @(@(14.5, 49.5), @(49.5, 49.5))) {
        Fill-DiscTwoTone -c $c -cx $pt[0] -cy $pt[1] -r 3.4 -k $k -core $pal.cream -rim $pal.edge -off 1.4
    }
})

# -- Decorative ---------------------------------------------------------------

Add-Asset 'monet_brush_stroke' 'deco' '笔触长条' 256 32 $true '标题条 / 分隔线 / 高亮条，按主题色 SetVertexColor' '锥形笔道：奶白芯 + 赭金侧影（无碎点、无光晕）' ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    # exact spindle outline: a smooth tapered lens from (8,16) to (248,16)
    $top = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    $bot = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    $N = 96
    for ($i = 0; $i -le $N; $i++) {
        $t = $i / $N
        $x = 8.0 + 240.0 * $t
        $h = 7.0 * [math]::Pow([math]::Sin($t * [math]::PI), 0.5)
        $top.Add([System.Drawing.PointF]::new([float]($x * $k), [float]((16 - $h) * $k)))
        $bot.Add([System.Drawing.PointF]::new([float]($x * $k), [float]((16 + $h) * $k)))
    }
    $outline = New-Object System.Drawing.Drawing2D.GraphicsPath
    $outline.StartFigure()
    $outline.AddLines($top.ToArray())
    $rev = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = $bot.Count - 1; $i -ge 0; $i--) { $rev.Add($bot[$i]) }
    $outline.AddLines($rev.ToArray())
    $outline.CloseFigure()

    # ochre under-layer nudged down-right, cream core on top (the Monet edge)
    $brush = New-Brush $pal.edge 1.0
    try {
        $g.TranslateTransform([float](2.2 * $k), [float](2.2 * $k))
        $g.FillPath($brush, $outline)
        $g.ResetTransform()
    } finally { $brush.Dispose() }
    $brush = New-Brush $pal.white 1.0
    try { $g.FillPath($brush, $outline) } finally { $brush.Dispose() }
    $outline.Dispose()
})

Add-Asset 'monet_corner' 'deco' '边角饰纹' 64 64 $true '面板四角点缀，按主题色 SetVertexColor' '四分之一正圆弧 + 端点圆点' ({
    param($c, $k, $pal, $rng)
    $arc = Get-Arc 46 46 38 180 270 40
    Draw-TwoTone -c $c -strokes @(,$arc) -k $k -width 5.2 -core $pal.white -rim $pal.edge
    foreach ($e in @(@(8, 46), @(46, 8))) {
        Fill-DiscTwoTone -c $c -cx $e[0] -cy $e[1] -r 3.0 -k $k -core $pal.white -rim $pal.edge -off 1.6
    }
})

Add-Asset 'monet_canvas_weave' 'deco' '画布织纹（平铺）' 64 64 $true `
    '按钮/背包格子底纹：无缝平铺，叠在图标之下，按主题色 SetVertexColor' `
    '无缝细经纬网格：横竖细线连续交织、交叉点微亮，缝隙透明（画布底），非填充方格' -fullBleed $true ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $pitch  = 8      # thread pitch, final px
    $tw     = 3      # thread thickness, final px -> thin lines, 5px transparent gap
    $cells  = 8      # 64 / 8 -> seamless (8 even, so both axes wrap clean)

    # Threads are drawn as CONTINUOUS thin lines in both directions.  The old
    # version filled every other 6px cell, which read as a black/white
    # checkerboard; a real weave reads as a fine grid of crossing threads with
    # transparent gaps, so keep the lines thin and let the holes breathe.
    # SourceOver makes each crossing stack to ~0.64 alpha -> the knots land a
    # shade brighter than the threads, which is exactly where cloth catches light.

    # weft (horizontal), one continuous line per row
    $brush = New-Brush $pal.white 0.42
    try {
        for ($row = 0; $row -lt $cells; $row++) {
            $y = $row * $pitch
            $g.FillRectangle($brush, 0, [float]($y * $k), [float]$c.W, [float]($tw * $k))
        }
    } finally { $brush.Dispose() }

    # warp (vertical), one continuous line per column, crossing the weft
    $brush = New-Brush $pal.white 0.42
    try {
        for ($col = 0; $col -lt $cells; $col++) {
            $x = $col * $pitch
            $g.FillRectangle($brush, [float]($x * $k), 0, [float]($tw * $k), [float]$c.H)
        }
    } finally { $brush.Dispose() }
})

Add-Asset 'monet_diagonal_weave' 'deco' '交叉斜纹（平铺）' 64 64 $true `
    '按钮/背包格子底纹（斜纹版）：无缝平铺，叠在图标之下，按主题色 SetVertexColor' `
    '无缝 45° 交叉斜纹（/ 与 \ 双向），线距16、线宽3、缝隙透明，作材质底层' -fullBleed $true ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $pitch = 16     # period along (x+y) / (x-y); 64 % 16 == 0 -> seamless, and
                    # larger period = fewer lines = the lower density requested

    # Two sets of exact-45° lines crossing, giving a crosshatch.  Lines are kept
    # thin with transparent gaps so it reads as woven diagonal gauze (the
    # Andromeda "stripes" flavour), not filled cells.
    #   "/"  x + y = c  -> from (c,0) to (c-64,64)
    #   "\"  x - y = c  -> from (c,0) to (c+64,64)
    # Every c is a multiple of the pitch, so the phase wraps exactly at the tile
    # edge (64 is a multiple of 8) and the pattern tiles with no seam.

    $strokes = New-Object 'System.Collections.Generic.List[object]'
    for ($c0 = 0; $c0 -le 128; $c0 += $pitch)      { $strokes.Add((Get-Line $c0 0 ($c0 - 64) 64)) }
    for ($c0 = -64; $c0 -le 64; $c0 += $pitch)     { $strokes.Add((Get-Line $c0 0 ($c0 + 64) 64)) }

    Draw-Strokes -g $c -strokes $strokes.ToArray() -k $k -width 3.0 -rgb $pal.white -alpha 0.42
})

# -- Status bars ----------------------------------------------------------------

Add-Asset 'monet_barfill' 'bar' '状态条填充' 16 16 $true `
    '血条/施法条填充：SetStatusBarTexture 后按角色色/主题色 SetVertexColor' `
    '全幅纵向渐变（顶亮底沉），拉伸到任意条高都有体积感' ({
    param($c, $k, $pal, $rng)
    # full-bleed vertical gradient: white at the top, a shade mixed toward the
    # ambient tone at the bottom -- subtle, but it survives any multiply tint
    $t = $pal.white
    $bot0 = [int][math]::Round($t[0] + ($pal.ambient[0] - $t[0]) * 0.25)
    $bot1 = [int][math]::Round($t[1] + ($pal.ambient[1] - $t[1]) * 0.25)
    $bot2 = [int][math]::Round($t[2] + ($pal.ambient[2] - $t[2]) * 0.25)
    $zero = [float]0
    $rw = [float]$c.W
    $rh = [float]$c.H
    $top = [System.Drawing.Color]::FromArgb(255, $t[0], $t[1], $t[2])
    $bot = [System.Drawing.Color]::FromArgb(255, $bot0, $bot1, $bot2)
    $rect = New-Object System.Drawing.RectangleF($zero, $zero, $rw, $rh)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bot, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    try { $c.G.FillRectangle($brush, $rect) } finally { $brush.Dispose() }
}) -fullBleed $true

# -- Structural ---------------------------------------------------------------

# The ring is authored at its final size (16x16, arc radius 3, ring 2 wide),
# because a backdrop samples its corner region 1:1: 1 texture px = 1 UI unit.
# Utils/Widget.lua pairs it with edgeSize = 3 and insets = 2, so the visible
# border is 2 UI units and the 1px transparent band inside the ring shows the
# frame's own background instead of a seam.
# 16 and not 12: the canvas has to be a power of two, and only its outermost
# edgeSize (3) pixels are ever sampled -- the middle is the stretched edge
# strip, so the extra 4px cost nothing and the client never pads the texture.
# fullBleed: the outer arc is tangent to the canvas edges -- a backdrop samples
# its corner slice from the texture's outermost pixels, so an arc inset by a
# margin would push the whole border inwards by that margin.
Add-Asset 'monet_round_edge' 'deco' '圆角九宫格边纹' 16 16 $true `
    'Widget:Theme 圆角面板的 edgeFile：四角按 edgeSize 切片、四边拉伸；随主题边框色 SetVertexColor' `
    '外半径 3 / 环宽 2 / 内半径 1；even-odd 填充挖空芯部，底板仍归 SetBackdrop 的 bgFile' ({
    param($c, $k, $pal, $rng)
    $g = $c.G
    $ring = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundedRectPath $ring 0 0 16 16 3 $k     # 外沿：圆角半径 3
    Add-RoundedRectPath $ring 2 2 12 12 1 $k     # 内沿：内缩环宽 2 -> 内半径 1
    $brush = New-Brush $pal.white 1.0
    try { $g.FillPath($brush, $ring) } finally { $brush.Dispose() }
}) -fullBleed $true

# -- Render + emit -------------------------------------------------------------

function Invoke-Asset {
    param($asset)
    $SS = $script:SS
    $cw = $asset.w * $SS
    $ch = $asset.h * $SS
    $c = New-Canvas $cw $ch
    $k = [float]([double]$cw / [double]$asset.w)          # glyph units == final px
    $rng = New-Object System.Random(1009 + $asset.name.Length * 7919 + $asset.w * 31 + $asset.h)

    & $asset.body $c $k $PAL $rng

    $final = Scale-Down $c.B $asset.w $asset.h
    $c.B.Dispose()
    Fill-TransparentRgb $final

    $png = Join-Path $PreviewDir ($asset.name + '.png')   # browser preview only, never shipped
    $tga = Join-Path $OutDir ($asset.name + '.tga')
    $final.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = Get-TopDownBytes $final
    $tgaSize = Write-Tga $tga $final $bytes
    $cover = Test-Alpha $tga $png $final $asset.name $asset.fullBleed

    # the PNG comes straight from GDI+, so spot-check it against the render
    $re = New-Object System.Drawing.Bitmap($png)
    try {
        $samples = @(@(0, 0), @(($asset.w - 1), ($asset.h - 1)),
                     @([int]($asset.w / 2), [int]($asset.h / 2)),
                     @([int]($asset.w / 3), [int]($asset.h / 4)))
        foreach ($s in $samples) {
            $p1 = $final.GetPixel($s[0], $s[1]).ToArgb()
            $p2 = $re.GetPixel($s[0], $s[1]).ToArgb()
            # Fill-TransparentRgb paints the colour under alpha = 0, and a PNG round-trip may normalise
            # that invisible colour back to black; fully transparent samples are compared on alpha.
            if ((($p1 -shr 24) -band 0xFF) -eq 0 -and (($p2 -shr 24) -band 0xFF) -eq 0) { continue }
            if ($p1 -ne $p2) { throw "$($asset.name): PNG round-trip mismatch at $($s[0]),$($s[1])" }
        }
    } finally { $re.Dispose(); $final.Dispose() }

    $kb = [math]::Round($tgaSize / 1024, 1)
    $flag = if ($asset.tintable) { 'tintable' } else { 'fixed colour' }
    Write-Host ("  {0,-24} {1}x{2}  {3} KB  visible {4,5:P0}  {5}" -f $asset.name, $asset.w, $asset.h, $kb, $cover, $flag)
}

# -- Manifest for docs/texture-preview.html -----------------------------------

function ConvertTo-Hex {
    param([int[]]$rgb)
    return ('#{0:X2}{1:X2}{2:X2}' -f [int]$rgb[0], [int]$rgb[1], [int]$rgb[2])
}

function Write-Manifest {
    $js = New-Object 'System.Collections.Generic.List[string]'
    $js.Add('// Generated by tools\make-ui-textures.ps1 -- do not edit by hand.')
    $js.Add('window.MONET_TEXTURES = {')
    $js.Add(('  generated: "{0}",' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
    $js.Add('  addon: "MonetUI",')
    $js.Add('  textureDir: "Interface\\AddOns\\MonetUI\\Assets\\Textures\\",')
    $js.Add('  supersample: 4,')
    $js.Add('  palette: {')
    $order = @('white', 'cream', 'edge', 'ambient', 'neutral', 'health', 'resource', 'danger', 'shadow')
    $zh = @{
        white = '可染白'; cream = '高光奶油'; edge = '赭金边缘'; ambient = '冷灰环境'
        neutral = '莫奈灰'; health = '生命绿'; resource = '资源蓝'; danger = '危险红'; shadow = '暗底'
    }
    foreach ($key in $order) {
        $rgb = $PAL[$key]
        $js.Add(('    {0}: {{ hex: "{1}", rgb: [{2}, {3}, {4}], zh: "{5}" }},' -f
            $key, (ConvertTo-Hex $rgb), $rgb[0], $rgb[1], $rgb[2], $zh[$key]))
    }
    $js.Add('  },')
    $js.Add('  groups: [')
    foreach ($g in $groups.GetEnumerator()) {
        $js.Add(('    {{ id: "{0}", label: "{1}" }}' -f $g.Key, $g.Value) + ',')
    }
    $js.Add('  ],')
    $js.Add('  assets: [')
    foreach ($a in $assets) {
        $js.Add(('    {{ name: "{0}", group: "{1}", title: "{2}", w: {3}, h: {4}, tintable: {5}, src: "{0}.png", tga: "{0}.tga", use: "{6}", note: "{7}" }}' -f
            $a.name, $a.group, $a.title, $a.w, $a.h,
            $(if ($a.tintable) { 'true' } else { 'false' }),
            ($a.use -replace '\\', '\\\\'), ($a.note -replace '"', "'")) + ',')
    }
    $js.Add('  ]')
    $js.Add('};')

    $dir = Split-Path -Parent $ManifestOut
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllLines($ManifestOut, $js, (New-Object System.Text.UTF8Encoding($false)))
}

# -- Main ---------------------------------------------------------------------

$groups = [ordered]@{
    window = '窗口控件'
    glyph  = '通用图标'
    bar    = '状态条'
    role   = '职责 Role'
    deco   = '装饰'
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not (Test-Path $PreviewDir)) { New-Item -ItemType Directory -Path $PreviewDir -Force | Out-Null }

Write-Host ("MonetUI texture build: {0} assets, supersample x{1}" -f $assets.Count, $script:SS)
foreach ($a in $assets) { Invoke-Asset $a }

Write-Manifest
Write-Host ("wrote : {0}" -f $ManifestOut)
Write-Host 'verify: OK (TGA == render, PNG round-trip, transparent margins, non-empty glyphs)'
