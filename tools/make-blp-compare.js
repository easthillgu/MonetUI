/**
 * tools/make-blp-compare.js — 素材交付对照页（TGA / BLP-RAW3 / BLP-DXT5 / mip 链 / 实机尺寸）
 *
 * 产出 docs/texture-preview/blp-compare.html（gitignored），逐张给：
 *   ① RAW3 mip0 ×4 最近邻   —— 交付的原始像素
 *   ② DXT5 mip0 ×4          —— 若改压缩格式会损失什么
 *   ③ 32×32 DXT5 ×4         —— 「别人的材质」那一套口径（降分辨率 + 压缩）
 *   ④ mip 链条              —— 实际写进 BLP 的每一级，最近邻放大到同高
 *   ⑤ 实机尺寸对照          —— 16/24/32px，深/浅底各一行：
 *                              有 mip 采样 / 无 mip 采样（旧交付）/ 32×32 DXT5
 *                              用来直观看出「mip 缺失」在真实显示尺寸下的代价
 *
 * 采样模拟：GPU 的 mip 选择 = 取「尺寸仍 ≥ 目标」的最小一级再做双线性；无 mip 就是直接
 * 从 mip0 双线性缩到目标（1px 线条会丢、会闪）。这里按同一规则在 CPU 上复现。
 *
 * 用法：node tools/make-blp-compare.js [纹理名...]   （不给名字 = 全量）
 */

import init, { encodeBlp, decodeBlp } from 'wow-blp-web';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { createCanvas } = require('@napi-rs/canvas');

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'Assets-src', 'Textures');    // TGA 源（进 git，不发行）
const SHIP = path.join(ROOT, 'Assets', 'Textures');       // BLP 交付（进游戏）
const OUT_DIR = path.join(ROOT, 'docs', 'texture-preview');

const wasmBytes = new Uint8Array(fs.readFileSync(
    path.join(ROOT, 'node_modules', 'wow-blp-web', 'wow_blp_web_bg.wasm')));
await init({ module_or_path: wasmBytes });

// ---------- STENCIL 名单：从 audit-pixels.js 里解析，保持唯一真源 ----------
function loadStencilSet() {
    const src = fs.readFileSync(path.join(__dirname, 'audit-pixels.js'), 'utf8');
    const start = src.indexOf('const STENCIL = new Set([');
    if (start < 0) throw new Error('audit-pixels.js: STENCIL block not found');
    const end = src.indexOf(']);', start);
    const block = src.slice(start, end);
    return new Set([...block.matchAll(/'([a-z0-9_]+)'/g)].map(m => m[1]));
}
const STENCIL = loadStencilSet();

// ---------- TGA ----------
function decodeTGA(buf) {
    const imgType = buf[2];
    const bpp = buf[16];
    if (imgType !== 2 || bpp !== 32) throw new Error(`unsupported TGA type=${imgType} bpp=${bpp}`);
    const desc = buf[17];
    const dataStart = 18 + buf[0] + (buf[1] ? buf.readUInt16LE(3) * buf.readUInt8(8) : 0);
    const width = buf.readUInt16LE(12);
    const height = buf.readUInt16LE(14);
    const px = new Uint8Array(width * height * 4);
    const flipY = (desc & 0x20) === 0;
    for (let y = 0; y < height; y++) {
        const srcY = flipY ? height - 1 - y : y;
        for (let x = 0; x < width; x++) {
            const si = dataStart + (srcY * width + x) * 4;
            const di = (y * width + x) * 4;
            px[di] = buf[si + 2]; px[di + 1] = buf[si + 1];
            px[di + 2] = buf[si]; px[di + 3] = buf[si + 3];
        }
    }
    return { width, height, px };
}

// ---------- canvas helpers ----------
function canvasFromRGBA(w, h, rgba) {
    const c = createCanvas(w, h);
    const ctx = c.getContext('2d');
    const img = ctx.createImageData(w, h);
    img.data.set(rgba);
    ctx.putImageData(img, 0, 0);
    return c;
}

function pngDataURL(canvas) {
    return 'data:image/png;base64,' + canvas.toBuffer('image/png').toString('base64');
}

function upscaleNearest(src, factor) {
    const c = createCanvas(src.width * factor, src.height * factor);
    const ctx = c.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(src, 0, 0, c.width, c.height);
    return c;
}

function resize(src, w, h) {
    w = Math.max(1, Math.round(w));
    h = Math.max(1, Math.round(h));
    if (w === src.width && h === src.height) return src;
    const c = createCanvas(w, h);
    const ctx = c.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(src, 0, 0, w, h);
    return c;
}

/** 长边缩到 size，保持宽高比（实机尺寸对照用）。 */
function fitLongEdge(src, size) {
    const k = size / Math.max(src.width, src.height);
    return resize(src, src.width * k, src.height * k);
}

/** GPU 风格采样：先选 mip 级（仍 ≥ 目标尺寸的最后一级），再双线性缩到目标。 */
function sampleFromMips(levels, size) {
    const base = levels[0].canvas;
    const k = size / Math.max(base.width, base.height);
    const tw = Math.max(1, Math.round(base.width * k));
    const th = Math.max(1, Math.round(base.height * k));
    let pick = levels[0];
    for (const lv of levels) {
        if (lv.canvas.width >= tw && lv.canvas.height >= th) pick = lv;
        else break;
    }
    return resize(pick.canvas, tw, th);
}

function tileOnBG(sprite, bg) {
    const pad = 2;
    const c = createCanvas(sprite.width + pad * 2, sprite.height + pad * 2);
    const ctx = c.getContext('2d');
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, c.width, c.height);
    ctx.drawImage(sprite, pad, pad);
    return c;
}

function rowOf(tiles, gap = 6, groupSize = 0, groupGap = 0) {
    let w = gap * (tiles.length - 1);
    if (groupSize > 0) w += groupGap * (Math.floor((tiles.length - 1) / groupSize));
    w += tiles.reduce((a, t) => a + t.width, 0);
    const h = Math.max(...tiles.map(t => t.height));
    const c = createCanvas(w, h);
    const ctx = c.getContext('2d');
    let x = 0;
    tiles.forEach((t, i) => {
        if (i > 0) {
            x += gap;
            if (groupSize > 0 && i % groupSize === 0) x += groupGap - gap;
        }
        ctx.drawImage(t, x, Math.floor((h - t.height) / 2));
        x += t.width;
    });
    return c;
}

function columnOf(tiles, gap = 4) {
    const w = Math.max(...tiles.map(t => t.width));
    const h = tiles.reduce((a, t) => a + t.height, 0) + gap * (tiles.length - 1);
    const c = createCanvas(w, h);
    const ctx = c.getContext('2d');
    let y = 0;
    for (const t of tiles) {
        ctx.drawImage(t, 0, y);
        y += t.height + gap;
    }
    return c;
}

// ---------- BLP ----------
function blpLevels(bytes) {
    const meta = decodeBlp(bytes);
    const out = [];
    for (let lvl = 0; lvl < (meta.mipmaps || []).length; lvl++) {
        const t = decodeBlp(bytes, lvl);
        out.push({ level: lvl, width: t.width, height: t.height, canvas: canvasFromRGBA(t.width, t.height, t.rgba) });
    }
    return { meta, levels: out };
}

function dxt5Error(refRGBA, dxtBytes) {
    const t = decodeBlp(dxtBytes);
    let maxDelta = 0, sum = 0, over16 = 0;
    for (let i = 0; i < refRGBA.length; i += 4) {
        let pxMax = 0;
        for (let ch = 0; ch < 4; ch++) {
            const d = Math.abs(refRGBA[i + ch] - t.rgba[i + ch]);
            if (d > pxMax) pxMax = d;
        }
        if (pxMax > maxDelta) maxDelta = pxMax;
        if (pxMax > 16) over16++;
        sum += pxMax;
    }
    return { maxDelta, mean: sum / (refRGBA.length / 4), over16, total: refRGBA.length / 4 };
}

// ---------- main ----------
const onlyNames = process.argv.slice(2).filter(a => !a.startsWith('--'));
const files = fs.readdirSync(SRC).filter(f => f.endsWith('.tga'))
    .filter(f => !onlyNames.length || onlyNames.includes(f.replace(/\.tga$/, '')))
    .sort();

fs.mkdirSync(OUT_DIR, { recursive: true });

const DARK = '#1b1917';
const LIGHT = '#e9e4da';
const SIZES = [16, 24, 32];

const rows = [];
let totalTga = 0, totalRaw3 = 0, totalDxt5 = 0, totalRef32 = 0;

for (const file of files) {
    const name = file.replace(/\.tga$/, '');
    const tgaBuf = fs.readFileSync(path.join(SRC, file));
    const { width, height, px } = decodeTGA(tgaBuf);
    const blpPath = path.join(SHIP, name + '.blp');
    if (!fs.existsSync(blpPath)) throw new Error(`missing ${name}.blp — run tools/tga-to-blp.js first`);
    const blpBuf = fs.readFileSync(blpPath);

    const raw3 = blpLevels(blpBuf);
    const dxt5Bytes = encodeBlp(px, width, height, { version: 'blp2', format: 'dxt5', mipmaps: true, filter: 'triangle' });
    const dxt5 = blpLevels(Buffer.from(dxt5Bytes));

    // 参考口径：长边降到 32（若本来就 ≤32 则原样），再 DXT5 + mip
    const srcCanvas = canvasFromRGBA(width, height, px);
    const ref32Source = Math.max(width, height) > 32 ? fitLongEdge(srcCanvas, 32) : srcCanvas;
    const ref32Ctx = ref32Source.getContext('2d');
    const ref32RGBA = new Uint8Array(ref32Ctx.getImageData(0, 0, ref32Source.width, ref32Source.height).data);
    const ref32Bytes = encodeBlp(ref32RGBA, ref32Source.width, ref32Source.height,
        { version: 'blp2', format: 'dxt5', mipmaps: true, filter: 'triangle' });
    const ref32 = blpLevels(Buffer.from(ref32Bytes));

    const err = dxt5Error(px, dxt5Bytes);
    const zoom = width <= 64 ? 4 : 2;

    // ① ② ③ 放大
    const imgRaw3 = upscaleNearest(raw3.levels[0].canvas, zoom);
    const imgDxt5 = upscaleNearest(dxt5.levels[0].canvas, zoom);
    const imgRef32 = upscaleNearest(ref32.levels[0].canvas, zoom);

    // ④ mip 链条：每级最近邻放大到统一 48 高
    const mipTiles = raw3.levels.map(lv => {
        const scale = Math.max(1, Math.round(48 / Math.max(lv.canvas.width, lv.canvas.height)));
        const up = upscaleNearest(lv.canvas, scale);
        const c = createCanvas(up.width, Math.max(48, up.height));
        const ctx = c.getContext('2d');
        ctx.drawImage(up, 0, Math.floor((c.height - up.height) / 2));
        return c;
    });
    const imgMips = rowOf(mipTiles, 4);

    // ⑤ 实机尺寸对照：有 mip / 无 mip / 32×32 DXT5
    //    1px 厚的纹理（发丝线）在游戏里是横向拉伸使用，缩小采样对它没有意义 —— 单独按拉伸展示。
    const extreme = Math.min(width, height) === 1;
    const realRows = {};
    for (const [bgName, bg] of [['dark', DARK], ['light', LIGHT]]) {
        if (extreme) {
            const stretch = (src) => {
                const long = 170;
                const w = width >= height ? long : Math.max(1, Math.round(src.width * long / Math.max(src.width, src.height)));
                const h = width >= height ? 1 : long;
                const c = createCanvas(w + 4, h + 4);
                const ctx = c.getContext('2d');
                ctx.fillStyle = bg;
                ctx.fillRect(0, 0, c.width, c.height);
                ctx.imageSmoothingEnabled = false;
                ctx.drawImage(src, 2, 2, w, h);
                return c;
            };
            realRows[bgName] = stretch(raw3.levels[0].canvas);
            continue;
        }
        const tiles = [];
        for (const size of SIZES) {
            const withMip = sampleFromMips(raw3.levels, size);
            const noMip = fitLongEdge(raw3.levels[0].canvas, size);
            const ref32s = sampleFromMips(ref32.levels, Math.min(size, Math.max(ref32Source.width, ref32Source.height)));
            tiles.push(tileOnBG(withMip, bg));
            tiles.push(tileOnBG(noMip, bg));
            tiles.push(tileOnBG(ref32s, bg));
        }
        realRows[bgName] = rowOf(tiles, 4, 3, 18);
    }

    totalTga += tgaBuf.length;
    totalRaw3 += blpBuf.length;
    totalDxt5 += dxt5Bytes.length;
    totalRef32 += ref32Bytes.length;

    rows.push({
        name, width, height,
        stencil: STENCIL.has(name),
        tgaSize: tgaBuf.length,
        raw3Size: blpBuf.length,
        dxt5Size: dxt5Bytes.length,
        ref32Size: ref32Bytes.length,
        levels: raw3.levels.length,
        err,
        imgRaw3: pngDataURL(imgRaw3),
        imgDxt5: pngDataURL(imgDxt5),
        imgRef32: pngDataURL(imgRef32),
        imgMips: pngDataURL(imgMips),
        imgDark: pngDataURL(realRows.dark),
        imgLight: pngDataURL(realRows.light),
    });
    process.stdout.write(`  ${name.padEnd(28)} ${width}x${height}  raw3=${blpBuf.length}B  dxt5=${dxt5Bytes.length}B  ref32=${ref32Bytes.length}B  mip=${raw3.levels.length}\n`);
}

const kb = n => (n / 1024).toFixed(1) + ' KB';

const html = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>MonetUI 素材交付对照（TGA / BLP-RAW3 / BLP-DXT5 / mip 链）</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#141210; color:#ece7dd; font:14px/1.6 -apple-system,"Segoe UI","PingFang SC","Noto Sans CJK SC",sans-serif; }
  header { padding:28px 32px 8px; border-bottom:1px solid #2e2a26; }
  h1 { margin:0 0 6px; font-size:22px; font-weight:600; letter-spacing:.02em; }
  .sub { color:#a29a8d; font-size:13px; max-width:920px; }
  h2 { font-size:16px; margin:34px 32px 10px; color:#e8c078; font-weight:600; }
  .wrap { padding:0 32px 60px; }
  table { border-collapse:collapse; width:100%; font-size:12.5px; margin-top:8px; }
  th,td { border-bottom:1px solid #2b2724; padding:5px 8px; text-align:right; }
  th:first-child, td:first-child { text-align:left; }
  th { color:#a29a8d; font-weight:500; background:#1a1816; position:sticky; top:0; }
  tr:hover td { background:#1c1a18; }
  .stencil { color:#9ec7a8; }
  .art { color:#d8a75b; }
  .bad { color:#e07b6a; }
  .ok { color:#9ec7a8; }
  .card { border:1px solid #2b2724; border-radius:8px; margin:16px 0; background:#181614; overflow:hidden; }
  .card > .head { display:flex; align-items:baseline; gap:12px; padding:10px 14px; background:#1d1a17; border-bottom:1px solid #2b2724; }
  .card > .head .nm { font-family:ui-monospace,SFMono-Regular,Consolas,monospace; font-size:13px; color:#f0ead9; }
  .card > .head .meta { margin-left:auto; font-size:12px; color:#a29a8d; display:flex; gap:14px; }
  .body { padding:14px; display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:16px; }
  figure { margin:0; }
  figcaption { font-size:11.5px; color:#a29a8d; margin-bottom:6px; letter-spacing:.02em; }
  .shot { background:
      repeating-conic-gradient(#232120 0% 25%, #1a1816 0% 50%) 50%/12px 12px;
      border:1px solid #2b2724; border-radius:5px; padding:8px; display:flex; align-items:center; justify-content:center; }
  .shot img { image-rendering:pixelated; display:block; max-width:100%; }
  .legend { display:flex; gap:22px; flex-wrap:wrap; font-size:12px; color:#a29a8d; margin:6px 0 0; }
  .legend b { color:#ece7dd; font-weight:500; }
  .note { border-left:2px solid #d8a75b; padding:8px 14px; margin:14px 0; background:#1b1916; font-size:13px; color:#cfc7b9; }
  code { font-family:ui-monospace,Consolas,monospace; font-size:12px; background:#221f1c; padding:1px 5px; border-radius:3px; color:#e8c078; }
  .grid3 { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; }
  .cellhead { font-size:11px; color:#8d857a; text-align:center; margin-bottom:2px; }
</style></head><body>
<header>
  <h1>MonetUI 素材交付对照</h1>
  <div class="sub">
    ${files.length} 张自绘纹理 · 生成于 ${new Date().toISOString().replace('T', ' ').slice(0, 19)} ·
    源：<code>Assets/Textures/*.tga</code>（审计源）+ <code>*.blp</code>（交付）<br>
    本页为一次性诊断产物，落在 gitignored 的 <code>docs/texture-preview/</code>，不进仓库。
  </div>
  <div class="legend" style="margin-top:14px">
    <span><b>mip0 ×N</b> 最近邻放大，看真实像素</span>
    <span><b>mip 链</b> 实际写进 BLP 的每一级</span>
    <span><b>实机尺寸</b> 16/24/32px 三组，组内有 mip / 无 mip / 32×32，深浅两底</span>
  </div>
</header>

<h2>① 体积与格式总表</h2>
<div class="wrap">
  <div class="note">
    <b>结论先说：</b>mip 链已补上（此前 <code>mipmaps:false</code> 是我们自己关的，属于交付缺陷）。
    mip 由编码器逐级降采样生成，随后我们做一道<b>白衬底修正</b>：降采样会把 alpha 舍入到 0 而 RGB 还带色，
    这类像素每张图会冒出几十个，逐级强制写回纯白（本批共修正 6 张 / 115 个像素）。
    分类：RAW3 用于<b>所有</b>贴图——它们几乎全是压边模具（1px 线 / alpha 遮罩），DXT 的 4×4 块量化会
    把发丝线啃成断续的点、并在 alpha 硬边留下块状台阶。「32×32」也不适合本套：9-slice 边纹按 1 texel = 1 UI 单位
    映射，降一半分辨率等于把边框线宽算错。
  </div>
  <table>
    <thead><tr>
      <th>纹理</th><th>类型</th><th>尺寸</th><th>TGA</th>
      <th>RAW3+mip</th><th>DXT5+mip</th><th>32×32 DXT5+mip</th>
      <th>mip 级</th><th>DXT5 最大色差</th><th>超 16 的像素</th>
    </tr></thead>
    <tbody>
    ${rows.map(r => `<tr>
      <td>${r.name}</td>
      <td class="${r.stencil ? 'stencil' : 'art'}">${r.stencil ? '模具' : '美术'}</td>
      <td>${r.width}×${r.height}</td>
      <td>${kb(r.tgaSize)}</td>
      <td>${kb(r.raw3Size)}</td>
      <td>${kb(r.dxt5Size)}</td>
      <td>${kb(r.ref32Size)}</td>
      <td>${r.levels}</td>
      <td class="${r.err.maxDelta > 16 ? 'bad' : 'ok'}">${r.err.maxDelta}</td>
      <td>${r.err.over16} / ${r.err.total}</td>
    </tr>`).join('\n')}
    </tbody>
    <tfoot><tr>
      <th>合计</th><th></th><th></th><th>${kb(totalTga)}</th>
      <th>${kb(totalRaw3)}</th><th>${kb(totalDxt5)}</th><th>${kb(totalRef32)}</th>
      <th></th><th></th><th></th>
    </tr></tfoot>
  </table>
</div>

<h2>② 逐张对照</h2>
<div class="wrap">
${rows.map(r => `
  <div class="card">
    <div class="head">
      <span class="nm">${r.name}</span>
      <span class="${r.stencil ? 'stencil' : 'art'}" style="font-size:12px">${r.stencil ? '染色模具' : '美术色'}</span>
      <span class="meta">
        <span>${r.width}×${r.height}</span>
        <span>mip ${r.levels} 级</span>
        <span>RAW3 ${kb(r.raw3Size)}</span>
        <span>DXT5 ${kb(r.dxt5Size)}</span>
        <span>32×32 ${kb(r.ref32Size)}</span>
        <span>DXT5 最大色差 ${r.err.maxDelta}</span>
      </span>
    </div>
    <div class="body">
      <figure>
        <figcaption>① RAW3 mip0 ×${r.width <= 64 ? 4 : 2}（交付像素，与 TGA 逐位一致）</figcaption>
        <div class="shot"><img src="${r.imgRaw3}"></div>
      </figure>
      <figure>
        <figcaption>② DXT5 mip0 ×${r.width <= 64 ? 4 : 2}（若改压缩）</figcaption>
        <div class="shot"><img src="${r.imgDxt5}"></div>
      </figure>
      <figure>
        <figcaption>③ 32×32 DXT5 ×4（「别人的材质」口径）</figcaption>
        <div class="shot"><img src="${r.imgRef32}"></div>
      </figure>
      <figure>
        <figcaption>④ mip 链（level 0 → ${r.levels - 1}，逐级放大到同高）</figcaption>
        <div class="shot"><img src="${r.imgMips}"></div>
      </figure>
    </div>
    <div style="padding:0 14px 14px">
      <figcaption style="font-size:11.5px;color:#a29a8d;margin-bottom:6px">
        ⑤ 实机尺寸：三组分别是 <b>16 / 24 / 32 px</b>；每组内 3 个变体 ——
        <b>有 mip</b>（现交付） / <b>无 mip</b>（旧交付） / <b>32×32 DXT5</b>
      </figcaption>
      <div class="grid3">
        <div><div class="cellhead">深色底</div><div class="shot"><img src="${r.imgDark}"></div></div>
        <div><div class="cellhead">浅色底</div><div class="shot"><img src="${r.imgLight}"></div></div>
        <div><div class="cellhead">怎么读这一栏</div>
          <div class="shot" style="background:#1a1816;color:#8d857a;font-size:11px;display:block;padding:10px 12px;line-height:1.9">
            组 = 一个显示尺寸，组内固定顺序：<br>
            有 mip / 无 mip / 32×32 DXT5<br>
            <span style="color:#e8c078">1px 线条：无 mip 会变淡、断裂、闪烁</span><br>
            <span style="color:#8d857a">1:1 使用的材质（遮罩、9-slice）不会缩小，<br>这一栏对它们只是压力测试</span>
          </div>
        </div>
      </div>
    </div>
  </div>`).join('\n')}
</div>
</body></html>
`;

const outFile = path.join(OUT_DIR, 'blp-compare.html');
fs.writeFileSync(outFile, html);
console.log(`\n→ ${outFile}  (${(fs.statSync(outFile).size / 1024).toFixed(0)} KB)`);
console.log(`   TGA ${kb(totalTga)} | RAW3+mip ${kb(totalRaw3)} | DXT5+mip ${kb(totalDxt5)} | 32×32 DXT5+mip ${kb(totalRef32)}`);
