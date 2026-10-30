// 分析 Andromeda TGA 纹理的线宽
const fs = require('fs');
const path = require('path');

const ANDROMEDA_DIR = 'C:/Users/EastHillGu/Documents/wowaddonsdev/Andromeda/assets/textures';

function decodeTGA(buf) {
  const idLength = buf.readUInt8(0);
  const colormapType = buf.readUInt8(1);
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

// 检测线宽：扫描第一行/列，找到从透明→不透明→透明的过渡
function measureLineWidth(pixels, width, height, direction) {
  const widths = [];
  if (direction === 'horizontal') {
    // 扫描每一行，检测水平线段宽度
    for (let y = 0; y < height; y++) {
      let runStart = -1;
      for (let x = 0; x <= width; x++) {
        const alpha = x < width ? pixels[(y * width + x) * 4 + 3] : 0;
        if (alpha > 0 && runStart < 0) {
          runStart = x;
        } else if (alpha === 0 && runStart >= 0) {
          widths.push(x - runStart);
          runStart = -1;
        }
      }
    }
  } else {
    // 扫描每一列，检测垂直线段宽度
    for (let x = 0; x < width; x++) {
      let runStart = -1;
      for (let y = 0; y <= height; y++) {
        const alpha = y < height ? pixels[(y * width + x) * 4 + 3] : 0;
        if (alpha > 0 && runStart < 0) {
          runStart = y;
        } else if (alpha === 0 && runStart >= 0) {
          widths.push(y - runStart);
          runStart = -1;
        }
      }
    }
  }
  return widths;
}

// 检测边框宽度：从边缘向内扫描
function measureBorderWidth(pixels, width, height) {
  const results = { top: 0, bottom: 0, left: 0, right: 0 };
  // Top border: 扫描第一列从上往下
  for (let y = 0; y < height; y++) {
    if (pixels[(y * width + 0) * 4 + 3] > 0) results.top++;
    else if (results.top > 0) break;
  }
  // Bottom border
  for (let y = height - 1; y >= 0; y--) {
    if (pixels[(y * width + 0) * 4 + 3] > 0) results.bottom++;
    else if (results.bottom > 0) break;
  }
  // Left border
  for (let x = 0; x < width; x++) {
    if (pixels[(0 * width + x) * 4 + 3] > 0) results.left++;
    else if (results.left > 0) break;
  }
  // Right border
  for (let x = width - 1; x >= 0; x--) {
    if (pixels[(0 * width + x) * 4 + 3] > 0) results.right++;
    else if (results.right > 0) break;
  }
  return results;
}

// 主逻辑
function scanDir(dir) {
  const results = [];
  const files = fs.readdirSync(dir).filter(f => f.endsWith('.tga'));
  for (const f of files.sort()) {
    const fullPath = path.join(dir, f);
    const buf = fs.readFileSync(fullPath);
    const { width, height, pixels } = decodeTGA(buf);
    const hWidths = measureLineWidth(pixels, width, height, 'horizontal');
    const vWidths = measureLineWidth(pixels, width, height, 'vertical');
    const border = measureBorderWidth(pixels, width, height);
    const allWidths = [...hWidths, ...vWidths];
    const avgWidth = allWidths.length ? (allWidths.reduce((a, b) => a + b, 0) / allWidths.length).toFixed(2) : 0;
    const minWidth = allWidths.length ? Math.min(...allWidths) : 0;
    const maxWidth = allWidths.length ? Math.max(...allWidths) : 0;
    results.push({ name: f, width, height, avgWidth, minWidth, maxWidth, border, pixelCount: allWidths.length });
  }
  return results;
}

console.log('=== Andromeda TGA 纹理线宽分析 ===\n');

const rootResults = scanDir(ANDROMEDA_DIR);
const buttonDir = path.join(ANDROMEDA_DIR, 'button');
const buttonResults = fs.existsSync(buttonDir) ? scanDir(buttonDir) : [];

const allResults = [...rootResults, ...buttonResults];

console.log('文件名'.padEnd(35), '尺寸'.padEnd(10), '平均线宽', '最小', '最大', '上边框', '下边框', '左边框', '右边框');
console.log('-'.repeat(110));
for (const r of allResults) {
  console.log(
    r.name.padEnd(35),
    (r.width + 'x' + r.height).padEnd(10),
    String(r.avgWidth).padEnd(8),
    String(r.minWidth).padEnd(4),
    String(r.maxWidth).padEnd(4),
    String(r.border.top).padEnd(6),
    String(r.border.bottom).padEnd(6),
    String(r.border.left).padEnd(6),
    String(r.border.right).padEnd(6)
  );
}

// 统计汇总
const allAvgs = allResults.filter(r => r.avgWidth > 0).map(r => parseFloat(r.avgWidth));
if (allAvgs.length) {
  const overallAvg = (allAvgs.reduce((a, b) => a + b, 0) / allAvgs.length).toFixed(2);
  console.log('\n总体平均线宽: ' + overallAvg + 'px');
}
