/**
 * TGA 像素转储器（开发自检用）
 * 把 Assets/Textures 下（或备份目录）的 TGA 解码成 ASCII 图，直接看线宽/alpha/边缘质量。
 *
 * 用法：
 *   node tools/tga-dump.js <名字> [宽|高]        # 默认 Assets/Textures
 *   node tools/tga-dump.js <名字> --bak          # 读 Assets/Textures.bak
 *   node tools/tga-dump.js <名字> --rgb          # 看 RGB（不带 alpha 遮罩）
 *
 * 图例：. =0    : <=100    + <=200    o <=254    # =255
 */

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const name = args[0];
if (!name) { console.error('用法: node tools/tga-dump.js <名字> [--bak] [--rgb] [最大行数]'); process.exit(1); }
const useBak = args.includes('--bak');
const showRgb = args.includes('--rgb');
const maxRows = parseInt(args.find(a => /^\d+$/.test(a)) || '0', 10);

const dir = useBak ? path.join(__dirname, '..', 'Assets', 'Textures.bak')
                   : path.join(__dirname, '..', 'Assets', 'Textures');
const file = path.join(dir, name.endsWith('.tga') ? name : name + '.tga');
if (!fs.existsSync(file)) { console.error('找不到: ' + file); process.exit(1); }

const b = fs.readFileSync(file);
const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
const bpp = b.readUInt8(16), desc = b.readUInt8(17);
const topLeft = (desc & 0x20) !== 0;
const px = new Uint8Array(w * h * 4);
let o = 18;
const bytes = bpp / 8;
for (let i = 0; i < w * h; i++) {
  const bl = b[o++], g = b[o++], r = b[o++];
  const a = bytes === 4 ? b[o++] : 255;
  const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
  const idx = (row * w + (i % w)) * 4;
  px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
}

const ch = (v) => v === 0 ? '.' : v === 255 ? '#' : v > 200 ? 'o' : v > 100 ? '+' : ':';

// 自适应图例：织物质感这类整幅都很淡的材质，用固定阈值会全画成 ':'，看不出结构。
// 所以按本图实际的 alpha 峰值重算分级。
let peak = 0;
for (let i = 0; i < w * h; i++) peak = Math.max(peak, px[i * 4 + 3]);
const faint = peak <= 120;
const chA = faint
  ? (v) => v === 0 ? '.' : v >= peak * 0.92 ? '#' : v >= peak * 0.6 ? 'o' : v >= peak * 0.28 ? '+' : ':'
  : ch;

const rows = maxRows > 0 ? Math.min(maxRows, h) : h;

console.log(`${file}`);
console.log(`${w}x${h}  bpp=${bpp} descriptor=0x${desc.toString(16).padStart(2, '0')} (${topLeft ? 'TOP-LEFT' : 'BOTTOM-LEFT'} origin)  alpha峰值=${peak}${faint ? '（淡色图，图例已按峰值缩放）' : ''}`);
console.log(showRgb ? '--- RGB 亮度（alpha>0 的像素） ---' : '--- alpha ---');
console.log('    ' + Array.from({ length: Math.min(w, 64) }, (_, i) => String(i % 10)).join(''));

for (let y = 0; y < rows; y++) {
  let s = String(y).padStart(3) + ' ';
  for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4;
    if (showRgb) s += px[i + 3] === 0 ? ' ' : ch(Math.round(px[i] * 0.299 + px[i + 1] * 0.587 + px[i + 2] * 0.114));
    else s += chA(px[i + 3]);
  }
  console.log(s);
}

// 统计
let opaque = 0, partial = 0, transparent = 0;
for (let i = 0; i < w * h; i++) {
  const a = px[i * 4 + 3];
  if (a === 0) transparent++; else if (a === 255) opaque++; else partial++;
}
console.log(`\nalpha 统计: 全不透明 ${opaque} / 半透明 ${partial} / 全透明 ${transparent}`);

// --cross：沿中线切一刀，看颜色剖面（材质被非等比拉伸时，剖面比整图更能说明问题）
if (args.includes('--cross')) {
  const midY = h >> 1, midX = w >> 1;
  const rgba = (i) => `rgba(${String(px[i]).padStart(3)},${String(px[i+1]).padStart(3)},${String(px[i+2]).padStart(3)},${String(px[i+3]).padStart(3)})`;
  console.log(`\n--- 竖向剖面 (x=${midX}, ${h} 行) ---`);
  for (let y = 0; y < h; y++) console.log(`  y=${String(y).padStart(3)}  ${rgba((y * w + midX) * 4)}`);
  console.log(`\n--- 横向剖面 (y=${midY}, ${w} 列, 每 8 列) ---`);
  for (let x = 0; x < w; x += 8) console.log(`  x=${String(x).padStart(3)}  ${rgba((midY * w + x) * 4)}`);
}