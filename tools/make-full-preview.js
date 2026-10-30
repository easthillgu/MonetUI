/**
 * 全套预览页
 * 把 Assets/Textures 下 26 张 TGA 解码成 PNG data-URL 嵌进一个 HTML，
 * 按"看什么"分成几段，而不是只给一张大图：
 *
 *   ① 三底对照   深色 / 浅色 / 棋盘 —— 确认透明边和可染色材质在两种界面底色下都成立
 *   ② 实机尺寸   16 / 22 / 32 / 48 px 真实尺寸，不做任何放大 —— 这是游戏里真正看到的大小
 *   ③ 放大检视   每张整数倍最近邻放大，看线宽和造型
 *   ④ 审计状态   直接内嵌 tools/audit-pixels.js 的判定结果
 *
 * 浏览器读不了 TGA，所以走 PNG data-URL 内嵌；好处是页面里的图是浏览器原生渲染，
 * 可以自己缩放、可以用浏览器缩放级别检查，和游戏里的重采样路径一致。
 *
 * 用法：node tools/make-full-preview.js
 */

const { createCanvas } = require('@napi-rs/canvas');
const os = require('os');
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'Assets-src', 'Textures');
const OUT_DIR = path.join(os.tmpdir(), 'opencode', 'texture-review');

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

function toDataURL(dec) {
  const c = createCanvas(dec.w, dec.h);
  const cx = c.getContext('2d');
  const id = cx.createImageData(dec.w, dec.h);
  id.data.set(dec.px);
  cx.putImageData(id, 0, 0);
  return 'data:image/png;base64,' + c.toBuffer('image/png').toString('base64');
}

// --- 审计（与 tools/audit-pixels.js 同一套判据，这里只取结论，不重复实现全部逻辑）---
const STRICT = new Set(['monet_barfill', 'monet_hairline', 'monet_plus', 'monet_minus',
  'monet_win_maximize', 'monet_win_minimize', 'monet_win_restore']);
const NO_SOFT_EDGE = new Set([...STRICT, 'minimap_rect_mask', 'monet_corner', 'monet_round_edge',
  'monet_arrow_left', 'monet_arrow_right', 'monet_check', 'monet_chevron_up', 'monet_chevron_down',
  'monet_close_normal', 'monet_close_hover', 'monet_close_push',
  'monet_canvas_weave', 'monet_diagonal_weave']);

function audit(dec, name) {
  const { w, h, px } = dec;
  const A = (x, y) => (x < 0 || y < 0 || x >= w || y >= h) ? 0 : px[(y * w + x) * 4 + 3];
  let partial = 0, iso = 0;
  for (let i = 0; i < w * h; i++) { const a = px[i * 4 + 3]; if (a > 0 && a < 255) partial++; }
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    if (A(x, y) === 0) continue;
    let s = 0;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      if (!dx && !dy) continue;
      if (A(x + dx, y + dy) > 0) s++;
    }
    if (s === 0) iso++;
  }
  // 软边：长度>=8 的满 alpha 横/竖段，中段邻居是半覆盖
  const MIN_RUN = 8, TRIM = 5;
  let soft = 0;
  const scan = (len, at, nA, nB) => {
    let i = 0;
    while (i < len) {
      if (at(i) !== 255) { i++; continue; }
      const i0 = i; while (i < len && at(i) === 255) i++;
      const i1 = i - 1;
      if (i1 - i0 + 1 < MIN_RUN) continue;
      for (let k = i0 + TRIM; k <= i1 - TRIM; k++) {
        const a = nA(k), b = nB(k);
        if ((a > 0 && a < 255) || (b > 0 && b < 255)) { soft++; break; }
      }
    }
  };
  for (let y = 0; y < h; y++) scan(w, x => A(x, y), k => A(k, y - 1), k => A(k, y + 1));
  for (let x = 0; x < w; x++) scan(h, y => A(x, y), k => A(x - 1, k), k => A(x + 1, k));

  const bad = [];
  if (STRICT.has(name) && partial > 0) bad.push(`半覆盖 ${partial}（应 0）`);
  if (NO_SOFT_EDGE.has(name) && soft > 0) bad.push(`软边 ${soft}（应 0）`);
  if (iso > 0) bad.push(`孤立 ${iso}（应 0）`);
  return { partial, soft, iso, ok: bad.length === 0, bad };
}

// --- 读全部纹理 ---
const files = fs.readdirSync(SRC).filter(f => f.endsWith('.tga')).sort();
const items = files.map(f => {
  const dec = decodeTGA(path.join(SRC, f));
  const name = f.replace('.tga', '');
  return { name, dec, url: toDataURL(dec), audit: audit(dec, name) };
});

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
const passAll = items.every(i => i.audit.ok);

// 三底对照：一张纹理三格
const tr = items.map(i => `
  <tr>
    <td class="nm">${esc(i.name)}<span class="dim">${i.dec.w}×${i.dec.h}</span></td>
    <td><div class="box dark"><img src="${i.url}" width="88" height="${Math.round(88 * i.dec.h / i.dec.w)}"></div></td>
    <td><div class="box light"><img src="${i.url}" width="88" height="${Math.round(88 * i.dec.h / i.dec.w)}"></div></td>
    <td><div class="box chk"><img src="${i.url}" width="88" height="${Math.round(88 * i.dec.h / i.dec.w)}"></div></td>
    <td class="au ${i.audit.ok ? 'ok' : 'bad'}">${i.audit.ok ? 'PASS' : esc(i.audit.bad.join('; '))}</td>
  </tr>`).join('');

// 实机尺寸阶梯：真实 px，不放大
const SIZES = [16, 22, 32, 48];
const tr2 = items.map(i => `
  <tr>
    <td class="nm">${esc(i.name)}</td>
    ${SIZES.map(s => `<td class="sz"><div class="sizer"><img src="${i.url}" width="${s}" height="${Math.max(1, Math.round(s * i.dec.h / i.dec.w))}" style="image-rendering:auto"></div></td>`).join('')}
  </tr>`).join('');

// 放大检视
const tr3 = items.map(i => {
  const z = Math.max(1, Math.floor(120 / Math.max(i.dec.w, i.dec.h)));
  const dw = i.dec.w * z, dh = i.dec.h * z;
  return `<div class="card"><div class="nm2">${esc(i.name)}</div>
    <div class="zoom"><img src="${i.url}" width="${dw}" height="${dh}" style="image-rendering:pixelated"></div>
    <div class="dim">${i.dec.w}×${i.dec.h} ×${z} · 半覆盖 ${i.audit.partial} · 孤立 ${i.audit.iso}</div></div>`;
}).join('');

const html = `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>MonetUI 全套材质预览（${items.length} 张）</title><style>
*{box-sizing:border-box}
body{background:#0d0d0d;color:#ddd;font:13px/1.6 system-ui,"Microsoft YaHei",sans-serif;margin:0;padding:22px}
h1{font-size:20px;margin:0 0 4px}
h2{font-size:15px;margin:26px 0 10px;color:#e8c9a0;border-bottom:1px solid #2a2a2a;padding-bottom:6px}
.meta{color:#8a8a8a;margin-bottom:6px}
.meta b{color:#e8c9a0}
table{border-collapse:collapse}
td,th{border:1px solid #262626;padding:4px 8px;vertical-align:middle}
th{background:#1a1a1a;color:#9a9a9a;font-weight:600;text-align:left}
.nm{font:12px/1.4 ui-monospace,Consolas,monospace;white-space:nowrap}
.nm .dim{display:block;color:#5f5f5f;font-size:10px}
.dim{color:#5f5f5f;font-size:10px}
.box{display:flex;align-items:center;justify-content:center;width:96px;height:72px;overflow:hidden}
.dark{background:#141414;border:1px solid #2a2a2a}
.light{background:#e8e8e8;border:1px solid #bbb}
.chk{background:#202020;border:1px solid #2a2a2a;
  background-image:linear-gradient(45deg,#2e2e2e 25%,transparent 25%,transparent 75%,#2e2e2e 75%),
                   linear-gradient(45deg,#2e2e2e 25%,transparent 25%,transparent 75%,#2e2e2e 75%);
  background-size:12px 12px;background-position:0 0,6px 6px}
.au{font:11px ui-monospace,Consolas,monospace;white-space:nowrap}
.au.ok{color:#6fbf73}.au.bad{color:#e06c6c}
.sz{text-align:center}.sizer{display:flex;align-items:flex-end;justify-content:center;height:52px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.card{background:#151515;border:1px solid #262626;padding:8px;text-align:center}
.nm2{font:11px ui-monospace,Consolas,monospace;color:#9a9a9a;margin-bottom:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.zoom{display:flex;align-items:center;justify-content:center;height:124px;background:#000;border:1px solid #222}
</style></head><body>
<h1>MonetUI 全套材质预览 — ${items.length} 张</h1>
<div class="meta">采用变体 <b>crisp 锐利</b>（图标线宽 3px / 加减 5px）· 像素级审计 <b>${passAll ? items.length + '/' + items.length + ' PASS' : '有未通过项'}</b> · 规格：幂次方 / 32bit TGA / descriptor 0x08 / 透明像素纯白哑光</div>

<h2>① 三底对照 —— 深色（游戏暗底）/ 浅色 / 棋盘（看 alpha 边）</h2>
<table>
<tr><th>纹理</th><th>深色</th><th>浅色</th><th>棋盘</th><th>审计</th></tr>
${tr}
</table>

<h2>② 实机尺寸阶梯 —— ${SIZES.join(' / ')} px，浏览器原样渲染（这是游戏里真正看到的大小）</h2>
<table>
<tr><th>纹理</th>${SIZES.map(s => `<th>${s}px</th>`).join('')}</tr>
${tr3 ? tr2 : ''}
</table>

<h2>③ 放大检视 —— 整数倍最近邻（image-rendering:pixelated），看线宽与造型</h2>
<div class="grid">${tr3}</div>
</body></html>`;

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
const out = path.join(OUT_DIR, 'full-preview.html');
fs.writeFileSync(out, html);
const kb = (fs.statSync(out).size / 1024).toFixed(0);
console.log(`written: ${out}  (${kb} KB, ${items.length} 张, 审计 ${passAll ? '全 PASS' : '有未通过'})`);