// tools/tga-to-blp.js — convert an uncompressed 32-bit TGA to BLP2 (raw3 by default) with a full mip chain.
//
// Usage:
//   node tools/tga-to-blp.js <input.tga> [output.blp]
//   node tools/tga-to-blp.js <input.tga> [output.blp] --format=dxt5 --filter=lanczos3
//   node tools/tga-to-blp.js <input.tga> [output.blp] --no-mips
//
// 交付口径（2026-10-28）：
//   * mip 链默认**开**（--no-mips 只用于诊断对比）。没有 mip 的纹理在小尺寸显示时只能靠引擎
//     实时缩采样，1px 线条会闪、会丢；BLP 的 mip 是交付物的一部分，不是可选项。
//   * 滤波默认 triangle：唯一**不产生过冲**（ringing）的选项。catmullRom / lanczos3 会在 1px 发丝线
//     和 alpha 硬边两侧振铃出 halo —— 我们的贴图全是压边模具，过冲是可见缺陷。
//   * 格式默认 raw3（无压缩 RGBA）：9-slice 边纹、1px 发丝线、alpha 遮罩经不起 DXT 的 4x4 块量化。
//     --format=dxt5 仅供体积/画质对照（体积约 1/3，代价见 tools/make-blp-compare.js 的误差表）。
//   * mip 生成保住了"Alpha=0 像素 RGB 必须是纯白"的衬底规则（逐级实测 0 违规），
//     降采样不会把黑边拖进可见区。

import init, { encodeBlp, decodeBlp } from 'wow-blp-web';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Load wasm bytes synchronously so init() doesn't need to fetch.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmPath = path.join(__dirname, '..', 'node_modules', 'wow-blp-web', 'wow_blp_web_bg.wasm');
const wasmBytes = new Uint8Array(fs.readFileSync(wasmPath));
await init({ module_or_path: wasmBytes });

function decodeTGA(buf) {
    const imgType = buf[2];
    if (imgType !== 2) throw new Error(`expected type 2 TGA, got ${imgType}`);
    const bpp = buf[16];
    if (bpp !== 32) throw new Error(`expected 32bpp TGA, got ${bpp}`);
    const desc   = buf[17];
    const dataStart = 18 + buf[0] + (buf[1] ? buf.readUInt16LE(3) * buf.readUInt8(8) : 0);
    const width  = buf.readUInt16LE(12);
    const height = buf.readUInt16LE(14);

    const px = new Uint8Array(width * height * 4);
    const flipY = (desc & 0x20) === 0;
    for (let y = 0; y < height; y++) {
        const srcY = flipY ? height - 1 - y : y;
        for (let x = 0; x < width; x++) {
            const si = dataStart + (srcY * width + x) * 4;
            const di = (y * width + x) * 4;
            px[di    ] = buf[si + 2];  // R
            px[di + 1] = buf[si + 1];  // G
            px[di + 2] = buf[si    ];  // B
            px[di + 3] = buf[si + 3];  // A
        }
    }
    return { width, height, px };
}

// ---------- CLI ----------
const argv = process.argv.slice(2);
const flags = {};
const positional = [];
for (const a of argv) {
    if (a.startsWith('--')) {
        const [k, v] = a.slice(2).split('=');
        flags[k] = v === undefined ? true : v;
    } else positional.push(a);
}

const input = positional[0];
if (!input) {
    console.error('Usage: node tools/tga-to-blp.js <input.tga> [output.blp] '
        + '[--format=raw3|dxt5] [--filter=triangle] [--no-mips]');
    process.exit(1);
}

// 默认输出：源目录（Assets-src/Textures）里的 TGA 一律交到 Assets/Textures 去。
// 源与交付分处两个目录，写错地方就是"游戏里没更新、源目录里多个 BLP"，所以这里按目录判定，
// 而不是简单地把扩展名换掉。
function defaultOutput(inPath) {
    const dir = path.dirname(inPath);
    const base = path.basename(inPath).replace(/\.tga$/i, '.blp');
    if (path.basename(dir) === 'Textures' && path.basename(path.dirname(dir)) === 'Assets-src') {
        const repoRoot = path.dirname(path.dirname(dir));   // .../MonetUI
        return path.join(repoRoot, 'Assets', 'Textures', base);
    }
    return path.join(dir, base);
}
const output = positional[1] || defaultOutput(input);

const format  = flags.format || 'raw3';
const filter  = flags.filter || 'triangle';
const mipmaps = flags['no-mips'] ? false : true;

if (!['raw1', 'raw3', 'dxt1', 'dxt3', 'dxt5', 'jpeg'].includes(format)) {
    console.error(`unknown --format: ${format}`);
    process.exit(1);
}
if (!['nearest', 'triangle', 'catmullRom', 'gaussian', 'lanczos3'].includes(filter)) {
    console.error(`unknown --filter: ${filter}`);
    process.exit(1);
}

const buf = fs.readFileSync(input);
const { width, height, px } = decodeTGA(buf);
console.log(`input : ${input}  ${width}x${height}`);

// RAW3 (uncompressed RGBA) keeps pixels identical to TGA — stencils cannot afford DXT compression artifacts.
// 注意：wow-blp-web 0.7.2 给 raw3 固定写 alphaType=0（= "无 alpha"，alphaBits/hasAlpha 选项对
// raw3 无效，实测四种组合都一样）。本客户端的加载器认这个字段，alphaType=0 时整张图被当成不透明：
// 图标/close 全变实心小方块、遮罩不裁切（小地图成了正方形）、圆角弧变方角、斜纹只剩白底。
// 同机真实素材（NDui/Media/bgTex.blp、Andromeda bag-config.blp）的无压缩 BLP 都是
// enc=3 alphaDepth=8 alphaType=8 —— 所以编码后按这个口径把头里两个字段改回来。
function declareRaw3Alpha(bytes) {
    if (bytes.readUInt8(8) !== 3) return 0;   // 只有 raw3 走这条路（DXT 的 alphaType 由库自己写）
    const before = bytes.readUInt8(10);
    bytes.writeUInt8(8, 9);                   // alphaDepth：BGRA 的 A 通道固定 8 bit
    bytes.writeUInt8(8, 10);                  // alphaType：8 = 8-bit alpha
    return before === 8 ? 0 : 1;
}
const options = { version: 'blp2', format, mipmaps, filter };
let blp = Buffer.from(encodeBlp(px, width, height, options));

/**
 * 白衬底修正（只对 raw3）。
 *
 * 编码器逐级降采样时，alpha 会被舍入到 0，而 RGB 仍带着邻居的颜色 —— 于是每一级都会冒出几十个
 * "alpha=0 但 RGB 有色"的像素。这正是 audit-pixels.js 全局禁止的那种像素：客户端建 mip / 滤波时
 * 会把它拖进可见区，形成彩色毛边（美术贴图上是脏边，模具上是带色相的边）。
 *
 * 我们自己在 TGA 里已经保证了白衬底，所以这里对**生成的每一级**做同样的强制：
 * alpha=0 的像素 RGB 一律写回 (255,255,255)。raw3 是无压缩 BGRA，可以直接按偏移改字节。
 */
function enforceWhiteMatte(bytes) {
    if (bytes.readUInt32BE(0) !== 0x424C5032) throw new Error('not BLP2'); // 'BLP2'
    const compression = bytes.readUInt8(8);       // 3 = raw3 (BGRA8888)
    const hasMips = bytes.readUInt8(11);
    if (compression !== 3) return { bytes, patched: 0, note: 'not raw3, skipped' };
    const w = bytes.readUInt32LE(12);
    const h = bytes.readUInt32LE(16);
    const offsets = [];
    const sizes = [];
    for (let i = 0; i < 16; i++) {
        offsets.push(bytes.readUInt32LE(20 + i * 4));
        sizes.push(bytes.readUInt32LE(84 + i * 4));
    }
    let patched = 0;
    for (let lvl = 0; lvl < 16; lvl++) {
        if (!offsets[lvl] || !sizes[lvl]) continue;
        const lw = Math.max(1, w >> lvl);
        const lh = Math.max(1, h >> lvl);
        const expect = lw * lh * 4;
        if (sizes[lvl] !== expect) throw new Error(`mip ${lvl}: size ${sizes[lvl]} != ${expect}`);
        let p = offsets[lvl];
        for (let i = 0; i < lw * lh; i++, p += 4) {
            if (bytes[p + 3] === 0 && (bytes[p] !== 255 || bytes[p + 1] !== 255 || bytes[p + 2] !== 255)) {
                bytes[p] = 255; bytes[p + 1] = 255; bytes[p + 2] = 255;
                patched++;
            }
        }
    }
    if (!hasMips) return { bytes, patched, note: 'no mips' };
    return { bytes, patched };
}

/**
 * 剔除调色板块（只对 raw3）。
 *
 * 编码器给所有 BLP2 都预留了 1024 字节调色板（mip0 偏移 = 148 + 1024），但 raw3 是无压缩 BGRA，
 * 根本不用调色板 —— 那 1KB 纯属白烧（16×16 的图总共才 2.5KB，四成是它）。这里把头之后那段
 * 删掉，并把 16 个 mip 偏移整体前移 1024；偏移表本身就在头里，所以引擎按偏移读不会受影响。
 */
function stripPalette(bytes) {
    const mip0Off = bytes.readUInt32LE(20);
    if (mip0Off !== 148 + 1024) return { bytes, stripped: 0, note: 'no palette block' };
    const out = Buffer.concat([bytes.subarray(0, 148), bytes.subarray(148 + 1024)]);
    for (let i = 0; i < 16; i++) {
        const off = out.readUInt32LE(20 + i * 4);
        if (off) out.writeUInt32LE(off - 1024, 20 + i * 4);
    }
    return { bytes: out, stripped: 1024 };
}

const matte = enforceWhiteMatte(blp);
const pal = stripPalette(matte.bytes);
blp = pal.bytes;
const alphaFixed = declareRaw3Alpha(blp);

fs.writeFileSync(output, blp);

// Report the chain we actually wrote (not what we asked for).
const tex = decodeBlp(blp);
const levels = (tex.mipmaps || []).map(m => `${m.width}x${m.height}`).join(' → ') || '(none)';
const mip0 = (tex.mipmaps || [])[0];

// mip0 must stay byte-identical to the TGA for raw3 — a mismatch means the encoder resampled level 0.
let mip0Diff = 0;
if (format === 'raw3' && mip0) {
    for (let i = 0; i < px.length; i++) if (px[i] !== tex.rgba[i]) mip0Diff++;
}

console.log(`output: ${output}  ${blp.length} bytes  (${format}, ${filter}, `
    + `${(tex.mipmaps || []).length} levels${mip0Diff ? `, mip0 diff px=${mip0Diff}` : ', mip0 identical'}`
    + `${matte.patched ? `, matte fixed px=${matte.patched}` : ', matte clean'}`
    + `${pal.stripped ? `, palette -${pal.stripped}B` : ''}`
    + `${alphaFixed ? ', alphaType=8' : ''})`);
console.log(`  mips: ${levels}`);
