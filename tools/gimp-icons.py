#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/gimp-icons.py —— 用 GIMP 画笔引擎画"手绘感"的图标（对比用样本）。

**不是所有材质都该交给 GIMP**。判据是**实际显示尺寸**：

  材质            显示尺寸      谁更合适
  笔触 256×16     256×9         GIMP（软笔触在小尺寸下仍有质感）✓ 已画
  界面图标 64×64  12–24px       脚本（硬边 + 整数像素吸附；笔刷的抗锯齿到这个尺寸会糊）
  role 三图标     16–22px       脚本（要在小尺寸下还认得出是剑/杖/盾）
  地图按钮图标    11×11         脚本（更小）
  圆角边纹/遮罩/发丝线 1–3px   脚本（必须像素级精确：9-slice 环宽、遮罩圆角、发丝线整行）

但"手绘感在 64×64 里到底留不留得住"是能看出来的，不是推出来的 —— 所以这里拿
**关闭钮的 X / 地图追踪的准星 / role 坦克的盾**三个当样本，各出一张 GIMP 版，
和脚本版并排放到真实显示尺寸上比。

用法（便携版 GIMP 3.2）：
  gimp-console-3.2.exe -i --batch-interpreter=python-fu-eval ^
      -b "import runpy; runpy.run_path(r'<abs path>', run_name='__main__', init_globals=globals())"

输出：%TEMP%\gimp-icons\*.png（之后用 tools/tga-post.js 转成项目格式的 TGA）
"""

import math
import os
import sys
import traceback

LOG = []


def log(*a):
    LOG.append(' '.join(str(x) for x in a))


S = 64                      # 图标画布
OUT = os.path.join(os.environ.get('TEMP', '/tmp'), 'gimp-icons')
os.makedirs(OUT, exist_ok=True)

WHITE = (255, 255, 255)
GREY_L = (255, 255, 255)
GREY_D = (168, 168, 168)


def gegl_color(rgb, alpha=1.0):
    """分量必须是 0..1 的浮点（传 0..255 会被夹成纯白）。"""
    c = Gegl.Color()
    c.set_rgba(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, alpha)
    return c


def stroke(img, layer, color, brush_name, size, hardness, spacing, opacity, pts):
    """沿折线盖章：每个点一条 0.01 长的小路径 = 一个笔触点。"""
    Gimp.context_set_brush(Gimp.Brush.get_by_name(brush_name))
    Gimp.context_set_brush_size(size)
    Gimp.context_set_brush_hardness(hardness)
    Gimp.context_set_brush_spacing(spacing)
    Gimp.context_set_opacity(opacity)
    Gimp.context_set_paint_mode(Gimp.LayerMode.NORMAL)
    Gimp.context_set_stroke_method(Gimp.StrokeMethod.PAINT_METHOD)
    Gimp.context_set_foreground(gegl_color(color))
    for (x, y) in pts:
        p = Gimp.Path.new(img, 'd')
        sid = p.bezier_stroke_new_moveto(x, y)
        p.bezier_stroke_lineto(sid, x + 0.01, y)
        img.insert_path(p, None, 0)
        layer.edit_stroke_item(p)


def line(x0, y0, x1, y1, n=26):
    return [(x0 + (x1 - x0) * i / (n - 1.0), y0 + (y1 - y0) * i / (n - 1.0)) for i in range(n)]


def arc(cx, cy, r, a0, a1, n=40):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / (n - 1.0)),
             cy + r * math.sin(a0 + (a1 - a0) * i / (n - 1.0))) for i in range(n)]


def new_canvas():
    img = Gimp.Image.new(S, S, Gimp.ImageBaseType.RGB)
    layer = Gimp.Layer.new(img, 'i', S, S, Gimp.ImageType.RGBA_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
    img.insert_layer(layer, None, 0)
    Gimp.context_set_antialias(True)
    return img, layer


def save(img, name):
    out = os.path.join(OUT, name + '.png')
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img, Gio.File.new_for_path(out), None)
    log('SAVED', out)


def paint_close_x():
    """关闭钮的 X：两道手绘的斜线。笔画要够粗（64×64 上 7px → 24px 显示时约 2.6px）。"""
    img, layer = new_canvas()
    stroke(img, layer, WHITE, 'Charcoal 01', 7.0, 0.55, 6, 100, line(15, 15, 49, 49))
    stroke(img, layer, WHITE, 'Charcoal 01', 7.0, 0.55, 6, 100, line(49, 15, 15, 49))
    save(img, 'monet_close_normal')


def paint_crosshair():
    """地图追踪的准星：一个圈 + 四向刻度。"""
    img, layer = new_canvas()
    stroke(img, layer, WHITE, 'Pencil 02', 5.0, 0.5, 6, 100, arc(32, 32, 17, 0, math.tau, 44))
    for a in (0, math.pi / 2, math.pi, 3 * math.pi / 2):
        stroke(img, layer, WHITE, 'Pencil 02', 5.0, 0.5, 6, 100,
               line(32 + 20 * math.cos(a), 32 + 20 * math.sin(a),
                    32 + 29 * math.cos(a), 32 + 29 * math.sin(a), 6))
    save(img, 'monet_map_tracking')


def paint_shield():
    """role 坦克的盾：近白芯 + 灰色侧影（两层，灰度是既定决策）。"""
    img, layer = new_canvas()
    body = line(18, 12, 18, 36, 8) + line(18, 36, 32, 52, 10) + line(32, 52, 46, 36, 10) + line(46, 36, 46, 12, 8)
    shadow = [(x + 2.5, y + 2.5) for (x, y) in body]
    stroke(img, layer, GREY_D, 'Charcoal 02', 5.0, 0.5, 6, 100, shadow)
    stroke(img, layer, GREY_L, 'Charcoal 01', 5.0, 0.55, 6, 100, body)
    save(img, 'monet_role_tank')


try:
    paint_close_x()
    paint_crosshair()
    paint_shield()
except Exception:
    log('FAILED', traceback.format_exc())

for line_ in LOG:
    print(line_)
sys.stdout.flush()
Gimp.quit()
