/**
 * tools/gen-minimap-mask-ab.js —— 小地图矩形遮罩 A/B 对比图
 *
 * 同一块面板、同一张地图内容，只换遮罩：
 *   A = 当前 minimap_rect_mask.tga（256 画布，中间 190px 带，四角 r=6）
 *   B = 直角版（同样 190px 带，四角 r=0，即 Andromeda / Ellesmere / WindTools 的做法）
 *
 * 几何取自主代码真实常量（Modules/Minimap/Minimap.lua）：
 *   MAP_HEIGHT=190、MASK_CANVAS=256、MASK_CROP=33、面板 = 地图 + 每边 4。
 * 边框是 2px 直角描边（客户端 SetBackdrop 那一套：blank 白模 × 边框色）——
 * 圆角 9-slice 方案已放弃，这里不再模拟。
 *
 * 用法：
 *   node tools/gen-minimap-mask-ab.js              # 出 docs/minimap-mask-ab.png
 *   node tools/gen-minimap-mask-ab.js --out x.png
 */

const fs = require('fs');
const path = require('path');
const { createCanvas, loadImage } = require('@napi-rs/canvas');

const ROOT = path.join(__dirname, '..');
const TEX = path.join(ROOT, 'Assets-src', 'Textures');

const MAP_W = 256, MAP_H = 190, CANVAS = 256;
const CROP = (CANVAS - MAP_H) / 2;      // 33
const INSET = 4;                        // 地图离面板每边 4
const PANEL_W = MAP_W + INSET * 2, PANEL_H = MAP_H + INSET * 2;

/* ── 读未压缩 32bit TGA ─────────────────────────────────────────────── */
function readTGA(file) {
    const b = fs.readFileSync(file);
    const w = b.readUInt16LE(12), h = b.readUInt16LE(14), bpp = b[16], desc = b[17];
    const topDown = !!(desc & 0x20);
    const off = 18 + (b[0] || 0);
    const out = createCanvas(w, h);
    const ctx = out.getContext('2d');
    const img = ctx.createImageData(w, h);
    for (let y = 0; y < h; y++) {
        const srcY = topDown ? y : h - 1 - y;
        for (let x = 0; x < w; x++) {
            const s = off + (srcY * w + x) * 4, d = (y * w + x) * 4;
            img.data[d] = b[s + 2];       // TGA is BGRA
            img.data[d + 1] = b[s + 1];
            img.data[d + 2] = b[s];
            img.data[d + 3] = bpp === 32 ? b[s + 3] : 255;
        }
    }
    ctx.putImageData(img, 0, 0);
    return out;
}

/* ── 遮罩：A 用现成材质，B 现场画直角 ──────────────────────────────── */
const maskCache = {};
function maskCanvas(rounded) {
    const key = rounded ? 'A' : 'B';
    if (maskCache[key]) return maskCache[key];
    let c;
    if (rounded) {
        c = readTGA(path.join(TEX, 'minimap_rect_mask.tga'));
    } else {
        c = createCanvas(CANVAS, CANVAS);
        const ctx = c.getContext('2d');
        ctx.fillStyle = '#fff';
        ctx.fillRect(0, CROP, MAP_W, MAP_H);
    }
    return (maskCache[key] = c);
}

/* ── 地图内容：自绘的地形（任意倍率都清晰，不会像截图那样糊） ────── */
function drawTerrain(ctx, S) {
    const rnd = (() => { let s = 0x9e3779b9; return () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296; })();
    const blobs = ['#a8946a', '#c2b085', '#9d9a6d', '#8d8a5c', '#c8b98c', '#82805a', '#b1a075', '#bdb08a'];

    ctx.fillStyle = '#b3a077';
    ctx.fillRect(0, 0, S, S);

    for (let i = 0; i < 90; i++) {
        const x = rnd() * S, y = rnd() * S, r = (0.04 + rnd() * 0.14) * S;
        const g = ctx.createRadialGradient(x, y, 0, x, y, r);
        const c = blobs[(rnd() * blobs.length) | 0];
        g.addColorStop(0, c);
        g.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = 0.55;
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(x, y, r, 0, Math.PI * 2);
        ctx.fill();
    }
    ctx.globalAlpha = 1;

    // 河
    ctx.strokeStyle = 'rgba(104,136,140,0.85)';
    ctx.lineWidth = S * 0.035;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(-0.05 * S, 0.72 * S);
    ctx.bezierCurveTo(0.22 * S, 0.60 * S, 0.30 * S, 0.86 * S, 0.52 * S, 0.74 * S);
    ctx.bezierCurveTo(0.72 * S, 0.63 * S, 0.80 * S, 0.40 * S, 1.05 * S, 0.34 * S);
    ctx.stroke();

    // 路
    ctx.strokeStyle = 'rgba(96,80,56,0.55)';
    ctx.lineWidth = S * 0.012;
    ctx.beginPath();
    ctx.moveTo(0.10 * S, -0.02 * S);
    ctx.bezierCurveTo(0.24 * S, 0.30 * S, 0.46 * S, 0.34 * S, 0.62 * S, 0.30 * S);
    ctx.bezierCurveTo(0.80 * S, 0.26 * S, 0.66 * S, 0.62 * S, 0.86 * S, 0.78 * S);
    ctx.stroke();

    // 树林小点
    ctx.fillStyle = 'rgba(86,98,60,0.55)';
    for (let i = 0; i < 70; i++) {
        const x = rnd() * S, y = rnd() * S, r = (0.006 + rnd() * 0.012) * S;
        ctx.beginPath();
        ctx.arc(x, y, r, 0, Math.PI * 2);
        ctx.fill();
    }

    // 轻微压暗 + 暗角，接近小地图
    ctx.fillStyle = 'rgba(10,12,16,0.10)';
    ctx.fillRect(0, 0, S, S);
}

async function mapCanvas(shot, rounded, Z) {
    const S = CANVAS * Z;
    const c = createCanvas(S, S);
    const ctx = c.getContext('2d');
    drawTerrain(ctx, S);
    ctx.globalCompositeOperation = 'destination-in';
    ctx.imageSmoothingEnabled = true;
    ctx.drawImage(maskCanvas(rounded), 0, 0, S, S);
    ctx.globalCompositeOperation = 'source-over';
    return c;
}

/* ── 边框：客户端那套直角 SetBackdrop 描边（blank 白模 × 边框色）─────── */
const EDGE_RGBA = 'rgba(217,168,92,0.95)';   // Color.edge 的近似值，只用于这张对比图
function drawBorder(ctx, W, H, Z) {
    ctx.strokeStyle = EDGE_RGBA;
    ctx.lineWidth = 2 * Z;
    ctx.strokeRect(Z, Z, W * Z - 2 * Z, H * Z - 2 * Z);
}


/* ── 一整块面板 ─────────────────────────────────────────────────────── */
async function renderPanel(rounded, Z) {
    const map = await mapCanvas(null, rounded, Z);

    const c = createCanvas(PANEL_W * Z, PANEL_H * Z);
    const ctx = c.getContext('2d');

    // 场景底（面板 35% 黑盖在上面，透出一点）
    const bg = ctx.createLinearGradient(0, 0, c.width, c.height);
    bg.addColorStop(0, '#232a33');
    bg.addColorStop(1, '#12151b');
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, c.width, c.height);
    // 面板底色 bgAlpha=0.35（客户端是不带圆角的整块矩形）
    ctx.fillStyle = 'rgba(24,26,32,0.35)';
    ctx.fillRect(0, 0, c.width, c.height);

    // 地图 256 画布：可见带从第 33 行开始，面板顶边在画布顶边下方 29
    ctx.drawImage(map, INSET * Z, (INSET - CROP) * Z, CANVAS * Z, CANVAS * Z);

    // 边框
    drawBorder(ctx, PANEL_W, PANEL_H, Z);
    return c;
}

/* ── 拼图 ───────────────────────────────────────────────────────────── */
function label(ctx, text, x, y, size, color, align) {
    ctx.font = `600 ${size}px "Microsoft YaHei", "Segoe UI", sans-serif`;
    ctx.fillStyle = color;
    ctx.textAlign = align || 'left';
    ctx.textBaseline = 'alphabetic';
    ctx.fillText(text, x, y);
}

function tile(ctx, src, sx, sy, size, Z, dx, dy) {
    ctx.drawImage(src, sx * Z, sy * Z, size * Z, size * Z, dx, dy, size * Z, size * Z);
    ctx.strokeStyle = 'rgba(255,255,255,0.12)';
    ctx.lineWidth = 1;
    ctx.strokeRect(dx + 0.5, dy + 0.5, size * Z - 1, size * Z - 1);
}

function wrap(ctx, text, x, y, maxW, size, color, lh) {
    ctx.font = `400 ${size}px "Microsoft YaHei", "Segoe UI", sans-serif`;
    ctx.fillStyle = color;
    ctx.textAlign = 'left';
    let line = '';
    for (const ch of text) {
        if (ctx.measureText(line + ch).width > maxW && line) {
            ctx.fillText(line, x, y);
            line = ch;
            y += lh;
        } else line += ch;
    }
    if (line) ctx.fillText(line, x, y);
    return y + lh;
}

/* 遮罩 alpha 图（白 = 可见），棋盘格垫底 */
function maskAlphaTile(rounded, Z, size) {
    const S = size * Z;
    const c = createCanvas(S, S);
    const ctx = c.getContext('2d');
    const q = 12;
    for (let y = 0; y < S; y += q) for (let x = 0; x < S; x += q) {
        ctx.fillStyle = ((x / q + y / q) & 1) ? '#2a2d36' : '#20232b';
        ctx.fillRect(x, y, q, q);
    }
    // 取遮罩左上角：与面板左上角对齐（面板 (0,0) 对应遮罩 (0, 29)）
    ctx.drawImage(maskCanvas(rounded),
        INSET * Z, (INSET - CROP) * Z, CANVAS * Z, CANVAS * Z);
    return c;
}

(async () => {
    const outArg = process.argv.indexOf('--out');
    const out = outArg > -1 ? process.argv[outArg + 1] : path.join(ROOT, 'docs', 'minimap-mask-ab.png');

    const Z1 = 2, Z2 = 12;
    const CROP_SIZE = 25;             // 角部取 25×25 UI 单位

    const A = await renderPanel(true, Z1);
    const B = await renderPanel(false, Z1);
    const A12 = await renderPanel(true, Z2);
    const B12 = await renderPanel(false, Z2);
    const MA = maskAlphaTile(true, Z2, CROP_SIZE);
    const MB = maskAlphaTile(false, Z2, CROP_SIZE);

    const M = 40, gap = 40;
    const T = CROP_SIZE * Z2;
    const W = M * 2 + A.width * 2 + gap;
    const H = 118 + A.height + 46 + 22 + T + 42 + 22 + T + 34;

    const sheet = createCanvas(W, H);
    const ctx = sheet.getContext('2d');
    ctx.fillStyle = '#14161c';
    ctx.fillRect(0, 0, W, H);

    label(ctx, '小地图矩形遮罩 A/B：只换四角', M, 52, 26, '#f2ede2');
    label(ctx, '同一块面板（264×198）· 同一张地图内容 · 边框是 2px 直角描边（客户端 SetBackdrop 那一套）', M, 80, 14, '#8b93a4');

    /* ── 整图 2× ── */
    const y0 = 116;
    label(ctx, 'A　圆角 r=6（当前）', M + A.width / 2, y0 - 10, 16, '#e8c88a', 'center');
    label(ctx, 'B　直角 r=0（Andromeda / Ellesmere）', M + A.width + gap + B.width / 2, y0 - 10, 16, '#9fb4cc', 'center');
    ctx.drawImage(A, M, y0);
    ctx.drawImage(B, M + A.width + gap, y0);

    const noteX = M + 2 * T + gap * 2;

    /* ── 遮罩 alpha ── */
    let y = y0 + A.height + 42;
    label(ctx, '遮罩 alpha　12×（左上角 · 白 = 地图可见 · 棋盘 = 被裁）', M, y, 14, '#8b93a4');
    y += 14;
    label(ctx, 'A　r=6', M, y + 12, 14, '#e8c88a');
    label(ctx, 'B　r=0', M + T + gap, y + 12, 14, '#9fb4cc');
    ctx.drawImage(MA, M, y + 18);
    ctx.drawImage(MB, M + T + gap, y + 18);

    /* ── 实机合成 ── */
    let y2 = y + 18 + T + 40;
    label(ctx, '实机合成　12×（左上角 · 地图 + 面板底色 + 边框）', M, y2, 14, '#8b93a4');
    y2 += 14;
    label(ctx, 'A　r=6', M, y2 + 12, 14, '#e8c88a');
    label(ctx, 'B　r=0', M + T + gap, y2 + 12, 14, '#9fb4cc');
    tile(ctx, A12, 0, 0, CROP_SIZE, Z2, M, y2 + 18);
    tile(ctx, B12, 0, 0, CROP_SIZE, Z2, M + T + gap, y2 + 18);

    /* ── 说明 ── */
    const noteW = W - noteX - M;
    const gapFor = r => (2.414 + 0.4142 * r).toFixed(1);
    const blocks = [
        ['A　r=6（当前）', '#e8c88a',
            `地图角自己收一个 6px 的弧，和面板边框（弧 3、环宽 2）不同心；对角上留约 ${gapFor(6)}px 的透明缝 —— 四角读作“圆角地图”。`],
        ['B　r=0（参考插件）', '#9fb4cc',
            `直角一直顶到地图边缘，对角缝只剩约 ${gapFor(0)}px；四角更“满”，但地图轮廓是硬的，和圆角边框是两种风格。`],
        ['', null,
            '参考插件（Andromeda / Ellesmere / WindTools）都是 256 画布 + 190 带 + 直角。'],
        ['', null,
            `中间值 r=3：对角缝约 ${gapFor(3)}px，仍是圆角、但更贴边框。`],
        ['', null,
            '面板 264×198；地图 256×190 居中（每边 4）；边框 2px 直角描边。'],
    ];
    let ty = y + 6;
    for (const [head, hc, body] of blocks) {
        if (head) { label(ctx, head, noteX, ty, 13, hc); ty += 20; }
        ty = wrap(ctx, body, noteX, ty + 4, noteW, 12, '#aeb5c2', 19) + 8;
    }

    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, sheet.toBuffer('image/png'));
    console.log('wrote', out, `${sheet.width}x${sheet.height}`);
})();
