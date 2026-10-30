/**
 * tools/tga-post.js —— 导出后的收尾（GIMP 画的材质要走这一步）。
 *
 * 两件事：
 *  1) **纯白衬底**：alpha=0 的像素 RGB 必须是 (255,255,255)，绝不能是黑。
 *     客户端建 mip / 滤波时会把边缘颜色拖进可见区，黑衬底会让每个图标镶一圈灰边；
 *     而纯白哑光乘任何染色正好等于那个染色（AGENTS.md 材质制作规范）。
 *  2) **格式**：项目里所有材质都是**未压缩 32bit TGA（type 2，BGRA，bottom-left origin）**。
 *     GIMP 的 TGA 导出默认是 RLE（type 10），所以 GIMP 出的图先落 PNG，再由这里转成
 *     项目格式 —— 顺带保证任何来源的材质最后一步都过同一把尺子。
 *
 * 用法：
 *   node tools/tga-post.js <in.png> <out.tga>   # PNG → 项目格式 TGA
 *   node tools/tga-post.js <file.tga>            # 就地补白衬底（type 2 的 TGA）
 *   node tools/tga-post.js <file.tga> --check    # 只报信息
 */

const fs = require('fs');
const path = require('path');
const { createCanvas, loadImage } = require('@napi-rs/canvas');

/** 写未压缩 32bit TGA：BGRA、bottom-left origin（descriptor 0x08）。 */
function writeTga(file, w, h, rgba) {
  const header = Buffer.alloc(18);
  header[2] = 2;                                  // type 2 = uncompressed true-colour
  header.writeUInt16LE(w, 12);
  header.writeUInt16LE(h, 14);
  header[16] = 32;
  header[17] = 0x08;                              // 8 位 alpha + bottom-left origin
  const px = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    const src = (h - 1 - y) * w * 4;              // TGA 是 bottom-left：第 0 行是画布最下面
    for (let x = 0; x < w; x++) {
      const s = src + x * 4, d = (y * w + x) * 4;
      px[d] = rgba[s + 2];                        // B
      px[d + 1] = rgba[s + 1];                    // G
      px[d + 2] = rgba[s];                        // R
      px[d + 3] = rgba[s + 3];                    // A
    }
  }
  fs.writeFileSync(file, Buffer.concat([header, px]));
}

/** 透明像素的 RGB 补成纯白；返回改了多少个。 */
function fixMatte(rgba, count) {
  let fixed = 0;
  for (let i = 0; i < count; i++) {
    if (rgba[i * 4 + 3] === 0 &&
        (rgba[i * 4] !== 255 || rgba[i * 4 + 1] !== 255 || rgba[i * 4 + 2] !== 255)) {
      rgba[i * 4] = 255; rgba[i * 4 + 1] = 255; rgba[i * 4 + 2] = 255;
      fixed++;
    }
  }
  return fixed;
}

async function main() {
  const args = process.argv.slice(2).filter(a => !a.startsWith('--'));
  const check = process.argv.includes('--check');
  if (args.length === 0) {
    console.error('用法: node tools/tga-post.js <in.png> <out.tga> | <file.tga> [--check]');
    process.exit(1);
  }

  const input = args[0];
  if (/\.png$/i.test(input)) {
    const out = args[1] || input.replace(/\.png$/i, '.tga');
    const img = await loadImage(input);
    const w = img.width, h = img.height;
    const cv = createCanvas(w, h);
    const ctx = cv.getContext('2d');
    ctx.drawImage(img, 0, 0);
    const data = ctx.getImageData(0, 0, w, h).data;
    const fixed = fixMatte(data, w * h);
    if (!check) writeTga(out, w, h, data);
    console.log(`${input} -> ${out}  ${w}x${h}  非白衬底像素=${fixed}`);
    return;
  }

  // 已是 TGA：只补白衬底（要求 type 2 未压缩）
  const b = fs.readFileSync(input);
  const type = b.readUInt8(2);
  if (type !== 2) {
    console.error(`${input}: TGA type=${type}（不是未压缩的 type 2）—— 先用 PNG 中转`);
    process.exit(2);
  }
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
  const desc = b.readUInt8(17);
  const topLeft = (desc & 0x20) !== 0;
  let o = 18;
  const px = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
    const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
    const idx = (row * w + (i % w)) * 4;
    px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
  }
  const fixed = fixMatte(px, w * h);
  console.log(`${input}  ${w}x${h}  descriptor=0x${desc.toString(16)}  非白衬底像素=${fixed}`);
  if (!check) {
    const header = Buffer.alloc(18);
    header[2] = 2;
    header.writeUInt16LE(w, 12);
    header.writeUInt16LE(h, 14);
    header[16] = 32;
    header[17] = 0x08;
    fs.writeFileSync(input, Buffer.concat([header, px]));
    console.log('  已重写（纯白衬底）');
  }
}

main();
