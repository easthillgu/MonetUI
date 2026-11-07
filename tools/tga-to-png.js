#!/usr/bin/env node
// TGA → PNG（未压缩 32bit type-2，本仓项目格式）。
// 用途：把随包的 TGA 源转一张 PNG 给文档 / 仓库页用（游戏内仍然只吃 BLP）。
// 用法：node tools/tga-to-png.js <in.tga> [out.png]
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const CRC_TABLE = (() => {
    const t = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        t[n] = c;
    }
    return t;
})();

function crc32(buf) {
    let c = -1;
    for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
}

function chunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body), 0);
    return Buffer.concat([len, body, crc]);
}

function decodeTGA(buf) {
    const idLen = buf[0];
    const cmapType = buf[1];
    const imgType = buf[2];
    if (cmapType !== 0 || imgType !== 2) {
        throw new Error(`expected uncompressed truecolor (type 2, no colormap), got type=${imgType} cmap=${cmapType}`);
    }
    const w = buf.readUInt16LE(12);
    const h = buf.readUInt16LE(14);
    const bpp = buf[16];
    const desc = buf[17];
    if (bpp !== 32 && bpp !== 24) throw new Error(`expected 24/32bpp, got ${bpp}`);
    const bytesPP = bpp / 8;
    const off = 18 + idLen;
    const topDown = (desc & 0x20) !== 0;
    const px = Buffer.alloc(w * h * 4);
    for (let y = 0; y < h; y++) {
        const srcY = topDown ? y : h - 1 - y;
        for (let x = 0; x < w; x++) {
            const s = off + (srcY * w + x) * bytesPP;
            const d = (y * w + x) * 4;
            px[d] = buf[s + 2];       // R
            px[d + 1] = buf[s + 1];   // G
            px[d + 2] = buf[s];       // B
            px[d + 3] = bytesPP === 4 ? buf[s + 3] : 255;
        }
    }
    return { w, h, px };
}

function encodePNG(w, h, px) {
    const raw = Buffer.alloc((w * 4 + 1) * h);
    for (let y = 0; y < h; y++) {
        raw[y * (w * 4 + 1)] = 0; // filter: none
        px.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
    }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0);
    ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 8;  // bit depth
    ihdr[9] = 6;  // RGBA
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk("IHDR", ihdr),
        chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
        chunk("IEND", Buffer.alloc(0)),
    ]);
}

const [, , inArg, outArg] = process.argv;
if (!inArg) {
    console.error("usage: node tools/tga-to-png.js <in.tga> [out.png]");
    process.exit(1);
}
const { w, h, px } = decodeTGA(fs.readFileSync(inArg));
const out = outArg || path.join(path.dirname(inArg), path.basename(inArg).replace(/\.tga$/i, ".png"));
fs.writeFileSync(out, encodePNG(w, h, px));
console.log(`${inArg} -> ${out}  (${w}x${h}, RGBA)`);
