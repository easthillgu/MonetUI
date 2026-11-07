# 发布徽标合成：图标 + "MonetUI" 横排 → 240×40。
# 源 = Assets-src/Textures/monet_addon_icon.tga（先用 tools/tga-to-png.js 转 docs/monet_addon_icon.png）。
# 产出两份：
#   docs/monet_logo_240x40.png           深青底 + 暖白字（任何背景上都可读，发布页首选）
#   docs/monet_logo_240x40_transparent.png 透明底 + 白字（叠在深色图上用）
# 用法：powershell -File tools/make-banner.ps1
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$iconPath = Join-Path $root "docs\monet_addon_icon.png"
if (-not (Test-Path $iconPath)) { throw "missing $iconPath -- run: node tools/tga-to-png.js Assets-src/Textures/monet_addon_icon.tga docs/monet_addon_icon.png" }
$fontPath = Join-Path $root "Assets\Fonts\LXGWWenKai-Regular.ttf"

$W, $H = 240, 40
$src = [System.Drawing.Image]::FromFile($iconPath)
try {
    $fc = New-Object System.Drawing.Text.PrivateFontCollection
    $fc.AddFontFile($fontPath)
    $family = $fc.Families[0]
    # 24px 字面：40 高的条里 cap 高约 17，留白均衡
    $font = New-Object System.Drawing.Font($family, 24, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmt.Alignment = [System.Drawing.StringAlignment]::Near
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoClip   # 不裁剪，垂直居中按行盒算，肉眼偏了再调 $textDy
    $textDy = -1                                                    # 光学校正（WenKai 行盒大，居中略偏低）

    function Render([string]$out, [bool]$withBg, [System.Drawing.Color]$textColor) {
        $bmp = [System.Drawing.Bitmap]::new($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            if ($withBg) {
                # #214447 = Monet 深青（AGENTS 里那支画笔色）
                $bg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 0x21, 0x44, 0x47))
                $g.FillRectangle($bg, 0, 0, $W, $H)
                $bg.Dispose()
            }
            # 图标 40×40 齐左
            $dest = [System.Drawing.Rectangle]::new(0, 0, 40, 40)
            $srcrect = [System.Drawing.Rectangle]::new(0, 0, $src.Width, $src.Height)
            $g.DrawImage($src, $dest, $srcrect, [System.Drawing.GraphicsUnit]::Pixel)
            # 文字：x=52 起（图标后 12px 气口）
            $brush = [System.Drawing.SolidBrush]::new($textColor)
            $rect = [System.Drawing.RectangleF]::new(52, $textDy, $W - 52, $H)
            $g.DrawString("MonetUI", $font, $brush, $rect, $fmt)
            $brush.Dispose()
        } finally {
            $g.Dispose()
        }
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Output "$out  (${W}x${H})"
    }

    $warmWhite = [System.Drawing.Color]::FromArgb(255, 0xFF, 0xF8, 0xEC)
    $pureWhite = [System.Drawing.Color]::FromArgb(255, 0xFF, 0xFF, 0xFF)   # 文字恒不透明；"透明"指的是底
    Render (Join-Path $root "docs\monet_logo_240x40.png") $true $warmWhite
    Render (Join-Path $root "docs\monet_logo_240x40_transparent.png") $false $pureWhite
} finally {
    $src.Dispose()
}
