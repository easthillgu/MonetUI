// TGA → base64 PNG data URI
// 用法: node tga-to-png-base64.js <tga路径> <输出json路径>
const fs = require('fs');
const path = require('path');
const { createCanvas, loadImage } = require('@napi-rs/canvas');

async function tgaToPngDataURI(tgaPath) {
  const buf = fs.readFileSync(tgaPath);
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
  // 写入 canvas 再导出 PNG
  const canvas = createCanvas(width, height);
  const ctx = canvas.getContext('2d');
  const imgData = ctx.createImageData(width, height);
  imgData.data.set(pixels);
  ctx.putImageData(imgData, 0, 0);
  const pngBuf = canvas.toBuffer('image/png');
  return 'data:image/png;base64,' + pngBuf.toString('base64');
}

async function main() {
  const inputDir = process.argv[2];
  const outputFile = process.argv[3];
  const files = fs.readdirSync(inputDir).filter(f => f.endsWith('.tga')).sort();
  const result = {};
  for (const f of files) {
    const dataURI = await tgaToPngDataURI(path.join(inputDir, f));
    result[f] = dataURI;
    process.stdout.write('.');
  }
  console.log('');
  fs.writeFileSync(outputFile, JSON.stringify(result, null, 2));
  console.log('Written to ' + outputFile);
}

main().catch(e => { console.error(e); process.exit(1); });
