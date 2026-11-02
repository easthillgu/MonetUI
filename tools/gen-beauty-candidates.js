/**
 * tools/gen-beauty-candidates.js —— A3/A4/A5 真像素候选对照页（视觉验收门）
 *
 * 只生成像素用于验收，**不落地 Assets/**：选中之后才走 tga → blp + audit-pixels。
 * 颜色取 Utils/Color.lua 的 FALLBACK 与 SURFACE_STEPS 口径；L* 阶梯在这张图上只做
 * "亮度定位 + 色相轻染"的近似（实机颜色由 LibMonetColor 给），页面里逐处标注。
 *
 * 用法：
 *   node tools/gen-beauty-candidates.js
 *   node tools/gen-beauty-candidates.js --vizOut <path>   # 再写一份会话内片段
 */

const fs = require('fs');
const path = require('path');
const { createCanvas } = require('@napi-rs/canvas');

const ROOT = path.join(__dirname, '..');

/* ───────────────────────── 颜色底座 ───────────────────────── */

const FALLBACK = {
  edge: [0.85, 0.66, 0.36],
  ambient: [0.24, 0.26, 0.36],
  highlight: [0.95, 0.93, 0.84],
  neutral: [0.62, 0.60, 0.57],
  danger: [0.90, 0.20, 0.20],
};
// §3：bright = neutral 往白推 62%（Widget:PaletteColor 同口径）
const brightOf = c => c.map(v => v + (1 - v) * 0.62);

const srgbLin = c => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const srgbEnc = y => (y <= 0.0031308 ? 12.92 * y : 1.055 * Math.pow(y, 1 / 2.4) - 0.055);
const lumOf = c => 0.2126 * srgbLin(c[0]) + 0.7152 * srgbLin(c[1]) + 0.0722 * srgbLin(c[2]);
const clamp01 = v => (v < 0 ? 0 : v > 1 ? 1 : v);
const contrast = (a, b) => {
  const l1 = lumOf(a), l2 = lumOf(b);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
};
const css = (c, a) => `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a == null ? 1 : a})`;

// CIE L* → Y（只搬亮度，色相轻染；实机由 LMC.AtLightness 给）
const lstarToY = L => (L <= 8 ? L / 90.329 : Math.pow((L + 16) / 116, 3));
function surface(key) {
  const L = { panel: 10, lost: 28, weave: 40, fill: 46 }[key];
  // fill 不在 SURFACE_HUE 里 = edge 反相（先反相再定位）
  const src = key === 'fill' ? FALLBACK.edge.map(v => 1 - v)
    : { panel: FALLBACK.ambient, lost: FALLBACK.neutral, weave: FALLBACK.neutral }[key];
  const g = srgbEnc(lstarToY(L));
  const m = (src[0] + src[1] + src[2]) / 3;
  return src.map(v => clamp01(g * (1 + 0.25 * ((v - m) / (m || 1)))));
}
const SURF = { panel: surface('panel'), lost: surface('lost'), weave: surface('weave'), fill: surface('fill') };

/* ───────────────────────── 画布小工具 ───────────────────────── */

function newC(w, h) { const c = createCanvas(Math.round(w), Math.round(h)); return [c, c.getContext('2d')]; }
function zoom(src, sx, sy, sw, sh, k) {
  const [c, x] = newC(sw * k, sh * k);
  x.imageSmoothingEnabled = false;
  x.drawImage(src, sx, sy, sw, sh, 0, 0, sw * k, sh * k);
  return c;
}
function uri(c) { return c.toBuffer('image/png').toString('base64'); }
function px(c) { return c.getContext('2d').getImageData(0, 0, c.width, c.height).data; }

/* 一区"世界"底：水面 + 睡莲 + 远山（只为给对照图一个有起伏的背景，非交付资源） */
function worldScene(W, H) {
  const [c, x] = newC(W, H);
  const sky = x.createLinearGradient(0, 0, 0, H * 0.42);
  sky.addColorStop(0, '#5d6b7d'); sky.addColorStop(1, '#8c8b7a');
  x.fillStyle = sky; x.fillRect(0, 0, W, H * 0.42);
  const water = x.createLinearGradient(0, H * 0.42, 0, H);
  water.addColorStop(0, '#3f5560'); water.addColorStop(1, '#1d2c34');
  x.fillStyle = water; x.fillRect(0, H * 0.42, W, H * 0.58);
  let s = 0x2f3a1b;
  const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
  x.fillStyle = '#6f7a4e';                                     // 远岸
  x.beginPath(); x.moveTo(0, H * 0.42);
  for (let i = 0; i <= 12; i++) x.lineTo(i * W / 12, H * (0.40 - 0.05 * Math.abs(Math.sin(i * 1.7))));
  x.lineTo(W, H * 0.42); x.closePath(); x.fill();
  for (let i = 0; i < 46; i++) {                                // 睡莲
    const cx = rnd() * W, cy = H * (0.46 + rnd() * 0.5), r = (0.012 + rnd() * 0.03) * W;
    x.fillStyle = rnd() > 0.86 ? 'rgba(226,214,196,0.85)' : `rgba(${70 + rnd() * 40 | 0},${96 + rnd() * 40 | 0},${58 + rnd() * 30 | 0},0.8)`;
    x.beginPath(); x.ellipse(cx, cy, r * 1.5, r * 0.6, 0, 0, Math.PI * 2); x.fill();
  }
  for (let i = 0; i < 70; i++) {                                // 水面笔触
    const y = H * (0.44 + rnd() * 0.55), w = (0.03 + rnd() * 0.12) * W, x0 = rnd() * W;
    x.strokeStyle = `rgba(${150 + rnd() * 70 | 0},${160 + rnd() * 60 | 0},${150 + rnd() * 50 | 0},${0.05 + rnd() * 0.12})`;
    x.lineWidth = 1 + rnd() * 2; x.beginPath(); x.moveTo(x0, y); x.lineTo(x0 + w, y); x.stroke();
  }
  return c;
}

/* 一块 MonetUI 面板：1px 边 + 半透明底 + 一条发丝线 + 标题/正文（可选再压一层 overlay） */
function panel(W, H, o) {
  o = o || {};
  const [c, x] = newC(W, H);
  if (o.overWorld) { x.drawImage(o.overWorld, 0, 0, o.srcW || W, o.srcH || H); }
  else { x.clearRect(0, 0, W, H); }
  x.fillStyle = css(o.bgColor || SURF.panel, o.bgAlpha == null ? 0.96 : o.bgAlpha);
  x.fillRect(0, 0, W, H);
  x.strokeStyle = css(o.edgeColor || FALLBACK.edge, 0.95); x.lineWidth = 1;
  x.strokeRect(0.5, 0.5, W - 1, H - 1);
  if (o.hairline) {                                              // §5 发丝线：edge @0.55
    x.fillStyle = css(o.ruleColor || FALLBACK.edge, 0.55);
    x.fillRect(4, Math.round(o.ruleY || 22), W - 8, 1);
  }
  x.fillStyle = css(FALLBACK.edge, 1); x.font = '600 12px "Microsoft YaHei", sans-serif';
  x.fillText(o.title || '任务日志', 6, 15);
  x.fillStyle = css(FALLBACK.neutral, 1); x.font = '400 12px "Microsoft YaHei", sans-serif';
  for (let i = 0; i < (o.lines || 3); i++) x.fillText(o.lineText ? o.lineText[i] : `击败 哀嚎洞穴 的 猎物 0/${3 + i}`, 6, 38 + i * 14);
  return c;
}

/* ───────────────────────── A3 柔光外发光 ───────────────────────── */

// 三种衰减：linear 最直白、quad 像光但内沿最陡、cos（余弦）两头都缓
function falloff(t, curve, peak) {
  if (curve === 'linear') return peak * (1 - t);
  if (curve === 'quad') return peak * Math.pow(1 - t, 2);
  return peak * 0.5 * (1 + Math.cos(Math.PI * t));               // cos
}

// 白色模具：R==G==B=255，只改 alpha；长度方向可拉伸、厚度方向 1 纹素 = 1 UI 单位
function glowBand(depth, curve, peak) {
  const [c, x] = newC(64, depth);
  const img = x.createImageData(64, depth);
  const prof = [];
  for (let r = 0; r < depth; r++) {
    const t = depth === 1 ? 0 : r / (depth - 1);                 // r=0 贴控件边 → 最亮
    const a = falloff(t, curve, peak);
    prof.push(a);
    for (let i = 0; i < 64; i++) {
      const d = (r * 64 + i) * 4;
      img.data[d] = img.data[d + 1] = img.data[d + 2] = 255;     // 无色相 + 白衬底
      img.data[d + 3] = Math.round(clamp01(a) * 255);
    }
  }
  x.putImageData(img, 0, 0);
  // 台阶只看"两块都看得见"的相邻纹素：r=0 那格内侧贴着不透明控件，它不是可见跳变
  let step = 0, at = 0;
  for (let r = 2; r < depth; r++) {
    const s = Math.abs(prof[r] - prof[r - 1]) * 255;
    if (s > step) { step = s; at = r; }
  }
  const lstar = v => { const Y = srgbLin(v); return Y > 0.008856 ? 116 * Math.cbrt(Y) - 16 : 903.3 * Y; };
  return { c, prof, maxStep: step, stepAt: at, outer: prof[depth - 1], peak: prof[0],
           innerL: lstar(prof[0]) };
}

function withGlow(base, spec, glowColor) {
  const d = spec.depth, a = spec.peak;
  const W = base.width + d * 2, H = base.height + d * 2;
  const [c, x] = newC(W, H);
  const f = i => falloff(d === 1 ? 0 : i / (d - 1), spec.curve, a);
  const put = (bx, by, bw, bh) => {
    for (let i = 0; i < bh; i++) {
      x.globalAlpha = clamp01(f(i)); x.fillStyle = css(glowColor, 1);
      x.fillRect(bx, by + i, bw, 1);
    }
    x.globalAlpha = 1;
  };
  if (spec.blend === 'ADD') x.globalCompositeOperation = 'lighter';
  put(0, d, d, d); put(W - d, d, d, d); put(d, 0, base.width, d); put(d, H - d, base.width, d);
  x.globalCompositeOperation = 'source-over';
  x.drawImage(base, d, d);
  // 角部 = 两条带交叠：ALPHA 下 1-(1-a)^2，ADD 下 2a（会顶穿）
  const corner = spec.blend === 'ADD' ? Math.min(1, 2 * a) : (1 - Math.pow(1 - a, 2));
  return { c, corner };
}

/* ───────────────────────── A4 氛围层 ───────────────────────── */

function vignette(W, H, edgeA, r0) {
  const [c, x] = newC(W, H);
  const img = x.createImageData(W, H);
  const cx = W / 2, cy = H / 2, maxR = Math.hypot(cx, cy);
  const alphaAt = (px_, py) => {
    const t = Math.min(1, Math.max(0, (Math.hypot(px_ - cx, py - cy) / maxR - r0) / (1 - r0)));
    return edgeA * t * t * (3 - 2 * t);                          // smoothstep
  };
  let centerMax = 0;
  for (let y = 0; y < H; y++) for (let xx = 0; xx < W; xx++) {
    const a = alphaAt(xx, y);
    if (Math.hypot(xx - cx, y - cy) / maxR < r0) centerMax = Math.max(centerMax, a);
    const d = (y * W + xx) * 4;
    img.data[d] = img.data[d + 1] = img.data[d + 2] = 255;
    img.data[d + 3] = Math.round(a * 255);
  }
  x.putImageData(img, 0, 0);
  return { c, alphaAt, centerMax, corner: alphaAt(0, 0) };
}

// 画布齿纹：周期 8（64 % 8 == 0，平铺不断相位），剖面沿用斜纹那次的现役 [128,255,255,128,0,0,0,0]
function weaveCanvas(size, period, profile, alpha, cross) {
  const [c, x] = newC(size, size);
  const img = x.createImageData(size, size);
  let duty = 0;
  for (let y = 0; y < size; y++) for (let xx = 0; xx < size; xx++) {
    const p1 = profile[(xx % period + period) % period] / 255;
    const p2 = cross ? profile[(y % period + period) % period] / 255 : 0;
    const a = Math.min(1, (p1 + p2)) * alpha;
    duty += a;
    const d = (y * size + xx) * 4;
    img.data[d] = img.data[d + 1] = img.data[d + 2] = 255;
    img.data[d + 3] = Math.round(a * 255);
  }
  x.putImageData(img, 0, 0);
  return { c, duty: duty / (size * size) };
}

/* ───────────────────────── 组装 ───────────────────────── */

const WEAVE_PROFILE = [128, 255, 255, 128, 0, 0, 0, 0];
const fig = (title, cap, c, scale) => `<figure><figcaption><b>${title}</b>${cap ? `<span>${cap}</span>` : ''}</figcaption>
<div class="shot"><img src="data:image/png;base64,${uri(c)}" style="width:${Math.round(c.width * (scale || 1))}px"></div></figure>`;

function table(head, rows) {
  return `<table><thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${
    rows.map(r => `<tr>${r.map((v, i) => `<td${i ? '' : ' class="k"'}>${v}</td>`).join('')}</tr>`).join('')
  }</tbody></table>`;
}

/* A3 */
const hudIcon = (() => {                                     // 一个 32×32 的 proc 格（HUD 档 0.92）
  const [c, x] = newC(32, 32);
  x.fillStyle = css(SURF.lost, 1); x.fillRect(0, 0, 32, 32);
  x.fillStyle = css(SURF.weave, 1);
  for (let i = 0; i < 32; i += 2) x.fillRect(i, (i / 2) % 2, 1, 1);
  x.fillStyle = css(FALLBACK.highlight, 0.9); x.beginPath(); x.arc(16, 16, 9, 0, Math.PI * 2); x.fill();
  x.strokeStyle = css(FALLBACK.edge, 0.95); x.lineWidth = 1; x.strokeRect(0.5, 0.5, 31, 31);
  return c;
})();

const A3V = [
  ['基线', { depth: 0 }, '只有 1px 边，亮不起来'],
  ['5 cos .50', { depth: 5, curve: 'cos', peak: 0.50, blend: 'ALPHA' }, '最薄的一档：台阶 45 超标，不可选'],
  ['5 quad .50', { depth: 5, curve: 'quad', peak: 0.50, blend: 'ALPHA' }, '同厚度换更陡的曲线（对照组）：换曲线救不了，仍超标'],
  ['5 cos .30', { depth: 5, curve: 'cos', peak: 0.30, blend: 'ALPHA' }, '台阶救回来了（27），但角部只剩 0.51 —— 读成"脏了一圈"不是"发光"'],
  ['8 cos .45', { depth: 8, curve: 'cos', peak: 0.45, blend: 'ALPHA' }, '厚度与克制的折中'],
  ['8 quad .50', { depth: 8, curve: 'quad', peak: 0.50, blend: 'ALPHA' }, '像光，但内沿最陡'],
  ['12 cos .35', { depth: 12, curve: 'cos', peak: 0.35, blend: 'ALPHA' }, '最飘、最顺'],
  ['8 cos .45 ADD', { depth: 8, curve: 'cos', peak: 0.45, blend: 'ADD' }, '暗底透亮，角部会顶穿'],
];
const a3Rows = [], a3Shots = [];
for (const [name, spec, note] of A3V) {
  const band = spec.depth ? glowBand(spec.depth, spec.curve, spec.peak) : null;
  const scene = worldScene(160, 120);
  let shot, corner = 0;
  if (spec.depth) {
    const g = withGlow(hudIcon, spec, FALLBACK.highlight);
    const [c, x] = newC(160, 120); x.drawImage(scene, 0, 0);
    x.drawImage(g.c, 64 - g.c.width / 2, 60 - g.c.height / 2);
    shot = c; corner = g.corner;
  } else {
    // 基线的图标要和柔光档同一位置（柔光档的图标落在 48−d,44−d，d=0 即 48,44），
    // 否则 5× 角部图裁的不是同一个格子。
    const [c, x] = newC(160, 120); x.drawImage(scene, 0, 0); x.drawImage(hudIcon, 48, 44); shot = c;
  }
  a3Rows.push([name,
    spec.depth ? `${spec.depth} 纹素` : '—',
    spec.curve || '—',
    band ? `${band.peak.toFixed(2)} → ${band.outer === 0 ? '0（外沿无硬边）' : band.outer.toFixed(2)}` : '—',
    band ? `${band.maxStep.toFixed(0)}/255（第 ${band.stepAt} 纹素）${band.maxStep > 32 ? ' <b>扛不住</b>' : ''}` : '—',
    corner ? corner.toFixed(2) : '—',
    spec.depth ? 'PASS（纯白模）' : '—',
    note]);
  a3Shots.push([name, shot, zoom(shot, 64 - 16 - (spec.depth || 0), 60 - 16 - (spec.depth || 0), (16 + (spec.depth || 0)) * 2, (16 + (spec.depth || 0)) * 2, 5)]);
}

/* A4 */
const scene = worldScene(320, 180);
const panelBase = panel(150, 84, { bgAlpha: 0.96, hairline: true, lines: 3 });
const A4V = [
  ['V .06 r0=.62', 0.06, 0.62], ['V .10 r0=.62', 0.10, 0.62], ['V .12 r0=.55', 0.12, 0.55],
];
const DARK = [0.05, 0.06, 0.08];
const textContrast = a => contrast(
  FALLBACK.neutral.map(v => clamp01(v * (1 - a) + 0.055 * a)),
  SURF.panel.map(v => clamp01(v * (1 - a) + 0.055 * a)));
// 压顶摆法的天花板：正文对比度跌破 4.5 的那个 α
let ceiling = 1;
for (let a = 0; a <= 1; a += 0.002) { if (textContrast(a) < 4.5) { ceiling = a; break; } }

const a4Rows = [];
const a4Shots = [];
for (const [name, edgeA, r0] of A4V) {
  const v = vignette(320, 180, edgeA, r0);
  const aPanel = v.alphaAt(87, 54);                              // 面板中心（12,12 + 150×84）
  const aMidBottom = v.alphaAt(160, 170);                        // 底缘中央：按 r0 算其实还在平段里
  const aHud = v.alphaAt(300, 170);                              // 右下角动作条 / 小地图那一块才是挨压的
  const aCorner = v.alphaAt(0, 0);
  const mid = (() => {                                           // 世界与面板之间：面板不被压
    const [c, x] = newC(320, 180);
    x.drawImage(scene, 0, 0);
    x.fillStyle = css(DARK, 1); x.globalAlpha = edgeA; x.fillRect(0, 0, 320, 180); x.globalAlpha = 1;
    x.drawImage(panelBase, 12, 12);
    return c;
  })();
  const top = (() => {                                           // 压在一切之上
    const [c, x] = newC(320, 180);
    x.drawImage(scene, 0, 0); x.drawImage(panelBase, 12, 12);
    x.fillStyle = css(DARK, 1); x.globalAlpha = edgeA; x.fillRect(0, 0, 320, 180); x.globalAlpha = 1;
    return c;
  })();
  a4Rows.push([name, `r0=${r0}`,
    v.centerMax === 0 ? '0（中心一字不动）' : v.centerMax.toFixed(4),
    `${aPanel.toFixed(3)} → 正文对比度 ${textContrast(aPanel).toFixed(2)}`,
    aMidBottom.toFixed(3), aHud.toFixed(3), aCorner.toFixed(3),
    aHud <= ceiling * 0.6 ? `HUD 处有余量（线 ${ceiling.toFixed(2)}，这里 ${aHud.toFixed(2)}）`
                          : `<b>HUD 处贴线</b>（线 ${ceiling.toFixed(2)}，这里 ${aHud.toFixed(2)}）`]);
  a4Shots.push([name + '（左：世界与面板之间 / 右：压在一切之上）', (() => {
    const [c, x] = newC(648, 180); x.drawImage(mid, 0, 0); x.drawImage(top, 328, 0);
    x.strokeStyle = 'rgba(255,255,255,0.15)'; x.strokeRect(0.5, 0.5, 319, 179); x.strokeRect(328.5, 0.5, 319, 179);
    return c; })(), null]);
}
// 画布齿纹：剖面几何占空（= α 加权，和应用 alpha 无关）与最终平均 α 分两列报
const P8 = WEAVE_PROFILE, P4 = [128, 255, 0, 0];
function weaveStats(period, profile, alpha, cross) {
  const geom = profile.reduce((s, val) => s + val, 0) / (period * 255);
  let mean = 0;
  for (let y = 0; y < period; y++) for (let xx = 0; xx < period; xx++) {
    const p1 = profile[xx] / 255, p2 = profile[y] / 255;
    mean += (cross ? Math.min(1, p1 + p2) : p1) * alpha;
  }
  // perDir = 单一方向那一族线自己的平均 α（眼睛判"线还是雾"看的是这个）；
  // meanAlpha = 经纬交叉合成后整张的平均 α（min(1,p1+p2) 会在交点饱和，只反映压了多少，不反映线感）
  return { geom, perDir: geom * alpha, meanAlpha: mean / (period * period) };
}
const weaveRows = [];
const weaveShots = [];
for (const [name, period, profile, alpha, cross, read] of [
  ['经纬 周期8 .05', 8, P8, 0.05, true, '要的就是这一档：每向 0.019 在线区，交叉后才有画布感'],
  ['经纬 周期4 .05', 4, P4, 0.05, true, '每向 α 与上一行相同，差的只是周期（更密的齿）——看 6× 会不会抖'],
  ['单经 周期8 .05', 8, P8, 0.05, false, '对照：每向 α 一模一样（0.019），但没有交叉 → 读成竖纹，不是画布'],
  ['经纬 周期8 .08', 8, P8, 0.08, true, '每向 0.030 已经踩到雾的门槛，这是上限'],
]) {
  const w = weaveCanvas(64, period, profile, alpha, cross);
  const st = weaveStats(period, profile, alpha, cross);
  const [c, x] = newC(200, 120);
  x.fillStyle = css(SURF.panel, 1); x.fillRect(0, 0, 200, 120);
  x.fillStyle = x.createPattern(w.c, 'repeat'); x.fillRect(0, 0, 200, 120);
  x.strokeStyle = css(FALLBACK.edge, 0.95); x.strokeRect(0.5, 0.5, 199, 119);
  weaveRows.push([name, `${period}（64 % ${period} = 0）`, (st.geom * 100).toFixed(1) + '%',
    st.perDir.toFixed(4) + (st.perDir <= 0.02 ? '（线区）' : st.perDir < 0.03 ? '（临界）' : '<b>（雾区）</b>'),
    st.meanAlpha.toFixed(4), cross ? '2 纹素（经纬正交，不做 45° 折算）' : '2 纹素（单向）',
    'PASS（纯白模）', read]);
  weaveShots.push([name, c, zoom(c, 0, 0, 24, 24, 6)]);
}

/* A5 —— 只动"色"不动 alpha：0.97 那一档已经等于"对话框"，拿去做 hover 就破坏 §2 的一值一义 */
const mixLin = (a, b, k) => a.map((v, i) => srgbEnc(clamp01((1 - k) * srgbLin(v) + k * srgbLin(b[i]))));
const Lstar = c => { const Y = lumOf(c); return Y > 0.008856 ? 116 * Math.cbrt(Y) - 16 : 903.3 * Y; };
const WORLD = [0.35, 0.37, 0.40];                              // 面板底下透出来的世界均值（近似）
const effPanel = a => mixLin(WORLD, SURF.panel, a);
const dL = (a1, a0) => (Lstar(effPanel(a1)) - Lstar(effPanel(a0))).toFixed(2);
// 提亮 = 沿同色度做亮度定位（和 Color.lua 的 AtLightness 同思路），不混白：
// 混线性光会把 ΔL* 直接推到 +30 以上，正文对比度当场崩掉（第一版就栽在这）
function liftL(c, dLstar) {
  const Y = lumOf(c) || 1e-6, L = Lstar(c);
  const Y2 = Math.pow((Math.min(100, L + dLstar) + 16) / 116, 3);
  return c.map(v => srgbEnc(clamp01(srgbLin(v) * Y2 / Y)));
}
const PANEL_L = Lstar(effPanel(0.96));
const tc = (bg) => contrast(FALLBACK.neutral, bg);
let liftCeiling = 0;
for (let d = 0; d <= 30; d += 0.25) { if (tc(mixLin(WORLD, liftL(SURF.panel, d), 0.96)) < 4.5) { liftCeiling = d; break; } }

// 静态角 / 悬停角并排放大（同一张合成图上取两块，保证底色一致）
function cornerPair(c, sx, sy, hx, hy, size, k) {
  const gap = 10;
  const [out, x] = newC(size * k * 2 + gap, size * k);
  x.fillStyle = '#0f1116'; x.fillRect(0, 0, out.width, out.height);
  x.drawImage(zoom(c, sx, sy, size, size, k), 0, 0);
  x.drawImage(zoom(c, hx, hy, size, size, k), size * k + gap, 0);
  return out;
}

const A5V = [
  ['R 现状', { d: 0, rule: false, glow: 0 }, '只有 1px 边变色，整块读成"没反应"'],
  ['D +3', { d: 3, rule: true, glow: 0 }, '最克制：几乎只觉"亮了一点"'],
  ['D +6', { d: 6, rule: true, glow: 0 }, '推荐档：整块回应，色相家族不动'],
  ['D +10', { d: 10, rule: true, glow: 0 }, '接近天花板，再高正文就虚'],
  ['D +6 + 柔光', { d: 6, rule: true, glow: 8 }, '依赖 A3：8 纹素、highlight 色，峰值 α 取 0.28（比 A3 表里任何一档都弱，只作"两者叠起来什么样子"的示意）'],
  ['X 提 alpha 0.97', { d: 0, rule: true, glow: 0, badAlpha: 0.97 }, '<b>违规对照</b>：0.97 已被"对话框"占用'],
];
const a5Rows = [], a5Shots = [];
for (const [name, spec, note] of A5V) {
  const rest = panel(150, 84, { bgAlpha: 0.96, hairline: true, lines: 2 });
  const lifted = liftL(SURF.panel, spec.d);
  const a = spec.badAlpha || 0.96;
  let hov = panel(150, 84, {
    bgAlpha: a, bgColor: lifted, hairline: true, lines: 2,
    edgeColor: FALLBACK.highlight, ruleColor: spec.rule ? FALLBACK.highlight : FALLBACK.edge,
  });
  if (spec.glow) {
    const g = withGlow(hov, { depth: spec.glow, curve: 'cos', peak: 0.28, blend: 'ALPHA' }, FALLBACK.highlight);
    const [c, x] = newC(g.c.width, g.c.height);
    // 柔光外面的那圈是"世界"，不是面板色：垫 SURF.panel 会把发光压成看不见，
    // 垫 WORLD 才是 HUD 关键件（贴在世界上）的真实条件。
    x.fillStyle = css(WORLD, 1); x.fillRect(0, 0, c.width, c.height);
    x.drawImage(g.c, 0, 0); hov = c;
  }
  const pad = Math.max(84, hov.height) + 10;
  const oy = (pad - hov.height) / 2;
  const [c, x] = newC(174 + hov.width, pad);
  x.fillStyle = css(WORLD, 1); x.fillRect(0, 0, c.width, c.height);   // 世界底，柔光才有东西可"发"
  x.drawImage(rest, 0, (pad - 84) / 2);
  x.drawImage(hov, 174, oy);
  x.fillStyle = 'rgba(255,255,255,0.6)'; x.font = '10px sans-serif';
  x.fillText('静态', 4, pad - 2); x.fillText('悬停', 178, pad - 2);
  const backL = Lstar(mixLin(WORLD, lifted, a));
  a5Rows.push([name,
    spec.badAlpha ? '0.96 → 0.97（色不动）' : `背板亮度 +${spec.d} L*（同 alpha）`,
    `L* ${PANEL_L.toFixed(1)} → ${backL.toFixed(1)}`,
    tc(mixLin(WORLD, lifted, a)).toFixed(2),
    spec.badAlpha ? '<b>抢了 0.97 的语义</b>' : `离 lost(28) 还差 ${(28 - backL).toFixed(1)} 档`,
    spec.glow ? `需 ${spec.glow} 纹素柔光` : '不需要',
    '0', note]);
  // 从合成图（已垫世界底）上裁，不能裁 hov 原图：背板是半透明的，
  // 直接裁出来在页面上会垫到深色底上，亮度就不是表里那个"有效底"了。
  // 两角并排、都从面板角第 0 格起算（柔光档的起点在光晕内沿），才能逐格比"边 / 发丝线 / 背板"是否一起动。
  a5Shots.push([name, c, cornerPair(c, 0, (pad - 84) / 2,
    174 + (spec.glow || 0), oy + (spec.glow || 0), 32, 6)]);
}

/* ───────────────────────── 页面 ───────────────────────── */

const style = `<style>
body{background:#14161c;color:#dfe3ea;font:14px/1.6 "Segoe UI","Microsoft YaHei",sans-serif;margin:0;padding:28px 34px;}
h1{font-size:22px;margin:0 0 6px;} h2{font-size:17px;margin:38px 0 4px;color:#e8c88a;border-left:3px solid #e8c88a;padding-left:10px;}
h3{font-size:14px;margin:22px 0 8px;color:#9fb4cc;} p.lead{color:#8b93a4;margin:0 0 10px;}
.warn{background:#241d16;border:1px solid #4b3a20;padding:10px 14px;border-radius:2px;color:#e7c9a0;font-size:13px;}
table{border-collapse:collapse;margin:10px 0 18px;font-size:13px;}
th,td{border-bottom:1px solid #262a33;padding:6px 12px;text-align:left;vertical-align:top;}
th{color:#8b93a4;font-weight:600;background:#191c24;} td.k{color:#e8c88a;font-weight:600;white-space:nowrap;}
.shots{display:flex;gap:26px;flex-wrap:wrap;align-items:flex-start;}
figure{margin:0;} figcaption{font-size:12px;color:#9fb4cc;margin-bottom:6px;}
figcaption b{color:#e8c88a;display:block;} figcaption span{color:#7e8698;}
.shot img{display:block;image-rendering:pixelated;border:1px solid #2a2e38;background:#0f1116;}
.zoom img{border:1px solid #33384a;}
code{background:#1b1e26;padding:1px 5px;color:#cfd6e4;}
ul{margin:6px 0 0;padding-left:20px;} li{margin:3px 0;}
.pick{background:#161c22;border:1px solid #24404b;padding:12px 16px;margin-top:28px;font-size:13px;}
</style>`;

const head = `<h1>A3 / A4 / A5 真像素候选（视觉验收门）</h1>
<p class="lead">生成脚本：<code>tools/gen-beauty-candidates.js</code>。口径 = 分层折中：A2 角部收弧<b>已撤</b>，面板维持直角收口。</p>
<div class="warn">这些像素是<b>候选</b>，还没有进 <code>Assets/</code>。选中之后才走 TGA → BLP（完整 mip + 白衬底修正）→ <code>tools/audit-pixels.js</code> 验收 → 才谈实机。页面里的颜色取 <code>Utils/Color.lua</code> 的 FALLBACK 与 L* 阶梯近似，实机颜色由 LibMonetColor 给，最终以实机截图为准。</div>`;

const A3SEC = `<h2>A3 柔光外发光 —— 只给 HUD 关键件（proc 触发 / 焦点 / 施法完成那一类瞬时状态），不进普通窗口</h2>
<p class="lead">做法：<code>monet_glow_band</code> 一张 64×D 的白模（无色相、alpha=0 处纯白），厚度方向 <b>1 纹素 = 1 UI 单位</b>不许拉伸，长度方向可任意拉；四条带贴控件四边，角部靠两带自然交叠，<b>不需要第二张材质</b>。全走我们自己的子框体，一个暴雪 region 都不写。染色取 <code>highlight</code>（§3 那一档的允许用途就是"选中态 / 焦点 / 进度强调"，proc 正落在这里）——材质本身无色相，换色只改顶点色。</p>
${table(['候选', '厚度', '曲线', '峰值 → 外沿 α', '可见最大台阶（位置）', '角部合成 α', '灰阶 + 白衬底', '读感'], a3Rows)}
<div class="shots">${a3Shots.map(([n, s, z]) => fig(n, '1× 场景合成', s, 1) + `<figure class="zoom"><figcaption>角部 5×</figcaption><div class="shot"><img src="data:image/png;base64,${uri(z)}" style="width:${z.width * 0.5}px"></div></figure>`).join('')}</div>
<h3>这一组真正量出来的东西</h3>
<ul>
<li><b>台阶</b>这一列只量"两侧都看得见"的相邻纹素（第 0 格内侧贴的是不透明控件，那次跳变玩家看不见）。超过 32/255 在暗底上会读成一圈一圈，和斜纹那次"糊不糊看密度"是同一类问题。<b>结论（有对照组的）</b>：厚度 5 在可用峰值下必炸——<code>5 cos .50</code> 是 45，换曲线也救不了（<code>5 quad .50</code> = 40，仍超标）；把峰值压到 <code>.30</code> 才降到 27 过关，但那一档角部合成只剩 0.51，读起来是"脏了一圈"不是"发光"。<b>所以 8 纹素是分界：它能扛 0.45 的峰值（26/255），厚度 5 不能扛任何有用的峰值。</b></li>
<li><b>陡的位置也会变</b>：5 纹素的台阶最大出现在<b>第 2 纹素</b>（紧贴控件内沿），8 纹素 cos 的最大台阶挪到了<b>第 4 纹素</b>（带子中间）。前者是"内沿一圈硬边"，后者是"中间一道渐变"——玩家对前者的容忍度低得多，因为它挨着要突出的图标。</li>
<li><b>quad（二次）确实把陡度搬回内沿</b>：8 纹素下 <code>quad .50</code> 的最大台阶 29/255 落在<b>第 2 纹素</b>，同厚度 <code>cos .45</code> 是 26/255 落在第 4 纹素——两个数都在线内，但前者是"控件边上硬一道"，后者是"中间渐变"。要不要为"更像光"换 quad，看 5× 角部图里那条内圈接受不接受。</li>
<li><b>角部合成 α</b>：两条带在角上交叠，ALPHA 下是 <code>1-(1-a)²</code>（角比边亮一档，通常正好是想要的"光从角上散开"），ADD 下是 <code>2a</code> 会顶穿。选 ADD 必须把峰值压到 0.3 左右。</li>
</ul>`;

const A4SEC = `<h2>A4 氛围层 —— 独立模块、默认关，玩家手动打开</h2>
<p class="lead">两条摆法的差别是<b>要不要连面板一起压</b>：压在"世界与面板之间"完全不伤面板文字；压在"一切之上"画布感更强，但正文对比度按 α 直接掉。下面每行左半边是前者、右半边是后者。</p>
${table(['候选', '衰减起点 r0', '中心区 α（必须为 0）', '面板中心处 → 正文对比度', '底缘中央 α', '右下角 HUD α', '四角 α', '判定'], a4Rows)}
<div class="shots">${a4Shots.map(([n, s]) => fig(n, '320×180 缩略，非全屏比例', s, 1)).join('')}</div>
<h3>画布齿纹（可与暗角各自独立开关）</h3>
${table(['候选', '周期（必须整除 64）', '剖面几何占空', '每向平均 α（筛子看这列）', '交叉后平均 α', '亮纹截面', '灰阶 + 白衬底', '读法'], weaveRows)}
<div class="shots">${weaveShots.map(([n, s, z]) => fig(n, '200×120 面板底', s, 1) + `<figure class="zoom"><figcaption>6×（看读成齿还是读成雾）</figcaption><div class="shot"><img src="data:image/png;base64,${uri(z)}" style="width:${z.width * 0.4}px"></div></figure>`).join('')}</div>
<div class="warn">三列各管一件事，别混：<b>剖面几何占空</b>说的是线形本身（27% 读成一根根线、50% 读成一片雾，现役斜纹剖面 37.5%）——齿纹<b>不改剖面</b>，所以这一列四行全同。判"线还是雾"的筛子是<b>每向平均 α</b>：<b>≤0.02 线区 / 0.02–0.03 临界 / ≥0.03 雾区</b>。<b>交叉后平均 α</b> 只是材质整体压了多少（交点走 <code>min(1,p1+p2)</code> 会饱和），拿它判线感会把"经纬"误读成比"单经"更粗——其实两者每一向完全一样，差的只是有没有交叉。另外正交经纬是 90° 相交，<b>不做 45° 折算</b>（那是斜纹的算法）。</div>
<h3>摆法才是这一组的正题</h3>
<ul>
<li>暗角在<b>世界与面板之间</b>：面板完全不挨压，正文对比度一位不掉；代价是"画布感"只统住世界，统不住 UI。</li>
<li><b>压在一切之上</b>：整屏一体化最强。但取样点要选对——面板中心和<b>底缘中央</b>都还在 r0 的平段里（α = 0.000，等于没压），真正挨压的是<b>右下角那一圈</b>（动作条末端、小地图、姓名板边缘），实测 α 见"右下角 HUD"列。文字对比度跌破 4.5 的天花板算出来是 α ≈ <code>${ceiling.toFixed(2)}</code>，所以三档的四角都还在线内，但已经不远。</li>
<li>所以最稳的形态是<b>第三档摆法</b>：暗角 + 齿纹只压世界，凡是贴屏幕边的 HUD（动作条 / 姓名板 / 信息条）自己抬到暗角层之上。这样画布感留给世界，数字和状态色一位不减。</li>
</ul>`;

const A5SEC = `<h2>A5 悬停整块提亮 —— 同 alpha 下抬背板亮度，只动我们自己的子背板</h2>
<p class="lead">现状：hover 只把 1px 边换成 <code>highlight</code>，背板不动，所以整块"没反应"。这一组量完之后有个反直觉结论：<b>alpha 那一档不但几乎看不出变化，方向还是反的</b>——面板已经压到 0.96，透出来的世界比 panel 亮，把 alpha 提到 0.97 等于少透一点世界，实测 <b>ΔL* ≈ <code>${dL(0.97, 0.96)}</code>（变暗）</b>，正文对比度反而升了。而 <code>0.97</code> 在 §2 里已经等于"对话框（会挡住操作）"——拿去做 hover 等于把一值一义破掉。所以候选全部改成<b>同 alpha 下把背板做亮度定位</b>（沿 panel 自己的色度提 L*，和 <code>Color.lua</code> 的 <code>AtLightness</code> 同思路）。<b>不是</b>往 <code>highlight</code> 混色：第一版就是那么写的，线性光里混近白的 highlight 把 ΔL* 直接推到 +27/+37，正文对比度掉到 2.56/1.78，同一页下面却还写着"低于 4.5 停手"——自相矛盾，所以换成了定位。</p>
${table(['候选', '背板处理', '有效底 L*', '悬停后正文对比度', '离 ladder 下一档（lost 28）', '是否需 A3', '写暴雪 region 数', '说明'], a5Rows)}
<div class="shots">${a5Shots.map(([n, s, z]) => fig(n, '左静态 / 右悬停', s, 1) + `<figure class="zoom"><figcaption>角部 6×　左＝静态 / 右＝悬停</figcaption><div class="shot"><img src="data:image/png;base64,${uri(z)}" style="width:${z.width * 0.6}px"></div></figure>`).join('')}</div>
<h3>纪律与代价（这一组要动几条宪法，逐条对上）</h3>
<ul>
<li><b>hover 边框 → <code>highlight</code></b>：现役 §7-a 就允许，<code>R</code> 和所有 <code>D</code> 档都有，不算新增。</li>
<li><b>发丝线一起变 <code>highlight</code></b>：<code>D</code> 档做了、<code>R</code> 没做（看 6× 角部图里那根线有没有跟着亮）。这一条要 §7-a 把"hover 边框"放宽成"hover 边框 + 发丝线"。</li>
<li><b>背板提亮</b>：不吃 <code>highlight</code> 的 RGB（所以 §7-a 管不到它），但它给表面阶梯加了一个"悬停态的 panel"——归 <b>§3</b> 管。§3 的原话是"任何自己乘个系数的写法都是在绕过阶梯"，所以落地时必须写成<b>固定一档 ΔL*</b>：选中的那个数当命名档存进 <code>SURFACE_STEPS</code> 旁边（例如 <code>hover = 6</code>），调用点只读名字，不许现算。<b>选 D 档 = 同时要改 §3 和 §7-a 两行。</b></li>
<li>"悬停后正文对比度"是护栏：底被抬起，正文 <code>neutral</code> 的对比度就往下走。扫描出来的天花板是 <b>ΔL* = ${liftCeiling.toFixed(2)}</b>——<code>D +10</code> 那一行实测正好 <code>4.50</code>，就是贴到线上；所以可选的上限是 +6，+10 属于"能用但一步都不能再多"。</li>
<li>"离 ladder 下一档"是第二层判断：悬停态<b>不该</b>亮过 <code>lost</code>（L* 28，掉血空槽），否则"手指指着这格"和"这格是空的"会读成同一件事。三档 <code>D</code> 都还在 28 以下（最高的 +10 到 21.0），离多少位表里写了。</li>
<li>代价是每块窗口一条 <code>Widget:HoverWatch</code> 常驻轮询；forbidden 框照旧由 <code>VisibilityOf</code> 的 5 秒暂停兜住，入口必须先过 <code>Widget:Readable</code>。</li>
<li><code>X 提 alpha</code> 留着当反例：它一次同时犯两个错——<b>抢走 0.97 的语义</b>，而且<b>效果方向是反的</b>（表里有效底 L* 从 ${PANEL_L.toFixed(1)} <b>掉</b>到 ${Lstar(effPanel(0.97)).toFixed(1)}）。这就是"随手挑个 alpha"的代价。</li>
</ul>`;

const pick = `<div class="pick"><b>点名格式</b>（直接回一行就行，例：<i>"A3 选 8 cos .45，A4 暗角 .10 只压世界不压 HUD + 经纬 8 .05，A5 选 D +6"</i>）
<ul>
<li><b>A3 柔光</b>（只给 HUD 关键件）：台阶过关的有 <code>8 cos .45</code> / <code>8 quad .50</code> / <code>12 cos .35</code> / <code>5 cos .30</code>（峰值太低，不推荐）/ <code>8 cos .45 ADD</code>（角部 0.90，会顶穿）；<code>5 cos .50</code>、<code>5 quad .50</code> 是超标对照组，不可选。也可以都不做。<b>A2 角部收弧已撤</b>，面板维持直角。</li>
<li><b>A4 氛围层</b>（独立模块、默认关）：暗角 .06 / .10 / .12 三档选一 + 摆法（世界与面板之间 / 压在一切之上 / 只压世界不压 HUD）；齿纹 经纬8 .05 / 经纬4 .05 / 单经8 .05 / 经纬8 .08 —— 暗角与齿纹可以各开各的。</li>
<li><b>A5 悬停提亮</b>：R 维持现状 / D +3 / D +6 / D +10 / D +6 + 柔光（需先定 A3）。X 那一行是反例，不可选。</li>
</ul>
没点名的我不动，也不部署。选中的先在本车道离线做材质与代码，跑 <code>tools/audit-pixels.js</code> + <code>node tools/api-audit.js</code>，实机截图那一趟归集成道。<br>
宪法修订随点名一起生效，我会在同一个 commit 里改：<b>§1</b> 把"无装饰材质"改成"平板 + 发丝线 + <b>两件</b>受控例外"（A2 角部收弧已撤，剩下的例外只有 A3 限定 HUD、A4 限定默认关的独立层）；选了 A5 的 <code>D</code> 档再改两行——<b>§3</b> 补"悬停态是一档命名 ΔL*，不是现算的乘数"，<b>§7-a</b> 把 highlight 从"hover 边框"放宽到"hover 边框 + 发丝线"。</div>`;

const body = head + A3SEC + A4SEC + A5SEC + pick;

const outDir = path.join(ROOT, 'docs', 'texture-preview');
fs.mkdirSync(outDir, { recursive: true });

// --sheet <png>：把四组 shots 拼成一张联络单，供 agent/作者一眼复核合成有没有错位
const si = process.argv.indexOf('--sheet');
if (si > -1 && process.argv[si + 1]) {
  const groups = [['A3 柔光', a3Shots], ['A3 角部 5×（台阶这一列肉眼复核）', a3Shots.map(([n, , z]) => [n, z])],
    ['A4 暗角两摆法', a4Shots], ['A4 齿纹', weaveShots], ['A5 悬停', a5Shots],
    ['A5 角部 6×（左静态 / 右悬停，核边 + 发丝线 + 柔光内沿）', a5Shots.map(([n, , z]) => [n, z])]];
  let W = 0, H = 54;
  for (const [, shots] of groups) for (const [, s] of shots) { W = Math.max(W, s.width + 40); H += s.height + 46; }
  const [c, x] = newC(W, H);
  x.fillStyle = '#14161c'; x.fillRect(0, 0, W, H);
  let y = 30;
  for (const [gname, shots] of groups) {
    x.fillStyle = '#e8c88a'; x.font = '600 14px "Microsoft YaHei", sans-serif'; x.fillText(gname, 20, y); y += 18;
    for (const [n, s] of shots) {
      x.fillStyle = '#9fb4cc'; x.font = '11px "Microsoft YaHei", sans-serif'; x.fillText(n, 24, y + 11);
      x.drawImage(s, 24, y + 16); y += s.height + 30;
    }
    y += 10;
  }
  fs.writeFileSync(process.argv[si + 1], c.toBuffer('image/png'));
  console.log('wrote sheet', process.argv[si + 1], `${c.width}x${c.height}`);
}

const outPath = path.join(outDir, 'beauty-candidates.html');
fs.writeFileSync(outPath, `<!DOCTYPE html><html lang="zh"><head><meta charset="UTF-8"><title>A3/A4/A5 真像素候选</title>${style}</head><body>${body}</body></html>`);
console.log('wrote', outPath, `${fs.statSync(outPath).size} bytes`);

const vi = process.argv.indexOf('--vizOut');
if (vi > -1 && process.argv[vi + 1]) {
  fs.mkdirSync(path.dirname(process.argv[vi + 1]), { recursive: true });
  fs.writeFileSync(process.argv[vi + 1], `${style}${body}`);
  console.log('wrote viz fragment', process.argv[vi + 1]);
}
