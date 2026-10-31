#!/usr/bin/env node
/**
 * tools/render-dot.js
 * 把 docs/architecture/*.dot 渲染成 SVG + PNG（本机没有 dot 可执行文件，走 wasm）。
 *
 *   node tools/render-dot.js              # 全部 .dot
 *   node tools/render-dot.js flow-main    # 只渲染名字含该片段的
 *   node tools/render-dot.js --scale=3    # PNG 放大倍数（默认 2）
 *   node tools/render-dot.js --max-width=12000
 *
 * 两处非显然的做法：
 *  1. @hpcc-js/wasm-graphviz 1.30 的 dot() 不支持 png 格式，所以先出 SVG，
 *     再交给仓里已有的 @napi-rs/canvas 光栅化。
 *  2. canvas 的 SVG 渲染器自带字体表里**没有中日韩字形**，不注册字体的话
 *     中文标签会全渲染成豆腐块（.notdef），图看着"出来了"其实一个字都没画对。
 *     所以先把系统中文字体注册成 DOT 里写的家族名 "Sans-Serif"。
 *  3. 扇入图天然是一条几百点高的宽带（44 个事件排一层），按倍数放大能出 3 万像素宽的 PNG，
 *     所以 PNG 有一个最大宽度，超过就自动降倍数（SVG 不受限，放大看细节请用 SVG）。
 */
const fs = require('fs');
const path = require('path');

const DIR = path.resolve(__dirname, '..', 'docs/architecture');
const FONT_FAMILY = 'Sans-Serif';
const FONT_CANDIDATES = [
  'C:/Windows/Fonts/msyh.ttc',
  'C:/Windows/Fonts/simhei.ttf',
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/arphic/uming.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

const numArg = (name, dflt) => {
  const hit = process.argv.slice(2).find(a => a.startsWith('--' + name + '='));
  return hit ? Number(hit.split('=')[1]) : dflt;
};

function pickFont() {
  for (const p of FONT_CANDIDATES) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

async function main() {
  const scale = numArg('scale', 2);
  const maxWidth = numArg('max-width', 12000);
  const filter = process.argv.slice(2).find(a => !a.startsWith('--'));
  const files = fs.readdirSync(DIR).filter(f => f.endsWith('.dot') && (!filter || f.includes(filter)));
  if (!files.length) {
    console.error('没有匹配的 .dot（目录 ' + DIR + '）');
    process.exitCode = 1;
    return;
  }

  const { Graphviz } = require('@hpcc-js/wasm-graphviz');
  const { GlobalFonts, loadImage, createCanvas } = require('@napi-rs/canvas');

  const font = pickFont();
  if (font) GlobalFonts.registerFromPath(font, FONT_FAMILY);
  else console.error('WARN 找不到中文字体，PNG 里的中文会渲染成方块（SVG 不受影响）');

  const gv = await Graphviz.load();
  for (const f of files) {
    const src = fs.readFileSync(path.join(DIR, f), 'utf8');
    const stem = f.replace(/\.dot$/, '');
    let svg;
    try {
      svg = await gv.dot(src, 'svg');
    } catch (e) {
      console.error('FAIL ' + f + ' —— DOT 解析失败: ' + String(e.message || e).split('\n')[0]);
      process.exitCode = 1;
      continue;
    }
    fs.writeFileSync(path.join(DIR, stem + '.svg'), svg, 'utf8');

    const img = await loadImage(Buffer.from(svg));
    // 放大到 scale 倍；超宽就降，但**不降到 1:1 以下** —— 再缩字就看不清了，
    // 那种图（扇入图是一条 9700pt 宽的横带）交给 SVG 看。
    const factor = Math.max(1, Math.min(scale, maxWidth / img.width));
    const w = Math.max(1, Math.round(img.width * factor));
    const h = Math.max(1, Math.round(img.height * factor));
    const canvas = createCanvas(w, h);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(img, 0, 0, w, h);
    fs.writeFileSync(path.join(DIR, stem + '.png'), canvas.toBuffer('image/png'));

    const note = factor < scale ? '（倍数 ' + factor.toFixed(2) + '，受 --max-width=' + maxWidth + '）'
      : img.width * scale > maxWidth ? '（1:1 已超宽，看 SVG）' : '';
    console.error(stem + ': svg ' + Math.round(svg.length / 1024) + 'KB · png ' + w + 'x' + h + ' ' +
      Math.round(fs.statSync(path.join(DIR, stem + '.png')).size / 1024) + 'KB ' + note);
  }
  console.error('字体 ' + (font || '（未注册，中文会成方块）') + ' → 家族名 ' + FONT_FAMILY);
}

main().catch(e => { console.error('FAIL', e); process.exitCode = 1; });
