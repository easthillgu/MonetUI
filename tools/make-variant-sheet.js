/**
 * 三套变体的并排对比表
 * 读 texture-variants/<变体>/ 下各套 TGA，逐张比字节：
 *   · 完全相同的纹理折叠成一行"三套一致"，不占版面
 *   · 有差异的纹理整行展示：上半是放大看清造型，下半是按真实显示尺寸（18px）缩一次再
 *     最近邻放大 —— 小图标能不能认出来是在这个尺寸上决定的，只看放大图看不出来
 *
 * 用法：node tools/make-variant-sheet.js
 */

const { createCanvas } = require('@napi-rs/canvas');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = 'C:/Users/EastHillGu/AppData/Local/Temp/opencode/texture-variants';
const OUT_DIR = 'C:/Users/EastHillGu/AppData/Local/Temp/opencode/texture-review';

// 变体顺序与中文名（与 tools/regen-textures.js 的 VARIANTS 保持一致）
const VARIANTS = [
  ['standard', '标准'],
  ['crisp', '锐利'],
  ['heavy', '浓重'],
  ['bold', '厚重'],
  ['fine', '精细'],
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

const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');

// ---- 收集 ----
const names = fs.readdirSync(path.join(ROOT, VARIANTS[0][0])).filter(f => f.endsWith('.tga')).sort();
const rows = [];
for (const f of names) {
  const cells = VARIANTS.map(([k]) => path.join(ROOT, k, f));
  const bufs = cells.map(p => fs.readFileSync(p));
  const hashes = bufs.map(md5);
  const same = hashes.every(h => h === hashes[0]);
  rows.push({ name: f.replace('.tga', ''), same, decs: bufs.map((_, i) => decodeTGA(cells[i])) });
}
const diff = rows.filter(r => !r.same);
const sameRows = rows.filter(r => r.same);

// ---- 版面 ----
const NAME_W = 190;
const CELL = 132;
const PAD = 12;
const HEADER = 76;
const BIG_H = CELL;
const SMALL = 18, SMALL_ZOOM = 5;
const SMALL_H = SMALL * SMALL_ZOOM;
const ROW_H = BIG_H + SMALL_H + 42;
const PER_PAGE = 7;                 // 一页几行 —— 20 行一整张缩略后看不清
const W = PAD * 2 + NAME_W + VARIANTS.length * CELL;

const pages = [];
for (let i = 0; i < Math.max(1, Math.ceil(diff.length / PER_PAGE)); i++) {
  pages.push(diff.slice(i * PER_PAGE, (i + 1) * PER_PAGE));
}

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });

pages.forEach((pageRows, pi) => {
  const isLast = pi === pages.length - 1;
  const H = HEADER + pageRows.length * ROW_H + PAD + (isLast ? 50 : 0);
  const canvas = createCanvas(W, H);
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = '#141414';
  ctx.fillRect(0, 0, W, H);

  ctx.fillStyle = '#e8e8e8';
  ctx.font = 'bold 22px sans-serif';
  ctx.textAlign = 'left';
  ctx.fillText(`MonetUI 材质三套变体 — 并排对比  (${pi + 1}/${pages.length})`, PAD, PAD + 26);
  ctx.font = '13px sans-serif';
  ctx.fillStyle = '#8f8f8f';
  ctx.fillText(`${rows.length} 张纹理：${diff.length} 张有差异，${sameRows.length} 张三套完全一致（字节相同）`, PAD, PAD + 50);

  VARIANTS.forEach((pair, i) => {
    const x = PAD + NAME_W + i * CELL + CELL / 2;
    ctx.textAlign = 'center';
    ctx.fillStyle = '#e8c9a0';
    ctx.font = 'bold 16px sans-serif';
    ctx.fillText(pair[1], x, HEADER - 10);
  });
  ctx.textAlign = 'left';

  pageRows.forEach((row, ri) => {
    const y = HEADER + ri * ROW_H;
    const d0 = row.decs[0];

    ctx.fillStyle = '#9a9a9a';
    ctx.font = '13px monospace';
    ctx.fillText(row.name.length > 25 ? row.name.slice(0, 24) + '…' : row.name, PAD, y + 18);
    ctx.fillStyle = '#5f5f5f';
    ctx.font = '11px monospace';
    ctx.fillText(`${d0.w}x${d0.h}`, PAD, y + 34);

    row.decs.forEach((dec, ci) => {
      const cx0 = PAD + NAME_W + ci * CELL;
      const src = asCanvas(dec);
      const maxDim = Math.max(dec.w, dec.h);
      const scale = maxDim <= CELL ? Math.floor(CELL / maxDim) : CELL / maxDim;
      const dw = Math.round(dec.w * scale), dh = Math.round(dec.h * scale);

      ctx.fillStyle = '#000';
      ctx.fillRect(cx0, y, CELL, BIG_H);
      ctx.strokeStyle = '#2e2e2e';
      ctx.strokeRect(cx0 + 0.5, y + 0.5, CELL - 1, BIG_H - 1);
      ctx.drawImage(src, cx0 + (CELL - dw) / 2, y + (BIG_H - dh) / 2, dw, dh);

      const sy = y + BIG_H + 14;
      ctx.fillStyle = '#000';
      ctx.fillRect(cx0, sy, CELL, SMALL_H);
      ctx.strokeStyle = '#2e2e2e';
      ctx.strokeRect(cx0 + 0.5, sy + 0.5, CELL - 1, SMALL_H - 1);
      const scaleS = Math.min(SMALL / dec.w, SMALL / dec.h);
      const sw = Math.max(1, Math.round(dec.w * scaleS)), sh = Math.max(1, Math.round(dec.h * scaleS));
      const tmp = createCanvas(sw, sh);
      const tctx = tmp.getContext('2d');
      tctx.imageSmoothingEnabled = true;              // 模拟客户端的线性重采样
      tctx.drawImage(src, 0, 0, sw, sh);
      const zx = Math.round((CELL - sw * SMALL_ZOOM) / 2), zy = Math.round((SMALL_H - sh * SMALL_ZOOM) / 2);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(tmp, cx0 + zx, sy + zy, sw * SMALL_ZOOM, sh * SMALL_ZOOM);

      ctx.fillStyle = '#5f5f5f';
      ctx.font = '10px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`x${scale >= 1 ? scale : scale.toFixed(2)}`, cx0 + CELL / 2, sy + SMALL_H + 12);
      ctx.fillText(`${sw}px 实显`, cx0 + CELL / 2, sy + SMALL_H + 23);
      ctx.textAlign = 'left';
    });

    ctx.strokeStyle = '#242424';
    ctx.beginPath();
    ctx.moveTo(PAD, y + ROW_H - 12);
    ctx.lineTo(W - PAD, y + ROW_H - 12);
    ctx.stroke();
  });

  if (isLast) {
    const sy = HEADER + pageRows.length * ROW_H;
    ctx.fillStyle = '#7f7f7f';
    ctx.font = 'bold 13px sans-serif';
    ctx.fillText(`三套完全一致（${sameRows.length} 张，字节相同）:`, PAD, sy + 14);
    ctx.font = '12px monospace';
    ctx.fillStyle = '#606060';
    ctx.fillText(sameRows.map(r => r.name).join('  '), PAD, sy + 32);
  }

  const out = path.join(OUT_DIR, `variant-sheet-${pi + 1}.png`);
  fs.writeFileSync(out, canvas.toBuffer('image/png'));
  console.log('written: ' + out);
});

console.log(`\n差异 ${diff.length} 张: ${diff.map(r => r.name).join(', ')}`);
console.log(`一致 ${sameRows.length} 张: ${sameRows.map(r => r.name).join(', ')}`);