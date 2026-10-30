#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/gimp-brush-stroke.py —— 用 GIMP 的画笔引擎画 MonetUI 的油画笔触材质。

为什么用 GIMP 而不是 node-canvas 脚本：
  * GIMP 3.2 自带 **Oils / Bristles / Acrylic / Charcoal** 这些真实颜料笔刷，鬃毛痕与
    不规则边缘是引擎画出来的，不是逐像素循环凑出来的；
  * 同一个笔刷换"硬度 / 间距 / 不透明度"就能得到完全不同的笔性（实心、飞白、干笔），
    调参 = 改下面几个常数重跑一次。

**盖章而不是描边**：`Gimp.Drawable.edit_stroke_item()` 在这个版本里只画路径的首尾两点
（试过点列路径、两点路径、PAINT_METHOD / LINE，全都不跟随整条路径）。所以这里改成
"自己按位置逐个盖章"：每个位置建一条 0.01 长的小路径、调一次画笔引擎 → 一个笔触点。
效果就是真实的笔刷轨迹（见 tools 里的对照图）。

用法（便携版 GIMP 3.2，自带 Python-Fu）：
  gimp-console-3.2.exe -i --batch-interpreter=python-fu-eval ^
      -b "import runpy; runpy.run_path(r'<abs path>', run_name='__main__', init_globals=globals())"

输出：Assets/Textures/monet_brush_stroke.png（256x16 RGBA）
      之后必须过 tools/tga-post.js：项目里所有材质都是**未压缩 32bit TGA（type 2）**，
      而 GIMP 的 TGA 导出默认是 RLE（type 10）→ 统一由 tga-post.js 转格式 + 补纯白衬底。
"""

import math
import os
import sys
import traceback

LOG = []


def log(*a):
    LOG.append(' '.join(str(x) for x in a))


def srgb_to_linear(v):
    """sRGB → 线性。GIMP 的画笔上下文吃的是**线性**分量（实测：把 sRGB 值直接
    喂进去，#214447 会被画成 rgb(100,139,142) —— 整体提亮一大截；先转线性再喂，
    才拿到想要的 rgb(46,75,78)）。浅色几乎不变，越暗越明显。"""
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def gegl_color(rgb, alpha=1.0):
    """GIMP 3 的颜色对象：分量必须是 **0..1 的浮点**。
    传 0..255 会被当成超范围值夹到 1.0 —— 画出来是纯白（实测：u8 字符串与
    set_rgba(216,…) 两种写法都出白，0..1 的写法才出对的颜色）。"""
    c = Gegl.Color()
    c.set_rgba(srgb_to_linear(rgb[0]), srgb_to_linear(rgb[1]), srgb_to_linear(rgb[2]), alpha)
    return c


def make_image(w, h):
    """建图像。GIMP 3 的默认精度是 U8_NON_LINEAR（= sRGB 伽勒姆）✓ 颜色可以直接给 sRGB 值，
    不用自己做线性/伽勒姆换算（实测：同一支笔画出的峰值与目标色一致）。"""
    img = Gimp.Image.new(w, h, Gimp.ImageBaseType.RGB)
    log('PRECISION', img.get_precision(), '(150 = U8_NON_LINEAR / sRGB)')
    return img


# ---------------------------------------------------------------- 画布与色板

W, H = 256, 16

# Monet 色板（与 tools/regen-textures.js 的 PALETTE 同一组值）
SHADOW  = (0x2e, 0x2a, 0x26)   # 干笔暗边
ACCENT  = (0xd8, 0xa7, 0x5b)   # 赭金
ACCENTH = (0xe8, 0xc0, 0x78)   # 浅金
CORELO  = (0xf5, 0xea, 0xd6)   # 暖白
CORE    = (0xff, 0xfc, 0xf6)   # 奶白芯

# (颜色, 笔刷, 直径, 硬度 0..1, 间距 0..100, 不透明度 0..100, 基线 y, 起伏, 相位, 盖章数)
PASSES = [
    (SHADOW,  '2. Hardness 050', 15.0, 0.30,  4, 70, 8.0, 0.55, 0.4, 44),
    (ACCENT,  '2. Hardness 050', 12.0, 0.45,  4, 85, 8.0, 0.45, 1.9, 52),
    (ACCENTH, '2. Hardness 050',  9.0, 0.60,  4, 90, 8.0, 0.38, 3.1, 60),
    (CORELO,  '2. Hardness 050',  6.0, 0.75,  5, 95, 8.0, 0.30, 4.6, 68),
    (CORE,    'Bristles 01',     3.6, 0.80, 26, 95, 8.0, 0.24, 0.9, 76),
]

# 两端淡出：贴图是被"拉长到位的"（Widget:Rule 从锚点左拉到右），硬切口拉长后是一道
# 生硬的竖边；这里让首尾几个笔触逐步变淡，裁到任何长度都还像一笔画完的。
EDGE_FADE = 0.10               # 首尾各 10% 长度做淡出


def path_y(u, y_base, amp, phase):
    """沿长度的起伏：整周期（u = x/w 的整数倍）→ 左右接得上，裁到任何长度都成立。"""
    return (y_base
            + amp * math.sin(phase + u * math.tau)
            + amp * 0.35 * math.sin(phase * 1.7 + u * math.tau * 3))


def stamp_dabs(img, layer, color, brush_name, size, hardness, spacing, opacity,
               y_base, amp, phase, count):
    """沿路径逐个盖章：每个位置一条 0.01 长的小路径 = 一个笔触点。"""
    Gimp.context_set_brush(Gimp.Brush.get_by_name(brush_name))
    Gimp.context_set_brush_size(size)
    Gimp.context_set_brush_hardness(hardness)
    Gimp.context_set_brush_spacing(spacing)
    Gimp.context_set_paint_mode(Gimp.LayerMode.NORMAL)
    Gimp.context_set_stroke_method(Gimp.StrokeMethod.PAINT_METHOD)
    Gimp.context_set_foreground(gegl_color(color))

    for i in range(count):
        u = i / (count - 1.0)
        x = -2.0 + (W + 4.0) * u
        y = path_y(u, y_base, amp, phase)
        # 两端淡出
        edge = min(u, 1.0 - u) / EDGE_FADE
        a = opacity * (0.15 + 0.85 * min(1.0, edge)) if edge < 1.0 else opacity
        Gimp.context_set_opacity(max(1, int(round(a))))
        p = Gimp.Path.new(img, 'd')
        sid = p.bezier_stroke_new_moveto(x, y)
        p.bezier_stroke_lineto(sid, x + 0.01, y)
        img.insert_path(p, None, 0)
        layer.edit_stroke_item(p)


def main():
    img = make_image(W, H)
    layer = Gimp.Layer.new(img, 'stroke', W, H, Gimp.ImageType.RGBA_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
    img.insert_layer(layer, None, 0)
    Gimp.context_set_antialias(True)

    for (color, brush, size, hardness, spacing, opacity, ybase, amp, phase, dabs) in PASSES:
        stamp_dabs(img, layer, color, brush, size, hardness, spacing, opacity, ybase, amp, phase, dabs)
        log('pass', brush, 'size', size, 'hard', hardness, 'space', spacing, 'op', opacity, 'dabs', dabs)

    out = os.path.join(os.environ.get('TEMP', '/tmp'), 'monet_brush_stroke.png')
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img, Gio.File.new_for_path(out), None)
    log('SAVED', out)


try:
    main()
except Exception:
    log('FAILED', traceback.format_exc())

for line in LOG:
    print(line)
sys.stdout.flush()
Gimp.quit()
