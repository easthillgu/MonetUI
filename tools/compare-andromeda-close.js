/**
 * tools/compare-andromeda-close.js — 只读对照工具（不进发行包，不动发行码）
 *
 * 背景：3f2ba5f 的 ✕ 重绘与斜纹剖面都引 Andromeda 为参照，而 AGENTS/MULTI-HARNESS
 * 记的 ../Andromeda 不在。实测参照件确在 _classic_titan_ 的 AddOns 里（38001 适配套）。
 * 本工具用 make-blp-compare.js 同一条解码链（wow-blp-web + @napi-rs/canvas）把
 *   参考 ui-close.blp / statusbar-stripes-thin.tga
 * 与本仓现役
 *   monet_close_normal（TGA 源 + 发行 BLP mip0）/ monet_stripe_weave（同左）
 * 读出像素，按同一口径逐量对比，产一页 HTML。
 *
 *   node tools/compare-andromeda-close.js
 *   → docs/texture-preview/andromeda-close-compare.html
 *
 * 对参考目录**只读**。测量口径全部注明，方便复核。
 */
import init, { decodeBlp } from 'wow-blp-web';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { createCanvas } = require('@napi-rs/canvas');

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const ANDRO = 'C:/Users/EastHillGu/Documents/Blizzards/WOWFOREVER/World of Warcraft/_classic_titan_/Interface/AddOns/Andromeda/assets/textures';

const wasmBytes = new Uint8Array(fs.readFileSync(
    path.join(ROOT, 'node_modules', 'wow-blp-web', 'wow_blp_web_bg.wasm')));
await init({ module_or_path: wasmBytes });

// ---------- 通用：RGBA 读写 + 缩放 ----------
// ---------- 解码（TGA：type 2/10 × 24/32bpp —— 参考件 stripes 是 type 10 RLE、64x32） ----------
function decodeTGA(buf) {
    const imgType = buf[2], bpp = buf[16];
    if ((imgType !== 2 && imgType !== 10) || (bpp !== 32 && bpp !== 24)) throw new Error(`unsupported TGA type=${imgType} bpp=${bpp}`);
    const desc = buf[17];
    const dataStart = 18 + buf[0] + (buf[1] ? buf.readUInt16LE(3) * buf.readUInt8(8) : 0);
    const width = buf.readUInt16LE(12), height = buf.readUInt16LE(14);
    const bytes = bpp / 8;
    const px = new Uint8Array(width * height * 4);
    const flipY = (desc & 0x20) === 0;
    const total = width * height;
    const put = (idx, b0, b1, b2, b3) => {
        const y = Math.floor(idx / width), x = idx % width;
        const sy = flipY ? height - 1 - y : y;
        const di = (sy * width + x) * 4;
        px[di] = b2; px[di + 1] = b1; px[di + 2] = b0; px[di + 3] = b3;
    };
    if (imgType === 2) {
        for (let i = 0; i < total; i++) {
            const si = dataStart + i * bytes;
            put(i, buf[si], buf[si + 1], buf[si + 2], bytes === 4 ? buf[si + 3] : 255);
        }
    } else {
        let off = dataStart, i = 0;
        while (i < total) {
            const pkt = buf[off++];
            const count = (pkt & 0x7F) + 1;
            if (pkt & 0x80) {
                const b0 = buf[off], b1 = buf[off + 1], b2 = buf[off + 2], b3 = bytes === 4 ? buf[off + 3] : 255;
                off += bytes;
                for (let k = 0; k < count; k++, i++) put(i, b0, b1, b2, b3);
            } else {
                for (let k = 0; k < count; k++, i++) {
                    put(i, buf[off], buf[off + 1], buf[off + 2], bytes === 4 ? buf[off + 3] : 255);
                    off += bytes;
                }
            }
        }
    }
    return { width, height, px };
}
function decodeBLP0(file) {
    const bytes = new Uint8Array(fs.readFileSync(file));
    const t = decodeBlp(bytes, 0);
    return { width: t.width, height: t.height, px: t.rgba };
}

// ---------- 通用：RGBA 读写 + 缩放 ----------
function toCanvas(w, h, rgba) {
    const c = createCanvas(w, h);
    const ctx = c.getContext('2d');
    const img = ctx.createImageData(w, h);
    img.data.set(rgba);
    ctx.putImageData(img, 0, 0);
    return c;
}
function fromCanvas(c) {
    const ctx = c.getContext('2d');
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    return { width: c.width, height: c.height, px: new Uint8Array(d) };
}
function fitTo(img, size) { return fromCanvas(resizeBilinear(toCanvas(img.width, img.height, img.px), size, size)); }
function resizeBilinear(src, w, h) {
    const c = createCanvas(w, h);
    const ctx = c.getContext('2d');
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(src, 0, 0, w, h);
    return c;
}
function pngURL(c) { return 'data:image/png;base64,' + c.toBuffer('image/png').toString('base64'); }
function up(src, f, bg) {
    const c = createCanvas(src.width * f, src.height * f);
    const ctx = c.getContext('2d');
    if (bg) { ctx.fillStyle = bg; ctx.fillRect(0, 0, c.width, c.height); }
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(src, 0, 0, c.width, c.height);
    return c;
}
// ---------- ✕ 的度量（口径：alpha>16 记墨；bbox 含端点；质心按 alpha 加权） ----------
function closeMetrics(img) {
    const { width: w, height: h, px } = img;
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9, ink = 0, sx = 0, sy = 0, sumA = 0;
    let aMax = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const a = px[(y * w + x) * 4 + 3];
        if (a > aMax) aMax = a;
        if (a > 16) {
            ink++; sumA += a; sx += x * a; sy += y * a;
            if (x < x0) x0 = x; if (x > x1) x1 = x;
            if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
    }
    const spanX = x1 - x0 + 1, spanY = y1 - y0 + 1;
    const cx = sx / sumA, cy = sy / sumA;
    // 笔画：中心行 / 中心列上，左右两臂的 alpha≥128 连续段宽度取平均
    function runs(fixed, horiz) {
        const row = [];
        for (let i = 0; i < (horiz ? w : h); i++) {
            const [xx, yy] = horiz ? [i, fixed] : [fixed, i];
            row.push(px[(yy * w + xx) * 4 + 3] >= 128 ? 1 : 0);
        }
        const out = []; let c = 0;
        for (const v of row) { if (v) c++; else if (c) { out.push(c); c = 0; } }
        if (c) out.push(c);
        return out;
    }
    const mid = Math.floor(h / 2), midx = Math.floor(w / 2);
    const rowRuns = runs(mid, true), colRuns = runs(midx, false);
    const arm = (arr) => arr.filter(v => v <= Math.max(w, h) / 3);
    const strokeRow = arm(rowRuns), strokeCol = arm(colRuns);
    const stroke = (strokeRow.length ? strokeRow.reduce((a, b) => a + b, 0) / strokeRow.length : 0);
    const strokeV = (strokeCol.length ? strokeCol.reduce((a, b) => a + b, 0) / strokeCol.length : 0);
    // 对称性：alpha 图与自身水平/垂直镜像的平均绝对差（0..255 归一）
    let diffH = 0, diffV = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const i = px[(y * w + x) * 4 + 3], j = px[(y * w + (w - 1 - x)) * 4 + 3];
        const k = px[((h - 1 - y) * w + x) * 4 + 3];
        diffH += Math.abs(i - j); diffV += Math.abs(i - k);
    }
    const n = w * h;
    // 墨迹分段（alpha≥128）：中心行 + 上方 1/4 高度的"手臂行"，用于区分笔画宽与中心交叠
    function runStr(fixed) {
        const out = []; let c = 0, st = -1;
        for (let x = 0; x < w; x++) {
            const a = px[(fixed * w + x) * 4 + 3];
            if (a >= 128) { if (c === 0) st = x; c++; }
            else if (c) { out.push(st + '..' + (st + c - 1)); c = 0; }
        }
        if (c) out.push(st + '..' + (st + c - 1));
        return out.join(' ');
    }
    return {
        size: `${w}x${h}`, bbox: `[${x0}..${x1}, ${y0}..${y1}]`,
        span: spanX, spanPct: +(spanX / Math.max(w, h) * 100).toFixed(1),
        strokeH: +stroke.toFixed(2), strokeV: +strokeV.toFixed(2),
        strokePct: +(stroke / Math.max(w, h) * 100).toFixed(1),
        centroid: [cx.toFixed(2), cy.toFixed(2)], center: (w / 2).toFixed(2),
        inkPct: +(ink / n * 100).toFixed(1), alphaMax: aMax,
        asymH: +(diffH / n / 255 * 100).toFixed(2), asymV: +(diffV / n / 255 * 100).toFixed(2),
        runsMid: runStr(mid), runsArm: runStr(Math.max(0, mid - Math.floor(h / 4))),
    };
}

// ---------- 斜纹度量：45° 剖面 ----------
function stripeMetrics(img) {
    const { width: w, height: h, px } = img;
    const A = (x, y) => px[((y % h + h) % h * w + (x % w + w) % w) * 4 + 3];
    let sum = 0; for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) sum += A(x, y);
    const duty = sum / (255 * w * h);
    // 方向 + 周期：对 k=2..16，把 alpha 按 (x+y)%k 和 (x-y)%k 折叠，取组内方差最小者
    function foldScore(diag, k) {
        const bins = Array.from({ length: k }, () => ({ s: 0, s2: 0, n: 0 }));
        for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
            const d = ((diag ? x + y : x - y) % k + k) % k;
            const a = A(x, y); const b = bins[d];
            b.s += a; b.s2 += a * a; b.n++;
        }
        let within = 0, means = [];
        for (const b of bins) {
            const m = b.s / b.n; means.push(Math.round(m));
            within += b.s2 / b.n - m * m;
        }
        return { within: within / k, means };
    }
    let best = null;
    for (const diag of [true, false]) for (let k = 2; k <= 16; k++) {
        const sc = foldScore(diag, k);
        if (!best || sc.within < best.within) best = { ...sc, diag, k };
    }
    return {
        size: `${w}x${h}`, dutyPct: +(duty * 100).toFixed(1),
        period: best.k, dir: best.diag ? 'x+y (↘)' : 'x-y (↗)',
        profile: best.means, withinVar: Math.round(best.within),
        peak: Math.max(...best.means), valley: Math.min(...best.means),
    };
}

// ---------- 收集 ----------
function need(f) { const p = path.join(ANDRO, f); if (!fs.existsSync(p)) throw new Error(`参考件缺失: ${p}`); return p; }
const refClose = decodeBLP0(need('ui-close.blp'));
const ourCloseTga = decodeTGA(fs.readFileSync(path.join(ROOT, 'Assets-src/Textures/monet_close_normal.tga')));
const ourCloseBlp = decodeBLP0(path.join(ROOT, 'Assets/Textures/monet_close_normal.blp'));
const ourPushTga = decodeTGA(fs.readFileSync(path.join(ROOT, 'Assets-src/Textures/monet_close_push.tga')));
const refStripe = decodeTGA(fs.readFileSync(need('statusbar-stripes-thin.tga')));
const refStripeThick = decodeTGA(fs.readFileSync(need('statusbar-stripes-thick.tga')));
const ourStripeTga = decodeTGA(fs.readFileSync(path.join(ROOT, 'Assets-src/Textures/monet_stripe_weave.tga')));
const ourStripeBlp = decodeBLP0(path.join(ROOT, 'Assets/Textures/monet_stripe_weave.blp'));

const rows32ref = closeMetrics(refClose);
const rows32ours32 = closeMetrics(ourCloseTga.width > 32 ? fitTo(ourCloseTga, 32) : ourCloseTga);
const rowsOursNative = closeMetrics(ourCloseTga);
const rowsOursShip = closeMetrics(ourCloseBlp);
const rowsPush = closeMetrics(ourPushTga);

const sRef = stripeMetrics(refStripe);
const sRefThick = stripeMetrics(refStripeThick);
const sOurs = stripeMetrics(ourStripeTga);
const sOursBlp = stripeMetrics(ourStripeBlp);

// ---------- HTML ----------
const DARK = '#1b1917', LIGHT = '#e9e4da';
function imgRow(caption, cells) {
    return `<tr><td class="cap">${caption}</td>${cells.map(c => `<td>${c}</td>`).join('')}</tr>`;
}
const stripeShots = [pngURL(up(toCanvas(refStripe.width, refStripe.height, refStripe.px), 6, DARK)),
    pngURL(up(toCanvas(ourStripeTga.width, ourStripeTga.height, ourStripeTga.px), 6, DARK)),
    pngURL(up(toCanvas(ourStripeBlp.width, ourStripeBlp.height, ourStripeBlp.px), 6, DARK))];
// 4px 血条模拟：把斜纹按 1:1 平铺到 60x4（参考件口径 = 实机 1 texel/px 时）
function stripe4px(img, name) {
    const c = createCanvas(64, 8);
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#7a1414'; ctx.fillRect(0, 0, 64, 8);
    const a = toCanvas(img.width, img.height, img.px);
    ctx.imageSmoothingEnabled = false;
    ctx.globalAlpha = 0.55;
    for (let x = 0; x < 64; x += img.width) ctx.drawImage(a, x, 0, img.width, img.height);
    ctx.globalAlpha = 1;
    return pngURL(up(c, 4, DARK));
}

function table(objs, names) {
    const keys = Object.keys(objs[0]);
    return `<table><tr><th></th>${names.map(n => `<th>${n}</th>`).join('')}</tr>` +
        keys.map(k => `<tr><td class="cap">${k}</td>${objs.map(o => `<td>${Array.isArray(o[k]) ? o[k].join(',') : o[k]}</td>`).join('')}</tr>`).join('') + '</table>';
}

// ---------- 3. 线宽→物理像素换算（纯几何：笔画垂直厚 = 占比 × 显示直径(px)） ----------
// 占比来源：我们 = CLOSE_GLYPH_STROKE 0.125（regen-textures.js）；参考 = 实测 32px 上手臂行
// run=8px（α≥128）→ 垂直厚 8/√2 = 5.66px → 0.177。**未计入** 64→显示尺寸的 mip/双线性
// 软化、圆帽、DXT5 块量化 —— 那些只能实机看。
const OURS_F = 0.125, REF_F = 8 / Math.SQRT2 / 32;
const widths = [];
for (const D of [18, 20, 22, 24, 28, 32]) {
    const row = { '钮径(UI px)': D };
    for (const s of [1, 2]) {
        const ours = D * s * OURS_F, ref = D * s * REF_F;
        row[`我们@${s}x`] = ours.toFixed(2) + (ours < 1 ? ' ⚠<1px' : '');
        row[`参考@${s}x`] = ref.toFixed(2) + (ref < 1 ? ' ⚠<1px' : '');
    }
    widths.push(row);
}
// 临界：笔画进亚像素 <=> 显示物理直径 < 1/0.125 = 8px（我们）；参考 = 1/0.177 ≈ 5.66px。
const critOurs = +(1 / OURS_F).toFixed(2), critRef = +(1 / REF_F).toFixed(2);
const widthKeys = Object.keys(widths[0]);
const widthHtml = `<table><tr>${widthKeys.map(k => `<th>${k}</th>`).join('')}</tr>` +
    widths.map(r => `<tr>${widthKeys.map(k => `<td>${r[k]}</td>`).join('')}</tr>`).join('') + '</table>';

const html = `<!doctype html><meta charset="utf-8"><title>Andromeda 对照：close ✕ 与斜纹剖面</title>
<style>body{font-family:system-ui;background:#141210;color:#ddd;padding:24px;max-width:1200px}
h2{color:#e8c078}table{border-collapse:collapse;margin:8px 0 20px}td,th{border:1px solid #443;padding:4px 8px;font-size:13px}
.cap{color:#999}.note{color:#f2b632}img{vertical-align:middle}</style>
<h1>Andromeda 对照页（只读工具产出，不进发行包）</h1>
<p class="note">参考件实测目录：_classic_titan_ 38001 适配套（Andromeda.toc Version 11.01）。
若其像素与本仓 HANDOFF 记录的"零售参考件尺寸"不一致，先报数字、不反推我们错。</p>
<h2>1. 关闭 ✕（ui-close.blp vs monet_close_normal）</h2>
<p>口径：alpha&gt;16 记墨；bbox 含端点；质心 alpha 加权；笔画宽 = 中心行上 &alpha;≥128 的短连续段均值。</p>
${table([rows32ref, rows32ours32, rowsOursNative, rowsOursShip, rowsPush],
    ['参考 ui-close.mip0', '我们 TGA 降到 32', '我们 TGA mip0(64)', '我们 BLP mip0(64)', 'push 态(64)'])}
${imgRow('原始像素', [pngURL(up(toCanvas(refClose.width, refClose.height, refClose.px), 8, DARK)),
    pngURL(up(toCanvas(ourCloseTga.width, ourCloseTga.height, ourCloseTga.px), 8, DARK)),
    pngURL(up(toCanvas(ourCloseBlp.width, ourCloseBlp.height, ourCloseBlp.px), 8, DARK))])}
${imgRow('实机 32px 显示（双线性，深底）', [pngURL(resizeBilinear(toCanvas(refClose.width, refClose.height, refClose.px), 32, 32)),
    pngURL(resizeBilinear(toCanvas(ourCloseTga.width, ourCloseTga.height, ourCloseTga.px), 32, 32)),
    pngURL(resizeBilinear(toCanvas(ourPushTga.width, ourPushTga.height, ourPushTga.px), 32, 32))])}
<h2>2. 斜纹（statusbar-stripes-thin.tga vs monet_stripe_weave）</h2>
<p>口径：方向/周期 = 在 (x±y) 折叠里取组内方差最小的 k（k∈2..16）；占空 = alpha 加权墨量。</p>
${table([sRef, sRefThick, sOurs, sOursBlp], ['参考 thin.tga', '参考 thick.tga', '我们 TGA', '我们 BLP mip0'])}
${imgRow('最近邻 ×6（深底）', stripeShots)}
${imgRow('8px 条带 1:1 平铺 ×4（红底=血条模拟）', [stripe4px(refStripe), stripe4px(ourStripeTga)])}
<h2>3. ✕ 线宽 → 物理像素（纯几何推算，非实机渲染）</h2>
<p class="note">口径：垂直笔画厚 = 占比 × 显示物理直径。占比：我们 0.125（drawCloseX 常数）；
参考件实测 8/√2÷32 = 0.177。⚠&lt;1px = 该档一定进亚像素。<b>不含</b> mip 选择、双线性软化、
圆帽与 DXT5 量化 —— 实际显示粗细必须实机看（本仓 1px 边框奇偶判例同）。</p>
${widthHtml}
<p>临界尺寸（我们）：显示物理直径 &lt; <b>${critOurs}px</b> 时笔画必进亚像素；
参考件同判据为 ${critRef}px。六档钮径（×1/×2 缩放共 12 种显示直径 18–64px）全部高于临界，
按几何层判定<b>不存在亚像素线</b>。</p>
`;
fs.mkdirSync(path.join(ROOT, 'docs/texture-preview'), { recursive: true });
const out = path.join(ROOT, 'docs/texture-preview/andromeda-close-compare.html');
fs.writeFileSync(out, html);
console.log(JSON.stringify({
    out,
    refClose: rows32ref, ours32: rows32ours32, oursNative: rowsOursNative, oursShip: rowsOursShip, push: rowsPush,
    stripeRef: sRef, stripeRefThick: sRefThick, stripeOurs: sOurs, stripeOursBlp: sOursBlp,
    widthTable: widths, criticalOursPx: critOurs, criticalRefPx: critRef,
}, null, 1));
