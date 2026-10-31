/**
 * MonetUI 纹理批量重生成器
 * 基于 @napi-rs/canvas 的精确 2D 渲染，替代 PowerShell 逐像素绘制
 * 
 * 输出规范：
 *   - 尺寸: 2 的幂次方
 *   - 格式: 32bit uncompressed TGA
 *   - 命名: 小写下划线
 *   - 透明: Alpha=0（非纯黑）
 */

const { createCanvas } = require('@napi-rs/canvas');
const os = require('os');
const fs = require('fs');
const path = require('path');

// 源（TGA）落在 Assets-src/Textures：**进 git、不发行**。发行包里只有 BLP（Assets/Textures）。
// 写出一张 TGA 后由本脚本自动调 `node tools/tga-to-blp.js` 同步出 BLP（见末尾 toBLP）。
const OUT_DIR = path.join(__dirname, '..', 'Assets-src', 'Textures');
const SHIP_DIR = path.join(__dirname, '..', 'Assets', 'Textures');
const TEMP_DIR = path.join(os.tmpdir(), 'opencode', 'texture-compare');
const VARIANT_DIR = path.join(os.tmpdir(), 'opencode', 'texture-variants');

// 设计系统：从现有纹理提取的共享色板
const PALETTE = {
  core:    '#fffcf6',  // 主色：暖白/奶油白（**只给不染色的美术图**：笔刷笔触、角落装饰、close hover）
  // 染色模具色：凡是被 SetVertexColor / SetBackdropBorderColor 上色的贴图，只能用它。
  // 引擎是 贴图 × 顶点色 相乘，所以贴图里带的色相会原样乘进最终颜色：
  //   #fffcf6 → borderColor × (1, 0.988, 0.965)，蓝少 3.5%。
  // 一根几百像素长的边框用暖色笔触，跟旁边用 WHITE8X8 的平边框就不是一个颜色；
  // 主题换个冷色，按下态的金 X 就成浑浊的蓝褐。
  // 这跟透明像素用纯白衬底、role 图标用纯灰度是同一条规则：模具不该自己带色相。
  stencil: '#ffffff',
  coreHi:  '#ffffff',  // 高光白
  coreLo:  '#f5ead6',  // 暗部暖白
  accent:  '#d8a75b',  // 强调色：金/琥珀
  accentHi:'#e8c078',  // 亮金
  shadow:  '#2e2a26',  // 阴影（仅用于细节，非透明）
};

// ============================================================
// 变体（visual variant）
// ============================================================
// 三套只在"视觉重量"这一个维度上分档：线宽 + 图标留白 + 织纹密度 + role 灰度对比 +
// 关闭钮三态色。色板底色、描边宽度这些**不是**自由变量：
//   * monet_barfill 是平色，明暗在运行期由 Widget:BarGradient 算，与变体无关；
//   * barfill / brush_stroke / 发丝线 / 遮罩的形状也不随变体走。
let LINE_WIDTH = null;   // 由 applyVariant 填
let GLYPH = null;        // 图标在画布里的占比系数
let CLOSE = null;        // 关闭钮三态
let ROLE_EDGE = null;    // role 图标灰度侧影
let WEAVE = null;        // 织纹密度

const VARIANTS = {
  standard: {
    label: '标准',
    note: '现状基线。线宽 2px、图标占画布 55%、织纹孔隙适中、role 灰度对比中等。',
    lineWidth: { icon: 2, plusMinus: 4, hairline: 1 },
    glyph: 1.0,
    roleEdge: '#a8a8a8',
    close: { normal: PALETTE.stencil, hover: PALETTE.accentHi, push: '#acacac' },
    weave: { canvasStep: 8, canvasLine: 2.0, canvasAlpha: 0.35, diagonalK: 2.0, diagonalAlpha: 0.50 },
  },
  bold: {
    label: '厚重',
    note: '线宽 3px、图形略微撑满、织纹更粗、role 灰度压得更深。缩到 16–22px 时最不容易糊。',
    lineWidth: { icon: 3, plusMinus: 5, hairline: 1 },
    glyph: 1.06,
    roleEdge: '#787878',
    close: { normal: PALETTE.stencil, hover: '#f2cb8a', push: '#888888' },
    weave: { canvasStep: 8, canvasLine: 3.0, canvasAlpha: 0.42, diagonalK: 1.7, diagonalAlpha: 0.58 },
  },
  fine: {
    label: '精细',
    note: '图形收小一圈、留白更多，织纹更稀，role 灰度更浅。偏古典安静的观感。',
    lineWidth: { icon: 2, plusMinus: 3, hairline: 1 },
    glyph: 0.86,
    roleEdge: '#cccccc',
    close: { normal: PALETTE.stencil, hover: '#eed9ac', push: '#b1b1b1' },
    weave: { canvasStep: 8, canvasLine: 1.5, canvasAlpha: 0.26, diagonalK: 2.5, diagonalAlpha: 0.40 },
  },
  // 线宽和织纹本来就是两条独立的轴，各取一档即可 —— 没有"混搭不成立"的道理。
  // 取 bold 的线宽（3px 在 18px 实显下最实）配 standard 的织纹（bold 的 3px 线在
  // 18px 会互相叠成一片白，织纹结构全丢）。role 灰度跟着 bold，因为它也是跟着线宽走的。
  crisp: {
    label: '锐利',
    note: '重厚的线宽（图标 3px / 加减 5px）+ 标准的织纹。小尺寸最清晰，同时保住织纹结构。',
    lineWidth: { icon: 3, plusMinus: 5, hairline: 1 },
    glyph: 1.06,
    roleEdge: '#787878',
    close: { normal: PALETTE.stencil, hover: '#f2cb8a', push: '#888888' },
    weave: { canvasStep: 8, canvasLine: 2.0, canvasAlpha: 0.35, diagonalK: 2.0, diagonalAlpha: 0.50 },
  },
  // 往"最重"探一档，回答选了 crisp 之后自然要问的下一句：还能不能再粗，粗到哪一步会显得笨。
  // 图标占比反而收小到 0.94：4px 的笔触压在 106% 的图形上会把转折糊成一团，
  // 收小一圈刚好让笔画之间留出呼吸 —— 这是"浓"和"挤"的分界。
  heavy: {
    label: '浓重',
    note: '图标 4px / 加减 6px 的最重档，图形收小一圈换呼吸感，role 侧影压到最深。',
    lineWidth: { icon: 4, plusMinus: 6, hairline: 1 },
    glyph: 0.94,
    roleEdge: '#5c5c5c',
    close: { normal: PALETTE.stencil, hover: '#ffd98f', push: '#707070' },
    weave: { canvasStep: 8, canvasLine: 2.0, canvasAlpha: 0.35, diagonalK: 2.0, diagonalAlpha: 0.50 },
  },
};

function applyVariant(key) {
  const v = VARIANTS[key];
  if (!v) throw new Error('未知变体: ' + key + '（可选: ' + Object.keys(VARIANTS).join(' / ') + '）');
  LINE_WIDTH = v.lineWidth;
  GLYPH = v.glyph;
  CLOSE = v.close;
  ROLE_EDGE = v.roleEdge;
  WEAVE = v.weave;
  ROLE_GRAY.edge = v.roleEdge;
  return v;
}

function saveTGA(canvas, outputPath) {
  const width = canvas.width;
  const height = canvas.height;
  const ctx = canvas.getContext('2d');
  const imageData = ctx.getImageData(0, 0, width, height);
  const pixels = imageData.data;

  // 规范：透明像素的 RGB 必须填成纯白 (255,255,255)，不留黑也不填"平均色"。
  // 客户端生成 mip / 双线性过滤时会把边缘像素的颜色拖进可见区，纯黑会在每个图标
  // 周围描一圈灰边；而我们的材质全部是 SetVertexColor 可染色的近白，染色是乘法，
  // 纯白哑光乘任何色调都得到该色调本身，不会带进偏色残留。
  // 参考插件 EllesmereUI 的做法一致：所有可染色遮罩（rounded/*、basics/ring_*）的
  // alpha=0 像素都恰好是 (255,255,255)（"white matte"）。
  for (let i = 0; i < pixels.length; i += 4) {
    if (pixels[i + 3] === 0) { pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255; }
  }

  const header = Buffer.alloc(18);
  header.writeUInt8(0, 0);       // ID length
  header.writeUInt8(0, 1);       // no colormap
  header.writeUInt8(2, 2);       // uncompressed true-color
  header.writeUInt16LE(0, 3);    // colormap origin
  header.writeUInt16LE(0, 5);    // colormap length
  header.writeUInt8(0, 7);       // colormap depth
  header.writeUInt16LE(0, 8);    // x origin
  header.writeUInt16LE(0, 10);   // y origin
  header.writeUInt16LE(width, 12);
  header.writeUInt16LE(height, 14);
  header.writeUInt8(32, 16);     // 32 bits per pixel
  // descriptor 0x08: 8 alpha bits, BOTTOM-LEFT origin (TGA 标准，与项目既有文件一致)
  header.writeUInt8(0x08, 17);

  const pixelBuffer = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    const srcRow = y * width * 4;
    const dstRow = (height - 1 - y) * width * 4;
    for (let x = 0; x < width; x++) {
      const si = srcRow + x * 4;
      const di = dstRow + x * 4;
      pixelBuffer[di]     = pixels[si + 2]; // B
      pixelBuffer[di + 1] = pixels[si + 1]; // G
      pixelBuffer[di + 2] = pixels[si];     // R
      pixelBuffer[di + 3] = pixels[si + 3]; // A
    }
  }

  const dir = path.dirname(outputPath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(outputPath, Buffer.concat([header, pixelBuffer]));
  return { width, height, size: 18 + width * height * 4 };
}

// ============================================================
// 绘制辅助
// ============================================================

// ============================================================
// 像素吸附工具
// ============================================================
// 抗锯齿对曲线是对的，对**本该对齐的直边**是错的。fillRect(30.5, ...) 会让左右两列
// 像素各拿到半个覆盖，渲染出来就是一条 50% 灰的发虚边 —— 加减号、窗口控件、任何构成
// 网格的直线段都栽在这里。规则只有一条：**边必须落在整数像素边界上**，落在边界上就
// 天然无 AA、每个像素都是满 alpha。
// 代价是边长只能取整像素，所以用"先吸附边界、再回填厚度"而不是"吸附中心"——
// 后者会让一根 3px 的臂偏出中心半像素，一组对称图形就不对称了。

// 填充实心矩形：边界取整，覆盖 x0..x1 的整数像素（不含 x1+1）
function pxRect(ctx, x0, y0, x1, y1, color) {
  const X0 = Math.round(x0), Y0 = Math.round(y0);
  const X1 = Math.round(x1), Y1 = Math.round(y1);
  if (X1 <= X0 || Y1 <= Y0) return;
  ctx.fillStyle = color;
  ctx.fillRect(X0, Y0, X1 - X0, Y1 - Y0);
}

// 水平线（两端方帽）：把**覆盖范围**吸附到整数像素，中心线随之回退半个线宽
function pxHLine(ctx, x0, x1, yc, lineW, color) {
  const i = lineW / 2;
  pxRect(ctx, x0, yc - i, x1, yc + i, color);
}

// 竖直线：同上，沿 y 方向
function pxVLine(ctx, y0, y1, xc, lineW, color) {
  const i = lineW / 2;
  pxRect(ctx, xc - i, y0, xc + i, y1, color);
}

// 描边矩形：外框吸附到整数像素，中心线内缩半个线宽，笔触完整落在框内
function pxStrokeRect(ctx, x0, y0, x1, y1, lineW, color) {
  const X0 = Math.round(x0), Y0 = Math.round(y0);
  const X1 = Math.round(x1), Y1 = Math.round(y1);
  const w = X1 - X0 - lineW, h = Y1 - Y0 - lineW;
  if (w <= 0 || h <= 0) return;
  ctx.strokeStyle = color;
  ctx.lineWidth = lineW;
  ctx.strokeRect(X0 + lineW / 2, Y0 + lineW / 2, w, h);
}

// ============================================================
// 图标字形几何（2026-10-28 照参考插件重定）
// ============================================================
// 参考的 tick / X / 箭头（Andromeda ui-checkbox-tick / ui-close / ui-arrow-up）在 32px 画布上：
// 笔画 ≈ 4px（画布的 12.5%）、字形撑到 ≈ 28/32（87%）、边缘全抗锯齿。
// 我们原来是**固定 2px 笔画 + 55% 字形**，缩到实显 16–22px 时细得几乎看不见，也没法再"加粗"
// （2px 在 64px 画布上只有 3%）。所以笔画宽度改成跟画布成比例，字形也撑开。
//
// 注意：笔画跟画布成比例，但**直边仍要落在像素边界上**（pxRect/pxHLine 那一套照旧用于构成
// 网格的直线：窗口控件、加减号、光标杆）。曲线与斜线走 canvas 抗锯齿，那是对的。
// 2026-10-29 改「细线 + 留白」（作者要求，以关闭按钮为样板 / OpenCode 风）：
//   目标：显示字形 ≈ 11px、线宽 ≈ 1.1px，按控件的**实际显示尺寸**校准 ——
//   同一张 64px 纹理，显示越小，笔画在纹理里要越粗、字形占比要越大（16px 滚动条 vs 24px 窗口按钮）。
//   旧版字形 0.88（贴边）+ 12.5% 笔画，在 24px 关闭钮上又粗又贴边。
const GLYPH_RENDER_PX = 11;    // 目标显示字形尺寸（物理像素）
const GLYPH_TARGET_PX = 1.1;   // 目标显示线宽（物理像素）
const gSpan   = (displayPx) => Math.min(0.86, GLYPH_RENDER_PX / (displayPx || 20));
const gStroke = (displayPx) => Math.max(2, Math.round(GLYPH_TARGET_PX * 64 / (displayPx || 20) * 2) / 2);

// close 风格（作者指定 2026-10-29）：chevron / arrow 与关闭按钮**完全同口径** ——
// 字形 44%（18→46）、笔画 3px、圆头端帽。不按显示尺寸放大（那样在 16px 滚动条上又粗又贴边）。
const CLOSE_SPAN = 0.44;
const CLOSE_STROKE = 3;

function drawPlus(ctx, cx, cy, armLen, armW, color) {
  // armW 已按 LINE_WIDTH.plusMinus 传入；上下左右四条臂各自吸附，所以十字一定对称
  pxRect(ctx, cx - armW / 2, cy - armLen, cx + armW / 2, cy + armLen, color);
  pxRect(ctx, cx - armLen, cy - armW / 2, cx + armLen, cy + armW / 2, color);
}

function drawMinus(ctx, cx, cy, length, height, color) {
  // height 已按 LINE_WIDTH.plusMinus 传入
  pxRect(ctx, cx - length / 2, cy - height / 2, cx + length / 2, cy + height / 2, color);
}

function drawChevronUp(ctx, cx, cy, size, color, displayPx) {
  // 向上 V 形：顶点在上。close 风格 —— 字形 44%、笔画 3px（与关闭按钮同口径）。
  const s = size / 2, w = s * CLOSE_SPAN * 0.92, h = s * CLOSE_SPAN * 0.52;
  ctx.strokeStyle = color;
  ctx.lineWidth = CLOSE_STROKE;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(cx - w, cy + h);
  ctx.lineTo(cx, cy - h);
  ctx.lineTo(cx + w, cy + h);
  ctx.stroke();
}

function drawChevronDown(ctx, cx, cy, size, color, displayPx) {
  const s = size / 2, w = s * CLOSE_SPAN * 0.92, h = s * CLOSE_SPAN * 0.52;
  ctx.strokeStyle = color;
  ctx.lineWidth = CLOSE_STROKE;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(cx - w, cy - h);
  ctx.lineTo(cx, cy + h);
  ctx.lineTo(cx + w, cy - h);
  ctx.stroke();
}

function drawArrowLeft(ctx, cx, cy, size, color, displayPx) {
  // 左向 V 形（与 chevron 同一套几何）。close 风格 —— 字形 44%、笔画 3px。
  const s = size / 2, w = s * CLOSE_SPAN * 0.92, h = s * CLOSE_SPAN * 0.52;
  ctx.strokeStyle = color;
  ctx.lineWidth = CLOSE_STROKE;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(cx + w, cy - h);
  ctx.lineTo(cx - w, cy);
  ctx.lineTo(cx + w, cy + h);
  ctx.stroke();
}

function drawArrowRight(ctx, cx, cy, size, color, displayPx) {
  const s = size / 2, w = s * CLOSE_SPAN * 0.92, h = s * CLOSE_SPAN * 0.52;
  ctx.strokeStyle = color;
  ctx.lineWidth = CLOSE_STROKE;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(cx - w, cy - h);
  ctx.lineTo(cx + w, cy);
  ctx.lineTo(cx - w, cy + h);
  ctx.stroke();
}

function drawX(ctx, cx, cy, size, color, displayPx) {
  // 关闭 X：粗笔画 + 圆帽，字形撑到 88%（参考 ui-close 是 32px 画布上 ~4px 笔画、28/32 字形）。
  const s = size / 2 * gSpan(displayPx) * 0.94;
  ctx.strokeStyle = color;
  ctx.lineWidth = gStroke(displayPx);
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(cx - s, cy - s);
  ctx.lineTo(cx + s, cy + s);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(cx + s, cy - s);
  ctx.lineTo(cx - s, cy + s);
  ctx.stroke();
}

function drawCircleBorder(ctx, cx, cy, r, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = LINE_WIDTH.icon;
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.stroke();
}

function drawCheck(ctx, cx, cy, size, color, displayPx) {
  // 标准勾形：短臂在左下，长臂向右上挑出。
  // 笔画 12.5%、字形 88%（参考 ui-checkbox-tick：32px 画布上 ~4px 笔画、28/32 字形）。
  const s = size / 2 * gSpan(displayPx);
  ctx.strokeStyle = color;
  ctx.lineWidth = gStroke(displayPx);
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(cx - s * 0.78, cy + s * 0.04);
  ctx.lineTo(cx - s * 0.22, cy + s * 0.58);
  ctx.lineTo(cx + s * 0.80, cy - s * 0.66);
  ctx.stroke();
}

function drawCheckFilled(ctx, cx, cy, size, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = LINE_WIDTH.icon;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  const s = size / 2;
  ctx.beginPath();
  ctx.moveTo(cx - s * 0.7, cy + s * 0.1);
  ctx.lineTo(cx - s * 0.15, cy + s * 0.7);
  ctx.lineTo(cx + s * 0.8, cy - s * 0.6);
  ctx.stroke();
}

function drawSearch(ctx, cx, cy, r, lineW, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = lineW;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.stroke();
  const hx = cx + r * 0.7;
  const hy = cy + r * 0.7;
  ctx.beginPath();
  ctx.moveTo(hx, hy);
  ctx.lineTo(hx + r * 0.55, hy + r * 0.55);
  ctx.stroke();
}

function drawRadio(ctx, cx, cy, size, displayPx) {
  // 单选钮：环 + 实心点。外半径 = 字形半径（gSpan 是画布占比），环宽按显示尺寸校准（细线）。
  const half = size / 2;
  const R = half * gSpan(displayPx);
  const ring = gStroke(displayPx);
  ctx.strokeStyle = PALETTE.stencil;
  ctx.lineWidth = ring;
  ctx.beginPath();
  ctx.arc(cx, cy, R - ring / 2, 0, Math.PI * 2);
  ctx.stroke();
  ctx.fillStyle = PALETTE.stencil;
  ctx.beginPath();
  ctx.arc(cx, cy, R * 0.42, 0, Math.PI * 2);
  ctx.fill();
}

function drawMaximize(ctx, cx, cy, size, color, displayPx) {
  // 窗口按钮：方形外框 + 顶部标题栏高光。线宽按显示尺寸校准（细线）；直线段仍走像素吸附，不许发虚。
  const s = size / 2 * gSpan(displayPx) * 0.82;
  const w = gStroke(displayPx);
  pxStrokeRect(ctx, cx - s, cy - s, cx + s, cy + s, w, color);
  pxHLine(ctx, cx - s + w, cx + s - w, cy - s + Math.round(w * 1.6), Math.max(2, Math.round(w * 0.55)), PALETTE.accent);
}

function drawMinimize(ctx, cx, cy, size, color, displayPx) {
  // 一条横杠：窗口最小化的通用形状
  const s = size / 2 * gSpan(displayPx) * 0.82;
  const w = gStroke(displayPx);
  pxHLine(ctx, cx - s, cx + s, cy, w, color);
}

function drawRestore(ctx, cx, cy, size, lineW, color) {
  const s = size * 0.35;
  pxStrokeRect(ctx, cx - s * 0.2, cy - s, cx + s * 1.2, cy + s * 0.4, lineW, color);
  pxStrokeRect(ctx, cx - s, cy - s * 0.2, cx + s * 0.4, cy + s * 1.2, lineW, color);
}

// role 图标是**刻意无色**的灰度图（R == G == B），颜色全部由运行期顶点色决定。
// 见 Utils/Media.lua：染色与否取决于该玩家是不是队长/助理，是状态信号而不是职业语义。
// 做成灰度的三个理由：
//   1) 一张图服务多种状态（队长/助理染色、其他人单色），不必为每个状态各出一张；
//   2) 语义色若烘进纹理，就得为每种职业各出一套；灰度把色相完全交给 SetVertexColor；
//   3) 灰度下形状仍然可读 —— 靠明度渐变（芯 255 → 边 168）撑住立体感，这是 1) 和 2) 的前提。
// 参考插件 EllesmereUI 的 icons\roles 两张（leader/assist，16x16）走的是同一条路：
// 纯灰度、14–15 级灰、刻意无色以便按状态染色。
const ROLE_GRAY = {
  core: '#ffffff',   // 芯（最亮）
  mid:  '#e4e4e4',   // 过渡
  edge: '#8e8e8e',   // 边（最暗，撑出轮廓）
};

// 近白芯 + 灰度侧影的径向渐变。半径按材质大小给，芯留白、边缘压暗。
function roleGradient(ctx, cx, cy, r) {
  const g = ctx.createRadialGradient(cx, cy, r * 0.05, cx, cy, r);
  g.addColorStop(0.00, ROLE_GRAY.core);
  g.addColorStop(0.55, ROLE_GRAY.mid);
  g.addColorStop(1.00, ROLE_GRAY.edge);
  return g;
}

// 反转径向渐变：**中间暗、边缘亮**（2026-10-29 作者要的盾牌效果）。芯压暗、外沿提亮。
function roleGradientInv(ctx, cx, cy, r) {
  const g = ctx.createRadialGradient(cx, cy, r * 0.05, cx, cy, r);
  g.addColorStop(0.00, ROLE_GRAY.edge);
  g.addColorStop(0.55, ROLE_GRAY.mid);
  g.addColorStop(1.00, ROLE_GRAY.core);
  return g;
}

// role 图标的统一画法（2026-10-28 照参考插件重画）：
//   实心剪影（不是细线描边）+ 柔和外发光 + 内沿压暗。
// 参考的 role 图标（Andromeda role-tank / role-healer / role-damager）是 68–83% 半透明像素的
// 渐变剪影 —— 缩到 16–22px 仍然认得出形状；我们原来是"细线 + 浅灰渐变"，小尺寸下糊成一根线。
// 三条纪律不变：整图只允许 R==G==B（染色模具，色相必须为 0）；alpha=0 处纯白；只调 alpha 的地方不染色。
function roleIcon(ctx, cx, cy, size, pathFn, opts) {
  const s = size / 2;
  const o = opts || {};
  const fillRule = o.evenodd ? 'evenodd' : 'nonzero';
  // ① 柔和外发光（参考图的剪影都带一层很淡的边光，太强就糊成一团）
  ctx.save();
  ctx.shadowColor = `rgba(255,255,255,${o.glowAlpha === undefined ? 0.35 : o.glowAlpha})`;
  ctx.shadowBlur = s * (o.glow === undefined ? 0.16 : o.glow);
  ctx.beginPath();
  pathFn(ctx, cx, cy, s);
  ctx.closePath();
  ctx.fillStyle = (o.invert ? roleGradientInv : roleGradient)(ctx, cx, cy, s * 1.05);
  ctx.fill(fillRule);
  ctx.restore();

  // ② 内沿压暗：clip 后描边，线宽加倍 → 只有内侧一半可见，等于给剪影加内阴影。
  //    **反转渐变（中间暗边缘亮）时不加** —— 那会把刚提亮的外沿又压暗，抵消效果。
  if (!o.invert) {
    ctx.save();
    ctx.beginPath();
    pathFn(ctx, cx, cy, s);
    ctx.closePath();
    ctx.clip(fillRule);
    ctx.beginPath();
    pathFn(ctx, cx, cy, s);
    ctx.closePath();
    ctx.strokeStyle = ROLE_GRAY.edge;
    ctx.lineWidth = s * 0.16;
    ctx.stroke();
    ctx.restore();
  }
}

// 十字的 12 个角点（a = 臂半宽，p = 臂长）。圆角版与直角版共用。
const PLUS_PTS = (s, a, p) => [
  [-a, -p], [a, -p], [a, -a], [p, -a], [p, a], [a, a],
  [a, p], [-a, p], [-a, a], [-p, a], [-p, -a], [-a, -a],
];

// 多边形圆角化：每个角用二次曲线切掉，半径不超过最短边的 45%（否则相邻圆角互相吃掉）。
function roundedPoly(c, x, y, pts, r) {
  const n = pts.length;
  const len = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]);
  let minEdge = Infinity;
  for (let i = 0; i < n; i++) minEdge = Math.min(minEdge, len(pts[i], pts[(i + 1) % n]));
  const rr = Math.min(r, minEdge * 0.45);
  for (let i = 0; i < n; i++) {
    const prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n];
    const l1 = len(prev, cur) || 1, l2 = len(cur, next) || 1;
    const p1 = [cur[0] - (cur[0] - prev[0]) / l1 * rr, cur[1] - (cur[1] - prev[1]) / l1 * rr];
    const p2 = [cur[0] + (next[0] - cur[0]) / l2 * rr, cur[1] + (next[1] - cur[1]) / l2 * rr];
    if (i === 0) c.moveTo(x + p1[0], y + p1[1]); else c.lineTo(x + p1[0], y + p1[1]);
    c.quadraticCurveTo(x + cur[0], y + cur[1], x + p2[0], y + p2[1]);
  }
  c.closePath();
}

// 单把匕首（原点 = 护手中心，刃朝上）：叶状刃 + 小护手 + 短柄 + 圆柄头。
// 与剑的差别是刃短而宽、护手小 —— 交叉或并排时靠这个差别和"剑"分开。
function daggerPath(c, s, o) {
  const bw = s * (o.bw || 0.30);          // 刃半宽
  const tip = -s * (o.tip || 0.86);
  const gw = s * (o.gw || 0.44), gh = s * 0.16;
  const gripW = s * (o.gripW || 0.13), gripEnd = s * 0.52, pomR = s * 0.15;
  c.moveTo(0, tip);
  c.lineTo(bw, tip + bw * 1.3);
  c.lineTo(bw * 0.78, 0);
  c.lineTo(-bw * 0.78, 0);
  c.lineTo(-bw, tip + bw * 1.3);
  c.closePath();
  c.rect(-gw, 0, gw * 2, gh);
  c.rect(-gripW, gh, gripW * 2, gripEnd - gh);
  c.moveTo(pomR, gripEnd);
  c.arc(0, gripEnd, pomR, 0, Math.PI * 2);
}

// 2026-10-31 A/B 定案（验收页 monetui-role-ab）：三枚全部按 8px 剪影重选。
// 旧三枚在 8px 的满墨格只有 24/12/3，dps 那把斜剑基本等于看不见。
function drawRoleTank(ctx, cx, cy, size) {
  // **宽盾**：撑到整格（w 0.90 / 高 1.80s），8px 满墨 28 格是全场最高的一档。
  // 用常规渐变（芯亮边暗）—— 反转渐变在 8px 会把芯读成一个黑洞。
  const s = size / 2, w = s * 0.90, top = -s * 0.88, bot = s * 0.92;
  roleIcon(ctx, cx, cy, size, (c, x, y) => {
    c.moveTo(x - w, y + top);
    c.lineTo(x + w, y + top);
    c.quadraticCurveTo(x + w, y + s * 0.14, x, y + bot);
    c.quadraticCurveTo(x - w, y + s * 0.14, x - w, y + top);
    c.closePath();
  });
}

function drawRoleHeal(ctx, cx, cy, size) {
  // **圆角十字**：臂半宽 0.24s、臂长 0.86s、圆角 0.20s。8px 满墨 20 / 半墨 9，
  // 与盾、双匕首的最小区分度 69.6（十字和盾 69.6、和双匕首 101.6）。
  const s = size / 2;
  roleIcon(ctx, cx, cy, size, (c, x, y) => roundedPoly(c, x, y, PLUS_PTS(s, s * 0.24, s * 0.86), s * 0.20));
}

function drawRoleDps(ctx, cx, cy, size) {
  // **并列双匕首**：两把竖直、不旋转（字身对齐像素栅格）。
  // 间距是硬约束：两把内缘离中心 ≥0.25s，8px 下中缝才有 2 格 —— 收近就并成一坨
  // （第一版 dx 0.44 / 护手 0.34 实测半墨 22 格，"两把"读不出来）。
  // 交叉 / V 形两版在 8px 都并成斜灰，且与十字的互差只有 55，已否决。
  const s = size / 2;
  roleIcon(ctx, cx, cy, size, (c, x, y) => {
    for (const dx of [-s * 0.50, s * 0.50]) {
      c.save(); c.translate(x + dx, y); daggerPath(c, s, { bw: 0.24, gw: 0.28 }); c.restore();
    }
  });
}

function drawBarFill(ctx, w, h) {
  // 状态条/滑块的"基材"，刻意画成**平的**：明暗不烘进纹理，由运行期 SetGradient 按条轴算。
  // 这是参考插件 EllesmereUI 的思路（EllesmereUIUnitFrames.lua:1337 ApplyBarGradient）：
  // 纹理只负责提供一块可染色的基色（SetVertexColor 的乘法底），体积感交给几何。
  // 之前把这道竖向渐变烘进 16x16 纹理，条一高就把 16 级渐变拉长 —— 滑块 thumb 那种
  // 12x40 的竖条上会变成一条 40px 的长渐变，而不是横截面的体积。
  // 画布保持 16x16 方形：方向无关，正方形状不携带任何方向信息，横条竖条通用。
  ctx.fillStyle = 'rgb(252,252,252)';
  ctx.fillRect(0, 0, w, h);
}

function drawBarFillThin(ctx, w, h) {
  // 细条剖面：**上亮下暗的单向**（用户 2026-10-30 定）。
  // 亮区要占大头、暗区只压在底缘一条（用户 2026-10-30 二次调整）：
  // 用 (1-t)^EXP 的幂曲线，EXP 越小亮部保持得越久。0.40 时 t=0.5 还有 209（而不是线性 175），
  // 4–6px 的条上前三四行几乎都是亮的，只有最后一两行掉下去。
  const BRIGHT = 240, DARK = 112, EXP = 0.40;
  for (let y = 0; y < h; y++) {
    const t = h <= 1 ? 0 : y / (h - 1);
    const v = Math.round(DARK + (BRIGHT - DARK) * Math.pow(1 - t, EXP));
    ctx.fillStyle = `rgb(${v},${v},${v})`;
    ctx.fillRect(0, y, w, 1);
  }
}

// 用户调的 64 行剖面（原始 TGA 是底部原点，所以这里是**下 → 上**）。
const BARFILL_GRADIENT_BOTTOM_UP = [
  141, 152, 163, 175, 189, 197, 205, 205, 206, 205, 205, 205, 203, 200, 200, 200,
  198, 198, 198, 197, 195, 192, 192, 189, 189, 186, 186, 183, 181, 178, 178, 175,
  173, 173, 170, 167, 167, 167, 161, 161, 157, 156, 156, 155, 152, 149, 149, 147,
  144, 144, 141, 139, 139, 137, 134, 133, 132, 132, 131, 131, 129, 126, 126, 124,
];

function drawBarFillGradient(ctx, w, h) {
  // 竖向剖面（顶暗 → 中下亮 → 底缘一条压暗的收边）。与 monet_barfill_thin 的区别：
  // 这张是"从上方受光"的单向渐变，适合 12px 以上的条；细条用 thin 那版的对称剖面。
  const rows = BARFILL_GRADIENT_BOTTOM_UP.slice().reverse();   // 顶 → 底
  for (let y = 0; y < h; y++) {
    const v = rows[Math.min(rows.length - 1, Math.round(y / Math.max(1, h - 1) * (rows.length - 1)))];
    ctx.fillStyle = `rgb(${v},${v},${v})`;
    ctx.fillRect(0, y, w, 1);
  }
}

function drawHairline(ctx, w, h) {
  // 发丝线：整幅就是一行满 alpha 的近白。
  // 参考插件的 thin-line-top / pixels-overshield-line 是同一个思路（单行 alpha=255、
  // 其余全透明，最细的一张只有 2x32）。画布 256x1 —— 贴图被拉成多高，这一行就铺多高，
  // 所以 Widget:Hairline 里 SetHeight(1) 才是"发丝"，拉高就变成"分隔带"。
  // 整幅铺满、没有任何边缘，也就没有对齐问题。
  ctx.fillStyle = 'rgb(252,252,252)';
  ctx.fillRect(0, 0, w, h);
}


function drawCorner(ctx, size) {
  // 角落装饰：固定小圆弧（线宽 1px，半径 4px）
  // 圆心放在 (radius, radius)、中心线半径 radius - lineWidth/2，两端正好落在画布边缘上：
  // 笔触横截面完整落在像素内（x∈[0,1] / y∈[0,1]），不会被边界裁掉半像素而发暗。
  // 四角使用时：原始 TOPLEFT 不翻转，TOPRIGHT 水平翻转，BOTTOMLEFT 垂直翻转，BOTTOMRIGHT 水平+垂直翻转
  const lineWidth = LINE_WIDTH.hairline;
  const radius = 4;
  const r = radius - lineWidth / 2;
  ctx.strokeStyle = PALETTE.core;
  ctx.lineWidth = lineWidth;
  ctx.lineCap = 'butt';
  ctx.beginPath();
  ctx.arc(radius, radius, r, Math.PI, Math.PI * 1.5);
  ctx.stroke();
}

function drawDiagonalWeave(ctx, size) {
  // 45° 斜纹编织。线宽必须按**垂直间距**算，不是按步距算：
  // 相邻两条平行斜线的垂直距离 = step / √2，线宽给到垂直间距的一半才留得住孔。
  // 迁移初版 线宽 = size*0.08 (5.1px) 配 步距 size/8 → 垂直间距 5.7px，单方向覆盖率 90%，
  // 两方向叠完实测 4096 个像素**没有一个是透明的** —— 织纹的"孔"没了，
  // 铺在按钮上就是一层均匀的白膜，而不是织物质感。
  ctx.strokeStyle = PALETTE.stencil;   // 被 ButtonMaterial 染色，笔触必须中性
  ctx.globalAlpha = WEAVE.diagonalAlpha;
  const step = size / WEAVE.canvasStep;
  const lineW = step / Math.SQRT2 / WEAVE.diagonalK;
  ctx.lineWidth = lineW;
  ctx.lineCap = 'butt';
  for (let i = -size; i < size * 2; i += step) {
    ctx.beginPath();
    ctx.moveTo(i, 0);
    ctx.lineTo(i + size, size);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(i + size, 0);
    ctx.lineTo(i, size);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

function drawCanvasWeave(ctx, size) {
  // 平纹编织（布纹底）。同 diagonal_weave：孔必须留出来。
  // 步距 8px、线宽 2px，与旧稿的观感一致（旧稿 period 8、线 ~2px、孔 ~3px）。
  ctx.strokeStyle = PALETTE.stencil;   // 被 ButtonMaterial 染色，笔触必须中性
  ctx.globalAlpha = WEAVE.canvasAlpha;
  const step = size / WEAVE.canvasStep;
  ctx.lineWidth = WEAVE.canvasLine;
  ctx.lineCap = 'butt';
  for (let y = 0; y <= size; y += step) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(size, y);
    ctx.stroke();
  }
  for (let x = 0; x <= size; x += step) {
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, size);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

function drawBarStripe(ctx, size) {
  // 状态条底纹：单向 45° 细斜纹（Andromeda 的 statusbar-stripes-thin 那一类）。
  //
  // 剖面（2026-10-31 按参考件实测定为 S1）：**周期 8**，每条线是
  //   **2px 满 alpha 核心 + 两侧各 1px 半 alpha（128）**，即 [128,255,255,128,0,0,0,0]。
  // 半像素过渡这条规矩没变（45° 的线只有硬边单像素时锯齿无过渡，越小越糊）；
  // 改的是**周期/密度**，依据来自 docs/texture-preview/aurora-verify/measure-stripe.js
  // 对两张进度条截图的逐列测量：
  //   · 参考件的亮纹水平截面 2 纹素 → 45° 折算垂直厚度 2/√2 ≈ 1.4 纹素，
  //     我们旧的 1 满 + 2 半 = 同样 1.4 —— **笔画粗细本来就一样**；
  //   · 差别全在密度：α 加权占空 参考件 27.3% / 我们（周期 4）50.3%。
  //     50% 读成"一片雾"，27% 才读成"一根根线"；
  //   · 参考件周期 ≈ 条的内容高（6.3 vs 6），一根斜纹正好跨过整个条高，视觉最整齐。
  //     但周期 6 **不能照抄**：64 % 6 ≠ 0，平铺时每个 tile 边界要断 43 个像素的相位
  //     （harness.js 独立复测过），而且 6 是硬边两像素、没有过渡。
  //   · 8 是"64 的约数 + 比 4 稀 + 保住半像素斜坡"三者唯一的交集：
  //     占空 37.5%，正落在 27% 与 50% 之间，向参考件靠拢又留一条过渡带过 mip。
  // 已知代价（实机要看的就是这一条）：4px 血条上 8 的周期等于"亮 4 格 / 空 4 格"，
  // 会从"织纹"退化成"dashes"；13px 施法条上是 1.6 条纹（旧版 3.25 条）。
  //
  // 用 ImageData 直接写，而不是 fillRect + globalAlpha：canvas 合成会把 alpha 抖成
  // 128/130 之类，剖面就不整齐了；这里要的是每个像素精确等于 255/128/0。
  // 颜色恒为纯白（被 BarWeave 的 SetVertexColor 染色，贴图不许带色相）；
  // alpha=0 的像素也显式写 255 —— 白衬底规则的源头就在这张图。
  const period = 8;
  const ramp = [128, 255, 255, 128, 0, 0, 0, 0];   // (x + y) % 8 的 alpha 剖面
  const img = ctx.createImageData(size, size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      img.data[i] = 255; img.data[i + 1] = 255; img.data[i + 2] = 255;
      img.data[i + 3] = ramp[(x + y) % period];
    }
  }
  ctx.putImageData(img, 0, 0);
}

// ============================================================
// 覆盖率描边的 glyph（2026-10-29，作者要「斜纹底布那种画法」）
// ============================================================
// 与 monet_stripe_weave 同一套光栅化：每个像素按到折线的距离算覆盖率
// （half + 0.5 - dist，半像素过渡），所以 1px 线在 1:1 下是精确的 255 / 过渡 / 0，
// 缩到实机尺寸也不会碎成点。几何与关闭按钮同口径：字形 44%、笔画 3px、圆头端帽
// （端点是"到点的距离"，覆盖率自然成圆角）。这是**替代 canvas 描边**的那条路：
// canvas 的 AA 在 1px 处只在"有/没有"之间挑，容易出锯齿。

// 到折线的最近距离。closed=false 时首尾不相连（开放折线）。
function distToPolyline(px, py, pts, closed) {
  let best = Infinity;
  const n = pts.length;
  const last = closed ? n : n - 1;
  for (let i = 0; i < last; i++) {
    const a = pts[i], b = pts[(i + 1) % n];
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    let t = len2 ? ((px - a[0]) * dx + (py - a[1]) * dy) / len2 : 0;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    const d = Math.hypot(a[0] + t * dx - px, a[1] + t * dy - py);
    if (d < best) best = d;
  }
  return best;
}

// 把一条折线按覆盖率叠进 img（取较大 alpha；color 默认纯白）。w/h 是纹理宽高（可非正方形）。
function strokeInto(img, w, h, pts, strokeW, open, color) {
  const d = img.data;
  const r = color ? color[0] : 255, g = color ? color[1] : 255, b = color ? color[2] : 255;
  const half = strokeW / 2, closed = !open;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const dist = distToPolyline(x + 0.5, y + 0.5, pts, closed);
      let cov = half + 0.5 - dist;
      cov = cov <= 0 ? 0 : (cov >= 1 ? 1 : cov);
      const a = Math.round(cov * 255);
      const i = (y * w + x) * 4;
      if (a > d[i + 3]) { d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = a; }
    }
  }
}

// 用一组 {pts,w,open,color} 画一张 glyph。底衬纯白（alpha=0 处也白，遵守衬底规则）。
function renderGlyph(ctx, w, h, parts) {
  const img = ctx.createImageData(w, h);
  const d = img.data;
  for (let i = 0; i < d.length; i += 4) { d[i] = 255; d[i + 1] = 255; d[i + 2] = 255; d[i + 3] = 0; }
  for (const p of parts) strokeInto(img, w, h, p.pts, p.w, p.open, p.color);
  ctx.putImageData(img, 0, 0);
}

// chevron / arrow：V 形（up/down/left/right 一套几何）。
function glyphChevron(ctx, size, dir) {
  const c = size / 2, w = c * CLOSE_SPAN * 0.92, h = c * CLOSE_SPAN * 0.52;
  let pts;
  if (dir === "up")         pts = [[c - w, c + h], [c, c - h], [c + w, c + h]];
  else if (dir === "down")  pts = [[c - w, c - h], [c, c + h], [c + w, c - h]];
  else if (dir === "left")  pts = [[c + w, c - h], [c - w, c], [c + w, c + h]];
  else                      pts = [[c - w, c - h], [c + w, c], [c - w, c + h]];
  renderGlyph(ctx, size, size, [{ pts, w: CLOSE_STROKE, open: true }]);
}

// 窗口最大化：细方框 + 顶部金色标题栏高光。
function glyphMaximize(ctx, size) {
  const c = size / 2, s = c * CLOSE_SPAN * 0.82;
  const rect = [[c - s, c - s], [c + s, c - s], [c + s, c + s], [c - s, c + s]];
  const ay = c - s + CLOSE_STROKE * 1.7;
  renderGlyph(ctx, size, size, [
    { pts: rect, w: CLOSE_STROKE, open: false },
    { pts: [[c - s + CLOSE_STROKE, ay], [c + s - CLOSE_STROKE, ay]], w: Math.max(2, Math.round(CLOSE_STROKE * 0.6)), open: true, color: [232, 192, 120] },
  ]);
}

// 窗口最小化：一条细横杠。
function glyphMinimize(ctx, size) {
  const c = size / 2, s = c * CLOSE_SPAN * 0.82;
  renderGlyph(ctx, size, size, [{ pts: [[c - s, c], [c + s, c]], w: CLOSE_STROKE, open: true }]);
}

// 关闭 X：44% 字形、3px 笔画、圆头端帽（覆盖率画法，和 chevron/arrow 同口径）。
function glyphClose(ctx, size, color) {
  const c = size / 2, s = c * CLOSE_SPAN;
  renderGlyph(ctx, size, size, [
    { pts: [[c - s, c - s], [c + s, c + s]], w: CLOSE_STROKE, open: true, color },
    { pts: [[c + s, c - s], [c - s, c + s]], w: CLOSE_STROKE, open: true, color },
  ]);
}

// 滚动条细槽：1px 竖线（覆盖率），整条贯穿纹理高度；运行期横向铺满当槽。
function glyphScrollTrack(ctx, w, h) {
  const cx = w / 2;
  renderGlyph(ctx, w, h, [{ pts: [[cx, 0], [cx, h]], w: 1, open: true }]);
}

// 滚动条细把手：3px 竖条（覆盖率）。运行期再按把手宽度收窄/拉伸。
function glyphScrollThumb(ctx, w, h) {
  const cx = w / 2;
  renderGlyph(ctx, w, h, [{ pts: [[cx, 0], [cx, h]], w: 3, open: true }]);
}

// ============================================================
// 批量生成
// ============================================================

// 改由 SVG 绘制的那几张不在这里（源码在 tools/svg/，导出见 tools/svg-to-tga.js）：
//   minimap_rect_mask / monet_close_{normal,hover,push} / monet_map_{tracking,compartment,difficulty}
// 2026-10-28：monet_canvas_weave / diagonal_weave / minus / plus / search / win_restore 全仓无引用，
// 已从下表删除（对应 draw* 函数保留作参考，要恢复把键加回来即可；素材文件与 Media 注册键已一并移除）。
const generators = {
  'monet_barfill':       (ctx, w, h) => drawBarFill(ctx, w, h),
  'monet_barfill_gradient': (ctx, w, h) => drawBarFillGradient(ctx, w, h),
  'monet_barfill_thin':  (ctx, w, h) => drawBarFillThin(ctx, w, h),
  'monet_stripe_weave':  (ctx, w, h) => drawBarStripe(ctx, w),
  'monet_check':         (ctx, w, h) => drawCheck(ctx, w/2, h/2, Math.min(w,h), PALETTE.stencil, 20),
  'monet_corner':        (ctx, w, h) => drawCorner(ctx, w),
  'monet_hairline':      (ctx, w, h) => drawHairline(ctx, w, h),
  'monet_radio':         (ctx, w, h) => drawRadio(ctx, w/2, h/2, Math.min(w,h), 20),
  'monet_role_dps':      (ctx, w, h) => drawRoleDps(ctx, w/2, h/2, Math.min(w,h)),
  'monet_role_heal':     (ctx, w, h) => drawRoleHeal(ctx, w/2, h/2, Math.min(w,h)),
  'monet_role_tank':     (ctx, w, h) => drawRoleTank(ctx, w/2, h/2, Math.min(w,h)),
  'monet_scrollbar_track': (ctx, w, h) => glyphScrollTrack(ctx, w, h),
  'monet_scrollbar_thumb': (ctx, w, h) => glyphScrollThumb(ctx, w, h),
};
// 以下 glyph 改由 tools/import-glyphgen.js 从 ../glyphgen 导入（覆盖率+像素对齐）：
//   monet_chevron_up/down、monet_arrow_left/right、monet_close_normal/hover/push、
//   monet_win_maximize/minimize。它们**不在**本生成器里 —— 跑了 regen 也不会覆盖导入的像素。

// 尺寸定义（2 的幂次方）
const SIZES = {
  'monet_barfill':       { w: 16, h: 16 },
  'monet_barfill_gradient': { w: 64, h: 64 },
  'monet_barfill_thin':  { w: 64, h: 64 },
  'monet_brush_stroke':  { w: 256, h: 16 },   // GIMP 画的，不在本生成器里出
  'monet_stripe_weave':  { w: 64, h: 64 },
  'monet_corner':        { w: 16, h: 16 },
  'monet_hairline':      { w: 256, h: 1 },
  'monet_scrollbar_track': { w: 8, h: 64 },
  'monet_scrollbar_thumb': { w: 8, h: 64 },
};

// 默认尺寸：图标类 64x64
for (const key of Object.keys(generators)) {
  if (!SIZES[key]) SIZES[key] = { w: 64, h: 64 };
}

// 用法：
//   node tools/regen-textures.js                 # 生成全部变体到临时对比目录
//   node tools/regen-textures.js standard        # 只生成某一套到 Assets-src/Textures，并同步出 BLP
//   node tools/regen-textures.js standard --dry  # 只生成到临时目录，不落到 Assets-src
//   node tools/regen-textures.js standard monet_stripe_weave   # 只重出某一张
const argv = process.argv.slice(2);
const only = argv.find(a => VARIANTS[a]);
const onlyTexture = argv.find(a => generators[a]);
const dryRun = !only;

function tgaToBlp(tgaPath) {
  const blpPath = path.join(SHIP_DIR, path.basename(tgaPath).replace(/\.tga$/i, '.blp'));
  require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'tga-to-blp.js'), tgaPath, blpPath], {
    stdio: 'ignore',
  });
  return fs.statSync(blpPath).size;
}

function runVariant(key) {
  const v = applyVariant(key);
  const outDir = only && !dryRun ? OUT_DIR : path.join(VARIANT_DIR, key);
  const results = [];
  for (const [name, drawFn] of Object.entries(generators)) {
    if (onlyTexture && name !== onlyTexture) continue;
    const { w, h } = SIZES[name];
    const canvas = createCanvas(w, h);
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, w, h);
    drawFn(ctx, w, h);
    const info = saveTGA(canvas, path.join(outDir, name + '.tga'));
    if (only && !dryRun) info.blpSize = tgaToBlp(path.join(outDir, name + '.tga'));
    results.push({ name, ...info });
  }
  return { v, outDir, results };
}

console.log('=== MonetUI 纹理批量重生成 ===');
console.log(only
  ? `模式: 单套 —— ${only}（${dryRun ? '临时目录' : '写入 Assets-src/Textures + 同步 BLP 到 Assets/Textures'}）`
  : `模式: 全变体对比 —— ${Object.keys(VARIANTS).join(' / ')} → ${VARIANT_DIR}\n`);

const toRun = only ? [only] : Object.keys(VARIANTS);
const summary = [];

for (const key of toRun) {
  const { v, outDir, results } = runVariant(key);
  console.log(`\n--- [${key}] ${v.label} --- ${v.note}`);
  for (const r of results) console.log('  ' + r.name.padEnd(30) + r.width + 'x' + r.height + '  ' + r.size + 'B');

  // 验证规范合规性
  let allPass = true;
  for (const r of results) {
    const pow2W = (r.width & (r.width - 1)) === 0;
    const pow2H = (r.height & (r.height - 1)) === 0;
    const namingOk = /^[a-z0-9_]+\.tga$/.test(r.name + '.tga');
    if (!pow2W || !pow2H) { console.log('  [FAIL] ' + r.name + ': 非幂次方'); allPass = false; }
    if (!namingOk) { console.log('  [FAIL] ' + r.name + ': 命名不规范'); allPass = false; }
  }
  console.log('  规范: ' + (allPass ? '[PASS] 幂次方尺寸 / 小写下划线命名 / 32bit TGA' : '失败'));
  summary.push({ key, label: v.label, count: results.length, pass: allPass, outDir });
}

console.log('\n=== 汇总 ===');
for (const s of summary) console.log(`  ${s.key.padEnd(10)} ${s.label.padEnd(5)} ${s.count} 张  ${s.pass ? 'PASS' : 'FAIL'}  → ${s.outDir}`);
if (!only) console.log('\n对比表: node tools/make-variant-sheet.js');

