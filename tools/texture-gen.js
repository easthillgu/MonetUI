/**
 * MonetUI Texture Generator — 基于 @napi-rs/canvas 的精确 TGA 纹理生成工具
 * 
 * 用法：
 *   node tools/texture-gen.js <command> [options]
 * 
 * 命令：
 *   panel    — 生成面板背景纹理（带边框、内阴影、可选圆角）
 *   button   — 生成按钮纹理（正常/按下/悬停三态）
 *   border   — 生成 1px 精确边框线条
 *   arc      — 生成圆弧/环形纹理
 *   line     — 生成精确宽度直线
 * 
 * 示例：
 *   node tools/texture-gen.js panel --width 256 --height 64 --border-color "#1a1a2e" --output assets/panel.tga
 *   node tools/texture-gen.js button --width 128 --height 32 --text "确认" --output assets/button_normal.tga
 *   node tools/texture-gen.js border --length 256 --width 1 --color "#4a6fa5" --output assets/border.tga
 *   node tools/texture-gen.js arc --radius 48 --stroke-width 4 --start 0 --end 6.28 --output assets/ring.tga
 */

const { createCanvas } = require('@napi-rs/canvas');
const fs = require('fs');
const path = require('path');

// ============================================================
// 参数解析
// ============================================================
function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        args[key] = argv[i + 1];
        i++;
      } else {
        args[key] = true;
      }
    } else {
      args._.push(a);
    }
  }
  return args;
}

// ============================================================
// 颜色工具
// ============================================================
function hexToRgba(hex, alpha = 1) {
  let h = hex.replace('#', '');
  if (h.length === 3) h = h.split('').map(c => c + c).join('');
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return [r, g, b, Math.round(alpha * 255)];
}

function rgbaString(rgba) {
  if (rgba[3] === 255) return `rgb(${rgba[0]},${rgba[1]},${rgba[2]})`;
  return `rgba(${rgba[0]},${rgba[1]},${rgba[2]},${(rgba[3] / 255).toFixed(3)})`;
}

// ============================================================
// 圆角矩形路径
// ============================================================
function roundedRect(ctx, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.arcTo(x + w, y, x + w, y + r, r);
  ctx.lineTo(x + w, y + h - r);
  ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
  ctx.lineTo(x + r, y + h);
  ctx.arcTo(x, y + h, x, y + h - r, r);
  ctx.lineTo(x, y + r);
  ctx.arcTo(x, y, x + r, y, r);
  ctx.closePath();
}

// ============================================================
// 命令实现
// ============================================================
function cmdPanel(args) {
  const w = parseInt(args.width) || 256;
  const h = parseInt(args.height) || 64;
  const radius = parseInt(args.radius) || 0;
  const borderW = parseFloat(args['border-width']) || 1;
  const bgColor = hexToRgba(args['bg-color'] || '#0d1117');
  const borderColor = hexToRgba(args['border-color'] || '#30363d');
  const innerGlow = args['inner-glow'] !== 'false';
  const output = args.output || 'assets/panel.tga';

  const canvas = createCanvas(w, h);
  const ctx = canvas.getContext('2d');

  // 背景
  if (radius > 0) {
    roundedRect(ctx, 0, 0, w, h, radius);
  } else {
    ctx.beginPath();
    ctx.rect(0, 0, w, h);
  }
  ctx.fillStyle = rgbaString(bgColor);
  ctx.fill();

  // 内部发光/顶部高光
  if (innerGlow) {
    const grad = ctx.createLinearGradient(0, 0, 0, h * 0.5);
    grad.addColorStop(0, 'rgba(255,255,255,0.03)');
    grad.addColorStop(1, 'rgba(255,255,255,0)');
    if (radius > 0) {
      roundedRect(ctx, 1, 1, w - 2, h * 0.5, Math.max(0, radius - 1));
    } else {
      ctx.beginPath();
      ctx.rect(1, 1, w - 2, h * 0.5);
    }
    ctx.fillStyle = grad;
    ctx.fill();
  }

  // 精确边框
  if (borderW > 0) {
    if (radius > 0) {
      roundedRect(ctx, borderW / 2, borderW / 2, w - borderW, h - borderW, Math.max(0, radius - borderW / 2));
    } else {
      ctx.beginPath();
      ctx.rect(borderW / 2, borderW / 2, w - borderW, h - borderW);
    }
    ctx.strokeStyle = rgbaString(borderColor);
    ctx.lineWidth = borderW;
    ctx.stroke();
  }

  saveTGA(canvas, output);
  console.log(`✓ Panel: ${w}x${h} → ${output}`);
}

function cmdButton(args) {
  const w = parseInt(args.width) || 128;
  const h = parseInt(args.height) || 32;
  const state = args.state || 'normal';
  const radius = parseInt(args.radius) || 4;
  const text = args.text || '';
  const output = args.output || `assets/button_${state}.tga`;

  const colors = {
    normal: { bg1: '#2d3748', bg2: '#1a202c', border: '#4a5568', text: '#e2e8f0' },
    hover:  { bg1: '#3d4a5c', bg2: '#243044', border: '#63b3ed', text: '#ffffff' },
    down:   { bg1: '#1a202c', bg2: '#0d1117', border: '#2b6cb0', text: '#bee3f8' },
    disabled: { bg1: '#1a1a2e', bg2: '#0f0f1a', border: '#2d2d44', text: '#4a5568' },
  };
  const c = colors[state] || colors.normal;

  const canvas = createCanvas(w, h);
  const ctx = canvas.getContext('2d');

  // 渐变背景
  const grad = ctx.createLinearGradient(0, 0, 0, h);
  grad.addColorStop(0, c.bg1);
  grad.addColorStop(1, c.bg2);
  roundedRect(ctx, 0, 0, w, h, radius);
  ctx.fillStyle = grad;
  ctx.fill();

  // 顶部高光
  const hlGrad = ctx.createLinearGradient(0, 0, 0, h * 0.45);
  hlGrad.addColorStop(0, 'rgba(255,255,255,0.08)');
  hlGrad.addColorStop(1, 'rgba(255,255,255,0)');
  roundedRect(ctx, 1, 1, w - 2, h * 0.45, Math.max(0, radius - 1));
  ctx.fillStyle = hlGrad;
  ctx.fill();

  // 边框
  roundedRect(ctx, 0.5, 0.5, w - 1, h - 1, radius);
  ctx.strokeStyle = c.border;
  ctx.lineWidth = 1;
  ctx.stroke();

  // 文字
  if (text) {
    const fontSize = parseInt(args['font-size']) || 12;
    ctx.font = `${fontSize}px "Microsoft YaHei", "Segoe UI", sans-serif`;
    ctx.fillStyle = c.text;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, w / 2, h / 2 + 0.5);
  }

  saveTGA(canvas, output);
  console.log(`✓ Button (${state}): ${w}x${h} → ${output}`);
}

function cmdBorder(args) {
  const length = parseInt(args.length) || 256;
  const borderW = parseFloat(args.width) || 1;
  const color = hexToRgba(args.color || '#4a6fa5');
  const orientation = args.orientation || 'horizontal';
  const output = args.output || 'assets/border.tga';

  const w = orientation === 'horizontal' ? length : borderW;
  const h = orientation === 'horizontal' ? borderW : length;

  const canvas = createCanvas(w, h);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = rgbaString(color);
  ctx.fillRect(0, 0, w, h);

  saveTGA(canvas, output);
  console.log(`✓ Border: ${w}x${h} (${borderW}px ${orientation}) → ${output}`);
}

function cmdArc(args) {
  const radius = parseFloat(args.radius) || 48;
  const strokeW = parseFloat(args['stroke-width']) || 4;
  const startAngle = parseFloat(args['start']) || 0;
  const endAngle = parseFloat(args['end']) || Math.PI * 2;
  const color = hexToRgba(args.color || '#63b3ed');
  const filled = args.filled === 'true' || args.filled === true;
  const output = args.output || 'assets/arc.tga';

  const size = Math.ceil((radius + strokeW) * 2 + 4);
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');
  const cx = size / 2;
  const cy = size / 2;

  ctx.beginPath();
  if (filled) {
    ctx.arc(cx, cy, radius, startAngle, endAngle);
    ctx.closePath();
    ctx.fillStyle = rgbaString(color);
    ctx.fill();
  } else {
    ctx.arc(cx, cy, radius, startAngle, endAngle);
    ctx.strokeStyle = rgbaString(color);
    ctx.lineWidth = strokeW;
    ctx.lineCap = args['line-cap'] || 'butt';
    ctx.stroke();
  }

  saveTGA(canvas, output);
  console.log(`✓ Arc: r=${radius} w=${strokeW} → ${output}`);
}

function cmdLine(args) {
  const length = parseInt(args.length) || 256;
  const lineW = parseFloat(args.width) || 1;
  const color = hexToRgba(args.color || '#ffffff');
  const orientation = args.orientation || 'horizontal';
  const output = args.output || 'assets/line.tga';

  const w = orientation === 'horizontal' ? length : lineW;
  const h = orientation === 'horizontal' ? lineW : length;

  const canvas = createCanvas(w, h);
  const ctx = canvas.getContext('2d');

  ctx.beginPath();
  if (orientation === 'horizontal') {
    const y = Math.floor(lineW / 2) + 0.5;
    ctx.moveTo(0, y);
    ctx.lineTo(length, y);
  } else {
    const x = Math.floor(lineW / 2) + 0.5;
    ctx.moveTo(x, 0);
    ctx.lineTo(x, length);
  }
  ctx.strokeStyle = rgbaString(color);
  ctx.lineWidth = lineW;
  ctx.lineCap = 'butt';
  ctx.stroke();

  saveTGA(canvas, output);
  console.log(`✓ Line: ${length}x${lineW}px → ${output}`);
}

function cmdGrid(args) {
  const w = parseInt(args.width) || 64;
  const h = parseInt(args.height) || 64;
  const cellW = parseInt(args['cell-width']) || 8;
  const cellH = parseInt(args['cell-height']) || 8;
  const gap = parseFloat(args.gap) || 0.5;
  const color = hexToRgba(args.color || '#63b3ed');
  const output = args.output || 'assets/grid.tga';

  const canvas = createCanvas(w, h);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = rgbaString(color);

  for (let y = 0; y < h; y += cellH + gap) {
    for (let x = 0; x < w; x += cellW + gap) {
      ctx.fillRect(x, y, cellW, cellH);
    }
  }

  saveTGA(canvas, output);
  console.log(`✓ Grid: ${w}x${h} cell=${cellW}x${cellH} gap=${gap} → ${output}`);
}

// ============================================================
// TGA 输出
// ============================================================
function saveTGA(canvas, outputPath) {
  const fs = require('fs');
  const path = require('path');

  // 确保目录存在
  const dir = path.dirname(outputPath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const width = canvas.width;
  const height = canvas.height;
  const ctx = canvas.getContext('2d');
  const imageData = ctx.getImageData(0, 0, width, height);
  const pixels = imageData.data; // RGBA Uint8ClampedArray

  // TGA 32-bit uncompressed (type 2)
  // Header: 18 bytes
  const header = Buffer.alloc(18);
  header.writeUInt8(0, 0);       // ID length
  header.writeUInt8(0, 1);       // colormap type
  header.writeUInt8(2, 2);       // image type = uncompressed true-color
  header.writeUInt16LE(0, 3);    // colormap origin
  header.writeUInt16LE(0, 5);    // colormap length
  header.writeUInt8(0, 7);       // colormap depth
  header.writeUInt16LE(0, 9);    // x origin
  header.writeUInt16LE(0, 11);   // y origin
  header.writeUInt16LE(width, 13);
  header.writeUInt16LE(height, 15);
  header.writeUInt8(32, 16);     // bits per pixel
  // descriptor byte: bit 5 = top-left origin (0x20)
  header.writeUInt8(0x20, 17);

  // Pixel data: TGA stores bottom-to-top, BGRA order
  const pixelBuffer = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    const srcRow = y * width * 4;
    const dstRow = (height - 1 - y) * width * 4; // flip vertically
    for (let x = 0; x < width; x++) {
      const si = srcRow + x * 4;
      const di = dstRow + x * 4;
      pixelBuffer[di]     = pixels[si + 2]; // B
      pixelBuffer[di + 1] = pixels[si + 1]; // G
      pixelBuffer[di + 2] = pixels[si];     // R
      pixelBuffer[di + 3] = pixels[si + 3]; // A
    }
  }

  fs.writeFileSync(outputPath, Buffer.concat([header, pixelBuffer]));
}

// ============================================================
// 主入口
// ============================================================
const args = parseArgs(process.argv.slice(2));
const command = args._[0];

const commands = {
  panel: cmdPanel,
  button: cmdButton,
  border: cmdBorder,
  arc: cmdArc,
  line: cmdLine,
  grid: cmdGrid,
};

if (command && commands[command]) {
  commands[command](args);
} else {
  console.log(`
MonetUI Texture Generator — 精确 TGA 纹理生成

用法: node tools/texture-gen.js <command> [options]

命令:
  panel    面板背景    --width --height --radius --bg-color --border-color --border-width --inner-glow
  button   按钮纹理    --width --height --state(normal|hover|down|disabled) --text --radius
  border   边框线条    --length --width --color --orientation(horizontal|vertical)
  arc      圆弧/圆环   --radius --stroke-width --start --end --color --filled --line-cap
  line     精确直线    --length --width --color --orientation
  grid     网格纹理    --width --height --cell-width --cell-height --gap --color

通用:
  --output   输出路径 (默认 assets/xxx.tga)

示例:
  node tools/texture-gen.js panel --width 256 --height 64 --border-color "#1a1a2e" --output assets/panel.tga
  node tools/texture-gen.js button --width 128 --height 32 --text "确认" --state normal
  node tools/texture-gen.js arc --radius 48 --stroke-width 4 --end 6.2832 --output assets/ring.tga
  node tools/texture-gen.js line --length 512 --width 1 --color "#4a6fa5"
`);
}
