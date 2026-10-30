/**
 * tools/import-glyphgen.js
 * 把 ../glyphgen/out 里的 glyph TGA 导入 MonetUI：
 *   * 白模直接复用（glyphgen 已是 type2/32bit/左下原点/白衬底，和项目同格式）；
 *   * close_hover/push 按颜色染色（RGB 乘系数，alpha 不变）；
 *   * win_maximize 在方框顶部叠一条金色标题栏。
 * 输出 Assets-src/Textures/monet_*.tga，并调 tga-to-blp.js 出 BLP。
 *
 * 用法：node tools/import-glyphgen.js
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const GG = path.join(__dirname, '..', '..', 'tools', 'glyphgen', 'out');
const SRC = path.join(ROOT, 'Assets-src', 'Textures');
const SHIP = path.join(ROOT, 'Assets', 'Textures');

// dest -> { src, tint?, bar? }
const MAP = {
  'monet_chevron_up':   { src: 'chevron-up_64.tga' },
  'monet_chevron_down': { src: 'chevron-down_64.tga' },
  'monet_arrow_left':   { src: 'arrow-left_64.tga' },
  'monet_arrow_right':  { src: 'arrow-right_64.tga' },
  'monet_close_normal': { src: 'close_64.tga' },
  'monet_close_hover':  { src: 'close_64.tga', tint: [0.910, 0.753, 0.471] },  // #e8c078 金
  'monet_close_push':   { src: 'close_64.tga', tint: [0.675, 0.675, 0.675] },  // #acacac 灰
  'monet_win_minimize': { src: 'minus_64.tga' },
  'monet_win_maximize': { src: 'square_64.tga', bar: [0.910, 0.753, 0.471] },  // 方框 + 金条
};

// 读 glyphgen TGA（左下原点，32bit）→ top-left RGBA
function readTGA(file) {
  const b = fs.readFileSync(file);
  const idLen = b.readUInt8(0), type = b.readUInt8(2);
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14), bpp = b.readUInt8(16);
  const bytes = bpp / 8;
  let o = 18 + idLen;
  const px = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const bl = b[o], g = b[o + 1], r = b[o + 2], a = bytes === 4 ? b[o + 3] : 255;
    o += bytes;
    const fileRow = (i / w) | 0;        // 文件里第 0 行是图像底部
    const row = h - 1 - fileRow;        // 转成 top-left 行
    const idx = (row * w + (i % w)) * 4;
    px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
  }
  return { w, h, px };
}

// top-left RGBA → 项目格式 TGA（type2/32bit/左下原点/白衬底）
function writeTGA(file, w, h, px) {
  const header = Buffer.alloc(18);
  header[2] = 2;
  header.writeUInt16LE(w, 12);
  header.writeUInt16LE(h, 14);
  header[16] = 32;
  header[17] = 0x08;
  const out = Buffer.alloc(w * h * 4);
  let fixed = 0;
  for (let y = 0; y < h; y++) {
    const src = (h - 1 - y) * w * 4;   // 写回底部优先
    for (let x = 0; x < w; x++) {
      const s = src + x * 4, d = (y * w + x) * 4;
      let r = px[s], g = px[s + 1], b = px[s + 2], a = px[s + 3];
      if (a === 0 && !(r === 255 && g === 255 && b === 255)) { r = g = b = 255; fixed++; }
      out[d] = b; out[d + 1] = g; out[d + 2] = r; out[d + 3] = a;
    }
  }
  fs.writeFileSync(file, Buffer.concat([header, out]));
  return fixed;
}

// 方框顶部叠一条金色标题栏
function addTitleBar(px, w, h, color) {  let minX = w, maxX = -1, minY = h, maxY = -1;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    if (px[(y * w + x) * 4 + 3] > 0) {
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return;
  const barY = Math.round(minY + (maxY - minY) * 0.22);
  const x0 = minX + 2, x1 = maxX - 2, thick = Math.max(2, Math.round((maxY - minY) * 0.10));
  for (let y = barY; y < barY + thick; y++) {
    if (y < 0 || y >= h) continue;
    for (let x = x0; x <= x1; x++) {
      if (x < 0 || x >= w) continue;
      const i = (y * w + x) * 4;
      px[i] = Math.round(255 * color[0]);
      px[i + 1] = Math.round(255 * color[1]);
      px[i + 2] = Math.round(255 * color[2]);
      px[i + 3] = 255;
    }
  }
}

// 只硬化**轴对齐直边**：算每个像素的水平/垂直满 alpha 连续长度；把"紧邻长直段(≥8)"
// 的半透明像素二值化（≥128→255，否则→0）。斜线/曲线没有长横/竖段，不受影响。
// 目的：glyphgen 的覆盖率 AA 会在横/竖边留半透明边（audit 判"软边直边"），这里补齐。
function hardenAxisEdges(px, w, h) {
  const A = (x, y) => (x < 0 || y < 0 || x >= w || y >= h) ? 0 : px[(y * w + x) * 4 + 3];
  const hrun = new Int32Array(w * h), vrun = new Int32Array(w * h);
  for (let y = 0; y < h; y++) {
    let x = 0;
    while (x < w) {
      if (A(x, y) === 255) { const x0 = x; while (x < w && A(x, y) === 255) x++; const len = x - x0; for (let k = x0; k < x; k++) hrun[y * w + k] = len; }
      else x++;
    }
  }
  for (let x = 0; x < w; x++) {
    let y = 0;
    while (y < h) {
      if (A(x, y) === 255) { const y0 = y; while (y < h && A(x, y) === 255) y++; const len = y - y0; for (let k = y0; k < y; k++) vrun[k * w + x] = len; }
      else y++;
    }
  }
  const MIN = 8;
  const out = new Uint8Array(px.length); out.set(px);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4, a = px[i + 3];
      if (a === 0 || a === 255) continue;
      const snap =
        (A(x, y - 1) === 255 && hrun[(y - 1) * w + x] >= MIN) ||
        (A(x, y + 1) === 255 && hrun[(y + 1) * w + x] >= MIN) ||
        (A(x - 1, y) === 255 && vrun[y * w + (x - 1)] >= MIN) ||
        (A(x + 1, y) === 255 && vrun[y * w + (x + 1)] >= MIN);
      if (snap) out[i + 3] = a >= 128 ? 255 : 0;
    }
  }
  return out;
}

for (const [dest, cfg] of Object.entries(MAP)) {
  const srcPath = path.join(GG, cfg.src);
  if (!fs.existsSync(srcPath)) { console.log(`  [SKIP] ${dest}: 缺 ${cfg.src}`); continue; }
  const { w, h, px } = readTGA(srcPath);
  if (cfg.tint) {
    for (let i = 0; i < px.length; i += 4) {
      if (px[i + 3] > 0) {
        px[i] = Math.round(px[i] * cfg.tint[0]);
        px[i + 1] = Math.round(px[i + 1] * cfg.tint[1]);
        px[i + 2] = Math.round(px[i + 2] * cfg.tint[2]);
      }
    }
  }
  if (cfg.bar) addTitleBar(px, w, h, cfg.bar);
  const hardened = hardenAxisEdges(px, w, h);
  const out = path.join(SRC, dest + '.tga');
  const fixed = writeTGA(out, w, h, hardened);
  const blp = path.join(SHIP, dest + '.blp');
  execFileSync(process.execPath, [path.join(__dirname, 'tga-to-blp.js'), out, blp], { stdio: 'ignore' });
  console.log(`  ${dest}  <= ${cfg.src}  (${w}x${h}, 补白 ${fixed}, BLP ${fs.statSync(blp).size}B)`);
}
console.log('done');
