#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
tools/gimp-addon-icon-variants.py —— 一次 GIMP 会话画出 4 个 logo 变体（bg/fg PNG）。

只给"选 logo"用，不动现役的 tools/gimp-addon-icon.py。输出（不进仓库）：
  %TEMP%/opencode/monet-icon-variants/
    sunrise_bg.png    日出·印象（莫奈同名作：灰蓝海面 + 橙日在水面的倒影）
    poppies_bg.png    罂粟花田（绿田 + 红花斑）
    haystack_bg.png   黄昏草垛（金紫互补的双面锥体）
    bluelily_bg.png / bluelily_fg.png   蓝睡莲（深青紫池水 + 蓝紫花，特写大花）
    done.txt          完成标记（给 tools/gimp-render.ps1 盯梢收摊用，最后写）

画法沿用正式脚本的四个坑位结论：两点子路径盖章分层、线性分量颜色、
层序 = 创建序、盖章间距取笔刷直径的 ~0.22。
"""

import math
import os
import random
import traceback

LOG = []


def log(*a):
    LOG.append(' '.join(str(x) for x in a))


def srgb_to_linear(v):
    """画笔上下文吃线性分量；喂 sRGB 会整体提亮（见正式脚本注释）。"""
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def gegl_color(rgb, alpha=1.0):
    c = Gegl.Color()
    c.set_rgba(srgb_to_linear(rgb[0]), srgb_to_linear(rgb[1]), srgb_to_linear(rgb[2]), alpha)
    return c


W = H = 256
OUTDIR = os.path.join(os.environ.get('TEMP', '/tmp'), 'opencode', 'monet-icon-variants')

BRUSH_SOFT = 'Oils 01'
BRUSH_TEX = 'Acrylic 01'
BRUSH_SMOOTH = '2. Hardness 050'

RNG = random.Random(1)


def jcol(rgb, amount=8):
    return tuple(max(0, min(255, c + RNG.randint(-amount, amount))) for c in rgb)


def lerp_col(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Buckets:
    """同色同笔刷的点攒起来，一次 edit_stroke_item 全画出去。"""

    def __init__(self):
        self.data = {}

    def add(self, pts, color, brush, size, hardness, opacity):
        key = (color, brush, round(size, 1), round(hardness, 2), round(opacity))
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


def save_png(img, name):
    os.makedirs(OUTDIR, exist_ok=True)
    out = os.path.join(OUTDIR, name)
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img, Gio.File.new_for_path(out), None)
    log('SAVED', out)


def stroke(buckets, x0, y0, x1, y1, color, brush=BRUSH_SOFT, size=14.0,
           hardness=0.62, opacity=100, step=None, wobble=1.2):
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


# ---------------------------------------------------------------- 通用件

def paint_base(b, col):
    """底色：铺满画布，保证 alpha 全 255。"""
    g = 13
    for gy in range(-g, H + g, g):
        for gx in range(-g, W + g, g):
            b.add([(gx, gy)], jcol(col, 5), BRUSH_SMOOTH, 48.0, 0.55, 100)


def band(b, y0, y1, pal, rows, per_row, ln, size, ang=(-0.45, 0.45), hs=0.28, op=88):
    """一整条色带：抖动的横向/斜向大笔触，逐行往下铺。"""
    step = (y1 - y0) / float(rows)
    for i in range(rows):
        y = y0 + step * i + RNG.uniform(-5, 5)
        for _ in range(per_row):
            x = RNG.uniform(-70, W)
            l = RNG.uniform(*ln)
            a = RNG.uniform(*ang)
            col = jcol(RNG.choice(pal), 9)
            s = RNG.uniform(*size)
            x2 = x + l * math.cos(a)
            y2 = y + l * math.sin(a) + RNG.uniform(-6, 6)
            stroke(b, x, y + RNG.uniform(-6, 6), x2, y2, col, BRUSH_SOFT, s, hs, op)


def paint_shadow_low(b, pal, n=70, y0_frac=0.80, size=(14, 26), op=70):
    """画面下缘压暗。"""
    for _ in range(n):
        x = RNG.uniform(-24, W)
        y = RNG.uniform(H * y0_frac, H + 14)
        col = jcol(RNG.choice(pal), 8)
        stroke(b, x, y, x + RNG.uniform(24, 54), y + RNG.uniform(-3, 3),
               col, BRUSH_SOFT, RNG.uniform(*size), 0.5, op)


def paint_pad(b, cx, cy, rx, ry, pad, pad_lt, pad_dk, extra):
    """一片浮叶：左上受光、右下入暗，叶缘一道暗描。"""
    rings = 6
    for ri in range(rings):
        f = 0.18 + 0.82 * (ri / float(rings - 1))
        segs = 34
        for si in range(segs):
            a = math.tau * si / segs
            x = cx + rx * f * math.cos(a)
            y = cy + ry * f * math.sin(a)
            lit = math.cos(a - math.radians(215))
            if lit > 0.40:
                col = jcol(pad_lt, 10)
            elif lit < -0.30:
                col = jcol(pad_dk, 10)
            else:
                col = jcol(pad, 10)
            if RNG.random() < 0.10:
                col = jcol(extra, 12)
            stroke(b, x, y, x + RNG.uniform(8, 18), y + RNG.uniform(-4, 4),
                   col, BRUSH_TEX, RNG.uniform(11.0, 17.0), 0.5, 100)
    for si in range(40):
        a = math.tau * si / 40
        x = cx + rx * 0.99 * math.cos(a)
        y = cy + ry * 0.99 * math.sin(a)
        if math.cos(a - math.radians(215)) < -0.05:
            continue
        stroke(b, x, y, x + RNG.uniform(6, 13), y + RNG.uniform(-3, 3),
               jcol(pad_dk, 8), BRUSH_TEX, RNG.uniform(8.0, 12.0), 0.55, 85)


def paint_blossom2(b, cx, cy, r, petals, col_hl, col_root, col_center):
    """实心画法的花：一整团软花形（上亮下深）+ 瓣界深笔 + 探出的瓣尖 + 花心 + 高光。"""
    for _ in range(int(r * 0.7)):
        a = RNG.uniform(0, math.tau)
        rr = r * RNG.uniform(0.95, 1.18)
        x = cx + rr * math.cos(a) * 1.04
        y = cy + rr * math.sin(a) * 0.9
        stroke(b, x, y, x + RNG.uniform(8, 18), y + RNG.uniform(-5, 5),
               jcol(DEEPISH, 8), BRUSH_SOFT, RNG.uniform(r * 0.16, r * 0.28), 0.5, 70)

    def colfn(u, v):
        t = max(0.0, min(1.0, (v + 1.0) * 0.5))
        c = lerp_col(col_hl, col_root, t ** 1.5)
        if u < -0.45:
            c = lerp_col(c, col_hl, 0.5)
        return jcol(c, 7)

    fill_ellipse(b, cx, cy, r * 0.62, r * 0.52, 0.0, colfn,
                 BRUSH_TEX, max(6.0, r * 0.18), 0.3, 100)

    for k in range(petals):
        a = math.tau * k / petals + RNG.uniform(-0.06, 0.06)
        x0 = cx + r * 0.13 * math.cos(a)
        y0 = cy + r * 0.13 * math.sin(a) * 0.9
        x1 = cx + r * 0.56 * math.cos(a)
        y1 = cy + r * 0.56 * math.sin(a) * 0.9
        stroke(b, x0, y0, x1, y1, jcol(lerp_col(col_root, DEEPISH, 0.25), 8),
               BRUSH_TEX, RNG.uniform(r * 0.10, r * 0.16), 0.25, 85)

    for k in range(petals):
        a = math.tau * k / petals + RNG.uniform(-0.14, 0.14)
        rr = r * RNG.uniform(0.52, 0.64)
        x = cx + rr * math.cos(a)
        y = cy + rr * math.sin(a) * 0.9
        stroke(b, x, y, x + RNG.uniform(4, 10), y + RNG.uniform(-4, 4),
               jcol(col_hl if RNG.random() < 0.6 else lerp_col(col_hl, col_root, 0.55), 6),
               BRUSH_TEX, RNG.uniform(r * 0.14, r * 0.20), 0.35, 90)

    for _ in range(12):
        x = cx + RNG.uniform(-r * 0.10, r * 0.10)
        y = cy + RNG.uniform(-r * 0.08, r * 0.08)
        stroke(b, x, y, x + 2, y, jcol(col_center, 10), BRUSH_TEX, max(3.2, r * 0.10), 0.5, 100)

    for _ in range(int(r * 0.45)):
        a = math.radians(205 + RNG.uniform(-55, 55))
        rr = r * RNG.uniform(0.25, 0.50)
        x = cx + rr * math.cos(a)
        y = cy + rr * math.sin(a) * 0.9
        stroke(b, x, y, x + 2, y, jcol(col_hl, 5), BRUSH_SOFT, max(3.0, r * 0.11), 0.5, 70)


DEEPISH = (0x14, 0x33, 0x38)   # 花底暗影（每变体可改）


# ---------------------------------------------------------------- 变体 1：日出·印象

def paint_sun(b, cx, cy, r):
    # 光晕：大而软的橙色散笔
    for _ in range(26):
        a = RNG.uniform(0, math.tau)
        rr = r * RNG.uniform(1.15, 1.75)
        x = cx + rr * math.cos(a)
        y = cy + rr * math.sin(a) * 0.85
        stroke(b, x, y, x + 2, y, jcol((0xD9, 0x87, 0x4E), 12), BRUSH_SOFT,
               RNG.uniform(r * 0.5, r * 0.9), 0.12, 22)
    # 日面：亮心 + 橙边
    def colfn(u, v):
        d = math.hypot(u, v)
        if d < 0.38:
            return jcol((0xF7, 0xC6, 0x7E), 5)
        return jcol((0xE4, 0x8E, 0x4C), 6)
    fill_ellipse(b, cx, cy, r, r, 0.0, colfn, BRUSH_TEX, max(4.5, r * 0.17), 0.42, 100)


def paint_reflection(b, cx, y_top, y_bot):
    """日头正下方水面上的那条抖动光带（橙色短横 + 冷色间笔）。"""
    x = float(cx)
    y = float(y_top)
    while y < y_bot:
        drift = RNG.uniform(-6, 6)
        seg = RNG.uniform(9, 22)
        hot = RNG.random() < 0.72
        if hot:
            col = jcol(RNG.choice([(0xE2, 0x9B, 0x57), (0xDA, 0x8A, 0x4A), (0xCB, 0x76, 0x40)]), 8)
        else:
            col = jcol((0x5A, 0x6C, 0x74), 8)
        stroke(b, x + drift, y, x + drift + seg, y + RNG.uniform(-2, 2),
               col, BRUSH_TEX, RNG.uniform(8.0, 15.0), 0.35, RNG.uniform(55, 85))
        x = cx + (x + drift - cx) * 0.8
        y += RNG.uniform(9, 16)


def paint_boat(b):
    """一条小船的暗色剪影（左下）。"""
    for t in range(3):
        stroke(b, 58 + t * 3, 206 + t * 5, 118 - t * 4, 213 + t * 3,
               jcol((0x25, 0x2F, 0x37), 4), BRUSH_SOFT, 16.0 - t * 2, 0.55, 95)
    stroke(b, 99, 182, 95, 207, jcol((0x2A, 0x33, 0x3B), 4), BRUSH_SOFT, 4.5, 0.6, 90)
    for _ in range(6):
        x = RNG.uniform(58, 116)
        y = RNG.uniform(218, 232)
        stroke(b, x, y, x + RNG.uniform(10, 22), y + RNG.uniform(-2, 2),
               jcol((0x3E, 0x4E, 0x58), 8), BRUSH_TEX, RNG.uniform(5.0, 9.0), 0.4, 55)


def variant_sunrise():
    global RNG
    RNG = random.Random(20261231)
    img = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)

    b = Buckets()
    paint_base(b, (0x6E, 0x82, 0x88))
    b.flush(img, new_layer(img, 'base'))

    b = Buckets()
    band(b, -12, 122, [(0xC9, 0xC5, 0xB6), (0xB6, 0xB1, 0xA6), (0xCB, 0xB2, 0x92),
                       (0xA3, 0xA5, 0xA4), (0xD6, 0xC2, 0xA2)], rows=6, per_row=7,
         ln=(50, 120), size=(30, 54), hs=0.20, op=78)
    b.flush(img, new_layer(img, 'sky'))

    b = Buckets()
    band(b, 116, 262, [(0x8E, 0x9C, 0x99), (0x6E, 0x82, 0x8A), (0x55, 0x6B, 0x77),
                       (0x46, 0x5B, 0x68), (0x99, 0xA5, 0x9B)], rows=8, per_row=6,
         ln=(26, 74), size=(16, 32), hs=0.30, op=86)
    # 近地平线带一点暖
    for _ in range(9):
        x = RNG.uniform(-16, W)
        y = RNG.uniform(108, 132)
        stroke(b, x, y, x + RNG.uniform(30, 64), y + RNG.uniform(-3, 3),
               jcol((0xC4, 0xA6, 0x84), 10), BRUSH_TEX, RNG.uniform(12.0, 22.0), 0.3, 40)
    b.flush(img, new_layer(img, 'sea'))

    b = Buckets()
    paint_sun(b, 150, 76, 21)
    b.flush(img, new_layer(img, 'sun'))

    b = Buckets()
    paint_reflection(b, 150, 126, 258)
    b.flush(img, new_layer(img, 'refl'))

    b = Buckets()
    paint_boat(b)
    b.flush(img, new_layer(img, 'boat'))

    save_png(img, 'sunrise_bg.png')


# ---------------------------------------------------------------- 变体 2：罂粟花田

def paint_poppy(b, cx, cy, r):
    for k in range(6):
        a = math.tau * k / 6 + RNG.uniform(-0.3, 0.3)
        rr = r * RNG.uniform(0.45, 0.95)
        x = cx + rr * math.cos(a)
        y = cy + rr * math.sin(a)
        col = jcol(RNG.choice([(0xB6, 0x30, 0x33), (0xC4, 0x42, 0x3F), (0xA5, 0x2A, 0x2E)]), 8)
        stroke(b, x, y, x + RNG.uniform(2, 5), y + RNG.uniform(-2, 2),
               col, BRUSH_TEX, RNG.uniform(r * 0.5, r * 0.85), 0.5, 100)
    b.add([(cx + RNG.uniform(-1, 1), cy + RNG.uniform(-1, 1))],
          (0x30, 0x24, 0x26), BRUSH_TEX, max(2.6, r * 0.34), 0.6, 100)


def variant_poppies():
    global RNG
    RNG = random.Random(20260615)
    img = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)

    b = Buckets()
    paint_base(b, (0x5C, 0x76, 0x3A))
    b.flush(img, new_layer(img, 'base'))

    # 天：丁香灰蓝的云，两朵团絮
    b = Buckets()
    band(b, -12, 78, [(0xD9, 0xD9, 0xE8), (0xC6, 0xC4, 0xDE), (0xE6, 0xE6, 0xEE),
                      (0xEF, 0xEF, 0xF2), (0xAD, 0xB2, 0xD0)], rows=4, per_row=7,
         ln=(40, 96), size=(28, 52), hs=0.20, op=80)
    b.flush(img, new_layer(img, 'sky'))

    # 田：绿浪（近大远小）
    b = Buckets()
    band(b, 70, 264, [(0x5C, 0x76, 0x3A), (0x70, 0x8C, 0x44), (0x8A, 0x9E, 0x54),
                      (0x49, 0x64, 0x30), (0x9E, 0xAB, 0x66), (0x3E, 0x58, 0x2A)],
         rows=10, per_row=6, ln=(30, 90), size=(20, 44), hs=0.30, op=88)
    for _ in range(20):
        x = RNG.uniform(-20, W)
        y = RNG.uniform(120, H)
        stroke(b, x, y, x + RNG.uniform(26, 56), y + RNG.uniform(-4, 4),
               jcol((0xB2, 0xBC, 0x74), 10), BRUSH_TEX, RNG.uniform(9.0, 17.0), 0.35, 55)
    b.flush(img, new_layer(img, 'field'))

    # 罂粟：远处小、近处大，一簇簇红花斑
    b = Buckets()
    for i in range(30):
        y = RNG.uniform(88, 250)
        persp = min(1.0, max(0.0, (y - 84) / 172.0))
        r = 5.0 + 14.0 * persp
        x = RNG.uniform(-8, W + 8)
        paint_poppy(b, x, y, r)
    # 前景再补两簇大的（构图锚点）
    paint_poppy(b, 60, 216, 17)
    paint_poppy(b, 196, 232, 19)
    b.flush(img, new_layer(img, 'poppies'))

    save_png(img, 'poppies_bg.png')


# ---------------------------------------------------------------- 变体 3：黄昏草垛

def tri_fill(b, apex_x, apex_y, ybase, rx, colfn, size=(8, 14)):
    rows = 30
    for i in range(rows + 1):
        t = i / float(rows)
        y = apex_y + (ybase - apex_y) * t
        halfw = rx * t
        if halfw < 1:
            continue
        cols = max(1, int(halfw * 2 / (8 * 0.8)))
        for j in range(cols + 1):
            lat = -1.0 + 2.0 * j / cols
            x = apex_x - halfw + halfw * 2 * j / cols
            b.add([(x + RNG.uniform(-2, 2), y + RNG.uniform(-2, 2))],
                  colfn(lat, t), BRUSH_TEX, RNG.uniform(*size), 0.5, 100)


def paint_rim(b, x0, y0, x1, y1, pal, n, seg=(4, 9), size=(5.0, 9.0), op=90):
    for i in range(n):
        t = i / float(n - 1) if n > 1 else 0
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t
        col = jcol(RNG.choice(pal), 6)
        stroke(b, x, y, x + RNG.uniform(*seg), y + RNG.uniform(-3, 3),
               col, BRUSH_TEX, RNG.uniform(*size), 0.45, op)


def variant_haystack():
    global RNG
    RNG = random.Random(20260928)
    img = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)

    b = Buckets()
    paint_base(b, (0x8A, 0x86, 0x99))
    b.flush(img, new_layer(img, 'base'))

    # 天：黄昏的金 + 粉 + 右上带淡紫
    b = Buckets()
    band(b, -12, 152, [(0xE7, 0xCE, 0x96), (0xDE, 0xAA, 0x6A), (0xD8, 0x92, 0x76),
                       (0xEF, 0xDD, 0xAC), (0xE9, 0xC5, 0x99), (0xA8, 0x9E, 0xAE)],
         rows=8, per_row=7, ln=(44, 108), size=(26, 52), hs=0.22, op=80)
    b.flush(img, new_layer(img, 'sky'))

    # 太阳：垛后偏右一颗淡金的日
    b = Buckets()
    for _ in range(16):
        a = RNG.uniform(0, math.tau)
        rr = 14 * RNG.uniform(1.3, 2.0)
        x = 196 + rr * math.cos(a)
        y = 64 + rr * math.sin(a) * 0.9
        stroke(b, x, y, x + 2, y, jcol((0xEB, 0xC9, 0x92), 10), BRUSH_SOFT,
               RNG.uniform(10.0, 20.0), 0.12, 30)
    fill_ellipse(b, 196, 64, 12, 12, 0.0,
                 lambda u, v: jcol((0xF6, 0xE3, 0xB4), 5), BRUSH_TEX, 6.0, 0.4, 100)
    b.flush(img, new_layer(img, 'sun'))

    # 地：冷紫的夕影田
    b = Buckets()
    band(b, 146, 264, [(0x6A, 0x68, 0x94), (0x49, 0x4C, 0x74), (0x5A, 0x55, 0x84),
                       (0x3C, 0x3E, 0x62), (0x82, 0x76, 0x7E)], rows=7, per_row=6,
         ln=(30, 84), size=(18, 36), hs=0.30, op=88)
    # 垛根一道暖反光
    for _ in range(8):
        x = RNG.uniform(-20, W)
        y = RNG.uniform(150, 176)
        stroke(b, x, y, x + RNG.uniform(28, 58), y + RNG.uniform(-3, 3),
               jcol((0xB4, 0x94, 0x74), 10), BRUSH_TEX, RNG.uniform(10.0, 18.0), 0.3, 45)
    b.flush(img, new_layer(img, 'ground'))

    # 垛：左暗紫、右受光的金锥
    b = Buckets()
    apex = (132, 86)
    ybase = 186
    rx = 56

    def colfn(lat, t):
        if t > 0.86 and abs(lat) > 0.72:
            return jcol((0x3E, 0x3B, 0x5C), 7)      # 底缘踏进去的影子
        if lat > 0.55 and t < 0.5:
            return jcol((0xF0, 0xD9, 0xA0), 7)      # 右上受光面
        if lat > 0.30:
            return jcol((0xD9, 0xA9, 0x5C), 8)      # 金
        if lat < -0.30:
            return jcol((0x4E, 0x4A, 0x70), 8)      # 左暗面
        return jcol((0x63, 0x5F, 0x8A), 8)          # 中间的青紫过渡
    tri_fill(b, apex[0], apex[1], ybase, rx, colfn, size=(7, 13))

    # 沿两棱再描：右棱亮、左棱暗
    paint_rim(b, apex[0], apex[1], apex[0] + rx, ybase, [(0xF0, 0xD9, 0xA0), (0xE2, 0xBE, 0x7E)], 26)
    paint_rim(b, apex[0], apex[1], apex[0] - rx, ybase, [(0x45, 0x43, 0x66), (0x3E, 0x3B, 0x5C)], 24)
    # 顶结一撮
    for _ in range(9):
        x = apex[0] + RNG.uniform(-6, 6)
        y = apex[1] + RNG.uniform(0, 12)
        stroke(b, x, y, x + RNG.uniform(-4, 4), y + 6, jcol((0xE8, 0xC8, 0x8C), 7),
               BRUSH_TEX, RNG.uniform(4.0, 7.0), 0.45, 95)
    b.flush(img, new_layer(img, 'stack'))

    save_png(img, 'haystack_bg.png')


# ---------------------------------------------------------------- 变体 4：蓝睡莲（特写）

def variant_bluelily():
    global RNG
    RNG = random.Random(20261031)
    global DEEPISH
    DEEPISH = (0x17, 0x2E, 0x33)

    # --- 前景：只有花（带透明）
    img_fg = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)
    b = Buckets()
    paint_blossom2(b, 126, 146, 84, 13,
                   col_hl=(0xEE, 0xF1, 0xF3), col_root=(0x8E, 0x8E, 0xC2),
                   col_center=(0xD8, 0xC4, 0x6E))
    b.flush(img_fg, new_layer(img_fg, 'flowers'))
    save_png(img_fg, 'bluelily_fg.png')

    # --- 背景：深青紫池水 + 叶 + 压暗（不透明）
    img_bg = Gimp.Image.new(W, H, Gimp.ImageBaseType.RGB)

    b = Buckets()
    paint_base(b, (0x27, 0x59, 0x5B))
    b.flush(img_bg, new_layer(img_bg, 'base'))

    b = Buckets()
    band(b, -14, 268, [(0x17, 0x2E, 0x33), (0x27, 0x59, 0x5B), (0x43, 0x3C, 0x63),
                       (0x35, 0x6B, 0x4C), (0x1E, 0x44, 0x4A), (0x54, 0x4A, 0x70)],
         rows=12, per_row=5, ln=(34, 96), size=(20, 42), hs=0.28, op=88)
    # 水影里的紫破色
    for _ in range(18):
        x = RNG.uniform(-24, W)
        y = RNG.uniform(90, H)
        stroke(b, x, y, x + RNG.uniform(38, 80), y + RNG.uniform(-7, 7),
               jcol((0x58, 0x4E, 0x86), 10), BRUSH_TEX, RNG.uniform(22.0, 38.0), 0.28, 48)
    b.flush(img_bg, new_layer(img_bg, 'water'))

    b = Buckets()
    paint_pad(b, 210, 212, 64, 28, (0x3E, 0x62, 0x52), (0x7A, 0x94, 0x6E), (0x22, 0x3A, 0x33), (0x35, 0x62, 0x5E))
    paint_pad(b, 34, 236, 82, 34, (0x46, 0x6E, 0x52), (0x8A, 0xA2, 0x74), (0x24, 0x42, 0x36), (0x3E, 0x62, 0x5E))
    b.flush(img_bg, new_layer(img_bg, 'pads'))

    b = Buckets()
    # 水面碎高光
    for _ in range(22):
        x = RNG.uniform(-10, W)
        y = RNG.uniform(20, 180)
        col = jcol((0x9A, 0xAE, 0xB4) if RNG.random() < 0.7 else (0x7E, 0x9A, 0xA0), 6)
        stroke(b, x, y, x + RNG.uniform(16, 34), y + RNG.uniform(-2, 2),
               col, BRUSH_SOFT, RNG.uniform(7.0, 13.0), 0.45, 45)
    b.flush(img_bg, new_layer(img_bg, 'glints'))

    b = Buckets()
    paint_shadow_low(b, [(0x0E, 0x22, 0x28), (0x2A, 0x26, 0x40)], n=84, y0_frac=0.74, op=76)
    for _ in range(18):
        x = RNG.uniform(-12, W)
        y = RNG.uniform(-10, 12)
        col = jcol((0x2A, 0x26, 0x40) if RNG.random() < 0.5 else (0x17, 0x36, 0x38), 8)
        stroke(b, x, y, x + RNG.uniform(22, 42), y + RNG.uniform(-2, 2),
               col, BRUSH_SOFT, RNG.uniform(13.0, 21.0), 0.5, 62)
    b.flush(img_bg, new_layer(img_bg, 'shadow'))

    save_png(img_bg, 'bluelily_bg.png')


# ---------------------------------------------------------------- 主流程

def main():
    global DEEPISH
    os.makedirs(OUTDIR, exist_ok=True)
    Gimp.context_set_antialias(True)
    Gimp.context_set_paint_mode(Gimp.LayerMode.NORMAL)
    Gimp.context_set_stroke_method(Gimp.StrokeMethod.PAINT_METHOD)

    log('== sunrise ==')
    variant_sunrise()
    log('== poppies ==')
    variant_poppies()
    log('== haystack ==')
    variant_haystack()
    log('== bluelily ==')
    variant_bluelily()
    DEEPISH = (0x14, 0x33, 0x38)

    with open(os.path.join(OUTDIR, 'done.txt'), 'w') as f:
        f.write('done')
    log('DONE')


try:
    main()
except Exception:
    log('FAILED', traceback.format_exc())

for line in LOG:
    print(line)
sys.stdout.flush()
os._exit(0)
