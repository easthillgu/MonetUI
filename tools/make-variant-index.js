/**
 * 材质变体对比页（把 make-variant-sheet.js 出的三页 PNG 拼成一个 HTML，方便一次看完）
 * 用法：node tools/make-variant-index.js
 */
const fs = require('fs');
const path = require('path');

const DIR = 'C:/Users/EastHillGu/AppData/Local/Temp/opencode/texture-review';
const pages = fs.readdirSync(DIR)
  .filter(f => /^variant-sheet-\d+\.png$/.test(f))
  .sort((a, b) => (+a.match(/\d+/)[0]) - (+b.match(/\d+/)[0]));

if (!pages.length) { console.error('先跑 node tools/make-variant-sheet.js'); process.exit(1); }

const html = [
  '<!doctype html><html lang="zh"><head><meta charset="utf-8">',
  '<title>MonetUI 材质三套变体对比</title><style>',
  'body{background:#0d0d0d;color:#ddd;font:14px/1.7 system-ui,"Microsoft YaHei",sans-serif;margin:0;padding:24px}',
  'h1{font-size:20px;margin:0 0 10px}',
  '.meta{color:#8a8a8a;margin:0 0 22px;max-width:900px}',
  '.meta b{color:#e8c9a0}',
  'img{display:block;max-width:640px;border:1px solid #2a2a2a;margin:0 0 18px;border-radius:4px}',
  '</style></head><body>',
  '<h1>MonetUI 材质三套变体 — 并排对比</h1>',
  '<div class="meta">',
  '三套只在「视觉重量」一个维度上分档：线宽 / 图标占画布比例 / 织纹密度 / role 灰度对比 / 关闭钮三态色。<br>',
  '每行<b>上半</b>是放大看清造型，<b>下半</b>是按真实显示尺寸（18px）缩一次再最近邻放大 5 倍 —— 小图标能不能认出来是在这个尺寸上决定的，只看放大图看不出来。<br>',
  '色板底色、描边宽度<b>不是</b>自由变量：都由 <code>Widget.lua</code> 按物理像素换算钉住（thickness * Media:Mult()），边框一律直角。',
  '</div>',
  ...pages.map(p => `<img src="${p}">`),
  '</body></html>',
].join('\n');

const out = path.join(DIR, 'variant-index.html');
fs.writeFileSync(out, html);
console.log('written: ' + out + '  (' + pages.length + ' 页)');