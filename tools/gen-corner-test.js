// 生成 corner 方向测试 HTML
const { createCanvas } = require('@napi-rs/canvas');
const fs = require('fs');

const s = 64;
const LW = 2;

function drawCorner(ctx, cx, cy, r, startAngle, endAngle) {
  ctx.strokeStyle = '#fffcf6';
  ctx.lineWidth = LW;
  ctx.lineCap = 'butt';
  ctx.beginPath();
  ctx.arc(cx, cy, r, startAngle, endAngle);
  ctx.stroke();
}

const variants = [
  { name: 'A: 左上角弧线 (圆心s/2,s/2 r=s/2)', cx: s/2, cy: s/2, r: s/2 - LW/2, start: Math.PI, end: Math.PI * 1.5 },
  { name: 'B: 左下角弧线 (圆心s/2,s/2 r=s/2)', cx: s/2, cy: s/2, r: s/2 - LW/2, start: Math.PI * 1.5, end: Math.PI * 2 },
  { name: 'C: 右上角弧线 (圆心s/2,s/2 r=s/2)', cx: s/2, cy: s/2, r: s/2 - LW/2, start: 0, end: Math.PI * 0.5 },
  { name: 'D: 右下角弧线 (圆心s/2,s/2 r=s/2)', cx: s/2, cy: s/2, r: s/2 - LW/2, start: Math.PI * 0.5, end: Math.PI },
];

let html = '<html><head><meta charset="UTF-8"><style>' +
  'body{background:#1a1a2e;color:#eee;font-family:sans-serif;padding:20px;}' +
  '.grid{display:flex;flex-wrap:wrap;gap:20px;}' +
  '.item{text-align:center;}' +
  '.checker{width:128px;height:128px;background-image:conic-gradient(#333 25%, #222 0 50%, #333 0 75%, #222 0);background-size:16px 16px;image-rendering:pixelated;}' +
  'img{image-rendering:pixelated;}' +
  '</style></head><body>';
html += '<h2>Corner 方向测试</h2>';
html += '<p>代码注释: "The asset is the top-left arc" (左上角弧线)，其他三个方向通过 SetTexCoord 镜像生成</p>';
html += '<p>请确认哪个方向的弧线是正确的</p>';
html += '<div class="grid">';

for (const v of variants) {
  const canvas = createCanvas(s, s);
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, s, s);
  drawCorner(ctx, v.cx, v.cy, v.r, v.start, v.end);
  const dataUri = canvas.toDataURL('image/png');
  html += '<div class="item">';
  html += '<div style="font-size:12px;margin-bottom:8px;">' + v.name + '</div>';
  html += '<div class="checker"><img src="' + dataUri + '" style="width:' + s + 'px;height:' + s + 'px;"></div>';
  html += '</div>';
}

html += '</div></body></html>';
fs.writeFileSync(__dirname + '/../corner-test.html', html);
console.log('Generated: corner-test.html');
