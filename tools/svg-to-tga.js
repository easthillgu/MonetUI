/**
 * tools/svg-to-tga.js —— SVG → 项目格式 TGA（走 Inkscape 导出 PNG 中转）。
 *
 * 为什么多一条这条路：
 *   * 脚本（node-canvas）画的是**像素**，改一个圆角要重跑脚本、对着代码调；
 *     SVG 是**矢量源码**，可以直接在 Inkscape 里打开、手改、存回仓库 ✓。
 *   * Inkscape 的渲染是矢量的，几何精确 —— 与脚本同级的"不糊"，但源文件可读可改。
 *   * 笔触那种"要软、要洇、要鬃毛"的仍然交给 GIMP（tools/gimp-brush-stroke.py）：
 *     矢量画不出颜料的洇边。两边互补。
 *
 * 规矩：
 *   * **有 SVG 的以 SVG 为准** —— 生成器（tools/regen-textures.js）里不再画同名纹理，
 *     否则两套源码会互相覆盖。
 *   * SVG 画布尺寸必须是 **2 的幂**（AGENTS.md 材质制作规范），这里会校验。
 *   * 导出的 PNG 一律走 tools/tga-post.js 那套：未压缩 32bit TGA（type 2）+ 纯白衬底。
 *
 * 用法：
 *   node tools/svg-to-tga.js              # 全部导出
 *   node tools/svg-to-tga.js --check      # 只报信息与尺寸校验，不写文件
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { createCanvas, loadImage } = require('@napi-rs/canvas');

const ROOT = path.join(__dirname, '..');
const SVG_DIR = path.join(__dirname, 'svg');
// 源（TGA）落 Assets-src/Textures：进 git、不发行。交付（BLP）落 Assets/Textures。
// 与 regen-textures.js 同口径 —— 任何一条路线出新 TGA 都要同步转 BLP，否则游戏里还是旧像素。
const SRC_DIR = path.join(ROOT, 'Assets-src', 'Textures');
const SHIP_DIR = path.join(ROOT, 'Assets', 'Textures');
const INKSCAPE = process.env.INKSCAPE
  || 'C:/Users/EastHillGu/Documents/GreenAPPS/Inkscape/bin/inkscape.com';

const check = process.argv.includes('--check');

function svgSize(file) {
  const head = fs.readFileSync(file, 'utf8').slice(0, 2000);
  const w = head.match(/\bwidth="([\d.]+)"/);
  const h = head.match(/\bheight="([\d.]+)"/);
  const vb = head.match(/viewBox="([-\d.]+)\s+([-\d.]+)\s+([\d.]+)\s+([\d.]+)"/);
  const W = w ? parseFloat(w[1]) : (vb ? parseFloat(vb[3]) : 0);
  const H = h ? parseFloat(h[1]) : (vb ? parseFloat(vb[4]) : 0);
  return { W, H };
}

function isPow2(n) { return n > 0 && (n & (n - 1)) === 0; }

/** PNG → 项目格式 TGA（未压缩 32bit BGRA，bottom-left origin，透明像素纯白衬底）。 */
function writeTga(file, w, h, rgba) {
  const header = Buffer.alloc(18);
  header[2] = 2;
  header.writeUInt16LE(w, 12);
  header.writeUInt16LE(h, 14);
  header[16] = 32;
  header[17] = 0x08;
  const px = Buffer.alloc(w * h * 4);
  let fixed = 0;
  for (let y = 0; y < h; y++) {
    const src = (h - 1 - y) * w * 4;
    for (let x = 0; x < w; x++) {
      const s = src + x * 4, d = (y * w + x) * 4;
      let r = rgba[s], g = rgba[s + 1], b = rgba[s + 2], a = rgba[s + 3];
      if (a === 0 && !(r === 255 && g === 255 && b === 255)) { r = g = b = 255; fixed++; }
      px[d] = b; px[d + 1] = g; px[d + 2] = r; px[d + 3] = a;
    }
  }
  fs.writeFileSync(file, Buffer.concat([header, px]));
  return fixed;
}

(async () => {
  if (!fs.existsSync(SVG_DIR)) {
    console.log('没有 ' + SVG_DIR + '（SVG 源目录）');
    return;
  }
  const svgs = fs.readdirSync(SVG_DIR).filter(f => f.toLowerCase().endsWith('.svg')).sort();
  if (!svgs.length) { console.log('SVG 目录是空的'); return; }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'monet-svg-'));
  let bad = 0;
  for (const svg of svgs) {
    const name = path.basename(svg, '.svg');
    const src = path.join(SVG_DIR, svg);
    const { W, H } = svgSize(src);
    const okSize = isPow2(W) && isPow2(H);
    if (!okSize) { bad++; console.log(`  [FAIL] ${name}: 画布 ${W}×${H} 不是 2 的幂`); }
    else console.log(`  ${name}: ${W}×${H}`);

    const png = path.join(tmp, name + '.png');
    execFileSync(INKSCAPE, ['--export-type=png', `--export-filename=${png}`, '--export-background-opacity=0', src],
                 { stdio: 'pipe' });
    const img = await loadImage(png);
    const cv = createCanvas(img.width, img.height);
    const c = cv.getContext('2d');
    c.drawImage(img, 0, 0);
    const data = c.getImageData(0, 0, img.width, img.height).data;
    if (!check) {
      const out = path.join(SRC_DIR, name + '.tga');
      const fixed = writeTga(out, img.width, img.height, data);
      const blp = path.join(SHIP_DIR, name + '.blp');
      execFileSync(process.execPath, [path.join(__dirname, 'tga-to-blp.js'), out, blp], { stdio: 'pipe' });
      console.log(`    -> ${path.relative(ROOT, out)} + ${path.basename(blp)}  (${img.width}×${img.height}, 补白衬底 ${fixed})`);
    }
  }
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(bad ? `尺寸不合规 ${bad} 个` : '全部通过尺寸校验');
})();
