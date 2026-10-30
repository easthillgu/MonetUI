/**
 * 分析参考插件的状态条填充材质（只读分析，不修改参考插件任何文件）
 * 目标：EllesmereUI\media\textures\ 下的 21 个 bar fill 纹理
 *
 * 报告：尺寸 / bpp / RLE / 渐变轴向哪条边最亮 / alpha 是否参与 / 透明像素是否纯黑
 * 用法：node tools/analyze-ref-barfill.js <media根目录>
 */

const fs = require('fs');
const path = require('path');

const MEDIA = process.argv[2] || 'C:/Users/EastHillGu/Documents/wowaddonsdev/EllesmereUI-v9.4/EllesmereUI/media';
const DIR = path.join(MEDIA, 'textures');

// EllesmereUI.BAR_TEXTURE_FILES（EllesmereUI/EllesmereUI.lua:1330）
const BAR_TEXTURES = [
  'melli', 'beautiful', 'plating', 'atrocity', 'divide', 'glass',
  'fade-right', 'thin-line-top', 'thin-line-bottom', 'fade',
  'gradient-lr', 'gradient-rl', 'gradient-bt', 'gradient-tb',
  'matte', 'sheer',
  'pixels-fill', 'pixels-dark', 'pixels-bg',
  'blinkii-diamonds', 'kringel-window',
];

function decodeTGA(file) {
  const b = fs.readFileSync(file);
  const idLen = b.readUInt8(0);
  const imgType = b.readUInt8(2);
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
  const bpp = b.readUInt8(16);
  const desc = b.readUInt8(17);
  const topLeft = (desc & 0x20) !== 0;
  if (imgType !== 2 || bpp !== 32) return { w, h, bpp, imgType, desc, rle: true };

  let o = 18 + idLen;
  const px = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
    const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
    const idx = (row * w + (i % w)) * 4;
    px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
  }
  return { w, h, bpp, imgType, desc, px };
}

// 取一条中线（水平或垂直）的亮度/alpha 剖面
function profile(d, axis) {
  const lum = [], alp = [];
  const steps = axis === 'v' ? d.h : d.w;
  for (let i = 0; i < steps; i++) {
    let sl = 0, sa = 0, n = 0;
    if (axis === 'v') {
      for (let x = 0; x < d.w; x++) {
        const k = (i * d.w + x) * 4;
        sl += d.px[k] * 0.299 + d.px[k + 1] * 0.587 + d.px[k + 2] * 0.114; sa += d.px[k + 3]; n++;
      }
    } else {
      for (let y = 0; y < d.h; y++) {
        const k = (y * d.w + i) * 4;
        sl += d.px[k] * 0.299 + d.px[k + 1] * 0.587 + d.px[k + 2] * 0.114; sa += d.px[k + 3]; n++;
      }
    }
    lum.push(sl / n); alp.push(sa / n);
  }
  return { lum, alp };
}

function spread(a) { return Math.max(...a) - Math.min(...a); }
function argmax(a) { let bi = 0; for (let i = 1; i < a.length; i++) if (a[i] > a[bi]) bi = i; return bi; }
function argmin(a) { let bi = 0; for (let i = 1; i < a.length; i++) if (a[i] < a[bi]) bi = i; return i; }

// 压缩成一串趋势，用于一行看清形状
function shape(a, len = 12) {
  const out = [];
  for (let i = 0; i < len; i++) {
    const v = a[Math.floor(i * (a.length - 1) / (len - 1))];
    out.push(Math.round(v / 26));   // 0-9
  }
  return out.join('');
}

console.log(`目录: ${DIR}\n`);
console.log('纹理'.padEnd(20) + '尺寸'.padEnd(12) + 'bpp  编码   alpha跨度  竖剖亮度  横剖亮度  最亮边');
console.log('-'.repeat(100));

for (const name of BAR_TEXTURES) {
  for (const ext of ['.tga', '.png']) {
    const f = path.join(DIR, name + ext);
    if (!fs.existsSync(f)) continue;
    let d;
    if (ext === '.tga') {
      d = decodeTGA(f);
    } else {
      d = { w: 0, h: 0, bpp: 0, imgType: 0, desc: 0, png: true };
      const b = fs.readFileSync(f);
      d.w = b.readUInt32BE(16); d.h = b.readUInt32BE(20);
      d.bpp = b[24];
      // PNG 只报头，不解像素
      console.log(`${(name + ext).padEnd(20)}${(d.w + 'x' + d.h).padEnd(12)}${String(d.bpp).padEnd(5)}PNG(${d.w}x${d.h}) —— 仅读头，PNG 未解像素`);
      continue;
    }
    const enc = d.rle ? 'RLE' : 'raw';
    if (d.rle) {
      console.log(`${name.padEnd(20)}${(d.w + 'x' + d.h).padEnd(12)}${String(d.bpp).padEnd(5)}${enc.padEnd(7)}(未解像素)`);
      continue;
    }
    const pv = profile(d, 'v'), ph = profile(d, 'h');
    const av = spread(pv.alp), ah = spread(ph.alp);
    const alphaAxis = av > ah * 1.5 ? '竖' : ah > av * 1.5 ? '横' : '均匀';
    const alphaTxt = `${av.toFixed(0)}/${ah.toFixed(0)} ${alphaAxis}`;
    const lv = spread(pv.lum), lh = spread(ph.lum);
    const vShape = shape(pv.lum), hShape = shape(ph.lum);
    // 最亮在哪条边
    const sideV = argmax(pv.lum) < d.h / 2 ? '上' : '下';
    const sideH = argmax(ph.lum) < d.w / 2 ? '左' : '右';
    const bright = lv > lh ? `竖${sideV}` : `横${sideH}`;
    console.log(`${name.padEnd(20)}${(d.w + 'x' + d.h).padEnd(12)}${String(d.bpp).padEnd(5)}${enc.padEnd(7)}${alphaTxt.padEnd(11)}${vShape.padEnd(10)}${hShape.padEnd(10)}${bright}`);
    break;
  }
}

console.log('\n图例：');
console.log('  alpha跨度 = 竖剖/横剖 的 alpha 极差（0 表示整幅同一 alpha）');
console.log('  亮度剖面 = 0-9 的相对亮度趋势（0 最暗，9 最亮），采样 12 点');
console.log('  最亮边 = 亮度剖面变化更大的那个轴上，最亮的一端在哪');