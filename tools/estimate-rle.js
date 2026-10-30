/**
 * 估算：把当前 25 张 TGA 改成 RLE 压缩（type 10）能省多少字节。
 * 只做测量，不写文件。像素完全不变，只是换 TGA 的行程编码方式。
 *
 * 依据：参考插件 EllesmereUI 的 bar fill 大量用 type 10（RLE）+ 24bpp，
 * 而我们 25 张全是 type 2 未压缩 32bpp。
 *
 * 用法：node tools/estimate-rle.js
 */

const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '..', 'Assets-src', 'Textures');

function decodeTGA(file) {
  const b = fs.readFileSync(file);
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
  const topLeft = (b.readUInt8(17) & 0x20) !== 0;
  let o = 18;
  const px = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
    const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
    const k = (row * w + (i % w)) * 4;
    px[k] = r; px[k + 1] = g; px[k + 2] = bl; px[k + 3] = a;
  }
  return { w, h, px };
}

// TGA RLE 编码（type 10）。每行独立打包，包头 1 字节：
//   bit7 = 1 → RLE 包（后 6 位 = 重复次数-1，1..128），后面跟 1 个像素（4 字节）
//   bit7 = 0 → RAW 包（后 6 位 = 像素数-1，1..128），后面跟 N 个像素
function encodeRLE(d) {
  const { w, h, px } = d;
  const out = [];
  for (let y = 0; y < h; y++) {
    const rowStart = y * w * 4;
    let x = 0;
    while (x < w) {
      // 数连续相同像素
      let run = 1;
      while (x + run < w && run < 128) {
        const o = rowStart + (x + run) * 4;
        const p = rowStart + x * 4;
        if (px[o] !== px[p] || px[o + 1] !== px[p + 1] || px[o + 2] !== px[p + 2] || px[o + 3] !== px[p + 3]) break;
        run++;
      }
      if (run >= 2) {
        out.push(0x80 | (run - 1));
        const o = rowStart + x * 4;
        out.push(px[o], px[o + 1], px[o + 2], px[o + 3]);
        x += run;
      } else {
        // 收集不重复的像素
        let raw = 1;
        while (x + raw < w && raw < 128) {
          const p = rowStart + (x + raw) * 4;
          const p1 = rowStart + (x + raw + 1) * 4;
          const sameNext = (x + raw + 1 < w) && px[p] === px[p1] && px[p + 1] === px[p1 + 1] && px[p + 2] === px[p1 + 2] && px[p + 3] === px[p1 + 3];
          if (sameNext) break;
          raw++;
        }
        out.push(raw - 1);
        for (let i = 0; i < raw; i++) {
          const o = rowStart + (x + i) * 4;
          out.push(px[o], px[o + 1], px[o + 2], px[o + 3]);
        }
        x += raw;
      }
    }
  }
  return Buffer.from(out);
}

// TGA RLE 解码（用于回环校验）：把上面的编码结果解回像素，必须与原图逐字节相同
function decodeRLE(buf, w, h) {
  const out = Buffer.alloc(w * h * 4);
  let o = 0;
  for (let y = 0; y < h; y++) {
    let x = 0;
    while (x < w) {
      const hdr = buf[o++];
      const count = (hdr & 0x7f) + 1;
      if (hdr & 0x80) {
        // 包里的 4 字节就是编码器写入的 R,G,B,A 顺序，不要按 TGA 磁盘上的 B,G,R,A 去读
        const r = buf[o], g = buf[o + 1], b = buf[o + 2], a = buf[o + 3]; o += 4;
        for (let i = 0; i < count; i++) {
          const k = (y * w + x + i) * 4;
          out[k] = r; out[k + 1] = g; out[k + 2] = b; out[k + 3] = a;
        }
      } else {
        for (let i = 0; i < count; i++) {
          const k = (y * w + x + i) * 4;
          out[k] = buf[o]; out[k + 1] = buf[o + 1]; out[k + 2] = buf[o + 2]; out[k + 3] = buf[o + 3];
          o += 4;
        }
      }
      x += count;
    }
  }
  return out;
}

const files = fs.readdirSync(DIR).filter(f => f.endsWith('.tga')).sort();
let rawTotal = 0, rleTotal = 0;
let allMatch = true;
const rows = [];

for (const f of files) {
  const full = path.join(DIR, f);
  const cur = fs.statSync(full).size;
  const d = decodeTGA(full);
  const rle = encodeRLE(d);
  const withHeader = 18 + rle.length;
  rawTotal += cur;
  rleTotal += withHeader;
  rows.push([f, `${d.w}x${d.h}`, cur, withHeader, cur > 0 ? (1 - withHeader / cur) : 0]);

  // 回环校验：解回来必须和原像素逐字节相同
  const back = decodeRLE(rle, d.w, d.h);
  const orig = Buffer.from(d.px.buffer, d.px.byteOffset, d.px.length);
  if (!back.equals(orig)) {
    allMatch = false;
    let at = -1;
    for (let i = 0; i < orig.length; i++) if (back[i] !== orig[i]) { at = i; break; }
    const px_i = at >> 2, ch = at & 3;
    console.log(`[FAIL] ${f}: 首个差异在字节 ${at}（第 ${px_i} 像素 = 第 ${(px_i / d.w) | 0} 行 第 ${px_i % d.w} 列，通道 ${ch}）` +
                ` 原=${orig[at]} 回=${back[at]}`);
  }
}

rows.sort((a, b) => (b[2] - b[3]) - (a[2] - a[3]));

console.log('纹理'.padEnd(26) + '尺寸'.padEnd(11) + '当前(raw)'.padStart(11) + 'RLE 后'.padStart(11) + '省下'.padStart(10));
console.log('-'.repeat(69));
for (const [f, sz, cur, rle, save] of rows) {
  const kb = (n) => (n / 1024).toFixed(1) + 'K';
  console.log(f.padEnd(26) + sz.padEnd(11) + kb(cur).padStart(11) + kb(rle).padStart(11) + ((save * 100).toFixed(0) + '%').padStart(10));
}
console.log('-'.repeat(69));
console.log('合计'.padEnd(26) + ''.padEnd(11) + ((rawTotal / 1024).toFixed(1) + 'K').padStart(11) + ((rleTotal / 1024).toFixed(1) + 'K').padStart(11) + (((1 - rleTotal / rawTotal) * 100).toFixed(1) + '%').padStart(10));
console.log(`\n像素完全不变（同一份 RGBA，只换 TGA 的行程编码），省下 ${((rawTotal - rleTotal) / 1024).toFixed(1)} KB`);
console.log(`回环校验：${allMatch ? files.length + '/' + files.length + ' 张 RLE 解码后与原图逐字节相同 —— 编码器正确' : '存在不一致，编码器有 bug'}`);