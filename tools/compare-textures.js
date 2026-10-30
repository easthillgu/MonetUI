const fs = require('fs');
const os = require('os');
const path = require('path');

const OLD_DIR = path.join(__dirname, '..', 'Assets-src', 'Textures');
const NEW_DIR = path.join(os.tmpdir(), 'opencode', 'texture-compare');

function decodeTGA(buf) {
  const imageType = buf.readUInt8(2);
  const width = buf.readUInt16LE(12);
  const height = buf.readUInt16LE(14);
  const bpp = buf.readUInt8(16);
  const descriptor = buf.readUInt8(17);
  const topLeft = (descriptor & 0x20) !== 0;
  let offset = 18;
  const pixels = new Uint8Array(width * height * 4);
  if (imageType === 2) {
    for (let i = 0; i < width * height; i++) {
      const b = buf[offset++]; const g = buf[offset++];
      const r = buf[offset++]; const a = buf[offset++];
      const row = topLeft ? i / width | 0 : height - 1 - (i / width | 0);
      const col = i % width;
      const idx = (row * width + col) * 4;
      pixels[idx] = r; pixels[idx+1] = g; pixels[idx+2] = b; pixels[idx+3] = a;
    }
  } else if (imageType === 10) {
    let pos = 0;
    let row = topLeft ? 0 : height - 1;
    let col = 0;
    const totalPixels = width * height;
    while (pos < totalPixels) {
      const header = buf[offset++];
      const count = (header & 0x7F) + 1;
      if (header & 0x80) {
        const b = buf[offset++]; const g = buf[offset++];
        const r = buf[offset++]; const a = buf[offset++];
        for (let i = 0; i < count; i++) {
          const idx = (row * width + col) * 4;
          pixels[idx] = r; pixels[idx+1] = g; pixels[idx+2] = b; pixels[idx+3] = a;
          col++;
          if (col >= width) { col = 0; row += topLeft ? 1 : -1; }
          pos++;
        }
      } else {
        for (let i = 0; i < count; i++) {
          const b = buf[offset++]; const g = buf[offset++];
          const r = buf[offset++]; const a = buf[offset++];
          const idx = (row * width + col) * 4;
          pixels[idx] = r; pixels[idx+1] = g; pixels[idx+2] = b; pixels[idx+3] = a;
          col++;
          if (col >= width) { col = 0; row += topLeft ? 1 : -1; }
          pos++;
        }
      }
    }
  }
  return { width, height, pixels };
}

const files = fs.readdirSync(OLD_DIR).filter(f => f.endsWith('.tga')).sort();
console.log('=== 新旧纹理对比 ===\n');
console.log('文件名'.padEnd(30), '尺寸变化'.padEnd(14), '像素差%', 'Alpha差%', '结构相似度');
console.log('-'.repeat(85));

for (const f of files) {
  const oldPath = path.join(OLD_DIR, f);
  const newPath = path.join(NEW_DIR, f);
  if (!fs.existsSync(newPath)) continue;
  const oldInfo = decodeTGA(fs.readFileSync(oldPath));
  const newInfo = decodeTGA(fs.readFileSync(newPath));
  if (oldInfo.width !== newInfo.width || oldInfo.height !== newInfo.height) {
    console.log(f.padEnd(30), (oldInfo.width + 'x' + oldInfo.height + '→' + newInfo.width + 'x' + newInfo.height).padEnd(14), 'N/A');
    continue;
  }
  let pixelDiff = 0, alphaDiff = 0, matching = 0;
  const total = oldInfo.width * oldInfo.height;
  for (let i = 0; i < total; i++) {
    const o = i * 4, n = i * 4;
    const dr = Math.abs(oldInfo.pixels[o] - newInfo.pixels[n]);
    const dg = Math.abs(oldInfo.pixels[o+1] - newInfo.pixels[n+1]);
    const db = Math.abs(oldInfo.pixels[o+2] - newInfo.pixels[n+2]);
    const da = Math.abs(oldInfo.pixels[o+3] - newInfo.pixels[n+3]);
    pixelDiff += (dr + dg + db) / 3;
    alphaDiff += da;
    if (dr < 10 && dg < 10 && db < 10 && da < 10) matching++;
  }
  const avgPixelDiff = (pixelDiff / total).toFixed(1);
  const avgAlphaDiff = (alphaDiff / total).toFixed(1);
  const similarity = (matching / total * 100).toFixed(1) + '%';
  console.log(f.padEnd(30), '同尺寸'.padEnd(14), avgPixelDiff.padEnd(7), avgAlphaDiff.padEnd(7), similarity);
}
