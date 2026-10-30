// 分析 MonetUI TGA 纹理的线宽，对比 Andromeda 规范
const fs = require('fs');
const path = require('path');

const MONET_DIR = path.join(__dirname, '..', 'Assets-src', 'Textures');

function decodeTGA(buf) {
  const idLength = buf.readUInt8(0);
  const imageType = buf.readUInt8(2);
  const width = buf.readUInt16LE(12);
  const height = buf.readUInt16LE(14);
  const bpp = buf.readUInt8(16);
  const descriptor = buf.readUInt8(17);
  const topLeft = (descriptor & 0x20) !== 0;
  let offset = 18 + idLength;
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
    let pos = 0, row = topLeft ? 0 : height - 1, col = 0;
    const total = width * height;
    while (pos < total) {
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

function measureLineWidth(pixels, width, height, direction) {
  const widths = [];
  if (direction === 'horizontal') {
    for (let y = 0; y < height; y++) {
      let runStart = -1;
      for (let x = 0; x <= width; x++) {
        const alpha = x < width ? pixels[(y * width + x) * 4 + 3] : 0;
        if (alpha > 0 && runStart < 0) runStart = x;
        else if (alpha === 0 && runStart >= 0) { widths.push(x - runStart); runStart = -1; }
      }
    }
  } else {
    for (let x = 0; x < width; x++) {
      let runStart = -1;
      for (let y = 0; y <= height; y++) {
        const alpha = y < height ? pixels[(y * width + x) * 4 + 3] : 0;
        if (alpha > 0 && runStart < 0) runStart = y;
        else if (alpha === 0 && runStart >= 0) { widths.push(y - runStart); runStart = -1; }
      }
    }
  }
  return widths;
}

function measureBorderWidth(pixels, width, height) {
  const results = { top: 0, bottom: 0, left: 0, right: 0 };
  for (let y = 0; y < height; y++) {
    if (pixels[(y * width + 0) * 4 + 3] > 0) results.top++;
    else if (results.top > 0) break;
  }
  for (let y = height - 1; y >= 0; y--) {
    if (pixels[(y * width + 0) * 4 + 3] > 0) results.bottom++;
    else if (results.bottom > 0) break;
  }
  for (let x = 0; x < width; x++) {
    if (pixels[(0 * width + x) * 4 + 3] > 0) results.left++;
    else if (results.left > 0) break;
  }
  for (let x = width - 1; x >= 0; x--) {
    if (pixels[(0 * width + x) * 4 + 3] > 0) results.right++;
    else if (results.right > 0) break;
  }
  return results;
}

// 主逻辑
const files = fs.readdirSync(MONET_DIR).filter(f => f.endsWith('.tga')).sort();
console.log('=== MonetUI 现有纹理线宽分析 ===\n');
console.log('文件名'.padEnd(30), '尺寸'.padEnd(10), '平均线宽', '最小', '最大', '上', '下', '左', '右');
console.log('-'.repeat(90));

const results = [];
for (const f of files) {
  const buf = fs.readFileSync(path.join(MONET_DIR, f));
  const { width, height, pixels } = decodeTGA(buf);
  const hWidths = measureLineWidth(pixels, width, height, 'horizontal');
  const vWidths = measureLineWidth(pixels, width, height, 'vertical');
  const border = measureBorderWidth(pixels, width, height);
  const allWidths = [...hWidths, ...vWidths];
  const avgWidth = allWidths.length ? (allWidths.reduce((a, b) => a + b, 0) / allWidths.length).toFixed(2) : 0;
  const minWidth = allWidths.length ? Math.min(...allWidths) : 0;
  const maxWidth = allWidths.length ? Math.max(...allWidths) : 0;
  const r = { name: f, width, height, avgWidth, minWidth, maxWidth, border };
  results.push(r);
  console.log(
    r.name.padEnd(30),
    (r.width + 'x' + r.height).padEnd(10),
    String(r.avgWidth).padEnd(8),
    String(r.minWidth).padEnd(4),
    String(r.maxWidth).padEnd(4),
    String(r.border.top).padEnd(2),
    String(r.border.bottom).padEnd(2),
    String(r.border.left).padEnd(2),
    String(r.border.right).padEnd(2)
  );
}

// 对比建议
console.log('\n=== Andromeda 规范对比 ===\n');
console.log('Andromeda 关键线宽基准:');
console.log('  button-circle-border (64x64): 边框 ~2px');
console.log('  statusbar-stripes-thin (64x32): 细线 1px');
console.log('  button-minus/plus (16x16): 14px 粗线');
console.log('  ui-checkbox-tick (32x32): 勾线 ~2px');
console.log('\nMonetUI 对应调整建议:');
const suggestions = {
  'monet_round_edge': '应对齐 Andromeda button-circle-border 的 ~2px 线宽',
  'monet_barfill': '渐变条，无边框，保持一致',
  'monet_minus': '应对齐 Andromeda button-minus 的 14px 粗线（16x16基准）',
  'monet_plus': '应对齐 Andromeda button-plus 的 14px 粗线（16x16基准）',
  'monet_check': '应对齐 Andromeda ui-checkbox-tick 的 ~2px 线宽',
  'monet_close_normal': '应对齐 Andromeda button-circle-border 的 ~2px 线宽',
  'monet_close_hover': '应对齐 Andromeda button-circle-border 的 ~2px 线宽',
  'monet_close_push': '应对齐 Andromeda button-circle-border 的 ~2px 线宽',
};
for (const [key, suggestion] of Object.entries(suggestions)) {
  const r = results.find(r => r.name === key + '.tga');
  if (r) console.log('  ' + key + ': ' + suggestion);
}
