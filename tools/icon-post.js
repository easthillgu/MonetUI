/**
 * tools/icon-post.js —— 印象派图标的收尾：柔化 + 画布颗粒 + 合成。
 *
 * GIMP 的笔触是"盖章"出来的：一笔 = 一串实心椭圆硬边，所以直接看是数码味的。
 * 这里做三件事把它拉回油画：
 *   1) 背景重柔化（~2.4px）—— 硬边化开，色块互相洇，成"浑融"的水面；
 *      花只轻柔化（~0.8px），保留笔触与轮廓 —— 20x20 的插件列表里要认得出是朵花。
 *   2) 叠一层细颗粒 + 横向织纹（画布布纹）—— 破掉塑料感。
 *   3) 提一点饱和度 —— 让蓝绿更"莫奈"。
 *
 * 用法：
 *   node tools/icon-post.js --bg <bg.png> --fg <fg.png> --out <out.png>
 *        [--blur-bg=2.4] [--blur-fg=0.8] [--grain=5] [--sat=1.16]
 */

const fs = require('fs');
const { createCanvas, loadImage } = require('@napi-rs/canvas');

function arg(name, dflt) {
  const hit = process.argv.find(a => a.startsWith(`--${name}=`));
  return hit ? parseFloat(hit.split('=')[1]) : dflt;
}

function opt(name) {
  const eq = process.argv.find(a => a.startsWith(`--${name}=`));
  if (eq) return eq.split('=').slice(1).join('=');
  const i = process.argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < process.argv.length) return process.argv[i + 1];
  return null;
}

/** 高斯柔化。放大 5% 再画：否则模糊会把画布边缘啃掉一圈透明。 */
function blurred(img, radius) {
  const w = img.width, h = img.height;
  const cv = createCanvas(w, h);
  const ctx = cv.getContext('2d');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  if (radius > 0) {
    ctx.filter = `blur(${radius}px)`;
    const m = Math.round(w * 0.05);
    ctx.drawImage(img, -m, -m, w + m * 2, h + m * 2);
    ctx.filter = 'none';
  } else {
    ctx.drawImage(img, 0, 0);
  }
  return { cv, ctx };
}

async function main() {
  const bgPath = opt('bg');
  const fgPath = opt('fg');
  const outPath = opt('out');
  if (!bgPath || !outPath) {
    console.error('用法: node tools/icon-post.js --bg <bg.png> [--fg <fg.png>] --out <out.png> ' +
      '[--blur-bg=2.4] [--blur-fg=0.8] [--grain=5] [--sat=1.16]');
    process.exit(1);
  }
  const blurBg = arg('blur-bg', 2.4);
  const blurFg = arg('blur-fg', 0.8);
  let grain = arg('grain', 5);
  const sat = arg('sat', 1.16);
  const size = arg('size', 0);

  const bg = await loadImage(bgPath);
  const { cv, ctx } = blurred(bg, blurBg);

  // 前景（花）叠上来
  if (fgPath && fs.existsSync(fgPath)) {
    const fg = await loadImage(fgPath);
    const f = blurred(fg, blurFg);
    ctx.drawImage(f.cv, 0, 0);
  }

  // 缩到目标尺寸（插件列表里只显示 20x20，128 足够，还省文件体积）
  let work = { cv, ctx };
  let w = cv.width, h = cv.height;
  if (size > 0 && size !== w) {
    const sc = createCanvas(size, size);
    const sctx = sc.getContext('2d');
    sctx.imageSmoothingEnabled = true;
    sctx.imageSmoothingQuality = 'high';
    sctx.drawImage(cv, 0, 0, size, size);
    work = { cv: sc, ctx: sctx };
    w = h = size;
    grain = grain * (size / cv.width);
  }
  const data = work.ctx.getImageData(0, 0, w, h).data;

  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      let r = data[i], g = data[i + 1], b = data[i + 2];

      // 饱和度
      const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      r = l + (r - l) * sat;
      g = l + (g - l) * sat;
      b = l + (b - l) * sat;

      // 颗粒（确定性哈希，不用随机 —— 同一张图每次跑出来一样）
      const n = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
      const noise = (n - Math.floor(n) - 0.5) * 2 * grain;
      // 画布织纹：横向略强于纵向
      const weave = (Math.sin(x * Math.PI) * 0.5 + Math.sin(y * Math.PI * 0.5) * 0.25) * grain * 0.25;

      data[i] = Math.max(0, Math.min(255, r + noise + weave));
      data[i + 1] = Math.max(0, Math.min(255, g + noise + weave));
      data[i + 2] = Math.max(0, Math.min(255, b + noise + weave));
    }
  }
  const out = work.ctx.createImageData(w, h);
  out.data.set(new Uint8ClampedArray(data));
  work.ctx.putImageData(out, 0, 0);

  fs.writeFileSync(outPath, work.cv.toBuffer('image/png'));
  console.log(`${bgPath}${fgPath ? ' + ' + fgPath : ''} -> ${outPath}  ${w}x${h}  ` +
    `blur(bg ${blurBg}, fg ${blurFg}) grain=${grain} sat=${sat}`);
}

main();
