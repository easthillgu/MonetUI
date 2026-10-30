#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
tools/gimp-addon-icon.py —— 用 GIMP 的油画笔刷画 MonetUI 的**插件管理界面图标**。

图标挂在 .toc 的 `## IconTexture:` 上，客户端（Blizzard_AddOnList/AddonList.lua:390）
用 `C_AddOns.GetAddOnMetadata(addonIndex, "IconTexture")` 取到，再以内联
`CreateSimpleTextureMarkup(iconTexture, 20, 20)` 画在插件名前面 —— 也就是
**实际只显示 20x20 像素**。所以这张图要在 20px 下还认得出（一朵大花 + 强明暗对比），
放大到 256px 又能看出是印象派油画。

四个踩过的坑（都写在代码里）：
  1. GIMP 3.2 的 `edit_stroke_item()` **只画路径的首尾两点**（多点路径实测只落首尾），
     所以统一"自己盖章"：一个路径里塞 N 条 0.01 长的两点子路径，一次画全。
  2. 画笔上下文吃的是**线性**分量，喂 sRGB 会整体提亮（#214447 → rgb(100,139,142)），
     画面会糊成一片粉白。必须先 srgb_to_linear()。
  3. **一笔不能是一桶点**：盖章点攒在字典里，出图顺序是字典序 —— 谁先画全看运气。
     所以按画面元素**分层**，每层一个桶（层序 = 创建序，创建即插到最上面）。
  4. 笔刷间距太大时笔触会散成一堆圆点，看不出"一笔"。盖章间距取笔刷直径的 ~0.22。

构图（《睡莲》）：深青绿的池水 + 顶部一线天空倒影；中央一朵大睡莲（焦点，画面最亮的一块），
底下两片扁平的睡莲叶，右上一朵小花作次要呼应。20x20 下就是"一朵浅色花浮在深绿水上"。

用法（便携版 GIMP 3.2，自带 Python-Fu）：
  powershell -File tools/gimp-render.ps1 -Script tools/gimp-addon-icon.py -Out $env:TEMP\monet_addon_icon.png

输出：%TEMP%/monet_addon_icon.png（256x256 RGBA，全不透明）
      之后必须过 tools/tga-post.js 转成项目格式的未压缩 32bit TGA。
"""

import math
import os
import random
import sys
import traceback

LOG = []


def log(*a):
    LOG.append(' '.join(str(x) for x in a))


def srgb_to_linear(v):
    """sRGB → 线性。GIMP 的画笔上下文吃的是**线性**分量（实测：把 sRGB 值直接
    喂进去，#214447 会被画成 rgb(100,139,142) —— 整体提亮一大截，颜色全糊掉；
    先转线性再喂，才拿到想要的 rgb(46,75,78)）。"""
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def gegl_color(rgb, alpha=1.0):
    """GIMP 3 的颜色对象：分量必须是 **0..1 的浮点**。传 0..255 会被夹成纯白。"""
    c = Gegl.Color()
    c.set_rgba(srgb_to_linear(rgb[0]), srgb_to_linear(rgb[1]), srgb_to_linear(rgb[2]), alpha)
    return c


# ---------------------------------------------------------------- 画布

W = H = 256
RNG = random.Random(20261020)

# ---------------------------------------------------------------- 色板（莫奈《睡莲》）

SKY_PALE = (0xD2, 0xE1, 0xEA)   # 天空倒影·最亮
SKY_BLUE = (0xA6, 0xC6, 0xE0)   # 天空倒影·蓝
LILAC    = (0xBE, 0xB2, 0xD6)   # 天空倒影·紫
CREAM    = (0xF4, 0xE9, 0xD2)   # 奶白高光
ROSE     = (0xE6, 0xBE, 0xB0)   # 暖粉反光

TEAL     = (0x2E, 0x6B, 0x69)   # 池水·青（主色）
GREEN    = (0x3E, 0x7A, 0x54)   # 池水·绿
SAGE     = (0x74, 0xA0, 0x76)   # 池水·浅绿
DEEP     = (0x14, 0x33, 0x38)   # 池水·深（暗部）
VIOLET   = (0x3A, 0x39, 0x60)   # 水影·紫（莫奈爱在水影里点紫）
GOLD     = (0xD2, 0xA1, 0x56)   # 赭金暖光

PAD      = (0x4E, 0x7E, 0x45)   # 莲叶
PAD_LT   = (0x8B, 0xAA, 0x60)   # 莲叶受光
PAD_DK   = (0x24, 0x46, 0x30)   # 莲叶暗部

PINK     = (0xD9, 0x7E, 0x9C)   # 花瓣（根部）
PINK_LT  = (0xF0, 0xB4, 0xC6)   # 花瓣
FLR_WT   = (0xFB, 0xF1, 0xE4)   # 花瓣高光
YELLOW   = (0xE8, 0xBC, 0x4E)   # 花心

HORIZON = 54          # 天空倒影 / 池水的过渡带
BRUSH_SOFT = 'Oils 01'
BRUSH_TEX = 'Acrylic 01'
BRUSH_SMOOTH = '2. Hardness 050'


def jcol(rgb, amount=8):
    return tuple(max(0, min(255, c + RNG.randint(-amount, amount))) for c in rgb)


def lerp_col(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Buckets:
    """把同色同笔刷的点攒起来，一次 edit_stroke_item 全画出去。"""

    def __init__(self):
        self.data = {}

    def add(self, pts, color, brush, size, hardness, opacity):
        key = (color, brush, round(size, 1), round(hardness, 2), opacity)
        self.data.setdefault(key, []).extend(pts)

    def flush(self, img, layer):
        n = 0
        for (color, brush, size, hardness, opacity), pts in self.data.items():
            if not pts:
                continue
            Gimp.context_set_brush(Gimp.Brush.get_by_name(brush))
            Gimp.context_set_brush_size(size)
            Gimp.context_set_brush_hardness(hardness)
            Gimp.context_set_brush_spacing(4)
            Gimp.context_set_opacity(opacity)
            Gimp.context_set_foreground(gegl_color(color))
            p = Gimp.Path.new(img, 's')
            for (x, y) in pts:
                sid = p.bezier_stroke_new_moveto(x, y)
                p.bezier_stroke_lineto(sid, x + 0.01, y)
            img.insert_path(p, None, 0)
            layer.edit_stroke_item(p)
            n += len(pts)
        log('  flush dabs =', n, 'groups =', len(self.data))
        return n


def new_layer(img, name):
    """新建一层并插到最上面 —— 创建顺序即层序（最后创建的画在最上）。"""
    layer = Gimp.Layer.new(img, name, W, H, Gimp.ImageType.RGBA_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
    img.insert_layer(layer, None, 0)
    return layer


# ---------------------------------------------------------------- 笔触

def stroke(buckets, x0, y0, x1, y1, color, brush=BRUSH_SOFT, size=14.0,
           hardness=0.62, opacity=100, step=None, wobble=1.2):
    """一段笔触：从 (x0,y0) 到 (x1,y1)，沿途盖章。step = 相邻盖章点间距（px）。"""
    if step is None:
        step = max(1.4, size * 0.22)
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    if length < 0.01:
        return
    ux, uy = dx / length, dy / length
    nx, ny = -uy, ux
    n = max(2, int(length / step) + 1)
    pts = []
    for i in range(n):
        t = i / (n - 1.0)
        w = math.sin(t * math.pi) * wobble
        pts.append((x0 + dx * t + nx * w * RNG.uniform(-1, 1),
                    y0 + dy * t + ny * w * RNG.uniform(-1, 1)))
    buckets.add(pts, color, brush, size, hardness, opacity)


def fill_ellipse(buckets, cx, cy, rx, ry, rot, colfn, brush=BRUSH_TEX, size=9.0,
                 hardness=0.5, opacity=100):
    """用盖章填一个椭圆。colfn(u, v) 决定每个点的颜色（u,v 是椭圆内的局部坐标）。

    盖章间距要比笔刷直径小得多（0.3 倍），否则椭圆里全是洞。
    """
    step = max(1.5, size * 0.3)
    ca, sa = math.cos(rot), math.sin(rot)
    rows = max(2, int(ry * 2 / step))
    for i in range(rows + 1):
        v = -1.0 + 2.0 * i / rows
        halfw = rx * math.sqrt(max(0.0, 1.0 - v * v))
        cols = max(1, int(halfw * 2 / step))
        for j in range(cols + 1):
            u = -1.0 + 2.0 * j / cols
            lx, ly = u * halfw, v * ry
            x = cx + lx * ca - ly * sa
            y = cy + lx * sa + ly * ca
            buckets.add([(x, y)], colfn(u, v), brush, size, hardness, opacity)


# ---------------------------------------------------------------- 画面元素

def paint_base(buckets):
    """底色：铺满画布，保证 alpha 全 255。"""
    g = 13
    for gy in range(-g, H + g, g):
        for gx in range(-g, W + g, g):
            buckets.add([(gx, gy)], jcol(TEAL, 5), BRUSH_SMOOTH, 48.0, 0.55, 100)


def paint_water(buckets):
    """池水：先铺一层软的大笔触做底，再点几笔破色。

    笔触要"软"（硬度 0.25~0.4）：硬边 + 等距排布 = 数码横条；
    软边 + 交叠 = 油画的浑融。底下压一层深色，前景才有厚度。
    """
    # 1) 底层：越往下越深的大笔触
    #    角度要放开（±0.45 弧度）：全横的笔触排在一起会被眼睛读成"扫描线"，
    #    而印象派的水面本来就是横、斜、竖混着来的。
    y = -14
    while y < H + 20:
        t = (y + 14) / float(H + 34)                       # 0 顶 → 1 底
        if t < 0.30:
            pal = [TEAL, TEAL, SAGE, SKY_BLUE]
        elif t < 0.62:
            pal = [TEAL, TEAL, GREEN, DEEP, SAGE]
        else:
            pal = [DEEP, DEEP, TEAL, VIOLET, GREEN]
        for _ in range(5):
            x = RNG.uniform(-80, W)
            ln = RNG.uniform(34, 104) * (0.85 + 0.3 * t)
            ang = RNG.uniform(-0.45, 0.45)
            col = jcol(RNG.choice(pal), 9)
            size = RNG.uniform(22.0, 46.0) * (0.85 + 0.3 * t)
            x2 = x + ln * math.cos(ang)
            y2 = y + ln * math.sin(ang) + RNG.uniform(-8, 8)
            # 每笔再各自随机偏一点，别排成一条条横线
            stroke(buckets, x, y + RNG.uniform(-11, 11), x2, y2, col, BRUSH_SOFT, size, 0.28, 100)
        y += RNG.uniform(10.0, 22.0)

    # 2) 破色：水影里的紫（印象派的"破色"），大而软，不能是碎点 ——
    #    小碎笔在 20x20 的插件列表里只会变成噪点。
    for _ in range(26):
        x = RNG.uniform(-24, W)
        y = RNG.uniform(HORIZON, H)
        col = jcol(RNG.choice([VIOLET, VIOLET, ROSE]), 10)
        stroke(buckets, x, y, x + RNG.uniform(40, 86), y + RNG.uniform(-8, 8),
               col, BRUSH_TEX, RNG.uniform(24.0, 40.0), 0.28, 50)
    for _ in range(10):
        x = RNG.uniform(-20, W)
        y = RNG.uniform(HORIZON, H)
        stroke(buckets, x, y, x + RNG.uniform(30, 60), y + RNG.uniform(-4, 4),
               jcol(GOLD, 12), BRUSH_TEX, RNG.uniform(14.0, 24.0), 0.32, 45)
    # 池子里的暖赭（莫奈的日光落在水面上）
    for _ in range(12):
        x = RNG.uniform(-20, W)
        y = RNG.uniform(HORIZON - 20, H)
        stroke(buckets, x, y, x + RNG.uniform(36, 72), y + RNG.uniform(-6, 6),
               jcol(GOLD, 14), BRUSH_TEX, RNG.uniform(22.0, 36.0), 0.26, 42)


def paint_sky(buckets):
    """上部：天空在水面的倒影。

    这里**不能**按行铺横笔触 —— 等距横条会被看成数码故障（"断掉的电视"）。
    改成抖动的二维色块场：每个格子随机偏移 + 随机大小 + 随机颜色，
    互相交叠成一片柔和的、有斑驳感的倒影。
    """
    step = 22
    gy = -step
    while gy < HORIZON + 34:
        depth = (gy + step) / float(HORIZON + 38)
        if depth < 0.45:
            pal = [SKY_PALE, SKY_BLUE, LILAC, CREAM, CREAM, ROSE]
        elif depth < 0.75:
            pal = [SKY_BLUE, LILAC, CREAM, TEAL, ROSE]
        else:
            pal = [TEAL, LILAC, SAGE, CREAM]
        gx = -step
        while gx < W + step:
            x = gx + RNG.uniform(-10, 10)
            y = gy + RNG.uniform(-10, 10)
            col = jcol(RNG.choice(pal), 8)
            size = RNG.uniform(26.0, 42.0)
            buckets.add([(x, y)], col, BRUSH_SOFT, size, 0.24, 84)
            gx += step
        gy += step
    # 水面反光里的几笔暖金（大而软，别成小点）
    for _ in range(8):
        x = RNG.uniform(0, W)
        y = RNG.uniform(6, HORIZON)
        stroke(buckets, x, y, x + RNG.uniform(34, 64), y + RNG.uniform(-3, 3),
               jcol(GOLD, 10), BRUSH_TEX, RNG.uniform(18.0, 28.0), 0.3, 45)


def paint_pad(buckets, cx, cy, rx, ry, notch=True):
    """一片睡莲叶：沿椭圆铺短笔触，左上受光、右下入暗，边缘压一道暗线。"""
    rings = 6
    for ri in range(rings):
        f = 0.18 + 0.82 * (ri / float(rings - 1))
        segs = 34
        for si in range(segs):
            a = math.tau * si / segs
            if notch and abs(((a - math.radians(205) + math.pi) % math.tau) - math.pi) < 0.40:
                continue
            x = cx + rx * f * math.cos(a)
            y = cy + ry * f * math.sin(a)
            lit = math.cos(a - math.radians(215))          # 左上 = 受光
            if lit > 0.40:
                col = jcol(PAD_LT, 10)
            elif lit < -0.30:
                col = jcol(PAD_DK, 10)
            else:
                col = jcol(PAD, 10)
            if RNG.random() < 0.10:
                col = jcol(GREEN, 12)
            stroke(buckets, x, y, x + RNG.uniform(8, 18), y + RNG.uniform(-4, 4),
                   col, BRUSH_TEX, RNG.uniform(11.0, 17.0), 0.5, 100)
    # 叶缘的暗描，把叶子和水面分开
    for si in range(40):
        a = math.tau * si / 40
        if notch and abs(((a - math.radians(205) + math.pi) % math.tau) - math.pi) < 0.45:
            continue
        x = cx + rx * 0.99 * math.cos(a)
        y = cy + ry * 0.99 * math.sin(a)
        if math.cos(a - math.radians(215)) < -0.05:
            continue
        stroke(buckets, x, y, x + RNG.uniform(6, 13), y + RNG.uniform(-3, 3),
               jcol(PAD_DK, 8), BRUSH_TEX, RNG.uniform(8.0, 12.0), 0.55, 85)


def paint_blossom(buckets, cx, cy, r, petals=13):
    """一朵睡莲。

    画法不是"放射状排花瓣"（那样边缘全是尖刺，20x20 下看着像太阳），
    而是莫奈的实心画法：
      1) 先铺一整团柔和的花形（上白下粉）；
      2) 再用几笔深一点的粉画出瓣与瓣的分界；
      3) 中心一簇黄，左上再补几笔白高光。
    """
    # 花底的一圈暗影（只在花瓣外缘），把花从水面上"抬"起来
    for _ in range(int(r * 0.7)):
        a = RNG.uniform(0, math.tau)
        rr = r * RNG.uniform(0.95, 1.18)
        x = cx + rr * math.cos(a) * 1.04
        y = cy + rr * math.sin(a) * 0.9
        stroke(buckets, x, y, x + RNG.uniform(8, 18), y + RNG.uniform(-5, 5),
               jcol(DEEP, 8), BRUSH_SOFT, RNG.uniform(r * 0.16, r * 0.28), 0.5, 70)

    # 1) 花形：一整团软笔触，上白下粉
    def colfn(u, v):
        t = max(0.0, min(1.0, (v + 1.0) * 0.5))
        c = lerp_col(FLR_WT, PINK, t ** 1.5)
        if u < -0.45:
            c = lerp_col(c, FLR_WT, 0.5)          # 左上受光
        return jcol(c, 7)

    fill_ellipse(buckets, cx, cy, r * 0.62, r * 0.52, 0.0, colfn,
                 BRUSH_TEX, max(6.0, r * 0.18), 0.3, 100)

    # 2) 瓣与瓣的分界：几笔深一点的粉，从中心往外
    for k in range(petals):
        a = math.tau * k / petals + RNG.uniform(-0.06, 0.06)
        x0 = cx + r * 0.13 * math.cos(a)
        y0 = cy + r * 0.13 * math.sin(a) * 0.9
        x1 = cx + r * 0.56 * math.cos(a)
        y1 = cy + r * 0.56 * math.sin(a) * 0.9
        stroke(buckets, x0, y0, x1, y1, jcol(PINK, 8),
               BRUSH_TEX, RNG.uniform(r * 0.10, r * 0.16), 0.25, 85)

    # 2b) 花缘：几片探出来的花瓣尖，让轮廓不是个圆球
    for k in range(petals):
        a = math.tau * k / petals + RNG.uniform(-0.14, 0.14)
        rr = r * RNG.uniform(0.52, 0.64)
        x = cx + rr * math.cos(a)
        y = cy + rr * math.sin(a) * 0.9
        stroke(buckets, x, y, x + RNG.uniform(4, 10), y + RNG.uniform(-4, 4),
               jcol(FLR_WT if RNG.random() < 0.6 else PINK_LT, 6),
               BRUSH_TEX, RNG.uniform(r * 0.14, r * 0.20), 0.35, 90)

    # 3) 花心：一小簇黄
    for _ in range(12):
        x = cx + RNG.uniform(-r * 0.10, r * 0.10)
        y = cy + RNG.uniform(-r * 0.08, r * 0.08)
        stroke(buckets, x, y, x + 2, y,
               jcol(YELLOW, 10), BRUSH_TEX, max(3.2, r * 0.10), 0.5, 100)

    # 4) 左上受光的高光
    for _ in range(int(r * 0.45)):
        a = math.radians(205 + RNG.uniform(-55, 55))
        rr = r * RNG.uniform(0.25, 0.50)
        x = cx + rr * math.cos(a)
        y = cy + rr * math.sin(a) * 0.9
        stroke(buckets, x, y, x + 2, y,
               jcol(FLR_WT, 5), BRUSH_SOFT, max(3.0, r * 0.11), 0.5, 70)


def paint_glints(buckets):
    """水面上的高光碎笔（少量，只在中上部，别糊到花上）。"""
    for _ in range(28):
        x = RNG.uniform(-10, W)
        y = RNG.uniform(0, HORIZON + 40)
        col = jcol(CREAM if RNG.random() < 0.7 else FLR_WT, 6)
        stroke(buckets, x, y, x + RNG.uniform(16, 34), y + RNG.uniform(-2, 2),
               col, BRUSH_SOFT, RNG.uniform(8.0, 14.0), 0.45, 60)


def paint_shadow(buckets):
    """画面下缘与两角压暗。"""
    for _ in range(90):
        x = RNG.uniform(-24, W)
        y = RNG.uniform(H - 44, H + 14)
        col = jcol(DEEP if RNG.random() < 0.6 else VIOLET, 8)
        stroke(buckets, x, y, x + RNG.uniform(26, 56), y + RNG.uniform(-3, 3),
               col, BRUSH_SOFT, RNG.uniform(15.0, 25.0), 0.5, 75)
    for _ in range(22):
        x = RNG.uniform(-12, W)
        y = RNG.uniform(-10, 14)
        col = jcol(VIOLET if RNG.random() < 0.5 else TEAL, 8)
        stroke(buckets, x, y, x + RNG.uniform(22, 42), y + RNG.uniform(-2, 2),
               col, BRUSH_SOFT, RNG.uniform(13.0, 21.0), 0.5, 65)


# ---------------------------------------------------------------- 主流程

def main():
    tmp = os.environ.get('TEMP', '/tmp')

    Gimp.context_set_antialias(True)
    Gimp.context_set_paint_mode(Gimp.LayerMode.NORMAL)
    Gimp.context_set_stroke_method(Gimp.StrokeMethod.PAINT_METHOD)

    # --- 前景图：只有花（带透明），交给后期单独决定柔化程度
    #     注意先存前景、再存背景：tools/gimp-render.ps1 是盯着"最后一个文件"收摊的。
    #     GIMP 3.2 的 ImageBaseType 只有 RGB / GRAY，没有 RGBA；
    #     图有没有 alpha 取决于层 —— 画在 RGBA_IMAGE 的层上，导出 PNG 就带透明。
    #     花占画幅约 45%：插件列表里只显示 20x20，花太小就认不出了。
    img_fg = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)
    b = Buckets()
    paint_blossom(b, 126, 146, 80, 13)
    b.flush(img_fg, new_layer(img_fg, 'flowers'))

    fg_out = os.path.join(tmp, 'monet_addon_icon_fg.png')
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img_fg, Gio.File.new_for_path(fg_out), None)
    log('SAVED', fg_out)

    # --- 背景图：水 + 天空 + 压暗 + 叶 + 高光（不透明）
    img_bg = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)

    b = Buckets()
    paint_base(b)
    paint_water(b)
    b.flush(img_bg, new_layer(img_bg, 'water'))

    b = Buckets()
    paint_sky(b)
    b.flush(img_bg, new_layer(img_bg, 'sky'))

    b = Buckets()
    paint_shadow(b)
    b.flush(img_bg, new_layer(img_bg, 'shadow'))

    b = Buckets()
    for (cx, cy, rx, ry) in [(214, 206, 62, 27), (56, 230, 80, 33), (26, 124, 42, 19)]:
        paint_pad(b, cx, cy, rx, ry)
    b.flush(img_bg, new_layer(img_bg, 'pads'))

    b = Buckets()
    paint_glints(b)
    b.flush(img_bg, new_layer(img_bg, 'glints'))

    bg_out = os.path.join(tmp, 'monet_addon_icon_bg.png')
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img_bg, Gio.File.new_for_path(bg_out), None)
    log('SAVED', bg_out)


try:
    main()
except Exception:
    log('FAILED', traceback.format_exc())

for line in LOG:
    print(line)
sys.stdout.flush()
os._exit(0)
