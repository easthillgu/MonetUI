/**
 * 材质审查表生成器
 * 把 Assets/Textures 下所有 TGA 解码，按整数倍最近邻放大铺成一张 contact sheet，
 * 方便逐张目检（1px 线宽、圆弧质量、透明边、字形辨识度）。
 *
 * 输出：
 *   <temp>/review-sheet-dark.png   深色底
 *   <temp>/review-sheet-light.png  浅色底
 *   <temp>/review-sheet-checker.png 棋盘底（看 alpha）
 *
 * 用法：node tools/make-review-sheet.js
 */

const { createCanvas } = require('@napi-rs/canvas');
const os = require('os');
const fs = require('fs');
const path = require('path');

const SRC_DIR = path.join(__dirname, '..', 'Assets-src', 'Textures');
const OUT_DIR = path.join(os.tmpdir(), 'opencode', 'texture-review');

// ---------- TGA 解码 ----------
function decodeTGA(file) {
  const b = fs.readFileSync(file);
  const idLen = b.readUInt8(0);
  const imgType = b.readUInt8(2);
  const w = b.readUInt16LE(12);
  const h = b.readUInt16LE(14);
  const bpp = b.readUInt8(16);
  const desc = b.readUInt8(17);
  const topLeft = (desc & 0x20) !== 0;
  let o = 18 + idLen;
  const px = new Uint8Array(w * h * 4);
  const bytes = bpp / 8;
  for (let i = 0; i < w * h; i++) {
    const bl = b[o], g = b[o + 1], r = b[o + 2], a = bytes === 4 ? b[o + 3] : 255;
    o += bytes;
    const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
    const idx = (row * w + (i % w)) * 4;
    px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
  }
  return { w, h, px, imgType, bpp, desc };
}

// 把解码后的 RGBA 变成一张 imageData（用临时画布自己的 createImageData）
function toImageData(ctx, dec) {
  const id = ctx.createImageData(dec.w, dec.h);
  id.data.set(dec.px);
  return id;
}

// ---------- 布局 ----------
const BOX = 150;          // 纹理显示框
const CELL_W = 190;
const CELL_H = 210;
const COLS = 6;
const PAD = 14;

const files = fs.readdirSync(SRC_DIR).filter(f => f.endsWith('.tga')).sort();
const rows = Math.ceil(files.length / COLS);
const sheetW = PAD + COLS * CELL_W + PAD;
const sheetH = PAD + 46 + rows * CELL_H + PAD;

function drawCheckerboard(ctx, x, y, w, h, a = 12, b = 24) {
  const s = 10;
  for (let yy = 0; yy < h; yy += s) {
    for (let xx = 0; xx < w; xx += s) {
      ctx.fillStyle = (((xx / s) + (yy / s)) | 0) % 2 === 0 ? `rgb(${a},${a},${a})` : `rgb(${b},${b},${b})`;
      ctx.fillRect(x + xx, y + yy, Math.min(s, w - xx), Math.min(s, h - yy));
    }
  }
}

function buildSheet(mode) {
  const canvas = createCanvas(sheetW, sheetH);
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = false;

  // 背景
  if (mode === 'dark') { ctx.fillStyle = '#141414'; ctx.fillRect(0, 0, sheetW, sheetH); }
  else if (mode === 'light') { ctx.fillStyle = '#e6e6e6'; ctx.fillRect(0, 0, sheetW, sheetH); }
  else { ctx.fillStyle = '#0d0d0d'; ctx.fillRect(0, 0, sheetW, sheetH); }

  // 标题
  ctx.fillStyle = mode === 'light' ? '#222' : '#ddd';
  ctx.font = 'bold 22px sans-serif';
  ctx.textAlign = 'left';
  ctx.fillText(`MonetUI texture review — ${mode}`, PAD, PAD + 26);

  files.forEach((f, i) => {
    const col = i % COLS;
    const row = (i / COLS) | 0;
    const cx = PAD + col * CELL_W;
    const cy = PAD + 46 + row * CELL_H;

    const dec = decodeTGA(path.join(SRC_DIR, f));

    // 显示框底色
    if (mode === 'checker') drawCheckerboard(ctx, cx, cy, BOX, BOX);
    else {
      ctx.fillStyle = mode === 'dark' ? '#000000' : '#ffffff';
      ctx.fillRect(cx, cy, BOX, BOX);
    }
    ctx.strokeStyle = mode === 'light' ? '#bbb' : '#333';
    ctx.lineWidth = 1;
    ctx.strokeRect(cx + 0.5, cy + 0.5, BOX - 1, BOX - 1);

    // 缩放：小图整数倍放大，大图缩小到框内
    const maxDim = Math.max(dec.w, dec.h);
    let scale;
    if (maxDim <= BOX) scale = Math.floor(BOX / maxDim);      // 整数倍
    else scale = BOX / maxDim;                                 // 缩小
    const dw = Math.round(dec.w * scale);
    const dh = Math.round(dec.h * scale);
    const dx = cx + (BOX - dw) / 2;
    const dy = cy + (BOX - dh) / 2;

    // 用临时画布做最近邻放大
    const tmp = createCanvas(dec.w, dec.h);
    const tctx = tmp.getContext('2d');
    tctx.putImageData(toImageData(tctx, dec), 0, 0);
    ctx.drawImage(tmp, dx, dy, dw, dh);

    // 标签
    ctx.fillStyle = mode === 'light' ? '#222' : '#cfcfcf';
    ctx.font = 'bold 13px monospace';
    ctx.textAlign = 'left';
    const name = f.replace('.tga', '');
    ctx.fillText(name.length > 24 ? name.slice(0, 23) + '…' : name, cx, cy + BOX + 18);
    ctx.fillStyle = mode === 'light' ? '#666' : '#8a8a8a';
    ctx.font = '12px monospace';
    ctx.fillText(`${dec.w}x${dec.h}  x${scale >= 1 ? scale : scale.toFixed(2)}`, cx, cy + BOX + 34);
  });

  return canvas;
}

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
for (const mode of ['dark', 'light', 'checker']) {
  const canvas = buildSheet(mode);
  const out = path.join(OUT_DIR, `review-sheet-${mode}.png`);
  fs.writeFileSync(out, canvas.toBuffer('image/png'));
  console.log('written: ' + out);
}
