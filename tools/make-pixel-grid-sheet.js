/**
 * 像素网格检视表
 * 把关键纹理按整数倍最近邻放大，并在每个源像素边界上画一条细网格线。
 * 边落在像素边界上时，网格线两侧是纯白/纯黑，一眼就能看出来；
 * 边跑出边界时，两侧会出现灰阶，那正是"发虚"。
 *
 * 用法：node tools/make-pixel-grid-sheet.js [目录]
 */

const { createCanvas } = require('@napi-rs/canvas');
const os = require('os');
const fs = require('fs');
const path = require('path');

const SRC = process.argv[2] || path.join(__dirname, '..', 'Assets-src', 'Textures');
const OUT_DIR = path.join(os.tmpdir(), 'opencode', 'texture-review');

// 只看"本该整像素对齐"的那些：矩形、直线、直边
const TARGETS = [
  'monet_plus', 'monet_minus',
  'monet_win_maximize', 'monet_win_minimize', 'monet_win_restore',
  'monet_arrow_left', 'monet_arrow_right',
  'monet_corner', 'monet_hairline',
  'monet_role_dps', 'monet_barfill',
];

function decodeTGA(file) {
  const b = fs.readFileSync(file);
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
  const topLeft = (b.readUInt8(17) & 0x20) !== 0;
  let o = 18;
  const px = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
    const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
    const idx = (row * w + (i % w)) * 4;
    px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
  }
  return { w, h, px };
}

function asCanvas(dec) {
  const c = createCanvas(dec.w, dec.h);
  const cx = c.getContext('2d');
  const id = cx.createImageData(dec.w, dec.h);
  id.data.set(dec.px);
  cx.putImageData(id, 0, 0);
  return c;
}

const ZOOM = 7;                 // 每个源像素放大到多少屏幕像素
const CELL = 64 * ZOOM;         // 格子边长（按 64px 纹理算）
const NAME_W = 0, PAD = 12, HEADER = 104;
const COLS = 3;

const rows = TARGETS.filter(n => fs.existsSync(path.join(SRC, n + '.tga')));
const nRows = Math.ceil(rows.length / COLS);
const W = PAD * 2 + COLS * (CELL + 20);
const ROW_H = CELL + 46;
const H = HEADER + nRows * ROW_H + PAD;

const canvas = createCanvas(W, H);
const ctx = canvas.getContext('2d');
ctx.fillStyle = '#101010';
ctx.fillRect(0, 0, W, H);

ctx.fillStyle = '#e8e8e8';
ctx.font = 'bold 22px sans-serif';
ctx.textAlign = 'left';
ctx.fillText('像素网格检视 — 网格线 = 源像素边界', PAD, PAD + 26);
ctx.font = '13px sans-serif';
ctx.fillStyle = '#8f8f8f';
ctx.fillText('边压在网格线上 → 两侧纯白/纯黑，像素级干净；边跑偏 → 出现灰阶毛边。最多放大 ' + ZOOM + ' 倍。', PAD, PAD + 50);
ctx.fillStyle = '#c8a06a';
ctx.font = '13px sans-serif';
ctx.fillText('底色是暖白 (252,252,252)，透明区是纯白哑光 —— 灰阶只可能来自抗锯齿，不来自底色', PAD, PAD + 68);

rows.forEach((name, i) => {
  const col = i % COLS, row = (i / COLS) | 0;
  const x = PAD + col * (CELL + 20);
  const y = HEADER + row * ROW_H;
  const dec = decodeTGA(path.join(SRC, name + '.tga'));
  const src = asCanvas(dec);

  // 每张按自己的尺寸取整数倍缩放，保证不溢出格子
  const z = Math.max(1, Math.min(ZOOM, Math.floor(CELL / Math.max(dec.w, dec.h))));
  const dw = dec.w * z, dh = dec.h * z;

  ctx.fillStyle = '#9a9a9a';
  ctx.font = 'bold 13px monospace';
  ctx.fillText(name, x, y - 6);

  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = '#000';
  ctx.fillRect(x, y, CELL, CELL);
  ctx.drawImage(src, x, y, dw, dh);

  // 像素网格：只画内部边界，避免盖住最外圈
  ctx.strokeStyle = 'rgba(200,60,60,0.34)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let gx = 1; gx < dec.w; gx++) {
    const gxp = x + gx * z + 0.5;
    ctx.moveTo(gxp, y);
    ctx.lineTo(gxp, y + dh);
  }
  for (let gy = 1; gy < dec.h; gy++) {
    const gyp = y + gy * z + 0.5;
    ctx.moveTo(x, gyp);
    ctx.lineTo(x + dw, gyp);
  }
  ctx.stroke();

  ctx.strokeStyle = '#3a3a3a';
  ctx.strokeRect(x + 0.5, y + 0.5, CELL - 1, CELL - 1);

  ctx.fillStyle = '#5f5f5f';
  ctx.font = '11px monospace';
  ctx.fillText(`${dec.w}x${dec.h}  x${z}`, x, y + CELL + 16);
});

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
const out = path.join(OUT_DIR, 'pixel-grid-sheet.png');
fs.writeFileSync(out, canvas.toBuffer('image/png'));
console.log('written: ' + out);